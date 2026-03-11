# Run:ai Project Module

Creates a Run:ai project within a registered cluster via the REST API.

## How it works

1. **Authenticate** -- obtains a bearer token from `/api/v1/token` using the
   provided admin email and password.
2. **Fetch departments** -- queries
   `/v1/k8s/clusters/{cluster_uid}/departments` to discover the default
   department ID for the cluster.
3. **Create project** -- posts to
   `/v1/k8s/clusters/{cluster_uid}/projects` with the project name and default
   department ID.

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
| [restful_operation.departments](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |
| [restful_operation.project](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| api\_password | Run:ai API user password | `string` | n/a | yes |
| cluster\_uid | UUID of the Run:ai cluster to create the project in | `string` | n/a | yes |
| project\_name | Name of the Run:ai project to create | `string` | n/a | yes |
| api\_user | Run:ai API user email for authentication | `string` | `"admin@run.ai"` | no |

## Outputs

| Name | Description |
|------|-------------|
| department\_id | ID of the department the project belongs to |
| project\_id | ID of the created Run:ai project |
<!-- END_TF_DOCS -->

## Usage example

```hcl
module "cluster_registration" {
  source = "../modules/runai-cluster-registration"

  control_plane_url = "https://runai-cp.example.com"
  api_password      = var.runai_api_password
  cluster_name      = "my-cluster"
  cluster_url       = "https://my-cluster.example.com"
}

module "project" {
  source = "../modules/runai-project"

  control_plane_url = "https://runai-cp.example.com"
  api_password      = var.runai_api_password
  cluster_uid       = module.cluster_registration.cluster_uid
  project_name      = "my-project"

  depends_on = [module.cluster_registration]
}

output "project_id" {
  value = module.project.project_id
}
```
