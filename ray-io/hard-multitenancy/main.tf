provider "kubernetes" {
  config_path    = var.host_kubeconfig_path
  config_context = var.host_kube_context != "" ? var.host_kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = var.host_kubeconfig_path
    config_context = var.host_kube_context != "" ? var.host_kube_context : null
  }
}

# ---------------------------------------------------------------------------
# Tenant vClusters — one per tenant, each with private auto-nodes and a
# dedicated KubeRay operator + optional default RayCluster for full isolation.
#
# Like SkyPilot and Slinky, Ray has no separate control-plane / agent model.
# The KubeRay operator manages RayCluster/RayJob/RayService CRs within a
# single cluster.  Hard multi-tenancy is achieved by giving each tenant its
# own vCluster with dedicated auto-provisioned GPU nodes.
# ---------------------------------------------------------------------------

locals {
  tenant_effective_node_groups = {
    for t in var.tenants : t.name =>
    t.node_groups != null ? t.node_groups : var.node_groups
  }
}

module "tenant_vcluster" {
  for_each = { for t in var.tenants : t.name => t }
  source   = "git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster?ref=fc02f7924763a1c1745f25e847a68ed830a62cf8" # v1.0.0

  name                   = "${var.name}-${each.key}"
  namespace              = "${var.name}-${each.key}"
  project_name           = var.platform_project_name
  platform_url           = var.platform_url
  platform_access_key    = var.platform_access_key
  platform_insecure      = var.platform_insecure
  chart_version          = var.vcluster_chart_version
  kubeconfig_output_path = "${var.kubeconfig_output_dir}/${var.name}-${each.key}-kubeconfig.yaml"
  skip_kubeconfig        = var.skip_kubeconfig

  helm_values = [templatefile("${path.module}/templates/vcluster-values.yaml.tpl", {
    node_provider_name   = var.node_provider_name
    auto_node_properties = var.auto_node_properties
    static_node_groups   = local.tenant_effective_node_groups[each.key].static
    dynamic_node_groups  = local.tenant_effective_node_groups[each.key].dynamic

    deploy_gpu_operator         = var.deploy_gpu_operator
    gpu_operator_version        = var.gpu_operator_version
    gpu_operator_driver_enabled = var.gpu_operator_driver_enabled ? "true" : "false"

    kuberay_version             = var.kuberay_version
    deploy_default_cluster      = var.deploy_default_cluster
    ray_image                   = var.ray_image
    ray_image_tag               = var.ray_version
    worker_replicas             = each.value.worker_replicas
    gpu_per_worker              = each.value.gpu_per_worker
    enable_autoscaling          = each.value.enable_autoscaling
    max_workers                 = each.value.max_workers
    head_service_annotations    = each.value.head_service_annotations
    ingress_service_annotations = each.value.ingress_service_annotations
    ingress_nginx_version       = var.ingress_nginx_version
  })]
}
