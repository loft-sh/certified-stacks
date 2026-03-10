# =============================================================================
# Hard Multitenancy Stack - Variable Validation Tests
# =============================================================================
#
# Tests variable validations using mock providers and module overrides.
# All tests use `command = plan` so no real infrastructure is required.
#
# =============================================================================

mock_provider "kubernetes" {}
mock_provider "helm" {}

# -----------------------------------------------------------------------------
# Reject empty name
# -----------------------------------------------------------------------------

run "reject_empty_name" {
  command = plan

  variables {
    name                = ""
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }

  expect_failures = [
    var.name,
  ]
}

# -----------------------------------------------------------------------------
# Accept valid inputs with no tenants
# -----------------------------------------------------------------------------

run "accept_valid_inputs_no_tenants" {
  command = plan

  variables {
    name                = "ray-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }
}

# -----------------------------------------------------------------------------
# Accept valid inputs with tenants
# -----------------------------------------------------------------------------

run "accept_valid_inputs_with_tenants" {
  command = plan

  override_module {
    target = module.tenant_vcluster
    outputs = {
      name                     = "ray-test-tenant-1"
      namespace                = "ray-test-tenant-1"
      kubeconfig_path          = "/tmp/ray-test-tenant-1-kubeconfig.yaml"
      kubeconfig_content       = "mock-kubeconfig"
      server                   = "https://ray-test-tenant-1.example.com"
      project_namespace        = "p-default"
      access_key               = "mock-access-key"
      helm_release_name        = "ray-test-tenant-1"
      helm_release_namespace   = "ray-test-tenant-1"
      ready                    = true
      host                     = "https://ray-test-tenant-1.example.com"
      cluster_ca_certificate   = "mock-ca-cert"
      client_certificate       = "mock-client-cert"
      client_key               = "mock-client-key"
      token                    = "mock-token"
      insecure_skip_tls_verify = false
    }
  }

  variables {
    name                = "ray-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      {
        name            = "tenant-1"
        worker_replicas = 2
        gpu_per_worker  = 1
      }
    ]
  }
}

# -----------------------------------------------------------------------------
# Variable validation — platform_url must start with http(s)://
# -----------------------------------------------------------------------------

run "reject_invalid_platform_url" {
  command = plan

  variables {
    name                = "ray-test"
    platform_url        = "platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }

  expect_failures = [
    var.platform_url,
  ]
}

# -----------------------------------------------------------------------------
# Variable validation — duplicate tenant names are rejected
# -----------------------------------------------------------------------------

run "reject_duplicate_tenant_names" {
  command = plan

  variables {
    name                = "ray-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      { name = "same-name" },
      { name = "same-name" },
    ]
  }

  expect_failures = [
    var.tenants,
  ]
}

# -----------------------------------------------------------------------------
# With 2 tenants — both vClusters are created
# -----------------------------------------------------------------------------

run "two_tenants_creates_vclusters" {
  command = plan

  override_module {
    target = module.tenant_vcluster
    outputs = {
      name                     = "ray-test-tenant"
      namespace                = "ray-test-tenant"
      kubeconfig_path          = "/tmp/ray-test-tenant-kubeconfig.yaml"
      kubeconfig_content       = "mock-kubeconfig"
      server                   = "https://ray-test-tenant.example.com"
      project_namespace        = "p-default"
      access_key               = "mock-access-key"
      helm_release_name        = "ray-test-tenant"
      helm_release_namespace   = "ray-test-tenant"
      ready                    = true
      host                     = "https://ray-test-tenant.example.com"
      cluster_ca_certificate   = "mock-ca-cert"
      client_certificate       = "mock-client-cert"
      client_key               = "mock-client-key"
      token                    = "mock-token"
      insecure_skip_tls_verify = false
    }
  }

  variables {
    name                = "ray-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      { name = "team-a" },
      { name = "team-b" },
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 2
    error_message = "Should have 2 tenant vClusters."
  }

  assert {
    condition     = length(output.tenant_ray_dashboard) == 2
    error_message = "Should have 2 Ray Dashboard instructions."
  }
}
