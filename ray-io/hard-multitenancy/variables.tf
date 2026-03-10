# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for the deployment (e.g. 'ray-prod')"
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
# Tenants — each gets an isolated vCluster with a dedicated KubeRay operator
# ---------------------------------------------------------------------------

variable "tenants" {
  description = "List of tenants, each deployed as an isolated vCluster with private nodes and a dedicated KubeRay operator"
  type = list(object({
    name               = string
    worker_replicas    = optional(number, 1)
    gpu_per_worker     = optional(number, 1)
    enable_autoscaling = optional(bool, false)
    max_workers        = optional(number, 5)
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
    head_service_annotations    = optional(map(string), {})
    ingress_service_annotations = optional(map(string), {})
  }))
  default = []
  validation {
    condition     = length(var.tenants) == length(distinct([for t in var.tenants : t.name]))
    error_message = "Tenant names must be unique."
  }
}

# ---------------------------------------------------------------------------
# KubeRay
# ---------------------------------------------------------------------------

variable "kuberay_version" {
  description = "KubeRay operator and ray-cluster Helm chart version"
  type        = string
  default     = "1.5.1"
}

variable "ray_version" {
  description = "Ray container image tag (e.g. '2.54.0'). GPU workers automatically use the '-gpu' suffix."
  type        = string
  default     = "2.54.0"
}

variable "ray_image" {
  description = "Ray container image repository"
  type        = string
  default     = "rayproject/ray"
}

variable "deploy_default_cluster" {
  description = "Deploy a default RayCluster in each tenant vCluster"
  type        = bool
  default     = true
}

variable "ingress_nginx_version" {
  description = "Ingress NGINX Helm chart version"
  type        = string
  default     = "4.12.1"
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
