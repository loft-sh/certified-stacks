# run:ai soft-multitenancy Stack

This Stack installs a run:ai self-hosted control plane and cluster components.

It installs registry credentials, TLS, Prometheus, GPU support, control-plane services, cluster registration, and cluster components. It reuses existing host ingress-nginx.

The Stack uses `nip.io` to make a control-plane FQDN from existing host ingress LoadBalancer IPv4 address.

## Requirements

- A Loft Platform installation with StackInstance support.
- Existing host ingress-nginx with IngressClass `nginx` and a LoadBalancer IPv4 address.
- A storage class for control-plane persistent volumes.
- A JFrog token that can pull images from `runai.jfrog.io`.
- `kubectl` access to target platform cluster.
- Nodes able to pull the hook image (see [Hook image](#hook-image)). Point `hookImage` at a mirror, or add a pull secret, if your registry needs one.

## TLS

By default the `bootstrap` step issues a self-signed CA and leaf certificate inside the cluster.
Use a trusted certificate before production use.

Default certificate:

| Property | Value |
| --- | --- |
| CA key | RSA 4096, valid 3650 days |
| Leaf key | RSA 2048, valid 825 days |
| Leaf SANs | `<fqdn>` and `*.<fqdn>` |

The step writes these Secrets:

| Secret | Namespace | Contents |
| --- | --- | --- |
| `runai-backend-tls` | `runai-backend` | Served certificate and key. |
| `runai-ca-cert` | `runai-backend`, `runai` | CA as `runai-ca.pem`, for `global.customCA`. |
| `runai-internal-ca` | `runai-backend` | CA certificate and key, for reuse. |

The CA is stored in `runai-internal-ca` and reused. An upgrade reissues the leaf only when it no
longer covers the FQDN or expires within 30 days, so trust survives upgrades.

Upgrading from a release before `runai-internal-ca` existed rotates the CA once. Restart pods that
mount `runai-ca-cert` after that upgrade.

### Use a trusted certificate

Set `tlsMode: user-provided`. The step then skips `openssl` and publishes what you supply.

Point at an existing Secret in the `runai` namespace with keys `tls.crt`, `tls.key`, and optionally
`ca.crt`. Prefer this form. It keeps private keys out of the StackInstance.

```yaml
inputs:
  tlsMode: user-provided
  userTlsSecretName: my-runai-tls
```

Supply PEM inline when no Secret can exist before the Stack runs:

```yaml
inputs:
  tlsMode: user-provided
  userTlsCert: |
    -----BEGIN CERTIFICATE-----
    ...
  userTlsKey: |
    -----BEGIN PRIVATE KEY-----
    ...
```

Omit `userCaCert` when the chain is publicly trusted, and set both of these:

```yaml
inputs:
  customCAEnabled: "false"
  skipTLSVerify: "false"
```

`customCAEnabled` controls `global.customCA.enabled` in the control-plane and cluster charts.
`skipTLSVerify` controls whether the `authtoken`, `clusterreg`, and `clustercreds` steps verify the
control-plane certificate. Both default to the self-signed behaviour.

A `nip.io` FQDN cannot get a publicly trusted certificate. Serve the control plane on a domain you
control before you supply one.

### Verify

```bash
bash tests/verify-certs.sh
TLS_MODE=user-provided bash tests/verify-certs.sh
```

## Hook image

The `bootstrap` step and the three `restful-operation` steps run short-lived Jobs. They share one
image, set by the `hookImage` input:

```
docker.io/bitnami/kubectl@sha256:c62a62db80e777acdee87f76bc6f06a95239ad2ff210bf78f585e39e33da98e2
```

The image must provide `openssl`, `kubectl`, `jq`, `curl` and `sh`. Each Job checks for its tools
first and fails with a clear message rather than part-way through, so a wrong image is obvious.

It is pinned by digest, not by tag, for two reasons. The upstream repository publishes only a
`latest` tag, and a `latest` or tagless reference makes Kubernetes default `imagePullPolicy` to
`Always`, which re-pulls on every Job. A digest reference defaults to `IfNotPresent`. Digest
resolved 2026-08-06; re-resolve it if you bump the pin.

### Use a different image

Patch a running StackInstance:

```bash
kubectl patch stackinstance runai -n p-default --type=merge \
  -p '{"spec":{"inputs":{"hookImage":"<image>"}}}'
```

Or set `hookImage` in the StackInstance before you apply it.

### Match the vCluster Platform image you already run

The platform image carries all the required tools, so it is a valid choice, and nodes that already
run the platform or its agent have it cached. It is not the default because it is roughly six times
larger, and the image cache is per node, so a Job scheduled elsewhere pays a full pull.

Read the image off the platform Deployment. This needs access to the cluster the platform runs in:

```bash
PLATFORM_IMAGE=$(kubectl -n vcluster-platform get deploy loft \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="manager")].image}')
echo "$PLATFORM_IMAGE"

kubectl patch stackinstance runai -n p-default --type=merge \
  -p "{\"spec\":{\"inputs\":{\"hookImage\":\"$PLATFORM_IMAGE\"}}}"
```

The Deployment is always named `loft` and the container is always `manager`, but the namespace
varies by install: `loft`, `vcluster-platform`, `vcluster-agent` for multi-region, or a custom
management namespace. Find it with:

```bash
kubectl get deploy -A -l app=loft
```

### Change the default for everything you apply

Re-render the manifests instead of editing each App:

```bash
./v2/run-ai/render.sh --image "$PLATFORM_IMAGE"
git diff --stat                        # image lines only
kubectl apply -f apps/
kubectl apply -f stacktemplate.yaml
git checkout -- v2/run-ai/hard-multitenancy v2/run-ai/soft-multitenancy
```

`--image` writes in place, so `./v2/run-ai/render.sh --check` reports stale until you re-run a plain
`./v2/run-ai/render.sh`. Restore with the `git checkout` above.

## Files

| File | Purpose |
| --- | --- |
| `apps/` | Apps used by Stack steps. |
| `stacktemplate.yaml` | StackTemplate with NVIDIA GPU Operator. |
| `stacktemplate-fake-gpu-operator.yaml` | StackTemplate with simulated GPUs. |
| `example/stackinstance-from-template.yaml` | Example StackInstance for NVIDIA GPU Operator template. |
| `tests/verify-certs.sh` | Checks the published TLS material against a live cluster. |

Steps `authtoken`, `clusterreg`, and `clustercreds` use `restful-operation`.

Loft Platform includes this App. This repository does not include it.

## Configure inputs

Set `runaiRegistryCredentials`, `storageClass`, and `hostIngressAddress` before you apply StackInstance.

`storageClass` has no default. Set it to a storage class on target cluster. Set `hostIngressAddress` to existing host ingress-nginx LoadBalancer IPv4 address.

Example inputs:

```yaml
inputs:
  tenant: runai
  runaiRegistryCredentials: "<JFROG_TOKEN>"
  storageClass: "<STORAGE_CLASS>"
  hostIngressAddress: "<HOST_NGINX_LOADBALANCER_IPV4>"
  clusterName: runai
```

Keep `runaiVersion` equal to chart versions in these Apps:

- `apps/06-control-plane.yaml`
- `apps/10-cluster.yaml`

Control-plane chart source:

```text
https://runai.jfrog.io/artifactory/cp-charts-prod
```

## Install with NVIDIA GPU Operator

1. Set `runaiRegistryCredentials`, `storageClass`, and `hostIngressAddress` in `example/stackinstance-from-template.yaml`.
2. Configure `nvidia` RuntimeClass and GPU node labels.
3. Apply Apps and the StackTemplate.
4. Apply StackInstance.

```bash
kubectl apply -f apps/
kubectl apply -f stacktemplate.yaml
kubectl apply -f example/stackinstance-from-template.yaml
```

Use GPU nodes for this template.

## Install with simulated GPUs

1. Copy `example/stackinstance-from-template.yaml`.
2. Set `runaiRegistryCredentials`, `storageClass`, and `hostIngressAddress` in copied file.
3. Set `spec.templateRef.name` to `runai-selfhosted-nipio-fake-gpu`.
4. Apply Apps, the fake-GPU StackTemplate, and StackInstance.

```bash
kubectl apply -f apps/
kubectl apply -f stacktemplate-fake-gpu-operator.yaml
kubectl apply -f <STACKINSTANCE_FILE>
```

Apply one StackTemplate and one StackInstance.

## Check status

```bash
kubectl get stackinstance runai -n p-default \
  -o jsonpath='{range .status.steps[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

Existing host ingress must route synced tenant Ingress resources before dependent services become reachable.

## Release names

Keep StackInstance name `runai`.

Keep step names `backend` and `cluster`.

The control-plane chart requires release name `runai-backend`.

The cluster chart requires release name `runai-cluster`.

The Stack derives these release names from StackInstance and step names.

## Remove Stack

Delete StackInstance first.

```bash
kubectl delete stackinstance runai -n p-default
```

The Stack deletes Helm releases and deregisters cluster.

It does not delete namespaces or Prometheus release PVCs.

Check remaining resources before you delete Apps.
