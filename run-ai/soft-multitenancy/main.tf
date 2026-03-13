# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

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

provider "restful" {
  base_url = var.runai_cp_url
  client = {
    tls_insecure_skip_verify = var.runai_cp_insecure
    retry = {
      status_codes    = [0, 502, 503, 504]
      count           = 30
      wait_in_sec     = 10
      max_wait_in_sec = 30
    }
  }
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  cp_domain = replace(replace(var.runai_cp_url, "https://", ""), "http://", "")

  agents_map = { for a in var.agents : a.name => a }

  # Only register agents that don't have pre-provided credentials
  agents_to_register = {
    for a in var.agents : a.name => a
    if a.cluster_uid == ""
  }

  # Resolve cluster credentials: pre-provided or from registration
  agent_credentials = {
    for name, a in local.agents_map : name => {
      cluster_uid   = a.cluster_uid != "" ? a.cluster_uid : module.cluster_registration[name].cluster_uid
      client_secret = a.client_secret != "" ? a.client_secret : module.cluster_registration[name].client_secret
    }
  }
}

# ---------------------------------------------------------------------------
# TLS – self-signed certificates for workload domains (NVIDIA Run:ai ingress-nginx)
# ---------------------------------------------------------------------------

locals {
  has_workload_domain = anytrue([for a in var.agents : a.workload_domain != ""])
}

resource "tls_private_key" "workload_domain_ca" {
  count     = local.has_workload_domain ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "workload_domain_ca" {
  count           = local.has_workload_domain ? 1 : 0
  private_key_pem = tls_private_key.workload_domain_ca[0].private_key_pem
  subject {
    common_name = "NVIDIA Run:ai Workload Domain CA"
  }
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "workload_domain" {
  for_each  = { for a in var.agents : a.name => a if a.workload_domain != "" }
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "workload_domain" {
  for_each        = { for a in var.agents : a.name => a if a.workload_domain != "" }
  private_key_pem = tls_private_key.workload_domain[each.key].private_key_pem
  subject {
    common_name = each.value.workload_domain
  }
  dns_names = [each.value.workload_domain, "*.${each.value.workload_domain}"]
}

resource "tls_locally_signed_cert" "workload_domain" {
  for_each           = { for a in var.agents : a.name => a if a.workload_domain != "" }
  cert_request_pem   = tls_cert_request.workload_domain[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.workload_domain_ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.workload_domain_ca[0].cert_pem

  validity_period_hours = 8760
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

# ---------------------------------------------------------------------------
# TLS – self-signed certificates for inference (Kourier HTTPS)
# ---------------------------------------------------------------------------

resource "tls_private_key" "inference_ca" {
  count     = var.enable_inference ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "inference_ca" {
  count           = var.enable_inference ? 1 : 0
  private_key_pem = tls_private_key.inference_ca[0].private_key_pem
  subject {
    common_name = "Inference Self-Signed CA"
  }
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "inference_domain" {
  for_each  = var.enable_inference ? { for a in var.agents : a.name => a if a.inference_domain != "" } : {}
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "inference_domain" {
  for_each        = var.enable_inference ? { for a in var.agents : a.name => a if a.inference_domain != "" } : {}
  private_key_pem = tls_private_key.inference_domain[each.key].private_key_pem
  subject {
    common_name = each.value.inference_domain
  }
  dns_names = [each.value.inference_domain, "*.${each.value.inference_domain}"]
}

resource "tls_locally_signed_cert" "inference_domain" {
  for_each           = var.enable_inference ? { for a in var.agents : a.name => a if a.inference_domain != "" } : {}
  cert_request_pem   = tls_cert_request.inference_domain[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.inference_ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.inference_ca[0].cert_pem

  validity_period_hours = 8760
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

# ---------------------------------------------------------------------------
# Cluster registration – register each agent with the NVIDIA Run:ai control plane
# ---------------------------------------------------------------------------

module "cluster_registration" {
  for_each = local.agents_to_register
  source   = "../_shared/runai-cluster-registration"

  api_user                    = var.runai_admin_email
  api_password                = var.runai_admin_password
  cluster_name                = each.key
  cluster_url                 = "https://${each.value.workload_domain != "" ? each.value.workload_domain : each.value.domain}"
  runai_cluster_agent_version = var.runai_chart_version
}

# ---------------------------------------------------------------------------
# Agent vClusters – one per registered cluster
# ---------------------------------------------------------------------------

module "agent_vcluster" {
  for_each = local.agents_map
  source   = "git::https://github.com/loft-sh/vcluster-terraform-modules.git//vcluster?ref=v1.0.0"

  name                   = "${var.name}-${each.key}"
  namespace              = "${var.name}-${each.key}"
  project_name           = var.platform_project_name
  platform_url           = var.platform_url
  platform_access_key    = var.platform_access_key
  platform_insecure      = var.platform_insecure
  chart_version          = var.vcluster_chart_version
  kubeconfig_output_path = "${var.kubeconfig_output_dir}/${var.name}-${each.key}-kubeconfig.yaml"
  skip_kubeconfig        = var.skip_kubeconfig

  helm_values = [templatefile("${path.module}/templates/agent-vcluster-values.yaml.tpl", {
    agent_name      = "${var.name}-${each.key}"
    agent_namespace = "runai"
    agent_domain    = each.value.domain
    workload_domain = each.value.workload_domain != "" ? each.value.workload_domain : each.value.domain

    # Node selection
    node_selector_label_key   = var.node_selector_label_key
    node_selector_label_value = each.value.node_selector_label_value

    # High availability
    high_availability = var.high_availability
    ha_replicas       = var.ha_replicas

    # NVIDIA Run:ai cluster credentials
    cluster_uid = local.agent_credentials[each.key].cluster_uid
    # client_secret is passed into the Helm values template as plaintext; it is
    # not a user-facing secret — it authenticates the agent back to the CP.
    client_secret  = nonsensitive(local.agent_credentials[each.key].client_secret)
    cp_url         = var.runai_cp_url
    cp_domain      = local.cp_domain
    cp_ca_cert_b64 = var.runai_cp_ca_cert

    # Registry
    registry_secret_name = "runai-reg-creds"
    registry_credentials = var.runai_registry_credentials

    # Charts
    agent_chart_repo    = var.runai_agent_chart_repo
    agent_chart_version = var.runai_chart_version

    # Ingress
    ingress_service_annotations = each.value.ingress_service_annotations

    # GPU Operator
    deploy_gpu_operator                = var.deploy_gpu_operator
    gpu_operator_version               = var.gpu_operator_version
    gpu_operator_driver_enabled        = var.gpu_operator_driver_enabled ? "true" : "false"
    gpu_operator_device_plugin_enabled = var.gpu_operator_device_plugin_enabled
    gpu_operator_driver_install_dir    = var.gpu_operator_driver_install_dir

    # Prometheus
    deploy_prometheus_operator    = var.deploy_prometheus_operator
    kube_prometheus_stack_version = var.kube_prometheus_stack_version

    # Inference
    enable_inference              = var.enable_inference
    knative_operator_version      = var.knative_operator_version
    knative_serving_version       = var.knative_serving_version
    inference_domain              = each.value.inference_domain
    inference_service_annotations = each.value.inference_service_annotations
    inference_tls_cert_b64        = var.enable_inference && each.value.inference_domain != "" ? base64encode("${tls_locally_signed_cert.inference_domain[each.key].cert_pem}${tls_self_signed_cert.inference_ca[0].cert_pem}") : ""
    inference_tls_key_b64         = var.enable_inference && each.value.inference_domain != "" ? base64encode(tls_private_key.inference_domain[each.key].private_key_pem) : ""
    raw_chart_version             = var.raw_chart_version

    # Workload domain TLS
    workload_domain_tls_cert_b64 = each.value.workload_domain != "" ? base64encode("${tls_locally_signed_cert.workload_domain[each.key].cert_pem}${tls_self_signed_cert.workload_domain_ca[0].cert_pem}") : ""
    workload_domain_tls_key_b64  = each.value.workload_domain != "" ? base64encode(tls_private_key.workload_domain[each.key].private_key_pem) : ""
  })]

  depends_on = [module.cluster_registration]
}
