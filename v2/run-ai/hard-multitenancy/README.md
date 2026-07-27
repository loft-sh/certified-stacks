# run:ai hard-multitenancy Stack

This Stack installs a run:ai self-hosted control plane and cluster components.

It installs registry credentials, ingress-nginx, TLS, Prometheus, GPU support, control-plane services, cluster registration, and cluster components.

The Stack uses `nip.io` to make a control-plane FQDN from LoadBalancer IP address. Set the
optional `domain` input to use a domain you control instead (see
[Configure inputs](#configure-inputs)).

## Requirements

- A Loft Platform installation with StackInstance support.
- A Kubernetes cluster that supports `LoadBalancer` Services and reports an IP for them. AWS
  reports a hostname instead, so EKS needs the AWS templates; see [AWS / EKS](#aws--eks).
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

Omit `userCaCert` when the chain is publicly trusted, and set both of these:

```yaml
inputs:
  customCAEnabled: "false"
  skipTLSVerify: "false"
```

`customCAEnabled` controls `global.customCA.enabled` in the control-plane and cluster charts.
`skipTLSVerify` controls whether the `authtoken`, `clusterreg`, and `clustercreds` steps verify the
control-plane certificate. Both default to the self-signed behaviour.

A `nip.io` FQDN cannot get a publicly trusted certificate. Set the `domain` input to a domain you
control (see [Configure inputs](#configure-inputs)) before you supply one.

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
| `stacktemplate-aws.yaml` | AWS/EKS StackTemplate with NVIDIA GPU Operator. See [AWS / EKS](#aws--eks). |
| `example/stackinstance-from-template.yaml` | Example StackInstance for NVIDIA GPU Operator template. |
| `example/stackinstance-aws.yaml` | Example StackInstance for the AWS/EKS template. |
| `example/cronjob-runai-custom-link.yaml` | Optional CronJob that backfills the `RunAI_UI` custom link on nip.io tenants. |
| `tests/verify-certs.sh` | Checks the published TLS material against a live cluster. |
| `tests/validate-aws-ingress.sh` | Checks the AWS ingress, FQDN, storage and GPU assumptions against a live EKS cluster. |

Steps `authtoken`, `clusterreg`, and `clustercreds` use `restful-operation`.

Loft Platform includes this App. This repository does not include it.

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
publishes that IP as the `ingressIP` output; create the DNS records once the IP exists, or use a
pre-provisioned static IP. Pair `domain` with `tlsMode: user-provided` for a publicly trusted
certificate (see [TLS](#tls)).

A `RunAI_UI` custom link (`loft.sh/custom-links`) on the VirtualClusterInstance makes the platform
UI link to that tenant's run:ai control plane. The vCluster templates cannot add it at creation
time, whether or not `domain` is set: the annotation is rendered before the Stack runs, and with no
`domain` the FQDN is not known until the ingress LoadBalancer exists.

`example/cronjob-runai-custom-link.yaml` fills the link in afterwards. Apply it by hand on the
cluster that runs vCluster Platform, then label the instances that should get a link:

```bash
kubectl apply -f example/cronjob-runai-custom-link.yaml
kubectl -n p-<project> label virtualclusterinstance <name> loft.sh/stacks-sync=true
```

Every five minutes it looks at labelled instances that have no `loft.sh/custom-links` annotation,
reads the tenant's `vc-<name>` kubeconfig Secret, finds the run:ai control-plane Ingress inside that
tenant, and sets the annotation to `RunAI_UI=https://<host>` using any non-wildcard host that
Ingress serves. That covers a derived nip.io address, the ingress NLB hostname on AWS, and an
explicit `domain` alike. Tenants that are asleep, still installing, unreachable, or placed on a
connected cluster are skipped and retried on the next run. Nothing in the Stack depends on the
CronJob; delete it once the links exist.

The domain must resolve from inside the tenant. The `authtoken`, `clusterreg`, and `clustercreds`
steps and the run:ai cluster components all call the control plane over this name. A made-up
domain fails at `authtoken` with `curl: (6) Could not resolve host`, reported on the Stack as
`BackoffLimitExceeded`. Do not use a `.local` name: RFC 6762 reserves it for mDNS, so it cannot be
delegated in ordinary DNS.

#### In-cluster domain for testing

Set `domain` to the ingress controller's own Service DNS name to get a domain that always resolves
without any DNS records:

```yaml
inputs:
  domain: <ingressControllerServiceName>.ingress-nginx.svc.cluster.local
```

`ingressControllerServiceName` already carries the tenant prefix, so for a tenant named `lyka`
created from the example this is
`lyka-runai-ingress-ingress-nginx-controller.ingress-nginx.svc.cluster.local`.

Use this for testing only. The name resolves inside the tenant, so the Stack completes and the
run:ai cluster registers, but nothing outside the cluster can reach the control plane. Use
`vcluster connect` or a port-forward to open the UI, and expect the `RunAI_UI` custom link to be
unusable from a browser.

Keep `runaiVersion` equal to chart versions in these Apps:

- `apps/06-control-plane.yaml`
- `apps/10-cluster.yaml`

Control-plane chart source:

```text
https://runai.jfrog.io/artifactory/cp-charts-prod
```

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

## Install with simulated GPUs

1. Copy `example/stackinstance-from-template.yaml`.
2. Set `runaiRegistryCredentials` and `storageClass` in copied file.
3. Set `spec.templateRef.name` to `runai-selfhosted-nipio-fake-gpu`.
4. Apply Apps, the fake-GPU StackTemplate, and StackInstance.

```bash
kubectl apply -f apps/
kubectl apply -f stacktemplate-fake-gpu-operator.yaml
kubectl apply -f <STACKINSTANCE_FILE>
```

Apply one StackTemplate and one StackInstance.

## AWS / EKS

The generic templates do not work on EKS. Their `ingress` step reads
`.status.loadBalancer.ingress[0].ip` from the controller Service, and AWS load balancers publish a
hostname there and leave `ip` empty. The step produces no value, the required
`loadBalancerAddress` parameter is empty, and no derived FQDN is valid, so nothing after the
ingress step runs.

Use `stacktemplate-aws.yaml` instead. It reads `.hostname` and uses the load balancer's own hostname
as the control-plane FQDN, so there is no `tenant` input and no nip.io.

It is the only AWS template; there is no simulated-GPU variant. On a cluster with no GPU nodes it
still installs — the GPU operator's DaemonSets are gated on the NVIDIA PCI node label and so have
nothing to schedule — but the cluster advertises no `nvidia.com/gpu`, so run:ai has nowhere to place
GPU workloads. Bring real GPU nodes, or use a GKE/DOKS cluster with
`stacktemplate-fake-gpu-operator.yaml`.

### Cluster prerequisites

| Requirement | Why |
| --- | --- |
| AWS Load Balancer Controller | The AWS ingress step sets NLB annotations that only that controller reads. |
| A default StorageClass on `ebs.csi.aws.com` | EKS ships `gp2` bound to the removed in-tree provisioner, so control-plane PVCs never bind. Create a `gp3` class, make it default, and pass `storageClass: gp3`. |
| GPU node group with an accelerated AMI | AL2023 NVIDIA AMIs ship the driver and the container toolkit, which is what the `gpu*` input defaults assume. |
| `nvidia` RuntimeClass | run:ai workloads can set `runtimeClassName: nvidia`; nothing creates it when the operator's toolkit is off. |

The storage class is the one that is easy to miss, because `gp2` exists and looks usable:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters: { type: gp3, encrypted: "true" }
allowVolumeExpansion: true
# EBS volumes are zonal. Bind late so the volume lands in the zone the pod was scheduled to.
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite
```

This needs the `aws-ebs-csi-driver` add-on with an IRSA role; EKS does not install it by default.

### Install

1. Set `runaiRegistryCredentials` in `example/stackinstance-aws.yaml`.
2. Apply Apps, the AWS StackTemplate, and the StackInstance.

```bash
kubectl apply -f apps/
kubectl apply -f stacktemplate-aws.yaml
kubectl apply -f example/stackinstance-aws.yaml
```

### Inputs that differ from the generic templates

| Input | AWS default | Reason |
| --- | --- | --- |
| `tenant` | not present | It only ever named the nip.io label. |
| `gpuDevicePluginEnabled` | `"false"` | eksctl installs the NVIDIA device plugin on GPU node groups, as GKE does with its managed plugin. |
| `gpuToolkitEnabled` | `"false"` | The AMI ships nvidia-container-toolkit and nodeadm owns the containerd configuration. |
| `gpuCdiEnabled` | `"false"` | CDI needs the operator's own toolkit. |
| `domain` | empty | Empty uses the load balancer hostname. Set it to a name with a Route53 record pointing at that load balancer. |

The FQDN is long, so the bootstrap step issues the certificate with `CN=runai control plane` and
keeps the FQDN in the SANs: X.509 `commonName` caps at 64 bytes and a load balancer hostname is
around 77, which `openssl req` rejects outright.

### Validate

```bash
bash tests/validate-aws-ingress.sh
bash tests/verify-certs.sh
```

`validate-aws-ingress.sh` runs a probe pod on a node that hosts an ingress-nginx pod and calls the
FQDN. That is the routing AWS drops when NLB client IP preservation is on, which is why the AWS
ingress App sets `preserve_client_ip.enabled=false`: the Stack's own `authtoken`, `clusterreg` and
`clustercreds` steps and the run:ai cluster agent all call the FQDN from inside the cluster.

### Caveats

- ingress-nginx logs NLB addresses rather than real client IPs, the cost of disabling client IP
  preservation.
- Deleting and recreating the ingress Service produces a new load balancer hostname. The bootstrap
  step reissues the leaf certificate when its SANs no longer cover the FQDN, but the run:ai cluster
  registration keeps the old domain and has to be redone.
- `example/cronjob-runai-custom-link.yaml` matches Ingress hosts ending in `.nip.io`, so it does
  nothing on AWS.

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
