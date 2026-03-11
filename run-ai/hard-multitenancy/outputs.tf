output "name" {
  description = "Name prefix for the deployment"
  value       = var.name
}

output "control_plane_url" {
  description = "URL of the Run:AI control plane"
  value       = local.cp_url
}

output "cp_vcluster_host" {
  description = "API server endpoint for the CP vCluster"
  value       = module.cp_vcluster.host
}

output "cp_vcluster_kubeconfig_path" {
  description = "Path to the CP vCluster kubeconfig file"
  value       = module.cp_vcluster.kubeconfig_path
}

output "agent_vclusters" {
  description = "Map of agent vCluster names to their connection info"
  value = {
    for name, vc in module.agent_vcluster : name => {
      host            = vc.host
      kubeconfig_path = vc.kubeconfig_path
    }
  }
}

output "runai_admin_password" {
  description = "Run:AI admin password (auto-generated if not provided)"
  value       = local.runai_admin_password
  sensitive   = true
}

output "cluster_registrations" {
  description = "Map of registered cluster names to their UUIDs"
  value = {
    for name, op in restful_operation.create_cluster : name => {
      cluster_uid = op.output.uuid
    }
  }
}

output "inference_domains" {
  description = "Inference endpoint domains per agent (wildcard, points to Kourier LB)"
  value = var.enable_inference ? {
    for a in var.agents : a.name => a.inference_domain != "" ? "*.${a.inference_domain}" : ""
  } : {}
}
