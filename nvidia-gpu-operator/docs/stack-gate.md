# The reusable Stack gate

`nvidia-gpu-operator-stack-gate` is an App that waits for something to become true, optionally counts scheduler capacity, and optionally marks a contract ConfigMap ready for later tasks to read. This Stack uses it three times: `gpuready`, `dcgmready`, and the `cert-manager` task when cert-manager is preinstalled.

## Why a Job

A Stack `app` task is healthy when its AppInstance is ready. For a chart that installs an operator, ready means the operator's own pods run. That can be long before the thing the operator manages is usable. The GPU Operator is healthy well before a driver is built and the device plugin registers a GPU.

The gate turns the stronger condition into a Job. The App sets `wait: true`, so Platform runs Helm with `--wait --wait-for-jobs`. The task stays `Progressing` while the Job runs, becomes `Healthy` when the Job completes, and fails when the Job fails. The wait also becomes its own node in the task graph, with its own timeout and its own log, rather than a status buried inside another task.

A Job can check what a readiness probe or a per-object health check cannot:

- Sum allocatable `nvidia.com/gpu` across every node that matches a selector. Allocatable capacity is a fact about the node set, not about any object an operator owns.
- Wait on resources the release does not own, such as Nodes, or a DaemonSet another task created.
- Wait for a resource to exist, including one whose CRD is not served yet.
- Carry different conditions per task, from one App.

The trade-off is that the Job checks once. If the watched resource degrades an hour later, the task stays `Healthy`. Ongoing health is a monitoring concern, which NVSentinel covers in this Stack.

## What the gate does

The script runs up to four steps. Each one can be switched off.

1. **Wait for the resource to exist.** Polls `kubectl get <waitResource>`. Polling instead of `kubectl wait --for=create` also covers a CRD that is not served yet.
2. **Wait for it to report ready.** `kubectl wait <waitResource> --for=<waitCondition>`. With `waitCondition: rollout`, the gate runs `kubectl rollout status <waitResource>` instead, which waits for every scheduled pod of a Deployment, DaemonSet, or StatefulSet.
3. **Count scheduler capacity.** Sums allocatable `<capacityResource>` across nodes that match `<capacityNodeSelector>`, and blocks until it reaches `capacityMin`.
4. **Mark the contract ready.** Patches `ready`, `observedCount`, `resourceName`, and `verifiedAt` into the contract ConfigMap.

An empty `waitResource`, or `waitEnabled: "false"`, skips steps 1 and 2. A `capacityMin` of `0` makes step 3 count without blocking. An empty `contractName` skips step 4. The script refuses to run when all three are off, because that gate would do nothing.

All steps share one deadline, `timeoutSeconds`. When it passes, the Job fails with the step it was on and what it last observed.

The Job runs on `.Values.__image__`, the image vCluster Platform itself runs, which includes `kubectl`. Its root filesystem is read-only, it runs as non-root with all capabilities dropped, and it gets read-only access to Nodes and the watched kind only.

## The contract

The Helm release owns the contract ConfigMap and writes the keys in `contractData`. The gate adds only keys the release does not declare. A later `helm upgrade` therefore leaves `ready` and `observedCount` alone. Removing the release removes the contract.

A task declares Stack outputs from the contract, and later tasks consume them:

```yaml
outputs:
  - name: dcgmhost
    fromResource:
      apiVersion: v1
      kind: ConfigMap
      namespace: gpu-stack
      name: gpu-stack-contract
      jsonPath: '{.data.dcgmHost}'
```

```yaml
parameters:
  dcgmHost: '{{ .Outputs.gpuready.dcgmhost }}'
```

Rules to know:

- Platform captures outputs only after the task is healthy, so every key a task reads is already present.
- A task that declares outputs is not ready until every output is captured, reported as `CapturingOutputs`. A missing key holds the task until its timeout rather than failing it at once.
- Outputs can be read only from a namespace the Stack deployed a release into. For a `templateRef` task that is the App's `defaultNamespace`, `gpu-stack` for this gate. It cannot be changed per task.
- `fromResource` cannot read Secrets or cluster-scoped resources.
- A task that declares outputs needs a name of letters and digits only: `gpuready`, not `gpu-ready`.

## Reuse it

Add a task that references the gate and set only what you need:

```yaml
- name: metallbready
  dependsOn:
    - metallb
  timeout: 15m0s
  app:
    templateRef:
      name: nvidia-gpu-operator-stack-gate
    parameters:
      gateName: metallbready
      waitResource: ipaddresspool/default
      waitNamespace: metallb-system
      waitCondition: 'jsonpath={.status.conditions[?(@.type=="Ready")].status}=True'
      watchAPIGroup: metallb.io
      watchResources: ipaddresspools
      capacityMin: "0"
      timeoutSeconds: "780"
```

Stack-driven AppInstances do not apply App parameter defaults, so the gate falls back to built-in defaults for anything a task leaves out. Keep these rules in mind:

- **Grant it what it watches.** `watchAPIGroup` and `watchResources` build the gate's ClusterRole. Point it at a new kind without them and it polls a resource it cannot read until the deadline. Use an empty `watchAPIGroup` for core resources.
- **Give each gate a distinct `gateName`.** It appears in object names, the `app.kubernetes.io/component` label, and every log line.
- **Layer the timeouts.** Keep `timeoutSeconds` plus 60 below the task `timeout`, and the App `timeout` (25m) below the Platform per-deploy cap of 30m. The task timeout then reports the failure with the gate's reason.

Other conditions it can gate on:

- **Another Stack's contract:** `waitResource: configmap/gpu-stack-contract`, `waitNamespace: gpu-stack`, `waitCondition: jsonpath={.data.ready}=true`, `watchResources: configmaps`.
- **A different accelerator:** `capacityResource: amd.com/gpu`, `capacityNodeSelector: workload.example.com/pool=amd-compute`, `capacityMin: "2"`.
- **Publish only:** leave `waitResource` empty, set `capacityMin: "0"` and a `contractName`. The gate records the observed capacity without blocking on anything.

## Parameters

| Parameter | Built-in default | Purpose |
| --- | --- | --- |
| `gateName` | `gate` | Short name used in object names, labels, and logs |
| `cpuNodeSelector` | empty | Optional `key=value` node label for the gate Job |
| `waitEnabled` | `true` | `false` skips the resource wait |
| `waitResource` | empty | `TYPE/NAME` passed to `kubectl` |
| `waitNamespace` | empty | Empty for a cluster-scoped resource |
| `waitCondition` | empty | Passed to `kubectl wait --for`, or `rollout` for `kubectl rollout status`. Empty waits only for existence |
| `watchAPIGroup` | empty | API group granted read access |
| `watchResources` | empty | Plural resource granted read access |
| `capacityResource` | empty | Scheduler resource to count |
| `capacityMin` | `0` | Minimum allocatable to wait for |
| `capacityNodeSelector` | empty | Label selector limiting which nodes count |
| `contractName` | empty | ConfigMap to mark ready. Empty publishes nothing |
| `contractData` | empty | YAML string pairs the release writes into the contract |
| `timeoutSeconds` | `1380` | Deadline shared by every step |

## Operational notes

- **Job immutability.** The Job name carries a hash of the gate's settings. A changed setting creates a new Job instead of failing the upgrade on an immutable Job spec, and Helm removes the old Job.
- **No `ttlSecondsAfterFinished`.** The completed Job and its log remain until the release is removed.
- **Retries.** A failed Job fails the deploy. The AppInstance retries after 1, 5, and 15 minutes, and reinstalls the release so the Job runs again.
