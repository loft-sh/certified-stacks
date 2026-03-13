# Shared NVIDIA Run:ai authentication module.
# Obtains a bearer token from the NVIDIA Run:ai control plane.
# The caller must configure the restful provider (base_url, TLS, retries).

resource "restful_operation" "auth" {
  method = "POST"
  path   = "/api/v1/token"

  header = {
    "Content-Type" = "application/json"
  }

  body = {
    grantType = "password"
    username  = var.api_user
    password  = var.api_password
  }

  use_sensitive_output = true
}
