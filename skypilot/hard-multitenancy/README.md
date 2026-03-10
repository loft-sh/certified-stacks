# SkyPilot Hard Multitenancy Stack

Deploys isolated SkyPilot environments inside vClusters with **hard isolation**. Each tenant gets a dedicated vCluster with private auto-provisioned nodes, a complete SkyPilot API server, GPU operator, and ingress controller.

## Architecture

```
Host Cluster (GKE / EKS / etc.)
  ├── vCluster Platform
  ├── NodeProvider (auto-provisions dedicated VMs per tenant)
  │
  ├── vCluster "skypilot-tenant-1"  (namespace: skypilot-tenant-1)
  │     ├── Private auto-nodes (dedicated VMs)
  │     ├── SkyPilot API Server
  │     ├── GPU Operator
  │     ├── Ingress NGINX
  │     └── Tenant workloads (sky launch / sky jobs / sky serve)
  │
  └── vCluster "skypilot-tenant-2"  (namespace: skypilot-tenant-2)
        └── ...
```

## How it works

1. For each tenant in `var.tenants`, a vCluster is created with private auto-nodes via the vCluster Platform NodeProvider.
2. Inside each vCluster, Helm charts are deployed for: GPU Operator, Ingress NGINX, and the SkyPilot API server.
3. Tenants interact with their isolated SkyPilot instance via the API server endpoint exposed through ingress.

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
| name | Name prefix for the deployment (e.g. 'skypilot-prod') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| auto\_node\_properties | Properties passed to each autoNodes entry (e.g. {region = "us-east-1"} for AWS, {project = "my-proj", region = "us-central1"} for GCP) | `map(string)` | `{}` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator in tenant vClusters | `bool` | `true` | no |
| deploy\_grafana | Deploy Grafana inside tenant vClusters (SkyPilot sub-chart) | `bool` | `false` | no |
| deploy\_prometheus | Deploy Prometheus inside tenant vClusters (SkyPilot sub-chart) | `bool` | `false` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator (true for private auto-nodes) | `bool` | `true` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| host\_kube\_context | Kubernetes context to use from the kubeconfig (empty = current context) | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| ingress\_nginx\_version | Ingress NGINX Helm chart version | `string` | `"4.12.1"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| node\_groups | Node groups for tenant vClusters (static = always-on, dynamic = autoscaled) | <pre>object({<br/>    static = optional(list(object({<br/>      name       = string<br/>      quantity   = number<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>    })), [])<br/>    dynamic = optional(list(object({<br/>      name       = string<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>    })), [])<br/>  })</pre> | <pre>{<br/>  "dynamic": [<br/>    {<br/>      "name": "cpu-pool",<br/>      "node_types": []<br/>    },<br/>    {<br/>      "limits": {<br/>        "nodes": 5<br/>      },<br/>      "name": "gpu-pool",<br/>      "node_types": []<br/>    }<br/>  ]<br/>}</pre> | no |
| node\_provider\_name | Name of the NodeProvider configured in vCluster Platform for auto nodes | `string` | `""` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| skypilot\_image | SkyPilot API server container image (set to pin a stable release) | `string` | `"berkeleyskypilot/skypilot:0.11.2"` | no |
| skypilot\_version | SkyPilot Helm chart version | `string` | `"0.11.2"` | no |
| tenants | List of tenants, each deployed as an isolated vCluster with private nodes and a dedicated SkyPilot API server | <pre>list(object({<br/>    name             = string<br/>    auth_credentials = optional(string, "")<br/>    skypilot_config  = optional(string, "")<br/>    node_groups = optional(object({<br/>      static = optional(list(object({<br/>        name       = string<br/>        quantity   = number<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      })), [])<br/>      dynamic = optional(list(object({<br/>        name       = string<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>        limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>      })), [])<br/>    }))<br/>    ingress_service_annotations = optional(map(string), {})<br/>  }))</pre> | `[]` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| name | Name prefix for the deployment |
| tenant\_skypilot\_access | SkyPilot API server access instructions for each tenant |
| tenant\_vclusters | Map of tenant vCluster names to their connection info |
<!-- END_TF_DOCS -->

## Usage example

```hcl
module "skypilot" {
  source = "git::https://github.com/loft-sh/certified-stacks.git//skypilot/hard-multitenancy?ref=main"

  name                = "skypilot"
  platform_url        = "https://platform.example.com"
  platform_access_key = var.platform_access_key

  node_provider_name   = "gcp-compute"
  auto_node_properties = { project = "my-project", region = "us-central1" }

  tenants = [
    {
      name = "tenant-1"
      # auth_credentials = "admin:$apr1$..."
    },
    {
      name = "tenant-2"
    }
  ]
}
```
