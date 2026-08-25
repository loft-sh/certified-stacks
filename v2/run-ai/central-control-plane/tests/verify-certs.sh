#!/usr/bin/env bash
# Verify the TLS material the bootstrap step (apps/04-bootstrap.yaml) published.
#
# Run against a tenant cluster with the Stack installed:
#   ./verify-certs.sh                      # self-signed (default)
#   TLS_MODE=user-provided ./verify-certs.sh
#
# Read the FQDN from the endpoint ConfigMap. It matches the Stack-derived FQDN.
# Set FQDN=... to test a control plane with a different name.
set -uo pipefail

TLS_MODE="${TLS_MODE:-self-signed}"
BACKEND_NS="${BACKEND_NS:-runai-backend}"
CLUSTER_NS="${CLUSTER_NS:-runai}"
# `openssl x509 -checkend` uses seconds. Keep this equal to `RENEW_BEFORE_SECONDS` in the bootstrap App.
RENEW_BEFORE_SECONDS="${RENEW_BEFORE_SECONDS:-2592000}"

failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

for t in kubectl openssl; do
  command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }
done

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# go-template with `index` sidesteps jsonpath's dot-escaping rules for keys like `tls.crt`.
secret_key() { # ns name key outfile
  kubectl -n "$1" get secret "$2" -o go-template="{{ index .data \"$3\" }}" 2>/dev/null \
    | base64 -d > "$4" 2>/dev/null
  [ -s "$4" ]
}

FQDN="${FQDN:-$(kubectl -n "$CLUSTER_NS" get configmap runai-control-plane-endpoint -o jsonpath='{.data.fqdn}' 2>/dev/null)}"
[ -n "$FQDN" ] || { echo "could not determine FQDN; set FQDN=..." >&2; exit 2; }
echo "verifying certificates for $FQDN (tlsMode=$TLS_MODE)"
echo

# --- Secrets exist with the expected shape ------------------------------------------------

check "$BACKEND_NS/runai-backend-tls is a kubernetes.io/tls Secret" \
  "[ \"\$(kubectl -n $BACKEND_NS get secret runai-backend-tls -o jsonpath='{.type}')\" = kubernetes.io/tls ]"

if secret_key "$BACKEND_NS" runai-backend-tls tls.crt "$workdir/tls.crt"; then
  pass "$BACKEND_NS/runai-backend-tls has tls.crt"
else
  fail "$BACKEND_NS/runai-backend-tls has tls.crt"
  echo "cannot continue without the served certificate" >&2
  exit 1
fi
check "$BACKEND_NS/runai-backend-tls has tls.key" \
  "secret_key $BACKEND_NS runai-backend-tls tls.key $workdir/tls.key"

# --- The served leaf ----------------------------------------------------------------------

# `openssl x509` reads the first certificate in the file, which is the leaf.
check "leaf SAN covers $FQDN" \
  "openssl x509 -in $workdir/tls.crt -noout -ext subjectAltName | grep -qF 'DNS:$FQDN'"
check "leaf SAN covers *.$FQDN" \
  "openssl x509 -in $workdir/tls.crt -noout -ext subjectAltName | grep -qF 'DNS:*.$FQDN'"
check "leaf extendedKeyUsage includes serverAuth" \
  "openssl x509 -in $workdir/tls.crt -noout -ext extendedKeyUsage | grep -q 'TLS Web Server Authentication'"
check "leaf keyUsage includes Digital Signature" \
  "openssl x509 -in $workdir/tls.crt -noout -ext keyUsage | grep -q 'Digital Signature'"
check "leaf keyUsage includes Key Encipherment" \
  "openssl x509 -in $workdir/tls.crt -noout -ext keyUsage | grep -q 'Key Encipherment'"
check "leaf is not inside the renewal window" \
  "openssl x509 -in $workdir/tls.crt -noout -checkend $RENEW_BEFORE_SECONDS"
check "leaf public key matches tls.key" \
  "[ \"\$(openssl x509 -in $workdir/tls.crt -noout -pubkey)\" = \"\$(openssl pkey -in $workdir/tls.key -pubout)\" ]"

# --- The published CA ---------------------------------------------------------------------

if [ "$TLS_MODE" = user-provided ] && ! kubectl -n "$BACKEND_NS" get secret runai-ca-cert >/dev/null 2>&1; then
  echo "note: no runai-ca-cert Secret, which is expected for a publicly trusted supplied chain"
else
  for ns in "$BACKEND_NS" "$CLUSTER_NS"; do
    check "$ns/runai-ca-cert has runai-ca.pem" \
      "secret_key $ns runai-ca-cert runai-ca.pem $workdir/$ns-ca.pem"
  done
  if [ -s "$workdir/$BACKEND_NS-ca.pem" ] && [ -s "$workdir/$CLUSTER_NS-ca.pem" ]; then
    check "both namespaces publish the same CA" \
      "cmp -s $workdir/$BACKEND_NS-ca.pem $workdir/$CLUSTER_NS-ca.pem"
  fi
  if [ -s "$workdir/$BACKEND_NS-ca.pem" ]; then
    check "leaf chains to the published CA" \
      "openssl verify -CAfile $workdir/$BACKEND_NS-ca.pem $workdir/tls.crt"
  fi
fi

# --- Self-signed specifics ------------------------------------------------------------------

if [ "$TLS_MODE" = user-provided ]; then
  check "runai-internal-ca is absent in user-provided mode" \
    "! kubectl -n $BACKEND_NS get secret runai-internal-ca"
else
  check "tls.crt carries the leaf and the CA" \
    "[ \"\$(grep -c 'BEGIN CERTIFICATE' $workdir/tls.crt)\" -eq 2 ]"

  if secret_key "$BACKEND_NS" runai-internal-ca ca.crt "$workdir/internal-ca.crt"; then
    pass "$BACKEND_NS/runai-internal-ca has ca.crt"
    check "CA key is 4096-bit" \
      "openssl x509 -in $workdir/internal-ca.crt -noout -text | grep -q 'Public-Key: (4096 bit)'"
    check "CA has basicConstraints CA:TRUE" \
      "openssl x509 -in $workdir/internal-ca.crt -noout -ext basicConstraints | grep -q 'CA:TRUE'"
    check "CA keyUsage includes Certificate Sign" \
      "openssl x509 -in $workdir/internal-ca.crt -noout -ext keyUsage | grep -q 'Certificate Sign'"
    check "stored CA matches the published CA" \
      "cmp -s $workdir/internal-ca.crt $workdir/$BACKEND_NS-ca.pem"
  else
    # Without this Secret, the next upgrade creates a new CA.
    fail "$BACKEND_NS/runai-internal-ca has ca.crt"
  fi
  check "$BACKEND_NS/runai-internal-ca has ca.key" \
    "secret_key $BACKEND_NS runai-internal-ca ca.key $workdir/internal-ca.key"
fi

echo
if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
