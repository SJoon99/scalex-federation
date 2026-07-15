#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/scripts/sync-object-storage-binding.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
case "$args" in
  *'get configmap rgw-analysis-web-storage-binding -o json'*)
    source_cluster="${MOCK_SOURCE_CLUSTER:-b}"
    jq -cn --arg sourceCluster "$source_cluster" '{data:{sourceCluster:$sourceCluster,sourceNamespace:"scalex-rgw-analysis-web",sourceClaimName:"rgw-analysis-web-bucket",sourceSecretName:"rgw-analysis-web-bucket",sourceConfigMapName:"rgw-analysis-web-bucket",targetNamespace:"scalex-rgw-analysis-web",targetSecretName:"rgw-analysis-web-s3",targetConfigMapName:"rgw-analysis-web-runtime",endpointUrl:"http://10.33.142.10",region:"scalex-poc"}}'
    ;;
  *'get secret rgw-analysis-web-bucket -o json'*)
    if [ "${MOCK_SOURCE_FORBIDDEN:-false}" = true ]; then
      echo 'Error from server (Forbidden): secrets is forbidden' >&2
      exit 1
    fi
    printf '%s' '{"data":{"AWS_ACCESS_KEY_ID":"QUtJQS1URVNU","AWS_SECRET_ACCESS_KEY":"U0VDUkVULVRFU1Q="}}'
    ;;
  *'get configmap rgw-analysis-web-bucket -o json'*)
    if [ "${MOCK_SOURCE_CONFIG_INVALID:-false}" = true ]; then
      printf '%s' '{"data":{"BUCKET_HOST":"rook-ceph-rgw"}}'
    else
      printf '%s' '{"data":{"BUCKET_HOST":"rook-ceph-rgw","BUCKET_NAME":"poc-rgw-analysis-web-generated","BUCKET_PORT":"80","BUCKET_REGION":"us-east-1"}}'
    fi
    ;;
  *'get namespace scalex-rgw-analysis-web'*)
    exit 0
    ;;
  *'apply --server-side --field-manager=scalex-object-storage-binding -f -'*)
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
export MOCK_KUBECTL_APPLY="$tmp/binding.json"

PATH="$tmp/bin:$PATH" \
B_KUBECONFIG="$tmp/b.kubeconfig" \
KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
SOURCE_WAIT_SECONDS=1 \
SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$BRIDGE" >/dev/null

jq -e '
  .apiVersion == "v1" and .kind == "List" and
  (.items | length) == 2 and
  (.items[0].kind == "Secret") and
  (.items[0].metadata.namespace == "scalex-rgw-analysis-web") and
  (.items[0].metadata.name == "rgw-analysis-web-s3") and
  (.items[0].metadata.labels."scalex.io/credential-source-cluster" == "b") and
  (.items[0].metadata.labels."scalex.io/credential-source-name" == "rgw-analysis-web-bucket") and
  (.items[0].data.AWS_ACCESS_KEY_ID == "QUtJQS1URVNU") and
  (.items[0].data.AWS_SECRET_ACCESS_KEY == "U0VDUkVULVRFU1Q=") and
  (.items[1].kind == "ConfigMap") and
  (.items[1].metadata.namespace == "scalex-rgw-analysis-web") and
  (.items[1].metadata.name == "rgw-analysis-web-runtime") and
  (.items[1].data.S3_ENDPOINT_URL == "http://10.33.142.10") and
  (.items[1].data.S3_BUCKET == "poc-rgw-analysis-web-generated") and
  (.items[1].data.AWS_DEFAULT_REGION == "scalex-poc")
' "$MOCK_KUBECTL_APPLY" >/dev/null

grep -F -- '--server-side --field-manager=scalex-object-storage-binding' \
  "$MOCK_KUBECTL_ARGS" >/dev/null

if grep -nE -- '--arg (access|secret)|jsonpath=.*AWS_' "$BRIDGE" >/dev/null; then
  echo "storage binding must not expose secret data through process arguments" >&2
  exit 1
fi

if PATH="$tmp/bin:$PATH" \
  MOCK_SOURCE_FORBIDDEN=true \
  B_KUBECONFIG="$tmp/b.kubeconfig" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  SOURCE_WAIT_SECONDS=10 \
  SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$BRIDGE" >"$tmp/forbidden.out" 2>"$tmp/forbidden.err"; then
  echo "storage binding must fail on source authorization errors" >&2
  exit 1
fi
grep -F 'Forbidden' "$tmp/forbidden.err" >/dev/null

if PATH="$tmp/bin:$PATH" \
  MOCK_SOURCE_CONFIG_INVALID=true \
  B_KUBECONFIG="$tmp/b.kubeconfig" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  SOURCE_WAIT_SECONDS=1 \
  SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$BRIDGE" >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo "storage binding accepted a source ConfigMap without BUCKET_NAME" >&2
  exit 1
fi
grep -F 'source OBC Secret/ConfigMap is not ready' "$tmp/invalid.err" >/dev/null

if PATH="$tmp/bin:$PATH" \
  MOCK_SOURCE_CLUSTER=c \
  B_KUBECONFIG="$tmp/b.kubeconfig" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  SOURCE_WAIT_SECONDS=1 \
  SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$BRIDGE" >"$tmp/source-cluster.out" 2>"$tmp/source-cluster.err"; then
  echo "storage binding accepted a source cluster that does not match B_KUBECONFIG" >&2
  exit 1
fi
grep -F 'only supports sourceCluster=b' "$tmp/source-cluster.err" >/dev/null

echo "storage binding test passed"
