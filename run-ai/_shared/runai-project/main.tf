# =============================================================================
# NVIDIA Run:ai Project Module
# =============================================================================
#
# Creates a project in NVIDIA Run:ai via REST API.
# Uses the restful provider for all API interactions.
#
# The caller must pass in a configured restful provider.
#
# =============================================================================

module "auth" {
  source       = "../runai-auth"
  api_user     = var.api_user
  api_password = var.api_password
}

# Get departments for the cluster to find the default department ID
resource "restful_operation" "departments" {
  method = "GET"
  path   = "/v1/k8s/clusters/${var.cluster_uid}/departments"

  header = {
    "Authorization" = "Bearer ${module.auth.access_token}"
  }
}

# Create the project in the default department
resource "restful_operation" "project" {
  method = "POST"
  path   = "/v1/k8s/clusters/${var.cluster_uid}/projects"

  header = {
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer ${module.auth.access_token}"
  }

  body = {
    name         = var.project_name
    departmentId = restful_operation.departments.output[0].id
  }
}
