# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for the deployment (e.g. 'slinky-soft')"
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
# Node Selection
# ---------------------------------------------------------------------------

variable "node_selector_label_key" {
  description = "Label key used to assign dedicated host nodes to tenant vClusters (e.g. 'tenant')"
  type        = string
  default     = "tenant"
}

# ---------------------------------------------------------------------------
# Tenants – each gets an isolated vCluster with a full Slinky deployment
# ---------------------------------------------------------------------------

variable "tenants" {
  description = "List of tenants, each deployed as a vCluster with Slurm on shared host nodes"
  type = list(object({
    name                      = string
    node_selector_label_value = optional(string, "")
    ssh_authorized_keys       = optional(list(string), [])
    worker_replicas           = optional(number, 2)
    login_replicas            = optional(number, 1)
    gpu_per_node              = optional(number, 1)
    gpu_gres                  = optional(string, "gpu:nvidia:1")
    partition_name            = optional(string, "gpu")
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
  description = "Enable NVIDIA driver installation via GPU Operator (false for shared host drivers)"
  type        = bool
  default     = false
}

variable "gpu_operator_device_plugin_enabled" {
  description = "Enable the GPU Operator's device plugin. Set to false when the host already provides one (e.g. GKE)"
  type        = bool
  default     = true
}

variable "gpu_operator_driver_install_dir" {
  description = "Host path where NVIDIA drivers are installed. On GKE with Google-managed drivers use /home/kubernetes/bin/nvidia"
  type        = string
  default     = "/home/kubernetes/bin/nvidia"
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
