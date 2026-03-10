mock_provider "kubernetes" {}
mock_provider "helm" {}

override_module {
  target = module.tenant_vcluster
  outputs = {
    name                     = "test-tenant"
    namespace                = "test-tenant"
    kubeconfig_path          = "/tmp/test-tenant-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    ready                    = true
    host                     = "https://test-tenant.example.com"
    cluster_ca_certificate   = "mock-ca-cert"
    client_certificate       = "mock-client-cert"
    client_key               = "mock-client-key"
    token                    = "mock-token"
    insecure_skip_tls_verify = false
  }
}

# -----------------------------------------------------------------------------
# With 0 tenants — no vCluster resources are created
# -----------------------------------------------------------------------------

run "zero_tenants" {
  command = plan

  variables {
    name                = "skypilot-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }

  assert {
    condition     = output.name == "skypilot-test"
    error_message = "Name output should match the input variable."
  }

  assert {
    condition     = length(output.tenant_vclusters) == 0
    error_message = "No tenant vClusters should exist with 0 tenants."
  }

  assert {
    condition     = length(output.tenant_skypilot_access) == 0
    error_message = "No SkyPilot access instructions should exist with 0 tenants."
  }
}

# -----------------------------------------------------------------------------
# With 1 tenant — a single vCluster is created
# -----------------------------------------------------------------------------

run "one_tenant" {
  command = plan

  variables {
    name                = "skypilot-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      { name = "tenant-1" }
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 1
    error_message = "Should have 1 tenant vCluster."
  }

  assert {
    condition     = output.tenant_vclusters["tenant-1"].host == "https://test-tenant.example.com"
    error_message = "Tenant vCluster host should come from module output."
  }

  assert {
    condition     = output.tenant_vclusters["tenant-1"].kubeconfig_path == "/tmp/test-tenant-kubeconfig.yaml"
    error_message = "Tenant vCluster kubeconfig_path should come from module output."
  }

  assert {
    condition     = length(output.tenant_skypilot_access) == 1
    error_message = "Should have 1 SkyPilot access instruction."
  }
}

# -----------------------------------------------------------------------------
# With 2 tenants — both vClusters are created
# -----------------------------------------------------------------------------

run "two_tenants" {
  command = plan

  variables {
    name                = "skypilot-prod"
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
    condition     = length(output.tenant_skypilot_access) == 2
    error_message = "Should have 2 SkyPilot access instructions."
  }
}

# -----------------------------------------------------------------------------
# Tenant with custom per-tenant node groups
# -----------------------------------------------------------------------------

run "tenant_with_custom_node_groups" {
  command = plan

  variables {
    name                = "skypilot-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      {
        name = "gpu-tenant"
        node_groups = {
          static = [
            {
              name       = "gpu-static"
              quantity   = 2
              node_types = ["n1-standard-8"]
              labels     = { "gpu" = "true" }
            }
          ]
          dynamic = [
            {
              name       = "gpu-dynamic"
              node_types = ["a2-highgpu-1g"]
              limits     = { nodes = 3 }
            }
          ]
        }
      }
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 1
    error_message = "Should have 1 tenant vCluster with custom node groups."
  }
}

# -----------------------------------------------------------------------------
# Tenant with auth credentials and SkyPilot config
# -----------------------------------------------------------------------------

run "tenant_with_auth_and_config" {
  command = plan

  variables {
    name                = "skypilot-test"
    platform_url        = "https://platform.example.com"
    platform_access_key = "test-key"
    tenants = [
      {
        name             = "secure-tenant"
        auth_credentials = "admin:$apr1$xyz"
        skypilot_config  = "kubernetes:\n  gpu_label_key: nvidia.com/gpu"
      }
    ]
  }

  assert {
    condition     = length(output.tenant_vclusters) == 1
    error_message = "Should have 1 tenant vCluster with auth and config."
  }
}

# -----------------------------------------------------------------------------
# Variable validation — platform_url must start with http(s)://
# -----------------------------------------------------------------------------

run "invalid_platform_url_rejected" {
  command = plan

  variables {
    name                = "skypilot-test"
    platform_url        = "platform.example.com"
    platform_access_key = "test-key"
    tenants             = []
  }

  expect_failures = [
    var.platform_url,
  ]
}

# -----------------------------------------------------------------------------
# Variable validation — name must not be empty
# -----------------------------------------------------------------------------

run "empty_name_rejected" {
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
# Variable validation — duplicate tenant names are rejected
# -----------------------------------------------------------------------------

run "duplicate_tenant_names_rejected" {
  command = plan

  variables {
    name                = "skypilot-test"
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
