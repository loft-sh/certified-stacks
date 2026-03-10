# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.host_kube_context != "" ? var.host_kube_context : null
}

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.host_kube_context != "" ? var.host_kube_context : null
  }
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  cluster_url    = var.cluster_url != "" ? var.cluster_url : "https://${var.name}.${var.ingress_ip}.nip.io"
  cluster_domain = replace(local.cluster_url, "https://", "")
}

# ---------------------------------------------------------------------------
# KubeRay operator – shared on the host cluster across all tenants
# Docs: https://docs.ray.io/en/latest/cluster/kubernetes/getting-started/kuberay-operator-installation.html
# ---------------------------------------------------------------------------

resource "helm_release" "kuberay_operator" {
  count = var.deploy_kuberay_operator ? 1 : 0

  name             = "kuberay-operator"
  namespace        = "kuberay-system"
  create_namespace = true
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "kuberay-operator"
  version          = var.kuberay_operator_version
  wait             = true
}

# ---------------------------------------------------------------------------
# vCluster – soft-isolated tenant environment; Ray CRDs are synced to the
# host so the shared KubeRay operator can reconcile them.
# ---------------------------------------------------------------------------

module "vcluster" {
  source = "git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster?ref=fc02f7924763a1c1745f25e847a68ed830a62cf8" # v1.0.0

  name                   = var.name
  namespace              = "${var.name}-ns"
  project_name           = var.platform_project_name
  platform_url           = var.platform_url
  platform_access_key    = var.platform_access_key
  platform_insecure      = var.platform_insecure
  chart_version          = var.vcluster_chart_version
  kubeconfig_output_path = "${path.root}/${var.name}-kubeconfig.yaml"

  helm_values = [templatefile("${path.module}/templates/vcluster-values.yaml.tpl", {
    name                 = var.name
    cluster_url          = local.cluster_url
    cluster_domain       = local.cluster_domain
    install_gpu_operator = var.install_gpu_operator
    gpu_operator_version = var.gpu_operator_version
  })]

  depends_on = [helm_release.kuberay_operator]
}
