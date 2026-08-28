#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_root="$root/source"
variants=(dedicated-control-plane central-control-plane)
mode=render

case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  -h|--help)
    echo "Usage: $0 [--check]"
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    exit 2
    ;;
esac

# Variant markers. A block bounded by `# +dedicated:begin` / `# +dedicated:end` survives only in the
# dedicated render, `# +central:begin` / `# +central:end` only in the central render, and marker lines
# are always
# dropped. This keeps one source file for a manifest that differs in a handful of lines, instead of
# forking it and having two copies drift apart. Only *.yaml is processed; a marker anywhere else is
# caught by the unprocessed-marker guard below rather than silently ignored.
apply_variant_markers() {
  local keep="$1" dir="$2" file
  while IFS= read -r -d '' file; do
    awk -v keep="$keep" '
      /^[[:space:]]*#[[:space:]]*\+(dedicated|central):(begin|end)[[:space:]]*$/ {
        marker = $0
        sub(/^[[:space:]]*#[[:space:]]*\+/, "", marker)
        sub(/[[:space:]]*$/, "", marker)
        split(marker, part, ":")
        if (part[2] == "begin") {
          if (depth) { print FILENAME ": nested variant marker" > "/dev/stderr"; aborted = 1; exit 2 }
          depth = 1; current = part[1]
        } else {
          if (!depth) { print FILENAME ": unmatched variant end marker" > "/dev/stderr"; aborted = 1; exit 2 }
          depth = 0; current = ""
        }
        next
      }
      depth && current != keep { next }
      { print }
      END { if (depth && !aborted) { print FILENAME ": unterminated variant block" > "/dev/stderr"; exit 2 } }
    ' "$file" > "$file.rendered" || exit 1
    mv "$file.rendered" "$file"
  done < <(find "$dir" -name '*.yaml' -type f -print0)
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

for variant in "${variants[@]}"; do
  target="$stage/$variant"
  mkdir -p "$target/apps" "$target/tests"
  cp "$source_root/common/apps/"*.yaml "$target/apps/"
  cp "$source_root/common/tests/"* "$target/tests/"
  cp -R "$source_root/$variant/." "$target/"
  apply_variant_markers "${variant%%-*}" "$target"
done

# A malformed marker is inert to the filter above, which would silently ship one variant's lines
# into the other. Fail instead.
for variant in "${variants[@]}"; do
  if grep -rn -E '\+(dedicated|central):(begin|end)' "$stage/$variant" >/dev/null; then
    echo "Unprocessed variant markers in $variant:" >&2
    grep -rn -E '\+(dedicated|central):(begin|end)' "$stage/$variant" >&2
    exit 1
  fi
done

dedicated="$stage/dedicated-control-plane"
central="$stage/central-control-plane"

# Apps are Platform-global. Same-name, byte-identical manifests are one resource; different
# central manifests need distinct names and matching template references.
metadata_name() {
  awk '/^  name: / { sub(/^  name: /, ""); print; exit }' "$1"
}

for dedicated_app in "$dedicated"/apps/*.yaml; do
  dedicated_name=$(metadata_name "$dedicated_app")
  for central_app in "$central"/apps/*.yaml; do
    [[ "$(metadata_name "$central_app")" == "$dedicated_name" ]] || continue
    cmp -s "$dedicated_app" "$central_app" && continue

    central_name="$dedicated_name-central-control-plane"
    [[ ${#central_name} -le 63 ]] || {
      echo "Central App name exceeds Kubernetes limit: $central_name" >&2
      exit 1
    }
    for app in "$dedicated"/apps/*.yaml "$central"/apps/*.yaml; do
      [[ "$app" == "$central_app" ]] && continue
      [[ "$(metadata_name "$app")" != "$central_name" ]] || {
        echo "Central App collision target already exists: $central_name" >&2
        exit 1
      }
    done
    python3 - "$central" "$dedicated_name" "$central_name" <<'PY'
from pathlib import Path
import sys

root, old, new = map(Path, sys.argv[1:])
for manifest in root.rglob("*.yaml"):
    manifest.write_text(manifest.read_text().replace(str(old), str(new)))
PY
  done
done

grep -q '^  name: run-ai-dedicated-control-plane$' "$dedicated/stacktemplate.yaml"
grep -A1 '^  annotations:$' "$dedicated/stacktemplate.yaml" | grep -q '^    vcluster.com/certified: "true"$'
grep -q 'variable: ingressProvider' "$dedicated/stacktemplate.yaml"
grep -q 'name: ingress-ready' "$dedicated/stacktemplate.yaml"
grep -qF '{{ if eq .Values.ingressProvider "aws" }}' "$dedicated/apps/02-ingress-nginx.yaml"
test ! -e "$dedicated/stacktemplate-aws.yaml"
test ! -e "$dedicated/apps/02-ingress-nginx-aws.yaml"

grep -q '^  name: run-ai-central-control-plane$' "$central/stacktemplate.yaml"
grep -A1 '^  annotations:$' "$central/stacktemplate.yaml" | grep -q '^    vcluster.com/certified: "true"$'
grep -q 'awaitSecrets: "runai-tenant-facts,runai-reg-creds-host' "$central/stacktemplate.yaml"

# Central renders three StackTemplates: shared host foundation, per-tenant registration, tenant runtime.
grep -q '^  name: run-ai-central-control-plane-host$' "$central/stacktemplate-host.yaml"
grep -A1 '^  annotations:$' "$central/stacktemplate-host.yaml" | grep -q '^    vcluster.com/certified: "true"$'
grep -q '^  name: run-ai-central-control-plane-registration$' "$central/stacktemplate-registration.yaml"
grep -A1 '^  annotations:$' "$central/stacktemplate-registration.yaml" | grep -q '^    vcluster.com/certified: "true"$'
test -f "$central/example/stackinstance-host.yaml"
test -f "$central/example/stackinstance-registration.yaml"

# Ingress remains a host prerequisite under central control-plane, in every template.
for st in "$central/stacktemplate.yaml" "$central/stacktemplate-host.yaml" "$central/stacktemplate-registration.yaml"; do
  if grep -E 'tasks\.ingress|runai-step-02-ingress-nginx|name: ingress-ready' "$st" >/dev/null; then
    echo "Central manifest contains dedicated-ingress references: $st" >&2
    exit 1
  fi
done

# Tenant Stack owns neither central control plane nor shared GPU Operator, and never receives
# control-plane administrator credentials.
if grep -E 'runai-step-0(4|6|7)-' "$central/stacktemplate.yaml" >/dev/null; then
  echo "Central tenant StackTemplate installs host components" >&2
  exit 1
fi
if grep -E 'variable: (adminUsername|adminPassword)' "$central/stacktemplate.yaml" >/dev/null; then
  echo "Central tenant StackTemplate takes control-plane admin credentials" >&2
  exit 1
fi
grep -q 'runai-step-06-gpu-operator' "$central/stacktemplate-host.yaml"
grep -q 'runai-step-07-control-plane' "$central/stacktemplate-host.yaml"

if [[ "$mode" == check ]]; then
  status=0
  for variant in "${variants[@]}"; do
    diff -ruN "$root/$variant" "$stage/$variant" || status=1
  done
  [[ "$status" -eq 0 ]] || {
    echo "Generated manifests are stale. Run: ./v2/run-ai/render.sh" >&2
    exit "$status"
  }
  [[ "${RENDER_SKIP_TESTS:-}" == 1 ]] || bash "$root/test-certified-manifests.sh"
  echo "Generated manifests are current."
  exit 0
fi

for variant in "${variants[@]}"; do
  rm -rf "$root/$variant"
  cp -R "$stage/$variant" "$root/$variant"
done

[[ "${RENDER_SKIP_TESTS:-}" == 1 ]] || bash "$root/test-certified-manifests.sh"
echo "Rendered ${variants[*]}."
