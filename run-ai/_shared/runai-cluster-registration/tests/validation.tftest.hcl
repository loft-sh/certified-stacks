mock_provider "restful" {}

override_module {
  target = module.auth
  outputs = {
    access_token = "mock-token"
  }
}

override_resource {
  target = restful_operation.cluster
  values = {
    output = {
      uuid = "mock-cluster-uuid"
    }
  }
}

override_resource {
  target = restful_operation.credentials
  values = {
    sensitive_output = {
      clientSecret = "mock-client-secret"
      clientId     = "mock-client-id"
    }
  }
}

# Email validation for api_user is handled by the shared runai-auth
# module and tested in its own test suite.

# -----------------------------------------------------------------------------
# Reject empty cluster_name
# -----------------------------------------------------------------------------

run "reject_empty_cluster_name" {
  command = plan

  variables {
    api_user     = "admin@run.ai"
    api_password = "test-password"
    cluster_name = ""
    cluster_url  = "https://agent-1.example.com"
  }

  expect_failures = [
    var.cluster_name,
  ]
}

# -----------------------------------------------------------------------------
# Accept valid inputs - plan should succeed
# -----------------------------------------------------------------------------

run "accept_valid_inputs" {
  command = plan

  variables {
    api_user     = "admin@run.ai"
    api_password = "test-password"
    cluster_name = "my-cluster"
    cluster_url  = "https://agent-1.example.com"
  }
}

# -----------------------------------------------------------------------------
# Verify resource configuration
# -----------------------------------------------------------------------------

run "correct_resource_config" {
  command = plan

  variables {
    api_user     = "admin@run.ai"
    api_password = "test-password"
    cluster_name = "my-cluster"
    cluster_url  = "https://agent-1.example.com"
  }

  assert {
    condition     = restful_operation.cluster.method == "POST"
    error_message = "Cluster resource should use POST method."
  }

  assert {
    condition     = restful_operation.cluster.path == "/api/v1/clusters"
    error_message = "Cluster resource should POST to /api/v1/clusters."
  }

  assert {
    condition     = restful_operation.credentials.method == "GET"
    error_message = "Credentials resource should use GET method."
  }
}

# -----------------------------------------------------------------------------
# Verify default values are applied correctly
# -----------------------------------------------------------------------------

run "default_values_applied" {
  command = plan

  variables {
    api_password = "test-password"
    cluster_name = "my-cluster"
    cluster_url  = "https://agent-1.example.com"
  }
}
