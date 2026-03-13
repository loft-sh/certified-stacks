# NVIDIA Run:ai Cluster Registration Module

Registers a cluster with an external NVIDIA Run:ai control plane via the REST API and
retrieves the credentials needed to deploy the NVIDIA Run:ai cluster agent.

## How it works

1. **Authenticate** -- obtains a bearer token from `/api/v1/token` using the
   provided admin email and password.
2. **Register cluster** -- creates a new cluster entry via `POST /api/v1/clusters`
   with a given name and external URL. On `terraform destroy` the cluster is
   removed with a forced `DELETE`.
3. **Retrieve credentials** -- fetches `clientId` and `clientSecret` from
   `/api/v1/clusters/{uuid}/cluster-install-info` so the agent Helm chart can
   authenticate back to the control plane.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| restful | ~> 0.25 |

## Providers

| Name | Version |
|------|---------|
| restful | 0.25.1 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| auth | ../runai-auth | n/a |

## Resources

| Name | Type |
|------|------|
| [restful_operation.cluster](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |
| [restful_operation.credentials](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| api\_password | NVIDIA Run:ai API user password | `string` | n/a | yes |
| cluster\_name | Name for the cluster to register with NVIDIA Run:ai | `string` | n/a | yes |
| cluster\_url | External URL for the cluster (e.g. https://agent-1.example.com) | `string` | n/a | yes |
| api\_user | NVIDIA Run:ai API user email for authentication | `string` | `"admin@run.ai"` | no |
| runai\_cluster\_agent\_version | NVIDIA Run:ai cluster agent version for credential retrieval | `string` | `"2.24.18"` | no |

## Outputs

| Name | Description |
|------|-------------|
| client\_secret | Client secret for the registered cluster |
| cluster\_uid | UUID of the registered cluster |
<!-- END_TF_DOCS -->

## Usage example

```hcl
module "cluster_registration" {
  source = "../modules/runai-cluster-registration"

  control_plane_url           = "https://runai-cp.example.com"
  api_user                    = "admin@run.ai"
  api_password                = var.runai_api_password
  cluster_name                = "my-cluster"
  cluster_url                 = "https://my-cluster.example.com"
  runai_cluster_agent_version = "2.24.18"
}

output "cluster_uid" {
  value = module.cluster_registration.cluster_uid
}
```
