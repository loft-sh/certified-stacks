output "cluster_uid" {
  description = "UUID of the registered cluster"
  value       = restful_operation.cluster.output.uuid
}

output "client_secret" {
  description = "Client secret for the registered cluster"
  value       = restful_operation.credentials.sensitive_output.clientSecret
  sensitive   = true
}
