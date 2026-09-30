#!/usr/bin/env bash
# Static and rendered checks for the NVIDIA GPU Operator Certified Stack. No cluster needed.
#
# Renders every task's parameters the way the Stack controller does, then renders each referenced
# App the way the AppInstance controller does, for several parameter sets, and checks the result.
# Set RENDER_CHARTS=1 to also render the upstream charts with the rendered values (needs network).
# Set CHART_DIR to a directory of untarred charts (<dir>/<chart name>) to render local copies instead.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
for tool in python3 helm; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml)"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$root" "$work" "${RENDER_CHARTS:-0}" "${CHART_DIR:-}" <<'PY'
import copy, json, re, subprocess, sys
from pathlib import Path

import yaml

root, work, render_charts, chart_dir = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "1", sys.argv[4]
failures = []
rendered_charts = {}
PREFIX = "nvidia-gpu-operator-stack"
PLATFORM_DEPLOY_CAP = 30 * 60


def fail(message):
    failures.append(message)


def seconds(duration):
    """Go duration (e.g. 1h2m30s, 15m0s) to seconds."""
    total, rest = 0, duration
    for amount, unit in re.findall(r"(\d+)(h|m|s)", duration):
        total += int(amount) * {"h": 3600, "m": 60, "s": 1}[unit]
        rest = rest.replace(amount + unit, "", 1)
    if rest:
        raise ValueError(f"not a duration: {duration}")
    return total


def load(path):
    return yaml.safe_load(path.read_text())


def helm_template(chart, values, name, namespace):
    values_file = chart / "values-under-test.yaml"
    values_file.write_text(yaml.safe_dump(values))
    result = subprocess.run(
        ["helm", "template", name, str(chart), "--namespace", namespace, "-f", str(values_file)],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip())
    return result.stdout


def new_chart(label, templates):
    chart = work / label
    (chart / "templates").mkdir(parents=True, exist_ok=True)
    (chart / "Chart.yaml").write_text(f"apiVersion: v2\nname: {label[:50]}\nversion: 0.0.0\n")
    for filename, body in templates.items():
        (chart / "templates" / filename).write_text(body)
    return chart


def tpl_render(label, strings, values, release_name, namespace):
    """Render template strings with Helm's engine, the same sprig functions Platform uses."""
    template = (
        "{{- range $i, $s := .Values.__strings }}\n"
        "s{{ $i }}: {{ tpl $s $ | toJson }}\n"
        "{{- end }}\n")
    chart = new_chart(label, {"strings.yaml": template})
    rendered = helm_template(chart, {**values, "__strings": strings}, release_name, namespace)
    body = yaml.safe_load(rendered.split("\n", 2)[2])
    return [body[f"s{i}"] for i in range(len(strings))]


# ---------------------------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------------------------
stack = load(root / "stacktemplate.yaml")
apps = {}
for path in sorted((root / "apps").glob("*.yaml")):
    app = load(path)
    name = app["metadata"]["name"]
    if app.get("kind") != "App":
        fail(f"{path}: kind must be App (the Platform bundle loads only App, StackTemplate, VirtualClusterTemplate)")
    if name in apps:
        fail(f"{path}: duplicate App name {name}")
    if not name.startswith(PREFIX + "-"):
        fail(f"{path}: App name {name} must start with {PREFIX}-")
    apps[name] = (path, app)

if stack["metadata"]["name"] != PREFIX:
    fail(f"StackTemplate name must be {PREFIX}")
if stack["metadata"].get("annotations", {}).get("vcluster.com/certified") != "true":
    fail('StackTemplate needs annotation vcluster.com/certified: "true"')

# Cluster-scoped names must not collide with any other integration in the catalog.
repo = root.parent
for other in repo.rglob("*.yaml"):
    if root in other.parents or ".git" in other.parts:
        continue
    try:
        documents = list(yaml.safe_load_all(other.read_text()))
    except yaml.YAMLError:
        continue  # Run:ai sources with variant markers are not valid YAML by design.
    for document in documents:
        if isinstance(document, dict) and document.get("kind") in ("App", "StackTemplate"):
            other_name = document.get("metadata", {}).get("name")
            if other_name in apps or other_name == PREFIX:
                fail(f"{other}: {document['kind']} {other_name} collides with this integration")

params = {p["variable"]: p for p in stack["spec"]["parameters"]}
for name, parameter in params.items():
    if parameter.get("type") in ("boolean", "number") and "defaultValue" not in parameter:
        fail(f"StackTemplate parameter {name}: booleans and numbers need a defaultValue or rendering fails")

tasks = {task["name"]: task for task in stack["spec"]["tasks"]}
task_text = yaml.safe_dump(stack["spec"]["tasks"])
for used in set(re.findall(r"\.Values\.([A-Za-z0-9_]+)", task_text)):
    if used not in params:
        fail(f"tasks reference .Values.{used}, which is not a StackTemplate parameter")


def ancestors(task_name, seen=None):
    seen = set() if seen is None else seen
    for dependency in tasks[task_name].get("dependsOn", []):
        if dependency not in seen:
            seen.add(dependency)
            ancestors(dependency, seen)
    return seen


def template_names(task):
    """Every App name a possibly templated templateRef.name can render to."""
    name = task["app"]["templateRef"]["name"]
    match = re.fullmatch(r"(.*)\{\{ if [^}]+ \}\}(.*)\{\{ else \}\}(.*)\{\{ end \}\}(.*)", name)
    if match:
        head, a, b, tail = match.groups()
        return [head + a + tail, head + b + tail]
    return [name]


for name, task in tasks.items():
    if "app" not in task:
        fail(f"task {name}: must be an app task")
        continue
    for dependency in task.get("dependsOn", []):
        if dependency not in tasks:
            fail(f"task {name}: dependsOn unknown task {dependency}")
    if not re.fullmatch(r"(\d+h)?(\d+m)?\d+s", task.get("timeout", "")):
        fail(f"task {name}: timeout {task.get('timeout')!r} must be a full Go duration such as 15m0s")
        continue
    task_timeout = seconds(task["timeout"])
    parameters = task["app"].get("parameters", {})
    for reference, output in re.findall(r"\.Outputs\.([A-Za-z0-9]+)\.([A-Za-z0-9]+)", yaml.safe_dump(parameters)):
        if reference not in ancestors(name):
            fail(f"task {name}: reads .Outputs.{reference} but does not depend on it")
        elif output not in {o["name"] for o in tasks[reference].get("outputs", [])}:
            fail(f"task {name}: reads undeclared output {reference}.{output}")
    for app_name in template_names(task):
        if app_name not in apps:
            fail(f"task {name}: templateRef {app_name} has no App in apps/")
            continue
        app = apps[app_name][1]["spec"]
        app_timeout = seconds(app.get("timeout", "5m"))
        if app_timeout > PLATFORM_DEPLOY_CAP:
            fail(f"App {app_name}: timeout {app['timeout']} exceeds the Platform per-deploy cap of 30m")
        # A gate's own Job deadline bounds the deploy; otherwise the Helm timeout does.
        bound = app_timeout
        if app_name == f"{PREFIX}-gate":
            bound = int(parameters.get("timeoutSeconds", 1380)) + 60
        if task_timeout <= bound:
            fail(f"task {name}: timeout {task['timeout']} must exceed {bound}s so the task reports the failure")
        if not app.get("wait"):
            fail(f"App {app_name}: needs wait: true so the task tracks readiness")
        for output in task.get("outputs", []):
            namespace = output["fromResource"]["namespace"]
            if namespace != app["defaultNamespace"]:
                fail(f"task {name}: output {output['name']} reads namespace {namespace}, "
                     f"but outputs are readable only from {app['defaultNamespace']}")
    if task.get("outputs") and not re.fullmatch(r"[A-Za-z0-9]+", name):
        fail(f"task {name}: declares outputs, so its name must be letters and digits only")
    for output in task.get("outputs", []):
        if not re.fullmatch(r"[a-z0-9]+", output["name"]):
            fail(f"task {name}: output name {output['name']} must be lowercase letters and digits")

for published in stack["spec"].get("publishedOutputs", []):
    source = published["fromTask"]
    if source["output"] not in {o["name"] for o in tasks.get(source["task"], {}).get("outputs", [])}:
        fail(f"publishedOutputs {published['name']}: {source['task']}.{source['output']} is not declared")

# Examples pass only parameters the StackTemplate declares.
instance = load(root / "example" / "stackinstance.yaml")
for key in instance["spec"].get("parameters", {}):
    if key not in params:
        fail(f"example/stackinstance.yaml: unknown parameter {key}")
if instance["spec"]["templateRef"]["name"] != PREFIX:
    fail("example/stackinstance.yaml: templateRef must name the StackTemplate")
vct = (root / "example" / "vcluster-template-with-gpu-stack.yaml").read_text()
stack_block = vct.split("stacks:", 1)[1].split("parameters:", 1)[1]
for key in re.findall(r"^ {16}([A-Za-z0-9]+):", stack_block, re.M):
    if key not in params:
        fail(f"example/vcluster-template-with-gpu-stack.yaml: unknown Stack parameter {key}")

# ---------------------------------------------------------------------------------------------
# Rendered checks
# ---------------------------------------------------------------------------------------------
def typed_defaults(overrides):
    values = {}
    for name, parameter in params.items():
        raw = overrides.get(name, parameter.get("defaultValue", ""))
        if parameter.get("type") == "boolean":
            values[name] = str(raw).lower() == "true"
        elif parameter.get("type") == "number":
            values[name] = int(raw)
        else:
            values[name] = raw
    return values


def render_task(scenario, task, values):
    """Render templateRef.name and parameters as the Stack controller does."""
    parameters = task["app"].get("parameters", {})
    keys = list(parameters)
    strings = [task["app"]["templateRef"]["name"]] + [
        str(parameters[k]).replace(".Outputs.", ".Values.__outputs.") for k in keys]
    outputs = {"gpuready": {"gpucount": "1", "dcgmhost": "nvidia-dcgm.gpu-operator.svc", "dcgmport": "5555"}}
    rendered = tpl_render(f"{scenario}-{task['name']}-task", strings, {**values, "__outputs": outputs},
                          "stack", "p-default")
    return rendered[0], dict(zip(keys, rendered[1:]))


def render_app(scenario, task_name, app_name, parameters):
    """Render an App as the AppInstance controller does. Returns (objects, chart values)."""
    app = apps[app_name][1]["spec"]
    release = f"{PREFIX}-{task_name}-a1b2c3"[:53]
    namespace = app["defaultNamespace"]
    config = app["config"]
    if "manifests" in config:
        chart = new_chart(f"{scenario}-{task_name}-app", {"manifests.yaml": config["manifests"]})
        values = {**parameters, "__image__": "ghcr.io/loft-sh/vcluster-platform:test"}
        rendered = helm_template(chart, values, release, namespace)
        return [d for d in yaml.safe_load_all(rendered) if d], None
    [values_text] = tpl_render(f"{scenario}-{task_name}-values", [config["values"]],
                               parameters, release, namespace)
    values = yaml.safe_load(values_text) or {}
    if render_charts:
        chart = config["chart"]
        merged = {**parameters, **values}
        values_file = work / f"{scenario}-{task_name}-chart-values.yaml"
        values_file.write_text(yaml.safe_dump(merged))
        local = Path(chart_dir) / chart["name"] if chart_dir else None
        if local and (local / "Chart.yaml").exists():
            if load(local / "Chart.yaml")["version"] != chart["version"]:
                fail(f"{scenario}: {local} is not version {chart['version']}")
            args = ["helm", "template", release, str(local)]
        elif chart["repoURL"].startswith("oci:"):
            # Platform pulls <repoURL>/<name>, the same reference Helm resolves here.
            args = ["helm", "template", release, chart["repoURL"] + "/" + chart["name"], "--version", chart["version"]]
        else:
            args = ["helm", "template", release, chart["name"], "--repo", chart["repoURL"], "--version", chart["version"]]
        # AppInstance deploys skip schema validation, and Platform merges parameters into values.
        args += ["--namespace", namespace, "-f", str(values_file), "--skip-schema-validation"]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{scenario}: upstream chart {chart['name']} failed to render: {result.stderr.strip()}")
        else:
            rendered_charts[(scenario, task_name)] = [d for d in yaml.safe_load_all(result.stdout) if d]
    return None, values


def find(objects, kind, name=None):
    return [o for o in objects if o.get("kind") == kind and (name is None or o["metadata"]["name"] == name)]


def job_env(job):
    return {e["name"]: e.get("value") for e in job["spec"]["template"]["spec"]["containers"][0].get("env", [])}


scenarios = {
    "defaults": {},
    "placed": {
        "cpuNodeSelector": "workload.example.com/pool=cpu-services",
        "gpuNodeSelector": "workload.example.com/pool=gpu-compute",
        "driverPreinstalled": "true",
        "certManagerPreinstalled": "true",
        "waitForClusterPolicy": "true",
        "minGPUs": "2",
    },
}

for scenario, overrides in scenarios.items():
    values = typed_defaults(overrides)
    cpu = values["cpuNodeSelector"].split("=", 1) if values["cpuNodeSelector"] else None
    gpu = values["gpuNodeSelector"].split("=", 1) if values["gpuNodeSelector"] else None
    for name, task in tasks.items():
        try:
            app_name, parameters = render_task(scenario, task, values)
        except RuntimeError as error:
            fail(f"{scenario}: task {name} did not render: {error}")
            continue
        if app_name not in apps:
            fail(f"{scenario}: task {name} renders templateRef {app_name!r}, which has no App")
            continue
        for key, value in parameters.items():
            if "<no value>" in value or "{{" in value:
                fail(f"{scenario}: task {name} parameter {key} rendered to {value!r}")
        try:
            objects, chart_values = render_app(scenario, name, app_name, parameters)
        except (RuntimeError, yaml.YAMLError) as error:
            fail(f"{scenario}: App {app_name} for task {name} did not render: {error}")
            continue
        where = f"{scenario}: task {name} ({app_name})"

        if objects is not None:
            for obj in objects:
                if len(obj["metadata"]["name"]) > 63:
                    fail(f"{where}: {obj['kind']} name {obj['metadata']['name']} exceeds 63 characters")
            for job in find(objects, "Job"):
                pod = job["spec"]["template"]["spec"]
                image = pod["containers"][0]["image"]
                if not image:
                    fail(f"{where}: Job {job['metadata']['name']} has no image")
                if app_name == f"{PREFIX}-gate":
                    selector = pod.get("nodeSelector")
                    if cpu and selector != {cpu[0]: cpu[1]}:
                        fail(f"{where}: gate Job nodeSelector {selector}, expected {cpu[0]}={cpu[1]}")
                    if not cpu and selector:
                        fail(f"{where}: gate Job has a nodeSelector with no cpuNodeSelector set")
                    script = pod["containers"][0]["args"][0]
                    check = subprocess.run(["sh", "-n"], input=script, capture_output=True, text=True)
                    if check.returncode != 0:
                        fail(f"{where}: gate script does not parse: {check.stderr.strip()}")
                if app_name == f"{PREFIX}-smoke-test":
                    if pod["containers"][0]["resources"]["limits"].get("nvidia.com/gpu") != 1:
                        fail(f"{where}: smoke test must request one nvidia.com/gpu")
                    if gpu and pod.get("nodeSelector") != {gpu[0]: gpu[1]}:
                        fail(f"{where}: smoke test nodeSelector {pod.get('nodeSelector')}, expected {gpu}")

        if name == "cert-manager":
            expected = f"{PREFIX}-gate" if values["certManagerPreinstalled"] else f"{PREFIX}-cert-manager"
            if app_name != expected:
                fail(f"{where}: expected templateRef {expected}")
            if objects is not None:
                env = job_env(find(objects, "Job")[0])
                if env["WAIT_RESOURCE"] != "deployment/cert-manager-webhook" or env["CONTRACT_NAME"]:
                    fail(f"{where}: preinstalled check must wait on the webhook and publish nothing")
            elif cpu and chart_values.get("global", {}).get("nodeSelector", {}).get(cpu[0]) != cpu[1]:
                fail(f"{where}: cert-manager global.nodeSelector does not carry {cpu}")

        if name == "gpuready":
            env = job_env(find(objects, "Job")[0])
            if env["CAPACITY_MIN"] != str(values["minGPUs"]):
                fail(f"{where}: CAPACITY_MIN {env['CAPACITY_MIN']} != minGPUs {values['minGPUs']}")
            wants_wait = values["waitForClusterPolicy"]
            if bool(env["WAIT_RESOURCE"]) != wants_wait:
                fail(f"{where}: WAIT_RESOURCE={env['WAIT_RESOURCE']!r} with waitForClusterPolicy={wants_wait}")
            if env["CAPACITY_NODE_SELECTOR"] != values["gpuNodeSelector"]:
                fail(f"{where}: capacity selector {env['CAPACITY_NODE_SELECTOR']!r} != gpuNodeSelector")
            contract = find(objects, "ConfigMap", "gpu-stack-contract")
            if not contract:
                fail(f"{where}: no gpu-stack-contract ConfigMap")
            else:
                data = contract[0].get("data", {})
                for output in task["outputs"]:
                    key = output["fromResource"]["jsonPath"].split(".")[-1].rstrip("}")
                    # observedCount is written by the Job, never by the release, so Helm upgrades keep it.
                    if key == "observedCount":
                        if key in data:
                            fail(f"{where}: the release must not declare {key}")
                    elif key not in data:
                        fail(f"{where}: output {output['name']} reads {key}, which the contract lacks")
                if "ready" in data:
                    fail(f"{where}: the release must not declare ready; an upgrade would reset it")

        if name == "dcgmready":
            env = job_env(find(objects, "Job")[0])
            if (env["WAIT_RESOURCE"] != "daemonset/nvidia-dcgm" or env["WAIT_CONDITION"] != "rollout"
                    or env["CONTRACT_NAME"] or env["CAPACITY_MIN"] != "0"):
                fail(f"{where}: dcgmready must only wait on daemonset/nvidia-dcgm")

        if name == "gpu-operator":
            driver = chart_values["driver"]["enabled"]
            if driver == values["driverPreinstalled"]:
                fail(f"{where}: driver.enabled={driver} with driverPreinstalled={values['driverPreinstalled']}")
            selector = chart_values["operator"]["nodeSelector"]
            if cpu and selector.get(cpu[0]) != cpu[1]:
                fail(f"{where}: operator.nodeSelector {selector} lacks {cpu}")
            worker = chart_values["node-feature-discovery"]["worker"]
            if gpu and worker.get("nodeSelector", {}).get(gpu[0]) != gpu[1]:
                fail(f"{where}: NFD worker nodeSelector lacks {gpu}")
            if not gpu and "nodeSelector" in worker:
                fail(f"{where}: NFD worker must run on every node when gpuNodeSelector is empty")

        if name == "nvsentinel":
            if chart_values["labeler"]["assumeDriverInstalled"] != values["driverPreinstalled"]:
                fail(f"{where}: labeler.assumeDriverInstalled does not follow driverPreinstalled")
            key, value = gpu or ("nvidia.com/gpu.present", "true")
            if chart_values["global"]["nodeSelector"].get(key) != value:
                fail(f"{where}: global.nodeSelector lacks {key}={value}")
            if chart_values["global"]["dcgm"]["service"]["endpoint"] != "nvidia-dcgm.gpu-operator.svc":
                fail(f"{where}: DCGM endpoint does not come from the gpuready contract")

# ---------------------------------------------------------------------------------------------
# Gate script behavior, against a stub kubectl
# ---------------------------------------------------------------------------------------------
_, gpuready_parameters = render_task("gate", tasks["gpuready"], typed_defaults({"minGPUs": "2"}))
gate_objects, _ = render_app("gate", "gpuready", f"{PREFIX}-gate", gpuready_parameters)
gate_job = find(gate_objects, "Job")[0]
gate_script = gate_job["spec"]["template"]["spec"]["containers"][0]["args"][0]
stub_dir = work / "stub-bin"
stub_dir.mkdir()
(stub_dir / "kubectl").write_text("""#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$*" in
  *"get nodes"*) echo "$STUB_ALLOCATABLE" ;;
  *" wait "*|wait*|*"rollout status"*) exit 0 ;;
esac
exit 0
""")
(stub_dir / "kubectl").chmod(0o755)


def run_gate(env_overrides, allocatable):
    log = work / "stub.log"
    log.write_text("")
    env = {"PATH": f"{stub_dir}:/usr/bin:/bin", "STUB_LOG": str(log), "STUB_ALLOCATABLE": allocatable,
           **job_env(gate_job), "POLL_SECONDS": "0", **env_overrides}
    result = subprocess.run(["sh", "-c", gate_script], env=env, capture_output=True, text=True)
    return result, log.read_text()


result, calls = run_gate({}, "1 1")
if result.returncode != 0 or "patch configmap gpu-stack-contract" not in calls or '"observedCount":"2"' not in calls:
    fail(f"gate: two allocatable GPUs should pass and mark the contract ready\n{result.stdout}{result.stderr}{calls}")
if "clusterpolicy" in calls:
    fail("gate: waitForClusterPolicy=false must not touch ClusterPolicy")
result, calls = run_gate({"TIMEOUT_SECONDS": "0"}, "1")
if result.returncode == 0 or "patch" in calls:
    fail("gate: one GPU against minGPUs=2 must fail at the deadline without marking the contract")
result, calls = run_gate({"WAIT_RESOURCE": "clusterpolicy/cluster-policy"}, "2")
if result.returncode != 0 or "wait clusterpolicy/cluster-policy" not in calls:
    fail(f"gate: with a wait resource the gate must kubectl wait on it\n{result.stderr}{calls}")
result, calls = run_gate({"WAIT_RESOURCE": "daemonset/nvidia-dcgm", "WAIT_NAMESPACE": "gpu-operator",
                          "WAIT_CONDITION": "rollout"}, "2")
if result.returncode != 0 or "-n gpu-operator rollout status daemonset/nvidia-dcgm" not in calls:
    fail(f"gate: waitCondition rollout must run kubectl rollout status\n{result.stderr}{calls}")
result, _ = run_gate({"WAIT_RESOURCE": "", "CAPACITY_MIN": "0", "CONTRACT_NAME": ""}, "0")
if result.returncode == 0:
    fail("gate: a gate with nothing to do must refuse to run")

# ---------------------------------------------------------------------------------------------
# Placement in the rendered upstream charts (RENDER_CHARTS=1 only)
# ---------------------------------------------------------------------------------------------
WORKLOADS = ("Deployment", "DaemonSet", "StatefulSet", "Job")


def pod_spec(obj):
    return obj["spec"]["template"]["spec"]


def tolerates_gpu(spec):
    return any(t.get("key") == "nvidia.com/gpu" and t.get("effect", "NoSchedule") == "NoSchedule"
               for t in spec.get("tolerations") or [])


for (scenario, task_name), objects in rendered_charts.items():
    values = typed_defaults(scenarios[scenario])
    cpu = values["cpuNodeSelector"].split("=", 1) if values["cpuNodeSelector"] else None
    gpu = values["gpuNodeSelector"].split("=", 1) if values["gpuNodeSelector"] else None
    for obj in (o for o in objects if o.get("kind") in WORKLOADS):
        spec, label = pod_spec(obj), f"{scenario}: {task_name} {obj['kind']}/{obj['metadata']['name']}"
        selector = spec.get("nodeSelector") or {}
        agent = obj["kind"] == "DaemonSet"
        if agent:
            if not tolerates_gpu(spec):
                fail(f"{label}: node agent does not tolerate the nvidia.com/gpu taint")
            if task_name == "nvsentinel":
                key, value = gpu or ("nvidia.com/gpu.present", "true")
                terms = (spec.get("affinity") or {}).get("nodeAffinity", {}).get(
                    "requiredDuringSchedulingIgnoredDuringExecution", {}).get("nodeSelectorTerms", [])
                in_affinity = any(e.get("key") == key and value in e.get("values", [])
                                  for term in terms for e in term.get("matchExpressions", []))
                if selector.get(key) != value and not in_affinity:
                    fail(f"{label}: not placed on {key}={value}")
            if task_name == "gpu-operator" and gpu and selector.get(gpu[0]) != gpu[1]:
                fail(f"{label}: NFD worker not placed on {gpu[0]}={gpu[1]}")
        elif cpu and obj["kind"] != "Job" and selector.get(cpu[0]) != cpu[1]:
            fail(f"{label}: controller not placed on {cpu[0]}={cpu[1]}")

if failures:
    for message in failures:
        print(f"FAIL {message}", file=sys.stderr)
    sys.exit(1)
checked = sum(1 for objs in rendered_charts.values() for o in objs if o.get("kind") in WORKLOADS)
print(f"ok: {len(tasks)} tasks, {len(apps)} Apps, {len(scenarios)} parameter sets"
      + (f", {checked} upstream workloads placed" if render_charts else ""))
PY
