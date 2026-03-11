output "name" {
  description = "Name prefix for the deployment"
  value       = var.name
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

output "cluster_registrations" {
  description = "Map of registered cluster names to their UIDs"
  value = {
    for name, reg in module.cluster_registration : name => {
      cluster_uid = reg.cluster_uid
    }
  }
}

