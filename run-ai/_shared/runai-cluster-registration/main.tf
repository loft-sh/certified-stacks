# =============================================================================
# NVIDIA Run:ai Cluster Registration Module
# =============================================================================
#
# Registers a cluster with the NVIDIA Run:ai control plane via REST API.
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

# Register the cluster
resource "restful_operation" "cluster" {
  method = "POST"
  path   = "/api/v1/clusters"

  header = {
    "Content-Type"  = "application/json"
    "Authorization" = "Bearer ${module.auth.access_token}"
  }

  body = {
    name   = var.cluster_name
    domain = var.cluster_url
  }

  delete_method = "DELETE"
  delete_path   = "/api/v1/clusters/$(body.uuid)"

  delete_header = {
    "Authorization" = "Bearer ${module.auth.access_token}"
  }

  delete_query = {
    force = ["true"]
  }
}

# Retrieve cluster credentials
resource "restful_operation" "credentials" {
  method = "GET"
  path   = "/api/v1/clusters/${restful_operation.cluster.output.uuid}/cluster-install-info"

  header = {
    "Authorization" = "Bearer ${module.auth.access_token}"
  }

  query = {
    version = [var.runai_cluster_agent_version]
  }

  use_sensitive_output = true
}
