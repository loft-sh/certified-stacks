# Run:ai Sveltos Stack POC

This context defines terms for POC that deploys one Run:ai instance to one disposable target cluster through Sveltos.

## Language

**Tenant**:
Immutable submitter and audit metadata for POC. It is not a Kubernetes isolation boundary, a Run:ai logical tenant, or an installed instance.
_Avoid_: namespace boundary, Run:ai tenant, isolation boundary

**RunAIInstance**:
One installed Run:ai control-plane and cluster-agent workload pair. POC has exactly one instance named `runai`.
_Avoid_: tenant, stack instance

**TargetCluster**:
Exclusive disposable Kubernetes cluster selected by Sveltos for POC deployment. It is not shared with other workloads.
_Avoid_: shared cluster, Run:ai cluster, registered cluster

**RunAIClusterName**:
Name of external cluster registration in Run:ai. It is distinct from TargetCluster identity.
_Avoid_: target cluster name, Kubernetes cluster name

**Registration Identity**:
Immutable POC run ID and TargetCluster identity stored with a Run:ai external cluster registration and target `runai-cluster-creds` Secret. Only an exact match permits retry adoption or external deletion.
_Avoid_: registration name match, inferred ownership

**Cluster Credentials Secret**:
Target-local `runai-cluster-creds` Secret containing `clusterUID`, `clientSecret`, POC Run ID, and TargetCluster identity. Cluster chart consumes it; teardown verifies identity before external deletion.
_Avoid_: generic REST output Secret, management credentials ConfigMap

**POC Run ID**:
Compiler-generated immutable identifier for one POC lifecycle. Retry must explicitly supply same ID; fresh run gets a new ID.
_Avoid_: latest run, instance name, automatic retry selection

**Launcher**:
One-shot compiler invocation that derives authenticated management-cluster submitter identity, requires exactly one selected managed cluster, performs read-only target preflight, then creates phase 01 only when checks pass. It rejects resources owned by another POC Run ID and records target cluster UID and pinned source digest.
_Avoid_: preflight Job, caller-supplied submitter, mutable source fetch, multi-cluster rollout, phase runner, automatic stale-run teardown, reconciliation controller

**Cluster Chart Wrapper**:
POC-owned Helm chart that wraps pinned `runai-cluster` chart and uses its documented environment or volume injection hook to reference target-local credentials. It does not copy credential values through management-cluster resources.
_Avoid_: vendor chart fork, credential bridge, post-install patch

**Phase Runner**:
Finite observer that polls one phase's ClusterSummary and target Jobs, then emits normalized success, failure, or timeout report. It never creates subsequent phases.
_Avoid_: phase orchestrator, reconciliation controller

**Phase Report**:
One management-cluster ConfigMap per POC Run ID containing labels and secret-scanned normalized phase status. It is UI's only POC status object.
_Avoid_: status CRD, target status ConfigMap, local-only report

**Safe Failure Summary**:
Whitelisted resource reference, condition type/reason, HTTP class, and phase code. It excludes raw Job logs and arbitrary status messages.
_Avoid_: raw logs, regex-redacted logs, verbatim error status

**Structural Secret Scan**:
Payload-free verification that management artifacts contain no Secret data fields, secret templates, known credential fields, or raw logs. It does not read target Secret values.
_Avoid_: secret-value scan, secret hashing, raw Secret retrieval

**Teardown**:
Explicit `teardown --run-id` operation that reads Phase Report and withdraws phases in reverse order. It never relies on selector removal or background garbage collection. Terminal install failure preserves state until this operation runs.
_Avoid_: selector teardown, automatic rollback, automatic garbage collection, manual profile deletion

**Phase Profile**:
One generated ClusterProfile for one POC Run ID and phase. Its deterministic `<run-id>-<phase>` name makes duplicate readiness events no-ops; a differing existing spec is terminal failure.
_Avoid_: event profile, repeated phase profile

**Phase Retry**:
Explicit retry withdraws failed phase profile, waits for owned-resource removal, then recreates identical profile under same POC Run ID. It does not create attempt-specific profiles.
_Avoid_: failed Job deletion, attempt profile, automatic retry

**Health-Check Failure**:
A false or missing target resource remains not-ready until phase timeout. Malformed health policy and RBAC denial are immediate terminal failures.
_Avoid_: undifferentiated timeout, immediate failure on absence

**Endpoint Handoff**:
Non-secret ingress FQDN derived from literal LoadBalancer IP and passed by EventTrigger into generated phase profile values. It is sole permitted target-to-management dynamic value path; hostname-only LoadBalancers are unsupported.
_Avoid_: target Secret propagation, management-plane credential copy, DNS-provider integration

**Registry Input Secret**:
Operator-precreated `kubernetes.io/dockerconfigjson` Secret of required fixed name in every consuming namespace. Compiler preflight validates metadata only.
_Avoid_: rendered registry credential, secret copier Job, generated registry Secret

**Fake GPU Labeling**:
Optional separate GPU-phase Job with reviewed cluster-scoped Node patch permission. TLS bootstrap has only namespace-scoped Secret Roles.
_Avoid_: bootstrap ClusterRole, real-GPU node labeling
