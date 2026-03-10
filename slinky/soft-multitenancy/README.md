# Slinky Soft Multitenancy Stack

Deploys multi-tenant Slinky (Slurm on Kubernetes) environments using vCluster with **soft isolation**. Each tenant gets a dedicated vCluster with its own Slurm cluster, but all vClusters share the same host nodes. Node syncing with label selectors assigns specific host nodes to each tenant.

## Architecture

```
+--[ Host Kubernetes Cluster ]-----------------------------------------------+
|                                                                             |
|  Host nodes labeled "tenant=slinky-tenant-1"    (synced into vCluster 1)   |
|  Host nodes labeled "tenant=slinky-tenant-2"    (synced into vCluster 2)   |
|  NVIDIA RuntimeClass "nvidia"                                               |
|                                                                             |
|  +--[ vCluster: slinky-soft-tenant-1 ]----+  +--[ vCluster: tenant-N ]--+  |
|  |                                         |  |                          |  |
|  |  cert-manager                           |  |  cert-manager            |  |
|  |  slurm-operator                         |  |  slurm-operator          |  |
|  |  Slurm cluster (full stack)             |  |  Slurm cluster           |  |
|  |  NVIDIA GPU Operator (host drivers)     |  |  NVIDIA GPU Operator     |  |
|  |  Prometheus Operator (optional)         |  |  Prometheus Operator     |  |
|  |  Slurm Exporter (optional)              |  |  Slurm Exporter          |  |
|  |                                         |  |                          |  |
|  |  Synced host nodes (by label)           |  |  Synced host nodes       |  |
|  |                                         |  |                          |  |
|  +-----------------------------------------+  +--------------------------+  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

Key characteristics:

- **Per-tenant vClusters** — each tenant gets its own Kubernetes API, RBAC, and Slurm cluster.
- **Shared host nodes** — nodes are synced from the host cluster into vClusters using label selectors (no auto-provisioned VMs).
- **GPU Operator with host drivers** — the GPU Operator runs inside each vCluster but uses pre-installed host drivers (driver install disabled).
- **Complete Slurm stack** — slurmctld, slurmdbd, slurmd, login, and slurmrestd per tenant.
- **SSH access** — each tenant can SSH into their Slurm login nodes via port-forward.

## Host Cluster Prerequisites

| Requirement | Details |
|---|---|
| **Kubernetes cluster** | GKE, EKS, or similar with GPU nodes |
| **vCluster Platform** | Running and accessible, with an access key |
| **Labeled node pools** | Each tenant needs host nodes labeled `tenant=<value>` |
| **NVIDIA drivers** | Pre-installed on host nodes (the GPU Operator inside vClusters does not install drivers) |
| **Terraform** | >= 1.6 |

### Setting up labeled node pools with `local/initial-setup/`

The host cluster must have node pools with tenant labels. Add entries to `local/initial-setup/terraform.tfvars`:

```hcl
tenant_node_pools = [
  {
    name         = "slinky-tenant-1"
    tenant_label = "slinky-tenant-1"
    machine_type = "n1-standard-4"    # optional, default: e2-standard-8
    node_count   = 1                  # optional, default: 1
  }
]
```

Then apply:

```bash
cd local/initial-setup/
terraform init && terraform apply
```

This creates GKE node pools with `tenant=slinky-tenant-1` labels baked in. The vCluster node sync selector (`sync.fromHost.nodes.selector.labels.tenant`) picks up these nodes automatically.

## Usage

### 1. Configure variables

```bash
cd slinky/soft-multitenancy/
cat > terraform.tfvars <<'EOF'
name = "slinky-soft"

platform_url          = "https://vc-platform.10.0.0.1.nip.io"
platform_access_key   = "your-access-key"
platform_project_name = "default"
platform_insecure     = true

deploy_gpu_operator                = true
gpu_operator_driver_enabled        = false
gpu_operator_device_plugin_enabled = true
gpu_operator_driver_install_dir    = "/home/kubernetes/bin/nvidia"

deploy_prometheus_operator = true
deploy_slurm_exporter      = true

tenants = [
  {
    name                      = "tenant-1"
    node_selector_label_value = "slinky-tenant-1"
    ssh_authorized_keys       = ["ssh-ed25519 AAAA... user@host"]
    worker_replicas           = 2
    login_replicas            = 1
    gpu_per_node              = 1
    gpu_gres                  = "gpu:nvidia:1"
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
export KUBECONFIG=./slinky-soft-tenant-1-kubeconfig.yaml

# Check Slurm pods
kubectl get pods -n slurm

# Verify synced host nodes
kubectl get nodes --show-labels

# SSH into login node
kubectl port-forward -n slurm svc/slurm-login-login 2222:22 &
ssh -i <PATH_TO_SSH_KEY> -p 2222 root@127.0.0.1

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
| `node_selector_label_key` | Label key for node selection | `string` | `"tenant"` | no |
| `tenants` | List of tenants (see below) | `list(object)` | `[]` | no |
| `slinky_version` | Slinky slurm-operator version | `string` | `"1.0.2"` | no |
| `cert_manager_version` | cert-manager Helm chart version | `string` | `"v1.19.4"` | no |
| `deploy_gpu_operator` | Deploy NVIDIA GPU Operator | `bool` | `true` | no |
| `gpu_operator_version` | GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| `gpu_operator_driver_enabled` | Install GPU drivers (false for host drivers) | `bool` | `false` | no |
| `gpu_operator_device_plugin_enabled` | Enable device plugin | `bool` | `true` | no |
| `gpu_operator_driver_install_dir` | Host path to NVIDIA drivers | `string` | `"/home/kubernetes/bin/nvidia"` | no |
| `deploy_prometheus_operator` | Deploy Prometheus Operator CRDs | `bool` | `true` | no |
| `deploy_slurm_exporter` | Deploy Slurm Prometheus exporter | `bool` | `true` | no |

### Tenant object

```hcl
tenants = [
  {
    name                      = "team-alpha"             # required
    node_selector_label_value = "slinky-team-alpha"      # optional — matches host node label
    ssh_authorized_keys       = ["ssh-ed25519 AAAA..."]  # optional — SSH keys for login nodes
    worker_replicas           = 2                        # optional — slurmd worker count
    login_replicas            = 1                        # optional — login node count
    gpu_per_node              = 1                        # optional — GPUs per worker
    gpu_gres                  = "gpu:nvidia:1"           # optional — Slurm GRES string
    partition_name            = "gpu"                    # optional — Slurm partition name
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

### Nodes not appearing in vCluster

The vCluster syncs host nodes that match `tenant=<node_selector_label_value>`. If no nodes appear:

1. Verify host nodes have the label: `kubectl get nodes -l tenant=slinky-tenant-1`
2. Check the vCluster is running: `kubectl get pods -n slinky-soft-tenant-1`
3. If using `local/initial-setup/`, verify the node pool was created: `gcloud container node-pools list --cluster=vcluster-platform --region=us-central1`

### GPU Operator pods crashing

The GPU Operator runs with `driver.enabled=false` since it uses pre-installed host drivers. If pods crash:

1. Verify drivers on host: `kubectl exec -it <gpu-node-pod> -- nvidia-smi`
2. Check `gpu_operator_driver_install_dir` matches the actual host path (GKE: `/home/kubernetes/bin/nvidia`)
3. Ensure the NVIDIA RuntimeClass exists on the host cluster

### Slurm workers stuck in Pending

Workers need GPU resources. If stuck:

1. Check node capacity: `kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.capacity.'nvidia\.com/gpu'`
2. Verify `gpu_per_node` doesn't exceed available GPUs per host node
3. Check GPU Operator pods are running: `kubectl get pods -n gpu-operator`

## Comparison with Hard Multitenancy

| Aspect | Soft Multitenancy (this stack) | Hard Multitenancy |
|---|---|---|
| Slurm components | Dedicated per tenant vCluster | Dedicated per tenant vCluster |
| GPU nodes | Shared host nodes (by label) | Private auto-provisioned nodes |
| GPU drivers | Host-installed (shared) | Per-vCluster (GPU Operator installs) |
| Node provisioning | Pre-existing labeled node pools | Auto nodes via NodeProvider |
| Isolation model | Separate K8s API, shared hardware | Separate K8s API + hardware |
| Host prerequisites | Labeled node pools with GPU drivers | Platform + NodeProvider only |
| Resource overhead | Lower (shared infrastructure) | Higher (dedicated VMs) |
| Use case | Trusted tenants, cost efficiency | Untrusted tenants, strict isolation |

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
| kubernetes | ~> 2.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| tenant\_vcluster | git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster | fc02f7924763a1c1745f25e847a68ed830a62cf8 |

## Resources

| Name | Type |
|------|------|
| [kubernetes_manifest.nvidia_runtime_class](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name prefix for the deployment (e.g. 'slinky-soft') | `string` | n/a | yes |
| platform\_access\_key | Access key for the vCluster Platform API | `string` | n/a | yes |
| platform\_url | URL of the vCluster Platform (e.g. https://platform.example.com) | `string` | n/a | yes |
| cert\_manager\_version | cert-manager Helm chart version (required by slurm-operator) | `string` | `"v1.19.4"` | no |
| deploy\_gpu\_operator | Deploy NVIDIA GPU Operator in tenant vClusters | `bool` | `true` | no |
| deploy\_prometheus\_operator | Deploy Prometheus Operator (CRDs) in tenant vClusters for Slurm metrics | `bool` | `true` | no |
| deploy\_slurm\_exporter | Deploy Slinky Prometheus exporter for Slurm metrics | `bool` | `true` | no |
| gpu\_operator\_device\_plugin\_enabled | Enable the GPU Operator's device plugin. Set to false when the host already provides one (e.g. GKE) | `bool` | `true` | no |
| gpu\_operator\_driver\_enabled | Enable NVIDIA driver installation via GPU Operator (false for shared host drivers) | `bool` | `false` | no |
| gpu\_operator\_driver\_install\_dir | Host path where NVIDIA drivers are installed. On GKE with Google-managed drivers use /home/kubernetes/bin/nvidia | `string` | `"/home/kubernetes/bin/nvidia"` | no |
| gpu\_operator\_version | NVIDIA GPU Operator Helm chart version | `string` | `"v25.10.1"` | no |
| host\_kube\_context | Kubernetes context to use from the kubeconfig (empty = current context) | `string` | `""` | no |
| host\_kubeconfig\_path | Path to the host cluster kubeconfig | `string` | `"~/.kube/config"` | no |
| kube\_prometheus\_stack\_version | kube-prometheus-stack Helm chart version | `string` | `"82.4.0"` | no |
| kubeconfig\_output\_dir | Directory where vCluster kubeconfig files will be written | `string` | `"."` | no |
| node\_selector\_label\_key | Label key used to assign dedicated host nodes to tenant vClusters (e.g. 'tenant') | `string` | `"tenant"` | no |
| platform\_insecure | Skip TLS verification for the vCluster Platform API | `bool` | `false` | no |
| platform\_project\_name | vCluster Platform project to deploy into | `string` | `"default"` | no |
| skip\_kubeconfig | Skip writing vCluster kubeconfig files to disk | `bool` | `false` | no |
| slinky\_version | Slinky slurm-operator and Slurm chart version | `string` | `"1.0.2"` | no |
| slurm\_exporter\_version | Slinky slurm-exporter Helm chart version (independent release cycle from slurm-operator) | `string` | `"0.4.1"` | no |
| tenants | List of tenants, each deployed as a vCluster with Slurm on shared host nodes | <pre>list(object({<br/>    name                      = string<br/>    node_selector_label_value = optional(string, "")<br/>    ssh_authorized_keys       = optional(list(string), [])<br/>    worker_replicas           = optional(number, 2)<br/>    login_replicas            = optional(number, 1)<br/>    gpu_per_node              = optional(number, 1)<br/>    gpu_gres                  = optional(string, "gpu:nvidia:1")<br/>    partition_name            = optional(string, "gpu")<br/>  }))</pre> | `[]` | no |
| vcluster\_chart\_version | vCluster Helm chart version | `string` | `"0.31.0"` | no |

## Outputs

| Name | Description |
|------|-------------|
| name | Name prefix for the deployment |
| tenant\_ssh\_access | SSH access instructions for each tenant's Slurm login nodes |
| tenant\_vclusters | Map of tenant vCluster names to their connection info |
<!-- END_TF_DOCS -->