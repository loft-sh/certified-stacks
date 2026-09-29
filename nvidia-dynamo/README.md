# NVIDIA Dynamo Certified Stack

This integration installs the [NVIDIA Dynamo](https://github.com/ai-dynamo/dynamo) inference runtime through a native vCluster Platform Stack. After the Stack is healthy, the destination can serve AI models with `DynamoGraphDeployment` resources.

The files in this directory are the source manifests, examples, and checks used to build and validate the bundled `nvidia-dynamo` StackTemplate.

## Architecture

The `nvidia-dynamo` StackTemplate has one App task, `runtime`. It installs the `dynamo-platform` Helm chart from `https://helm.ngc.nvidia.com/nvidia/ai-dynamo` into the destination the StackInstance selects: a tenant cluster or a control plane cluster.

The release contains:

- The Dynamo operator, cluster-wide, with its validating and mutating admission webhooks.
- NATS, from the chart's bundled subchart.
- etcd, from the chart's bundled subchart.

The runtime owns the whole Dynamo stack in its destination, so it installs NATS and etcd instead of pointing at external instances. The chart's other optional components (Grove, KAI Scheduler, Snapshot) stay disabled.

## Requirements

- vCluster Platform 4.12 or later.
- Kubernetes 1.30 or later in the destination. This is the chart's `kubeVersion` constraint.
- A default StorageClass in the destination. NATS requests a 10Gi volume and etcd a 1Gi volume.
- Outbound access from the destination to `helm.ngc.nvidia.com`, `nvcr.io`, and Docker Hub for the chart and images.
- GPU nodes with the NVIDIA device plugin for the models you deploy afterwards. The runtime itself does not need GPUs.

Install the Stack at most once per destination. The operator, its CRDs, and its webhooks are cluster-scoped, so a second instance in the same destination conflicts with the first.

## Files

| Path | Purpose |
| --- | --- |
| [`stacktemplate.yaml`](stacktemplate.yaml) | The `nvidia-dynamo` StackTemplate. |
| [`example/stackinstance-tenant-cluster.yaml`](example/stackinstance-tenant-cluster.yaml) | Installs the runtime into a tenant cluster. |
| [`example/stackinstance-control-plane-cluster.yaml`](example/stackinstance-control-plane-cluster.yaml) | Installs the runtime into a control plane cluster. |
| [`test-certified-manifests.sh`](test-certified-manifests.sh) | Static checks for the template and examples, plus a `helm template` render of the default chart version. |

## Configure parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `version` | `1.5.0` | Version of the `dynamo-platform` Helm chart. |
| `namespace` | `dynamo-system` | Namespace the runtime is installed into. |

## Install

Connect `kubectl` to the Platform management API, then create a StackInstance in the project namespace that owns the destination. Set `destination` to your tenant cluster or control plane cluster first:

```bash
vcluster platform connect management
kubectl apply -n p-default -f nvidia-dynamo/example/stackinstance-tenant-cluster.yaml
```

You can also create the Stack from the Platform UI with the **NVIDIA Dynamo** template.

The `runtime` task waits for the release to become ready and times out after 20 minutes, which leaves room for slow image pulls.

## Verify

Watch the StackInstance until the `runtime` task is healthy:

```bash
kubectl get stackinstance nvidia-dynamo -n p-default \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}{.name}{"\t"}{.phase}{"\t"}{.message}{"\n"}{end}'
```

Then, in the destination, check the operator, NATS, and etcd pods and the Dynamo CRDs:

```bash
kubectl get pods -n dynamo-system
kubectl get crd dynamographdeployments.nvidia.com
```

## Upgrade

Change `version` on the StackInstance to move to another chart release. The operator applies its CRDs from its image at startup (`upgradeCRD: true` in the chart), so CRD changes roll out with the new operator version. Read the Dynamo release notes before upgrading across minor versions.

## Remove

Delete every `DynamoGraphDeployment` in the destination first. The operator manages finalizers on its resources, and removing it first can leave those resources stuck in deletion.

Then delete the StackInstance. The Stack deletes its `runtime` App, which uninstalls the Helm release. The examples set `prunePolicy: Prune`, which applies when a template update removes a task, not when the StackInstance is deleted.

Some resources remain after removal:

- The Dynamo CRDs. The operator applies them, so the Helm release does not own them.
- The NATS and etcd PersistentVolumeClaims created from the StatefulSet volume claim templates.

Delete them manually if you do not plan to reinstall the runtime.

## Known limitations

- The Stack does not expose Helm values beyond `version` and `namespace`. To customize the chart further, copy the StackTemplate as described in the [repository README](../README.md#use-a-certified-stack).
- NATS and etcd run as single, bundled instances. Use a custom copy of the template to point the operator at external NATS or etcd.

## Test changes

From the repository root, run the static checks:

```bash
./nvidia-dynamo/test-certified-manifests.sh
```

The checks require Python 3 with PyYAML, and Helm. CI also validates every manifest in this directory with a server-side dry run against vCluster Platform.

For general Stack authoring and catalog contribution requirements, see the [repository README](../README.md#build-a-custom-stack) and [contribution checklist](../README.md#contribute-a-certified-stack).
