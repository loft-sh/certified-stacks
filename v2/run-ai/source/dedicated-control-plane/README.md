# NVIDIA Run:ai Dedicated Control-Plane Stack

This Stack installs a self-hosted NVIDIA Run:ai control plane and cluster components.

It installs registry credentials, ingress-nginx, TLS, Prometheus, GPU support, control-plane services,
and cluster registration.

The Stack derives a control-plane FQDN from the LoadBalancer IP address with `nip.io`.
Set `domain` to use a domain you control. See [Configure parameters](#configure-parameters).

## Requirements

- A vCluster Platform installation with StackInstance support.
- A Kubernetes cluster that supports `LoadBalancer` Services. Use `ingressProvider: aws` for an AWS hostname.
- A storage class for control-plane persistent volumes.
- A JFrog token that pulls images from `runai.jfrog.io`.
- `kubectl` access to the target Platform cluster.
- Nodes that can pull the Platform job image.

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

The Stack stores and reuses the CA in `runai-internal-ca`.
On upgrade, it reissues the leaf when it no longer covers the FQDN or expires within 30 days.
This preserves trust across upgrades.

An upgrade from a release without `runai-internal-ca` rotates the CA once.
Restart pods that mount `runai-ca-cert` after that upgrade.

### Use a trusted certificate

Set `tlsMode: user-provided`. The step then skips `openssl` and publishes what you supply.

Use an existing Secret in the `runai` namespace with keys `tls.crt`, `tls.key`, and optionally
`ca.crt`. Prefer this method. It keeps private keys out of the StackInstance.

```yaml
parameters:
  tlsMode: user-provided
  userTlsSecretName: my-runai-tls
```

Supply PEM inline when no Secret can exist before the Stack runs. This Stack creates its own
cluster. Inline PEM is usually the only option:

```yaml
parameters:
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
parameters:
  customCAEnabled: "false"
```

`customCAEnabled` controls `global.customCA.enabled` in the control-plane and cluster charts.
REST registration skips verification only during documented self-signed bootstrap.

A `nip.io` FQDN cannot get a publicly trusted certificate. Set the `domain` parameter to a domain you
control (see [Configure parameters](#configure-parameters)) before you supply one.

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

## Configure parameters

Set `runaiRegistryCredentials` and `storageClass` before you apply StackInstance.

`storageClass` has no default. Set it to a storage class on target cluster.

Example parameters:

```yaml
parameters:
  tenant: runai
  runaiRegistryCredentials: "<JFROG_TOKEN>"
  storageClass: "<STORAGE_CLASS>"
  clusterName: runai
```

### Use your own domain

`domain` is optional. An empty value derives `<tenant>.<lb-ip>.nip.io` after ingress-nginx gets a LoadBalancer IP.
When set, the Stack uses this FQDN for TLS SANs, `global.domain`, the API base URL, cluster registration,
and cluster chart URLs.

```yaml
parameters:
  domain: runai.example.com
```

DNS for the domain and `*.` under it must resolve to the ingress-nginx LoadBalancer IP.
The Stack publishes that address as `ingressAddress`. Create DNS records after it exists.
You can also use a pre-provisioned static IP. Use `domain` with `tlsMode: user-provided` for a
publicly trusted certificate. See [TLS](#tls).

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

Set `ingressProvider: aws` on `run-ai-dedicated-control-plane`.
It adds NLB annotations and uses the load-balancer hostname as the FQDN.
Do not apply a separate AWS StackTemplate.

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
