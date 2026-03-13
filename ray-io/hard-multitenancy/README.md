# Ray.io Hard Multitenancy Stack

Deploys fully isolated Ray.io tenant environments using vCluster Platform with private auto-nodes. Each tenant receives a dedicated vCluster with its own KubeRay operator, optional GPU operator, and auto-provisioned private nodes for complete workload and hardware isolation.

## Architecture

```
+--[ Host Kubernetes Cluster ]-----------------------------------------------+
|                                                                             |
|  +--[ vCluster: ray-tenant-1 ]--------+  +--[ vCluster: ray-tenant-N ]-+  |
|  |                                      |  |                             |  |
|  |  Private Auto-Nodes (VPN)            |  |  Private Auto-Nodes (VPN)   |  |
|  |  KubeRay Operator (dedicated)        |  |  KubeRay Operator           |  |
|  |  NVIDIA GPU Operator (optional)      |  |  NVIDIA GPU Operator        |  |
|  |  Default RayCluster (optional)       |  |  Default RayCluster         |  |
|  |                                      |  |                             |  |
|  |  Dashboard: LoadBalancer:8265        |  |  Dashboard: LoadBalancer    |  |
|  |                                      |  |                             |  |
|  +--------------------------------------+  +-----------------------------+  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

Key characteristics:

- **Private auto-nodes** — each vCluster gets dedicated cloud nodes provisioned on-demand via vCluster Platform auto-nodes with VPN connectivity.
- **Dedicated KubeRay operator** — each vCluster runs its own KubeRay operator via `experimental.deploy.vcluster.helm`, fully isolated from other tenants.
- **Full isolation** — separate Kubernetes API, etcd, RBAC, operator instances, and compute nodes per tenant. No cross-tenant visibility.
- **Optional components** — GPU operator, default RayCluster with configurable workers and GPU allocation.
- **Cloud-agnostic** — works with any cloud provider supported by vCluster Platform auto-nodes (AWS, GCP, Azure, etc.).

## Prerequisites

| Requirement | Details |
|---|---|
| Terraform | >= 1.6 |
| Host Kubernetes cluster | With vCluster Platform installed |
| vCluster Platform | Running with auto-nodes configured for your cloud provider |
| Platform access key | Created under Settings > Access Keys |

## Usage

### 1. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
cp secrets.auto.tfvars.example secrets.auto.tfvars
# Edit both files with your values
```

### 2. Initialize and apply

```bash
terraform init
terraform plan
terraform apply
```

### 3. Access tenant vClusters

```bash
# Get tenant-1 kubeconfig
export KUBECONFIG=./ray-tenant-1-kubeconfig.yaml

# KubeRay operator is already running inside the vCluster
kubectl get pods -n kuberay

# If deploy_default_cluster = true, the RayCluster is already running
kubectl get raycluster -n ray

# Access the Ray Dashboard via LoadBalancer
kubectl get svc -n ray ray-cluster-kuberay-head-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Open http://<IP>:8265 in your browser
```

### 4. Submit Ray jobs

```bash
# Via the Ray Jobs API
ray job submit --address http://<DASHBOARD_IP>:8265 -- python my_script.py

# Or create additional RayClusters/RayJobs via kubectl
kubectl apply -f my-rayjob.yaml
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Name prefix for all resources | `string` | — | yes |
| `host_kubeconfig_path` | Path to the host cluster kubeconfig | `string` | `~/.kube/config` | no |
| `kubeconfig_output_dir` | Directory for generated kubeconfig files | `string` | `.` | no |
| `platform_url` | URL of the vCluster Platform | `string` | — | yes |
| `platform_access_key` | Access key for the vCluster Platform API | `string` | — | yes |
| `platform_project_name` | vCluster Platform project to deploy into | `string` | `"default"` | no |
| `node_provider_name` | Auto-nodes provider name (e.g. `gcp-compute`, `aws-ec2`) | `string` | `""` | no |
| `auto_node_properties` | Properties for auto-nodes (e.g. `{region = "us-east-1"}`) | `map(string)` | `{}` | no |
| `node_groups` | Node groups configuration (static + dynamic) | `object` | See variables.tf | no |
| `tenants` | List of tenants with Ray worker config | `list(object)` | `[]` | no |
| `kuberay_version` | KubeRay Helm chart version | `string` | `"1.5.1"` | no |
| `ray_version` | Ray container image tag (e.g. '2.54.0') | `string` | `"2.54.0"` | no |
| `deploy_default_cluster` | Deploy a default RayCluster per tenant | `bool` | `true` | no |
| `deploy_gpu_operator` | Deploy NVIDIA GPU Operator | `bool` | `true` | no |
| `gpu_operator_version` | GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |

## Tenant Configuration

Each tenant object supports:

```hcl
tenants = [
  {
    name               = "team-a"
    worker_replicas    = 2        # Number of Ray workers
    gpu_per_worker     = 1        # GPUs per worker (0 = CPU only)
    enable_autoscaling = true     # Ray autoscaler
    max_workers        = 10       # Max workers when autoscaling
    node_groups        = { ... }  # Optional per-tenant node group override
    head_service_annotations = {} # Annotations for the head LoadBalancer
  }
]
```

## Outputs

| Name | Description |
|---|---|
| `name` | Name prefix for the deployment |
| `tenant_vclusters` | Map of tenant names to connection info (`host`, `kubeconfig_path`) |
| `tenant_ray_dashboard` | Ray Dashboard access instructions per tenant |

## References

- [Ray.io Documentation](https://docs.ray.io/en/latest/)
- [KubeRay Operator](https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/kuberay-operator-installation.html)
- [KubeRay Helm Charts](https://github.com/ray-project/kuberay-helm)
- [vCluster Private Nodes](https://www.vcluster.com/docs/vcluster/deploy/topologies/private-nodes)
- [vCluster Auto-Nodes](https://www.vcluster.com/docs/platform/auto-nodes)

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.6 |
| helm | ~> 2.0 |
| kubernetes | ~> 2.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| tenant\_vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | fc02f7924763a1c1745f25e847a68ed830a62cf8 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name prefix for the deployment (e.g. 'ray-prod') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| auto\_node\_properties | Properties passed to each autoNodes entry (e.g. {region = "us-east-1"} for AWS, {project = "my-proj", region = "us-central1"} for GCP) | `map(string)` | `{}` | no |
| deploy\_default\_cluster | Deploy a default RayCluster in each tenant vCluster | `bool` | `true` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator in tenant vClusters | `bool` | `true` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator (true for private auto-nodes) | `bool` | `true` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| host\_kube\_context | Kubernetes context to use from the kubeconfig (empty = current context) | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| ingress\_nginx\_version | Ingress NGINX Helm chart version | `string` | `"4.12.1"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| kuberay\_version | KubeRay operator and ray-cluster Helm chart version | `string` | `"1.5.1"` | no |
| node\_groups | Node groups for tenant vClusters (static = always-on, dynamic = autoscaled) | <pre>object({<br/>    static = optional(list(object({<br/>      name       = string<br/>      quantity   = number<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>    })), [])<br/>    dynamic = optional(list(object({<br/>      name       = string<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>    })), [])<br/>  })</pre> | <pre>{<br/>  "dynamic": [<br/>    {<br/>      "name": "cpu-pool",<br/>      "node_types": []<br/>    },<br/>    {<br/>      "limits": {<br/>        "nodes": 5<br/>      },<br/>      "name": "gpu-pool",<br/>      "node_types": []<br/>    }<br/>  ]<br/>}</pre> | no |
| node\_provider\_name | Name of the NodeProvider configured in vCluster Platform for auto nodes | `string` | `""` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| ray\_image | Ray container image repository | `string` | `"rayproject/ray"` | no |
| ray\_version | Ray container image tag (e.g. '2.54.0') | `string` | `"2.54.0"` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| tenants | List of tenants, each deployed as an isolated vCluster with private nodes and a dedicated KubeRay operator | <pre>list(object({<br/>    name               = string<br/>    worker_replicas    = optional(number, 1)<br/>    gpu_per_worker     = optional(number, 1)<br/>    enable_autoscaling = optional(bool, false)<br/>    max_workers        = optional(number, 5)<br/>    node_groups = optional(object({<br/>      static = optional(list(object({<br/>        name       = string<br/>        quantity   = number<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      })), [])<br/>      dynamic = optional(list(object({<br/>        name       = string<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>        limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>      })), [])<br/>    }))<br/>    head_service_annotations    = optional(map(string), {})<br/>    ingress_service_annotations = optional(map(string), {})<br/>  }))</pre> | `[]` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| name | Name prefix for the deployment |
| tenant\_ray\_dashboard | Ray Dashboard access instructions for each tenant |
| tenant\_vclusters | Map of tenant vCluster names to their connection info |
<!-- END_TF_DOCS -->