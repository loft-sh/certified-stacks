#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

missing=()
for tool in python3 helm; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v python3 >/dev/null && { python3 -c 'import yaml' 2>/dev/null || missing+=("PyYAML (python3 -m pip install pyyaml); needed to verify the manifests parse as YAML"); }
if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot run: missing prerequisite(s)" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Check the template and examples, then write what `helm template` needs to render the default
# chart version: the Stack renders `{{ .Values.* }}` before it installs the chart.
python3 - "$root" "$work" <<'MANIFESTS'
import re
import sys
from pathlib import Path

import yaml

root, work = Path(sys.argv[1]), Path(sys.argv[2])
errors = []

template = yaml.safe_load((root / "stacktemplate.yaml").read_text())
if template.get("kind") != "StackTemplate" or template["metadata"].get("name") != "nvidia-dynamo":
    errors.append("stacktemplate.yaml: expected StackTemplate nvidia-dynamo")
if (template["metadata"].get("annotations") or {}).get("vcluster.com/certified") != "true":
    errors.append('stacktemplate.yaml: missing annotation vcluster.com/certified: "true"')

parameters = {p["variable"]: p for p in template["spec"].get("parameters", [])}


def check_value(where, variable, value):
    validation = parameters[variable].get("validation")
    if validation and not re.fullmatch(validation, str(value)):
        errors.append(f"{where}: {variable}={value!r} does not match {validation!r}")


for variable, parameter in parameters.items():
    if "defaultValue" in parameter:
        check_value("stacktemplate.yaml default", variable, parameter["defaultValue"])

for example in sorted((root / "example").glob("*.yaml")):
    instance = yaml.safe_load(example.read_text())
    where = f"example/{example.name}"
    if instance.get("kind") != "StackInstance" or instance["spec"].get("templateRef", {}).get("name") != "nvidia-dynamo":
        errors.append(f"{where}: expected a StackInstance of nvidia-dynamo")
        continue
    for variable, value in (instance["spec"].get("parameters") or {}).items():
        if variable not in parameters:
            errors.append(f"{where}: parameter {variable!r} is not declared by the template")
            continue
        check_value(where, variable, value)

tasks = template["spec"]["tasks"]
if [task["name"] for task in tasks] != ["runtime"]:
    errors.append("stacktemplate.yaml: expected exactly one task named runtime")
else:
    values = {variable: parameter.get("defaultValue", "") for variable, parameter in parameters.items()}

    def render(text):
        return re.sub(r"{{\s*\.Values\.(\w+)\s*}}", lambda match: str(values[match.group(1)]), text)

    spec = tasks[0]["app"]["template"]["spec"]
    chart = spec["config"]["chart"]
    (work / "chart").write_text(
        "\n".join([chart["name"], chart["repoURL"], render(chart["version"]), render(spec["defaultNamespace"])]) + "\n"
    )
    (work / "values.yaml").write_text(render(spec["config"].get("values", "")))

if errors:
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    sys.exit(1)
MANIFESTS
echo "ok manifests"

{ read -r chart; read -r repo; read -r version; read -r namespace; } < "$work/chart"
if ! helm template nvidia-dynamo-runtime "$chart" \
  --repo "$repo" \
  --version "$version" \
  --namespace "$namespace" \
  --values "$work/values.yaml" \
  --kube-version 1.33.0 > "$work/rendered.yaml"; then
  echo "FAIL $chart $version from $repo does not render with the template values" >&2
  exit 1
fi
# The task installs the operator plus the bundled NATS and etcd; each must render.
for workload in dynamo-operator-controller-manager nats etcd; do
  grep -qx "  name: nvidia-dynamo-runtime-$workload" "$work/rendered.yaml" || {
    echo "FAIL $chart $version rendered no nvidia-dynamo-runtime-$workload object" >&2
    exit 1
  }
done
echo "ok chart $chart $version renders"
