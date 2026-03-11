mock_provider "restful" {}

override_resource {
  target = restful_operation.auth
  values = {
    sensitive_output = {
      accessToken = "mock-token"
    }
  }
}

# -----------------------------------------------------------------------------
# Reject invalid email
# -----------------------------------------------------------------------------

run "reject_invalid_email" {
  command = plan

  variables {
    api_user     = "not-an-email"
    api_password = "test-password"
  }

  expect_failures = [
    var.api_user,
  ]
}

# -----------------------------------------------------------------------------
# Accept valid email
# -----------------------------------------------------------------------------

run "accept_valid_email" {
  command = plan

  variables {
    api_user     = "admin@run.ai"
    api_password = "test-password"
  }

  assert {
    condition     = restful_operation.auth.method == "POST"
    error_message = "Auth resource should use POST method."
  }

  assert {
    condition     = restful_operation.auth.path == "/api/v1/token"
    error_message = "Auth resource should POST to /api/v1/token."
  }

  assert {
    condition     = restful_operation.auth.body.username == "admin@run.ai"
    error_message = "Auth body should contain the provided username."
  }
}

# -----------------------------------------------------------------------------
# Default api_user is admin@run.ai
# -----------------------------------------------------------------------------

run "default_api_user" {
  command = plan

  variables {
    api_password = "test-password"
  }

  assert {
    condition     = restful_operation.auth.body.username == "admin@run.ai"
    error_message = "Default api_user should be admin@run.ai."
  }
}
