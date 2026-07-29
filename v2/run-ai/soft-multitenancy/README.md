# run:ai soft-multitenancy Stack

This Stack installs a run:ai self-hosted control plane and cluster components.

It installs registry credentials, ingress-nginx, TLS, Prometheus, GPU support, control-plane services, cluster registration, and cluster components.

The Stack uses `nip.io` to make a control-plane FQDN from LoadBalancer IP address.

## Sveltos POC

`sveltos/` contains manifest-first Sveltos replacement POC. It maps Stack Apps to ClusterProfiles and uses target-local Jobs for Run:ai dynamic REST workflow. See [`sveltos/README.md`](sveltos/README.md).

## Requirements

- A Loft Platform installation with StackInstance support.
- A Kubernetes cluster that supports `LoadBalancer` Services.
- A storage class for control-plane persistent volumes.
- A JFrog token that can pull images from `runai.jfrog.io`.
- `kubectl` access to target platform cluster.

The Stack creates a self-signed certificate. Use a trusted certificate before production use.

## Files

| File | Purpose |
| --- | --- |
| `apps/` | Apps used by Stack steps. |
| `stacktemplate.yaml` | StackTemplate with NVIDIA GPU Operator. |
| `stacktemplate-fake-gpu-operator.yaml` | StackTemplate with simulated GPUs. |
| `example/stackinstance-from-template.yaml` | Example StackInstance for NVIDIA GPU Operator template. |

Steps `authtoken`, `clusterreg`, and `clustercreds` use `restful-operation`.

Loft Platform includes this App. This repository does not include it.

## Configure inputs

Set `dockerPassword` and `storageClass` before you apply StackInstance.

`storageClass` has no default. Set it to a storage class on target cluster.

Example inputs:

```yaml
inputs:
  tenant: runai
  dockerPassword: "<JFROG_TOKEN>"
  storageClass: "<STORAGE_CLASS>"
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

1. Set `dockerPassword` and `storageClass` in `example/stackinstance-from-template.yaml`.
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
2. Set `dockerPassword` and `storageClass` in copied file.
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
