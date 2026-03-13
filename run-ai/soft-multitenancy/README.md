# NVIDIA Run:ai Soft Multitenancy Stack

Deploys NVIDIA Run:ai cluster agents inside vClusters with **soft isolation**. In this model a single NVIDIA Run:ai control plane (external) is shared across tenants while each tenant gets a dedicated vCluster with its own Kubernetes API, NVIDIA Run:ai agent, and workload scheduling — all running on shared host cluster nodes.

## Architecture

```
Host Cluster (GKE / EKS / etc.)
  ├── Shared NVIDIA RuntimeClass
  ├── Ingress NGINX (shared)
  ├── vCluster Platform
  │
  ├── Node pool "tenant-a"  (label: tenant=tenant-a)
  │     └── Nodes assigned to tenant-a vCluster
  ├── Node pool "tenant-b"  (label: tenant=tenant-b)
  │     └── Nodes assigned to tenant-b vCluster
  │
  ├── vCluster "soft-mt-tenant-a"   (namespace: soft-mt-tenant-a)
  │     ├── NVIDIA Run:ai Cluster Agent
  │     ├── GPU Operator (discovers host GPUs via node sync)
  │     ├── Prometheus Operator (CRDs)
  │     ├── Knative Serving (inference)
  │     └── Tenant workloads
  │
  └── vCluster "soft-mt-tenant-b"   (namespace: soft-mt-tenant-b)
        └── ...
```

Key characteristics:

- **Shared control plane** — the NVIDIA Run:ai control plane is external (SaaS or self-hosted on the same host cluster); this stack only registers agents against it.
- **Shared host nodes** — tenants run on shared GKE/EKS node pools. Node assignment is controlled via Kubernetes labels and vCluster node syncing.
- **Isolated API server** — each tenant gets its own vCluster with a separate Kubernetes API, RBAC, and namespace hierarchy.
- **GPU discovery via sync** — the GPU Operator inside each vCluster discovers host GPUs through synced node objects.

## Host Cluster Prerequisites

The soft-multitenancy stack runs vClusters directly on shared host nodes. This requires more host-side preparation than hard multitenancy.

| Requirement | Details |
|---|---|
| **GKE/EKS cluster** | With GPU node pools and ingress controller |
| **vCluster Platform** | Running and accessible, with an access key |
| **NVIDIA Run:ai control plane** | External (SaaS or self-hosted), with admin API credentials |
| **Labeled node pools** | Host nodes must carry the tenant label matching each agent's `node_selector_label_value` |
| **NVIDIA RuntimeClass** | `nvidia` RuntimeClass on the host (must be created as part of host setup) |
| **NVIDIA Run:ai registry credentials** | Base64-encoded Docker config JSON |

### Node labeling

Nodes must carry labels matching the `node_selector_label_key` / `node_selector_label_value` pair configured for each agent. You can label nodes at the node pool level or manually:

```bash
# GKE node pool level (recommended — labels persist on new nodes)
gcloud container node-pools update <pool-name> \
  --cluster <cluster-name> --region <region> \
  --node-labels=tenant=tenant-a

# Manual (does NOT survive autoscaler scale-ups)
kubectl label node <node-name> tenant=tenant-a

# EKS — set labels via launch template or eksctl nodegroup config
```

If `node_selector_label_value` is empty (or omitted) for an agent, the vCluster syncs **all** host nodes — no labeling required. This is useful for dev/test but not recommended for production multi-tenancy.

Confirm nodes are labeled:

```bash
kubectl get nodes -l tenant=tenant-a
```

Without labeled nodes, the vCluster will sync zero nodes and all pods will be unschedulable.

## Usage

Use this stack as a Terraform module, or fork it and customize to fit your environment.

### 1. Create a wrapper configuration

Create a Terraform configuration that references this stack as a module:

```hcl
module "soft_multitenancy" {
  source = "git::https://github.com/loft-sh/certified-stacks.git//run-ai/soft-multitenancy?ref=main"

  # Deployment identity
  name                  = "soft-mt"
  host_kubeconfig_path  = "~/.kube/config"
  kubeconfig_output_dir = "."

  # vCluster Platform
  platform_url          = var.platform_url
  platform_access_key   = var.platform_access_key
  platform_project_name = "default"
  platform_insecure     = true

  # vCluster versions
  vcluster_chart_version = "0.31.0"

  # NVIDIA Run:ai Control Plane (external / shared)
  runai_cp_url               = var.runai_cp_url
  runai_admin_email          = "admin@loft.sh"
  runai_admin_password       = var.runai_admin_password
  runai_chart_version        = "2.24.40"
  runai_registry_credentials = var.runai_registry_credentials

  # Optional: CA cert if CP uses self-signed TLS
  # runai_cp_ca_cert = var.runai_cp_ca_cert

  # Agents — one vCluster per tenant on shared labeled nodes
  agents = [
    {
      name                      = "tenant-a"
      domain                    = "tenant-a.10.0.0.1.nip.io"
      node_selector_label_value = "tenant-a"
    },
    {
      name                      = "tenant-b"
      domain                    = "tenant-b.10.0.0.1.nip.io"
      node_selector_label_value = "tenant-b"
    }
  ]

  node_selector_label_key = "tenant"

  # GPU Operator
  deploy_gpu_operator                = true
  gpu_operator_driver_enabled        = false
  gpu_operator_device_plugin_enabled = true

  # Prometheus Operator
  deploy_prometheus_operator = true

  # Inference (Knative)
  enable_inference = true

  # Optional: CA cert if CP uses self-signed TLS
  # runai_cp_ca_cert = var.runai_cp_ca_cert
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
1. Register each agent with the NVIDIA Run:ai control plane via REST API
2. Create a vCluster per agent with GPU operator, Prometheus CRDs, Knative, and the NVIDIA Run:ai agent
3. Write kubeconfig files for each vCluster

### 3. Access tenant vClusters

```bash
# Using kubeconfig files
export KUBECONFIG=./soft-mt-tenant-a-kubeconfig.yaml
kubectl get nodes   # shows only nodes labeled tenant=tenant-a

# Or via vcluster CLI
vcluster connect soft-mt-tenant-a
```

### Pre-provided cluster credentials

If you already registered clusters with NVIDIA Run:ai (e.g. via the UI), skip auto-registration by providing credentials directly:

```hcl
agents = [
  {
    name          = "tenant-a"
    domain        = "tenant-a.10.0.0.1.nip.io"
    cluster_uid   = "your-cluster-uid"
    client_secret = "your-client-secret"
  }
]
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| helm | ~> 2.0 |
| kubernetes | ~> 2.0 |
| restful | ~> 0.25 |
| tls | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| tls | 4.2.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| agent\_vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | v1.0.0 |
| cluster\_registration | ../_shared/runai-cluster-registration | n/a |

## Resources

| Name | Type |
|------|------|
| [tls_cert_request.inference_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_cert_request.workload_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/cert_request) | resource |
| [tls_locally_signed_cert.inference_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_locally_signed_cert.workload_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/locally_signed_cert) | resource |
| [tls_private_key.inference_ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.inference_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.workload_domain](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_private_key.workload_domain_ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [tls_self_signed_cert.inference_ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |
| [tls_self_signed_cert.workload_domain_ca](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/self_signed_cert) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name prefix for the deployment (e.g. 'soft-mt') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| runai\_admin\_password | Admin password for the NVIDIA Run:ai control plane API | `string` | n/a | yes |
| runai\_cp\_url | URL of the external NVIDIA Run:ai control plane (e.g. https://runai.example.com). Used for REST API calls from terraform. | `string` | n/a | yes |
| runai\_registry\_credentials | Base64-encoded Docker config JSON for the NVIDIA Run:ai registry | `string` | n/a | yes |
| agents | List of cluster agents to register and deploy as vClusters | <pre>list(object({<br/>    name                          = string<br/>    domain                        = string<br/>    workload_domain               = optional(string, "")<br/>    node_selector_label_value     = optional(string, "")<br/>    inference_domain              = optional(string, "")<br/>    inference_service_annotations = optional(map(string), {})<br/>    ingress_service_annotations   = optional(map(string), {})<br/>    cluster_uid                   = optional(string, "")<br/>    # Note: client_secret cannot be marked sensitive inside an object type.<br/>    # Plan output may display this value. Use an encrypted remote backend.<br/>    client_secret = optional(string, "")<br/>  }))</pre> | `[]` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator inside agent vClusters | `bool` | `true` | no |
| deploy\_prometheus\_operator | Deploy kube-prometheus-stack CRDs inside agent vClusters | `bool` | `true` | no |
| enable\_inference | Enable Knative Serving for inference workloads in agent vClusters | `bool` | `true` | no |
| gpu\_operator\_device\_plugin\_enabled | Enable the GPU Operator's device plugin. Set to false when the host already provides one (e.g. GKE) | `bool` | `true` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator | `bool` | `false` | no |
| gpu\_operator\_driver\_install\_dir | Host path where NVIDIA drivers are installed. On GKE with Google-managed drivers use /home/kubernetes/bin/nvidia | `string` | `"/run/nvidia/driver"` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| ha\_replicas | Number of vCluster control plane replicas when HA is enabled | `number` | `3` | no |
| high\_availability | Enable HA for agent vClusters (multiple replicas + embedded etcd) | `bool` | `false` | no |
| host\_kube\_context | Kubeconfig context to use for the host cluster. If empty, uses the current context. | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| knative\_operator\_version | Knative Operator Helm chart version | `string` | `"1.18.0"` | no |
| knative\_serving\_version | Knative Serving version installed by the operator | `string` | `"1.16.3"` | no |
| kube\_prometheus\_stack\_version | kube-prometheus-stack Helm chart version | `string` | `"72.6.2"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| node\_selector\_label\_key | Label key used to assign dedicated host nodes to agent vClusters (e.g. 'tenant') | `string` | `"tenant"` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| raw\_chart\_version | Bedag raw Helm chart version (used to deploy Knative Serving CR) | `string` | `"2.0.2"` | no |
| runai\_admin\_email | Admin email for the NVIDIA Run:ai control plane API | `string` | `"admin@run.ai"` | no |
| runai\_agent\_chart\_repo | Helm chart repository for the NVIDIA Run:ai cluster agent | `string` | `"https://runai.jfrog.io/artifactory/api/helm/run-ai-charts"` | no |
| runai\_chart\_version | NVIDIA Run:ai Helm chart version (used for agent) | `string` | `"2.24.18"` | no |
| runai\_cp\_ca\_cert | Base64-encoded PEM CA certificate for the NVIDIA Run:ai control plane (required when using self-signed TLS) | `string` | `""` | no |
| runai\_cp\_insecure | Skip TLS verification for the NVIDIA Run:ai control plane API | `bool` | `false` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| agent\_vclusters | Map of agent vCluster names to their connection info |
| cluster\_registrations | Map of registered cluster names to their UIDs |
| name | Name prefix for the deployment |
<!-- END_TF_DOCS -->

## State Security

This stack stores sensitive values (client secrets, TLS private keys) in the Terraform state. **Use an encrypted remote backend** (e.g. GCS with customer-managed encryption keys, S3 with SSE-KMS) to protect state at rest. Never use local state files in production.

### Agent object

```hcl
agents = [
  {
    name                      = "tenant-a"         # required — unique tenant name
    domain                    = "a.example.com"    # required — ingress domain for the vCluster
    node_selector_label_value = "tenant-a"         # optional — host nodes must carry this label
    inference_domain          = ""                  # optional — Knative serving domain
    cluster_uid               = ""                  # optional — skip auto-registration
    client_secret             = ""                  # optional — skip auto-registration
  }
]
```

## Troubleshooting

### No nodes visible inside vCluster

This is the most common issue. The vCluster syncs nodes from the host using a label selector.

1. Check host nodes have the label: `kubectl get nodes -l tenant=<value>`
2. If no nodes are returned, the label is missing. Create a labeled node pool or label nodes manually (see [Node labeling](#node-labeling) above).
3. Verify the vCluster is running: `kubectl get pods -n <name>-<agent-name>`
4. Check vCluster logs: `kubectl logs -n <name>-<agent-name> <name>-<agent-name>-0`

### GPU devices not detected

1. Verify host GPU nodes exist: `kubectl get nodes -l nvidia.com/gpu.present=true`
2. Ensure GPU nodes also carry the tenant label: `kubectl get nodes -l tenant=<value>,nvidia.com/gpu.present=true`
3. Check GPU Operator pods inside vCluster: `kubectl --kubeconfig ./<name>-<agent>-kubeconfig.yaml get pods -n gpu-operator`
4. On GKE with Google-managed GPU drivers, set `gpu_operator_driver_enabled = false` and `gpu_operator_driver_install_dir = "/home/kubernetes/bin/nvidia"`

### Agent not connecting to control plane

1. Check the NVIDIA Run:ai agent pods: `kubectl --kubeconfig ./<name>-<agent>-kubeconfig.yaml get pods -n runai`
2. If using self-signed TLS on the CP, ensure `runai_cp_ca_cert` is set correctly
3. Verify the CP URL is reachable from the vCluster: `vcluster connect <name>-<agent> -- curl -sk <runai_cp_url>/api/v1/health`

### HA mode issues

When `high_availability = true`, the vCluster runs with embedded etcd and multiple replicas. Ensure:
- At least `ha_replicas` labeled nodes exist (default: 3)
- Nodes are spread across availability zones for resilience

## Comparison with Hard Multitenancy

| Aspect | Soft Multitenancy (this stack) | Hard Multitenancy |
|---|---|---|
| Control plane | External (shared) | Dedicated vCluster per deployment |
| Agent isolation | vCluster per tenant on shared nodes | vCluster per tenant on private nodes |
| Node provisioning | Shared host node pools with labels | Auto nodes (dedicated GCE VMs) |
| GPU operators | Per-vCluster (sync host devices) | Per-vCluster (full isolation) |
| Host prerequisites | Node pools with tenant labels, RuntimeClass | Minimal (platform + NodeProvider) |
| Resource overhead | Lower | Higher |
| Complexity | Lower | Higher |
| Use case | Trusted tenants, shared infrastructure | Untrusted tenants, strict isolation |
