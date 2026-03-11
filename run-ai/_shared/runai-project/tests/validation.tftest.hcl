mock_provider "restful" {}

override_module {
  target = module.auth
  outputs = {
    access_token = "mock-token"
  }
}

override_resource {
  target = restful_operation.departments
  values = {
    output = [{
      id = 1
    }]
  }
}

override_resource {
  target = restful_operation.project
  values = {
    output = {
      id = 999
    }
  }
}

# Email validation for api_user is handled by the shared runai-auth
# module and tested in its own test suite.

# -----------------------------------------------------------------------------
# Reject empty project_name
# -----------------------------------------------------------------------------

run "reject_empty_project_name" {
  command = plan

  variables {
    api_user     = "admin@run.ai"
    api_password = "test-password"
    cluster_uid  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    project_name = ""
  }

  expect_failures = [
    var.project_name,
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
    cluster_uid  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    project_name = "test-project"
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
    cluster_uid  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    project_name = "test-project"
  }

  assert {
    condition     = restful_operation.departments.method == "GET"
    error_message = "Departments resource should use GET method."
  }

  assert {
    condition     = restful_operation.project.method == "POST"
    error_message = "Project resource should use POST method."
  }

  assert {
    condition     = restful_operation.project.body.name == "test-project"
    error_message = "Project resource body should contain the project name."
  }
}

# -----------------------------------------------------------------------------
# Verify default values are applied correctly
# -----------------------------------------------------------------------------

run "default_values_applied" {
  command = plan

  variables {
    api_password = "test-password"
    cluster_uid  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    project_name = "test-project"
  }
}
