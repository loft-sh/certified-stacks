# =============================================================================
# Soft Multitenancy Stack - Variable Validation Tests
# =============================================================================
#
# Tests variable validations using mock providers and module overrides.
# All tests use `command = plan` so no real infrastructure is required.
#
# =============================================================================

mock_provider "kubernetes" {}
mock_provider "helm" {}

override_module {
  target = module.vcluster
  outputs = {
    name                     = "test-soft"
    namespace                = "test-soft-ns"
    kubeconfig_path          = "/tmp/test-soft-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    server                   = "https://test-soft.example.com"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    helm_release_name        = "test-soft"
    helm_release_namespace   = "test-soft-ns"
    ready                    = true
    host                     = "https://test-soft.example.com"
    cluster_ca_certificate   = "mock-ca-cert"
    client_certificate       = "mock-client-cert"
    client_key               = "mock-client-key"
    token                    = "mock-token"
    insecure_skip_tls_verify = false
  }
}

# -----------------------------------------------------------------------------
# Reject name with uppercase letters
# -----------------------------------------------------------------------------

run "reject_name_with_uppercase" {
  command = plan

  variables {
    name                = "Invalid-Name"
    ingress_ip          = "10.0.0.1"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
  }

  expect_failures = [
    var.name,
  ]
}

# -----------------------------------------------------------------------------
# Reject name that is too short (single character cannot match the regex
# requiring start + middle + end pattern)
# -----------------------------------------------------------------------------

run "reject_single_char_name" {
  command = plan

  variables {
    name                = "a"
    ingress_ip          = "10.0.0.1"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
  }

  expect_failures = [
    var.name,
  ]
}

# -----------------------------------------------------------------------------
# Reject invalid ingress_ip
# -----------------------------------------------------------------------------

run "reject_invalid_ingress_ip" {
  command = plan

  variables {
    name                = "test-soft"
    ingress_ip          = "not-an-ip"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
  }

  expect_failures = [
    var.ingress_ip,
  ]
}

run "reject_ingress_ip_with_letters" {
  command = plan

  variables {
    name                = "test-soft"
    ingress_ip          = "10.0.0.abc"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
  }

  expect_failures = [
    var.ingress_ip,
  ]
}

# -----------------------------------------------------------------------------
# Accept valid inputs
# -----------------------------------------------------------------------------

run "accept_valid_inputs" {
  command = plan

  variables {
    name                = "test-soft"
    ingress_ip          = "10.0.0.1"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
  }
}

run "accept_valid_inputs_operator_disabled" {
  command = plan

  variables {
    name                    = "ray-tenant-01"
    ingress_ip              = "192.168.1.100"
    platform_url            = "https://platform.example.com"
    platform_access_key     = "test-key"
    deploy_kuberay_operator = false
  }
}

# -----------------------------------------------------------------------------
# Reject platform_url without scheme
# -----------------------------------------------------------------------------

run "reject_invalid_platform_url" {
  command = plan

  variables {
    name                = "test-soft"
    ingress_ip          = "10.0.0.1"
    platform_url        = "platform.example.com"
    platform_access_key = "test-key"
  }

  expect_failures = [
    var.platform_url,
  ]
}
