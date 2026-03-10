mock_provider "kubernetes" {}
mock_provider "helm" {}

override_module {
  target = module.tenant_vcluster
  outputs = {
    name                     = "slinky-soft-tenant"
    namespace                = "slinky-soft-tenant"
    kubeconfig_path          = "/tmp/slinky-soft-tenant-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    server                   = "https://slinky-soft-tenant.example.com"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    helm_release_name        = "slinky-soft-tenant"
    helm_release_namespace   = "slinky-soft-tenant"
    ready                    = true
    host                     = "https://slinky-soft-tenant.example.com"
    cluster_ca_certificate   = "mock-ca-cert"
    client_certificate       = "mock-client-cert"
    client_key               = "mock-client-key"
    token                    = "mock-token"
    insecure_skip_tls_verify = false
  }
}

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
# Reject invalid platform_url
# -----------------------------------------------------------------------------

run "reject_invalid_platform_url" {
  command = plan

  variables {
    name                = "slinky-test"
    platform_url        = "platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }

  expect_failures = [
    var.platform_url,
  ]
}

# -----------------------------------------------------------------------------
# Reject duplicate tenant names
# -----------------------------------------------------------------------------

run "reject_duplicate_tenant_names" {
  command = plan

  variables {
    name                = "slinky-test"
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
# Accept valid inputs with no tenants
# -----------------------------------------------------------------------------

run "accept_valid_inputs_no_tenants" {
  command = plan

  variables {
    name                = "slinky-test"
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

  variables {
    name                = "slinky-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      {
        name                      = "tenant-1"
        node_selector_label_value = "slinky-tenant-1"
        worker_replicas           = 1
        gpu_per_node              = 1
      }
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 1
    error_message = "Should have 1 tenant vCluster."
  }
}

# -----------------------------------------------------------------------------
# Two tenants creates two vClusters
# -----------------------------------------------------------------------------

run "two_tenants" {
  command = plan

  variables {
    name                = "slinky-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      { name = "team-a", node_selector_label_value = "team-a" },
      { name = "team-b", node_selector_label_value = "team-b" },
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 2
    error_message = "Should have 2 tenant vClusters."
  }

  assert {
    condition     = length(output.tenant_ssh_access) == 2
    error_message = "Should have 2 SSH access instructions."
  }
}
