# Contribute to run:ai manifests

`dedicated-control-plane/` and `central-control-plane/` contain generated files. Do not edit them.

## Change source files

Edit files in `source/`:

- `source/common/apps/`: Apps for dedicated and central control-plane tenancy.
- `source/dedicated-control-plane/`: Dedicated control-plane Apps, StackTemplates, examples, and docs.
- `source/central-control-plane/`: Central control-plane StackTemplates, examples, tests, and docs. Central creates three StackTemplates: host foundation, tenant registration, and tenant runtime.

Put a manifest in `common/` only if both generated versions must be byte-identical. Put tenancy-specific manifests in matching variant directory.

## Platform-global Apps

An App is a cluster-scoped Platform object. `metadata.name` identifies it. Both `apps/` directories apply to same Platform.

Renderer copies `common/apps/` first. It then merges variant directory by basename. A variant file can replace one common file in one variant.

Follow these rules:

- Do not give a variant App same `metadata.name` as a common App.
- Do not use a common App filename for a variant App unless contents are byte-identical. Exception: variant markers also change `metadata.name`.

Otherwise, Platform gets two Apps with same name and different content. Last applied App replaces other tenancy model. `test-certified-manifests.sh` checks this rule.

A StackTemplate references an App by name. Share a component between host and tenant Stacks by using one App. Choose StackTemplate that references it and cluster for StackInstance.

## Variant markers

Some manifests differ by few lines. Use markers in one `common/` file instead of creating two files:

```yaml
  # +dedicated:begin
  name: runai-step-04-bootstrap
  # +dedicated:end
  # +central:begin
  name: runai-step-04-bootstrap-host
  # +central:end
```

A `# +dedicated:begin` to `# +dedicated:end` block exists only in dedicated render. A `# +central:...` block exists only in central render. Renderer removes marker lines. Do not nest blocks. Renderer fails on an unclosed or orphaned marker.

Rules:

- Renderer processes only `*.yaml`. Markers in shell tests are not markers. `render.sh` fails if marker text remains in rendered output.
- An App that changes `metadata.name` by variant has two `name:` keys in source file. This is intentional. Source file is not valid YAML. Apply only rendered output.

Use a marker when variants differ by few lines and must stay aligned. Use separate variant file when they differ in structure.

Do not use a marker when an optional parameter works. `restful-operation` has optional `hookImagePullSecret`. Only central control-plane tenancy sets it. An unset parameter renders no value, so both variants use one App.

## Task outputs and namespaces

A Stack can read task output only from namespace where its Apps deploy resources. Platform gets this namespace from each child AppInstance `status.releaseNamespace`. For a `templateRef` task, it uses referenced App `defaultNamespace`. You cannot override it per task.

An App can deploy resources to another namespace through `namespace` parameter. This does not expand allowed output namespaces. `restful-operation` uses this pattern. Its `defaultNamespace` must match namespace in caller `outputs[].fromSecret.namespace`. `test-certified-manifests.sh` checks both values.

Dedicated control-plane tenancy does not show this problem. Its stack-wide allow-list includes `runai-backend`, where `backend` task deploys control plane. A Stack with only `restful-operation` tasks, such as central registration Stack, does not have this allow-list.

## Render

From repository root:

```bash
./run-ai/render.sh
```

Review generated changes. Then verify artifacts match source files:

```bash
./run-ai/render.sh --check
```

Renderer also checks tenancy boundaries. Dedicated output owns ingress deployment and readiness. Central output requires host ingress and has no dedicated-ingress task references.
