mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}
mock_provider "restful" {}

override_module {
  target = module.cp_auth
  outputs = {
    access_token = "mock-token"
  }
}

override_module {
  target = module.cp_vcluster
  outputs = {
    name                     = "test-cp"
    namespace                = "test-cp"
    kubeconfig_path          = "/tmp/test-cp-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    server                   = "https://test-cp.example.com"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    helm_release_name        = "test-cp"
    helm_release_namespace   = "test-cp"
    ready                    = true
    host                     = "https://test-cp.example.com"
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
    name                       = ""
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }

  expect_failures = [
    var.name,
  ]
}

# -----------------------------------------------------------------------------
# Reject invalid domain - leading hyphen
# -----------------------------------------------------------------------------

run "reject_invalid_domain_leading_hyphen" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "-invalid.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }

  expect_failures = [
    var.runai_cp_domain,
  ]
}

# -----------------------------------------------------------------------------
# Reject invalid domain - contains spaces
# -----------------------------------------------------------------------------

run "reject_invalid_domain_with_spaces" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "has spaces.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }

  expect_failures = [
    var.runai_cp_domain,
  ]
}

# Email validation for runai_admin_email is handled by the shared runai-auth
# module and tested in its own test suite.

# -----------------------------------------------------------------------------
# Accept valid domain formats
# -----------------------------------------------------------------------------

run "accept_valid_domain_simple" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }
}

run "accept_valid_domain_with_nip_io" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.10.0.0.1.nip.io"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }
}

run "accept_valid_domain_subdomain" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "cp.runai.internal.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }
}
