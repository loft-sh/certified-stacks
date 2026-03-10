# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for the deployment (e.g. 'slinky-prod')"
  type        = string
  validation {
    condition     = length(var.name) > 0
    error_message = "Name must not be empty."
  }
}

variable "host_kubeconfig_path" {
  description = "Path to the host cluster kubeconfig"
  type        = string
  default     = "~/.kube/config"
}

variable "host_kube_context" {
  description = "Kubernetes context to use from the kubeconfig (empty = current context)"
  type        = string
  default     = ""
}

variable "kubeconfig_output_dir" {
  description = "Directory where vCluster kubeconfig files will be written"
  type        = string
  default     = "."
}

variable "skip_kubeconfig" {
  description = "Skip writing vCluster kubeconfig files to disk"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# vCluster Platform
# ---------------------------------------------------------------------------

variable "platform_url" {
  description = "URL of the vCluster Platform (e.g. https://platform.example.com)"
  type        = string
  validation {
    condition     = can(regex("^https?://", var.platform_url))
    error_message = "platform_url must start with http:// or https://"
  }
}

variable "platform_access_key" {
  description = "Access key for the vCluster Platform API"
  type        = string
  sensitive   = true
}

variable "platform_project_name" {
  description = "vCluster Platform project to deploy into"
  type        = string
  default     = "default"
}

variable "platform_insecure" {
  description = "Skip TLS verification for the vCluster Platform API"
  type        = bool
  default     = false
}

variable "vcluster_chart_version" {
  description = "vCluster Helm chart version"
  type        = string
  default     = "0.31.0"
}

# ---------------------------------------------------------------------------
# Auto Nodes (private dedicated nodes)
# ---------------------------------------------------------------------------

variable "node_provider_name" {
  description = "Name of the NodeProvider configured in vCluster Platform for auto nodes"
  type        = string
  default     = ""
}

variable "auto_node_properties" {
  description = "Properties passed to each autoNodes entry (e.g. {region = \"us-east-1\"} for AWS, {project = \"my-proj\", region = \"us-central1\"} for GCP)"
  type        = map(string)
  default     = {}
}

variable "node_groups" {
  description = "Node groups for tenant vClusters (static = always-on, dynamic = autoscaled)"
  type = object({
    static = optional(list(object({
      name       = string
      quantity   = number
      node_types = optional(list(string), [])
      labels     = optional(map(string), {})
      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])
    })), [])
    dynamic = optional(list(object({
      name       = string
      node_types = optional(list(string), [])
      labels     = optional(map(string), {})
      taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])
      limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))
    })), [])
  })
  default = {
    dynamic = [
      {
        name       = "cpu-pool"
        node_types = []
      },
      {
        name       = "gpu-pool"
        node_types = []
        limits     = { nodes = 5 }
      }
    ]
  }
}

# ---------------------------------------------------------------------------
# Tenants – each gets an isolated vCluster with a full Slinky deployment
# ---------------------------------------------------------------------------

variable "tenants" {
  description = "List of tenants, each deployed as an isolated vCluster with private nodes and a full Slurm cluster"
  type = list(object({
    name                = string
    ssh_authorized_keys = optional(list(string), [])
    worker_replicas     = optional(number, 2)
    login_replicas      = optional(number, 1)
    gpu_per_node        = optional(number, 1)
    gpu_gres            = optional(string, "gpu:nvidia:1")
    partition_name      = optional(string, "gpu")
    node_groups = optional(object({
      static = optional(list(object({
        name       = string
        quantity   = number
        node_types = optional(list(string), [])
        labels     = optional(map(string), {})
        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])
      })), [])
      dynamic = optional(list(object({
        name       = string
        node_types = optional(list(string), [])
        labels     = optional(map(string), {})
        taints     = optional(list(object({ key = string, value = optional(string, ""), effect = string })), [])
        limits     = optional(object({ nodes = optional(number), cpu = optional(number), memory = optional(string) }))
      })), [])
    }))
    login_service_annotations = optional(map(string), {})
  }))
  default = []
  validation {
    condition     = length(var.tenants) == length(distinct([for t in var.tenants : t.name]))
    error_message = "Tenant names must be unique."
  }
}

# ---------------------------------------------------------------------------
# Slinky (Slurm on Kubernetes)
# ---------------------------------------------------------------------------

variable "slinky_version" {
  description = "Slinky slurm-operator and Slurm chart version"
  type        = string
  default     = "1.0.2"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version (required by slurm-operator)"
  type        = string
  default     = "v1.19.4"
}

# ---------------------------------------------------------------------------
# NVIDIA GPU Operator
# ---------------------------------------------------------------------------

variable "deploy_gpu_operator" {
  description = "Deploy NVIDIA GPU Operator in tenant vClusters"
  type        = bool
  default     = true
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v25.10.1"
}

variable "gpu_operator_driver_enabled" {
  description = "Enable NVIDIA driver installation via GPU Operator (true for private auto-nodes)"
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Prometheus Operator
# ---------------------------------------------------------------------------

variable "deploy_prometheus_operator" {
  description = "Deploy Prometheus Operator (CRDs) in tenant vClusters for Slurm metrics"
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "82.4.0"
}

# ---------------------------------------------------------------------------
# Slurm Exporter
# ---------------------------------------------------------------------------

variable "deploy_slurm_exporter" {
  description = "Deploy Slinky Prometheus exporter for Slurm metrics"
  type        = bool
  default     = true
}

variable "slurm_exporter_version" {
  description = "Slinky slurm-exporter Helm chart version (independent release cycle from slurm-operator)"
  type        = string
  default     = "0.4.1"
}
