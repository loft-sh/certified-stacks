variable "api_user" {
  description = "NVIDIA Run:ai API user email for authentication"
  type        = string
  default     = "admin@run.ai"
}

variable "api_password" {
  description = "NVIDIA Run:ai API user password"
  type        = string
  sensitive   = true
}

variable "cluster_uid" {
  description = "UUID of the NVIDIA Run:ai cluster to create the project in"
  type        = string
}

variable "project_name" {
  description = "Name of the NVIDIA Run:ai project to create"
  type        = string

  validation {
    condition     = length(var.project_name) > 0
    error_message = "Project name must not be empty."
  }
}
