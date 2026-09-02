# NVIDIA Run:ai Certified Stacks

This integration deploys NVIDIA Run:ai and its supporting GPU infrastructure through native vCluster Platform Stacks. It provides two deployment models with different ownership and lifecycle boundaries.

If you want to install the bundled integration, start with the [vCluster Platform NVIDIA Run:ai guide](https://www.vcluster.com/docs/platform/next/integrations/certified-stacks/runai). The files in this directory are the source, generated manifests, examples, and tests used to build and validate that bundle.

## Choose a deployment model

| Model | Architecture | Operational boundary | Guide |
| --- | --- | --- | --- |
| Dedicated control plane | Each tenant receives its own NVIDIA Run:ai control plane, cluster components, GPU Operator, ingress, and supporting services. | Install, update, and remove the complete environment per tenant. | [Dedicated control plane](dedicated-control-plane/) |
| Central control plane | One NVIDIA Run:ai control plane and GPU Operator run on the Control Plane Cluster. Each tenant has separate registration and runtime resources. | Install the shared host foundation once, then register and manage each tenant separately. | [Central control plane](central-control-plane/) |

The central model shares infrastructure and requires an existing ingress-nginx deployment. It does not provide compute or network isolation by itself. Read the model guide's prerequisites, isolation boundaries, install order, and removal order before choosing it.

## Included StackTemplates

The dedicated model contains one StackTemplate:

- `run-ai-dedicated-control-plane` installs the complete dedicated environment.

The central model separates shared and per-tenant lifecycle into three StackTemplates:

- `run-ai-central-control-plane-host` installs the shared NVIDIA Run:ai control plane and GPU Operator.
- `run-ai-central-control-plane-registration` registers one tenant and publishes the credentials and connection details that tenant needs.
- `run-ai-central-control-plane` installs the NVIDIA Run:ai runtime components in one tenant cluster.

The `example/` directories contain StackInstances and tenant cluster configurations showing how these templates are used.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`source/common/`](source/common/) | Source shared by both deployment models. |
| [`source/dedicated-control-plane/`](source/dedicated-control-plane/) | Dedicated-model source files. |
| [`source/central-control-plane/`](source/central-control-plane/) | Central-model source files. |
| [`dedicated-control-plane/`](dedicated-control-plane/) | Generated dedicated-model manifests and documentation. |
| [`central-control-plane/`](central-control-plane/) | Generated central-model manifests and documentation. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Run:ai-specific source-sharing, naming, output, and variant rules. |

Edit files under `source/`. Do not edit the generated deployment-model directories directly.

## Render and test changes

From the repository root, generate the deployment-model directories:

```bash
./run-ai/render.sh
```

Review the generated changes, then verify that the generated files match their sources and run the manifest checks:

```bash
./run-ai/render.sh --check
```

The checks require Bash 4 or later, Python 3 with PyYAML, and `rg`. Integration tests that require a live cluster are documented in the deployment-model READMEs and their `tests/` directories.

For general Stack authoring and catalog contribution requirements, see the [repository README](../README.md#build-a-custom-stack) and [contribution checklist](../README.md#contribute-a-certified-stack).
