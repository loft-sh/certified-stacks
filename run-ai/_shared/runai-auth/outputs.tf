output "access_token" {
  description = "Bearer token for NVIDIA Run:ai API requests"
  value       = restful_operation.auth.sensitive_output.accessToken
  sensitive   = true
}
