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

output "tenant_skypilot_access" {
  description = "SkyPilot API server access instructions for each tenant"
  value = {
    for name, vc in module.tenant_vcluster : name => join("\n", [
      "# Connect to ${name} SkyPilot API server",
      "#",
      "# 1. Get the SkyPilot ingress endpoint:",
      "kubectl --kubeconfig ${vc.kubeconfig_path} get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}'",
      "#",
      "# 2. Point the SkyPilot CLI at the endpoint:",
      "sky api login -e http://<ENDPOINT>",
    ])
  }
}
