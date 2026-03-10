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

output "tenant_ray_dashboard" {
  description = "Ray Dashboard access instructions for each tenant"
  value = {
    for name, vc in module.tenant_vcluster : name => join("\n", [
      "# Connect to ${name} Ray Dashboard",
      "#",
      "# 1. Get the ingress endpoint:",
      "kubectl --kubeconfig ${vc.kubeconfig_path} get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}'",
      "#",
      "# 2. Open the Ray Dashboard in your browser:",
      "# http://<ENDPOINT>.nip.io",
      "#",
      "# 3. Submit jobs via the Ray Jobs API:",
      "# ray job submit --address http://<ENDPOINT>.nip.io -- python my_script.py",
    ])
  }
}
