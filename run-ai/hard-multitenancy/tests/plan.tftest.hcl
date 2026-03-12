mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "tls" {}
mock_provider "restful" {}

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

override_module {
  target = module.agent_vcluster
  outputs = {
    name                     = "test-stack-agent"
    namespace                = "test-stack-agent"
    kubeconfig_path          = "/tmp/test-stack-agent-kubeconfig.yaml"
    kubeconfig_content       = "mock-kubeconfig"
    server                   = "https://agent.example.com"
    project_namespace        = "p-default"
    access_key               = "mock-access-key"
    helm_release_name        = "test-stack-agent"
    helm_release_namespace   = "test-stack-agent"
    ready                    = true
    host                     = "https://agent.example.com"
    cluster_ca_certificate   = "mock-ca-cert"
    client_certificate       = "mock-client-cert"
    client_key               = "mock-client-key"
    token                    = "mock-token"
    insecure_skip_tls_verify = false
  }
}

override_module {
  target = module.cp_auth
  outputs = {
    access_token = "mock-token"
  }
}

override_resource {
  target = restful_operation.create_cluster
  values = {
    output = {
      uuid = "mock-cluster-uuid"
    }
  }
}

override_resource {
  target = restful_operation.cluster_creds
  values = {
    sensitive_output = {
      clientSecret = "mock-client-secret"
    }
  }
}

# -----------------------------------------------------------------------------
# With 0 agents - only CP resources are created
# -----------------------------------------------------------------------------

run "zero_agents_cp_only" {
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

  # CP TLS resources should be present
  assert {
    condition     = tls_private_key.cp[0].algorithm == "RSA"
    error_message = "TLS private key should use RSA algorithm."
  }

  assert {
    condition     = tls_cert_request.cp[0].dns_names[0] == "runai.example.com"
    error_message = "TLS cert should include the CP domain in DNS names."
  }

  # No agent-specific resources should be created
  assert {
    condition     = length(restful_operation.create_cluster) == 0
    error_message = "No cluster registrations should exist with 0 agents."
  }

  assert {
    condition     = length(restful_operation.cluster_creds) == 0
    error_message = "No cluster credentials should exist with 0 agents."
  }
}

# -----------------------------------------------------------------------------
# With 2 agents - agent resources are created for each
# -----------------------------------------------------------------------------

run "two_agents_creates_resources" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents = [
      { name = "agent-1", domain = "agent-1.example.com" },
      { name = "agent-2", domain = "agent-2.example.com" },
    ]
  }

  # CP resources should still be present
  assert {
    condition     = tls_private_key.cp[0].algorithm == "RSA"
    error_message = "TLS private key should still exist with agents."
  }

  # Agent resources should be created for each agent
  assert {
    condition     = length(restful_operation.create_cluster) == 2
    error_message = "Should have 2 cluster registrations for 2 agents."
  }

  assert {
    condition     = length(restful_operation.cluster_creds) == 2
    error_message = "Should have 2 cluster credential lookups for 2 agents."
  }

  assert {
    condition     = restful_operation.create_cluster["agent-1"].body.name == "agent-1"
    error_message = "Agent-1 cluster registration should have name 'agent-1'."
  }

  assert {
    condition     = restful_operation.create_cluster["agent-2"].body.name == "agent-2"
    error_message = "Agent-2 cluster registration should have name 'agent-2'."
  }

  assert {
    condition     = restful_operation.create_cluster["agent-1"].body.domain == "https://agent-1.example.com"
    error_message = "Agent-1 cluster registration should have correct domain URL."
  }

  assert {
    condition     = restful_operation.create_cluster["agent-2"].body.domain == "https://agent-2.example.com"
    error_message = "Agent-2 cluster registration should have correct domain URL."
  }
}

# -----------------------------------------------------------------------------
# With static IPs - CP and agents bind to pre-reserved addresses
# -----------------------------------------------------------------------------

run "static_ip_agents" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai-cp.34.10.108.83.nip.io"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    cp_static_ip               = "34.10.108.83"
    agents = [
      { name = "agent-1", domain = "agent-1.34.10.108.84.nip.io", static_ip = "34.10.108.84" },
    ]
  }

  # CP resources should be present
  assert {
    condition     = tls_private_key.cp[0].algorithm == "RSA"
    error_message = "TLS private key should exist with static IPs."
  }

  # Agent cluster registration should exist
  assert {
    condition     = length(restful_operation.create_cluster) == 1
    error_message = "Should have 1 cluster registration for 1 agent with static IP."
  }

  assert {
    condition     = restful_operation.create_cluster["agent-1"].body.name == "agent-1"
    error_message = "Agent-1 cluster registration should have correct name."
  }
}

# -----------------------------------------------------------------------------
# TLS certificate is generated for the CP domain
# -----------------------------------------------------------------------------

run "tls_cert_for_cp_domain" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.my-cluster.nip.io"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    agents                     = []
  }

  assert {
    condition     = tls_private_key.cp[0].algorithm == "RSA"
    error_message = "TLS key should use RSA algorithm."
  }

  assert {
    condition     = tls_private_key.cp[0].rsa_bits == 2048
    error_message = "TLS key should be 2048 bits."
  }

  assert {
    condition     = tls_cert_request.cp[0].dns_names[0] == "runai.my-cluster.nip.io"
    error_message = "TLS cert DNS names should include the CP domain."
  }

  assert {
    condition     = tls_locally_signed_cert.cp[0].validity_period_hours == 8760
    error_message = "TLS cert should be valid for 8760 hours (1 year)."
  }

  assert {
    condition     = contains(tls_locally_signed_cert.cp[0].allowed_uses, "server_auth")
    error_message = "TLS cert should allow server_auth usage."
  }

  assert {
    condition     = contains(tls_locally_signed_cert.cp[0].allowed_uses, "key_encipherment")
    error_message = "TLS cert should allow key_encipherment usage."
  }

  assert {
    condition     = contains(tls_locally_signed_cert.cp[0].allowed_uses, "digital_signature")
    error_message = "TLS cert should allow digital_signature usage."
  }
}

# -----------------------------------------------------------------------------
# User-provided TLS mode - no self-signed certs generated
# -----------------------------------------------------------------------------

run "user_provided_tls_mode" {
  command = plan

  variables {
    name                       = "test-stack"
    platform_url               = "https://platform.example.com"
    platform_access_key        = "test-key"
    runai_cp_domain            = "runai.example.com"
    runai_admin_password       = "test-password"
    runai_registry_credentials = "eyJ0ZXN0IjogdHJ1ZX0="
    tls_mode                   = "user-provided"
    user_tls_cert              = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----"
    user_tls_key               = "-----BEGIN PRIVATE KEY-----\nMIIBfake\n-----END PRIVATE KEY-----"
    user_ca_cert               = "-----BEGIN CERTIFICATE-----\nMIIBfakeCA\n-----END CERTIFICATE-----"
    agents                     = []
  }

  # No self-signed TLS resources should be created
  assert {
    condition     = length(tls_private_key.ca) == 0
    error_message = "CA private key should not be created in user-provided mode."
  }

  assert {
    condition     = length(tls_self_signed_cert.ca) == 0
    error_message = "CA cert should not be created in user-provided mode."
  }

  assert {
    condition     = length(tls_private_key.cp) == 0
    error_message = "CP private key should not be created in user-provided mode."
  }

  assert {
    condition     = length(tls_cert_request.cp) == 0
    error_message = "CP cert request should not be created in user-provided mode."
  }

  assert {
    condition     = length(tls_locally_signed_cert.cp) == 0
    error_message = "CP locally signed cert should not be created in user-provided mode."
  }
}
