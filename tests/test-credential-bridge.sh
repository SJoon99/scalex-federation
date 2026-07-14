#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
case "$args" in
  *'get secret rgw-analysis-web-bucket -o json'*)
    if [ "${MOCK_SOURCE_FORBIDDEN:-false}" = true ]; then
      echo 'Error from server (Forbidden): secrets is forbidden' >&2
      exit 1
    fi
    printf '%s' '{"data":{"AWS_ACCESS_KEY_ID":"QUtJQS1URVNU","AWS_SECRET_ACCESS_KEY":"U0VDUkVULVRFU1Q="}}'
    ;;
  *'get namespace scalex-rgw-analysis-web'*)
    exit 0
    ;;
  *'apply --server-side --field-manager=scalex-rgw-credential-bridge -f -'*)
    printf '%s\n' "$args" >"$MOCK_KUBECTL_ARGS"
    cat >"$MOCK_KUBECTL_APPLY"
    ;;
  *)
    echo "unexpected kubectl call: $args" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/bin/kubectl"

export MOCK_KUBECTL_ARGS="$tmp/args"
export MOCK_KUBECTL_APPLY="$tmp/secret.json"

PATH="$tmp/bin:$PATH" \
B_KUBECONFIG="$tmp/b.kubeconfig" \
KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
SOURCE_WAIT_SECONDS=1 \
SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$ROOT/scripts/bootstrap-rgw-credentials.sh" >/dev/null

jq -e '
  .kind == "Secret" and
  .metadata.namespace == "scalex-rgw-analysis-web" and
  .metadata.name == "rgw-analysis-web-s3" and
  .metadata.labels."scalex.io/credential-source-namespace" == "scalex-rgw-analysis-web" and
  .metadata.labels."scalex.io/credential-source-name" == "rgw-analysis-web-bucket" and
  .data.AWS_ACCESS_KEY_ID == "QUtJQS1URVNU" and
  .data.AWS_SECRET_ACCESS_KEY == "U0VDUkVULVRFU1Q="
' "$MOCK_KUBECTL_APPLY" >/dev/null

grep -F -- '--server-side --field-manager=scalex-rgw-credential-bridge' \
  "$MOCK_KUBECTL_ARGS" >/dev/null

if rg -n -- '--arg (access|secret)|jsonpath=.*AWS_' \
  "$ROOT/scripts/bootstrap-rgw-credentials.sh" >/dev/null; then
  echo "credential bridge must not expose secret data through process arguments" >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" \
  MOCK_SOURCE_FORBIDDEN=true \
  B_KUBECONFIG="$tmp/b.kubeconfig" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  SOURCE_WAIT_SECONDS=10 \
  SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$ROOT/scripts/bootstrap-rgw-credentials.sh" >"$tmp/forbidden.out" 2>"$tmp/forbidden.err"; then
  echo "credential bridge must fail on source authorization errors" >&2
  exit 1
fi
grep -F 'Forbidden' "$tmp/forbidden.err" >/dev/null

echo "credential bridge test passed"
