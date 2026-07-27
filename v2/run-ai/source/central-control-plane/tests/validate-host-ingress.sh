#!/usr/bin/env bash
# Validate the Control Plane Cluster prerequisites for central control-plane tenancy, before creating any tenant.
#
# Run against the Control Plane Cluster:
#   ./validate-host-ingress.sh
#   INGRESS_CLASS=nginx TENANT_LABEL=runai.vcluster.com/tenant ./validate-host-ingress.sh
#
# Read-only. It creates and changes nothing.
set -uo pipefail

INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TENANT_LABEL="${TENANT_LABEL:-runai.vcluster.com/tenant}"
GPU_NS="${GPU_NS:-gpu-operator}"
BACKEND_NS="${BACKEND_NS:-runai-backend}"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
warn() { printf 'warn %s\n' "$1"; }

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 2; }

echo "validating Control Plane Cluster prerequisites (ingressClass=$INGRESS_CLASS, tenant label=$TENANT_LABEL)"
echo

# --- ingress -------------------------------------------------------------------------------------

if kubectl get ingressclass "$INGRESS_CLASS" >/dev/null 2>&1; then
  pass "IngressClass $INGRESS_CLASS exists"
else
  fail "IngressClass $INGRESS_CLASS not found; central control-plane tenancy reuses an existing host ingress controller"
fi

lb_ips=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.status.loadBalancer.ingress[0].ip}{"\n"}{end}' 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u)
if [ -n "$lb_ips" ]; then
  pass "LoadBalancer IPv4 address(es) available for hostIngressAddress:"
  printf '       %s\n' $lb_ips
else
  fail "no LoadBalancer Service with an IPv4 address; hostIngressAddress has nothing to point at"
fi

# --- GPU stack -----------------------------------------------------------------------------------

if kubectl get runtimeclass nvidia >/dev/null 2>&1; then
  pass "RuntimeClass nvidia exists (tenants sync it in via sync.fromHost.runtimeClasses)"
else
  fail "RuntimeClass nvidia not found; run:ai GPU workloads select it by name"
fi

if kubectl get ns "$GPU_NS" >/dev/null 2>&1; then
  not_ready=$(kubectl -n "$GPU_NS" get pods --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed"' | wc -l | tr -d ' ')
  if [ "$not_ready" = "0" ]; then
    pass "GPU Operator pods in $GPU_NS are Running or Completed"
  else
    fail "$not_ready pod(s) in $GPU_NS are not ready"
  fi
else
  fail "namespace $GPU_NS not found; install the shared host foundation first"
fi

gpu_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | awk -F'\t' '$2 != "" && $2 != "0"')
if [ -n "$gpu_nodes" ]; then
  pass "node(s) advertising nvidia.com/gpu:"
  printf '       %s\n' "$gpu_nodes"
else
  fail "no node advertises nvidia.com/gpu allocatable capacity"
fi

# --- shared control plane ------------------------------------------------------------------------

if kubectl -n "$BACKEND_NS" get secret runai-control-plane-admin >/dev/null 2>&1; then
  pass "$BACKEND_NS/runai-control-plane-admin exists (registration reads it in-namespace)"
else
  fail "$BACKEND_NS/runai-control-plane-admin not found; install the shared host foundation first"
fi

# --- tenant node partitioning --------------------------------------------------------------------
# A node may belong to at most one tenant. Each tenant runs its own scheduler, so two tenants that
# can see the same node both claim its full GPU capacity with nothing arbitrating.

labelled=$(kubectl get nodes -o jsonpath="{range .items[*]}{.metadata.name}{\"\t\"}{.metadata.labels['${TENANT_LABEL//./\\.}']}{\"\n\"}{end}" 2>/dev/null)
assigned=$(printf '%s\n' "$labelled" | awk -F'\t' '$2 != ""')
if [ -n "$assigned" ]; then
  pass "tenant node assignments:"
  printf '%s\n' "$assigned" | awk -F'\t' '{n[$2] = n[$2] " " $1} END {for (t in n) printf "       %s ->%s\n", t, n[t]}'
  echo "       Each of these values may be used by at most ONE tenant cluster. Two tenants sharing"
  echo "       a value both claim the same nodes' full GPU capacity, with nothing arbitrating."
  echo "       That is a tenant-configuration property and cannot be checked from node labels;"
  echo "       cross-check nodeSelectorValue across your tenant clusters."
else
  warn "no node carries $TENANT_LABEL; a tenant with no matching nodes syncs zero nodes and cannot schedule"
fi

unlabelled_gpu=$(printf '%s\n' "$gpu_nodes" | awk -F'\t' '{print $1}' | while read -r n; do
  [ -n "$n" ] || continue
  v=$(printf '%s\n' "$assigned" | awk -F'\t' -v n="$n" '$1 == n {print $2}')
  [ -z "$v" ] && printf '%s ' "$n"
done)
[ -z "$unlabelled_gpu" ] || warn "GPU node(s) with no tenant label, invisible to every tenant: $unlabelled_gpu"

echo
if [ "$failures" -eq 0 ]; then
  echo "Control Plane Cluster prerequisites satisfied."
  exit 0
fi
echo "$failures check(s) failed." >&2
exit 1
