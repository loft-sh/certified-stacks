#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Fail on a missing prerequisite by name, rather than part-way through with `mapfile: command not
# found` or `rg: command not found` after some checks have already reported ok.
#
# `mapfile` is a bash builtin, but only since bash 4.0. Every current Linux distribution ships bash
# 5.x, so this passes there; macOS still ships bash 3.2 as /bin/bash, where `mapfile` does not
# exist. `rg` and `python3` are not installed by default on either.
missing=()
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || missing+=("bash >= 4 (running ${BASH_VERSION}; macOS /bin/bash is 3.2 -- try 'brew install bash')")
for tool in python3 rg; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml); needed to verify the manifests parse as YAML"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

require() {
  grep -qE "$2" "$1" || {
    echo "FAIL $1: missing $2" >&2
    exit 1
  }
}

dedicated="$root/dedicated-control-plane/stacktemplate.yaml"
# Central control-plane tenancy renders three StackTemplates: the shared host foundation, one registration Stack per
# tenant, and the tenant runtime itself.
central="$root/central-control-plane/stacktemplate.yaml"
central_host="$root/central-control-plane/stacktemplate-host.yaml"
central_reg="$root/central-control-plane/stacktemplate-registration.yaml"

require "$dedicated" '^  name: run-ai-dedicated-control-plane$'
require "$dedicated" '^  annotations:$'
require "$dedicated" '^    vcluster\.com/certified: "true"$'
require "$central" '^  name: run-ai-central-control-plane$'
require "$central" '^  annotations:$'
require "$central" '^    vcluster\.com/certified: "true"$'
require "$central_host" '^  name: run-ai-central-control-plane-host$'
require "$central_host" '^  annotations:$'
require "$central_host" '^    vcluster\.com/certified: "true"$'
require "$central_reg" '^  name: run-ai-central-control-plane-registration$'
require "$central_reg" '^  annotations:$'
require "$central_reg" '^    vcluster\.com/certified: "true"$'
require "$dedicated" 'variable: ingressProvider'
require "$root/dedicated-control-plane/apps/02-ingress-nginx.yaml" '{{ if eq .Values.ingressProvider "aws" }}'

# Closed string choices render as UI options, not hand-maintained regex alternation. Keep defaults
# and valid values coupled, then reject future simple enum validations anywhere in generated manifests.
python3 - "$root" <<'OPTIONS' || exit 1
import re
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
expected = {
    "dedicated-control-plane/stacktemplate.yaml": {
        "ingressProvider": ["standard", "aws"],
        "tlsMode": ["self-signed", "user-provided"],
        "gpuProvider": ["standard", "gke"],
    },
    "central-control-plane/stacktemplate-host.yaml": {
        "ingressProvider": ["standard", "aws"],
        "tlsMode": ["self-signed", "user-provided"],
        "gpuProvider": ["standard", "gke"],
    },
    "central-control-plane/stacktemplate-registration.yaml": {
        "ingressProvider": ["standard", "aws"],
    },
    "dedicated-control-plane/example/vcluster-template-with-runai-stack.yaml": {
        "ingressProvider": ["standard", "aws"],
    },
    "dedicated-control-plane/apps/02-ingress-nginx.yaml": {
        "ingressProvider": ["standard", "aws"],
    },
    "central-control-plane/example/vcluster-template-with-runai-stack.yaml": {
        "ingressProvider": ["standard", "aws"],
    },
    "central-control-plane/apps/04-bootstrap.yaml": {
        "ingressProvider": ["standard", "aws"],
        "tlsMode": ["self-signed", "user-provided"],
    },
}
for relative, wanted in expected.items():
    path = root / relative
    parameters = yaml.safe_load(path.read_text())["spec"]["parameters"]
    by_name = {parameter["variable"]: parameter for parameter in parameters}
    for name, options in wanted.items():
        if by_name.get(name, {}).get("options") != options:
            print(f"FAIL {path}: {name} options must be {options}", file=sys.stderr)
            raise SystemExit(1)

simple_enum = re.compile(r"^\^\([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)+\)\$$")
for path in root.rglob("*.yaml"):
    for document in yaml.safe_load_all(path.read_text()):
        if not isinstance(document, dict):
            continue
        for parameter in document.get("spec", {}).get("parameters", []):
            if not isinstance(parameter, dict):
                continue
            if simple_enum.fullmatch(parameter.get("validation", "")):
                print(f"FAIL {path}: {parameter['variable']} uses enum validation; use options", file=sys.stderr)
                raise SystemExit(1)
OPTIONS

# The ingress task reads its `address` output from the controller Service by name, and the Platform
# names each stack child `<stack>-<task>-<hash>` (adapter.ChildName), so the release name is not
# knowable here. `fullnameOverride` is what decouples the two: the chart then names the Service
# `<override>-controller` regardless of the release. If these two drift apart the output resolves
# against a Service that does not exist, the task never goes Ready, and it fails on timeout with
# every downstream task stuck behind it.
ingress_app="$root/dedicated-control-plane/apps/02-ingress-nginx.yaml"
ingress_fullname=$(awk '/^      fullnameOverride: /{print $2; exit}' "$ingress_app")
[[ -n "$ingress_fullname" ]] || {
  echo "FAIL $ingress_app: no fullnameOverride; object names would follow the release name" >&2
  exit 1
}
ingress_svc_default=$(awk -F'defaultValue: ' '/variable: ingressControllerServiceName/{split($2, a, ","); print a[1]; exit}' "$dedicated")
if [[ "$ingress_svc_default" != "$ingress_fullname-controller" ]]; then
  echo "FAIL ingressControllerServiceName default "$ingress_svc_default" does not match the chart's" >&2
  echo "     fullnameOverride "$ingress_fullname" (expected "$ingress_fullname-controller")" >&2
  exit 1
fi
# A tenant template that derives the name from its own instance is reintroducing the same bug from
# the other end: the release carries a task hash the template cannot know.
if rg -q 'ingressControllerServiceName' "$root/dedicated-control-plane/example/vcluster-template-with-runai-stack.yaml"; then
  echo "FAIL tenant template overrides ingressControllerServiceName; the release name is not derivable" >&2
  exit 1
fi
# GKE Autopilot admits only a 1 - 6.5 GiB-per-CPU request ratio and rejects any pod outside it.
# That is not a clean failure on a tenant cluster: the workload runs on the host, but the syncer
# cannot write the pod back, so the virtual pod's status never leaves Pending and the task's `wait`
# spends its whole timeout on something that is in fact healthy. Checked across every App, in the
# chart values and in the inline manifests alike, because a third-party chart default is just as
# able to carry a bad ratio as anything written here.
python3 - "$root" <<'RATIO' || exit 1
import pathlib, re, sys

def cpu(s):
    return float(s[:-1]) / 1000 if s.endswith("m") else float(s)

def gib(s):
    for suffix, mult in (("Gi", 1), ("Mi", 1 / 1024), ("Ki", 1 / 1024 ** 2)):
        if s.endswith(suffix):
            return float(s[: -len(suffix)]) * mult
    return float(s) / 2 ** 30

failed = False
for path in sorted(pathlib.Path(sys.argv[1]).rglob("apps/*.yaml")):
    lines = path.read_text().split("\n")
    for i, line in enumerate(lines):
        opener = re.match(r"^(\s*)requests:\s*$", line)
        if not opener:
            continue
        indent = len(opener.group(1))
        values = {}
        for follower in lines[i + 1:]:
            entry = re.match(r'^(\s*)([a-z-]+):\s*"?([0-9.]+[A-Za-z]*)"?\s*$', follower)
            if not entry or len(entry.group(1)) <= indent:
                break
            values[entry.group(2)] = entry.group(3)
        if "cpu" not in values or "memory" not in values:
            continue
        ratio = gib(values["memory"]) / cpu(values["cpu"])
        if not 1.0 <= ratio <= 6.5:
            failed = True
            print(
                f"FAIL {path}:{i + 1}: requests {values['cpu']}/{values['memory']} is "
                f"{ratio:.3f} GiB per CPU, outside GKE Autopilot's 1 - 6.5",
                file=sys.stderr,
            )
sys.exit(1 if failed else 0)
RATIO

# Each generated variant has one contiguous App sequence. File, App name, and display label agree.
# A step may carry more than one App only where a Stack chooses between them at render time through
# a templated `templateRef.name`; step 6 does exactly that for gpuProvider. The count is pinned per
# step so an accidental extra App is still caught, and every file for a step is validated, not just
# the first, so the name-and-label agreement holds across all of them.
for variant in dedicated-control-plane central-control-plane; do
  for step in 00 01 02 03 04 05 06 07 08; do
    mapfile -t apps < <(find "$root/$variant/apps" -maxdepth 1 -type f -name "$step-*.yaml" | sort)
    # Step 6: 06-gpu-operator.yaml installs it, 06-gpu-operator-skip.yaml does not.
    [[ "$step" == 06 ]] && want=2 || want=1
    [[ "${#apps[@]}" == "$want" ]] || {
      echo "FAIL $variant: expected $want App(s) for step $step, found ${#apps[@]}" >&2
      exit 1
    }
    label=${step#0}
    [[ -n "$label" ]] || label=0
    for app in "${apps[@]}"; do
      require "$app" "^  name: runai-step-$step-"
      require "$app" "Step - $label]"
    done
  done
done

for path in \
  "$root/dedicated-control-plane/stacktemplate-aws.yaml" \
  "$root/dedicated-control-plane/apps/02-ingress-nginx-aws.yaml"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL obsolete AWS manifest present: $path" >&2
    exit 1
  }
done

test -f "$root/dedicated-control-plane/apps/06-gpu-operator.yaml"
# Still required under central, but the App now backs the shared HOST install, not the tenant. The
# ownership assertions below carry that meaning; without them this degrades to "a file exists".
test -f "$root/central-control-plane/apps/06-gpu-operator.yaml"
# The shared host components belong to the host Stack and must never reappear per tenant.
require "$central_host" 'runai-step-06-gpu-operator'
require "$central_host" 'runai-step-07-control-plane'
require "$central_host" 'runai-step-04-bootstrap'
require "$central_host" 'name: backend'
if grep -E 'runai-step-0(4|6|7)-' "$central" >/dev/null; then
  echo "FAIL central tenant StackTemplate installs shared host components" >&2
  exit 1
fi
# The credential boundary: a tenant Stack must not merely lack defaults for control-plane admin
# credentials, it must not declare the inputs at all.
if grep -E 'variable: (adminUsername|adminPassword)' "$central" >/dev/null; then
  echo "FAIL central tenant StackTemplate takes control-plane admin credentials" >&2
  exit 1
fi
# The host Stack owns no ingress controller; ingress-nginx stays a prerequisite for central.
if grep -E 'runai-step-02|name: ingress-ready' "$central_host" >/dev/null; then
  echo "FAIL central host StackTemplate deploys ingress-nginx" >&2
  exit 1
fi
# Registration must read the admin credential from a namespace-local Secret, never an input.
require "$central_reg" 'bodySecret: runai-control-plane-admin'
if grep -E 'variable: (adminUsername|adminPassword)' "$central_reg" >/dev/null; then
  echo "FAIL central registration StackTemplate takes control-plane admin credentials as inputs" >&2
  exit 1
fi
# Per-tenant output Secret names. Fixed names would let one tenant's teardown read another tenant's
# uid and deregister the wrong NVIDIA Run:ai cluster.
require "$central_reg" 'outputSecret: "runai-auth-token-\{\{ \.Values\.tenantSlug \}\}"'
require "$central_reg" 'outputSecret: "runai-cluster-registration-\{\{ \.Values\.tenantSlug \}\}"'
require "$central_reg" 'outputSecret: "runai-cluster-creds-\{\{ \.Values\.tenantSlug \}\}"'
require "$central_reg" 'name: clusterUID'
require "$central_reg" 'name: clientSecret'
# tenantSlug identifies the NVIDIA Run:ai cluster; a default makes collision the default behaviour.
if grep -E 'variable: tenantSlug.*defaultValue' "$central_reg" >/dev/null; then
  echo "FAIL registration tenantSlug has a default" >&2
  exit 1
fi

# Apps are Platform-global objects keyed by metadata.name, and both variants' apps/ dirs are applied
# to the same Platform. render.sh merges variant files over common ones by basename, so a variant
# file reusing a common App's name would yield two Apps with one name and different content:
# whichever applied last would win and silently cross-contaminate the other variant.
app_files=("$root"/dedicated-control-plane/apps/*.yaml "$root"/central-control-plane/apps/*.yaml)
# A variant-marker mistake in a common App can leave BOTH variants' `name:` lines in one rendered
# file. app_name_of below takes the first match, so the collision guard would not see it. Catch it
# here instead, where the symptom is unambiguous.
for f in "${app_files[@]}"; do
  n=$(grep -c '^  name: ' "$f" || true)
  [[ "$n" == 1 ]] || {
    echo "FAIL $f: expected exactly one App name, found $n" >&2
    exit 1
  }
done
app_name_of() { awk '/^  name: /{sub(/^  name: /, ""); print; exit}' "$1"; }
for i in "${!app_files[@]}"; do
  for j in "${!app_files[@]}"; do
    ((j > i)) || continue
    a="${app_files[$i]}"
    b="${app_files[$j]}"
    [[ "$(app_name_of "$a")" == "$(app_name_of "$b")" ]] || continue
    cmp -s "$a" "$b" || {
      echo "FAIL App '$(app_name_of "$a")' declared by differing files: $a and $b" >&2
      echo "     Apps are Platform-global; two files may share a name only if byte-identical." >&2
      exit 1
    }
  done
done

# Different App manifests with one Platform-global name must be separated automatically, and central
# StackTemplates must follow renamed references.
collision_root=$(mktemp -d)
trap 'rm -rf "$collision_root"' EXIT
cp -R "$root/source" "$collision_root/source"
cp "$root/render.sh" "$collision_root/render.sh"
cp "$collision_root/source/common/apps/01-registry-secret.yaml" \
  "$collision_root/source/central-control-plane/apps/01-registry-secret.yaml"
printf '\n# collision fixture\n' >> "$collision_root/source/central-control-plane/apps/01-registry-secret.yaml"
RENDER_SKIP_TESTS=1 bash "$collision_root/render.sh" >/dev/null
collision_name='runai-step-01-registry-secret-central-control-plane'
require "$collision_root/central-control-plane/apps/01-registry-secret.yaml" "^  name: $collision_name$"
require "$collision_root/central-control-plane/stacktemplate-host.yaml" "name: $collision_name"
cp "$collision_root/source/common/apps/01-registry-secret.yaml" \
  "$collision_root/source/central-control-plane/apps/99-collision-target.yaml"
python3 - "$collision_root/source/central-control-plane/apps/99-collision-target.yaml" "$collision_name" <<'PY'
from pathlib import Path
import sys

path, name = map(Path, sys.argv[1:])
path.write_text(path.read_text().replace("runai-step-01-registry-secret", str(name)))
PY
if RENDER_SKIP_TESTS=1 bash "$collision_root/render.sh" >/dev/null 2>&1; then
  echo "FAIL render.sh accepted an existing central App collision target" >&2
  exit 1
fi

# The bootstrap App is split by variant marker, not by forking the file. Under dedicated control-plane tenancy the
# Jobs are synced to the host and pull through vCluster's workload ServiceAccount, so they take no
# pull secret of their own. Under central they run directly on the Control Plane Cluster, where nothing
# supplies one, hence `hookImagePullSecret`. Cross-contamination either way is a real outage: dedicated
# would gain a parameter its StackTemplate never sets, central would silently keep failing to pull.
dedicated_boot="$root/dedicated-control-plane/apps/04-bootstrap.yaml"
central_boot="$root/central-control-plane/apps/04-bootstrap.yaml"
require "$dedicated_boot" '^  name: runai-step-04-bootstrap$'
require "$central_boot" '^  name: runai-step-04-bootstrap-host$'
if grep -qE 'hookImagePullSecret|imagePullSecrets' "$dedicated_boot"; then
  echo "FAIL $dedicated_boot: dedicated bootstrap must not carry a pull secret; tenantImagePullSecret covers it" >&2
  exit 1
fi
require "$central_boot" 'variable: hookImagePullSecret'
# Tenant cluster API Ingress hosts are `<vcluster>.<host IP>.nip.io`, not children of the NVIDIA Run:ai
# control-plane hostname. Host bootstrap certificate therefore needs its own nip.io wildcard SAN.
require "$central_boot" 'variable: additionalDnsName'
require "$central_boot" 'SAN="\$SAN,DNS:\$ADDITIONAL_DNS_NAME"'
require "$central_boot" 'for dns_name in "\$FQDN" "\*\.\$FQDN" "\$ADDITIONAL_DNS_NAME"; do'
require "$central_boot" 'subjectAltName=\$SAN'
# Under `standard` that wildcard is still derived; under `aws` the host address is a LoadBalancer
# hostname, a wildcard beneath it resolves for nobody, and the App's validation demands a leading
# `*.`, so the value must be empty.
require "$central_host" 'additionalDnsName: "\{\{ if eq \.Values\.ingressProvider .*aws.* \}\}\{\{ else \}\}\*\.\{\{ \.Values\.hostIngressAddress \}\}\.nip\.io\{\{ end \}\}"'
n=$(grep -c 'imagePullSecrets:' "$central_boot" || true)
[[ "$n" == 2 ]] || {
  echo "FAIL $central_boot: expected imagePullSecrets in both bootstrap Jobs, found $n" >&2
  exit 1
}
# The discover App is central-only. It exists to read objects some other Stack wrote, or the vCluster
# syncer placed, and dedicated control-plane tenancy has neither: one Stack there owns every value it needs. It is also
# where the tenant Stack blocks on the synced control-plane CA, so dropping the wait Job turns a
# Secret that never arrives into late TLS failures from the NVIDIA Run:ai agent instead of a failed task.
central_discover="$root/central-control-plane/apps/02-discover.yaml"
require "$central_discover" '^  name: runai-step-02-discover$'
# Fixed namespace, not a parameter: the outputs allow-list follows the release namespace, which for a
# templateRef task is this App's defaultNamespace. A parameter would move the manifests without
# moving the allow-list entry and every declared output would fail to capture.
require "$central_discover" '^  defaultNamespace: runai$'
# A pre-install/pre-upgrade hook Job is the whole mechanism: Helm blocks on it, so the release and
# every dependent task wait. Anything else and the task reports success before the objects exist.
require "$central_discover" '"helm.sh/hook": pre-install,pre-upgrade'
if [[ -e "$root/dedicated-control-plane/apps/02-discover.yaml" ]]; then
  echo "FAIL dedicated control-plane tenancy renders the central-only discover App" >&2
  exit 1
fi
# A mismatch used to surface as `failed pre-install: exit status 1` on the StackInstance, with the
# real cause only in a Job log inside the tenant. The timeout branch has to name the contract that
# was not met, or the next person debugs a Helm hook instead of a Secret mapping.
require "$central_discover" 'sync\.fromHost\.secrets\.mappings'
require "$central_discover" 'runai-backend/runai-tenant-facts-<registration slug>'

# The host Stack must reference the host App and pass the value through, or the parameter is dead.
require "$central_host" 'templateRef: \{ name: runai-step-04-bootstrap-host \}'
if grep -qE 'name: runai-step-04-bootstrap \}' "$central_host"; then
  echo "FAIL $central_host: references the dedicated bootstrap App" >&2
  exit 1
fi
require "$central_host" 'variable: hookImagePullSecret'
require "$central_host" 'hookImagePullSecret: "\{\{ \.Values\.hookImagePullSecret \}\}"'
# It names a Secret that must already exist; a default would point every install at a missing one.
if grep -E 'variable: hookImagePullSecret' "$central_host" | grep -q 'defaultValue'; then
  echo "FAIL $central_host: hookImagePullSecret must not have a defaultValue" >&2
  exit 1
fi

# Registration discovers the control plane instead of being told where it is. A restated FQDN can
# only disagree with the one the control plane is served on, and the host Stack already published it.
if grep -E 'variable: controlPlaneFqdn' "$central_reg" >/dev/null; then
  echo "FAIL central registration takes controlPlaneFqdn as an input; read the endpoint ConfigMap" >&2
  exit 1
fi
require "$central_reg" 'templateRef: \{ name: runai-step-02-discover \}'
require "$central_reg" 'name: runai-control-plane-endpoint'
require "$central_reg" 'baseURL: "https://\{\{ \.Outputs\.discover\.controlplanefqdn \}\}"'
# The endpoint ConfigMap is what makes that possible, in both variants: the same App writes it.
for boot in "$dedicated_boot" "$central_boot"; do
  require "$boot" 'customCAEnabled: "\{\{ \.Values\.customCAEnabled \| default "true" \}\}"'
done
# Registration must use host-published TLS behavior without branching on a task output.
require "$central_boot" 'tlsInsecure:'
require "$dedicated" 'customCAEnabled: "\{\{ \.Values\.customCAEnabled \}\}"'
require "$central_host" 'customCAEnabled: "\{\{ \.Values\.customCAEnabled \}\}"'

# One Secret per tenant is the whole interface to that tenant's Stack. The slug suffix is load
# bearing for the same reason as the output Secrets above: every registration shares runai-backend.
reg_app="$root/central-control-plane/apps/01-registry-secret.yaml"
central_facts="$root/central-control-plane/apps/03-tenant-facts.yaml"
require "$central_facts" '^  name: runai-step-03-tenant-facts$'
require "$central_facts" '^  defaultNamespace: runai-backend$'
require "$central_facts" 'name: "runai-tenant-facts-\{\{ \.Values\.tenantSlug \}\}"'
require "$central_reg" 'templateRef: \{ name: runai-step-03-tenant-facts \}'
require "$central_reg" '^    - name: facts$'
if [[ -e "$root/dedicated-control-plane/apps/03-tenant-facts.yaml" ]]; then
  echo "FAIL dedicated control-plane tenancy renders the central-only tenant facts App" >&2
  exit 1
fi

# restful-operation stays ONE App for both variants; its pull secret is simply optional and dedicated
# never sets it. Byte-identity across the two rendered copies is covered by the collision guard.
rest="$root/central-control-plane/apps/restful-operation.yaml"
require "$rest" 'variable: hookImagePullSecret'
n=$(grep -c 'imagePullSecrets:' "$rest" || true)
[[ "$n" == 2 ]] || {
  echo "FAIL $rest: expected imagePullSecrets in both hook Jobs, found $n" >&2
  exit 1
}
# A Stack may read a task output only from a namespace its Apps deployed into, and for a templateRef
# task that is the referenced App's defaultNamespace, NOT the `namespace` parameter. The registration
# Stack is all restful-operation tasks, so its output namespaces and this App's defaultNamespace have
# to agree or every capture fails with "which this stack has not deployed into".
rest_ns=$(awk '/^  defaultNamespace: /{print $2; exit}' "$rest")
[[ "$rest_ns" == runai-backend ]] || {
  echo "FAIL $rest: defaultNamespace is '$rest_ns'; the registration Stack reads outputs from runai-backend" >&2
  exit 1
}
# Generalised from the same rule: every namespace a StackTemplate declares an output over must be
# the defaultNamespace of some App it references. This is the constraint the discovery tasks lean on,
# so check it for every template rather than for the one Stack it first bit.
app_default_ns() { # app-name variant-dir
  local name="$1" dir="$2" f
  for f in "$dir"/apps/*.yaml; do
    [[ "$(app_name_of "$f")" == "$name" ]] || continue
    awk '/^  defaultNamespace: /{print $2; exit}' "$f"
    return
  done
}
check_output_namespaces() { # stacktemplate variant-dir
  local st="$1" dir="$2" allowed=() name ns
  while read -r name; do
    ns=$(app_default_ns "$name" "$dir")
    [[ -n "$ns" ]] && allowed+=("$ns")
  done < <(grep -o 'templateRef: { name: [a-z0-9-]*' "$st" | awk '{print $NF}' | sort -u)
  while read -r ns; do
    [[ " ${allowed[*]} " == *" $ns "* ]] || {
      echo "FAIL $st: declares an output over namespace '$ns', which no App it references deploys into" >&2
      echo "     The Platform rejects that capture with \"which this stack has not deployed into\"." >&2
      exit 1
    }
  done < <(awk '/^      outputs:/{o=1} /^    - name: /{o=0} o' "$st" \
    | grep -oE 'namespace: [a-z0-9-]+' | awk '{print $NF}' | sort -u)
}
check_output_namespaces "$dedicated" "$root/dedicated-control-plane"
check_output_namespaces "$central" "$root/central-control-plane"
check_output_namespaces "$central_host" "$root/central-control-plane"
check_output_namespaces "$central_reg" "$root/central-control-plane"
# Every registration task that runs a hook Job must be handed the pull secret; missing it on one
# leaves that Job unable to pull while the others succeed, which reads as a flake. The facts task
# runs no Job, so it takes none.
n=$(grep -c 'hookImagePullSecret: "{{ .Values.hookImagePullSecret }}"' "$central_reg" || true)
[[ "$n" == 4 ]] || {
  echo "FAIL $central_reg: expected all 4 Job-running tasks to receive hookImagePullSecret, found $n" >&2
  exit 1
}
require "$central_reg" 'variable: hookImagePullSecret'
if grep -E 'variable: hookImagePullSecret' "$central_reg" | grep -q 'defaultValue'; then
  echo "FAIL $central_reg: hookImagePullSecret must not have a defaultValue" >&2
  exit 1
fi

require "$dedicated" 'name: ingressAddress'
require "$dedicated" 'name: clusterUID'
require "$dedicated" 'name: clientSecret'
expected_tasks=$'namespace\nregistry\ningress\ningress-ready\nbootstrap\nprometheus\ngpu\nbackend\nauthtoken\nclusterreg\nclustercreds\ncluster'
actual_tasks=$(awk '/^  tasks:/{in_tasks=1; next} /^  publishedOutputs:/{in_tasks=0} in_tasks && /^    - name: / {sub(/^    - name: /, ""); print}' "$dedicated" | sort)
expected_tasks=$(printf '%s\n' "$expected_tasks" | sort)
[[ "$actual_tasks" == "$expected_tasks" ]] || {
  echo "FAIL dedicated task graph changed" >&2
  exit 1
}

# Central's three task graphs. The split of shared host components from tenant components is the whole
# point of central control-plane tenancy, so pin each graph the same way dedicated's is pinned.
check_tasks() { # file label expected-newline-separated
  local got want
  got=$(awk '/^  tasks:/{t=1; next} /^  publishedOutputs:/{t=0} t && /^    - name: / {sub(/^    - name: /, ""); print}' "$1" | sort)
  want=$(printf '%s\n' "$3" | sort)
  [[ "$got" == "$want" ]] || {
    echo "FAIL $2 task graph changed" >&2
    echo "  want: $(echo "$want" | tr '\n' ' ')" >&2
    echo "  got:  $(echo "$got" | tr '\n' ' ')" >&2
    exit 1
  }
}
check_tasks "$central" "central tenant" $'discover\nregistry\nprometheus\ngpushim\ncluster\nverify'
check_tasks "$central_host" "central host" $'namespace\nregistry\nbootstrap\ngpu\nbackend'
check_tasks "$central_reg" "central registration" $'discover\nauthtoken\nclusterreg\nclustercreds\nfacts'

# The NVIDIA Run:ai operator probes for its GPU and monitoring dependencies inside the cluster it is
# installed in. Central tenancy keeps that stack on the Control Plane Cluster, so each probe has to be
# answered here or the operator never creates the scheduler and every task still reports Healthy.
gpu_shim="$root/central-control-plane/apps/09-gpu-stack-shim.yaml"
require "$gpu_shim" '^  name: runai-step-09-gpu-stack-shim$'
require "$gpu_shim" '^  defaultNamespace: gpu-operator$'
require "$gpu_shim" '^        name: nvidia-dcgm-exporter$'
# The operator matches the exporter on this label, not on the Service name. Without it the check
# reports `dcgm-exporter service not found in the cluster` no matter what the Service is called.
require "$gpu_shim" '^          app: nvidia-dcgm-exporter$'
# Endpoints here would point one tenant's Prometheus at a Service shared by every tenant's GPU nodes.
if rg -q '^\s+selector:' "$gpu_shim"; then
  echo "FAIL $gpu_shim: the placeholder DCGM Service must stay endpoint-less" >&2
  exit 1
fi
require "$central" 'templateRef: \{ name: runai-step-09-gpu-stack-shim \}'
# The check runs from the cluster chart's pre-install hook, so the Service must already exist.
if ! rg -U -q -- '- name: cluster\n      dependsOn: \[discover, registry, prometheus, gpushim\]' "$central"; then
  echo "FAIL $central: cluster must wait for the GPU stack placeholder" >&2
  exit 1
fi
require "$central" 'dcgmExporterNamespace: gpu-operator'
cluster_app="$root/central-control-plane/apps/08-cluster.yaml"
require "$cluster_app" 'variable: dcgmExporterNamespace'
require "$cluster_app" 'installedFromGpuOperator: false'
# Dedicated tenancy installs the real GPU Operator in the same cluster. Leaving the namespace unset
# there keeps the chart default, which is the operator managing its own exporter.
if rg -q 'dcgmExporterNamespace: [^"]' "$dedicated"; then
  echo "FAIL $dedicated: dedicated tenancy must not declare an external DCGM exporter" >&2
  exit 1
fi

# The Platform's release names are per-instance and hashed, and the chart truncates them at 63
# characters, so without this the prometheus-operator Deployment is named differently in every tenant
# and NVIDIA Run:ai reports it missing while this task is Healthy.
require "$root/central-control-plane/apps/05-prometheus-operator.yaml" '^      fullnameOverride: kube-prometheus-stack$'
require "$root/dedicated-control-plane/apps/05-prometheus-operator.yaml" '^      fullnameOverride: kube-prometheus-stack$'

# The charts installing is not the same as NVIDIA Run:ai working, and nothing else in the Stack
# notices the difference.
verify_app="$root/central-control-plane/apps/10-verify-cluster.yaml"
require "$verify_app" '^  name: runai-step-10-verify-cluster$'
require "$verify_app" '"helm.sh/hook": post-install,post-upgrade'
# Helm blocking on a failed hook Job is the whole mechanism: it is what turns an unusable NVIDIA
# Run:ai cluster into a failed task instead of a Healthy one. A retry would hide the failure.
require "$verify_app" '^        backoffLimit: 0$'
require "$verify_app" 'serviceaccount runai-scheduler'
require "$central" 'templateRef: \{ name: runai-step-10-verify-cluster \}'
if ! rg -U -q -- '- name: verify\n      dependsOn: \[cluster\]' "$central"; then
  echo "FAIL $central: verify must run after the cluster task" >&2
  exit 1
fi

# Bootstrap creates runai-backend resources before the backend chart exists. Its namespace must
# exist before bootstrap's Helm pre-install hook renders its admin Secret and RBAC there.
namespace_app="$root/dedicated-control-plane/apps/00-runai-backend-namespace.yaml"
require "$namespace_app" '^  name: runai-step-00-runai-backend-namespace$'
require "$namespace_app" '^  defaultNamespace: runai$'
require "$namespace_app" '^      kind: Namespace$'
require "$namespace_app" '^        name: runai-backend$'
require "$dedicated" 'templateRef: \{ name: runai-step-00-runai-backend-namespace \}'
require "$central_host" 'templateRef: \{ name: runai-step-00-runai-backend-namespace \}'
for template in "$dedicated" "$central_host"; do
  if ! rg -U -q -- '- name: registry\n      dependsOn: \[namespace\]' "$template"; then
    echo "FAIL $template: registry must wait for runai-backend namespace" >&2
    exit 1
  fi
  require "$template" 'copyToControlPlaneNamespace: "true"'
done

# GKE rejects a `system-node-critical` pod outright when its namespace holds no ResourceQuota scoped
# to that PriorityClass, and the GPU Operator chart hardcodes that class while shipping no quota of
# its own. Step 0 supplies the gpu-operator namespace and the quota together, so assert the scope
# itself and not just that a quota exists: the wrong scope fails exactly like no quota at all.
require "$namespace_app" '^        name: gpu-operator$'
require "$namespace_app" '^      kind: ResourceQuota$'
require "$namespace_app" '^        namespace: gpu-operator$'
require "$namespace_app" '^            - scopeName: PriorityClass$'
require "$namespace_app" '^              operator: In$'
require "$namespace_app" '^                - system-node-critical$'
# Every gpu task must order itself after that namespace, or it can start first and spend its whole
# timeout on pods admission keeps rejecting.
for template in "$dedicated" "$central_host"; do
  if ! rg -U -q -- '- name: gpu\n      dependsOn: \[[^]]*\bnamespace\b[^]]*\]' "$template"; then
    echo "FAIL $template: gpu must wait for the gpu-operator namespace and its scoped pod quota" >&2
    exit 1
  fi
done

# GKE owns the node-level GPU stack, so on a default GKE GPU pool the GPU Operator does not merely
# duplicate it, it fails: the toolkit never finds Google's driver, and every operand the operator
# stamps `runtimeClassName: nvidia` onto is refused a sandbox. `gpuProvider: gke` therefore installs
# nothing. A task cannot be conditionally skipped, so the choice rides on the one lever that does
# work -- a templated `templateRef.name` -- which is easy to "simplify" back into a constant by
# someone who does not know why it is a template. Pin it.
skip_app="$root/dedicated-control-plane/apps/06-gpu-operator-skip.yaml"
require "$skip_app" '^  name: runai-step-06-gpu-operator-skip$'
# The whole point of the skip App: it must not install the chart. `manifests` also takes precedence
# over `chart` in the Platform, so a chart added here would be silently inert rather than loud.
require "$skip_app" '^    manifests: |-$'
if grep -qE '^      (chart|repoURL|version):' "$skip_app"; then
  echo "FAIL $skip_app: skip App must install no chart" >&2
  exit 1
fi
for template in "$dedicated" "$central_host"; do
  require "$template" 'variable: gpuProvider'
  require "$template" 'variable: gpuProvider'
  if ! grep -qF -- 'templateRef: { name: "runai-step-06-gpu-operator{{ if eq .Values.gpuProvider \"gke\" }}-skip{{ end }}" }' "$template"; then
    echo "FAIL $template: gpu templateRef must select the -skip App when gpuProvider is gke" >&2
    exit 1
  fi
done
require "$central" 'copyToControlPlaneNamespace: "false"'
require "$dedicated" 'dependsOn: \[ingress, registry, namespace\]'
require "$central_host" 'dependsOn: \[registry, namespace\]'

# The facts Secret is the only source of a tenant's connection values. A tenant must never re-derive
# them or accept a second copy of the NVIDIA Run:ai cluster URL, UID, client secret, or control-plane FQDN.
require "$central" 'templateRef: \{ name: runai-step-02-discover \}'
require "$central" 'awaitSecrets: "runai-tenant-facts,runai-reg-creds-host'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-tenant-facts, key: fqdn \}'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-tenant-facts, key: clusterdomain \}'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-tenant-facts, key: uid \}'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-tenant-facts, key: clientsecret \}'
# requireControlPlaneCA decides what discover waits for, so it cannot be read from the Secret
# discover is waiting on. It is checked against that Secret instead, before the wait, so a
# disagreement with the host names both values rather than timing out or -- in the false-against-a-
# custom-CA direction -- starting the NVIDIA Run:ai agent with nothing to trust.
require "$central" 'assertSecret: runai-tenant-facts'
require "$central" 'assertSecretKey: customcaenabled'
require "$central" 'assertSecretValue: "\{\{ \.Values\.requireControlPlaneCA \}\}"'
require "$root/central-control-plane/apps/02-discover.yaml" 'if \[ "\$actual" != "\$ASSERT_VALUE" \]; then'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-tenant-facts, key: customcaenabled \}'
require "$central" 'clusterFqdn: "\{\{ \.Outputs\.discover\.clusterdomain \}\}"'
# The cluster task's full dependency list, gpushim included, is pinned with the GPU checks below.
# The CA wait is conditional because a publicly trusted control plane creates no CA Secret at all, and
# an unconditional wait would hang exactly that install.
require "$central" 'variable: requireControlPlaneCA'
require "$central" '\{\{ if \.Values\.requireControlPlaneCA \}\},runai-ca-cert\{\{ end \}\}'
# The tenant cluster template creates this tenant's registration as part of creating the cluster, so
# `discover` can start while the Stack that writes the facts Secret is still running. The task retry
# budget is fixed at 4 attempts a minute apart and is not configurable, so that latency has to be
# absorbed by waiting. The await must also finish INSIDE the task, or a Secret that never arrives
# surfaces as a task timeout instead of a message naming it.
to_seconds() { # 600 | 12m | 1h
  local n="${1%[smh]}" u="${1##*[0-9]}"
  case "$u" in
    ""|s) echo "$n" ;;
    m) echo $((n * 60)) ;;
    h) echo $((n * 3600)) ;;
    *) echo "FAIL unrecognised duration: $1" >&2; exit 1 ;;
  esac
}
central_await=$(awk '/^    - name: discover$/{d=1} d && /awaitTimeoutSeconds:/{gsub(/[^0-9]/, ""); print; exit}' "$central")
central_discover_timeout=$(awk '/^    - name: discover$/{d=1} d && /^      timeout:/{print $2; exit}' "$central")
[[ -n "$central_await" && "$central_await" -gt 300 ]] || {
  echo "FAIL $central: discover must raise awaitTimeoutSeconds above the App default of 300; got '${central_await:-unset}'" >&2
  echo "     It now waits out a concurrent registration, not just the vCluster syncer." >&2
  exit 1
}
[[ -n "$central_discover_timeout" ]] && [[ "$(to_seconds "$central_discover_timeout")" -ge "$central_await" ]] || {
  echo "FAIL $central: discover timeout '${central_discover_timeout:-unset}' is below awaitTimeoutSeconds ${central_await}s" >&2
  echo "     The wait would be cut short and the failure would not name the Secret that never arrived." >&2
  exit 1
}
if grep -E 'variable: (tenant|hostIngressAddress|controlPlaneFqdn|clusterDomain|clusterUID|clusterClientSecret|customCAEnabled|dockerServer|dockerUsername|dockerEmail|runaiRegistryCredentials)' "$central" >/dev/null; then
  echo "FAIL $central: tenant accepts a copied host or registration value" >&2
  exit 1
fi
# The JFrog credential is reused rather than re-entered. The Platform forbids reading a Secret through
# fromResource, so it arrives decoded and `runai-step-01-registry-secret` encodes it again; that App
# must never interpolate it into rendered YAML unencoded, because it is JSON full of double quotes.
require "$central" 'dockerConfigJson: "\{\{ \.Outputs\.discover\.dockerconfigjson \}\}"'
require "$central" 'fromSecret: \{ namespace: runai, name: runai-reg-creds-host, key: \.dockerconfigjson \}'
require "$reg_app" 'b64enc \| default \$inline'
if grep -nE 'kind: Secret' "$central" "$central_host" "$central_reg" "$dedicated" | grep -q .; then
  echo "FAIL a StackTemplate declares an output over kind: Secret through fromResource" >&2
  echo "     The Platform forbids it: use fromSecret, which keeps the value sensitive and decodes it." >&2
  exit 1
fi
if grep -E 'variable: (adminPassword|runaiRegistryCredentials).*defaultValue' "$dedicated" "$central" "$central_host" "$central_reg" >/dev/null || \
  rg -U -P 'variable: (adminPassword|runaiRegistryCredentials)(?s:(?:(?!^    - variable:).)*?)defaultValue' "$root/dedicated-control-plane/apps" "$root/central-control-plane/apps" >/dev/null; then
  echo "FAIL credential input has a default" >&2
  exit 1
fi
if grep -q 'skipTLSVerify' "$dedicated"; then
  echo "FAIL dedicated StackTemplate exposes insecure REST TLS" >&2
  exit 1
fi
require "$dedicated" "insecure: '{{ eq .Values.tlsMode \"self-signed\" }}'"
# Central's REST calls use host-published TLS behavior. Task outputs cannot drive conditions, but
# they can pass a precomputed boolean to the App parameter.
require "$central_reg" 'jsonPath: "\{\.data\.tlsInsecure\}"'
n=$(grep -cF 'insecure: "{{ .Outputs.discover.tlsinsecure }}"' "$central_reg" || true)
[[ "$n" == 3 ]] || {
  echo "FAIL $central_reg: expected all 3 REST tasks to use discovered TLS behavior, found $n" >&2
  exit 1
}
if grep -q 'variable: tlsMode' "$central_reg"; then
  echo "FAIL $central_reg: TLS mode must come from host endpoint data" >&2
  exit 1
fi
if grep -q 'restful-operation' "$central"; then
  echo "FAIL central tenant StackTemplate calls the control-plane API" >&2
  exit 1
fi
if grep -q 'insecure' "$central"; then
  echo "FAIL central tenant StackTemplate exposes insecure REST TLS" >&2
  exit 1
fi
if grep -q 'skipTLSVerify' "$central_host" || grep -q 'skipTLSVerify' "$central_reg"; then
  echo "FAIL central StackTemplate exposes insecure REST TLS" >&2
  exit 1
fi
if grep 'body:' "$dedicated" | grep -Fq '\"aws\"'; then
  echo "FAIL cluster registration body has invalid escaped Go-template quotes" >&2
  exit 1
fi

dedicated_vcluster="$root/dedicated-control-plane/example/vcluster-template-with-runai-stack.yaml"
central_vcluster="$root/central-control-plane/example/vcluster-template-with-runai-stack.yaml"
require "$dedicated_vcluster" '^  name: runai-tenant$'
require "$central_vcluster" '^  name: runai-tenant-central-control-plane$'
# Only ingressProvider controls registration template conditions. TLS behavior comes from host data.
for variable in ingressProvider tenantClusterDomain; do
  require "$central_vcluster" "variable: $variable"
done
require "$central_vcluster" 'ingressProvider: "\{\{ \.Values\.ingressProvider \}\}"'
require "$central_vcluster" 'tenantClusterDomain: "\{\{ \.Values\.tenantClusterDomain \}\}"'
if grep -q 'variable: tlsMode\|tlsMode: "{{ .Values.tlsMode }}"' "$central_vcluster"; then
  echo "FAIL $central_vcluster: TLS mode must not be copied into registration" >&2
  exit 1
fi
require "$central_vcluster" 'shared host infrastructure'
# `engine-operator` watches nvidia.com ClusterPolicy and crash-loops without the CRD. GPU Operator
# installs that CRD, and under this model GPU Operator runs only on the Control Plane Cluster, so the
# tenant gets the definition and the host's policy through read-only sync instead.
if ! rg -U -q -- 'customResources:\n              clusterpolicies\.nvidia\.com/v1:\n                enabled: true\n                scope: Cluster' "$central_vcluster"; then
  echo "FAIL $central_vcluster: tenants need clusterpolicies.nvidia.com synced from the host" >&2
  exit 1
fi
# Dedicated control-plane tenancy installs its own control plane, so whoever creates the cluster supplies the registry
# credential. Central tenants reuse the one the Control Plane Cluster already holds, synced in, so those
# parameters must be absent rather than merely defaulted.
require "$dedicated_vcluster" 'defaultValue: https://runai.jfrog.io'
require "$dedicated_vcluster" 'defaultValue: self-hosted-image-puller-prod'
require "$dedicated_vcluster" 'defaultValue: support@run.ai'
# Pull-secret plumbing is shared: both templates hand tenant workloads and hook Jobs one credential
# for Platform image through workload ServiceAccount.
for template in "$dedicated_vcluster" "$central_vcluster"; do
  require "$template" 'variable: tenantImagePullSecret'
  require "$template" 'defaultValue: ""'
  require "$template" '\{\{ if \.Values\.tenantImagePullSecret \}\}'
  require "$template" 'name: \{\{ \.Values\.tenantImagePullSecret \}\}'
  if ! rg -U -q 'controlPlane:\n          advanced:\n            workloadServiceAccount:\n              imagePullSecrets:' "$template"; then
    echo "FAIL $template: missing workload ServiceAccount pull-secret value" >&2
    exit 1
  fi
done

# The custom-link Job is an App, not `spaceTemplate.objects`. Only the App path is rendered through
# the Platform's synthetic chart, and that chart is what supplies `.Values.__image__`, the image of
# the running Platform. `objects` is applied as already-rendered YAML, so a Job living there has to
# name an image literally and every install pulls whatever registry the manifest was written against.
dedicated_link="$root/dedicated-control-plane/apps/custom-link.yaml"
central_link="$root/central-control-plane/apps/custom-link.yaml"
for template in "$dedicated_vcluster" "$central_vcluster"; do
  require "$template" 'variable: createCustomLinkCronJob'
  require "$template" 'label: Create NVIDIA Run:ai custom-link Job'
  require "$template" 'type: boolean'
  require "$template" 'defaultValue: "true"'
  # The toggle reaches the App as a parameter. It cannot gate the `apps` entry itself: a
  # VirtualClusterTemplate render fills each string leaf independently, so a `{{- if }}` there
  # cannot omit a list item. The App always installs and renders nothing when the toggle is off.
  require "$template" 'createCustomLinkJob: \{\{ \.Values\.createCustomLinkCronJob \}\}'
  if rg -q 'kind: Job' "$template"; then
    echo "FAIL $template: custom-link Job belongs in an App, where it receives .Values.__image__" >&2
    exit 1
  fi
done
require "$dedicated_vcluster" 'name: runai-custom-link$'
# render.sh renames the central copy because the two Apps differ; the reference has to follow.
require "$central_vcluster" 'name: runai-custom-link-central-control-plane$'

# Each VCI gets one bounded-retry custom-link Job. It patches only its own VCI, then TTL garbage
# collection removes the Job and its Job-owned namespaced RBAC. No shared CronJob may retain broad access.
for template in "$dedicated_link" "$central_link"; do
  require "$template" '\{\{- if \.Values\.createCustomLinkJob \}\}'
  require "$template" 'variable: createCustomLinkJob'
  require "$template" 'kind: Job'
  require "$template" 'backoffLimit: 100'
  require "$template" 'ttlSecondsAfterFinished: 300'
  require "$template" 'kind: Role'
  require "$template" 'kind: RoleBinding'
  require "$template" 'resourceNames: \["\{\{ \$vciName \}\}"\]'
  require "$template" 'ownerReferences: \[\{apiVersion: "batch/v1", kind: "Job"'
  require "$template" 'fieldPath: metadata\.namespace'
  require "$template" '\{\{- if \.Values\.tenantImagePullSecret \}\}'
  require "$template" 'variable: tenantImagePullSecret'
  # The whole point of the App: the image is the running Platform's own, so it follows registry
  # rewrites, mirrors and upgrades instead of pinning every install to one published tag.
  require "$template" 'image: \{\{ \.Values\.__image__ \| quote \}\}'
  if rg -q 'image: "' "$template"; then
    echo "FAIL $template: custom-link Job names an image literally instead of .Values.__image__" >&2
    exit 1
  fi
  # A helm release will not adopt objects it did not create. The old `runai-dlink-`/`runai-clink-`
  # names were applied by the objects path with no ownership metadata, so reusing either prefix
  # fails the first install on every existing tenant with "invalid ownership metadata".
  require "$template" 'printf "runai-link-%s"'
  if rg -q 'runai-(dlink|clink)-' "$template"; then
    echo "FAIL $template: reuses a helper name the objects path already created" >&2
    exit 1
  fi
  # No `wait` and no `timeout`: GetHelmArgs turns those into `--wait`, and this Job deliberately
  # retries for as long as the control plane and Ingress take to arrive.
  if rg -q '^  (wait|timeout):' "$template"; then
    echo "FAIL $template: --wait blocks the release on a Job that retries for minutes" >&2
    exit 1
  fi
  if rg -q 'kind: (CronJob|ClusterRole|ClusterRoleBinding)|--all-namespaces|INSTANCE_SELECTOR' "$template"; then
    echo "FAIL $template: per-VCI Job retains shared CronJob or cluster-wide RBAC" >&2
    exit 1
  fi
  # `kubectl patch <resource> <name>` resolves the object with a GET before it sends the PATCH, so a
  # patch-only rule fails the Job's own cleanup-ownership step and burns all 100 retries without ever
  # reaching the Ingress. Nothing here patches an object it cannot also get.
  if rg -q 'verbs: \["patch"\]' "$template"; then
    echo "FAIL $template: RBAC rule grants patch without get; kubectl patch GETs the object first" >&2
    exit 1
  fi
  # A failed Job pod is retried. Cross-namespace RBAC must survive until a pod sets the link,
  # otherwise its next retry loses access to the VCI and its cleanup Role.
  require "$template" 'link_complete=true'
  require "$template" '\[ "\$\{link_complete:-\}" = true \] \|\| return 0'
  # The control-plane FQDN is a real domain whenever `domain` is set, and the load balancer address
  # under the aws ingress provider. Selecting the Ingress host by a nip.io suffix strands every one
  # of those installations on "Ingress not ready" until the Job gives up.
  if rg -q 'endswith\(".nip.io"\)' "$template"; then
    echo "FAIL $template: custom-link Job accepts only nip.io Ingress hosts" >&2
    exit 1
  fi
  # The selected host goes into a URL annotation, and the dropped nip.io suffix check is what used to
  # constrain its characters, so the explicit guard is now the only one.
  require "$template" 'refusing malformed host'
  # Custom links are newline-separated. A pre-existing unrelated link must not suppress RunAI_UI.
  require "$template" 'has_runai_link=false'
  require "$template" 'while IFS= read -r link \|\| \[ -n "\$link" \]'
  require "$template" 'RunAI_UI=\*\) has_runai_link=true'
  require "$template" 'link_value="\$\(printf '\''%s\\n%s'\'' "\$current" "\$link"\)"'
  # Platform keeps the VCI in its project namespace, never in the tenant's space namespace, so the
  # Job reads and patches it there. Reading it from the pod's own namespace finds nothing and the
  # Job reports "VirtualClusterInstance not ready" until it gives up.
  require "$template" '\- name: PROJECT_NAMESPACE'
  require "$template" 'value: \{\{ \$projectNamespace \}\}'
  # Platform resolves the exact project namespace from its Project object, so the user never supplies
  # or needs to know the installation-wide namespace prefix.
  require "$template" '\$loft := \.Values\.loft \| default dict'
  require "$template" 'projectNamespace := required "runai-custom-link.* requires loft\.projectNamespace" \$loft\.projectNamespace'
  if rg -q 'projectNamespacePrefix' "$template"; then
    echo "FAIL $template: custom-link exposes a project namespace prefix" >&2
    exit 1
  fi
  if rg -q 'VCI_NAMESPACE' "$template"; then
    echo "FAIL $template: VCI_NAMESPACE conflates the space namespace with the project namespace" >&2
    exit 1
  fi
  if ! rg -U -q 'get virtualclusterinstances\.management\.loft\.sh' "$template"; then
    echo "FAIL $template: Job never reads its VirtualClusterInstance" >&2
    exit 1
  fi
  if rg -q -- '-n "\$SPACE_NAMESPACE" (get|patch) virtualclusterinstances' "$template"; then
    echo "FAIL $template: Job looks for its VCI in the space namespace" >&2
    exit 1
  fi
  # An ownerReference binds only within one namespace, so the project-namespace RBAC cannot be
  # Job-owned. Its RoleBinding hangs off its Role and the Job deletes that Role when it is done;
  # without the delete, per-tenant Roles pile up in the project namespace forever.
  require "$template" 'install_project_cleanup_tree'
  require "$template" 'cleanup_project_access'
  require "$template" 'cleanup_access\(\)'
  require "$template" 'trap cleanup_access 0'
  require "$template" "trap 'exit 1' HUP INT TERM"
  require "$template" 'delete role "\$HELPER_NAME"'
  # The prefix is an installation-wide Platform setting, so no manifest may bake a project namespace in.
  if rg -q 'namespace: (p|loft-p)-' "$template"; then
    echo "FAIL $template: project namespace is hard-coded" >&2
    exit 1
  fi
  # Helm would default a namespace-less object to the release namespace, but a ServiceAccount subject
  # is not defaulted: an empty namespace there binds to the RoleBinding's own namespace instead, which
  # looks correct for a same-namespace binding and denies every cross-namespace one. Every object and
  # every subject names its namespace, so nothing depends on that defaulting.
  require "$template" '\$spaceNamespace := required "runai-custom-link.* requires loft\.space" \$loft\.space'
  if rg -U -q 'kind: ServiceAccount\n            name: \{\{ \$helperName \}\}\n(?!            namespace: \{\{ \$spaceNamespace \}\})' -P "$template"; then
    echo "FAIL $template: ServiceAccount subject does not name the space namespace" >&2
    exit 1
  fi
done
# clusterRef.namespace is the tenant's space, which is the namespace this Job runs in, so it is
# compared against the space namespace and not the project namespace the VCI itself lives in.
require "$dedicated_link" 'vc_namespace" != "\$SPACE_NAMESPACE"'
# Dedicated Job reads only its own vCluster credential, never every Secret in shared tenant space.
require "$dedicated_link" 'resourceNames: \["vc-\{\{ \$vciName \}\}"\]'
# An HTTP listener that returns 5xx is not a ready admission webhook. Authentication/authorization
# responses prove it accepted TLS, while server errors must keep the installer waiting.
admission_ready="$root/dedicated-control-plane/apps/03-ingress-admission-ready.yaml"
require "$admission_ready" 'case "\$code" in'
require "$admission_ready" '2\*\|3\*\|4\*\) exit 0'
if rg -q '\[ "\$code" != 000 \]' "$admission_ready"; then
  echo "FAIL $admission_ready: treats every HTTP response as a ready admission webhook" >&2
  exit 1
fi
# Central tenants need policy enforcement and must not forward unresolved DNS to host cluster.
if ! rg -U -q 'policies:\n          networkPolicy:\n            enabled: true' "$central_vcluster"; then
  echo "FAIL $central_vcluster: central tenant network policy is disabled" >&2
  exit 1
fi
if rg -q 'fallbackHostCluster' "$central_vcluster"; then
  echo "FAIL $central_vcluster: central tenant forwards unresolved DNS to host cluster" >&2
  exit 1
fi
# The NVIDIA Run:ai hook reaches the public control-plane FQDN. Load-balancer DNAT can make that egress
# appear as ingress-controller Pod traffic to the CNI, so allow only controller HTTPS.
require "$central_vcluster" 'variable: ingressControllerNamespace'
require "$central_vcluster" 'defaultValue: ingress-nginx'
if ! rg -U -q 'workload:\n              egress:\n                - to:\n                    - namespaceSelector:\n                        matchLabels:\n                          kubernetes.io/metadata.name: \{\{ \.Values\.ingressControllerNamespace \}\}\n                      podSelector:\n                        matchLabels:\n                          app.kubernetes.io/component: controller\n                  ports:\n                    - protocol: TCP\n                      port: 443' "$central_vcluster"; then
  echo "FAIL $central_vcluster: central tenant workloads cannot reach ingress controller HTTPS" >&2
  exit 1
fi
# Tenant templates must not expose or forward Platform's private project namespace prefix.
for template in \
  "$root/source/dedicated-control-plane/example/vcluster-template-with-runai-stack.yaml" \
  "$root/source/central-control-plane/example/vcluster-template-with-runai-stack.yaml"; do
  if rg -q 'projectNamespacePrefix' "$template"; then
    echo "FAIL $template: tenant template exposes a project namespace prefix" >&2
    exit 1
  fi
done
# Dedicated tenancy knows its own control-plane FQDN, so it pins the Ingress host to the `domain`
# input when one is set instead of trusting whatever host the tenant's Ingress happens to carry.
require "$dedicated_link" '\- name: EXPECTED_HOST'
require "$dedicated_link" 'value: "\{\{ \.Values\.domain \}\}"'
require "$dedicated_link" '\-\-arg expected "\$EXPECTED_HOST"'
require "$dedicated_vcluster" 'domain: "\{\{ \.Values\.domain \}\}"'
require "$central_link" 'namespace: runai-backend'
require "$central_link" 'ownerReferences: \[\{apiVersion: "rbac\.authorization\.k8s\.io/v1", kind: "Role"'
require "$central_link" 'cleanup_ingress_access'
require "$central_vcluster" 'controlPlaneClusterName: "\{\{ \.Values\.controlPlaneClusterName \}\}"'
for path in \
  "$root/dedicated-control-plane/example/cronjob-runai-custom-link.yaml" \
  "$root/central-control-plane/example/cronjob-runai-custom-link.yaml"; do
  [[ ! -e "$path" ]] || {
    echo "FAIL obsolete shared custom-link CronJob present: $path" >&2
    exit 1
  }
done

if rg -q 'defaultValue: engnode' "$dedicated_vcluster" "$central_vcluster"; then
  echo "FAIL workload pull-secret input has fixed engnode default" >&2
  exit 1
fi

# Dedicated creates the control plane it registers against, so it still prompts for admin credentials.
require "$dedicated_vcluster" 'defaultValue: admin@run.ai'
# Central's tenants consume a control plane that already exists and must never see its credentials.
if grep -E 'variable: (adminUsername|adminPassword)' "$central_vcluster" >/dev/null; then
  echo "FAIL central tenant vCluster template takes control-plane admin credentials" >&2
  exit 1
fi
# The tenant must see host GPU nodes, and must be pinned to its own subset of them.
require "$central_vcluster" 'variable: nodeSelectorValue'
require "$central_vcluster" 'loft\.sh/stacks-sync'
if ! rg -U -q 'nodes:\n              enabled: true' "$central_vcluster"; then
  echo "FAIL $central_vcluster: tenant does not sync host nodes; GPU capacity would be invisible" >&2
  exit 1
fi
# NVIDIA Run:ai GPU workloads select runtimeClassName nvidia. With the GPU Operator on the host, nothing in
# the tenant creates that object, so it has to be synced in.
if ! rg -U -q 'runtimeClasses:\n              enabled: true' "$central_vcluster"; then
  echo "FAIL $central_vcluster: nvidia RuntimeClass is not synced from the host" >&2
  exit 1
fi
# Syncing the control plane's CA is the only thing that makes a tenant trust it. Nobody hands the CA
# over by value any more, so losing this mapping silently breaks every new tenant's agent.
if ! rg -U -q 'secrets:\n              enabled: true' "$central_vcluster"; then
  echo "FAIL $central_vcluster: control-plane CA Secret is not synced from the host" >&2
  exit 1
fi
require "$central_vcluster" '"runai/runai-ca-cert": "runai/runai-ca-cert"'
# Keyed on the cluster's own name, and the template registers the cluster under that same name just
# below, so nobody has to know the two must match. tenantSlug points at an existing registration.
require "$central_vcluster" 'runai-backend/runai-tenant-facts-\{\{ if \.Values\.tenantSlug \}\}\{\{ \.Values\.tenantSlug \}\}\{\{ else \}\}\{\{ \.Values\.loft\.virtualClusterName \}\}\{\{ end \}\}": "runai/runai-tenant-facts"'
# Creating the cluster registers it. Without this, whoever creates a tenant has to know that its name
# must equal a slug an administrator typed into a different Stack, minutes or days earlier, and a
# mismatch shows up only as a Job log inside the tenant.
if ! rg -U -q 'spaceTemplate:\n      objects: \|-' "$central_vcluster"; then
  echo "FAIL $central_vcluster: no spaceTemplate.objects; the tenant does not register itself" >&2
  exit 1
fi
if ! rg -U -q 'kind: StackInstance(?s:.)*?templateRef:\n            name: run-ai-central-control-plane-registration\n' -P "$central_vcluster"; then
  echo "FAIL $central_vcluster: spaceTemplate does not create a run-ai-central-control-plane-registration StackInstance" >&2
  exit 1
fi
require "$central_vcluster" 'tenantSlug: \{\{ \.Values\.loft\.virtualClusterName \}\}'
# The guard is the one that matters most. tenantSlug means "a registration for this tenant already
# exists"; without it, setting tenantSlug adds a SECOND registration under the cluster's own name,
# and two Stacks adopting one NVIDIA Run:ai cluster is the exact collision slug uniqueness exists to stop.
if ! rg -U -q 'objects: \|-\n        \{\{- if not \.Values\.tenantSlug \}\}' "$central_vcluster"; then
  echo "FAIL $central_vcluster: the owned registration is not guarded by '{{- if not .Values.tenantSlug }}'" >&2
  echo "     Setting tenantSlug would then double-register the tenant." >&2
  exit 1
fi
# The guard's `{{- end }}` is the last line of the `objects` block: the next line is dedented back
# to a `spaceTemplate` key. Anything left below it would be registered unconditionally.
if ! rg -U -q '\{\{- end \}\}\n      [^ ]' "$central_vcluster"; then
  echo "FAIL $central_vcluster: the tenantSlug guard is not closed around the whole StackInstance" >&2
  exit 1
fi
# Registration hook Jobs use tenant image-pull Secret before discovery can find anything. Pass
# tenantImagePullSecret through as hookImagePullSecret.
require "$central_vcluster" 'variable: tenantImagePullSecret'
require "$central_vcluster" 'hookImagePullSecret: "\{\{ \.Values\.tenantImagePullSecret \}\}"'
require "$central_vcluster" 'variable: controlPlaneClusterName'
require "$central_vcluster" 'name: \{\{ \.Values\.controlPlaneClusterName \}\}'
require "$central_vcluster" '"runai/runai-reg-creds": "runai/runai-reg-creds-host"'
# ...and no registration fact may return as a pasted value.
if grep -q 'controlPlaneCaCertB64' "$central_vcluster" "$central" || \
  grep -E 'variable: (hostIngressAddress|controlPlaneFqdn|clusterUID|clusterClientSecret|runaiRegistryCredentials|dockerServer|dockerUsername|dockerEmail)' "$central_vcluster" >/dev/null; then
  echo "FAIL tenant receives a copied host or registration value; sync facts instead" >&2
  exit 1
fi
# nodeSelectorValue must have no default: two tenants sharing nodes both claim full GPU capacity.
if rg -U -q 'variable: nodeSelectorValue(?s:(?:(?!- variable:).)*?)defaultValue' -P "$central_vcluster"; then
  echo "FAIL central tenant nodeSelectorValue has a default" >&2
  exit 1
fi

python3 - "$root" <<'YAMLPARSE' || exit 1
import sys
from pathlib import Path

import yaml

root = Path(sys.argv[1])
failed = False
for path in sorted(root.rglob("*.yaml")):
    try:
        list(yaml.safe_load_all(path.read_text()))
    except yaml.YAMLError as err:
        failed = True
        mark = getattr(err, "problem_mark", None)
        where = f":{mark.line + 1}" if mark else ""
        problem = getattr(err, "problem", None) or str(err).splitlines()[0]
        print(f"FAIL {path}{where}: not valid YAML: {problem}", file=sys.stderr)
        print("     a Go template inside a double-quoted scalar must escape its own quotes as \\\"", file=sys.stderr)
sys.exit(1 if failed else 0)
YAMLPARSE

# The NVIDIA Run:ai version is spelled out in seven places and `chart.version` cannot be templated: the
# Platform renders Go templates in `values` and `manifests`, not in the chart coordinates. So
# `runaiVersion` cannot drive the chart, and its only real job is the `cluster-install-info?version=`
# query. Keeping the two equal was a comment; make it a failure. A bump has to move every one of
# these together, and half-landing it means the control plane installs one version while the
# registration asks the API about another.
python3 - "$root" <<'VERSIONS' || exit 1
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
found = {}

# The two NVIDIA Run:ai charts. Other Apps pin unrelated charts (GPU Operator, kube-prometheus-stack,
# ingress-nginx) whose versions are their own and must not be dragged in here.
for variant in ("dedicated-control-plane", "central-control-plane"):
    for app in ("07-control-plane.yaml", "08-cluster.yaml"):
        path = root / variant / "apps" / app
        text = path.read_text()
        m = re.search(r'^      version: "([^"]+)"$', text, re.M)
        if not m:
            print(f"FAIL {path}: no quoted chart version found", file=sys.stderr)
            raise SystemExit(1)
        found.setdefault(m.group(1), []).append(f"{path}:chart.version")

    for template in sorted((root / variant).glob("stacktemplate*.yaml")):
        for m in re.finditer(r'variable: runaiVersion.*?defaultValue: "([^"]+)"', template.read_text()):
            found.setdefault(m.group(1), []).append(f"{template}:runaiVersion default")

    for example in sorted((root / variant / "example").glob("*.yaml")):
        for m in re.finditer(r'^\s*runaiVersion: "([^"]+)"$', example.read_text(), re.M):
            found.setdefault(m.group(1), []).append(f"{example}:runaiVersion")

if len(found) != 1:
    print("FAIL NVIDIA Run:ai version disagrees across the files that must move together:", file=sys.stderr)
    for version, places in sorted(found.items()):
        print(f"  {version}", file=sys.stderr)
        for place in places:
            print(f"    {place}", file=sys.stderr)
    raise SystemExit(1)

version, places = next(iter(found.items()))
if len(places) < 7:
    print(f"FAIL only {len(places)} NVIDIA Run:ai version site(s) found; expected at least 7", file=sys.stderr)
    for place in places:
        print(f"    {place}", file=sys.stderr)
    raise SystemExit(1)
VERSIONS

# GCP and Azure publish an ingress LoadBalancer as an IPv4 address; AWS publishes an ELB/NLB
# hostname and never an address, so `<name>.<address>.nip.io` has nothing to build on. The
# dedicated Stack has always had `ingressProvider` for this; the central host Stack must offer the
# same lever, and its address pattern must admit a hostname as well as an IPv4 address.
require "$central_host" 'variable: ingressProvider'
require "$central_host" 'variable: ingressProvider'
for template in "$dedicated" "$central_host"; do
  if ! grep -qF 'else if eq .Values.ingressProvider \"aws\"' "$template"; then
    echo "FAIL $template: FQDN derivation has no aws branch, so a hostname LoadBalancer gets a nip.io name" >&2
    exit 1
  fi
done
# Registration takes ingress provider as an input because task outputs cannot drive conditions.
# Under aws it derives nothing and tenant-facts validation names the fix.
require "$central_reg" 'variable: ingressProvider'
require "$central_reg" 'variable: ingressProvider'
n=$(grep -cE 'else if eq \.Values\.ingressProvider .*aws.* \}\}\{\{ else \}\}' "$central_reg" || true)
[[ "$n" == 2 ]] || {
  echo "FAIL $central_reg: both the registration body and the facts domain must skip nip.io under aws, found $n" >&2
  exit 1
}
facts="$root/central-control-plane/apps/03-tenant-facts.yaml"
require "$facts" 'validation: \^\[a-z0-9\]\(\[-a-z0-9\.\]\*\[a-z0-9\]\)\?\$'

# Stack task outputs resolve after template conditions. They may only appear in direct substitutions.
if rg -U -q '\{\{[^}]*\b(if|else if|eq|ne|and|or|not)\b[^}]*\.Outputs[^}]*\}\}' "$root/source"; then
  echo "FAIL StackTemplate condition reads .Outputs; use .Values for condition inputs" >&2
  exit 1
fi

# Every hook Job runs arbitrary shell as the Platform image on a cluster the operator does not
# necessarily own, so each one is hardened the same way: non-root, RuntimeDefault seccomp, no
# privilege escalation, a read-only root filesystem, no capabilities, and bounded resources. The
# count is per Job rather than per file, so adding a second Job to an existing App cannot inherit
# the first one's block by accident. `restful-operation.yaml` was the file that prompted this.
for variant in dedicated-control-plane central-control-plane; do
  for app in "$root/$variant/apps"/*.yaml; do
    jobs=$(grep -c '^      kind: Job$' "$app" || true)
    [[ "$jobs" -gt 0 ]] || continue
    for field in 'runAsNonRoot: true' 'type: RuntimeDefault' 'allowPrivilegeEscalation: false' \
      'readOnlyRootFilesystem: true' 'drop: \["ALL"\]' 'requests:' 'limits:'; do
      found=$(grep -cE "^ +${field}$" "$app" || true)
      [[ "$found" -ge "$jobs" ]] || {
        echo "FAIL $app: $jobs Job(s) but only $found '${field}'; every hook Job must be hardened" >&2
        exit 1
      }
    done
  done
done

echo "Certified NVIDIA Run:ai StackTemplates present."
