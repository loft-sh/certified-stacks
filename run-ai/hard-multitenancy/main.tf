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
# TLS – CA + leaf certificate chain for the Run:AI control-plane ingress
# ---------------------------------------------------------------------------

resource "tls_private_key" "ca" {
  count     = var.tls_mode == "self-signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  count           = var.tls_mode == "self-signed" ? 1 : 0
  private_key_pem = tls_private_key.ca[0].private_key_pem
  subject {
    common_name = "Run:AI Self-Signed CA"
  }
  is_ca_certificate     = true
  validity_period_hours = 87600 # 10 years
  allowed_uses          = ["cert_signing", "crl_signing"]
}

resource "tls_private_key" "cp" {
  count     = var.tls_mode == "self-signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_locally_signed_cert" "cp" {
  count              = var.tls_mode == "self-signed" ? 1 : 0
  cert_request_pem   = tls_cert_request.cp[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 8760 # 1 year
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

resource "tls_cert_request" "cp" {
  count           = var.tls_mode == "self-signed" ? 1 : 0
  private_key_pem = tls_private_key.cp[0].private_key_pem
  subject {
    common_name = var.runai_cp_domain
  }
  dns_names = [var.runai_cp_domain]
}

resource "random_password" "runai_admin" {
  length           = 24
  special          = true
  override_special = "!@#$%"

  lifecycle {
    precondition {
      condition = (
        var.tls_mode != "user-provided" || (
          var.user_tls_cert != "" && var.user_tls_key != "" && var.user_ca_cert != ""
        )
      )
      error_message = "When tls_mode is 'user-provided', user_tls_cert, user_tls_key, and user_ca_cert must all be non-empty."
    }
  }
}

locals {
  cp_name              = "${var.name}-cp"
  cp_url               = "https://${var.runai_cp_domain}"
  cp_tls_cert_b64      = var.tls_mode == "self-signed" ? base64encode("${tls_locally_signed_cert.cp[0].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}") : base64encode(var.user_tls_cert)
  cp_tls_key_b64       = var.tls_mode == "self-signed" ? base64encode(tls_private_key.cp[0].private_key_pem) : base64encode(var.user_tls_key)
  cp_ca_cert_b64       = var.tls_mode == "self-signed" ? base64encode(tls_self_signed_cert.ca[0].cert_pem) : base64encode(var.user_ca_cert)
  runai_admin_password = coalesce(var.runai_admin_password, random_password.runai_admin.result)

  agent_effective_node_groups = {
    for a in var.agents : a.name =>
    a.node_groups != null ? a.node_groups : var.agent_node_groups
  }
}

# ---------------------------------------------------------------------------
# Control-plane vCluster
# ---------------------------------------------------------------------------

module "cp_vcluster" {
  # TODO: switch to loft-sh/vcluster-terraform-modules.git once PR #5 is merged
  source = "git::https://github.com/janekbaraniewski/vcluster-terraform-modules.git//vcluster?ref=feat/add-vcluster-management-modules"

  name                   = local.cp_name
  namespace              = local.cp_name
  project_name           = var.platform_project_name
  platform_url           = var.platform_url
  platform_access_key    = var.platform_access_key
  platform_insecure      = var.platform_insecure
  chart_version          = var.vcluster_chart_version
  kubeconfig_output_path = "${var.kubeconfig_output_dir}/${local.cp_name}-kubeconfig.yaml"
  skip_kubeconfig        = var.skip_kubeconfig

  helm_values = [templatefile("${path.module}/templates/cp-vcluster-values.yaml.tpl", {
    backend_namespace              = "runai-backend"
    registry_secret_name           = "runai-reg-creds"
    registry_credentials           = var.runai_registry_credentials
    cp_chart_repo                  = var.runai_cp_chart_repo
    cp_chart_version               = var.runai_chart_version
    domain                         = var.runai_cp_domain
    admin_email                    = var.runai_admin_email
    admin_password                 = local.runai_admin_password
    tls_cert_b64                   = local.cp_tls_cert_b64
    tls_key_b64                    = local.cp_tls_key_b64
    cp_ca_cert_b64                 = local.cp_ca_cert_b64
    node_provider_name             = var.node_provider_name
    auto_node_properties           = var.auto_node_properties
    static_node_groups             = var.cp_node_groups.static
    dynamic_node_groups            = var.cp_node_groups.dynamic
    cp_static_ip                   = var.cp_static_ip
    cp_ingress_service_annotations = var.cp_ingress_service_annotations
  })]
}

# ---------------------------------------------------------------------------
# TLS – self-signed certificates for agent domain (subdomain routing + inference)
# ---------------------------------------------------------------------------

resource "tls_private_key" "agent_domain" {
  for_each  = var.tls_mode == "self-signed" ? { for a in var.agents : a.name => a } : {}
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "agent_domain" {
  for_each        = var.tls_mode == "self-signed" ? { for a in var.agents : a.name => a } : {}
  private_key_pem = tls_private_key.agent_domain[each.key].private_key_pem
  subject {
    common_name = each.value.domain
  }
  dns_names = compact([
    each.value.domain,
    "*.${each.value.domain}",
    each.value.inference_domain,
    each.value.inference_domain != "" ? "*.${each.value.inference_domain}" : "",
  ])
}

resource "tls_locally_signed_cert" "agent_domain" {
  for_each           = var.tls_mode == "self-signed" ? { for a in var.agents : a.name => a } : {}
  cert_request_pem   = tls_cert_request.agent_domain[each.key].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem

  validity_period_hours = 8760
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

# ---------------------------------------------------------------------------
# REST API – authenticate against the Run:AI control plane
# ---------------------------------------------------------------------------

provider "restful" {
  base_url = local.cp_url
  client = {
    # Always true: the Run:AI CP is deployed inside a vCluster with self-signed
    # TLS certificates that the restful provider cannot validate.
    tls_insecure_skip_verify = true
    retry = {
      # Retry on connectivity errors (0), auth/not-found (401/403/404) because
      # the CP may still be initializing, and server errors (5xx).
      status_codes    = [0, 401, 403, 404, 500, 502, 503, 504]
      count           = var.cp_health_check_retries
      wait_in_sec     = var.cp_health_check_interval
      max_wait_in_sec = 30
    }
  }
}

resource "restful_operation" "wait_for_runai_cp_ready" {
  method = "GET"
  path   = "/auth/realms/runai/.well-known/openid-configuration"
  header = {
    "Content-Type" = "application/json"
  }
  depends_on = [module.cp_vcluster]
}

module "cp_auth" {
  source       = "../_shared/runai-auth"
  api_user     = var.runai_admin_email
  api_password = local.runai_admin_password
  depends_on   = [restful_operation.wait_for_runai_cp_ready]
}

# ---------------------------------------------------------------------------
# Cluster registration – register each agent with the control plane
# ---------------------------------------------------------------------------

resource "restful_operation" "create_cluster" {
  for_each = { for a in var.agents : a.name => a }
  method   = "POST"
  path     = "/api/v1/clusters"
  header = {
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer ${module.cp_auth.access_token}"
  }
  body = {
    name   = each.key
    domain = "https://${each.value.domain}"
  }
  delete_method = "DELETE"
  delete_path   = "/api/v1/clusters/$(body.uuid)"
  delete_header = {
    "Authorization" = "Bearer ${module.cp_auth.access_token}"
  }
  delete_query = {
    force = ["true"]
  }
}

resource "restful_operation" "cluster_creds" {
  for_each = { for a in var.agents : a.name => a }
  method   = "GET"
  path     = "/api/v1/clusters/${restful_operation.create_cluster[each.key].output.uuid}/cluster-install-info"
  header = {
    "Authorization" = "Bearer ${module.cp_auth.access_token}"
  }
  query = {
    version = [var.runai_chart_version]
  }
  use_sensitive_output = true
}

# ---------------------------------------------------------------------------
# Agent vClusters – one per registered cluster
# ---------------------------------------------------------------------------

module "agent_vcluster" {
  for_each = { for a in var.agents : a.name => a }
  # TODO: switch to loft-sh/vcluster-terraform-modules.git once PR #5 is merged
  source = "git::https://github.com/janekbaraniewski/vcluster-terraform-modules.git//vcluster?ref=feat/add-vcluster-management-modules"

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
    agent_namespace      = "runai"
    registry_secret_name = "runai-reg-creds"
    registry_credentials = var.runai_registry_credentials
    agent_chart_repo     = var.runai_agent_chart_repo
    agent_chart_version  = var.runai_chart_version
    cluster_uid          = restful_operation.create_cluster[each.key].output.uuid
    # clientSecret is passed into the Helm values template as plaintext; it is
    # not a user-facing secret — it authenticates the agent back to the CP.
    client_secret                 = nonsensitive(restful_operation.cluster_creds[each.key].sensitive_output.clientSecret)
    cp_domain                     = var.runai_cp_domain
    agent_domain                  = each.value.domain
    cp_ca_cert_b64                = local.cp_ca_cert_b64
    deploy_gpu_operator           = var.deploy_gpu_operator
    gpu_operator_version          = var.gpu_operator_version
    gpu_operator_driver_enabled   = var.gpu_operator_driver_enabled ? "true" : "false"
    deploy_prometheus_operator    = var.deploy_prometheus_operator
    kube_prometheus_stack_version = var.kube_prometheus_stack_version
    node_provider_name            = var.node_provider_name
    auto_node_properties          = var.auto_node_properties
    static_node_groups            = local.agent_effective_node_groups[each.key].static
    dynamic_node_groups           = local.agent_effective_node_groups[each.key].dynamic
    agent_static_ip               = each.value.static_ip
    ingress_service_annotations   = each.value.ingress_service_annotations
    enable_inference              = var.enable_inference
    knative_operator_version      = var.knative_operator_version
    knative_serving_version       = var.knative_serving_version
    inference_domain              = each.value.inference_domain
    inference_static_ip           = each.value.inference_static_ip
    inference_service_annotations = each.value.inference_service_annotations
    agent_domain_tls_cert_b64     = var.tls_mode == "self-signed" ? base64encode("${tls_locally_signed_cert.agent_domain[each.key].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}") : base64encode(var.user_tls_cert)
    agent_domain_tls_key_b64      = var.tls_mode == "self-signed" ? base64encode(tls_private_key.agent_domain[each.key].private_key_pem) : base64encode(var.user_tls_key)
    inference_tls_cert_b64        = var.enable_inference && each.value.inference_domain != "" ? (var.tls_mode == "self-signed" ? base64encode("${tls_locally_signed_cert.agent_domain[each.key].cert_pem}${tls_self_signed_cert.ca[0].cert_pem}") : base64encode(var.user_tls_cert)) : ""
    inference_tls_key_b64         = var.enable_inference && each.value.inference_domain != "" ? (var.tls_mode == "self-signed" ? base64encode(tls_private_key.agent_domain[each.key].private_key_pem) : base64encode(var.user_tls_key)) : ""
  })]

  depends_on = [restful_operation.cluster_creds]
}


