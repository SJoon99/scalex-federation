#!/usr/bin/env bash
set -euo pipefail

: "${B_KUBECONFIG:?set B_KUBECONFIG to a site-b kubeconfig}"
: "${KARMADA_KUBECONFIG:?set KARMADA_KUBECONFIG to the Tower Karmada kubeconfig}"

SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-scalex-rgw-analysis-web}"
SOURCE_SECRET="${SOURCE_SECRET:-rgw-analysis-web-bucket}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-scalex-rgw-analysis-web}"
TARGET_SECRET="${TARGET_SECRET:-rgw-analysis-web-s3}"
SOURCE_WAIT_SECONDS="${SOURCE_WAIT_SECONDS:-600}"
SOURCE_POLL_INTERVAL_SECONDS="${SOURCE_POLL_INTERVAL_SECONDS:-5}"

deadline=$((SECONDS + SOURCE_WAIT_SECONDS))
source_ready=false
source_json="$(mktemp)"
source_error="$(mktemp)"
chmod 600 "$source_json" "$source_error"
trap 'rm -f "$source_json" "$source_error"' EXIT
while (( SECONDS < deadline )); do
  if kubectl --kubeconfig "$B_KUBECONFIG" -n "$SOURCE_NAMESPACE" \
    get secret "$SOURCE_SECRET" -o json >"$source_json" 2>"$source_error"; then
    jq empty "$source_json" >/dev/null || {
      echo "source OBC Secret returned invalid JSON" >&2
      exit 1
    }
    if jq -e '
      (.data.AWS_ACCESS_KEY_ID | type) == "string" and
      (.data.AWS_ACCESS_KEY_ID | length) > 0 and
      (.data.AWS_SECRET_ACCESS_KEY | type) == "string" and
      (.data.AWS_SECRET_ACCESS_KEY | length) > 0
    ' "$source_json" >/dev/null; then
      source_ready=true
      break
    fi
  elif ! grep -Eqi '(notfound|not found)' "$source_error"; then
    cat "$source_error" >&2
    exit 1
  fi
  sleep "$SOURCE_POLL_INTERVAL_SECONDS"
done

if [ "$source_ready" != true ]; then
  echo "source OBC secret is not ready: $SOURCE_NAMESPACE/$SOURCE_SECRET" >&2
  exit 1
fi

if ! kubectl --kubeconfig "$KARMADA_KUBECONFIG" get namespace "$TARGET_NAMESPACE" \
  >/dev/null 2>"$source_error"; then
  if grep -Eqi '(notfound|not found)' "$source_error"; then
    kubectl --kubeconfig "$KARMADA_KUBECONFIG" create namespace "$TARGET_NAMESPACE" >/dev/null
  else
    cat "$source_error" >&2
    exit 1
  fi
fi

jq -e \
  --arg namespace "$TARGET_NAMESPACE" \
  --arg name "$TARGET_SECRET" \
  --arg sourceNamespace "$SOURCE_NAMESPACE" \
  --arg sourceName "$SOURCE_SECRET" \
  'select(
    (.data.AWS_ACCESS_KEY_ID | type) == "string" and
    (.data.AWS_ACCESS_KEY_ID | length) > 0 and
    (.data.AWS_SECRET_ACCESS_KEY | type) == "string" and
    (.data.AWS_SECRET_ACCESS_KEY | length) > 0
  ) | {
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      namespace: $namespace,
      name: $name,
      labels: {
        "app.kubernetes.io/part-of": "scalex-federation-poc",
        "scalex.io/release": "rgw-analysis-web",
        "scalex.io/credential-source": "b-obc",
        "scalex.io/credential-source-namespace": $sourceNamespace,
        "scalex.io/credential-source-name": $sourceName
      }
    },
    type: "Opaque",
    data: {
      AWS_ACCESS_KEY_ID: .data.AWS_ACCESS_KEY_ID,
      AWS_SECRET_ACCESS_KEY: .data.AWS_SECRET_ACCESS_KEY
    }
  }' "$source_json" | kubectl --kubeconfig "$KARMADA_KUBECONFIG" apply \
    --server-side \
    --field-manager=scalex-rgw-credential-bridge \
    -f - >/dev/null

echo "Karmada credential Secret applied: $TARGET_NAMESPACE/$TARGET_SECRET"
