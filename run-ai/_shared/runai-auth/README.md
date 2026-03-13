# NVIDIA Run:ai Auth (shared)

Authenticates with the NVIDIA Run:ai control plane and returns a bearer token. Used internally by `runai-project` and `runai-cluster-registration`.

The caller must configure the `restful` provider with `base_url`, TLS settings, and retry policy.

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

No modules.

## Resources

| Name | Type |
|------|------|
| [restful_operation.auth](https://registry.terraform.io/providers/magodo/restful/latest/docs/resources/operation) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| api\_password | NVIDIA Run:ai API user password | `string` | n/a | yes |
| api\_user | NVIDIA Run:ai API user email for authentication | `string` | `"admin@run.ai"` | no |

## Outputs

| Name | Description |
|------|-------------|
| access\_token | Bearer token for NVIDIA Run:ai API requests |
<!-- END_TF_DOCS -->
