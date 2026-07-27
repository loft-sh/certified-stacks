#!/usr/bin/env bash
# Verify the AWS-specific assumptions of `stacktemplate-aws.yaml` against a live EKS cluster.
#
# Run against the cluster the Stack is installed on:
#   ./validate-aws-ingress.sh
#   SKIP_HAIRPIN=1 ./validate-aws-ingress.sh     # skip the pod-to-load-balancer check
#
# FQDN is read from the endpoint ConfigMap, so it always matches what the Stack derived.
# Override with FQDN=... when testing a control plane published under a different name.
set -uo pipefail

INGRESS_NS="${INGRESS_NS:-ingress-nginx}"
CLUSTER_NS="${CLUSTER_NS:-runai}"
LBC_NS="${LBC_NS:-kube-system}"
SVC="${SVC:-runai-ingress-ingress-nginx-controller}"
SKIP_HAIRPIN="${SKIP_HAIRPIN:-}"
# Same digest the Stack pins for its hook Jobs, so the probe reuses an image the nodes have.
PROBE_IMAGE="${PROBE_IMAGE:-docker.io/bitnami/kubectl@sha256:c62a62db80e777acdee87f76bc6f06a95239ad2ff210bf78f585e39e33da98e2}"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
note() { printf 'note %s\n' "$1"; }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 2; }

# go-template with `index` sidesteps jsonpath's dot-escaping rules for keys like
# `service.beta.kubernetes.io/aws-load-balancer-type`.
svc_annotation() {
  kubectl -n "$INGRESS_NS" get svc "$SVC" \
    -o go-template="{{ if .metadata.annotations }}{{ index .metadata.annotations \"$1\" }}{{ end }}" 2>/dev/null
}

kubectl -n "$INGRESS_NS" get svc "$SVC" >/dev/null 2>&1 \
  || { echo "Service $INGRESS_NS/$SVC not found; set SVC=... to the ingress controller Service" >&2; exit 2; }

LB_HOSTNAME=$(kubectl -n "$INGRESS_NS" get svc "$SVC" \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
LB_IP=$(kubectl -n "$INGRESS_NS" get svc "$SVC" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
FQDN="${FQDN:-$(kubectl -n "$CLUSTER_NS" get configmap runai-control-plane-endpoint \
  -o jsonpath='{.data.fqdn}' 2>/dev/null)}"

echo "validating AWS ingress for $INGRESS_NS/$SVC"
echo

# --- Load balancer -----------------------------------------------------------------------

check "AWS Load Balancer Controller is available in $LBC_NS" \
  "[ \"\$(kubectl -n $LBC_NS get deploy aws-load-balancer-controller -o jsonpath='{.status.availableReplicas}')\" -ge 1 ]"

if [ -n "$LB_HOSTNAME" ]; then
  pass "Service status publishes a hostname ($LB_HOSTNAME)"
else
  # The AWS template's ingress output reads .hostname, so an empty one stalls the whole Stack.
  fail "Service status publishes a hostname"
fi
if [ -n "$LB_IP" ]; then
  note "Service status also carries ip $LB_IP; the generic template would work here too"
else
  note "Service status has no ip, which is why the AWS template reads .hostname"
fi

check "annotation aws-load-balancer-type is external" \
  "[ \"\$(svc_annotation service.beta.kubernetes.io/aws-load-balancer-type)\" = external ]"
check "annotation aws-load-balancer-nlb-target-type is ip" \
  "[ \"\$(svc_annotation service.beta.kubernetes.io/aws-load-balancer-nlb-target-type)\" = ip ]"
check "annotation aws-load-balancer-scheme is internet-facing" \
  "[ \"\$(svc_annotation service.beta.kubernetes.io/aws-load-balancer-scheme)\" = internet-facing ]"
check "annotation aws-load-balancer-cross-zone-load-balancing-enabled is true" \
  "[ \"\$(svc_annotation service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled)\" = true ]"
# The one annotation that is a functional requirement rather than a preference: without it the
# Stack's own hook Jobs and the run:ai cluster agent cannot reach the FQDN from inside the cluster.
check "annotation aws-load-balancer-target-group-attributes disables preserve_client_ip" \
  "svc_annotation service.beta.kubernetes.io/aws-load-balancer-target-group-attributes \
    | grep -q 'preserve_client_ip.enabled=false'"

# --- FQDN --------------------------------------------------------------------------------

if [ -n "$FQDN" ]; then
  pass "endpoint ConfigMap publishes fqdn ($FQDN)"
  if [ -n "$LB_HOSTNAME" ] && [ "$FQDN" = "$LB_HOSTNAME" ]; then
    pass "fqdn is the load balancer hostname"
  else
    # Expected when the `domain` input is set; DNS then has to point at the load balancer.
    note "fqdn is not the load balancer hostname, so the domain input is presumably set"
    check "fqdn resolves" "getent hosts $FQDN || host $FQDN || nslookup $FQDN"
  fi
else
  fail "endpoint ConfigMap publishes fqdn"
fi

# --- In-cluster reachability (the hairpin case) -------------------------------------------

if [ -z "$SKIP_HAIRPIN" ] && [ -n "$FQDN" ]; then
  node=$(kubectl -n "$INGRESS_NS" get pods -l app.kubernetes.io/component=controller \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  if [ -n "$node" ]; then
    # Pinned to a node that runs an ingress-nginx pod: that is the routing AWS drops when client
    # IP preservation is on, so an unpinned probe can pass while the Stack still fails.
    code=$(kubectl run "runai-hairpin-probe-$$" --image="$PROBE_IMAGE" --restart=Never --rm -i \
      --quiet --overrides="{\"spec\":{\"nodeName\":\"$node\"}}" --command -- \
      sh -c "curl -sk --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' https://$FQDN/ || true" \
      2>/dev/null | tr -d '[:space:]')
    if [ -n "$code" ] && [ "$code" != 000 ]; then
      pass "pod on $node reaches https://$FQDN/ (HTTP $code)"
    else
      fail "pod on $node reaches https://$FQDN/ (got '${code:-no response}'; check preserve_client_ip)"
    fi
  else
    fail "found an ingress-nginx controller pod to pin the probe to"
  fi
fi

# --- Storage -----------------------------------------------------------------------------

default_sc=$(kubectl get storageclass -o go-template='{{ range .items }}{{ if .metadata.annotations }}{{ if eq (index .metadata.annotations "storageclass.kubernetes.io/is-default-class") "true" }}{{ .metadata.name }}{{ "\n" }}{{ end }}{{ end }}{{ end }}' 2>/dev/null | head -1)
if [ -n "$default_sc" ]; then
  pass "default StorageClass is $default_sc"
  # EKS ships gp2 on kubernetes.io/aws-ebs, which has no provisioner left, so PVCs never bind.
  check "default StorageClass $default_sc uses ebs.csi.aws.com" \
    "[ \"\$(kubectl get storageclass $default_sc -o jsonpath='{.provisioner}')\" = ebs.csi.aws.com ]"
else
  fail "a default StorageClass exists"
fi

# --- GPU nodes (skipped when there are none) ----------------------------------------------

gpu_node=$(kubectl get nodes -o go-template='{{ range .items }}{{ if index .status.allocatable "nvidia.com/gpu" }}{{ .metadata.name }}{{ "\n" }}{{ end }}{{ end }}' 2>/dev/null | head -1)
if [ -n "$gpu_node" ]; then
  check "$gpu_node allocates nvidia.com/gpu" \
    "[ \"\$(kubectl get node $gpu_node -o go-template='{{ index .status.allocatable \"nvidia.com/gpu\" }}')\" != 0 ]"
  # A tenant cluster's scheduler does not tolerate this taint, so GPU workloads would never place.
  check "$gpu_node has no nvidia.com/gpu taint" \
    "! kubectl get node $gpu_node -o jsonpath='{.spec.taints[*].key}' | grep -q 'nvidia.com/gpu'"
else
  note "no node advertises nvidia.com/gpu; skipping GPU checks"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
