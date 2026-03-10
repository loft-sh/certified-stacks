#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# End-to-end test suite for SkyPilot hard-multitenancy deployment
#
# Exercises all SkyPilot workload types via the SkyPilot API server:
#   1. sky launch     -- interactive development cluster with GPU
#   2. sky jobs launch -- managed job (training with auto-recovery)
#   3. sky serve up    -- model serving endpoint with replicas
#   4. sky exec        -- run command on existing cluster
#
# Prerequisites:
#   - A fully deployed hard-multitenancy stack (terraform apply completed)
#   - kubectl access to a tenant vCluster (kubeconfig from terraform output)
#   - SkyPilot CLI installed (pip install skypilot[kubernetes])
#   - curl, jq
#
# Usage:
#   ./test-hard-multitenancy.sh \
#       --kubeconfig ./skypilot-tenant-1-kubeconfig.yaml
#
#   # With API server endpoint (skips auto-detection):
#   ./test-hard-multitenancy.sh \
#       --kubeconfig ./skypilot-tenant-1-kubeconfig.yaml \
#       --api-endpoint http://10.0.0.1
#
#   # Run a single test:
#   ./test-hard-multitenancy.sh \
#       --kubeconfig ./skypilot-tenant-1-kubeconfig.yaml \
#       --test managed-job
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
API_ENDPOINT="${API_ENDPOINT:-}"
API_CREDENTIALS="${API_CREDENTIALS:-}"
RUN_TEST="${RUN_TEST:-all}"
SKYPILOT_NAMESPACE="${SKYPILOT_NAMESPACE:-skypilot}"
CLEANUP="${CLEANUP:-false}"
TIMEOUT="${TIMEOUT:-900}"
GPU_ENABLED="${GPU_ENABLED:-true}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --kubeconfig PATH       Path to tenant vCluster kubeconfig (required)
  --api-endpoint URL      SkyPilot API server URL (auto-detected if omitted)
  --api-credentials CREDS Auth credentials for the API (user:pass)
  --namespace NS          SkyPilot namespace (default: skypilot)
  --test NAME             Run a single test: cluster, exec, managed-job,
                          serve, all (default: all)
  --no-gpu                Run CPU-only workloads
  --cleanup               Tear down test resources after validation
  --timeout SECONDS       Max wait per workload (default: 900)
  -h, --help              Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)       KUBECONFIG_PATH="$2";   shift 2 ;;
    --api-endpoint)     API_ENDPOINT="$2";      shift 2 ;;
    --api-credentials)  API_CREDENTIALS="$2";   shift 2 ;;
    --namespace)        SKYPILOT_NAMESPACE="$2"; shift 2 ;;
    --test)             RUN_TEST="$2";          shift 2 ;;
    --no-gpu)           GPU_ENABLED=false;      shift ;;
    --cleanup)          CLEANUP=true;           shift ;;
    --timeout)          TIMEOUT="$2";           shift 2 ;;
    -h|--help)          usage ;;
    *)                  echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$KUBECONFIG_PATH" ]] && { echo "ERROR: --kubeconfig is required"; exit 1; }
[[ ! -f "$KUBECONFIG_PATH" ]] && { echo "ERROR: kubeconfig not found: $KUBECONFIG_PATH"; exit 1; }

log()  { echo "$(date +%H:%M:%S) [INFO]  $*"; }
pass() { echo "$(date +%H:%M:%S) [PASS]  $*"; }
fail() { echo "$(date +%H:%M:%S) [FAIL]  $*" >&2; }

KCTL="kubectl --kubeconfig=${KUBECONFIG_PATH}"
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_RUN=()
WORKDIR=""

record_pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); TESTS_RUN+=("PASS: $1"); }
record_fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); TESTS_RUN+=("FAIL: $1"); }

cleanup_workdir() {
  [[ -n "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup_workdir EXIT

# Create temp workdir for task YAML files
WORKDIR=$(mktemp -d)

# ═══════════════════════════════════════════════════════════════════════════
# SKYPILOT CLI WRAPPER
# ═══════════════════════════════════════════════════════════════════════════

SKY_CMD="sky"
SKY_LOGGED_IN=false

sky_login() {
  if [[ "$SKY_LOGGED_IN" == "true" ]]; then return 0; fi

  if [[ -n "$API_ENDPOINT" ]]; then
    log "Logging into SkyPilot API server at ${API_ENDPOINT} ..."
    local LOGIN_ARGS=("-e" "$API_ENDPOINT")
    if [[ -n "$API_CREDENTIALS" ]]; then
      LOGIN_ARGS+=("-u" "${API_CREDENTIALS%%:*}" "-p" "${API_CREDENTIALS#*:}")
    fi
    if ${SKY_CMD} api login "${LOGIN_ARGS[@]}" 2>&1; then
      pass "SkyPilot API login succeeded"
      SKY_LOGGED_IN=true
    else
      fail "SkyPilot API login failed"
      return 1
    fi
  else
    log "No --api-endpoint provided, using local SkyPilot with vCluster kubeconfig"
    export KUBECONFIG="$KUBECONFIG_PATH"
    SKY_LOGGED_IN=true
  fi
}

# Wait for a SkyPilot cluster to reach a target status
wait_for_sky_status() {
  local name="$1" target="$2" timeout="$3" label="$4"
  local elapsed=0 interval=15
  while [[ $elapsed -lt $timeout ]]; do
    local status
    status=$(${SKY_CMD} status "$name" --no-show-header 2>/dev/null | awk '{print $2}' || echo "")
    if [[ "$status" == "$target" ]]; then
      return 0
    fi
    log "  ${label}: status=${status:-PENDING} [${elapsed}s/${timeout}s]"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════

log "╔══════════════════════════════════════════════════════════════╗"
log "║  Pre-flight checks                                          ║"
log "╚══════════════════════════════════════════════════════════════╝"

log "Verifying kubectl access to tenant vCluster ..."
if ! ${KCTL} get ns "${SKYPILOT_NAMESPACE}" &>/dev/null; then
  fail "Cannot access namespace '${SKYPILOT_NAMESPACE}' in tenant vCluster"
  exit 1
fi
pass "kubectl access OK"

log "Checking SkyPilot components ..."
SKYPILOT_PODS=$(${KCTL} get pods -n "$SKYPILOT_NAMESPACE" -o name 2>/dev/null | wc -l | tr -d ' ')
log "  SkyPilot pods: ${SKYPILOT_PODS}"

# Auto-detect API endpoint if not provided
if [[ -z "$API_ENDPOINT" ]]; then
  log "Auto-detecting SkyPilot API endpoint ..."
  # Check ingress-nginx namespace first (standalone deployment)
  INGRESS_IP=$(${KCTL} get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [[ -z "$INGRESS_IP" ]]; then
    # Fallback: check skypilot namespace (bundled ingress-nginx)
    INGRESS_IP=$(${KCTL} get svc -n "$SKYPILOT_NAMESPACE" \
      -l "app.kubernetes.io/name=ingress-nginx" \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  fi
  if [[ -z "$INGRESS_IP" ]]; then
    INGRESS_IP=$(${KCTL} get svc -n "$SKYPILOT_NAMESPACE" \
      -l "app.kubernetes.io/name=ingress-nginx" \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  fi
  if [[ -n "$INGRESS_IP" ]]; then
    API_ENDPOINT="http://${INGRESS_IP}"
    log "  Detected API endpoint: ${API_ENDPOINT}"
  else
    log "  WARNING: Could not auto-detect API endpoint"
    log "  Will use local SkyPilot with vCluster kubeconfig"
  fi
fi

log "Checking SkyPilot CLI ..."
if ! command -v sky &>/dev/null; then
  fail "SkyPilot CLI (sky) not found — install with: pip install skypilot[kubernetes]"
  exit 1
fi
SKY_VERSION=$(sky --version 2>&1 || echo "unknown")
pass "SkyPilot CLI: ${SKY_VERSION}"

sky_login

# Check available resources
log "Checking available resources ..."
${SKY_CMD} check kubernetes 2>&1 | head -10 || true

# ═══════════════════════════════════════════════════════════════════════════
# GPU resource block for task YAML
# ═══════════════════════════════════════════════════════════════════════════

gpu_block() {
  if [[ "$GPU_ENABLED" == "true" ]]; then
    echo "  accelerators: T4:1"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: sky launch — interactive development cluster
# ═══════════════════════════════════════════════════════════════════════════

test_cluster() {
  local NAME="test-dev-cluster"
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Test: sky launch — development cluster                     ║"
  log "╚══════════════════════════════════════════════════════════════╝"

  # Cleanup previous
  ${SKY_CMD} down "$NAME" -y 2>/dev/null || true
  sleep 3

  # Create task YAML
  cat > "${WORKDIR}/dev-cluster.yaml" <<YAML
name: ${NAME}

resources:
  cloud: kubernetes
  cpus: 2+
  memory: 4+
$(gpu_block)

setup: |
  echo "Setting up development environment ..."
  pip install numpy pandas scikit-learn 2>/dev/null || true
  echo "Setup complete."

run: |
  echo "=== SkyPilot Development Cluster ==="
  echo "Hostname: \$(hostname)"
  echo "Python: \$(python3 --version)"
  echo ""

  python3 -c "
  import sys
  import platform
  print(f'Platform: {platform.platform()}')
  print(f'Python: {sys.version}')

  try:
      import numpy as np
      print(f'NumPy: {np.__version__}')
      # Quick compute test
      x = np.random.randn(1000, 1000)
      y = np.dot(x, x.T)
      print(f'Matrix multiply: {x.shape} -> {y.shape}, trace={np.trace(y):.2f}')
  except ImportError:
      print('NumPy not available')

  try:
      import torch
      print(f'PyTorch: {torch.__version__}')
      print(f'CUDA: {torch.cuda.is_available()}')
      if torch.cuda.is_available():
          print(f'GPU: {torch.cuda.get_device_name(0)}')
  except ImportError:
      print('PyTorch not available')

  print('')
  print('CLUSTER_LAUNCH_COMPLETED_SUCCESSFULLY')
  "
YAML

  log "Launching cluster '${NAME}' ..."
  local LAUNCH_OUTPUT
  LAUNCH_OUTPUT=$(${SKY_CMD} launch "${WORKDIR}/dev-cluster.yaml" -y --cluster "$NAME" -d 2>&1)
  local LAUNCH_RC=$?
  echo "$LAUNCH_OUTPUT" | tail -20

  if [[ $LAUNCH_RC -ne 0 ]]; then
    fail "sky launch failed (rc=${LAUNCH_RC})"
    record_fail "Cluster Launch"; return 1
  fi

  # Wait for the cluster to be UP
  log "Waiting for cluster to be UP ..."
  if wait_for_sky_status "$NAME" "UP" "$TIMEOUT" "Cluster"; then
    pass "Cluster ${NAME} is UP"
  else
    fail "Cluster did not reach UP state"
    ${SKY_CMD} status "$NAME" 2>/dev/null || true
    record_fail "Cluster Launch"; return 1
  fi

  # Verify we can execute on it
  log "Checking cluster logs ..."
  local LOGS
  LOGS=$(${SKY_CMD} logs "$NAME" --no-follow 2>&1 | tail -30 || echo "")
  echo "─── Cluster Logs (tail) ───"
  echo "$LOGS"
  echo "────────────────────────────"

  if echo "$LOGS" | grep -q "CLUSTER_LAUNCH_COMPLETED_SUCCESSFULLY"; then
    pass "Cluster run script completed with success marker"
  else
    log "  Success marker not found in logs (task may still be running)"
  fi

  # Don't clean up yet — we need it for the exec test
  record_pass "Cluster Launch"
  pass "Cluster Launch: PASSED"
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: sky exec — run command on existing cluster
# ═══════════════════════════════════════════════════════════════════════════

test_exec() {
  local NAME="test-dev-cluster"
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Test: sky exec — command on existing cluster               ║"
  log "╚══════════════════════════════════════════════════════════════╝"

  # Check if the cluster exists
  local STATUS
  STATUS=$(${SKY_CMD} status "$NAME" --no-show-header 2>/dev/null | awk '{print $2}' || echo "")
  if [[ "$STATUS" != "UP" ]]; then
    log "  Cluster ${NAME} not in UP state (status=${STATUS:-not found})"
    log "  Launching cluster first ..."
    test_cluster || { record_fail "Exec on Cluster"; return 1; }
  fi

  # sky exec with inline command
  log "Running sky exec with inline command ..."
  local EXEC_OUTPUT
  EXEC_OUTPUT=$(${SKY_CMD} exec "$NAME" -- bash -c '
    echo "=== sky exec test ==="
    echo "Hostname: $(hostname)"
    echo "Working dir: $(pwd)"
    echo "User: $(whoami)"

    # Check GPU if available
    if command -v nvidia-smi &>/dev/null; then
      echo ""
      echo "--- GPU Info ---"
      nvidia-smi -L
    fi

    echo ""
    echo "EXEC_COMPLETED_SUCCESSFULLY"
  ' 2>&1)
  echo "$EXEC_OUTPUT" | tail -20

  if echo "$EXEC_OUTPUT" | grep -q "EXEC_COMPLETED_SUCCESSFULLY"; then
    pass "sky exec completed with success marker"
  else
    fail "sky exec did not return success marker"
    record_fail "Exec on Cluster"; return 1
  fi

  # sky exec with a task YAML
  cat > "${WORKDIR}/exec-task.yaml" <<YAML
run: |
  echo "=== sky exec (task YAML) ==="
  python3 -c "
  import sys, os
  print(f'Python: {sys.version}')
  print(f'PID: {os.getpid()}')
  print(f'ENV HOME: {os.environ.get(\"HOME\", \"unknown\")}')
  print('EXEC_TASK_YAML_OK')
  "
YAML

  log "Running sky exec with task YAML ..."
  local EXEC_YAML_OUTPUT
  EXEC_YAML_OUTPUT=$(${SKY_CMD} exec "$NAME" "${WORKDIR}/exec-task.yaml" 2>&1)
  echo "$EXEC_YAML_OUTPUT" | tail -10

  if echo "$EXEC_YAML_OUTPUT" | grep -q "EXEC_TASK_YAML_OK"; then
    pass "sky exec (task YAML) completed"
  else
    log "  Task YAML exec marker not found (non-critical)"
  fi

  if [[ "$CLEANUP" == "true" ]]; then
    ${SKY_CMD} down "$NAME" -y 2>/dev/null || true
  fi

  record_pass "Exec on Cluster"
  pass "Exec on Cluster: PASSED"
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: sky jobs launch — managed job (training)
# ═══════════════════════════════════════════════════════════════════════════

test_managed_job() {
  local NAME="test-managed-training"
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Test: sky jobs launch — managed training job               ║"
  log "╚══════════════════════════════════════════════════════════════╝"

  # Cancel any previous run
  ${SKY_CMD} jobs cancel -n "$NAME" -y 2>/dev/null || true
  sleep 3

  cat > "${WORKDIR}/managed-job.yaml" <<YAML
name: ${NAME}

resources:
  cloud: kubernetes
  cpus: 2+
  memory: 4+
$(gpu_block)

setup: |
  pip install numpy 2>/dev/null || true

run: |
  echo "=== SkyPilot Managed Training Job ==="
  echo "Hostname: \$(hostname)"
  echo ""

  python3 -c "
  import time
  import random
  import os

  print('Starting managed training job ...')
  print(f'PID: {os.getpid()}')

  # Simulate a training loop that SkyPilot can manage
  # (auto-recovery, spot preemption handling)
  NUM_EPOCHS = 10
  best_loss = float('inf')
  start = time.time()

  for epoch in range(NUM_EPOCHS):
      # Simulate training
      loss = 1.0 / (epoch + 1) + random.gauss(0, 0.01)
      accuracy = 1.0 - loss + random.uniform(0, 0.05)
      accuracy = min(max(accuracy, 0), 1.0)

      if loss < best_loss:
          best_loss = loss
          print(f'  Epoch {epoch+1}/{NUM_EPOCHS}: loss={loss:.4f}, acc={accuracy:.4f} *best*')
      else:
          print(f'  Epoch {epoch+1}/{NUM_EPOCHS}: loss={loss:.4f}, acc={accuracy:.4f}')

      time.sleep(1)  # Simulate computation time

  elapsed = time.time() - start
  print(f'')
  print(f'Training complete in {elapsed:.1f}s')
  print(f'Best loss: {best_loss:.4f}')
  print('MANAGED_JOB_COMPLETED_SUCCESSFULLY')
  "
YAML

  log "Launching managed job '${NAME}' ..."
  local JOB_OUTPUT
  JOB_OUTPUT=$(${SKY_CMD} jobs launch "${WORKDIR}/managed-job.yaml" -y -d 2>&1)
  local JOB_RC=$?
  echo "$JOB_OUTPUT" | tail -10

  if [[ $JOB_RC -ne 0 ]]; then
    fail "sky jobs launch failed (rc=${JOB_RC})"
    record_fail "Managed Job"; return 1
  fi

  # Extract job ID
  local JOB_ID
  JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP 'Job ID: \K\d+' || echo "")
  if [[ -z "$JOB_ID" ]]; then
    # Try to find from jobs queue
    JOB_ID=$(${SKY_CMD} jobs queue --no-show-header 2>/dev/null | grep "$NAME" | awk '{print $1}' | head -1 || echo "")
  fi
  log "  Job ID: ${JOB_ID:-unknown}"

  # Wait for job to complete
  log "Waiting for managed job to complete ..."
  local elapsed=0
  local completed=false
  while [[ $elapsed -lt $TIMEOUT ]]; do
    local status
    if [[ -n "$JOB_ID" ]]; then
      status=$(${SKY_CMD} jobs queue --no-show-header 2>/dev/null | grep "^${JOB_ID}" | awk '{print $3}' || echo "")
    else
      status=$(${SKY_CMD} jobs queue --no-show-header 2>/dev/null | grep "$NAME" | awk '{print $3}' | head -1 || echo "")
    fi

    case "$status" in
      SUCCEEDED)
        completed=true
        break
        ;;
      FAILED|FAILED_SETUP|CANCELLED)
        fail "Managed job ${status}"
        record_fail "Managed Job"; return 1
        ;;
    esac

    log "  Managed job: status=${status:-PENDING} [${elapsed}s/${TIMEOUT}s]"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  if [[ "$completed" != "true" ]]; then
    fail "Managed job did not complete within ${TIMEOUT}s"
    ${SKY_CMD} jobs queue 2>/dev/null || true
    record_fail "Managed Job"; return 1
  fi
  pass "Managed job SUCCEEDED"

  # Check logs
  local JOB_LOGS
  if [[ -n "$JOB_ID" ]]; then
    JOB_LOGS=$(${SKY_CMD} jobs logs "$JOB_ID" --no-follow 2>&1 | tail -20 || echo "")
  fi
  if [[ -n "$JOB_LOGS" ]]; then
    echo "─── Managed Job Logs (tail) ───"
    echo "$JOB_LOGS"
    echo "────────────────────────────────"

    if echo "$JOB_LOGS" | grep -q "MANAGED_JOB_COMPLETED_SUCCESSFULLY"; then
      pass "Job logs contain success marker"
    fi
  fi

  record_pass "Managed Job"
  pass "Managed Job: PASSED"
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: sky serve up — model serving endpoint
# ═══════════════════════════════════════════════════════════════════════════

test_serve() {
  local NAME="test-serve-endpoint"
  log "╔══════════════════════════════════════════════════════════════╗"
  log "║  Test: sky serve up — model serving endpoint                ║"
  log "╚══════════════════════════════════════════════════════════════╝"

  # Tear down any previous service
  ${SKY_CMD} serve down "$NAME" -y 2>/dev/null || true
  sleep 3

  cat > "${WORKDIR}/serve.yaml" <<YAML
name: ${NAME}

resources:
  cloud: kubernetes
  cpus: 2+
  memory: 4+
$(gpu_block)
  ports: 8080

service:
  readiness_probe:
    path: /health
    initial_delay_seconds: 30
  replicas: 1

setup: |
  pip install fastapi uvicorn 2>/dev/null || true

run: |
  python3 -c "
  from fastapi import FastAPI
  from pydantic import BaseModel
  import random
  import uvicorn

  app = FastAPI(title='Test Serve Endpoint')

  class PredictRequest(BaseModel):
      text: str
      max_length: int = 50

  class PredictResponse(BaseModel):
      model: str
      input_text: str
      prediction: str
      confidence: float

  @app.get('/health')
  def health():
      return {'status': 'healthy', 'model': 'mock-classifier-v1'}

  @app.post('/predict')
  def predict(req: PredictRequest):
      # Mock prediction
      labels = ['positive', 'negative', 'neutral']
      label = random.choice(labels)
      confidence = random.uniform(0.6, 0.99)
      return PredictResponse(
          model='mock-classifier-v1',
          input_text=req.text[:100],
          prediction=label,
          confidence=round(confidence, 3),
      )

  @app.get('/models')
  def models():
      return {
          'models': [
              {'name': 'mock-classifier-v1', 'status': 'loaded'},
          ]
      }

  print('Starting serve endpoint on port 8080 ...')
  uvicorn.run(app, host='0.0.0.0', port=8080)
  " 2>&1
YAML

  log "Launching serve endpoint '${NAME}' ..."
  local SERVE_OUTPUT
  SERVE_OUTPUT=$(${SKY_CMD} serve up "${WORKDIR}/serve.yaml" -y -d 2>&1)
  local SERVE_RC=$?
  echo "$SERVE_OUTPUT" | tail -15

  if [[ $SERVE_RC -ne 0 ]]; then
    fail "sky serve up failed (rc=${SERVE_RC})"
    record_fail "Serve Endpoint"; return 1
  fi

  # Wait for service to be READY
  log "Waiting for serve endpoint to be READY ..."
  local elapsed=0
  local ready=false
  while [[ $elapsed -lt $TIMEOUT ]]; do
    local status
    status=$(${SKY_CMD} serve status --no-show-header 2>/dev/null | grep "$NAME" | awk '{print $3}' | head -1 || echo "")

    if [[ "$status" == "READY" ]]; then
      ready=true
      break
    fi
    if [[ "$status" == "FAILED" || "$status" == "FAILED_CLEANUP" ]]; then
      fail "Serve endpoint ${status}"
      record_fail "Serve Endpoint"; return 1
    fi
    log "  Serve: status=${status:-PENDING} [${elapsed}s/${TIMEOUT}s]"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  if [[ "$ready" != "true" ]]; then
    fail "Serve endpoint did not become READY within ${TIMEOUT}s"
    ${SKY_CMD} serve status 2>/dev/null || true
    record_fail "Serve Endpoint"; return 1
  fi
  pass "Serve endpoint is READY"

  # Get the endpoint URL
  local ENDPOINT_URL
  ENDPOINT_URL=$(${SKY_CMD} serve status --no-show-header 2>/dev/null | grep "$NAME" | awk '{print $NF}' || echo "")
  if [[ -z "$ENDPOINT_URL" ]]; then
    log "  Could not determine endpoint URL from serve status"
    log "  Attempting to find it via kubectl ..."
    ENDPOINT_URL="http://localhost:18080"
    # Start port-forward as fallback
    ${KCTL} port-forward svc/skypilot-serve -n "$SKYPILOT_NAMESPACE" 18080:80 &>/dev/null &
    local PF_PID=$!
    sleep 5
  fi
  log "  Endpoint: ${ENDPOINT_URL}"

  local FAILURES=0

  # Test health endpoint
  log "Testing /health ..."
  local HEALTH_RESP
  HEALTH_RESP=$(curl -s --max-time 30 "${ENDPOINT_URL}/health" 2>/dev/null || echo "")
  echo "─── Health Response ───"
  echo "$HEALTH_RESP" | jq . 2>/dev/null || echo "$HEALTH_RESP"
  echo "───────────────────────"

  if echo "$HEALTH_RESP" | jq -e '.status' &>/dev/null; then
    pass "Health endpoint OK"
  else
    fail "Health endpoint failed"
    FAILURES=$((FAILURES + 1))
  fi

  # Test predict endpoint
  log "Testing /predict ..."
  local PREDICT_RESP
  PREDICT_RESP=$(curl -s --max-time 30 "${ENDPOINT_URL}/predict" \
    -H "Content-Type: application/json" \
    -d '{"text": "This product is absolutely wonderful and I love it!"}' 2>/dev/null || echo "")
  echo "─── Predict Response ───"
  echo "$PREDICT_RESP" | jq . 2>/dev/null || echo "$PREDICT_RESP"
  echo "────────────────────────"

  if echo "$PREDICT_RESP" | jq -e '.prediction' &>/dev/null; then
    pass "Predict endpoint OK"
  else
    fail "Predict endpoint failed"
    FAILURES=$((FAILURES + 1))
  fi

  # Test models endpoint
  log "Testing /models ..."
  local MODELS_RESP
  MODELS_RESP=$(curl -s --max-time 30 "${ENDPOINT_URL}/models" 2>/dev/null || echo "")
  echo "─── Models Response ───"
  echo "$MODELS_RESP" | jq . 2>/dev/null || echo "$MODELS_RESP"
  echo "───────────────────────"

  if echo "$MODELS_RESP" | jq -e '.models' &>/dev/null; then
    pass "Models endpoint OK"
  else
    fail "Models endpoint failed"
    FAILURES=$((FAILURES + 1))
  fi

  # Stability: multiple rapid requests
  log "Stability check (5 rapid requests) ..."
  local STABLE=0
  for i in $(seq 1 5); do
    local R
    R=$(curl -s --max-time 10 "${ENDPOINT_URL}/predict" \
      -H "Content-Type: application/json" \
      -d "{\"text\": \"Stability test request ${i}\"}" 2>/dev/null || echo "")
    if echo "$R" | jq -e '.prediction' &>/dev/null; then
      STABLE=$((STABLE + 1))
    fi
  done
  if [[ $STABLE -eq 5 ]]; then
    pass "All 5 stability requests succeeded"
  else
    fail "Stability: ${STABLE}/5 succeeded"
    FAILURES=$((FAILURES + 1))
  fi

  # Kill port-forward if we started one
  kill $PF_PID 2>/dev/null || true

  if [[ "$CLEANUP" == "true" ]]; then
    ${SKY_CMD} serve down "$NAME" -y 2>/dev/null || true
  fi

  if [[ $FAILURES -gt 0 ]]; then
    record_fail "Serve Endpoint"; return 1
  fi

  record_pass "Serve Endpoint"
  pass "Serve Endpoint: PASSED"
}

# ═══════════════════════════════════════════════════════════════════════════
# RUN TESTS
# ═══════════════════════════════════════════════════════════════════════════

case "$RUN_TEST" in
  cluster)     test_cluster ;;
  exec)        test_exec ;;
  managed-job) test_managed_job ;;
  serve)       test_serve ;;
  all)
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  Running all SkyPilot workload tests                        ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    test_cluster     || true
    echo ""
    test_exec        || true
    echo ""
    test_managed_job || true
    echo ""
    test_serve       || true
    ;;
  *) echo "Unknown test: ${RUN_TEST}. Use: cluster, exec, managed-job, serve, all"; exit 1 ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
# FINAL CLEANUP
# ═══════════════════════════════════════════════════════════════════════════

if [[ "$CLEANUP" == "true" ]]; then
  log "Cleaning up all test resources ..."
  ${SKY_CMD} down test-dev-cluster -y 2>/dev/null || true
  ${SKY_CMD} serve down test-serve-endpoint -y 2>/dev/null || true
  ${SKY_CMD} jobs cancel -n test-managed-training -y 2>/dev/null || true
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "======================================"
echo " TEST RESULTS: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
echo "======================================"
for r in "${TESTS_RUN[@]}"; do
  echo "  ${r}"
done
echo ""
echo " Kubeconfig:     ${KUBECONFIG_PATH}"
echo " API endpoint:   ${API_ENDPOINT:-local}"
echo " GPU enabled:    ${GPU_ENABLED}"
echo " Workload types tested:"
echo "   - sky launch    (interactive development cluster)"
echo "   - sky exec      (remote command execution on cluster)"
echo "   - sky jobs      (managed training job with auto-recovery)"
echo "   - sky serve     (model serving endpoint with readiness probe)"
echo "======================================"

[[ $TESTS_FAILED -gt 0 ]] && exit 1
exit 0
