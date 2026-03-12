# Run:AI Hard Multitenancy Stack

Deploys a fully self-contained Run:AI environment using vCluster with **hard isolation**. Both the Run:AI control plane and each tenant agent run inside dedicated vClusters with private auto-provisioned nodes.

## Architecture

```
Host Cluster (GKE)
  ├── vCluster Platform (manages vClusters)
  ├── NodeProvider (auto-provisions GCE VMs as private nodes)
  │
  ├── vCluster "hard-mt-cp"               (private nodes)
  │     ├── Run:AI Control Plane
  │     ├── Ingress NGINX
  │     └── TLS certificates
  │
  ├── vCluster "hard-mt-1-agent"           (private nodes)
  │     ├── Run:AI Cluster Agent
  │     ├── NVIDIA GPU Operator
  │     ├── Prometheus Operator (CRDs)
  │     ├── Knative Serving (inference)
  │     ├── Ingress NGINX
  │     └── Tenant workloads
  │
  └── vCluster "hard-mt-2-agent"           (private nodes)
        └── ...
```

Key characteristics:

- **Dedicated control plane** — the Run:AI CP is deployed inside its own vCluster, fully managed by this stack.
- **Private auto nodes** — every vCluster gets dedicated GCE VMs provisioned on demand via the vCluster Platform NodeProvider. No shared host nodes.
- **Full isolation** — each tenant's GPU operator, drivers, monitoring, and networking run independently.
- **Configurable node groups** — static (always-on) and dynamic (autoscaled) node pools per vCluster, with per-agent overrides.

## Host Cluster Prerequisites

The hard-multitenancy stack requires the least from the host cluster since each vCluster runs on its own private nodes. You still need:

| Requirement | Details |
|---|---|
| **GKE cluster** | With workload identity enabled |
| **vCluster Platform** | Running on the host, with an access key and a `NodeProvider` configured |
| **NodeProvider** | A NodeProvider capable of provisioning CPU and GPU nodes (e.g. GCP Compute, AWS EC2, Azure VM) |
| **Static IPs** (optional) | Pre-reserved external IPs for stable ingress domains |
| **Run:AI registry credentials** | Base64-encoded Docker config JSON for pulling Run:AI images from JFrog |

## Usage

Use this stack as a Terraform module, or fork it and customize to fit your environment.

### 1. Create a wrapper configuration

Create a Terraform configuration that references this stack as a module:

```hcl
module "hard_multitenancy" {
  source = "git::https://github.com/loft-sh/certified-stacks.git//run-ai/hard-multitenancy?ref=main"

  # Deployment identity
  name                  = "hard-mt"
  host_kubeconfig_path  = "~/.kube/config"
  kubeconfig_output_dir = "."

  # vCluster Platform
  platform_url          = var.platform_url
  platform_access_key   = var.platform_access_key
  platform_project_name = "default"
  platform_insecure     = true

  # vCluster versions
  vcluster_chart_version = "0.31.0"

  # Auto Nodes — GCP Compute via the gcp-compute NodeProvider
  node_provider_name = "gcp-compute"
  auto_node_properties = {
    project = var.gcp_project
    region  = var.gcp_region
  }

  # Node groups
  cp_node_groups    = var.cp_node_groups
  agent_node_groups = var.agent_node_groups

  # Run:AI Control Plane
  runai_cp_domain            = var.runai_cp_domain
  runai_chart_version        = "2.24.40"
  runai_admin_email          = "admin@loft.sh"
  runai_admin_password       = var.runai_admin_password
  runai_registry_credentials = var.runai_registry_credentials

  cp_static_ip = var.cp_static_ip

  # Agents
  agents = [
    {
      name                = "1-agent"
      domain              = "1-agent.10.0.0.2.nip.io"
      static_ip           = "10.0.0.2"
      inference_static_ip = "10.0.0.3"
      inference_domain    = "inference.10.0.0.3.nip.io"
    }
  ]

  # Inference (Knative)
  enable_inference = true

  # GPU Operator
  deploy_gpu_operator         = true
  gpu_operator_driver_enabled = true

  # Prometheus Operator
  deploy_prometheus_operator = true

  # TLS — self-signed (default) or user-provided
  tls_mode     = "self-signed"
  # user_tls_cert = var.user_tls_cert  # required when tls_mode = "user-provided"
  # user_tls_key  = var.user_tls_key
  # user_ca_cert  = var.user_ca_cert
}
```

> Replace `?ref=main` with a tag (e.g. `?ref=v1.0.0`) to pin to a specific release.

### 2. Initialize and apply

```bash
cd my-runai-deployment/
terraform init
terraform apply
```

The stack will:
1. Create a CP vCluster with auto nodes and deploy the Run:AI control plane
2. Wait for the CP API to become healthy (up to 30 minutes, configurable)
3. Register each agent cluster via the Run:AI REST API
4. Create an agent vCluster per agent with auto nodes, GPU operator, and the Run:AI agent

### 3. Access tenant vClusters

```bash
# Using kubeconfig files (written to kubeconfig_output_dir)
export KUBECONFIG=./hard-mt-1-agent-kubeconfig.yaml
kubectl get nodes   # shows private auto-provisioned nodes

# Or via vcluster CLI
vcluster connect hard-mt-1-agent
```

## Node Groups

Each vCluster gets its own dedicated cloud VMs via the NodeProvider. Node groups are configurable as **static** (always-on) or **dynamic** (autoscaled).

### CP node groups (`cp_node_groups`)

Controls the VMs backing the Run:AI control-plane vCluster:

```hcl
cp_node_groups = {
  dynamic = [{
    name       = "cp-pool"
    node_types = ["gcp-compute.e2-standard-8", "gcp-compute.e2-standard-16"]
    limits     = { nodes = 2 }
  }]
}
```

### Agent node groups (`agent_node_groups`)

Default for all agent vClusters. Each agent gets its own copy of these pools:

```hcl
agent_node_groups = {
  static = [{
    name       = "always-on-cpu"
    quantity   = 1
    node_types = ["gcp-compute.e2-standard-8"]
  }]
  dynamic = [
    {
      name       = "cpu-burst"
      node_types = ["gcp-compute.e2-standard-8", "gcp-compute.e2-standard-16"]
      limits     = { nodes = 3 }
    },
    {
      name       = "gpu-pool"
      node_types = ["gcp-compute.n1-standard-4-t4"]
      limits     = { nodes = 5 }
    }
  ]
}
```

### Per-agent overrides

Override node groups for a specific agent by adding `node_groups` to the agent object. When set, it completely replaces the default `agent_node_groups` for that agent:

```hcl
agents = [
  {
    name      = "gpu-heavy-agent"
    domain    = "gpu.10.0.0.2.nip.io"
    static_ip = "10.0.0.2"
    node_groups = {
      static = [{
        name       = "always-on-gpu"
        quantity   = 1
        node_types = ["gcp-compute.g2-standard-4"]
      }]
      dynamic = [{
        name       = "burst-gpu"
        node_types = ["gcp-compute.g2-standard-4", "gcp-compute.g2-standard-8"]
        limits     = { nodes = 10 }
      }]
    }
  },
  {
    name      = "cpu-only-agent"
    domain    = "cpu.10.0.0.3.nip.io"
    static_ip = "10.0.0.3"
    # Uses default agent_node_groups (no override)
  }
]
```

### Node group field reference

**Static pools** (always-on nodes):

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Pool name |
| `quantity` | number | yes | Number of nodes to keep running |
| `node_types` | list(string) | no | Allowed instance types (empty = any) |
| `labels` | map(string) | no | Kubernetes node labels |
| `taints` | list(object) | no | Kubernetes taints (`key`, `value`, `effect`) |

**Dynamic pools** (autoscaled nodes):

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | Pool name |
| `node_types` | list(string) | no | Allowed instance types (empty = any) |
| `limits` | object | no | Scale limits: `nodes` (int), `cpu` (int), `memory` (string) |
| `labels` | map(string) | no | Kubernetes node labels |
| `taints` | list(object) | no | Kubernetes taints (`key`, `value`, `effect`) |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| helm | ~> 2.0 |
| kubernetes | ~> 2.0 |
| local | ~> 2.0 |
| random | ~> 3.0 |
| restful | ~> 0.25 |
| tls | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| random | 3.8.1 |
| restful | 0.25.1 |
| tls | 4.2.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| agent\_vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | v1.0.0 |
| cp\_auth | ../_shared/runai-auth | n/a |
| cp\_vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | v1.0.0 |

## Resources

| Name | Type |
|------|------|
| [random_password.runai_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [restful_operation.cluster_creds](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |
| [restful_operation.create_cluster](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |
| [restful_operation.wait_for_runai_cp_ready](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |
| [tls_cert_request.agent_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_cert_request.cp](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_locally_signed_cert.agent_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_locally_signed_cert.cp](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_private_key.agent_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.cp](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name prefix for the deployment (e.g. 'tenant-alpha') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| runai\_cp\_domain | Domain name for the Run:AI control plane (e.g. runai.10.0.0.1.nip.io) | `string` | n/a | yes |
| runai\_registry\_credentials | Base64-encoded Docker config JSON for the Run:AI registry | `string` | n/a | yes |
| agent\_node\_groups | Default node groups for all agent vClusters (overridable per agent) | <pre>object({<br/>    static = optional(list(object({<br/>      name       = string<br/>      quantity   = number<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>    })), [])<br/>    dynamic = optional(list(object({<br/>      name       = string<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>    })), [])<br/>  })</pre> | <pre>{<br/>  "dynamic": [<br/>    {<br/>      "name": "cpu-pool",<br/>      "node_types": []<br/>    },<br/>    {<br/>      "limits": {<br/>        "nodes": 5<br/>      },<br/>      "name": "gpu-pool",<br/>      "node_types": []<br/>    }<br/>  ]<br/>}</pre> | no |
| agents | List of cluster agents to register and deploy as vClusters | <pre>list(object({<br/>    name                          = string<br/>    domain                        = string<br/>    static_ip                     = optional(string, "")<br/>    inference_static_ip           = optional(string, "")<br/>    inference_domain              = optional(string, "")<br/>    ingress_service_annotations   = optional(map(string), {})<br/>    inference_service_annotations = optional(map(string), {})<br/>    node_groups = optional(object({<br/>      static = optional(list(object({<br/>        name       = string<br/>        quantity   = number<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      })), [])<br/>      dynamic = optional(list(object({<br/>        name       = string<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>        limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>      })), [])<br/>    }))<br/>  }))</pre> | `[]` | no |
| auto\_node\_properties | Properties passed to each autoNodes entry (e.g. {region = "us-east-1"} for AWS, {project = "my-proj", region = "us-central1"} for GCP) | `map(string)` | `{}` | no |
| cp\_health\_check\_interval | Seconds between health check retries | `number` | `10` | no |
| cp\_health\_check\_retries | Number of retries when waiting for the Run:AI API to become healthy | `number` | `180` | no |
| cp\_ingress\_service\_annotations | Additional annotations for the CP ingress-nginx LoadBalancer service (e.g. cloud-specific LB configuration) | `map(string)` | `{}` | no |
| cp\_node\_groups | Node groups for the control-plane vCluster (static = always-on, dynamic = autoscaled) | <pre>object({<br/>    static = optional(list(object({<br/>      name       = string<br/>      quantity   = number<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>    })), [])<br/>    dynamic = optional(list(object({<br/>      name       = string<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>    })), [])<br/>  })</pre> | <pre>{<br/>  "dynamic": [<br/>    {<br/>      "limits": {<br/>        "nodes": 2<br/>      },<br/>      "name": "cp-pool",<br/>      "node_types": []<br/>    }<br/>  ]<br/>}</pre> | no |
| cp\_static\_ip | Pre-reserved static IP for the CP ingress LoadBalancer (leave empty for dynamic) | `string` | `""` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator in agent vClusters | `bool` | `true` | no |
| deploy\_prometheus\_operator | Deploy Prometheus Operator (CRDs) in agent vClusters | `bool` | `true` | no |
| enable\_inference | Enable Knative Serving for inference workloads in agent vClusters | `bool` | `true` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator | `bool` | `true` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| host\_kube\_context | Kubeconfig context to use for the host cluster. If empty, uses the current context. | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| ingress\_nginx\_chart\_version | ingress-nginx Helm chart version | `string` | `"4.12.1"` | no |
| knative\_operator\_version | Knative Operator Helm chart version | `string` | `"1.18.0"` | no |
| knative\_serving\_version | Knative Serving version installed by the operator | `string` | `"1.16.3"` | no |
| kube\_prometheus\_stack\_version | kube-prometheus-stack Helm chart version | `string` | `"72.6.2"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| node\_provider\_name | Name of the NodeProvider configured in vCluster Platform for auto nodes | `string` | `""` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| raw\_chart\_version | Bedag raw Helm chart version (used to deploy Knative Serving CR) | `string` | `"2.0.2"` | no |
| runai\_admin\_email | Admin email for initial Run:AI login. Validated by the shared runai-auth module. | `string` | `"admin@run.ai"` | no |
| runai\_admin\_password | Admin password for initial Run:AI login. Auto-generated if not provided. | `string` | `null` | no |
| runai\_agent\_chart\_repo | Helm chart repository for the Run:AI cluster agent | `string` | `"https://runai.jfrog.io/artifactory/api/helm/run-ai-charts"` | no |
| runai\_chart\_version | Run:AI Helm chart version (used for both CP and agent) | `string` | `"2.24.18"` | no |
| runai\_cp\_chart\_repo | Helm chart repository for the Run:AI control plane | `string` | `"https://runai.jfrog.io/artifactory/cp-charts-prod"` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| tls\_mode | TLS certificate mode: 'self-signed' generates certs via Terraform, 'user-provided' uses supplied certs | `string` | `"self-signed"` | no |
| user\_ca\_cert | PEM-encoded CA certificate. Required when tls\_mode = 'user-provided' | `string` | `""` | no |
| user\_tls\_cert | PEM-encoded TLS certificate (full chain: leaf + CA). Required when tls\_mode = 'user-provided' | `string` | `""` | no |
| user\_tls\_key | PEM-encoded TLS private key. Required when tls\_mode = 'user-provided' | `string` | `""` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| agent\_vclusters | Map of agent vCluster names to their connection info |
| cluster\_registrations | Map of registered cluster names to their UUIDs |
| control\_plane\_url | URL of the Run:AI control plane |
| cp\_vcluster\_host | API server endpoint for the CP vCluster |
| cp\_vcluster\_kubeconfig\_path | Path to the CP vCluster kubeconfig file |
| inference\_domains | Inference endpoint domains per agent (wildcard, points to Kourier LB) |
| name | Name prefix for the deployment |
| runai\_admin\_password | Run:AI admin password (auto-generated if not provided) |
<!-- END_TF_DOCS -->

## State Security

This stack stores sensitive values (admin password, TLS private keys, client secrets) in the Terraform state. **Use an encrypted remote backend** (e.g. GCS with customer-managed encryption keys, S3 with SSE-KMS) to protect state at rest. Never use local state files in production.

## Troubleshooting

### Control plane not becoming healthy

The `restful` provider waits up to `cp_health_check_retries * cp_health_check_interval` seconds (default: 30 minutes) for the CP API to respond. If it times out:

1. Check the CP vCluster is running: `kubectl get pods -n <name>-cp`
2. Check Run:AI pods inside: `kubectl --kubeconfig ./<name>-cp-kubeconfig.yaml get pods -n runai-backend`
3. Check ingress: `curl -sk https://<cp-domain>/api/v1/health`

### Auto nodes not provisioning

1. Verify the NodeProvider CRD exists: `kubectl get nodeprovider gcp-compute`
2. Check vCluster Platform logs: `kubectl logs -n vcluster-platform deploy/loft`
3. Verify GCP IAM: the vCluster Platform service account needs `compute.admin` and `iam.serviceAccountUser` roles

### Agent not connecting to control plane

1. Check agent vCluster: `kubectl get pods -n <name>-<agent-name>`
2. Check Run:AI agent pods: `kubectl --kubeconfig ./<name>-<agent-name>-kubeconfig.yaml get pods -n runai`
3. Verify TLS trust: the agent must trust the CP's self-signed cert (provisioned automatically as `runai-cp-ca-cert`)

## Comparison with Soft Multitenancy

| Aspect | Hard Multitenancy (this stack) | Soft Multitenancy |
|---|---|---|
| Run:AI control plane | Dedicated vCluster (self-contained) | External (shared, pre-existing) |
| Agent isolation | vCluster + private nodes per tenant | vCluster on shared host nodes |
| Node provisioning | Auto nodes (dedicated GCE VMs) | Shared host node pools with labels |
| GPU operators | Per-vCluster (full isolation) | Per-vCluster (synced from host) |
| Host prerequisites | Minimal (platform + NodeProvider) | Node pools with tenant labels |
| Resource overhead | Higher (dedicated VMs per vCluster) | Lower (shared infrastructure) |
| Use case | Untrusted tenants, strict isolation | Trusted tenants, cost efficiency |
