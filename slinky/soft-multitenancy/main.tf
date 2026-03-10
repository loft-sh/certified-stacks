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
# Host prerequisites – NVIDIA RuntimeClass for GPU workloads
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "nvidia_runtime_class" {
  count = var.deploy_gpu_operator ? 1 : 0

  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "nvidia"
    }
    handler = "nvidia"
  }
}

# ---------------------------------------------------------------------------
# Tenant vClusters – one per tenant, each with a full Slinky (Slurm)
# deployment running on shared host nodes selected by label.
# ---------------------------------------------------------------------------

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
    tenant_name                        = "${var.name}-${each.key}"
    node_selector_label_key            = var.node_selector_label_key
    node_selector_label_value          = each.value.node_selector_label_value
    ssh_authorized_keys                = each.value.ssh_authorized_keys
    deploy_gpu_operator                = var.deploy_gpu_operator
    gpu_operator_version               = var.gpu_operator_version
    gpu_operator_driver_enabled        = var.gpu_operator_driver_enabled ? "true" : "false"
    gpu_operator_device_plugin_enabled = var.gpu_operator_device_plugin_enabled
    gpu_operator_driver_install_dir    = var.gpu_operator_driver_install_dir
    deploy_prometheus_operator         = var.deploy_prometheus_operator
    kube_prometheus_stack_version      = var.kube_prometheus_stack_version
    deploy_slurm_exporter              = var.deploy_slurm_exporter
    slurm_exporter_version             = var.slurm_exporter_version
    cert_manager_version               = var.cert_manager_version
    slinky_version                     = var.slinky_version
    slurm_cluster_name                 = each.key
    partition_name                     = each.value.partition_name
    gpu_gres                           = each.value.gpu_gres
    gpu_per_node                       = each.value.gpu_per_node
    worker_replicas                    = each.value.worker_replicas
    login_replicas                     = each.value.login_replicas
  })]
}
