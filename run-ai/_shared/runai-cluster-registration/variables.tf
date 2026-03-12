variable "api_user" {
  description = "Run:ai API user email for authentication"
  type        = string
  default     = "admin@run.ai"
}

variable "api_password" {
  description = "Run:ai API user password"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name for the cluster to register with Run:ai"
  type        = string

  validation {
    condition     = length(var.cluster_name) > 0
    error_message = "Cluster name must not be empty."
  }
}

variable "cluster_url" {
  description = "External URL for the cluster (e.g. https://agent-1.example.com)"
  type        = string

  validation {
    condition     = can(regex("^https?://", var.cluster_url))
    error_message = "cluster_url must start with http:// or https://."
  }
}

variable "runai_cluster_agent_version" {
  description = "Run:ai cluster agent version for credential retrieval"
  type        = string
  default     = "2.24.18"
}
