# `do-sfo3-jog-ai` A/B demo

Run exactly one implementation at once:

```text
existing StackInstance → teardown → Sveltos POC → teardown → StackInstance
```

Current cluster facts, checked 2026-07-29:

- Existing healthy `StackInstance/default/runai` owns Run:ai releases.
- Sveltos is not installed.
- `runai`, `runai-backend`, `ingress-nginx`, `monitoring`, and `gpu-operator` already contain Stack-owned resources.

Do not apply Sveltos POC until StackInstance deletion completes and Run:ai Helm releases are gone.

## 0. Set context and credentials

```sh
export CTX=do-sfo3-jog-ai
kubectl config use-context "$CTX"
```

Get fresh JFrog token and choose demo admin password from secret manager. Do **not** copy them from current StackInstance, print them, or write them into tracked files.

```sh
read -rs RUNAI_JFROG_TOKEN; export RUNAI_JFROG_TOKEN
read -rs RUNAI_ADMIN_PASSWORD; export RUNAI_ADMIN_PASSWORD
```

## 1. Remove existing Stack demo

Destructive. This removes current Run:ai installation.

```sh
kubectl delete stackinstance runai -n default
kubectl wait --for=delete stackinstance/runai -n default --timeout=45m
```

Require all Run:ai releases absent before continuing:

```sh
helm --kube-context "$CTX" list -A -o json \
  | jq -e 'all(.[]; (.name | startswith("runai-")) | not)'
```

If command fails, stop. Inspect remaining Stack cleanup. Do not force-delete finalizers or install Sveltos over remaining releases.

## 2. Install self-managed Sveltos

This POC uses same cluster as management and target. `agent.managementCluster=true` enables local-agent mode. Chart version pinned for repeatability; telemetry disabled.

```sh
helm upgrade --install projectsveltos projectsveltos/projectsveltos \
  --version 1.12.7 \
  --namespace projectsveltos --create-namespace \
  --set agent.managementCluster=true \
  --set telemetry.disabled=true \
  --wait --timeout 10m
kubectl -n projectsveltos get pods
```

Register this cluster as its own managed `SveltosCluster`. Token lasts four hours, enough for one demo. Temp kubeconfig has mode `0600` and is deleted on shell exit.

```sh
kubectl -n projectsveltos create serviceaccount runai-sveltos-demo
kubectl create clusterrolebinding runai-sveltos-demo \
  --clusterrole=cluster-admin \
  --serviceaccount=projectsveltos:runai-sveltos-demo

umask 077
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
ca=$(kubectl get configmap kube-root-ca.crt -n default -o jsonpath='{.data.ca\.crt}')
token=$(kubectl -n projectsveltos create token runai-sveltos-demo --duration=4h)
kubectl config --kubeconfig="$tmp" set-cluster self --server=https://kubernetes.default.svc --certificate-authority=<(printf '%s' "$ca") --embed-certs=true
kubectl config --kubeconfig="$tmp" set-credentials runai-sveltos-demo --token="$token"
kubectl config --kubeconfig="$tmp" set-context self --cluster=self --user=runai-sveltos-demo
kubectl config --kubeconfig="$tmp" use-context self
kubectl -n projectsveltos create secret generic do-sfo3-jog-ai-sveltos-kubeconfig \
  --from-file=kubeconfig="$tmp"
cat <<'EOF' | kubectl apply -f -
apiVersion: lib.projectsveltos.io/v1beta1
kind: SveltosCluster
metadata:
  name: do-sfo3-jog-ai
  namespace: projectsveltos
  labels:
    stacks.loft.sh/runai: "true"
spec:
  kubeconfigName: do-sfo3-jog-ai-sveltos-kubeconfig
  kubeconfigKeyName: kubeconfig
EOF
kubectl -n projectsveltos get sveltoscluster do-sfo3-jog-ai
```

Self-registration and target-local Helm workflow both use `cluster-admin` in this isolated POC. Teardown removes both bindings.

## 3. Create target-only inputs

```sh
kubectl apply -f sveltos/00-target-inputs.example.yaml
for ns in runai runai-backend; do
  kubectl -n "$ns" create secret docker-registry runai-reg-creds \
    --docker-server=https://runai.jfrog.io \
    --docker-username=self-hosted-image-puller-prod \
    --docker-password="$RUNAI_JFROG_TOKEN"
done
kubectl -n runai create secret generic runai-poc-inputs \
  --from-literal=admin-username=admin@run.ai \
  --from-literal=admin-password="$RUNAI_ADMIN_PASSWORD"
```

## 4. Apply and observe Sveltos POC

```sh
kubectl apply -f sveltos/10-management-manifests.yaml
kubectl get clusterprofile
kubectl -n projectsveltos get clustersummary
kubectl -n runai get jobs,pods,secrets,configmaps
kubectl -n runai-backend get pods
kubectl -n runai get runaiconfig
```

Success evidence:

- `runai-bootstrap`, `runai-backend-installer`, `runai-cluster-installer`: `Complete`.
- `runai-backend` and `runai-cluster` Helm releases: `deployed`.
- `RunaiConfig/runai` has `Available=True`, `Reconciled=True`, and `status.operands.agent.ready=true`.
- `runai-cluster-creds` exists only in target namespace `runai`.

## 5. Remove Sveltos POC

```sh
kubectl delete clusterprofile \
  runai-cluster runai-backend runai-fake-gpu runai-prometheus \
  runai-bootstrap runai-ingress runai-foundation
kubectl -n projectsveltos wait --for=delete clustersummary --all --timeout=30m || true
helm --kube-context "$CTX" list -A -o json \
  | jq -e 'all(.[]; (.name | startswith("runai-")) | not)'
```

Only after Run:ai releases are gone, remove POC-owned resources. Do not delete `runai` or `runai-backend` namespaces; Stack test reuses them.

```sh
# Withdraw can orphan already-created Job Pods. POC label selects only these Pods.
kubectl -n runai delete pod -l runai.sveltos.io/poc=true --ignore-not-found
kubectl -n projectsveltos delete configmap \
  runai-sveltos-foundation runai-sveltos-bootstrap \
  runai-sveltos-backend runai-sveltos-cluster --ignore-not-found
kubectl delete sveltoscluster -n projectsveltos do-sfo3-jog-ai --ignore-not-found
kubectl -n projectsveltos delete secret do-sfo3-jog-ai-sveltos-kubeconfig --ignore-not-found
kubectl delete clusterrolebinding runai-sveltos-demo runai-sveltos-workflow --ignore-not-found
kubectl -n projectsveltos delete serviceaccount runai-sveltos-demo --ignore-not-found
kubectl -n runai delete serviceaccount runai-sveltos-workflow --ignore-not-found
kubectl -n runai delete configmap runai-poc-config runai-endpoint --ignore-not-found
kubectl -n runai delete secret runai-poc-inputs runai-reg-creds runai-cluster-creds --ignore-not-found
kubectl -n runai-backend delete secret \
  runai-reg-creds runai-backend-tls runai-ca-cert runai-control-plane-admin --ignore-not-found
# Remove fake-only labels before another implementation owns GPU configuration.
kubectl label nodes -l run.ai/simulated-gpu-node-pool=default \
  run.ai/simulated-gpu-node-pool- --ignore-not-found
helm uninstall projectsveltos -n projectsveltos
```

Helm leaves Sveltos CRDs by design. They do not affect Stack test. Delete them only if no other Sveltos use exists.

## 6. Reapply Stack demo

Use a private StackInstance manifest with same non-secret values and JFrog token from your secret manager. Never reuse generated Run:ai registration credentials.

```sh
kubectl apply -f apps/
kubectl apply -f stacktemplate-fake-gpu-operator.yaml
kubectl apply -f /secure/path/stackinstance.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Healthy stackinstance/runai -n default --timeout=60m
```

Compare Helm releases, `RunaiConfig/runai` conditions, ingress IP/FQDN, and target-only Secrets. Then delete StackInstance and wait for release cleanup again.
