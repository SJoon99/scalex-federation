#!/usr/bin/env bash
set -euo pipefail

: "${B_KUBECONFIG:?set B_KUBECONFIG to a site-b kubeconfig}"
: "${KARMADA_KUBECONFIG:?set KARMADA_KUBECONFIG to the Tower Karmada kubeconfig}"

BINDING_NAMESPACE="${BINDING_NAMESPACE:-scalex-rgw-analysis-web}"
BINDING_NAME="${BINDING_NAME:-rgw-analysis-web-storage-binding}"
SOURCE_WAIT_SECONDS="${SOURCE_WAIT_SECONDS:-600}"
SOURCE_POLL_INTERVAL_SECONDS="${SOURCE_POLL_INTERVAL_SECONDS:-5}"

[[ "$SOURCE_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "SOURCE_WAIT_SECONDS must be a positive integer" >&2
  exit 1
}
[[ "$SOURCE_POLL_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "SOURCE_POLL_INTERVAL_SECONDS must be a positive integer" >&2
  exit 1
}

tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
binding_json="$tmp/binding.json"
source_secret_json="$tmp/source-secret.json"
source_config_json="$tmp/source-config.json"
source_error="$tmp/source-error"

if ! kubectl --kubeconfig "$KARMADA_KUBECONFIG" -n "$BINDING_NAMESPACE" \
  get configmap "$BINDING_NAME" -o json >"$binding_json" 2>"$source_error"; then
  cat "$source_error" >&2
  exit 1
fi
jq empty "$binding_json" >/dev/null || {
  echo "storage binding ConfigMap returned invalid JSON" >&2
  exit 1
}

read_binding() {
  jq -er --arg key "$1" '.data[$key] | select(type == "string" and length > 0)' \
    "$binding_json"
}

source_cluster="$(read_binding sourceCluster)"
source_namespace="$(read_binding sourceNamespace)"
source_claim_name="$(read_binding sourceClaimName)"
source_secret_name="$(read_binding sourceSecretName)"
source_config_name="$(read_binding sourceConfigMapName)"
target_namespace="$(read_binding targetNamespace)"
target_secret_name="$(read_binding targetSecretName)"
target_config_name="$(read_binding targetConfigMapName)"
endpoint_url="$(read_binding endpointUrl)"
region="$(read_binding region)"

[ "$source_cluster" = b ] || {
  echo "this POC binding script only supports sourceCluster=b" >&2
  exit 1
}

is_dns_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]
}

for value in "$source_cluster" "$source_namespace" "$source_claim_name" \
  "$source_secret_name" "$source_config_name" "$target_namespace" \
  "$target_secret_name" "$target_config_name"; do
  is_dns_name "$value" || {
    echo "storage binding contains an invalid Kubernetes name" >&2
    exit 1
  }
done
[[ "$endpoint_url" =~ ^https?://[^[:space:]]+$ ]] || {
  echo "storage binding endpointUrl must be an HTTP(S) URL" >&2
  exit 1
}

deadline=$((SECONDS + SOURCE_WAIT_SECONDS))
source_ready=false
while (( SECONDS < deadline )); do
  secret_ready=false
  config_ready=false

  if kubectl --kubeconfig "$B_KUBECONFIG" -n "$source_namespace" \
    get secret "$source_secret_name" -o json >"$source_secret_json" 2>"$source_error"; then
    jq -e '
      (.data.AWS_ACCESS_KEY_ID | type) == "string" and
      (.data.AWS_ACCESS_KEY_ID | length) > 0 and
      (.data.AWS_SECRET_ACCESS_KEY | type) == "string" and
      (.data.AWS_SECRET_ACCESS_KEY | length) > 0
    ' "$source_secret_json" >/dev/null && secret_ready=true
  elif ! grep -Eqi '(notfound|not found)' "$source_error"; then
    cat "$source_error" >&2
    exit 1
  fi

  if kubectl --kubeconfig "$B_KUBECONFIG" -n "$source_namespace" \
    get configmap "$source_config_name" -o json >"$source_config_json" 2>"$source_error"; then
    jq -e '(.data.BUCKET_NAME | type) == "string" and (.data.BUCKET_NAME | length) > 0' \
      "$source_config_json" >/dev/null && config_ready=true
  elif ! grep -Eqi '(notfound|not found)' "$source_error"; then
    cat "$source_error" >&2
    exit 1
  fi

  if [ "$secret_ready" = true ] && [ "$config_ready" = true ]; then
    source_ready=true
    break
  fi
  sleep "$SOURCE_POLL_INTERVAL_SECONDS"
done

if [ "$source_ready" != true ]; then
  echo "source OBC Secret/ConfigMap is not ready: $source_namespace/$source_claim_name" >&2
  exit 1
fi

if ! kubectl --kubeconfig "$KARMADA_KUBECONFIG" get namespace "$target_namespace" \
  >/dev/null 2>"$source_error"; then
  if grep -Eqi '(notfound|not found)' "$source_error"; then
    kubectl --kubeconfig "$KARMADA_KUBECONFIG" create namespace "$target_namespace" >/dev/null
  else
    cat "$source_error" >&2
    exit 1
  fi
fi

jq -n \
  --slurpfile sourceSecret "$source_secret_json" \
  --slurpfile sourceConfig "$source_config_json" \
  --arg sourceCluster "$source_cluster" \
  --arg sourceNamespace "$source_namespace" \
  --arg sourceClaim "$source_claim_name" \
  --arg targetNamespace "$target_namespace" \
  --arg targetSecret "$target_secret_name" \
  --arg targetConfig "$target_config_name" \
  --arg endpointUrl "$endpoint_url" \
  --arg region "$region" '
  {
    apiVersion: "v1",
    kind: "List",
    items: [
      {
        apiVersion: "v1",
        kind: "Secret",
        metadata: {
          namespace: $targetNamespace,
          name: $targetSecret,
          labels: {
            "app.kubernetes.io/part-of": "scalex-federation-poc",
            "scalex.io/release": "rgw-analysis-web",
            "scalex.io/credential-source-cluster": $sourceCluster,
            "scalex.io/credential-source-namespace": $sourceNamespace,
            "scalex.io/credential-source-name": $sourceClaim
          }
        },
        type: "Opaque",
        data: {
          AWS_ACCESS_KEY_ID: $sourceSecret[0].data.AWS_ACCESS_KEY_ID,
          AWS_SECRET_ACCESS_KEY: $sourceSecret[0].data.AWS_SECRET_ACCESS_KEY
        }
      },
      {
        apiVersion: "v1",
        kind: "ConfigMap",
        metadata: {
          namespace: $targetNamespace,
          name: $targetConfig,
          labels: {
            "app.kubernetes.io/part-of": "scalex-federation-poc",
            "scalex.io/release": "rgw-analysis-web",
            "scalex.io/component": "runtime",
            "scalex.io/storage-source-cluster": $sourceCluster,
            "scalex.io/storage-source-name": $sourceClaim
          }
        },
        data: {
          S3_ENDPOINT_URL: $endpointUrl,
          S3_BUCKET: $sourceConfig[0].data.BUCKET_NAME,
          AWS_DEFAULT_REGION: $region
        }
      }
    ]
  }' | kubectl --kubeconfig "$KARMADA_KUBECONFIG" apply \
    --server-side \
    --field-manager=scalex-object-storage-binding \
    -f - >/dev/null

echo "Karmada object storage binding applied: $target_namespace/$target_secret_name, $target_namespace/$target_config_name"
