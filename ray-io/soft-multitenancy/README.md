# Ray.io Soft Multitenancy Stack

Deploys a Ray.io tenant environment inside a vCluster with **soft isolation**. A single shared KubeRay operator runs on the host cluster while each tenant gets a dedicated vCluster with full Ray CRD access. Ray custom resources (RayCluster, RayJob, RayService) are synced to the host where the shared operator reconciles them — following vCluster's [shared platform stack](https://www.vcluster.com/blog/vcluster-shared-platform-stack) pattern (same as cert-manager, KubeVirt, and ESO integrations).

## Architecture

```
Host Cluster
  +-- KubeRay Operator (kuberay-system, shared, watches all namespaces)
  |     |
  |     | reconciles synced CRs
  |     v
  +-- tenant-ns (host namespace)
  |     +-- RayCluster CR (synced from vCluster)
  |     +-- head pod, worker pods, head-svc (:8265 dashboard)
  |     +-- status syncs back to vCluster
  |
  +-- vCluster: tenant (per tenant)
        +-- RayCluster / RayJob / RayService CRs (tenant creates these)
        +-- CR status visible (head.serviceIP, endpoints, conditions)
        +-- Shared GPU nodes (synced from host)
        +-- StorageClasses, IngressClasses (synced from host)
```

Key characteristics:

- **Shared KubeRay operator** — a single operator on the host reconciles Ray CRs for all tenants via namespace-scoped syncing.
- **CRD sync (toHost)** — `rayclusters.ray.io`, `rayjobs.ray.io`, and `rayservices.ray.io` are synced from vCluster to host; status syncs back bidirectionally.
- **Shared GPU nodes** — host nodes (including GPU nodes) are visible inside each vCluster via `sync.fromHost.nodes`.
- **Isolated API server** — each tenant gets its own vCluster with separate Kubernetes API, RBAC, and namespace hierarchy.
- **No Ray components inside vCluster** — the vCluster contains only the synced CRs and their status. All Ray pods run on the host.

## Prerequisites

| Requirement | Details |
|---|---|
| Terraform | >= 1.6 |
| Host Kubernetes cluster | With GPU nodes and an ingress controller |
| vCluster Platform | Running and accessible, with an access key |
| KubeRay CRDs on host | Installed automatically when `deploy_kuberay_operator = true` |

## Usage

1. Copy the example variables file and fill in your values:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Initialize and apply:

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. After apply completes, use the tenant kubeconfig to create Ray workloads:

   ```bash
   export KUBECONFIG=$(terraform output -raw kubeconfig_path)

   # Create a RayCluster
   kubectl apply -f - <<EOF
   apiVersion: ray.io/v1
   kind: RayCluster
   metadata:
     name: my-cluster
   spec:
     rayVersion: '2.53.0'
     headGroupSpec:
       rayStartParams:
         dashboard-host: '0.0.0.0'
       template:
         spec:
           containers:
           - name: ray-head
             image: rayproject/ray:2.53.0
             resources:
               limits:
                 cpu: "2"
                 memory: "4G"
     workerGroupSpecs:
     - replicas: 2
       groupName: workers
       template:
         spec:
           containers:
           - name: ray-worker
             image: rayproject/ray:2.53.0
             resources:
               limits:
                 cpu: "4"
                 memory: "8G"
   EOF

   # Check status (synced back from host operator)
   kubectl get raycluster my-cluster
   ```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Name for the vCluster and Ray.io tenant | `string` | — | yes |
| `ingress_ip` | IP address of the ingress controller for nip.io URL generation | `string` | — | yes |
| `cluster_url` | Explicit cluster URL (overrides auto-derived nip.io URL) | `string` | `""` | no |
| `host_kubeconfig_path` | Path to the host cluster kubeconfig | `string` | `~/.kube/config` | no |
| `platform_url` | URL of the vCluster Platform | `string` | — | yes |
| `platform_access_key` | Access key for the vCluster Platform API | `string` | — | yes |
| `platform_insecure` | Skip TLS verification for the vCluster Platform | `bool` | `false` | no |
| `platform_project_name` | vCluster Platform project to deploy into | `string` | `"default"` | no |
| `vcluster_chart_version` | vCluster Helm chart version | `string` | `"0.31.0"` | no |
| `deploy_kuberay_operator` | Deploy the shared KubeRay operator on the host cluster | `bool` | `true` | no |
| `kuberay_operator_version` | KubeRay operator Helm chart version | `string` | `"1.5.1"` | no |
| `ray_version` | Ray container image version | `string` | `"2.53.0"` | no |
| `install_gpu_operator` | Deploy the NVIDIA GPU Operator on the host | `bool` | `false` | no |
| `gpu_operator_version` | NVIDIA GPU Operator Helm chart version | `string` | `"v24.9.1"` | no |

## Outputs

| Name | Description |
|---|---|
| `name` | Name of the deployed vCluster and Ray.io tenant |
| `kubeconfig_path` | Local file path to the generated vCluster kubeconfig |
| `cluster_url` | External URL of the vCluster API server |
| `vcluster_host` | API server host of the vCluster |
| `vcluster_namespace` | Host namespace where synced Ray pods run |
| `kuberay_operator_namespace` | Namespace of the shared KubeRay operator (for admin) |

## Tenant Experience

The tenant receives `kubeconfig_path` and `cluster_url`. Using the vCluster kubeconfig, they can:

- **Create Ray clusters**: `kubectl apply -f raycluster.yaml`
- **Submit batch jobs**: `kubectl apply -f rayjob.yaml`
- **Deploy serving endpoints**: `kubectl apply -f rayservice.yaml`
- **Check status**: `kubectl get raycluster` — status fields (`head.serviceIP`, `endpoints`, `conditions`, `readyWorkerReplicas`) are synced back from the host operator.
- **Access the Ray Dashboard**: via the head service IP on port 8265 (from `.status.head.serviceIP` in the RayCluster status), or via port-forward on the host namespace.

## Comparison with Hard Multitenancy

| Aspect | Soft Multitenancy (this stack) | Hard Multitenancy |
|---|---|---|
| KubeRay operator | Shared on host | Dedicated per vCluster |
| GPU nodes | Shared across tenants | Private per tenant (label selector) |
| Ray pods run on | Host namespace (synced) | Inside vCluster |
| Complexity | Lower | Higher |
| Resource overhead | Lower | Higher |
| Use case | Trusted tenants, shared GPU pool | Untrusted tenants, strict GPU isolation |

## References

- [Ray.io Documentation](https://docs.ray.io/en/latest/)
- [KubeRay Operator](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/kuberay-operator-installation.html)
- [KubeRay Helm Charts](https://github.com/ray-project/kuberay-helm)
- [vCluster Shared Platform Stack Pattern](https://www.vcluster.com/blog/vcluster-shared-platform-stack)
- [vCluster Custom Resource Syncing](https://www.vcluster.com/docs/syncer/custom_resources)

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.6 |
| helm | ~> 2.0 |
| kubernetes | ~> 2.0 |

## Providers

| Name | Version |
|------|---------|
| helm | ~> 2.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | fc02f7924763a1c1745f25e847a68ed830a62cf8 |

## Resources

| Name | Type |
|------|------|
| [helm_release.kuberay_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| ingress\_ip | IP address of the ingress controller used to construct the default cluster URL via nip.io | `string` | n/a | yes |
| name | Name for the vCluster and Ray.io tenant (e.g. 'tenant-alpha') | `string` | n/a | yes |
| platform\_access\_key | Access key for authenticating with the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| cluster\_url | Explicit URL for the vCluster. When empty, derived as https://<name>.<ingress\_ip>.nip.io | `string` | `""` | no |
| deploy\_kuberay\_operator | Deploy the shared KubeRay operator on the host cluster. Set to false if already installed or managed separately. | `bool` | `true` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v24.9.1"` | no |
| host\_kube\_context | Kubernetes context to use from the kubeconfig (empty = current context) | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig file | `string` | `"~/.kube/config"` | no |
| install\_gpu\_operator | Deploy the NVIDIA GPU Operator inside the vCluster | `bool` | `false` | no |
| kuberay\_operator\_version | KubeRay operator Helm chart version | `string` | `"1.5.1"` | no |
| platform\_insecure | Skip TLS certificate verification when connecting to the vCluster Platform | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project in which to create the vCluster | `string` | `"default"` | no |
| vcluster\_chart\_version | vCluster Helm chart version to deploy | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| cluster\_url | External URL of the vCluster |
| kubeconfig\_path | Local file path to the generated vCluster kubeconfig |
| kuberay\_operator\_namespace | Namespace where the shared KubeRay operator is deployed |
| name | Name of the deployed vCluster and Ray.io tenant |
| vcluster\_host | API server host of the created vCluster |
| vcluster\_namespace | Host namespace in which the vCluster is running |
<!-- END_TF_DOCS -->