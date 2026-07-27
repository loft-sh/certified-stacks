# Contributing run:ai manifests

`dedicated-control-plane/` and `central-control-plane/` are committed generated artifacts. Do not edit them directly.

## Make changes

Edit files under `source/`:

- `source/common/apps/`: Apps shared by dedicated and central control-plane tenancy.
- `source/dedicated-control-plane/`: Dedicated control-plane Apps, StackTemplates, examples, and documentation.
- `source/central-control-plane/`: Central control-plane StackTemplates, examples, tests, and documentation. Central renders three StackTemplates: shared host foundation, per-tenant registration Stack, and tenant runtime.

Keep a manifest in `common/` only when both generated versions must be byte-identical. Put tenancy-specific manifests in matching variant directory.

## Apps are Platform-global

An App is a cluster-scoped Platform object keyed by `metadata.name`, and both variants' `apps/` directories are applied to the same Platform. The renderer copies `common/apps/` first, then merges the variant directory over it by basename, so a variant file can shadow a common file in one variant only.

That makes two rules load-bearing:

- Never give a variant App the same `metadata.name` as a common App.
- Never name a variant file after a common file unless the contents are byte-identical, or the
  difference comes from variant markers that also change `metadata.name`.

Breaking either produces two Apps with one name and different content; whichever is applied last wins and silently changes the other tenancy model. `test-certified-manifests.sh` enforces this.

A StackTemplate references an App by name, so sharing a component between the host and tenant Stacks needs no duplicate App. Decide which StackTemplate references it and which cluster the StackInstance targets.

## Variant markers

Some manifests are identical between the two variants except for a few lines. Rather than fork the
file, mark those lines in the single `common/` source:

```yaml
  # +dedicated:begin
  name: runai-step-04-bootstrap
  # +dedicated:end
  # +central:begin
  name: runai-step-04-bootstrap-host
  # +central:end
```

A block bounded by `# +dedicated:begin` and `# +dedicated:end` survives only in the dedicated render, `# +central:...`
only in central, and the marker lines themselves are always dropped. Blocks may not nest, and an
unterminated or orphaned marker fails the render rather than being ignored.

Two constraints:

- Only `*.yaml` is processed. A marker in a shell test is not a marker; `render.sh` fails on any
  that survive into rendered output, so a misplaced one is loud rather than silent.
- A marked App that changes its own `metadata.name` per variant makes the source file carry two
  `name:` keys. That is intentional and both values stay visible side by side, but it means the
  source is not valid YAML on its own. Only rendered output is ever applied.

Reach for a marker when the variants differ in a handful of lines and must not drift. Write a
separate variant file when they differ structurally.

Do not reach for one when a plain optional parameter does the job. `restful-operation` takes an
optional `hookImagePullSecret` that only central control-plane tenancy sets; that needs no marker, because an unset
parameter renders nothing and both variants keep one shared App.

## Task outputs and namespaces

A Stack may read a task output only from a namespace its Apps actually deployed into. The Platform
takes that set from each child AppInstance's `status.releaseNamespace`, which for a `templateRef`
task comes from the referenced App's `defaultNamespace` and cannot be overridden per task.

An App that places its resources somewhere else through a `namespace` parameter does not widen that
set. `restful-operation` does exactly this, so its `defaultNamespace` must equal the namespace its
callers declare in `outputs[].fromSecret.namespace`. `test-certified-manifests.sh` ties the two
together.

Dedicated control-plane tenancy masks the problem, because the allow-list is stack-wide and its `backend` task deploys
the control plane into `runai-backend` anyway. A Stack made only of `restful-operation` tasks, like
central's registration Stack, has no such cover.

## Render

From repository root:

```bash
./v2/run-ai/render.sh
```

Review generated changes, then verify artifacts match sources:

```bash
./v2/run-ai/render.sh --check
```

Renderer also checks core tenancy boundaries: dedicated output owns ingress deployment and readiness; central output requires host ingress and contains no dedicated-ingress task references.

## Automation

`.github/workflows/render-runai.yml` checks generated artifacts on pull requests. Pushes to `main` that change sources or renderer rerender artifacts and commit changes using GitHub Actions bot.
