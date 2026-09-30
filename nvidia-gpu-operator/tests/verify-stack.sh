#!/usr/bin/env bash
# Verifies a deployed NVIDIA GPU Operator Stack against a live tenant cluster.
#
#   PLATFORM_CONTEXT  kubectl context for the Platform management API
#   TENANT_CONTEXT    kubectl context for the tenant cluster
#   STACK_NAMESPACE   project namespace of the StackInstance, for example p-default
#   STACK_NAME        StackInstance name
set -euo pipefail

: "${PLATFORM_CONTEXT:?set PLATFORM_CONTEXT}"
: "${TENANT_CONTEXT:?set TENANT_CONTEXT}"
: "${STACK_NAMESPACE:?set STACK_NAMESPACE}"
: "${STACK_NAME:?set STACK_NAME}"

for tool in kubectl jq; do
  command -v "$tool" >/dev/null || { echo "cannot run: missing $tool" >&2; exit 2; }
done

failed=0
pass() { echo "ok    $*"; }
fail() { echo "FAIL  $*" >&2; failed=1; }
platform() { kubectl --context "$PLATFORM_CONTEXT" "$@"; }
tenant() { kubectl --context "$TENANT_CONTEXT" "$@"; }

stack=$(platform get stackinstance "$STACK_NAME" -n "$STACK_NAMESPACE" -o json)
phase=$(jq -r '.status.phase // "unknown"' <<<"$stack")
[[ "$phase" == Healthy ]] && pass "StackInstance is Healthy" || fail "StackInstance phase is $phase"
while IFS=$'\t' read -r task task_phase message; do
  [[ "$task_phase" == Healthy ]] && pass "task $task is Healthy" || fail "task $task is $task_phase: $message"
done < <(jq -r '.status.tasks[]? | [.name, .phase, (.message // "")] | @tsv' <<<"$stack")

contract=$(tenant -n gpu-stack get configmap gpu-stack-contract -o json)
[[ "$(jq -r '.data.ready' <<<"$contract")" == true ]] && pass "gpu-stack-contract is ready" \
  || fail "gpu-stack-contract is not marked ready"
min=$(jq -r '.spec.parameters.minGPUs // "1"' <<<"$stack")
observed=$(jq -r '.data.observedCount // "0"' <<<"$contract")
[[ "$observed" -ge "$min" ]] && pass "gate observed $observed allocatable GPUs (minimum $min)" \
  || fail "gate observed $observed allocatable GPUs, wanted $min"

allocatable=$(tenant get nodes -o json | jq '[.items[].status.allocatable["nvidia.com/gpu"] // "0" | tonumber] | add')
[[ "$allocatable" -ge "$min" ]] && pass "$allocatable GPUs allocatable now" || fail "only $allocatable GPUs allocatable now"

if tenant -n gpu-stack logs -l app.kubernetes.io/name=nvidia-gpu-operator-stack-smoke-test --tail=-1 | grep -q 'Test PASSED'; then
  pass "CUDA smoke test reported Test PASSED"
else
  fail "CUDA smoke test log has no Test PASSED"
fi

policy=$(tenant get clusterpolicy cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || true)
[[ "$policy" == ready ]] && pass "ClusterPolicy is ready" || fail "ClusterPolicy state is ${policy:-missing}"

ready=$(tenant -n gpu-operator get daemonset nvidia-dcgm -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
[[ "${ready:-0}" -ge 1 ]] && pass "DCGM host engine is serving on $ready node(s)" || fail "nvidia-dcgm has no ready pods"

not_running=$(tenant -n nvsentinel get pods -o json \
  | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name')
[[ -z "$not_running" ]] && pass "NVSentinel pods are running" || fail "NVSentinel pods not running: $not_running"

exit "$failed"
