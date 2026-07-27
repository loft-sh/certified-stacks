#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_root="$root/source"
variants=(hard-multitenancy soft-multitenancy)
mode=render

# The hook image the committed artifacts are rendered with. Single source of truth:
# `--image` rewrites exactly this string, so keep it byte-identical to the value in
# source/common/apps/{03-bootstrap,restful-operation}.yaml and the stacktemplates.
default_image="docker.io/bitnami/kubectl@sha256:c62a62db80e777acdee87f76bc6f06a95239ad2ff210bf78f585e39e33da98e2"
image="$default_image"

usage() {
  cat <<EOF
Usage: $0 [--check] [--image REF]

  --check        verify the committed artifacts match a fresh render
  --image REF    render with REF as the hook image instead of the default

The default hook image is:
  $default_image

--image writes in place, so the tree then differs from the committed artifacts by
exactly the image lines. Restore with:
  git checkout -- v2/run-ai/hard-multitenancy v2/run-ai/soft-multitenancy
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) mode=check; shift ;;
    --image)
      [[ $# -ge 2 ]] || { echo "--image needs a value" >&2; exit 2; }
      image="$2"; shift 2 ;;
    --image=*) image="${1#--image=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$image" ]] || { echo "--image value must not be empty" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for variant in "${variants[@]}"; do
  stage="$tmp/$variant"
  mkdir -p "$stage/apps" "$stage/tests"
  cp "$source_root/common/apps/"*.yaml "$stage/apps/"
  # Shared tests cover behaviour both variants get from common/apps.
  cp "$source_root/common/tests/"* "$stage/tests/"
  cp -R "$source_root/$variant/." "$stage/"
done

grep -q 'name: runai-step-02-ingress-nginx' "$tmp/hard-multitenancy/apps/02-ingress-nginx.yaml"
grep -q 'name: ingress-ready' "$tmp/hard-multitenancy/stacktemplate.yaml"
grep -q 'name: ingress-ready' "$tmp/hard-multitenancy/stacktemplate-fake-gpu-operator.yaml"

# AWS variant. It reads the LoadBalancer hostname where the generic templates read the IP, so both
# jsonPaths have to survive a render, and the NLB annotation the registration Jobs depend on must
# stay on the AWS ingress App. There is deliberately no AWS fake-GPU template.
grep -q 'name: runai-step-02-ingress-nginx-aws' "$tmp/hard-multitenancy/apps/02-ingress-nginx-aws.yaml"
grep -qF 'preserve_client_ip.enabled=false' "$tmp/hard-multitenancy/apps/02-ingress-nginx-aws.yaml"
aws_template=stacktemplate-aws.yaml
grep -q 'name: ingress-ready' "$tmp/hard-multitenancy/$aws_template"
grep -q 'runai-step-02-ingress-nginx-aws' "$tmp/hard-multitenancy/$aws_template"
grep -qF 'jsonPath: "{.status.loadBalancer.ingress[0].hostname}"' "$tmp/hard-multitenancy/$aws_template"
if grep -q 'nip.io{{ end }}' "$tmp/hard-multitenancy/$aws_template"; then
  echo "$aws_template derives a nip.io FQDN; the AWS template uses the load balancer hostname" >&2
  exit 1
fi
for f in stacktemplate.yaml stacktemplate-fake-gpu-operator.yaml; do
  grep -qF 'jsonPath: "{.status.loadBalancer.ingress[0].ip}"' "$tmp/hard-multitenancy/$f"
done

# The custom-link CronJob picks the UI link out of the tenant's control-plane Ingress. It once
# accepted only `.nip.io` hosts, which silently skipped every AWS tenant, so keep it host-agnostic.
# Wildcard rules must still be dropped in jq: the validation below it reads `*.` as malformed.
cronjob=$tmp/hard-multitenancy/example/cronjob-runai-custom-link.yaml
if grep -qF 'endswith(".nip.io")' "$cronjob"; then
  echo "$cronjob filters Ingress hosts to .nip.io; AWS tenants would be skipped" >&2
  exit 1
fi
grep -qF 'startswith("*") | not' "$cronjob"

if grep -R -E 'tasks\.ingress|runai-step-02|name: ingress-ready' \
  "$tmp/soft-multitenancy/stacktemplate.yaml" \
  "$tmp/soft-multitenancy/stacktemplate-fake-gpu-operator.yaml" >/dev/null; then
  echo "Soft manifests contain hard-ingress references" >&2
  exit 1
fi

grep -q 'variable: hostIngressAddress' "$tmp/soft-multitenancy/stacktemplate.yaml"
grep -q 'ingressNginx:' "$tmp/soft-multitenancy/example/vcluster-template-with-runai-stack.yaml"

# Substituting the hook image must never silently no-op: if the default string in this
# script drifts from the manifests, a --image render would ship the wrong image.
image_targets=()
for variant in "${variants[@]}"; do
  while IFS= read -r f; do image_targets+=("$f"); done \
    < <(find "$tmp/$variant" -maxdepth 2 \( -name '*.yaml' -o -name '*.yml' \) -print)
done

occurrences=$(grep -Fl -- "$default_image" "${image_targets[@]}" | wc -l | tr -d ' ')
if [[ "$occurrences" -eq 0 ]]; then
  echo "No file references the default hook image '$default_image'." >&2
  echo "Update default_image in $0 to match the manifests." >&2
  exit 1
fi

if [[ "$image" != "$default_image" ]]; then
  for f in "${image_targets[@]}"; do
    grep -Fq -- "$default_image" "$f" || continue
    # Python rather than sed: the digest ref contains '/' and ':', and REF is untrusted.
    IMAGE_OLD="$default_image" IMAGE_NEW="$image" python3 - "$f" <<'PY'
import os, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace(os.environ["IMAGE_OLD"], os.environ["IMAGE_NEW"]))
PY
  done
  # Only the manifests are rewritten. The READMEs keep documenting the committed default
  # and how to override it, so they are deliberately excluded from this check.
  if grep -l -F -- "$default_image" "${image_targets[@]}" >/dev/null 2>&1; then
    echo "Hook image substitution was incomplete; some manifests still reference the default." >&2
    exit 1
  fi
fi

if [[ "$mode" == check ]]; then
  status=0
  for variant in "${variants[@]}"; do
    if ! diff -ruN "$root/$variant" "$tmp/$variant"; then
      status=1
    fi
  done
  if [[ "$status" -ne 0 ]]; then
    echo "Generated manifests are stale. Run: ./v2/run-ai/render.sh" >&2
    exit "$status"
  fi
  echo "Generated manifests are current."
  exit 0
fi

for variant in "${variants[@]}"; do
  rm -rf "$root/$variant"
  cp -R "$tmp/$variant" "$root/$variant"
done

echo "Rendered ${variants[*]}."
if [[ "$image" != "$default_image" ]]; then
  cat >&2 <<EOF

Rendered with hook image: $image
The tree now differs from the committed artifacts by the image lines only, so
'$0 --check' will report stale until you re-run a plain '$0'.
Restore with:
  git checkout -- v2/run-ai/hard-multitenancy v2/run-ai/soft-multitenancy
EOF
fi
