# StackTemplate → Sveltos POC

Manifest-first proof that Sveltos can replace Run:ai Stack deployment. No compiler, phase engine, EventTrigger chain, management-plane credential transport, or StackInstance clone.

## Mapping

| StackTemplate concept | Sveltos manifest |
| --- | --- |
| Stack target | `ClusterProfile.spec.clusterSelector` |
| App with chart | `ClusterProfile.spec.helmCharts` |
| App with manifests | `ClusterProfile.spec.policyRefs` to management ConfigMap |
| Step order | profile `tier`; target-local workflow also waits for required target state |
| Stack input | target-local `ConfigMap` or `Secret` |
| REST output / sensitive output | target-local Job and target-local Secret |
| GPU template variant | `runai-fake-gpu` or `runai-real-gpu` profile |

Run:ai is example. Translation unit is Stack App, not numbered compiler phase.

## Files

- `00-target-inputs.example.yaml`: apply directly to target. Contains public config and placeholder target-only Secrets.
- `10-management-manifests.yaml`: management ConfigMaps plus ClusterProfiles.
- `20-real-gpu-profile.yaml`: replacement for fake-GPU profile. Apply only one GPU profile.

## Target-local workflow

`runai-bootstrap`, `runai-backend-installer`, and `runai-cluster-installer` are normal target Jobs deployed through Sveltos policy references. They handle Stack behavior with no native declarative Sveltos equivalent:

1. Wait for ingress LoadBalancer IP; derive nip.io FQDN.
2. Generate target TLS/admin/endpoint resources.
3. Install control plane with target-local values.
4. Call Run:ai registration APIs; write `runai-cluster-creds` only on target.
5. Install `runai-cluster` with chart-supported `controlPlane.existingSecret`.

Management manifests contain Secret names only. No password, access token, registration response, client secret, or Docker credential crosses to management cluster.

## Demo

- Current DigitalOcean A/B procedure: [`do-sfo3-jog-ai-demo.md`](do-sfo3-jog-ai-demo.md).
- Other cluster: apply target config first, create target-only Secrets, register and label its `SveltosCluster` with `stacks.loft.sh/runai=true`, then apply `10-management-manifests.yaml`.

For real GPU, delete fake profile then apply `20-real-gpu-profile.yaml` before backend/cluster installers run. Never apply both GPU profiles.

## Teardown

Delete ClusterProfiles in reverse dependency order. Then delete target-local workflow resources and input Secrets. Review Helm release/PVC retention before deleting namespaces.

```sh
kubectl --context MANAGEMENT delete clusterprofile runai-cluster runai-backend runai-fake-gpu runai-prometheus runai-bootstrap runai-ingress runai-foundation
kubectl --context TARGET -n runai delete job runai-cluster-installer runai-backend-installer runai-bootstrap --ignore-not-found
kubectl --context TARGET delete -f sveltos/00-target-inputs.example.yaml
```

## Deliberate limits

`tier` provides reconciliation priority. It is not Stack `dependsOn`. Dynamic prerequisites stay inside target-local Jobs. This POC demonstrates replacement pattern; general StackTemplate-to-Sveltos conversion still needs translation tooling for arbitrary App parameters, custom REST calls, and lifecycle semantics.

POC workflow RBAC is intentionally broad enough to create generated target resources. Narrow it per installation before production.
