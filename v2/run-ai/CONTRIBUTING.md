# Contributing run:ai manifests

`hard-multitenancy/` and `soft-multitenancy/` are committed generated artifacts. Do not edit them directly.

## Make changes

Edit files under `source/`:

- `source/common/apps/`: Apps shared by hard and soft tenancy.
- `source/hard-multitenancy/`: Hard-tenancy Apps, StackTemplates, examples, and documentation.
- `source/soft-multitenancy/`: Soft-tenancy StackTemplates, examples, tests, and documentation.

Keep a manifest in `common/` only when both generated versions must be byte-identical. Put tenancy-specific manifests in matching variant directory.

## Render

From repository root:

```bash
./v2/run-ai/render.sh
```

Review generated changes, then verify artifacts match sources:

```bash
./v2/run-ai/render.sh --check
```

Renderer also checks core tenancy boundaries: hard output owns ingress deployment and readiness; soft output requires host ingress and contains no hard-ingress task references.

## Automation

`.github/workflows/render-runai.yml` checks generated artifacts on pull requests. Pushes to `main` that change sources or renderer rerender artifacts and commit changes using GitHub Actions bot.
