# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name for the vCluster and Ray.io tenant (e.g. 'tenant-alpha')"
  type        = string
  validation {
    condition     = length(var.name) > 0 && can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.name))
    error_message = "Name must be non-empty and contain only lowercase alphanumeric characters and hyphens."
  }
}

variable "ingress_ip" {
  description = "IP address of the ingress controller used to construct the default cluster URL via nip.io"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$", var.ingress_ip))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "cluster_url" {
  description = "Explicit URL for the vCluster. When empty, derived as https://<name>.<ingress_ip>.nip.io"
  type        = string
  default     = ""
}

variable "host_kubeconfig_path" {
  description = "Path to the host cluster kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "host_kube_context" {
  description = "Kubernetes context to use from the kubeconfig (empty = current context)"
  type        = string
  default     = ""
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
  description = "Access key for authenticating with the vCluster Platform API"
  type        = string
  sensitive   = true
}

variable "platform_insecure" {
  description = "Skip TLS certificate verification when connecting to the vCluster Platform"
  type        = bool
  default     = false
}

variable "platform_project_name" {
  description = "vCluster Platform project in which to create the vCluster"
  type        = string
  default     = "default"
}

variable "vcluster_chart_version" {
  description = "vCluster Helm chart version to deploy"
  type        = string
  default     = "0.31.0"
}

# ---------------------------------------------------------------------------
# KubeRay Operator (shared on host)
# ---------------------------------------------------------------------------

variable "deploy_kuberay_operator" {
  description = "Deploy the shared KubeRay operator on the host cluster. Set to false if already installed or managed separately."
  type        = bool
  default     = true
}

variable "kuberay_operator_version" {
  description = "KubeRay operator Helm chart version"
  type        = string
  default     = "1.5.1"
}

# ---------------------------------------------------------------------------
# GPU Operator
# ---------------------------------------------------------------------------

variable "install_gpu_operator" {
  description = "Deploy the NVIDIA GPU Operator inside the vCluster"
  type        = bool
  default     = false
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v24.9.1"
}
