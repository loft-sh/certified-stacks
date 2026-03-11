mock_provider "kubernetes" {}
mock_provider "helm" {}

# The cluster_registration module uses the restful provider internally;
# override the entire module so its provider is never instantiated.
override_module {
  target = module.cluster_registration
  outputs = {
    cluster_uid   = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    client_id     = "mock-client-id"
    client_secret = "mock-client-secret"
  }
}

override_module {
  target = module.agent_vcluster
  outputs = {
    name                     = "test-soft-agent-1"
    namespace                = "test-soft-agent-1"
    kubeconfig_path          = "/tmp/test-soft-agent-1-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    server                   = "https://test-soft.example.com"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    helm_release_name        = "test-soft-agent-1"
    helm_release_namespace   = "test-soft-agent-1"
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
# Reject empty name
# -----------------------------------------------------------------------------

run "reject_empty_name" {
  command = plan

  variables {
    name                       = ""
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "https://runai-cp.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }

  expect_failures = [
    var.name,
  ]
}

# -----------------------------------------------------------------------------
# Reject invalid runai_cp_url (missing scheme)
# -----------------------------------------------------------------------------

run "reject_cp_url_missing_scheme" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "runai-cp.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }

  expect_failures = [
    var.runai_cp_url,
  ]
}

run "reject_cp_url_ftp_scheme" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "ftp://runai-cp.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }

  expect_failures = [
    var.runai_cp_url,
  ]
}

# -----------------------------------------------------------------------------
# Reject invalid admin email
# -----------------------------------------------------------------------------

run "reject_invalid_admin_email" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "https://runai-cp.example.com"
    runai_admin_email          = "not-valid-email"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }

  expect_failures = [
    var.runai_admin_email,
  ]
}

# -----------------------------------------------------------------------------
# Accept valid inputs (no agents)
# -----------------------------------------------------------------------------

run "accept_valid_inputs_no_agents" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "https://runai-cp.example.com"
    runai_admin_email          = "admin@run.ai"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }
}

# -----------------------------------------------------------------------------
# Accept valid inputs with agents (automated registration)
# -----------------------------------------------------------------------------

run "accept_valid_inputs_with_agents" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "https://runai-cp.example.com"
    runai_admin_email          = "admin@run.ai"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents = [
      {
        name                      = "agent-1"
        domain                    = "agent-1.10.0.0.1.nip.io"
        node_selector_label_value = "agent-1"
      }
    ]
  }
}

# -----------------------------------------------------------------------------
# Accept valid inputs with pre-provided credentials (skip registration)
# -----------------------------------------------------------------------------

run "accept_valid_inputs_skip_registration" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "https://runai-cp.example.com"
    runai_admin_email          = "admin@run.ai"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents = [
      {
        name          = "agent-pre"
        domain        = "agent-pre.10.0.0.1.nip.io"
        cluster_uid   = "pre-provided-uid"
        client_secret = "pre-provided-secret"
      }
    ]
  }
}

run "accept_valid_inputs_http_scheme" {
  command = plan

  variables {
    name                       = "test-soft"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_url               = "http://runai-cp.internal.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
  }
}
