# Slinky Hard Multitenancy Stack

Deploys fully isolated Slinky (Slurm on Kubernetes) environments using vCluster Platform. Each tenant receives a dedicated vCluster with its own Slurm cluster, GPU operator, and auto-provisioned private GPU nodes via the vCluster Platform NodeProvider.

## Architecture

```
+--[ Host Kubernetes Cluster ]-----------------------------------------------+
|                                                                             |
|  vCluster Platform (manages vClusters + NodeProvider)                       |
|                                                                             |
|  +--[ vCluster: slinky-tenant-1 ]------+  +--[ vCluster: slinky-N ]----+  |
|  |                                      |  |                             |  |
|  |  cert-manager                        |  |  cert-manager               |  |
|  |  slurm-operator                      |  |  slurm-operator             |  |
|  |  Slurm cluster (full stack)          |  |  Slurm cluster (full stack) |  |
|  |  NVIDIA GPU Operator (with drivers)  |  |  NVIDIA GPU Operator         |  |
|  |  Prometheus Operator (optional)      |  |  Prometheus Operator         |  |
|  |  Slurm Exporter (optional)           |  |  Slurm Exporter              |  |
|  |                                      |  |                             |  |
|  |  Private auto-nodes (GCE VMs)        |  |  Private auto-nodes          |  |
|  |                                      |  |                             |  |
|  +--------------------------------------+  +-----------------------------+  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

Key characteristics:

- **Full isolation** — separate Kubernetes API, etcd, RBAC, and Slurm cluster per tenant.
- **Private auto-nodes** — each tenant gets dedicated auto-provisioned GPU nodes via vCluster Platform NodeProvider (no shared hardware).
- **GPU Operator with driver install** — the GPU Operator installs NVIDIA drivers on the private auto-nodes (unlike soft-MT which uses pre-installed host drivers).
- **Complete Slurm stack** — slurmctld, slurmdbd, slurmd, login, and slurmrestd in each vCluster.
- **SSH access** — each tenant can SSH into their Slurm login nodes. Login service uses LoadBalancer for direct access.

## Host Cluster Prerequisites

The hard-multitenancy stack requires the least from the host cluster since each vCluster runs on its own private nodes.

| Requirement | Details |
|---|---|
| **Kubernetes cluster** | GKE or similar |
| **vCluster Platform** | Running and accessible, with an access key |
| **NodeProvider** | A `gcp-compute` NodeProvider CRD on the host (allows vCluster Platform to provision GCE VMs) |
| **GCP project** | For auto-node provisioning |
| **Terraform** | >= 1.6 |

### Setting up the host with `local/initial-setup/`

The `local/initial-setup/` terraform creates everything the hard-multitenancy stack needs:

```bash
cd local/initial-setup/
terraform init && terraform apply
```

This creates:
- GKE cluster with VPC, node pools, and workload identity
- vCluster Platform with ingress and TLS
- NodeProvider CRD for auto-node provisioning (`gcp-compute`)
- Service account with workload identity for compute provisioning

No labeled node pools are needed (unlike soft-multitenancy) — nodes are auto-provisioned on demand.

## Usage

### 1. Configure variables

```bash
cd slinky/hard-multitenancy/
cat > terraform.tfvars <<'EOF'
name = "slinky"

platform_url          = "https://vc-platform.10.0.0.1.nip.io"
platform_access_key   = "your-access-key"
platform_project_name = "default"
platform_insecure     = true

node_provider_name   = "gcp-compute"
auto_node_properties = {
  project = "my-gcp-project"
  region  = "us-central1"
}

tenants = [
  {
    name                = "tenant-1"
    ssh_authorized_keys = ["ssh-ed25519 AAAA... user@host"]
    worker_replicas     = 2
    login_replicas      = 1
    gpu_per_node        = 1
    gpu_gres            = "gpu:nvidia:1"
  }
]
EOF
```

### 2. Initialize and apply

```bash
terraform init
terraform plan
terraform apply
```

### 3. Access tenant Slurm clusters

```bash
# Get tenant-1 kubeconfig
export KUBECONFIG=./slinky-tenant-1-kubeconfig.yaml

# Check Slurm pods
kubectl get pods -n slurm

# Check private auto-provisioned nodes
kubectl get nodes

# SSH into login node (uses LoadBalancer — get external IP)
kubectl get svc -n slurm slurm-login-login
ssh -i <PATH_TO_SSH_KEY> root@<EXTERNAL_IP>

# Submit a Slurm job
srun --gres=gpu:1 nvidia-smi
```

## Inputs

| Name | Description | Type | Default | Required |
|---|---|---|---|---|
| `name` | Name prefix for the deployment | `string` | — | yes |
| `host_kubeconfig_path` | Path to the host cluster kubeconfig | `string` | `~/.kube/config` | no |
| `kubeconfig_output_dir` | Directory for generated kubeconfig files | `string` | `.` | no |
| `skip_kubeconfig` | Skip writing kubeconfig files to disk | `bool` | `false` | no |
| `platform_url` | URL of the vCluster Platform | `string` | — | yes |
| `platform_access_key` | Access key for the vCluster Platform API | `string` | — | yes |
| `platform_project_name` | vCluster Platform project | `string` | `"default"` | no |
| `platform_insecure` | Skip TLS verification for the platform | `bool` | `false` | no |
| `vcluster_chart_version` | vCluster Helm chart version | `string` | `"0.31.0"` | no |
| `node_provider_name` | NodeProvider name for auto nodes | `string` | `""` | no |
| `auto_node_properties` | Properties for auto-provisioned nodes (e.g. project, region) | `map(string)` | `{}` | no |
| `node_groups` | Node groups for tenants (static + dynamic) | `object` | see defaults | no |
| `tenants` | List of tenants (see below) | `list(object)` | `[]` | no |
| `slinky_version` | Slinky slurm-operator version | `string` | `"1.0.2"` | no |
| `cert_manager_version` | cert-manager Helm chart version | `string` | `"v1.19.4"` | no |
| `deploy_gpu_operator` | Deploy NVIDIA GPU Operator | `bool` | `true` | no |
| `gpu_operator_version` | GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| `gpu_operator_driver_enabled` | Install GPU drivers on auto-nodes | `bool` | `true` | no |
| `deploy_prometheus_operator` | Deploy Prometheus Operator CRDs | `bool` | `true` | no |
| `deploy_slurm_exporter` | Deploy Slurm Prometheus exporter | `bool` | `true` | no |

### Tenant object

```hcl
tenants = [
  {
    name                = "team-alpha"             # required
    ssh_authorized_keys = ["ssh-ed25519 AAAA..."]  # optional — SSH keys for login nodes
    worker_replicas     = 2                        # optional — slurmd worker count
    login_replicas      = 1                        # optional — login node count
    gpu_per_node        = 1                        # optional — GPUs per worker
    gpu_gres            = "gpu:nvidia:1"           # optional — Slurm GRES string
    partition_name      = "gpu"                    # optional — Slurm partition name
  }
]
```

## Outputs

| Name | Description |
|---|---|
| `name` | Name prefix for the deployment |
| `tenant_vclusters` | Map of tenant names to `{ host, kubeconfig_path }` |
| `tenant_ssh_access` | SSH access instructions for each tenant's login nodes |

## Troubleshooting

### Auto nodes not provisioning

1. Verify the NodeProvider CRD exists: `kubectl get nodeprovider gcp-compute`
2. Check vCluster Platform logs: `kubectl logs -n vcluster-platform deploy/loft`
3. Verify GCP IAM: the platform service account needs `compute.admin` and `iam.serviceAccountUser` roles

### GPU Operator pods crashing

The GPU Operator installs drivers on private auto-nodes (`driver.enabled=true`). If pods crash:

1. Check GPU Operator logs: `kubectl logs -n gpu-operator deploy/gpu-operator`
2. Verify the auto-nodes have GPU hardware attached
3. Check node runtime: the operator defaults to `containerd`

### Slurm workers stuck in Pending

Workers need GPU resources from auto-provisioned nodes. If stuck:

1. Check if auto-nodes are provisioned: `kubectl get nodes` (in the tenant vCluster)
2. Check `auto_node_limit` — workers can't start if the node limit is too low
3. Verify `gpu_per_node` matches available GPUs on the auto-node instance type

## Comparison with Soft Multitenancy

| Aspect | Hard Multitenancy (this stack) | Soft Multitenancy |
|---|---|---|
| Slurm components | Dedicated per tenant vCluster | Dedicated per tenant vCluster |
| GPU nodes | Private auto-provisioned nodes | Shared host nodes (by label) |
| GPU drivers | Per-vCluster (GPU Operator installs) | Host-installed (shared) |
| Node provisioning | Auto nodes via NodeProvider | Pre-existing labeled node pools |
| Login service | LoadBalancer (direct SSH) | ClusterIP (port-forward SSH) |
| Isolation model | Separate K8s API + hardware | Separate K8s API, shared hardware |
| Host prerequisites | Platform + NodeProvider only | Labeled node pools with GPU drivers |
| Resource overhead | Higher (dedicated VMs) | Lower (shared infrastructure) |
| Use case | Untrusted tenants, strict isolation | Trusted tenants, cost efficiency |

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
| name | Name prefix for the deployment (e.g. 'slinky-prod') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| auto\_node\_properties | Properties passed to each autoNodes entry (e.g. {region = "us-east-1"} for AWS, {project = "my-proj", region = "us-central1"} for GCP) | `map(string)` | `{}` | no |
| cert\_manager\_version | cert-manager Helm chart version (required by slurm-operator) | `string` | `"v1.19.4"` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator in tenant vClusters | `bool` | `true` | no |
| deploy\_prometheus\_operator | Deploy Prometheus Operator (CRDs) in tenant vClusters for Slurm metrics | `bool` | `true` | no |
| deploy\_slurm\_exporter | Deploy Slinky Prometheus exporter for Slurm metrics | `bool` | `true` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator (true for private auto-nodes) | `bool` | `true` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| host\_kube\_context | Kubernetes context to use from the kubeconfig (empty = current context) | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| kube\_prometheus\_stack\_version | kube-prometheus-stack Helm chart version | `string` | `"82.4.0"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| node\_groups | Node groups for tenant vClusters (static = always-on, dynamic = autoscaled) | <pre>object({<br/>    static = optional(list(object({<br/>      name       = string<br/>      quantity   = number<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>    })), [])<br/>    dynamic = optional(list(object({<br/>      name       = string<br/>      node_types = optional(list(string), [])<br/>      labels     = optional(map(string), {})<br/>      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>    })), [])<br/>  })</pre> | <pre>{<br/>  "dynamic": [<br/>    {<br/>      "name": "cpu-pool",<br/>      "node_types": []<br/>    },<br/>    {<br/>      "limits": {<br/>        "nodes": 5<br/>      },<br/>      "name": "gpu-pool",<br/>      "node_types": []<br/>    }<br/>  ]<br/>}</pre> | no |
| node\_provider\_name | Name of the NodeProvider configured in vCluster Platform for auto nodes | `string` | `""` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| slinky\_version | Slinky slurm-operator and Slurm chart version | `string` | `"1.0.2"` | no |
| slurm\_exporter\_version | Slinky slurm-exporter Helm chart version (independent release cycle from slurm-operator) | `string` | `"0.4.1"` | no |
| tenants | List of tenants, each deployed as an isolated vCluster with private nodes and a full Slurm cluster | <pre>list(object({<br/>    name                = string<br/>    ssh_authorized_keys = optional(list(string), [])<br/>    worker_replicas     = optional(number, 2)<br/>    login_replicas      = optional(number, 1)<br/>    gpu_per_node        = optional(number, 1)<br/>    gpu_gres            = optional(string, "gpu:nvidia:1")<br/>    partition_name      = optional(string, "gpu")<br/>    node_groups = optional(object({<br/>      static = optional(list(object({<br/>        name       = string<br/>        quantity   = number<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>      })), [])<br/>      dynamic = optional(list(object({<br/>        name       = string<br/>        node_types = optional(list(string), [])<br/>        labels     = optional(map(string), {})<br/>        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])<br/>        limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))<br/>      })), [])<br/>    }))<br/>    login_service_annotations = optional(map(string), {})<br/>  }))</pre> | `[]` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| name | Name prefix for the deployment |
| tenant\_ssh\_access | SSH access instructions for each tenant's Slurm login nodes |
| tenant\_vclusters | Map of tenant vCluster names to their connection info |
<!-- END_TF_DOCS -->