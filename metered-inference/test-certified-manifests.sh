#!/usr/bin/env bash
# Static checks for the metered inference Stacks. Renders every App with Helm across the parameter
# combinations the StackTemplates can produce, resolves every StackTemplate task against the Apps it
# can select, checks the examples, and cross-checks that the tenant routes, recording rules, and
# dashboards agree. Pass --offline to skip rendering the upstream charts.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
for tool in python3 helm jq; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml)"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

python3 "$root/render.py" --check

python3 - "$root" "$@" <<'CHECKS'
import copy
import itertools
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

root = Path(sys.argv[1])
offline = "--offline" in sys.argv[2:]
errors = []


def fail(message):
    errors.append(message)


def load(path):
    return [doc for doc in yaml.safe_load_all(path.read_text()) if doc]


# --- inventory -----------------------------------------------------------------------------------

apps = {}
for path in sorted(root.glob("*/apps/*.yaml")):
    for doc in load(path):
        where = path.relative_to(root)
        if doc.get("apiVersion") != "management.loft.sh/v1" or doc.get("kind") != "App":
            fail(f"{where}: expected a management.loft.sh/v1 App")
            continue
        name = doc["metadata"]["name"]
        if not name.startswith("metered-inference-"):
            fail(f"{where}: App {name} must be prefixed metered-inference- to avoid catalog collisions")
        if name in apps:
            fail(f"{where}: duplicate App {name}")
        apps[name] = {"doc": doc, "path": where}

templates = {}
for path in sorted(root.glob("*/stacktemplate.yaml")):
    doc = load(path)[0]
    templates[doc["metadata"]["name"]] = {"doc": doc, "path": path.relative_to(root)}
for name in templates:
    if not name.startswith("metered-inference-"):
        fail(f"StackTemplate {name} must be prefixed metered-inference-")


def params_of(spec):
    return {p["variable"]: p for p in spec.get("parameters") or []}


def validate_value(where, parameter, value):
    value = "" if value is None else str(value)
    if parameter.get("options") and value not in [str(o) for o in parameter["options"]] and value != "":
        fail(f"{where}: {parameter['variable']}={value!r} is not one of {parameter['options']}")
    pattern = parameter.get("validation")
    if pattern and not re.fullmatch(pattern, value):
        fail(f"{where}: {parameter['variable']}={value!r} does not match {pattern!r}")
    if parameter.get("type") == "boolean" and value.lower() not in ("true", "false", ""):
        fail(f"{where}: {parameter['variable']}={value!r} is not a boolean")


def typed_defaults(spec):
    values = {}
    for variable, parameter in params_of(spec).items():
        default = parameter.get("defaultValue", "")
        if parameter.get("type") == "boolean":
            values[variable] = str(default).lower() == "true"
        else:
            values[variable] = default
    return values


for kind, collection in (("App", apps), ("StackTemplate", templates)):
    for name, item in collection.items():
        for variable, parameter in params_of(item["doc"]["spec"]).items():
            if "defaultValue" in parameter and parameter["defaultValue"] != "":
                validate_value(f"{item['path']} default", parameter, parameter["defaultValue"])

# vCluster Platform's admission rejects an App whose parameters break these rules.
for name, item in apps.items():
    for parameter in item["doc"]["spec"].get("parameters") or []:
        if not parameter.get("variable") or not parameter.get("label"):
            fail(f"{item['path']}: the Platform rejects App parameters without a variable and a label: {parameter}")
        if parameter.get("type", "string") not in ("string", "multiline", "boolean", "number", "password"):
            fail(f"{item['path']}: the Platform rejects App parameter type {parameter.get('type')}")


# --- Helm rendering helpers ------------------------------------------------------------------------

work = Path(tempfile.mkdtemp())
counter = itertools.count()


def helm_render(template_text, values, namespace="default"):
    """Render text as a Helm template, which is what the Platform does with App manifests and values."""
    chart = work / f"chart{next(counter)}"
    (chart / "templates").mkdir(parents=True)
    (chart / "Chart.yaml").write_text("apiVersion: v2\nname: render\nversion: 0.0.1\n")
    (chart / "values.yaml").write_text(yaml.safe_dump(values))
    (chart / "templates" / "template.yaml").write_text(template_text)
    result = subprocess.run(["helm", "template", "release", str(chart), "--namespace", namespace],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None, result.stderr.strip()
    lines = [line for line in result.stdout.splitlines() if not line.startswith("# Source:")]
    # Keep the final line break: it ends a block scalar at the end of the last document.
    return "\n".join(lines) + "\n", None


def render_strings(obj, values):
    """Render every templated string in obj, as the Stack controller does before creating tasks."""
    strings = []

    def collect(node):
        if isinstance(node, dict):
            return {k: collect(v) for k, v in node.items()}
        if isinstance(node, list):
            return [collect(v) for v in node]
        if isinstance(node, str) and "{{" in node:
            strings.append(node)
            return ("__rendered__", len(strings) - 1)
        return node

    skeleton = collect(obj)
    if not strings:
        return obj, None
    # Helm only emits valid YAML, so each string goes through tpl and comes back as JSON.
    template = ('apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: rendered\ndata:\n'
                '{{- range $i, $s := .Values.__strings }}\n  s{{ $i }}: {{ tpl $s $ | toJson }}\n{{- end }}\n')
    out, err = helm_render(template, {**values, "__strings": strings})
    if err:
        return None, err
    data = yaml.safe_load(out)["data"]
    rendered = {int(k[1:]): v for k, v in data.items()}

    def fill(node):
        if isinstance(node, dict):
            return {k: fill(v) for k, v in node.items()}
        if isinstance(node, list):
            return [fill(v) for v in node]
        if isinstance(node, tuple) and node and node[0] == "__rendered__":
            return rendered[node[1]]
        return node

    return fill(skeleton), None


def docs_of(text, where):
    try:
        docs = [d for d in yaml.safe_load_all(text) if d]
    except yaml.YAMLError as err:
        fail(f"{where}: rendered output is not valid YAML: {err}")
        return []
    for doc in docs:
        if not all(k in doc for k in ("apiVersion", "kind", "metadata")) or not doc["metadata"].get("name"):
            fail(f"{where}: rendered object without apiVersion, kind, or metadata.name: {str(doc)[:120]}")
    return docs


IMAGE = "ghcr.io/loft-sh/loft:0.0.0-test"
LOFT = {"virtualClusterName": "yellow", "project": "all-hands", "projectNamespace": "p-all-hands",
        "space": "loft-all-hands-v-yellow", "cluster": "loft-cluster"}


def render_app(name, parameters, where, expect_failure=False):
    """Render an App with the parameter values a Stack task or template would pass."""
    app = apps[name]["doc"]["spec"]
    # The Platform hands an AppInstance exactly the parameters it was given: App defaults,
    # required, and validation do not apply, so neither do they here.
    values = dict(parameters)
    values["__image__"] = IMAGE
    values["loft"] = LOFT
    namespace = app.get("defaultNamespace") or LOFT["space"]
    config = app["config"]
    if "manifests" in config:
        text, err = helm_render(config["manifests"], values, namespace)
        if expect_failure:
            if not err:
                fail(f"{where}: expected {name} to refuse these parameters")
            return []
        if err:
            fail(f"{where}: {name} does not render: {err}")
            return []
        return docs_of(text, where)
    values_text = config.get("values", "")
    rendered, err = helm_render(values_text, values, namespace) if "{{" in values_text else (values_text, None)
    if err:
        fail(f"{where}: {name} values do not render: {err}")
        return None
    try:
        return yaml.safe_load(rendered) or {}
    except yaml.YAMLError as err:
        fail(f"{where}: {name} rendered values are not valid YAML: {err}")
        return None


pulled = {}
rendered_charts = {}


def render_chart(name, chart_values, where):
    """Render the upstream chart with the App's rendered values. Each chart is pulled once."""
    chart = apps[name]["doc"]["spec"]["config"]["chart"]
    namespace = apps[name]["doc"]["spec"].get("defaultNamespace", "default")
    source = (chart["repoURL"], chart["name"], str(chart["version"]))
    return template_chart(source, chart_values, namespace, where)


def template_chart(source, chart_values, namespace, where):
    """Render a chart, given as (repo, name, version), with values. Each chart is pulled once."""
    if offline:
        return []
    key = (source, json.dumps(chart_values or {}, sort_keys=True))
    if key in rendered_charts:
        return rendered_charts[key]
    if source not in pulled:
        destination = work / f"pull{next(counter)}"
        destination.mkdir()
        command = ["helm", "pull", "--destination", str(destination), "--version", source[2]]
        command += [f"{source[0]}/{source[1]}"] if source[0].startswith("oci://") else [source[1], "--repo", source[0]]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{where}: cannot pull chart {source[1]} {source[2]} from {source[0]}: {result.stderr.strip()[:300]}")
            pulled[source] = None
        else:
            pulled[source] = next(destination.glob("*.tgz"))
    if pulled[source] is None:
        return []
    values_file = work / f"values{next(counter)}.yaml"
    values_file.write_text(yaml.safe_dump(chart_values or {}))
    result = subprocess.run(["helm", "template", "release", str(pulled[source]), "--namespace", namespace,
                             "--values", str(values_file), "--kube-version", "1.34.0"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"{where}: chart {source[1]} {source[2]} does not render: {result.stderr.strip()[:500]}")
        docs = []
    else:
        docs = docs_of(result.stdout, where)
    rendered_charts[key] = docs
    return docs


def find(docs, kind, name=None):
    return [d for d in docs if d.get("kind") == kind and (name is None or d["metadata"]["name"] == name)]


def assert_chart(ref, docs, passed, where):
    """The names and settings other components depend on, in the rendered upstream charts."""
    if not docs:
        return
    if ref == "metered-inference-prometheus":
        service = find(docs, "Service", "metered-inference-prometheus")
        if not service or service[0]["spec"]["ports"][0]["port"] != 80:
            fail(f"{where}: Grafana and the connector expect Service metered-inference-prometheus on port 80")
        args = find(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"][-1]["args"]
        if "--web.enable-otlp-receiver" not in args:
            fail(f"{where}: Prometheus must accept OTLP to back the Platform connector")
        config = yaml.safe_load(find(docs, "ConfigMap", "metered-inference-prometheus")[0]["data"]["prometheus.yml"])
        if "agentgateway-proxy" not in [job["job_name"] for job in config["scrape_configs"]]:
            fail(f"{where}: Prometheus does not scrape the agentgateway proxies")
    if ref == "metered-inference-grafana":
        platform = str(passed.get("platformIntegration")).lower() == "true"
        want = passed.get("platformNamespace") if platform else "inference-observability"
        namespaces = {d["metadata"].get("namespace") for d in docs if d["kind"] not in ("ClusterRole", "ClusterRoleBinding")}
        if namespaces != {want}:
            fail(f"{where}: Grafana should run in {want}, renders into {namespaces}")
        if not find(docs, "Service", "metered-inference-grafana"):
            fail(f"{where}: the connector expects Service metered-inference-grafana")
        env = [e["name"] for c in find(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"] for e in c.get("env", [])]
        if platform != ("GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET" in env):
            fail(f"{where}: Platform SSO should be configured exactly when platformIntegration is on")
        # Go's soft memory limit must sit below the container's, or Grafana is killed before it
        # collects garbage.
        grafana = [c for c in find(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"] if c["name"] == "grafana"][0]
        units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "KiB": 2**10, "MiB": 2**20, "GiB": 2**30}

        def to_bytes(quantity):
            match = re.fullmatch(r"(\d+)([A-Za-z]*)", str(quantity or ""))
            return int(match.group(1)) * units.get(match.group(2), 1) if match else 0

        limit = to_bytes(grafana.get("resources", {}).get("limits", {}).get("memory"))
        soft = to_bytes({e["name"]: e.get("value") for e in grafana.get("env", [])}.get("GOMEMLIMIT"))
        if not (0 < soft < limit) or limit < 768 * 2**20:
            fail(f"{where}: Grafana needs a memory limit of at least 768Mi with GOMEMLIMIT below it, not {limit} and {soft}")
    if ref == "metered-inference-external-dns":
        args = find(docs, "Deployment")[0]["spec"]["template"]["spec"]["containers"][0]["args"]
        for arg in ("--source=service", "--label-filter=inference.vcluster.com/external-dns=true"):
            if arg not in args:
                fail(f"{where}: external-dns is missing {arg}")
        filters = [a for a in args if a.startswith("--domain-filter=")]
        if passed.get("provider") == "route53":
            # Filtered to the domain so a zone-scoped IAM policy works, with parent zones allowed.
            if filters != [f"--domain-filter={passed.get('domain')}"] or "--aws-zone-match-parent" not in args:
                fail(f"{where}: Route 53 external-dns should filter to the domain and match parent zones: {args}")
        elif filters:
            fail(f"{where}: Gandi external-dns should run unfiltered and rely on the token's scope: {filters}")
    if ref == "metered-inference-kubeai":
        ports = {d["metadata"]["name"]: d["spec"]["ports"][0].get("nodePort") for d in find(docs, "Service")}
        if str(ports.get("kubeai")) != str(passed.get("apiNodePort")):
            fail(f"{where}: KubeAI's node port {ports.get('kubeai')} is not apiNodePort {passed.get('apiNodePort')}")
        if str(passed.get("chatUI")).lower() == "true" and str(ports.get("open-webui")) != str(passed.get("chatNodePort")):
            fail(f"{where}: Open WebUI's node port {ports.get('open-webui')} is not chatNodePort {passed.get('chatNodePort')}")


# The chart vCluster Platform 4.10 to 4.13 installs the KubeVirt and CDI operators with, when a
# NodeProvider sets deploy.kubevirt.enabled. The Platform also renders its own chart for the KubeVirt
# and CDI resources, from the same values, under kubevirt.spec and cdi.spec.
KUBEVIRT_OPERATOR_CHART = ("oci://ghcr.io/loft-sh/charts", "kubevirt", "0.1.0")
node_providers = []


def check_node_provider(docs, values, where):
    """The NodeProvider passes the Platform's admission rules, and KubeVirt gets the promised values."""
    providers = find(docs, "NodeProvider")
    if len(providers) != 1:
        fail(f"{where}: expected one NodeProvider, got {len(providers)}")
        return
    provider = providers[0]
    node_providers.append(provider)
    name = provider["metadata"]["name"]
    kubevirt = provider["spec"]["kubeVirt"]
    cluster_ref = kubevirt.get("clusterRef") or {}
    if not cluster_ref.get("cluster") or not cluster_ref.get("namespace"):
        fail(f"{where}: the NodeProvider needs clusterRef.cluster and clusterRef.namespace")
    if cluster_ref.get("cluster") != LOFT["cluster"]:
        fail(f"{where}: the NodeProvider's cluster {cluster_ref.get('cluster')} is not the Stack's cluster {LOFT['cluster']}")
    node_types = kubevirt.get("nodeTypes") or []
    if not node_types:
        fail(f"{where}: the NodeProvider needs at least one node type")
    for node_type in node_types:
        if "virtualMachineTemplate" in node_type and "mergeVirtualMachineTemplate" in node_type:
            fail(f"{where}: node type {node_type['name']} sets both virtualMachineTemplate and mergeVirtualMachineTemplate")
        if "virtualMachineTemplate" not in kubevirt and (
                "virtualMachineTemplate" not in node_type or "mergeVirtualMachineTemplate" in node_type):
            fail(f"{where}: node type {node_type['name']} needs its own virtualMachineTemplate without a provider template")

    # Masquerade, so the Gateway reaches each VM at its virt-launcher pod's address on any CNI and
    # node OS. Each node type's VMs get it from its own template, its merge template, or the
    # provider's.
    def vm_spec(template):
        return (template or {}).get("spec", {}).get("template", {}).get("spec", {})

    for node_type in node_types:
        base = vm_spec(node_type.get("virtualMachineTemplate") or kubevirt.get("virtualMachineTemplate"))
        merged = vm_spec(node_type.get("mergeVirtualMachineTemplate"))
        interfaces = merged.get("domain", {}).get("devices", {}).get("interfaces",
                                                                     base.get("domain", {}).get("devices", {}).get("interfaces"))
        networks = merged.get("networks", base.get("networks"))
        if interfaces != [{"name": "default", "masquerade": {}}] or networks != [{"name": "default", "pod": {}}]:
            fail(f"{where}: node type {node_type['name']} VMs need masquerade binding on the pod network, not {interfaces} on {networks}")

    deploy = (kubevirt.get("deploy") or {}).get("kubevirt") or {}
    if bool(deploy.get("enabled")) != values["installKubeVirt"]:
        fail(f"{where}: deploy.kubevirt.enabled is {deploy.get('enabled')}, want {values['installKubeVirt']}")
    if deploy.get("enabled"):
        helm_values = yaml.safe_load(deploy.get("helmValues") or "") or {}
        spec = helm_values.get("kubevirt", {}).get("spec", {})
        required = helm_values.get("kubevirt", {}).get("operator", {}).get("affinity", {}).get("nodeAffinity", {})
        cdi_spec = helm_values.get("cdi", {}).get("spec", {})
        if spec.get("uninstallStrategy") != "BlockUninstallIfWorkloadsExist":
            fail(f"{where}: removing the NodeProvider must not uninstall KubeVirt, and every VM, while VMs exist")
        if cdi_spec.get("uninstallStrategy") != "BlockUninstallIfWorkloadsExist":
            fail(f"{where}: removing the NodeProvider must not uninstall CDI while VM disks exist")
        if "requiredDuringSchedulingIgnoredDuringExecution" not in required or required["requiredDuringSchedulingIgnoredDuringExecution"] is not None:
            fail(f"{where}: the KubeVirt operator must not require control plane nodes")
        if "nodePlacement" not in spec.get("infra", {}):
            fail(f"{where}: virt-api and virt-controller must not require control plane nodes")
        developer = spec.get("configuration", {}).get("developerConfiguration", {})
        emulation = developer.get("useEmulation", False)
        if emulation != values["kubeVirtEmulation"]:
            fail(f"{where}: useEmulation is {emulation}, want {values['kubeVirtEmulation']}")
        operator = [d for d in template_chart(KUBEVIRT_OPERATOR_CHART, helm_values, cluster_ref.get("namespace"), where)
                    if d["kind"] == "Deployment"]
        if not offline and len(operator) != 2:
            fail(f"{where}: expected the virt-operator and cdi-operator Deployments, got {len(operator)}")
        for deployment in operator:
            affinity = deployment["spec"]["template"]["spec"].get("affinity", {}).get("nodeAffinity", {})
            if "requiredDuringSchedulingIgnoredDuringExecution" in affinity:
                fail(f"{where}: {deployment['metadata']['name']} still requires {affinity['requiredDuringSchedulingIgnoredDuringExecution']}")

    # The status Job and its RBAC wait for this NodeProvider and the node types it declares.
    job = find(docs, "Job", "metered-inference-kubevirt-status")[0]
    container = job["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e.get("value") for e in container["env"]}
    if env["INSTALL_KUBEVIRT"] != str(values["installKubeVirt"]).lower():
        fail(f"{where}: the status Job's INSTALL_KUBEVIRT is {env['INSTALL_KUBEVIRT']}")
    rules = find(docs, "ClusterRole", "metered-inference-kubevirt-status")[0]["rules"]
    granted = {resource: rule.get("resourceNames") for rule in rules for resource in rule["resources"]}
    wanted = sorted(f"{name}.{t['name']}" for t in node_types)
    if granted.get("nodeproviders") != [name] or sorted(granted.get("nodetypes") or []) != wanted:
        fail(f"{where}: the status Job may read {granted.get('nodeproviders')} and {granted.get('nodetypes')}, not {name} and {wanted}")
    if granted.get("namespaces") != [cluster_ref.get("namespace")]:
        fail(f"{where}: the status Job checks namespace {granted.get('namespaces')}, not the VM namespace {cluster_ref.get('namespace')}")
    for word in [name, *wanted, f"namespace {cluster_ref.get('namespace')}"]:
        if word not in container["args"][0]:
            fail(f"{where}: the status Job does not check {word}")


OUTPUT_REF = re.compile(r"\{\{\s*\.Outputs\.([A-Za-z0-9]+)\.([A-Za-z0-9]+)\s*\}\}")


def fill_outputs(tasks, outputs, where):
    """Fill in {{ .Outputs.task.name }} as vCluster Platform does, checking its admission rules: an
    output reference is a bare substitution of an output that a task this one depends on declares."""
    declared = {(t["name"], o["name"]) for t in tasks for o in t.get("outputs") or []}

    def fill(node, task):
        if isinstance(node, dict):
            return {k: fill(v, task) for k, v in node.items()}
        if isinstance(node, list):
            return [fill(v, task) for v in node]
        if not isinstance(node, str):
            return node

        def value(match):
            producer, output = match.groups()
            if (producer, output) not in declared:
                fail(f"{where}: task {task['name']} reads {producer}.{output}, which no task declares")
            elif producer not in (task.get("dependsOn") or []):
                fail(f"{where}: task {task['name']} reads {producer}'s outputs without depending on it")
            return outputs.get(f"{producer}.{output}", "")

        filled = OUTPUT_REF.sub(value, node)
        if ".Outputs" in filled:
            fail(f"{where}: task {task['name']} has an output reference that is not a bare substitution: {node[:120]}")
        return filled

    return [fill(task, task) for task in tasks]


def check_contract_outputs(template):
    """The outputs the platform Stack reads are fields the gateway Stack's contract ConfigMap has, in a
    namespace the platform Stack installs an App into, which is the only place it may read them."""
    where = template["path"]
    docs = render_app("metered-inference-shared-gateway", {"domain": "inference.example.com"}, "contract source")
    contract = find(docs, "ConfigMap", "metered-inference-gateway")[0]
    job = find(docs, "Job", "metered-inference-gateway-status")[0]["spec"]["template"]["spec"]["containers"][0]["args"][0]
    # The status Job patches these into the ConfigMap Helm creates.
    patched = re.search(r"\{data: \{([^}]*)\}\}", job)
    if not patched:
        fail(f"{where}: cannot find the fields the gateway status Job adds to the contract")
        return
    keys = set(contract["data"]) | {field.split(":")[0].strip() for field in patched.group(1).split(",")}
    namespaces = {}
    for task in template["doc"]["spec"]["tasks"]:
        ref = task["app"]["templateRef"]["name"]
        if "{{" not in ref:
            namespaces[task["name"]] = apps[ref]["doc"]["spec"].get("defaultNamespace")
    for task in template["doc"]["spec"]["tasks"]:
        for output in task.get("outputs") or []:
            source = output.get("fromResource") or {}
            field = re.fullmatch(r"\{\.data\.([A-Za-z]+)\}", source.get("jsonPath", ""))
            if (source.get("kind"), source.get("name"), source.get("namespace")) != (
                    "ConfigMap", contract["metadata"]["name"], contract["metadata"]["namespace"]):
                fail(f"{where}: output {task['name']}.{output['name']} does not read the gateway contract ConfigMap")
            elif not field or field.group(1) not in keys:
                fail(f"{where}: output {task['name']}.{output['name']} reads {source.get('jsonPath')}, which the contract does not have ({sorted(keys)})")
            if namespaces.get(task["name"]) != source.get("namespace"):
                fail(f"{where}: task {task['name']} reads outputs from {source.get('namespace')} but installs into {namespaces.get(task['name'])}")


def check_cluster_template(docs, passed, where, provider):
    """The generated tenant cluster template: both halves agree, every name it references exists, and
    the endpoint settings are the gateway contract's, fixed rather than left to tenants."""
    vcts = find(docs, "VirtualClusterTemplate")
    if len(vcts) != 1:
        fail(f"{where}: expected one VirtualClusterTemplate, got {len(vcts)}")
        return
    spec = vcts[0]["spec"]
    settable = {"domain", "scheme", "clusterIssuer", "verifyTLS"} & set(params_of(spec))
    if settable:
        fail(f"{where}: tenants can set {sorted(settable)}, which the gateway contract fixes")
    values = typed_defaults(spec)
    values["loft"] = LOFT
    rendered, err = helm_render(spec["template"]["helmRelease"]["values"], values)
    if err:
        fail(f"{where}: helmRelease values do not render: {err}")
        return
    vcluster = yaml.safe_load(rendered)
    for stack in vcluster.get("deploy", {}).get("stacks", []):
        name = stack["templateRef"]["name"]
        declared = params_of(templates[name]["doc"]["spec"])
        for variable, value in (stack.get("parameters") or {}).items():
            if variable not in declared:
                fail(f"{where}: deploy.stacks {stack['name']} passes {variable}, which {name} does not declare")
            else:
                validate_value(f"{where} deploy.stacks", declared[variable], value)
        for variable, parameter in declared.items():
            if parameter.get("required") and not (stack.get("parameters") or {}).get(variable) and not parameter.get("defaultValue"):
                fail(f"{where}: deploy.stacks {stack['name']} does not pass required {variable}")
    stack_parameters = vcluster["deploy"]["stacks"][0]["parameters"]
    # A new node pulls in parallel, so system pods do not queue behind Open WebUI's large image.
    kubelet = vcluster.get("privateNodes", {}).get("kubelet", {}).get("config", {})
    if kubelet.get("serializeImagePulls") is not False or int(kubelet.get("maxParallelImagePulls") or 0) < 2:
        fail(f"{where}: tenant nodes must pull images in parallel: {kubelet}")

    # The gateway contract's settings, as the gateway Stack itself derives them from its TLS issuer.
    gateway = render_app("metered-inference-shared-gateway", {"tlsIssuer": passed["tlsIssuer"], "domain": passed["domain"]},
                         f"{where} gateway contract")
    contract = find(gateway, "ConfigMap", "metered-inference-gateway")[0]["data"]
    host = f"{LOFT['virtualClusterName']}.{LOFT['project']}.{passed['domain']}"
    if stack_parameters["apiURL"] != f"{contract['scheme']}://{host}/v1":
        fail(f"{where}: apiURL {stack_parameters['apiURL']} is not {contract['scheme']}://{host}/v1")
    if stack_parameters["verifyTLS"] != ("true" if passed["tlsIssuer"] == "letsencrypt" else "false"):
        fail(f"{where}: verifyTLS {stack_parameters['verifyTLS']} with tlsIssuer {passed['tlsIssuer']}")
    links, _ = render_strings(vcts[0]["spec"]["template"]["instanceTemplate"]["metadata"]["annotations"], values)
    if f"Inference API={contract['scheme']}://{host}/v1" not in (links or {}).get("loft.sh/custom-links", ""):
        fail(f"{where}: the Inference API link does not point at {contract['scheme']}://{host}/v1")

    for entry in spec["template"].get("spaceTemplate", {}).get("apps", []):
        name = entry["name"]
        if name not in apps:
            fail(f"{where}: spaceTemplate App {name} does not exist")
            continue
        text, err = helm_render(entry.get("parameters", ""), values)
        if err:
            fail(f"{where}: spaceTemplate App {name} parameters do not render: {err}")
            continue
        parameters = yaml.safe_load(text) or {}
        declared = params_of(apps[name]["doc"]["spec"])
        for variable in parameters:
            if variable not in declared:
                fail(f"{where}: spaceTemplate App {name} passes {variable}, which it does not declare")
        render_app(name, parameters, f"{where} spaceTemplate {name}")
        # Both halves must agree on the hostname, the node ports, and the key.
        if parameters["apiHostname"] != host:
            fail(f"{where}: endpoint apiHostname {parameters['apiHostname']} != {host}")
        for variable in ("apiNodePort", "chatNodePort", "apiKey"):
            if str(parameters.get(variable)) != str(stack_parameters.get(variable)):
                fail(f"{where}: {variable} differs between the endpoint App and the Stack")
        if parameters.get("clusterIssuer") != contract["clusterIssuer"]:
            fail(f"{where}: endpoint clusterIssuer {parameters.get('clusterIssuer')!r} is not the gateway's {contract['clusterIssuer']!r}")
        if parameters.get("jobImagePullSecret") != passed.get("jobImagePullSecret", ""):
            fail(f"{where}: endpoint jobImagePullSecret is not the platform Stack's")
        # The endpoint App finds VMs where the NodeProvider creates them.
        if provider and parameters.get("vmNamespace") != provider["spec"]["kubeVirt"]["clusterRef"]["namespace"]:
            fail(f"{where}: endpoint vmNamespace {parameters.get('vmNamespace')} is not the NodeProvider's namespace")

    # Every VM size the template offers is a node type of the NodeProvider.
    if not provider:
        return
    offered = {f"{provider['metadata']['name']}.{t['name']}" for t in provider["spec"]["kubeVirt"]["nodeTypes"]}
    for option in params_of(spec)["nodeType"].get("options") or [values["nodeType"]]:
        text, err = helm_render(spec["template"]["helmRelease"]["values"], {**values, "nodeType": option})
        pools = (yaml.safe_load(text) or {}).get("privateNodes", {}).get("autoNodes", []) if not err else []
        for pool in pools:
            if pool["provider"] != provider["metadata"]["name"]:
                fail(f"{where}: autoNodes provider {pool['provider']} is not the platform Stack's NodeProvider")
            for static in pool.get("static", []):
                for selector in static.get("nodeTypeSelector", []):
                    missing = set(selector.get("values", [])) - offered
                    if selector.get("property") == "vcluster.com/node-type" and missing:
                        fail(f"{where}: nodeType {option} selects {sorted(missing)}, which the NodeProvider does not offer ({sorted(offered)})")


# --- StackTemplates: every task in every parameter combination -------------------------------------

def check_template(template_name, scenarios):
    template = templates[template_name]
    spec = template["doc"]["spec"]
    parameters = params_of(spec)
    tasks = spec["tasks"]
    names = [t["name"] for t in tasks]
    if len(tasks) > 20:
        fail(f"{template['path']}: a Stack supports at most 20 tasks")
    for task in tasks:
        for dep in task.get("dependsOn") or []:
            if dep not in names:
                fail(f"{template['path']}: task {task['name']} depends on unknown task {dep}")
        if task.get("outputs") and not re.fullmatch(r"[a-z0-9]+", task["name"]):
            fail(f"{template['path']}: task {task['name']} declares outputs, so its name must be lowercase letters and digits")
        for output in task.get("outputs") or []:
            if not re.fullmatch(r"[a-z0-9]+", output["name"]):
                fail(f"{template['path']}: output {output['name']} must be lowercase letters and digits")
    outputs = {(t["name"], o["name"]) for t in tasks for o in t.get("outputs") or []}
    for published in spec.get("publishedOutputs") or []:
        source = (published["fromTask"]["task"], published["fromTask"]["output"])
        if source not in outputs:
            fail(f"{template['path']}: published output {published['name']} reads unknown {source}")

    selected = set()
    for label, overrides, *captured in scenarios:
        values = typed_defaults(spec)
        values.update(overrides)
        where = f"{template['path']} [{label}]"
        rendered, err = render_strings(fill_outputs(tasks, captured[0] if captured else {}, where), {**values})
        if err:
            fail(f"{where}: tasks do not render: {err}")
            continue
        provider = None
        # vCluster Platform reads outputs only from namespaces the Stack's own Apps install into.
        installed = {apps[t["app"]["templateRef"]["name"]]["doc"]["spec"].get("defaultNamespace")
                     for t in rendered if t["app"]["templateRef"]["name"] in apps}
        for task in rendered:
            for output in task.get("outputs") or []:
                source = (output.get("fromResource") or {}).get("namespace")
                if source not in installed:
                    fail(f"{where}: output {task['name']}.{output['name']} reads from {source}, where no App of this Stack installs")
        for task in rendered:
            ref = task["app"]["templateRef"]["name"]
            if ref not in apps:
                fail(f"{where}: task {task['name']} selects App {ref}, which does not exist")
                continue
            selected.add(ref)
            app_spec = apps[ref]["doc"]["spec"]
            declared = params_of(app_spec)
            passed = task["app"].get("parameters") or {}
            for variable, value in passed.items():
                if variable not in declared:
                    fail(f"{where}: task {task['name']} passes {variable}, which App {ref} does not declare")
                else:
                    validate_value(f"{where} task {task['name']}", declared[variable], value)
            for variable, parameter in declared.items():
                if parameter.get("required") and not passed.get(variable):
                    fail(f"{where}: task {task['name']} does not pass required {variable} to App {ref}")
            helm_timeout = app_spec.get("timeout")
            if app_spec.get("wait") and helm_timeout:
                def minutes(duration):
                    match = re.fullmatch(r"(\d+)m", str(duration))
                    return int(match.group(1)) if match else None
                if minutes(helm_timeout) is None or minutes(task.get("timeout", "10m")) is None:
                    fail(f"{where}: timeouts must be whole minutes")
                elif minutes(helm_timeout) >= minutes(task.get("timeout", "10m")):
                    fail(f"{where}: task {task['name']} timeout {task.get('timeout', '10m')} must exceed App {ref}'s Helm timeout {helm_timeout}")
            # Render the App with exactly what this task passes, as the Platform would.
            app_values = {k: v for k, v in passed.items()}
            result = render_app(ref, app_values, f"{where} task {task['name']}")
            if ref == "metered-inference-shared-gateway" and isinstance(result, list):
                job = find(result, "Job", "metered-inference-gateway-status")[0]
                env = {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0]["env"]}
                want = "true" if values["verifyDNS"] and values["dnsProvider"] != "none" else "false"
                if env["VERIFY_DNS"] != want:
                    fail(f"{where}: the DNS check is {env['VERIFY_DNS']}, want {want} for dnsProvider {values['dnsProvider']}")
                params = find(result, "AgentgatewayParameters")
                annotations = (params[0]["spec"]["service"]["metadata"].get("annotations") or {}) if params else {}
                # The first tenant's ListenerSet must not add a port, which some providers, such as
                # GKE, apply by recreating the load balancer.
                ports = (params[0]["spec"]["service"]["spec"].get("ports") or []) if params else []
                if {"name": "listener-443", "port": 443, "protocol": "TCP", "targetPort": 443} not in ports:
                    fail(f"{where}: the Gateway Service needs port 443 before any tenant listener, not {ports}")
                wanted = yaml.safe_load(passed.get("serviceAnnotations") or "") or {}
                if passed.get("domain"):
                    wanted["external-dns.kubernetes.io/hostname"] = f"*.{passed['domain']}"
                for key, value in wanted.items():
                    if str(annotations.get(key)) != str(value):
                        fail(f"{where}: Gateway Service annotation {key} renders as {annotations.get(key)!r}, not {value!r}")
            if ref == "metered-inference-kubevirt-node-provider" and isinstance(result, list):
                check_node_provider(result, values, f"{where} task {task['name']}")
                provider = node_providers[-1] if find(result, "NodeProvider") else None
            if ref == "metered-inference-cluster-template" and isinstance(result, list):
                check_cluster_template(result, passed, f"{where} task {task['name']}", provider)
            if isinstance(result, dict) and "chart" in app_spec["config"]:
                assert_chart(ref, render_chart(ref, result, f"{where} task {task['name']}"), passed, f"{where} task {task['name']}")
    return selected


gateway_scenarios = [("defaults", {})]
for tls, dns, platform in itertools.product(["self-signed", "letsencrypt", "letsencrypt-staging", "none"],
                                             ["none", "route53", "gandi"], [False, True]):
    overrides = {"tlsIssuer": tls, "dnsProvider": dns, "platformIntegration": platform}
    if dns != "none":
        overrides.update({"domain": "inference.example.com"})
    if platform:
        overrides["platformHost"] = "platform.example.com"
    gateway_scenarios.append((f"tls={tls} dns={dns} platform={platform}", overrides))
gateway_scenarios += [
    ("existing cert-manager", {"installCertManager": False}),
    ("existing Gateway API", {"installGatewayAPI": False}),
    ("service annotations", {"serviceAnnotations": "service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing\n"}),
    ("domain and service annotations", {"domain": "inference.example.com", "dnsProvider": "route53",
                                        "serviceAnnotations": "a.example.com/one: \"1\"\nb.example.com/two: two\n"}),
]
# The platform task's outputs, as the discovery Job writes them: an override, or the Platform's own.
gateway_scenarios = [(label, overrides, {"platform.host": overrides.get("platformHost") or "discovered.example.com",
                                         "platform.namespace": overrides.get("platformNamespace") or "vcluster-platform"})
                     for label, overrides in gateway_scenarios]
gateway_scenarios += [
    ("standalone Grafana", {"platformIntegration": False}, {"platform.host": "not-discovered", "platform.namespace": "vcluster-platform"}),
    ("Platform in another namespace", {}, {"platform.host": "platform.example.com", "platform.namespace": "loft"}),
]
selected = check_template("metered-inference-gateway", gateway_scenarios)


def contract_outputs(tls, domain):
    """The platform Stack's contract outputs, as the gateway Stack would publish them."""
    docs = render_app("metered-inference-shared-gateway", {"tlsIssuer": tls, "domain": domain}, "gateway contract")
    data = find(docs, "ConfigMap", "metered-inference-gateway")[0]["data"]
    return {"contract.domain": domain, "contract.scheme": data["scheme"], "contract.tlsissuer": data["tlsIssuer"]}


check_contract_outputs(templates["metered-inference-platform"])
platform_scenarios = [("defaults", {}, contract_outputs("self-signed", "192.0.2.10.sslip.io"))]
for tls, domain in itertools.product(["self-signed", "letsencrypt", "letsencrypt-staging", "none"],
                                     ["inference.example.com", "203.0.113.10.sslip.io"]):
    platform_scenarios.append((f"tls={tls} domain={domain}", {}, contract_outputs(tls, domain)))
platform_scenarios += [
    (label, overrides, contract_outputs("letsencrypt", "inference.example.com")) for label, overrides in [
        ("existing NodeProvider", {"installNodeProvider": False}),
        ("existing KubeVirt", {"installKubeVirt": False}),
        ("KubeVirt emulation", {"kubeVirtEmulation": True}),
        ("own cluster template", {"installClusterTemplate": False}),
        ("pull Secret", {"jobImagePullSecret": "registry-credentials"}),
        ("gateway settings re-read", {"gatewayRevision": "2"}),
    ]
]
selected |= check_template("metered-inference-platform", platform_scenarios)

service_scenarios = [
    ("minimal", {"apiURL": "https://yellow.all-hands.inference.example.com/v1"}),
    ("everything", {"apiURL": "https://yellow.all-hands.inference.example.com/v1",
                    "chatURL": "https://chat.yellow.all-hands.inference.example.com",
                    "apiKey": "0123456789abcdef0123", "verifyTLS": False, "verifyPublicEndpoint": True,
                    "trafficGenerators": "2", "resourceProfile": "gpu:1", "meterChat": False, "chatUI": False}),
]
selected |= check_template("metered-inference-kubeai", service_scenarios)


# --- Apps outside the StackTemplates ---------------------------------------------------------------

endpoint_scenarios = []
for issuer, chat, key in itertools.product(["metered-inference", ""], ["chat.yellow.all-hands.inference.example.com", ""],
                                            ["0123456789abcdef0123", ""]):
    endpoint_scenarios.append({"apiHostname": "yellow.all-hands.inference.example.com", "chatHostname": chat,
                               "clusterIssuer": issuer, "apiKey": key})
route_names = set()
for i, parameters in enumerate(endpoint_scenarios):
    where = f"metered-inference-endpoint [{i}: issuer={parameters['clusterIssuer'] or 'none'} chat={bool(parameters['chatHostname'])} key={bool(parameters['apiKey'])}]"
    docs = render_app("metered-inference-endpoint", parameters, where)
    routes_cm = find(docs, "ConfigMap", "inference-endpoint-routes")
    if not routes_cm:
        fail(f"{where}: no inference-endpoint-routes ConfigMap")
        continue
    routes = [d for d in yaml.safe_load_all(routes_cm[0]["data"]["routes.yaml"]) if d]
    for route in routes:
        route_names.add(f"{route['metadata']['namespace']}/{route['metadata']['name']}")
        parent = route["spec"]["parentRefs"][0]
        if bool(parameters["clusterIssuer"]) != (parent["kind"] == "ListenerSet"):
            fail(f"{where}: route {route['metadata']['name']} attaches to {parent['kind']}")
    if bool(parameters["chatHostname"]) != (len(routes) == 2):
        fail(f"{where}: expected {'two routes' if parameters['chatHostname'] else 'one route'}, got {len(routes)}")
    if bool(parameters["apiKey"]) != bool(find(docs, "AgentgatewayPolicy")):
        fail(f"{where}: the API key policy should exist exactly when an API key is set")
    if bool(parameters["clusterIssuer"]) != bool(find(docs, "ListenerSet")):
        fail(f"{where}: the ListenerSet should exist exactly when a cluster issuer is set")
    policy = find(docs, "AgentgatewayPolicy")
    if policy and policy[0]["spec"]["targetRefs"][0]["name"] not in {r["metadata"]["name"] for r in routes}:
        fail(f"{where}: the API key policy targets a route that is not rendered")
    namespaces = {d["metadata"].get("namespace") for d in docs}
    if not namespaces <= {LOFT["space"], LOFT["projectNamespace"], "kubevirt"}:
        fail(f"{where}: writes outside the tenant, project, and VM namespaces: {namespaces}")
saved_loft = dict(LOFT)
LOFT.clear()
LOFT["space"] = saved_loft["space"]
render_app("metered-inference-endpoint", {"apiHostname": "a.b.example.com"},
           "metered-inference-endpoint without a tenant identity", expect_failure=True)
LOFT.update(saved_loft)
render_app("metered-inference-platform-connector", {"platformHost": ""}, "connector without platformHost",
           expect_failure=True)

for name in apps:
    if name not in selected and name != "metered-inference-endpoint":
        fail(f"App {name} is not selected by any StackTemplate scenario")

# The tenant Stack's internalurl output is KubeAI's in-cluster Service URL, which every pod in the
# tenant cluster can reach.
report = find(render_app("metered-inference-model", {"modelId": "m", "modelURL": "ollama://m", "apiURL": "https://m.example.com/v1"},
                         "report Job"), "Job")[0]["spec"]["template"]["spec"]["containers"][0]["args"][0]
internal = re.search(r'internalURL="([^"]*)"', report)
if not internal or internal.group(1) != "http://${API_SERVICE}.${NS}.svc.cluster.local/openai/v1":
    fail(f"report Job: internalURL should be the in-cluster Service URL, not {internal.group(1) if internal else 'missing'}")


# --- The endpoint reconciler, run against a stub kubectl ------------------------------------------

STUB = r"""
import json, os, re, sys, yaml
args = sys.argv[1:]
state = os.environ["STUB_STATE"]
log = os.path.join(state, "calls.jsonl")
def record(entry):
    with open(log, "a") as f:
        f.write(json.dumps(entry) + "\n")
ns = args[args.index("-n") + 1] if "-n" in args else ""
if "create" in args and "--dry-run=client" in args:
    # Like kubectl: one JSON object per document, not a List.
    for doc in yaml.safe_load_all(open(args[args.index("-f") + 1])):
        if doc:
            print(json.dumps(doc, indent=2))
    sys.exit(0)
if "create" in args and "-f" in args and args[args.index("-f") + 1] == "-":
    body = json.load(sys.stdin)
    record({"verb": "create", "body": body})
    # Like kubectl: a validated create of a kind outside the built-in schema lists CRDs first,
    # which a Job's ServiceAccount may not do.
    if "--raw" not in args and "--validate=false" not in args:
        print('error: error validating "STDIN": error validating data: failed to check CRD: failed to list CRDs: '
              'customresourcedefinitions.apiextensions.k8s.io is forbidden', file=sys.stderr)
        sys.exit(1)
    if "--raw" in args and args[args.index("--raw") + 1] != "/apis/management.loft.sh/v1/selves":
        print(f'Error from server (NotFound): the server could not find the requested resource', file=sys.stderr)
        sys.exit(1)
    if body.get("kind") != "Self" or os.environ.get("STUB_SELF_FAIL"):
        print('Error from server (Forbidden): selves.management.loft.sh is forbidden', file=sys.stderr)
        sys.exit(1)
    print(json.dumps({**body, "status": {"loftHost": os.environ.get("STUB_LOFT_HOST", "")}}))
    sys.exit(0)
if "apply" in args:
    body = json.load(sys.stdin)
    record({"verb": "apply", "body": body})
    items = body["items"] if body.get("kind") == "List" else [body]
    routes_file = os.path.join(state, "routes.json")
    routes = json.load(open(routes_file)) if os.path.exists(routes_file) else {"items": []}
    for item in items:
        if item["kind"] == "HTTPRoute":
            routes["items"] = [r for r in routes["items"] if r["metadata"]["name"] != item["metadata"]["name"]] + [item]
    json.dump(routes, open(routes_file, "w"))
    sys.exit(0)
if "delete" in args:
    record({"verb": "delete", "args": args})
    sys.exit(0)
if "wait" in args:
    sys.exit(0)
if "patch" in args:
    record({"verb": "patch", "patch": json.loads(args[args.index("-p") + 1])})
    sys.exit(0)
if "get" in args:
    kind = args[args.index("get") + 1]
    if kind == "cronjob":
        print("cronjob-uid")
    elif kind in ("gateway", "service"):
        # The first STUB_STALE_READS Gateway reads report STUB_STALE_ADDRESS, the address of a Service
        # that is being deleted, as when the Gateway is recreated. Then its replacement's.
        reads_file = os.path.join(state, "gateway_reads")
        reads = int(open(reads_file).read()) if os.path.exists(reads_file) else 0
        if kind == "gateway":
            reads += 1
            open(reads_file, "w").write(str(reads))
        stale = reads <= int(os.environ.get("STUB_STALE_READS", "0"))
        address = os.environ["STUB_STALE_ADDRESS"] if stale else os.environ["STUB_ADDRESS"]
        if kind == "gateway":
            print(address)
        else:
            ingress = {"ip": address} if re.fullmatch(r"[0-9.]+", address) else {"hostname": address}
            metadata = {"name": "inference", **({"deletionTimestamp": "2026-01-01T00:00:00Z"} if stale else {})}
            print(json.dumps({"metadata": metadata, "spec": {"type": "LoadBalancer"},
                              "status": {"loadBalancer": {"ingress": [ingress]}}}))
    elif kind == "apiservice":
        if not os.environ.get("STUB_PLATFORM_NAMESPACE"):
            print('Error from server (NotFound): apiservices "v1.management.loft.sh" not found', file=sys.stderr)
            sys.exit(1)
        print(os.environ["STUB_PLATFORM_NAMESPACE"])
    elif kind == "secret":
        print("Q0EgUEVN")
    elif kind == "nodeclaims.storage.loft.sh":
        if os.environ.get("STUB_NODECLAIMS_FAIL"):
            print("Error from server (Forbidden): nodeclaims is forbidden", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(json.load(open(os.path.join(state, "nodeclaims.json")))))
    elif kind == "virtualmachineinstances.kubevirt.io":
        vmis = json.load(open(os.path.join(state, "vmis.json")))
        key = f"{ns}/{args[args.index(kind) + 1]}"
        if key not in vmis:
            print(f'Error from server (NotFound): virtualmachineinstances "{key}" not found', file=sys.stderr)
            sys.exit(1)
        print(json.dumps(vmis[key]))
    elif kind == "httproutes.gateway.networking.k8s.io":
        routes_file = os.path.join(state, "routes.json")
        print(open(routes_file).read() if os.path.exists(routes_file) else json.dumps({"items": []}))
    elif kind in ("nodeproviders.storage.loft.sh", "nodetypes.storage.loft.sh", "namespace", "configmap"):
        path = os.path.join(state, kind.split(".")[0] + ".json")
        objects = json.load(open(path)) if os.path.exists(path) else {}
        name = args[args.index(kind) + 1]
        if name not in objects:
            print(f'Error from server (NotFound): {kind} "{name}" not found', file=sys.stderr)
            sys.exit(1)
        print(json.dumps(objects[name]))
    elif kind in ("kubevirts.kubevirt.io", "cdis.cdi.kubevirt.io", "nodes"):
        path = os.path.join(state, kind.split(".")[0] + ".json")
        print(open(path).read() if os.path.exists(path) else json.dumps({"items": []}))
    else:
        print(f"stub kubectl: unexpected get {kind}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
print(f"stub kubectl: unexpected {args}", file=sys.stderr)
sys.exit(1)
"""


def claim(name, cluster, ready, vm_ref=None):
    return {"metadata": {"name": name, "annotations": {"kubevirt.vcluster.com/vm-ref": vm_ref} if vm_ref else {}},
            "spec": {"vClusterRef": cluster},
            "status": {"conditions": [{"type": "Ready", "status": "True" if ready else "False"}]}}


def vmi(phase, address):
    return {"status": {"phase": phase, "interfaces": [{"name": "default", "ipAddress": address}] if address else []}}


def run_reconciler(parameters, state, fail_claims=False):
    docs = render_app("metered-inference-endpoint", parameters, "endpoint reconciler")
    cronjob = find(docs, "CronJob", "inference-endpoint")[0]
    container = cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
    routes = find(docs, "ConfigMap", "inference-endpoint-routes")[0]["data"]["routes.yaml"]
    (state / "routes.yaml").write_text(routes)
    script = container["args"][0].replace("/routes/routes.yaml", str(state / "routes.yaml"))
    script = script.replace("/tmp/vmi.err", str(state / "vmi.err"))
    bin_dir = state / "bin"
    bin_dir.mkdir(exist_ok=True)
    (bin_dir / "stub.py").write_text(STUB)
    (bin_dir / "kubectl").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / "stub.py"}" "$@"\n')
    (bin_dir / "kubectl").chmod(0o755)
    if subprocess.run(["sh", "-c", "command -v sha256sum"], capture_output=True).returncode != 0:
        (bin_dir / "sha256sum").write_text('#!/bin/sh\nexec shasum -a 256 "$@"\n')
        (bin_dir / "sha256sum").chmod(0o755)
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    env.update({"PATH": f"{bin_dir}:{subprocess.os.environ['PATH']}", "STUB_STATE": str(state), "HOME": str(state)})
    if fail_claims:
        env["STUB_NODECLAIMS_FAIL"] = "1"
    result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
    calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()] if (state / "calls.jsonl").exists() else []
    (state / "calls.jsonl").unlink(missing_ok=True)
    return result, calls


state = work / "reconciler"
state.mkdir()
(state / "nodeclaims.json").write_text(json.dumps({"items": [
    claim("yellow-aaaaa", "yellow", True, "kubevirt/yellow-aaaaa"),
    claim("yellow-bbbbb", "yellow", True),
    claim("yellow-ccccc", "yellow", False, "kubevirt/yellow-ccccc"),
    claim("other-ddddd", "other", True, "kubevirt/other-ddddd"),
    claim("yellow-eeeee", "yellow", True, "loft-all-hands-v-yellow/yellow-eeeee"),
    claim("yellow-fffff", "yellow", True, "kubevirt/yellow-missing"),
]}))
(state / "vmis.json").write_text(json.dumps({
    "kubevirt/yellow-aaaaa": vmi("Running", "10.0.0.1"),
    "kubevirt/yellow-bbbbb": vmi("Running", "10.0.0.2"),
    "kubevirt/yellow-ccccc": vmi("Running", "10.0.0.3"),
    "kubevirt/other-ddddd": vmi("Running", "10.0.0.4"),
    "loft-all-hands-v-yellow/yellow-eeeee": vmi("Scheduling", None),
}))
reconcile_parameters = {"apiHostname": "yellow.all-hands.inference.example.com",
                        "chatHostname": "chat.yellow.all-hands.inference.example.com",
                        "clusterIssuer": "metered-inference", "apiKey": "0123456789abcdef0123"}

result, calls = run_reconciler(reconcile_parameters, state)
if result.returncode != 0:
    fail(f"endpoint reconciler exits {result.returncode}: {result.stderr.strip() or result.stdout.strip()}")
applied = [c["body"] for c in calls if c["verb"] == "apply"]
slices = {b["metadata"]["name"]: b for b in applied if b.get("kind") == "EndpointSlice"}
for name, port in (("inference-api", 30080), ("inference-chat", 30081)):
    if name not in slices:
        fail(f"endpoint reconciler did not apply EndpointSlice {name}")
        continue
    got = sorted(a for e in slices[name]["endpoints"] for a in e["addresses"])
    if got != ["10.0.0.1", "10.0.0.2"]:
        fail(f"endpoint reconciler: EndpointSlice {name} has {got}, want only the tenant cluster's Ready, running VMs")
    if slices[name]["ports"][0]["port"] != port or slices[name]["metadata"]["ownerReferences"][0]["uid"] != "cronjob-uid":
        fail(f"endpoint reconciler: EndpointSlice {name} has the wrong port or owner")
route_lists = [b for b in applied if b.get("kind") == "List"]
applied_routes = [r["metadata"]["name"] for b in route_lists for r in b["items"]]
if sorted(applied_routes) != ["api.all-hands.yellow", "chat.all-hands.yellow"]:
    fail(f"endpoint reconciler applied routes {applied_routes}, want the api and chat routes")

# A second run must leave the routes alone, so a rule sleep mode added survives.
result, calls = run_reconciler(reconcile_parameters, state)
if result.returncode != 0 or any(c["verb"] == "apply" and c["body"].get("kind") == "List" for c in calls):
    fail(f"endpoint reconciler re-applied unchanged routes: {result.stderr.strip() or result.stdout.strip()}")

# Dropping the chat hostname deletes the chat route.
result, calls = run_reconciler({**reconcile_parameters, "chatHostname": ""}, state)
deleted = [c["args"] for c in calls if c["verb"] == "delete"]
if result.returncode != 0 or not any("chat.all-hands.yellow" in a for a in deleted):
    fail(f"endpoint reconciler did not delete the chat route after chatHostname was removed: {result.stderr.strip()}")

# An API error must fail the run, not publish empty endpoints.
result, calls = run_reconciler(reconcile_parameters, state, fail_claims=True)
if result.returncode == 0 or any(c["verb"] == "apply" for c in calls):
    fail("endpoint reconciler published endpoints although it could not read the NodeClaims")


# --- The gateway status Job, run against stub kubectl and nslookup --------------------------------

NSLOOKUP = r"""
import json, os, sys
args = sys.argv[1:]
name = args[0]
with open(os.path.join(os.environ["STUB_STATE"], "calls.jsonl"), "a") as f:
    f.write(json.dumps({"verb": "nslookup", "args": args}) + "\n")
if name == os.environ.get("STUB_LB_HOSTNAME"):
    answers = os.environ.get("STUB_LB_ANSWERS", "")
elif name.endswith("." + os.environ.get("STUB_DNS_DOMAIN", "")):
    answers = os.environ.get("STUB_DNS_ANSWERS", "")
else:
    answers = ""
if not answers:
    print(f"** server can't find {name}: NXDOMAIN")
    sys.exit(1)
# Both busybox nslookup formats: the server's own Address line comes before the answer.
if os.environ.get("STUB_NSLOOKUP_FORMAT") == "small":
    print("Server:    10.96.0.10\nAddress 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local\n")
    print(f"Name:      {name}")
    for i, answer in enumerate(answers.split(","), 1):
        print(f"Address {i}: {answer} host-{i}.example.net")
else:
    print("Server:\t\t10.96.0.10\nAddress:\t10.96.0.10:53\n\nNon-authoritative answer:")
    for answer in answers.split(","):
        print(f"Name:\t{name}\nAddress: {answer}\n")
"""


def run_status_job(parameters, stub_env):
    state = work / f"status{next(counter)}"
    state.mkdir()
    docs = render_app("metered-inference-shared-gateway", parameters, "gateway status Job")
    job = find(docs, "Job", "metered-inference-gateway-status")[0]
    container = job["spec"]["template"]["spec"]["containers"][0]
    bin_dir = state / "bin"
    bin_dir.mkdir()
    (bin_dir / "stub.py").write_text(STUB)
    (bin_dir / "nslookup.py").write_text(NSLOOKUP)
    for tool, script in (("kubectl", "stub.py"), ("nslookup", "nslookup.py")):
        (bin_dir / tool).write_text(f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / script}" "$@"\n')
        (bin_dir / tool).chmod(0o755)
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    env.update({"PATH": f"{bin_dir}:{subprocess.os.environ['PATH']}", "STUB_STATE": str(state), "HOME": str(state),
                "DNS_TIMEOUT_SECONDS": "0", "POLL_SECONDS": "0"})
    env.update(stub_env)
    result = subprocess.run(["sh", "-c", container["args"][0]], env=env, capture_output=True, text=True)
    calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()] if (state / "calls.jsonl").exists() else []
    return result, calls


def published(calls):
    patches = [c["patch"]["data"] for c in calls if c["verb"] == "patch"]
    return patches[0] if patches else None


gateway_parameters = {"domain": "inference.example.com", "tlsIssuer": "self-signed", "verifyDNS": "true"}
dns_env = {"STUB_ADDRESS": "34.1.2.3", "STUB_DNS_DOMAIN": "inference.example.com"}
status_cases = [
    ("resolves", gateway_parameters, {**dns_env, "STUB_DNS_ANSWERS": "34.1.2.3"}, True),
    ("no record", gateway_parameters, dns_env, False),
    ("wrong address", gateway_parameters, {**dns_env, "STUB_DNS_ANSWERS": "9.9.9.9"}, False),
    ("load balancer hostname", gateway_parameters,
     {**dns_env, "STUB_ADDRESS": "abc.elb.us-east-1.amazonaws.com", "STUB_LB_HOSTNAME": "abc.elb.us-east-1.amazonaws.com",
      "STUB_LB_ANSWERS": "52.1.1.1,52.1.1.2", "STUB_DNS_ANSWERS": "52.1.1.2"}, True),
    ("custom resolver", {**gateway_parameters, "dnsCheckResolver": "1.1.1.1"}, {**dns_env, "STUB_DNS_ANSWERS": "34.1.2.3"}, True),
    ("small busybox nslookup", gateway_parameters,
     {**dns_env, "STUB_DNS_ANSWERS": "34.1.2.3", "STUB_NSLOOKUP_FORMAT": "small"}, True),
    ("small busybox nslookup, wrong address", gateway_parameters,
     {**dns_env, "STUB_DNS_ANSWERS": "10.96.0.10", "STUB_NSLOOKUP_FORMAT": "small"}, False),
    ("check off", {**gateway_parameters, "verifyDNS": "false"}, dns_env, True),
    ("sslip.io fallback", {**gateway_parameters, "domain": ""}, dns_env, True),
    # The Gateway is recreated and first reports the address of the Service being deleted.
    ("Service replaced", gateway_parameters,
     {**dns_env, "STUB_DNS_ANSWERS": "34.1.2.3", "STUB_STALE_ADDRESS": "34.9.9.9", "STUB_STALE_READS": "2"}, True),
    ("Service replaced, check off", {**gateway_parameters, "verifyDNS": "false"},
     {**dns_env, "STUB_STALE_ADDRESS": "34.9.9.9", "STUB_STALE_READS": "2"}, True),
]
for label, parameters, stub_env, succeeds in status_cases:
    result, calls = run_status_job(parameters, stub_env)
    where = f"gateway status Job [{label}]"
    contract = published(calls)
    lookups = [c["args"] for c in calls if c["verb"] == "nslookup"]
    if succeeds:
        if result.returncode != 0 or contract is None:
            fail(f"{where}: expected success: {result.stderr.strip() or result.stdout.strip()}")
            continue
        want_domain = parameters["domain"] or f"{stub_env['STUB_ADDRESS']}.sslip.io"
        if contract["domain"] != want_domain or contract["address"] != stub_env["STUB_ADDRESS"] or contract["caCert"] != "CA PEM":
            fail(f"{where}: published {contract}")
        probes = [a for a in lookups if a[0].startswith("probe-")]
        if bool(parameters.get("verifyDNS") == "true" and parameters["domain"]) != bool(probes):
            fail(f"{where}: DNS probes {probes} do not match verifyDNS={parameters.get('verifyDNS')} domain={parameters['domain']!r}")
        if parameters.get("dnsCheckResolver") and any(a[1:] != [parameters["dnsCheckResolver"]] for a in lookups):
            fail(f"{where}: lookups ignored dnsCheckResolver: {lookups}")
    else:
        if result.returncode == 0 or contract is not None:
            fail(f"{where}: expected the Job to fail without publishing the contract")
        elif "does not resolve to the Gateway" not in result.stderr:
            fail(f"{where}: the failure does not explain itself: {result.stderr.strip()}")

# An address only a Service being deleted reports is never published, with or without the DNS check.
for parameters in (gateway_parameters, {**gateway_parameters, "verifyDNS": "false"}):
    result, calls = run_status_job(parameters, {**dns_env, "STUB_STALE_ADDRESS": "34.9.9.9", "STUB_STALE_READS": "1000"})
    if result.returncode == 0 or published(calls) is not None or "no address that its Service also reports" not in result.stderr:
        fail(f"gateway status Job [stale address, verifyDNS={parameters['verifyDNS']}]: expected it to fail "
             f"without publishing the contract: {result.stderr.strip() or result.stdout.strip()}")


# --- The KubeVirt status Job, run against a stub kubectl -------------------------------------------

def run_kubevirt_job(parameters, objects):
    state = work / f"kubevirt{next(counter)}"
    state.mkdir()
    for kind, body in objects.items():
        (state / f"{kind}.json").write_text(json.dumps(body))
    docs = render_app("metered-inference-kubevirt-node-provider", parameters, "KubeVirt status Job")
    container = find(docs, "Job", "metered-inference-kubevirt-status")[0]["spec"]["template"]["spec"]["containers"][0]
    bin_dir = state / "bin"
    bin_dir.mkdir()
    (bin_dir / "stub.py").write_text(STUB)
    (bin_dir / "kubectl").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / "stub.py"}" "$@"\n')
    (bin_dir / "kubectl").chmod(0o755)
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    env.update({"PATH": f"{bin_dir}:{subprocess.os.environ['PATH']}", "STUB_STATE": str(state), "HOME": str(state),
                "PROVIDER_TIMEOUT_SECONDS": "0", "KUBEVIRT_TIMEOUT_SECONDS": "0", "KVM_TIMEOUT_SECONDS": "0",
                "POLL_SECONDS": "0"})
    return subprocess.run(["sh", "-c", container["args"][0]], env=env, capture_output=True, text=True)


def available(status="True"):
    return {"status": {"conditions": [{"type": "Available", "status": status}]}}


def kvm(*allocatable):
    return {"items": [{"status": {"allocatable": {"devices.kubevirt.io/kvm": a} if a else {}}} for a in allocatable]}


ready = {
    "nodeproviders": {"kubevirt": {"status": {"phase": "Available"}}},
    "nodetypes": {"kubevirt.inference-large": {}},
    "kubevirts": {"items": [{"metadata": {"name": "kubevirt", "namespace": "kubevirt"}, **available()}]},
    "cdis": {"items": [available()]},
    # Kubernetes reports the device count as a quantity: 1000 devices is 1k.
    "nodes": kvm("1k", None),
    "namespace": {"kubevirt": {}},
}
no_kvm = {**ready, "nodes": kvm("0", None)}
emulating = {"items": [{"spec": {"configuration": {"developerConfiguration": {"useEmulation": True}}}, **available()}]}
kubevirt_cases = [
    ("ready", {}, ready, None),
    ("license", {}, {**ready, "nodeproviders": {"kubevirt": {"status": {
        "phase": "Failed", "reason": "FeatureNotAllowed", "message": "feature auto-nodes-kubevirt is not allowed"}}}},
     "Failed: FeatureNotAllowed: feature auto-nodes-kubevirt is not allowed"),
    ("deploy keeps failing", {}, {**ready, "nodeproviders": {"kubevirt": {"status": {
        "phase": "Pending", "reason": "DeployResourcesFailed", "message": "failed to deploy kubevirt"}}}},
     "Pending: DeployResourcesFailed: failed to deploy kubevirt"),
    ("no NodeProvider", {}, {**ready, "nodeproviders": {}}, "no status yet"),
    ("no node type", {}, {**ready, "nodetypes": {}}, "no node type kubevirt.inference-large"),
    ("KubeVirt not installed", {}, {**ready, "kubevirts": {"items": []}}, "KubeVirt is not Available"),
    ("CDI not Available", {}, {**ready, "cdis": {"items": [available("False")]}}, "CDI, which imports the VM disks,"),
    ("no hardware virtualization", {}, no_kvm, "kubeVirtEmulation=true"),
    ("no hardware virtualization, emulation", {"emulation": "true"}, no_kvm, None),
    ("existing KubeVirt with emulation", {"installKubeVirt": "false"}, {**no_kvm, "kubevirts": emulating}, None),
    ("existing KubeVirt missing", {"installKubeVirt": "false"}, {**ready, "kubevirts": {"items": []}}, "installKubeVirt is false"),
    ("existing KubeVirt without the VM namespace", {"installKubeVirt": "false"}, {**ready, "namespace": {}},
     "Namespace kubevirt does not exist"),
]
for label, parameters, objects, failure in kubevirt_cases:
    result = run_kubevirt_job(parameters, objects)
    where = f"KubeVirt status Job [{label}]"
    if failure is None and result.returncode != 0:
        fail(f"{where}: expected success: {result.stderr.strip() or result.stdout.strip()}")
    elif failure is not None and (result.returncode == 0 or failure not in result.stderr):
        fail(f"{where}: expected a failure explaining {failure!r}, got {result.returncode}: {result.stderr.strip()}")


# --- The generated platform Apps reproduce their sources -------------------------------------------

tenant_sources = sorted((root / "tenant" / "apps").glob("*.yaml")) + [root / "tenant" / "stacktemplate.yaml"]
registered = render_app("metered-inference-tenant-stack", {}, "metered-inference-tenant-stack")
if registered != [doc for path in tenant_sources for doc in load(path)]:
    fail("metered-inference-tenant-stack does not register the tenant Apps and StackTemplate exactly as in tenant/")

template_source = (root / "source" / "virtualclustertemplate.yaml").read_text()
for tls, pull_secret in (("letsencrypt", ""), ("self-signed", "registry-credentials"), ("none", "")):
    contract = contract_outputs(tls, "inference.example.com")
    parameters = {"domain": "inference.example.com", "scheme": contract["contract.scheme"], "tlsIssuer": tls,
                  "jobImagePullSecret": pull_secret}
    want = template_source
    for placeholder, value in {"__DOMAIN__": "inference.example.com", "__SCHEME__": contract["contract.scheme"],
                               "__CLUSTER_ISSUER__": "" if tls == "none" else "metered-inference",
                               "__VERIFY_TLS__": "true" if tls == "letsencrypt" else "false",
                               "__JOB_IMAGE_PULL_SECRET__": pull_secret}.items():
        want = want.replace(placeholder, value)
    if render_app("metered-inference-cluster-template", parameters, f"cluster template [{tls}]") != [yaml.safe_load(want)]:
        fail(f"metered-inference-cluster-template [{tls}] does not render source/virtualclustertemplate.yaml with the contract filled in")

# The template App refuses contract values it cannot place safely in the template.
for label, parameters in [
    ("no domain", {"scheme": "https", "tlsIssuer": "self-signed"}),
    ("domain with a quote", {"domain": 'a.example.com"', "scheme": "https", "tlsIssuer": "self-signed"}),
    ("scheme against the issuer", {"domain": "a.example.com", "scheme": "http", "tlsIssuer": "letsencrypt"}),
    ("unknown issuer", {"domain": "a.example.com", "scheme": "https", "tlsIssuer": "vault"}),
    ("pull Secret with a quote", {"domain": "a.example.com", "scheme": "https", "tlsIssuer": "none", "jobImagePullSecret": 'x"'}),
]:
    render_app("metered-inference-cluster-template", parameters, f"cluster template [{label}]", expect_failure=True)


# --- The gateway contract Job, run against a stub kubectl ------------------------------------------

def run_contract_job(configmaps):
    state = work / f"contract{next(counter)}"
    state.mkdir()
    (state / "configmap.json").write_text(json.dumps(configmaps))
    docs = render_app("metered-inference-gateway-contract", {}, "gateway contract Job")
    container = find(docs, "Job", "metered-inference-gateway-contract")[0]["spec"]["template"]["spec"]["containers"][0]
    bin_dir = state / "bin"
    bin_dir.mkdir()
    (bin_dir / "stub.py").write_text(STUB)
    (bin_dir / "kubectl").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / "stub.py"}" "$@"\n')
    (bin_dir / "kubectl").chmod(0o755)
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    env.update({"PATH": f"{bin_dir}:{subprocess.os.environ['PATH']}", "STUB_STATE": str(state), "HOME": str(state),
                "CONTRACT_TIMEOUT_SECONDS": "0", "POLL_SECONDS": "0"})
    return subprocess.run(["sh", "-c", container["args"][0]], env=env, capture_output=True, text=True)


published_contract = {"data": {"domain": "203.0.113.10.sslip.io", "scheme": "https", "tlsIssuer": "self-signed"}}
for label, configmaps, failure in [
    ("published", {"metered-inference-gateway": published_contract}, None),
    ("no gateway Stack", {}, "Install that Stack on this cluster first"),
    ("no address yet", {"metered-inference-gateway": {"data": {"domain": "", "scheme": "https"}}}, "Install that Stack"),
    ("no scheme", {"metered-inference-gateway": {"data": {"domain": "a.example.com"}}}, "no valid scheme"),
]:
    result = run_contract_job(configmaps)
    where = f"gateway contract Job [{label}]"
    if failure is None and result.returncode != 0:
        fail(f"{where}: expected success: {result.stderr.strip() or result.stdout.strip()}")
    elif failure is not None and (result.returncode == 0 or failure not in result.stderr):
        fail(f"{where}: expected a failure explaining {failure!r}, got {result.returncode}: {result.stderr.strip()}")


# --- The Platform discovery Job, run against a stub kubectl ----------------------------------------

def run_discovery_job(parameters, stub_env):
    state = work / f"discovery{next(counter)}"
    state.mkdir()
    docs = render_app("metered-inference-platform-discovery", parameters, "Platform discovery Job")
    container = find(docs, "Job", "metered-inference-platform-discovery")[0]["spec"]["template"]["spec"]["containers"][0]
    bin_dir = state / "bin"
    bin_dir.mkdir()
    (bin_dir / "stub.py").write_text(STUB)
    (bin_dir / "kubectl").write_text(f'#!/bin/sh\nexec "{sys.executable}" "{bin_dir / "stub.py"}" "$@"\n')
    (bin_dir / "kubectl").chmod(0o755)
    script = container["args"][0].replace("/tmp/", f"{state}/")
    env = {e["name"]: e.get("value", "") for e in container["env"]}
    env.update({"PATH": f"{bin_dir}:{subprocess.os.environ['PATH']}", "STUB_STATE": str(state), "HOME": str(state)})
    env.update(stub_env)
    result = subprocess.run(["sh", "-c", script], env=env, capture_output=True, text=True)
    calls = [json.loads(line) for line in (state / "calls.jsonl").read_text().splitlines()] if (state / "calls.jsonl").exists() else []
    patches = [c["patch"]["data"] for c in calls if c["verb"] == "patch"]
    return result, patches[0] if patches else None, [c for c in calls if c["verb"] == "create"]


platform_env = {"STUB_LOFT_HOST": "discovered.example.com", "STUB_PLATFORM_NAMESPACE": "vcluster-platform"}
for label, parameters, stub_env, want in [
    ("discovered", {"platformIntegration": "true"}, platform_env, {"host": "discovered.example.com", "namespace": "vcluster-platform"}),
    ("overrides", {"platformIntegration": "true", "platformHost": "https://platform.example.com/", "platformNamespace": "loft"},
     {**platform_env, "STUB_SELF_FAIL": "1"}, {"host": "platform.example.com", "namespace": "loft"}),
    ("host with a port", {"platformIntegration": "true"}, {**platform_env, "STUB_LOFT_HOST": "localhost:9898"},
     {"host": "localhost:9898", "namespace": "vcluster-platform"}),
    ("Self refused", {"platformIntegration": "true"}, {**platform_env, "STUB_SELF_FAIL": "1"}, "Set platformHost"),
    ("no host reported", {"platformIntegration": "true"}, {**platform_env, "STUB_LOFT_HOST": ""}, "reports no host"),
    ("not a host name", {"platformIntegration": "true", "platformHost": "platform example"}, platform_env, "not a host name"),
    ("no API service", {"platformIntegration": "true"}, {"STUB_LOFT_HOST": "discovered.example.com"}, "namespace vCluster Platform runs in"),
    ("standalone, nothing found", {"platformIntegration": "false"}, {"STUB_SELF_FAIL": "1"},
     {"host": "not-discovered", "namespace": "vcluster-platform"}),
]:
    result, published, creates = run_discovery_job(parameters, stub_env)
    where = f"Platform discovery Job [{label}]"
    if isinstance(want, dict):
        if result.returncode != 0 or published != want:
            fail(f"{where}: expected {want}, published {published}: {result.stderr.strip()}")
        if parameters.get("platformHost") and creates:
            fail(f"{where}: asked the Platform for its host although platformHost was given")
    elif result.returncode == 0 or want not in result.stderr or published is not None:
        fail(f"{where}: expected a failure explaining {want!r}, got {result.returncode}: {result.stderr.strip()}")


# --- Examples --------------------------------------------------------------------------------------

for path in sorted(root.glob("*/example/*.yaml")):
    where = path.relative_to(root)
    for doc in load(path):
        kind = doc["kind"]
        if kind == "StackInstance":
            name = doc["spec"]["templateRef"]["name"]
            if name not in templates:
                fail(f"{where}: StackInstance of unknown StackTemplate {name}")
                continue
            declared = params_of(templates[name]["doc"]["spec"])
            for variable, value in (doc["spec"].get("parameters") or {}).items():
                if variable not in declared:
                    fail(f"{where}: parameter {variable} is not declared by {name}")
                else:
                    validate_value(where, declared[variable], value)
        elif kind == "AppInstance":
            name = doc["spec"]["templateRef"]["name"]
            if name not in apps:
                fail(f"{where}: AppInstance of unknown App {name}")
                continue
            parameters = doc["spec"].get("parameters") or {}
            if not isinstance(parameters, dict):
                fail(f"{where}: AppInstance parameters must be an object")
                continue
            declared = params_of(apps[name]["doc"]["spec"])
            for variable in parameters:
                if variable not in declared:
                    fail(f"{where}: parameter {variable} is not declared by App {name}")
            saved = dict(LOFT)
            LOFT.update({"virtualClusterName": "", "space": doc["spec"]["destination"]["cluster"]["namespace"]})
            render_app(name, parameters, str(where))
            LOFT.clear()
            LOFT.update(saved)
        else:
            fail(f"{where}: unexpected kind {kind}")


# --- Routes, recording rules, and dashboards agree -------------------------------------------------

prometheus_values = render_app("metered-inference-prometheus", {}, "metered-inference-prometheus")
rules = prometheus_values["serverFiles"]["recording_rules.yml"]["groups"][0]["rules"]
recorded = {rule["record"] for rule in rules}
for rule in rules:
    selector = re.search(r"route=~`([^`]+)`", rule["expr"]).group(1)
    captures = re.findall(r'"(tenant_project|tenant_cluster)", "\$1", "route", `([^`]+)`', rule["expr"])
    api_routes = [r for r in route_names if "/api." in r]
    if not api_routes:
        fail("no API route was rendered to check the recording rules against")
    for route in api_routes:
        if not re.fullmatch(selector, route):
            fail(f"recording rule {rule['record']} does not select the endpoint route {route}")
        for label, pattern in captures:
            match = re.fullmatch(pattern, route)
            want = LOFT["project"] if label == "tenant_project" else LOFT["virtualClusterName"]
            if not match or match.group(1) != want:
                fail(f"recording rule {rule['record']} reads {label} from {route} as {match and match.group(1)!r}, not {want!r}")

for path in sorted((root / "dashboards").glob("*.json")):
    dashboard = json.loads(path.read_text())
    where = path.relative_to(root)
    exprs = []

    def walk(panels):
        for panel in panels:
            exprs.extend(t["expr"] for t in panel.get("targets", []))
            walk(panel.get("panels", []))

    walk(dashboard["panels"])
    exprs += [v["query"]["query"] for v in dashboard["templating"]["list"] if v["type"] == "query"]
    for expr in exprs:
        for metric in re.findall(r"vcluster_platform_tenant:[a-z_]+", expr):
            if metric not in recorded:
                fail(f"{where}: {metric} is not produced by a recording rule")
        if re.search(r"vcluster_platform_(project|instance)\s*=~", expr):
            fail(f"{where}: the Platform query proxy rejects regular expression matchers on scope labels: {expr[:100]}")
tenant = json.loads((root / "dashboards" / "tenant-usage.json").read_text())
if tenant["uid"] != "vcluster-cluster-observability":
    fail("tenant-usage.json must keep the UID the Platform's Observability tab embeds")

dashboards = render_app("metered-inference-dashboards", {"platformIntegration": True, "inputPricePerMillion": "1.5"},
                        "metered-inference-dashboards")
for cm in dashboards:
    for body in cm["data"].values():
        rendered = json.loads(body)
        prices = [v for v in rendered["templating"]["list"] if v["name"] == "input_price"]
        if not prices or prices[0]["query"] != "1.5":
            fail(f"{cm['metadata']['name']}: the input price parameter is not substituted")
        if "{{" not in body.encode().decode("unicode_escape"):
            fail(f"{cm['metadata']['name']}: legend formats were lost in rendering")
if len(dashboards) != 2:
    fail(f"metered-inference-dashboards: expected 2 dashboards with the Platform integration, got {len(dashboards)}")

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
print(f"ok {len(apps)} Apps, {len(templates)} StackTemplates, {len(gateway_scenarios) + len(platform_scenarios) + len(service_scenarios)} Stack scenarios"
      + (" (charts not rendered: --offline)" if offline else ", upstream charts rendered"))
CHECKS
