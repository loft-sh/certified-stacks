output "name" {
  description = "Name prefix for the deployment"
  value       = var.name
}

output "tenant_vclusters" {
  description = "Map of tenant vCluster names to their connection info"
  value = {
    for name, vc in module.tenant_vcluster : name => {
      host            = vc.host
      kubeconfig_path = vc.kubeconfig_path
    }
  }
}

output "tenant_ssh_access" {
  description = "SSH access instructions for each tenant's Slurm login nodes"
  value = {
    for name, vc in module.tenant_vcluster : name => join("\n", [
      "# SSH into ${name} Slurm login node",
      "#",
      "# The login service is exposed via LoadBalancer. If the external IP is public,",
      "# restrict access with a firewall rule to trusted source IPs.",
      "#",
      "# Alternatively, use kubectl port-forward for private access:",
      "#",
      "# 1. Start the port-forward (runs in background):",
      "kubectl --kubeconfig ${vc.kubeconfig_path} port-forward -n slurm svc/slurm-login-login 2222:22 &",
      "#",
      "# 2. SSH into the login node:",
      "ssh -i <PATH_TO_SSH_KEY> -p 2222 root@127.0.0.1",
    ])
  }
}
