output "name" {
  description = "Name of the deployed vCluster and Ray.io tenant"
  value       = var.name
}

output "kubeconfig_path" {
  description = "Local file path to the generated vCluster kubeconfig"
  value       = module.vcluster.kubeconfig_path
}

output "cluster_url" {
  description = "External URL of the vCluster"
  value       = local.cluster_url
}

output "vcluster_host" {
  description = "API server host of the created vCluster"
  value       = module.vcluster.host
}

output "vcluster_namespace" {
  description = "Host namespace in which the vCluster is running"
  value       = module.vcluster.namespace
}

output "kuberay_operator_namespace" {
  description = "Namespace where the shared KubeRay operator is deployed"
  value       = var.deploy_kuberay_operator ? "kuberay-system" : ""
}
