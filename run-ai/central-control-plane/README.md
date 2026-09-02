# NVIDIA Run:ai Central Control-Plane Stack

Central control-plane tenancy shares one NVIDIA Run:ai control plane and one NVIDIA GPU Operator among tenant clusters.
An administrator installs these shared components once. Each tenant runs its own cluster agent,
Prometheus operator, registry credentials, and workloads. Each tenant registers with the shared control plane.

This design follows vCluster's [shared platform stack](https://www.vcluster.com/blog/vcluster-shared-platform-stack)
pattern. `ray-io/soft-multitenancy` uses this pattern for the KubeRay operator.

`dedicated-control-plane/` gives each tenant its own ingress controller, GPU Operator, and control plane.

## Architecture

```
Control Plane Cluster
  ingress-nginx                        prerequisite, shared, not installed here
  NVIDIA GPU Operator                  installed ONCE by run-ai-central-control-plane-host
  NVIDIA Run:ai control plane                 installed ONCE by run-ai-central-control-plane-host
    +-- runai-backend: postgres, NATS, Thanos, tenants-manager
    +-- runai-control-plane-admin      admin credentials live here and nowhere else
  run-ai-central-control-plane-registration             one StackInstance per tenant, created by the cluster
    +-- runai-tenant-facts-<slug>      FQDN, cluster URL, UID, client secret, CA setting

  Tenant cluster "tenant-a"            nodes labelled tenant=tenant-a, synced in
    +-- NVIDIA Run:ai cluster agent           registered as NVIDIA Run:ai cluster "tenant-a"
    +-- Prometheus operator (CRDs)     the NVIDIA Run:ai operator creates the Prometheus instance
    +-- runai-tenant-facts             synced in; the tenant Stack's only source of values
    +-- runai-ca-cert                  synced from the host; trusts the control plane
    +-- runai-reg-creds-host           synced from the host; the JFrog credential
    +-- tenant workloads

  Tenant cluster "tenant-b"            nodes labelled tenant=tenant-b
    +-- ...
```

Each tenant gets an isolated Kubernetes API, RBAC, namespaces, and NVIDIA Run:ai cluster identity. It does
not get isolated compute or network. See [Isolation](#isolation).

## Control Plane Cluster prerequisites

| Requirement | Details |
| --- | --- |
| vCluster Platform | With StackInstance support, and `kubectl` access to the target cluster. |
| ingress-nginx | Already installed, IngressClass `nginx`, with a LoadBalancer address. This bundle does not install it. See [Ingress LoadBalancer address](#ingress-loadbalancer-address). |
| Storage class | For the shared control plane's persistent volumes. |
| GPU nodes | With NVIDIA drivers, and the `nvidia` RuntimeClass on the Control Plane Cluster. |
| Tenant node labels | Every GPU node a tenant may use must carry that tenant's label. See [Node labelling](#node-labelling). |
| JFrog token | Can pull images from `runai.jfrog.io`. |
| Job image | Nodes can pull the Platform-provided job image. It must include `openssl`, `kubectl`, `jq`, `curl`, and `sh`. For a private registry, see [Pulling the job image](#pulling-the-job-image). |

### Ingress LoadBalancer address

The host Stack takes the existing ingress-nginx LoadBalancer's external address as
`hostIngressAddress`, and `ingressProvider` says which kind it is:

| `ingressProvider` | `hostIngressAddress` | Derived FQDN when `domain` is empty |
| --- | --- | --- |
| `standard` (default) | LoadBalancer IPv4 address | `<controlPlaneName>.<address>.nip.io` |
| `aws` | ELB/NLB hostname | the hostname itself |

GCP and Azure publish an address, so `standard` fits. AWS publishes a hostname and never an address,
so `nip.io` has nothing to wrap: set `ingressProvider: aws`, and set `tenantClusterDomain` on every
tenant, because tenant domains derive from the same value. A registration that leaves it empty under
`aws` fails validation naming `clusterDomain` rather than registering an unresolvable domain.
`tests/validate-host-ingress.sh` reports which kind the cluster has.

#### The address is captured once, and never reconciled

`hostIngressAddress` is a parameter, not something this Stack reads back from the cluster. It is
copied into the control-plane FQDN, into `runai/runai-control-plane-endpoint`, into the
`runai-backend` Ingress host, and into every tenant's `clusterDomain`. Nothing re-reads it, and
nothing checks it still matches the live Service.

So when the ingress-nginx LoadBalancer address changes, everything keeps reporting Healthy and
nothing works. On AWS the address changes whenever the controller's Service is recreated, which
includes an ordinary `helm uninstall` / `helm install` of ingress-nginx at the same chart version:
a new NLB gets a new hostname, and the old one leaves public DNS entirely.

Symptoms, in the order you meet them:

- New tenants fail in the `cluster` task's chart pre-install hook with a bare `no such host` naming a
  hostname that appears nowhere in the current cluster.
- The NVIDIA Run:ai UI and every tenant agent cannot reach the control plane.
- Both StackInstances still report Healthy, with every task Ready.

Confirm it in one line. These three must agree with each other and with the live Service:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
kubectl -n p-default get stackinstance runai -o jsonpath='{.spec.parameters.hostIngressAddress}{"\n"}'
kubectl -n runai get cm runai-control-plane-endpoint -o jsonpath='{.data.fqdn}{"\n"}'
```

To recover, patch the parameter and let `bootstrap` republish the endpoint:

```bash
NEW=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
kubectl -n p-default patch stackinstance runai --type merge \
  -p "{\"spec\":{\"parameters\":{\"hostIngressAddress\":\"$NEW\"}}}"
```

Two things to expect while that runs.

First, `bootstrap` republishes `runai-control-plane-endpoint` before the `backend` task patches the
`runai-backend` Ingress, so for a short window the control plane advertises a hostname its own
Ingress does not yet answer for.

Second, if you patch immediately after reinstalling ingress-nginx, the `backend` task fails on
ingress-nginx's own admission webhook:

```text
UPGRADE FAILED: cannot patch "runai-backend-ingress" with kind Ingress: Internal error occurred:
failed calling webhook "validate.nginx.ingress.kubernetes.io": no endpoints available for service
"ingress-nginx-controller-admission"
```

The StackInstance goes Degraded and retries, up to four attempts a minute apart, which is normally
enough for the new controller pod to become Ready. If it burns all four, wait for
`kubectl -n ingress-nginx get endpoints ingress-nginx-controller-admission` to report an address and
re-apply. The dedicated stack gates on this with `runai-step-03-ingress-admission-ready`; the central
host Stack has no equivalent, because it treats ingress-nginx as a prerequisite it never installs.

Then re-run every tenant: each tenant's `clusterDomain` was derived from the old address at
registration time and does not update on its own.

A real `domain` you control avoids all of this. The LoadBalancer address then only has to be correct
in your DNS records, and it is the one thing in this list that a Stack cannot silently get wrong.

### Pulling the job image

Bootstrap Jobs use the vCluster Platform image. Platform provides its reference as `__image__`.
Platform does not provide the pod `imagePullSecrets`.

Dedicated control-plane Jobs run in a tenant cluster. vCluster syncs them with the workload ServiceAccount,
which uses `tenantImagePullSecret`. Central control-plane host Jobs run on the Control Plane Cluster.
They have no tenant workload ServiceAccount. Set a pull Secret when their registry requires credentials.

If your Platform image is from a public registry, ignore this. Otherwise check where it comes
from:

```bash
kubectl -n vcluster-platform get pod -l app=loft \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="manager")].image}'
```

If that registry needs credentials, create a pull Secret before you apply the host Stack and pass
its name as `hookImagePullSecret`. Two Stacks need it, and their Jobs run in different namespaces:
the host Stack's bootstrap in `runai`, and all three registration steps in `runai-backend`. Use the
same Secret name in both so one parameter value serves both Stacks.

```bash
for ns in runai runai-backend; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" create secret docker-registry platform-reg-creds \
    --docker-server=<REGISTRY> --docker-username=<USER> --docker-password=<TOKEN>
done
```

Then set `hookImagePullSecret: platform-reg-creds` on the host StackInstance and
`tenantImagePullSecret: platform-reg-creds` on the tenant cluster template. The template passes it
to the registration it creates. Set it on a hand-applied
registration StackInstance too, if you use one. Leave it unset everywhere if the image pulls
anonymously.

The cluster template must receive this registration value. It cannot discover it because the
registration's first Job needs a pull credential before it can read a value.

This is not `runai-reg-creds`. That Secret authenticates to `runai.jfrog.io` for the NVIDIA Run:ai product
images, and Kubernetes matches pull secrets by registry host, so it does nothing for a Platform
image hosted elsewhere. Both can be needed at once.

Symptom when it is missing: the task times out and its Job pod sits in `ImagePullBackOff`, while
the Platform itself runs fine.

```bash
kubectl -n runai get pods -l job-name=runai-bootstrap-certs
kubectl -n runai-backend get pods -l 'job-name' | grep restful-op
```

## Install order

Central control-plane tenancy is not a one-command install, but only the first three steps are yours to run. They
happen once per Control Plane Cluster. After that, creating a tenant cluster from the template
registers it too.

```bash
# 1. Register the Apps and StackTemplates with the Platform.
kubectl apply -f apps/
kubectl apply -f stacktemplate-host.yaml \
               -f stacktemplate-registration.yaml \
               -f stacktemplate.yaml

# 2. Install the shared control plane and GPU Operator. ONCE per Control Plane Cluster.
#    Set runaiRegistryCredentials, storageClass, hostIngressAddress, and the admin credentials first.
#    The StackInstance must be named `runai`.
kubectl apply -f example/stackinstance-host.yaml

# 3. Wait for it, and note the control-plane FQDN.
#    Tasks are under `.status.tasks`, each with `.name`, `.phase`, `.health`, and `.message`.
kubectl get stackinstance runai -n p-default \
  -o jsonpath='{.status.phase}{"\n"}{range .status.tasks[*]}  {.name}{"\t"}{.phase}{"\t"}{.health}{"\t"}{.message}{"\n"}{end}'
```

### 4. Create a tenant cluster

Apply `example/vcluster-template-with-runai-stack.yaml`, then create a cluster from it.
Set `nodeSelectorValue`. You can use any cluster name.

Creating a tenant cluster creates its registration. `spaceTemplate` writes a
`run-ai-central-control-plane-registration` StackInstance in the tenant space. Name this StackInstance
`runai-reg-<cluster name>`. It uses the cluster name as `tenantSlug`.

The tenant cluster and registration can start at the same time. The tenant `discover` task waits for
the facts Secret. It starts only after registration publishes that Secret.

Set `tenantImagePullSecret` when the Platform image needs credentials. Registration hook Jobs run
on the Control Plane Cluster. Their first Job needs this Secret before it can discover any values.
See [Pulling the job image](#pulling-the-job-image).

The registration Stack takes no credentials or control-plane FQDN. It reads
`runai-control-plane-admin` from `runai-backend`. Its `discover` task reads the FQDN, ingress address,
TLS mode, and CA setting from `runai/runai-control-plane-endpoint`. The NVIDIA Run:ai cluster domain is
`<slug>.<address>.nip.io`. It is not a vCluster API server URL.

The last task writes `runai-backend/runai-tenant-facts-<slug>`.
This Secret contains the control-plane FQDN, tenant URL, UID, client secret, and CA setting.
The cluster template syncs it as `runai/runai-tenant-facts`. The tenant Stack reads it before it installs the agent.
Do not copy these values into tenant parameters.

The cluster template also syncs the control-plane CA. See [Trusting the control plane](#trusting-the-control-plane).

The tenant cluster does not install the control plane or GPU Operator.
`sync.fromHost.nodes` copies labeled host nodes, GPU capacity, and NFD/GFD labels to the tenant API server.
`sync.fromHost.runtimeClasses` copies the `nvidia` RuntimeClass for NVIDIA Run:ai GPU workloads.
`sync.fromHost.customResources` copies the `clusterpolicies.nvidia.com/v1` definition and the host's
policy, read-only. That CRD ships with GPU Operator, which runs only on the Control Plane Cluster, and
NVIDIA Run:ai's `engine-operator` watches it: without the CRD it crash-loops on `no matches for kind
"ClusterPolicy"` and the cluster never comes up. It is required, not optional. A tenant created before
this mapping existed picks it up only once its cluster is updated from the template.

The NVIDIA Run:ai operator also looks up a DCGM exporter Service in the cluster it is installed in, and
refuses to finish installing without one. The exporter runs on the Control Plane Cluster, so the tenant
Stack's `gpushim` task answers that lookup with an endpoint-less Service in `gpu-operator`, and its
`cluster` task sets `global.nvidiaDcgmExporter.installedFromGpuOperator: false` so the operator does not
then look for the GPU Operator that would own it. See [Known gaps](#known-gaps) for what this costs.

### Registering a tenant ahead of its cluster

Use standalone registration to register a tenant before its cluster exists. You can also use it to
register a tenant whose name differs from its cluster name. Copy
`example/stackinstance-registration.yaml`. Set `tenantSlug`. Name the instance
`runai-reg-<tenantSlug>`. Set the cluster template `tenantSlug` to same value.

`tenantSlug` means that registration already exists. It stops the template from creating another
registration. It maps the facts Secret to existing registration. Leave it empty unless registration
already exists. Otherwise, the tenant waits for a facts Secret that no task writes.

`tenantSlug` must be unique across the control plane. Registration matches an existing NVIDIA Run:ai cluster
by that name, so two registrations sharing a slug adopt the same NVIDIA Run:ai cluster and either one can
deregister the other. Deriving it from the cluster name is what normally makes that automatic.

## Node labelling

Label the GPU nodes each tenant may use, and keep the values disjoint:

```bash
# GKE node pool level (recommended, labels persist on new nodes)
gcloud container node-pools update <pool-name> \
  --cluster <cluster-name> --region <region> \
  --node-labels=runai.vcluster.com/tenant=tenant-a

# Manual (does NOT survive autoscaler scale-ups)
kubectl label node <node-name> runai.vcluster.com/tenant=tenant-a

kubectl get nodes -l runai.vcluster.com/tenant=tenant-a
```

Two rules, both load-bearing:

- **A node must belong to at most one tenant.** Each tenant runs its own scheduler, so two tenants
  that can see the same node both believe they own its full `nvidia.com/gpu` capacity and allocate it
  independently, with nothing arbitrating. GPUs get oversubscribed and pods fail at admission.
- **Without labelled nodes a tenant syncs zero nodes and every pod is unschedulable.** There is no
  all-node fallback: `nodeSelectorValue` is required and has no default.

## TLS

TLS is a Control Plane Cluster concern. The host Stack's `bootstrap` step issues the certificate
once. Tenants never handle certificates at all and no tenant ever holds a private key.

By default `bootstrap` issues a self-signed CA and leaf inside the Control Plane Cluster. Use a
trusted certificate before production use.

| Property | Value |
| --- | --- |
| CA key | RSA 4096, valid 3650 days |
| Leaf key | RSA 2048, valid 825 days |
| Leaf SANs | `<fqdn>` and `*.<fqdn>` |

The step writes these Secrets, all on the Control Plane Cluster:

| Secret | Namespace | Contents |
| --- | --- | --- |
| `runai-backend-tls` | `runai-backend` | Served certificate and key. |
| `runai-ca-cert` | `runai-backend`, `runai` | CA as `runai-ca.pem`. The `runai` copy is what tenants sync. |
| `runai-internal-ca` | `runai-backend` | CA certificate and key, for reuse. |

The CA is stored in `runai-internal-ca` and reused. An upgrade reissues the leaf only when it no
longer covers the FQDN or expires within 30 days, so trust survives upgrades.

### Trusting the control plane

Tenants do not receive the CA as a value to copy, and they receive no registration output, no
control-plane address, and no registry token either. The tenant cluster template syncs three Secrets
into the tenant's own `runai` namespace and the tenant Stack reads all of its values from them:

```yaml
sync:
  fromHost:
    secrets:
      enabled: true
      mappings:
        byName:
          "runai/runai-ca-cert": "runai/runai-ca-cert"
          "runai-backend/runai-tenant-facts-{{ .Values.loft.virtualClusterName }}": "runai/runai-tenant-facts"
          "runai/runai-reg-creds": "runai/runai-reg-creds-host"
```

The facts mapping resolves because this template registered the cluster with this name.
`tenantSlug` selects both the registration and facts Secret for a hand-applied registration.

Tenant creators do not need certificates, registration outputs, or registry tokens.
CA rotation reaches each tenant through Secret sync. The tenant `cluster.url` uses the registered domain.

None of the three is a Stack task, so nothing would sequence them against the `cluster` task. The
tenant Stack's first task is `discover`, whose hook Job blocks until all three exist and then fails
naming whichever never arrived. Set `requireControlPlaneCA: "false"` on the tenant Stack when the
control plane serves a publicly trusted certificate: no `runai-ca-cert` is created in that case, and
waiting for one would never return.

`requireControlPlaneCA` must equal the host Stack's `customCAEnabled`. It is the one value a tenant
still restates, because it decides what `discover` waits for and the host's value only arrives in
the facts Secret `discover` is waiting on. `discover` therefore compares the two before it waits,
and fails naming both. The registration Stack takes no `tlsMode`: it reads the host's from the
endpoint ConfigMap, so those two cannot disagree at all.

### Use a trusted certificate

Set `tlsMode: user-provided` on the host Stack. It then skips `openssl` and publishes what you
supply, either an existing Secret in the `runai` namespace with keys `tls.crt`, `tls.key`, and
optionally `ca.crt`:

```yaml
parameters:
  tlsMode: user-provided
  userTlsSecretName: my-runai-tls
```

or inline PEM. Omit `userCaCert` when the chain is publicly trusted, and set `customCAEnabled: "false"`
on both the host and tenant Stacks. The Secret sync is then unnecessary but harmless.

A `nip.io` FQDN cannot get a publicly trusted certificate, and under central control-plane tenancy that one name is
shared by every tenant. Set the host Stack's `domain` parameter to a domain you control before you supply
a trusted certificate.

### Verify

Run against the Control Plane Cluster, not a tenant:

```bash
bash tests/verify-certs.sh
TLS_MODE=user-provided bash tests/verify-certs.sh
```

## Isolation

Central control-plane tenancy isolates Kubernetes API, RBAC, namespaces, and NVIDIA Run:ai cluster identity. Network
isolation requires host CNI enforcement; compute remains shared:

- Tenants share host nodes. Node labels partition them. They are a policy, not a boundary.
- `policies.networkPolicy` is enabled. Host CNI must enforce Kubernetes NetworkPolicy for this control
  to isolate tenant traffic. Tenant workloads may send HTTPS only to controller Pods in
  `ingressControllerNamespace` (default `ingress-nginx`): a public control-plane FQDN can DNAT to
  those Pods before CNI policy evaluation.
- `networking.advanced.fallbackHostCluster` remains unset (`false` by default). Tenants reach shared
  control plane through public ingress DNS; unresolved names are never forwarded to host DNS.
- Tenants share one NVIDIA Run:ai control plane. Separation inside it is NVIDIA Run:ai's own, through its projects
  and departments.
- No tenant receives control-plane administrator credentials, a TLS private key, or cluster-wide node
  permission. Each tenant does hold its own per-cluster agent OIDC secret, but as a Secret synced into
  its `runai` namespace instead of a value in a StackInstance or cluster parameter. It still reaches
  that Stack's task outputs, so restrict RBAC on `stackinstances` and `virtualclusterinstances`
  accordingly.
- Each tenant registration StackInstance is in its tenant space namespace on the Control Plane Cluster.
  Its outputs include only that tenant's FQDN, cluster UID, and client secret. The administrator password
  remains in `runai-backend/runai-control-plane-admin`. Only Stack Jobs read it. Apply the RBAC guidance to this space.

Use `dedicated-control-plane/` where compute isolation is required.

## Known gaps

- **GPU metrics.** `dcgm-exporter` runs on the Control Plane Cluster in namespace `gpu-operator`,
  outside every tenant's API server, so a tenant's Prometheus cannot scrape it and NVIDIA Run:ai GPU
  utilisation views are empty. Allocation still works because synced node objects provide capacity.
  The `nvidia-dcgm-exporter` Service in a tenant's own `gpu-operator` namespace is a placeholder with
  no selector and no endpoints: it exists so the NVIDIA Run:ai operator's dependency check passes, and
  it exports nothing. Do not give it endpoints. The host Service load-balances across every tenant's
  GPU nodes, so pointing a tenant at it returns other tenants' metrics, sampled at random. Real
  per-tenant metrics need a scrape path scoped to that tenant's nodes, which this Stack does not have
  yet. This is a policy, not a boundary.
- **Tenant workload TLS.** Tenant Ingresses are served with ingress-nginx's default certificate. Issue
  per-tenant certificates with cert-manager on the Control Plane Cluster if you need them.
- **Tenant volumes** use the Control Plane Cluster's default StorageClass. Only the shared control
  plane takes an explicit `storageClass`.

## Files

| File | Purpose |
| --- | --- |
| `apps/` | Apps used by Stack steps. Registered with the Platform once. |
| `apps/02-discover.yaml` | App `runai-step-02-discover`. Central-only. Waits for objects another Stack wrote or the vCluster syncer placed, so a task can declare outputs over them. |
| `apps/03-tenant-facts.yaml` | App `runai-step-03-tenant-facts`. Central-only. Writes the one per-tenant Secret the tenant Stack reads. |
| `apps/04-bootstrap.yaml` | App `runai-step-04-bootstrap-host`. Named apart from dedicated control-plane tenancy's `runai-step-04-bootstrap` because it runs on the Control Plane Cluster and takes `hookImagePullSecret`. |
| `apps/09-gpu-stack-shim.yaml` | App `runai-step-09-gpu-stack-shim`. Central-only. Installs no GPU stack. Creates the DCGM exporter Service the NVIDIA Run:ai operator looks up, with nothing behind it. |
| `apps/10-verify-cluster.yaml` | App `runai-step-10-verify-cluster`. Central-only. Fails the tenant Stack when the NVIDIA Run:ai operator has not brought the scheduler up, instead of reporting Healthy over a dead cluster. |
| `stacktemplate-host.yaml` | Shared control plane and GPU Operator. Apply once per Control Plane Cluster. |
| `stacktemplate-registration.yaml` | Registers one tenant. The cluster template creates one instance of it per tenant. Apply it by hand only to pre-register. |
| `stacktemplate.yaml` | Tenant runtime. Deployed inside each tenant cluster. |
| `example/stackinstance-host.yaml` | Example shared host foundation instance. |
| `example/stackinstance-registration.yaml` | Example registration instance, for the pre-registration path. |
| `example/vcluster-template-with-runai-stack.yaml` | Tenant cluster template. Owns both the tenant Stack and the tenant's registration. |
| `example/stackinstance-from-template.yaml` | Applies the tenant Stack by hand instead. |
| `tests/verify-certs.sh` | Checks published TLS material. Run against the Control Plane Cluster. |
| `tests/validate-host-ingress.sh` | Checks Control Plane Cluster prerequisites: ingress, GPU stack, and tenant node labels. |

Steps `authtoken`, `clusterreg`, and `clustercreds` use the `restful-operation` App in
`apps/restful-operation.yaml`, which is shared byte-for-byte with dedicated control-plane tenancy. Its
`defaultNamespace` is `runai-backend`, and that is load-bearing: a Stack may read a task output only
from a namespace its Apps deployed into, which for a `templateRef` task is the referenced App's
`defaultNamespace`, not the `namespace` parameter. Point either one somewhere else and every
registration output fails to capture.

`runaiVersion` must equal the chart versions in `apps/07-control-plane.yaml` and
`apps/08-cluster.yaml`. It cannot drive them: the Platform renders Go templates in an App's `values`
and `manifests`, never in its chart coordinates, so the version is pinned in the App files and
`runaiVersion` only feeds the `cluster-install-info?version=` query. A bump has to move all seven
sites together -- four chart pins, the `stacktemplate-registration.yaml` and
`dedicated-control-plane/stacktemplate.yaml` defaults, and `example/stackinstance-registration.yaml`.
`test-certified-manifests.sh` fails when they disagree. The host Stack takes no `runaiVersion`; it
registers nothing.

Control-plane chart source:

```text
https://runai.jfrog.io/artifactory/cp-charts-prod
```

## Release names

The Platform derives a task's Helm release name as `<StackInstance name>-<task name>-<hash>`, and
truncates it at 63 characters. The hash makes the release name **per-instance and unpredictable**:

```text
runai-backend/sh.helm.release.v1.runai-backend-468bef.v1     instance `runai`, task `backend`
gpu-operator/sh.helm.release.v1.runai-gpu-763ab5.v1          instance `runai`, task `gpu`
runai-backend/sh.helm.release.v1.found-backend-a6ab58.v1     instance `found`, task `backend`
```

Nothing here may depend on that name. Where a chart needs a fixed operand name, pin it in the App
instead: `apps/07-control-plane.yaml` sets `fullnameOverride` on the postgresql and nats sub-charts,
and `apps/05-prometheus-operator.yaml` sets `fullnameOverride: kube-prometheus-stack` so the operator
Deployment is `kube-prometheus-stack-operator` in every tenant.

That second one is not hypothetical. Without it the release name reaches the chart's fullname
template, truncation cuts `prometheus` in half, and the tenant gets a Deployment named something like
`ant-runai-1d304a-prometheu-operator`. The NVIDIA Run:ai operator looks up `prometheus-operator`
by name, does not find it, and reports the dependency missing while the `prometheus` task is Healthy.

Name registration instances `runai-reg-<tenantSlug>`. The host instance name is otherwise free: this
bundle has installed correctly under both `runai` and other names.

## Remove

Order matters, and nothing enforces it.

```bash
# 1. Every tenant cluster first.
#    This removes the tenant's agent but does NOT deregister it: the tenant has no admin token.

# 2. Then that tenant's registration instance. Its pre-delete hook deregisters exactly this tenant.
kubectl delete stackinstance runai-reg-tenant-a -n p-default

# 3. Only when no tenants remain, the shared host foundation.
kubectl delete stackinstance runai -n p-default
```

**Deleting the host foundation is destructive and irreversible.** It uninstalls the shared control
plane and drops the PostgreSQL, NATS, and Thanos Receive PVCs, which are set to delete with the
release. Every tenant loses its control plane and all NVIDIA Run:ai data at once, and every remaining
registration instance is left pointing at a dead API. Confirm the NVIDIA Run:ai UI lists zero clusters
first.

Removal does not delete namespaces or Prometheus release PVCs. Check remaining resources before you
delete the Apps.

### What removal leaves behind

Deleting the host StackInstance uninstalls every Helm release it owns, and stops there. Observed
leftovers on a cluster that had run four tenants:

| Left behind | Why | Matters because |
| --- | --- | --- |
| Namespaces `runai`, `runai-backend`, `gpu-operator` | Helm does not delete namespaces it did not create as release resources | Harmless. A reinstall reuses them. |
| Completed `restful-op-create-*` Jobs and their pods in `runai-backend`, one set per tenant ever registered, plus the `runai-backend-*-migrator` Jobs | They carry `helm.sh/hook-delete-policy: before-hook-creation`, which deletes them on the *next* run of the same hook, never on uninstall | They accumulate for the life of the cluster. Delete the namespace to clear them. |
| CRDs `clusterpolicies.nvidia.com` and `nvidiadrivers.nvidia.com` | Helm never removes CRDs | A reinstall is not actually starting cold. Delete them explicitly if you are testing a first install. |

Deleting a tenant cluster removes its tenant StackInstance with it, because that Stack runs inside
the tenant. It does not remove the tenant's registration instance in `p-default`, by design: that
instance's pre-delete hook is what deregisters the tenant, so it has to outlive the cluster. Nothing
garbage-collects it, so a tenant deleted through the UI and left there stays registered in the shared
control plane, and its `runai-backend/runai-tenant-facts-<slug>` Secret, holding a client secret,
stays with it. Step 2 above is not optional.
