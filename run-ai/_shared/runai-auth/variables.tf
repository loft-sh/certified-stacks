variable "api_user" {
  description = "NVIDIA Run:ai API user email for authentication"
  type        = string
  default     = "admin@run.ai"

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.api_user))
    error_message = "Must be a valid email address."
  }
}

variable "api_password" {
  description = "NVIDIA Run:ai API user password"
  type        = string
  sensitive   = true
}
