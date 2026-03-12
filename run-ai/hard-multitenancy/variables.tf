variable "name" {
  description = "Name prefix for the deployment (e.g. 'tenant-alpha')"
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
  description = "Kubeconfig context to use for the host cluster. If empty, uses the current context."
  type        = string
  default     = ""
}

variable "kubeconfig_output_dir" {
  description = "Directory where vCluster kubeconfig files will be written"
  type        = string
  default     = "."
}

variable "platform_url" {
  description = "URL of the vCluster Platform (e.g. https://platform.example.com)"
  type        = string
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

variable "skip_kubeconfig" {
  description = "Skip writing vCluster kubeconfig files to disk"
  type        = bool
  default     = false
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

variable "cp_node_groups" {
  description = "Node groups for the control-plane vCluster (static = always-on, dynamic = autoscaled)"
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
    dynamic = [{
      name       = "cp-pool"
      node_types = []
      limits     = { nodes = 2 }
    }]
  }
}

variable "agent_node_groups" {
  description = "Default node groups for all agent vClusters (overridable per agent)"
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

variable "runai_cp_domain" {
  description = "Domain name for the Run:AI control plane (e.g. runai.10.0.0.1.nip.io)"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z0-9]$", var.runai_cp_domain))
    error_message = "Domain must be a valid hostname."
  }
}

variable "runai_chart_version" {
  description = "Run:AI Helm chart version (used for both CP and agent)"
  type        = string
  default     = "2.24.18"
}

variable "runai_cp_chart_repo" {
  description = "Helm chart repository for the Run:AI control plane"
  type        = string
  default     = "https://runai.jfrog.io/artifactory/cp-charts-prod"
}

variable "runai_agent_chart_repo" {
  description = "Helm chart repository for the Run:AI cluster agent"
  type        = string
  default     = "https://runai.jfrog.io/artifactory/api/helm/run-ai-charts"
}

variable "runai_admin_email" {
  description = "Admin email for initial Run:AI login. Validated by the shared runai-auth module."
  type        = string
  default     = "admin@run.ai"
}

variable "runai_admin_password" {
  description = "Admin password for initial Run:AI login. Auto-generated if not provided."
  type        = string
  default     = null
  sensitive   = true
}

variable "runai_registry_credentials" {
  description = "Base64-encoded Docker config JSON for the Run:AI registry"
  type        = string
  sensitive   = true
}


variable "cp_health_check_retries" {
  description = "Number of retries when waiting for the Run:AI API to become healthy"
  type        = number
  default     = 180
}

variable "cp_health_check_interval" {
  description = "Seconds between health check retries"
  type        = number
  default     = 10
}

variable "cp_static_ip" {
  description = "Pre-reserved static IP for the CP ingress LoadBalancer (leave empty for dynamic)"
  type        = string
  default     = ""
}

variable "cp_ingress_service_annotations" {
  description = "Additional annotations for the CP ingress-nginx LoadBalancer service (e.g. cloud-specific LB configuration)"
  type        = map(string)
  default     = {}
}

variable "agents" {
  description = "List of cluster agents to register and deploy as vClusters"
  type = list(object({
    name                          = string
    domain                        = string
    static_ip                     = optional(string, "")
    inference_static_ip           = optional(string, "")
    inference_domain              = optional(string, "")
    ingress_service_annotations   = optional(map(string), {})
    inference_service_annotations = optional(map(string), {})
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
  }))
  default = []
}

variable "enable_inference" {
  description = "Enable Knative Serving for inference workloads in agent vClusters"
  type        = bool
  default     = true
}

variable "knative_operator_version" {
  description = "Knative Operator Helm chart version"
  type        = string
  default     = "1.18.0"
}

variable "knative_serving_version" {
  description = "Knative Serving version installed by the operator"
  type        = string
  default     = "1.16.3"
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version"
  type        = string
  default     = "4.12.1"
}

variable "raw_chart_version" {
  description = "Bedag raw Helm chart version (used to deploy Knative Serving CR)"
  type        = string
  default     = "2.0.2"
}

variable "deploy_gpu_operator" {
  description = "Deploy NVIDIA GPU Operator in agent vClusters"
  type        = bool
  default     = true
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator Helm chart version"
  type        = string
  default     = "v25.10.1"
}

variable "gpu_operator_driver_enabled" {
  description = "Enable NVIDIA driver installation via GPU Operator"
  type        = bool
  default     = true
}

variable "deploy_prometheus_operator" {
  description = "Deploy Prometheus Operator (CRDs) in agent vClusters"
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "72.6.2"
}

# ---------------------------------------------------------------------------
# TLS Certificate Mode
# ---------------------------------------------------------------------------

variable "tls_mode" {
  description = "TLS certificate mode: 'self-signed' generates certs via Terraform, 'user-provided' uses supplied certs"
  type        = string
  default     = "self-signed"
  validation {
    condition     = contains(["self-signed", "user-provided"], var.tls_mode)
    error_message = "tls_mode must be 'self-signed' or 'user-provided'"
  }
}

variable "user_tls_cert" {
  description = "PEM-encoded TLS certificate (full chain: leaf + CA). Required when tls_mode = 'user-provided'"
  type        = string
  default     = ""
  sensitive   = true
}

variable "user_tls_key" {
  description = "PEM-encoded TLS private key. Required when tls_mode = 'user-provided'"
  type        = string
  default     = ""
  sensitive   = true
}

variable "user_ca_cert" {
  description = "PEM-encoded CA certificate. Required when tls_mode = 'user-provided'"
  type        = string
  default     = ""
  sensitive   = true
}
