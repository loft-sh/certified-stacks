# run:ai Dedicated Control-Plane Stack

This Stack installs a run:ai self-hosted control plane and cluster components.

It installs registry credentials, ingress-nginx, TLS, Prometheus, GPU support, control-plane services, cluster registration, and cluster components.

The Stack uses `nip.io` to make a control-plane FQDN from LoadBalancer IP address. Set the
optional `domain` input to use a domain you control instead (see
[Configure inputs](#configure-inputs)).

## Requirements

- A vCluster Platform installation with StackInstance support.
- A Kubernetes cluster that supports `LoadBalancer` Services. Set `ingressProvider: aws` when
  AWS reports a hostname.
- A storage class for control-plane persistent volumes.
- A JFrog token that can pull images from `runai.jfrog.io`.
- `kubectl` access to target platform cluster.
- Nodes able to pull Platform-provided job image.

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

Supply PEM inline when no Secret can exist before the Stack runs. This Stack creates its own
cluster, so inline is usually the only option here:

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

Omit `userCaCert` when the chain is publicly trusted, and set:

```yaml
inputs:
  customCAEnabled: "false"
```

`customCAEnabled` controls `global.customCA.enabled` in the control-plane and cluster charts.
REST registration skips verification only during documented self-signed bootstrap.

A `nip.io` FQDN cannot get a publicly trusted certificate. Set the `domain` input to a domain you
control (see [Configure inputs](#configure-inputs)) before you supply one.

### Verify

```bash
bash tests/verify-certs.sh
TLS_MODE=user-provided bash tests/verify-certs.sh
```

## Job image

Bootstrap and REST-operation Jobs use Platform-provided `__image__`. It must include `openssl`,
`kubectl`, `jq`, `curl`, and `sh`.

## Files

| File | Purpose |
| --- | --- |
| `apps/` | Apps used by Stack steps. |
| `stacktemplate.yaml` | StackTemplate with NVIDIA GPU Operator. |
| `example/stackinstance-from-template.yaml` | Example StackInstance for NVIDIA GPU Operator template. |
| `tests/verify-certs.sh` | Checks the published TLS material against a live cluster. |

Steps `authtoken`, `clusterreg`, and `clustercreds` use `restful-operation`.

This repository provides this App in `apps/restful-operation.yaml`.

## Configure inputs

Set `runaiRegistryCredentials` and `storageClass` before you apply StackInstance.

`storageClass` has no default. Set it to a storage class on target cluster.

Example inputs:

```yaml
inputs:
  tenant: runai
  runaiRegistryCredentials: "<JFROG_TOKEN>"
  storageClass: "<STORAGE_CLASS>"
  clusterName: runai
```

### Use your own domain

`domain` is optional. When empty, the Stack derives `<tenant>.<lb-ip>.nip.io` after the
ingress-nginx LoadBalancer IP is assigned. When set, the Stack uses it as the control-plane FQDN
everywhere: the TLS certificate SANs, `global.domain`, the API base URL, the run:ai cluster
registration, and the cluster chart URLs.

```yaml
inputs:
  domain: runai.example.com
```

DNS for the domain and `*.` under it must resolve to the ingress-nginx LoadBalancer IP. The Stack
publishes that address as the `ingressAddress` output; create the DNS records once it exists, or use a
pre-provisioned static IP. Pair `domain` with `tlsMode: user-provided` for a publicly trusted
certificate (see [TLS](#tls)).

## Install with NVIDIA GPU Operator

1. Set `runaiRegistryCredentials` and `storageClass` in `example/stackinstance-from-template.yaml`.
2. Configure `nvidia` RuntimeClass and GPU node labels.
3. Apply Apps and the StackTemplate.
4. Apply StackInstance.

```bash
kubectl apply -f apps/
kubectl apply -f stacktemplate.yaml
kubectl apply -f example/stackinstance-from-template.yaml
```

Use GPU nodes for this template.

## AWS / EKS

Set `ingressProvider: aws` on the same `run-ai-dedicated-control-plane` StackTemplate. It adds NLB annotations and
uses the load-balancer hostname as the derived FQDN. Do not apply a separate AWS StackTemplate.

### Cluster prerequisites

| Requirement | Why |
| --- | --- |
| AWS Load Balancer Controller | Reads NLB annotations. |
| A default StorageClass on `ebs.csi.aws.com` | EKS `gp2` uses a removed in-tree provisioner. |
| GPU node group with an accelerated AMI | Provides NVIDIA driver and container toolkit. |
| `nvidia` RuntimeClass | Required by workloads that select it. |

## Check status

```bash
kubectl get stackinstance runai -n p-default \
  -o jsonpath='{range .status.steps[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

The ingress step must get a LoadBalancer IP address before dependent steps start.

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
