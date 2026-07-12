#!/usr/bin/env bash
set -euo pipefail

: "${B_KUBECONFIG:?set B_KUBECONFIG to a site-b kubeconfig}"
: "${KARMADA_KUBECONFIG:?set KARMADA_KUBECONFIG to the Tower Karmada kubeconfig}"

SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-csi-rook-ceph}"
SOURCE_SECRET="${SOURCE_SECRET:-scalex-poc-bucket}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-scalex-rgw-analysis-web}"
TARGET_SECRET="${TARGET_SECRET:-scalex-poc-rgw}"

access_key="$(kubectl --kubeconfig "$B_KUBECONFIG" -n "$SOURCE_NAMESPACE" \
  get secret "$SOURCE_SECRET" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}')"
secret_key="$(kubectl --kubeconfig "$B_KUBECONFIG" -n "$SOURCE_NAMESPACE" \
  get secret "$SOURCE_SECRET" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}')"

if [ -z "$access_key" ] || [ -z "$secret_key" ]; then
  echo "source OBC secret is not ready: $SOURCE_NAMESPACE/$SOURCE_SECRET" >&2
  exit 1
fi

kubectl --kubeconfig "$KARMADA_KUBECONFIG" get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1 \
  || kubectl --kubeconfig "$KARMADA_KUBECONFIG" create namespace "$TARGET_NAMESPACE" >/dev/null

jq -n \
  --arg namespace "$TARGET_NAMESPACE" \
  --arg name "$TARGET_SECRET" \
  --arg access "$access_key" \
  --arg secret "$secret_key" \
  '{
    apiVersion: "v1",
    kind: "Secret",
    metadata: {
      namespace: $namespace,
      name: $name,
      labels: {
        "app.kubernetes.io/part-of": "scalex-federation-poc",
        "scalex.io/release": "rgw-analysis-web",
        "scalex.io/credential-source": "b-obc"
      }
    },
    type: "Opaque",
    data: {
      AWS_ACCESS_KEY_ID: $access,
      AWS_SECRET_ACCESS_KEY: $secret
    }
  }' | kubectl --kubeconfig "$KARMADA_KUBECONFIG" apply -f - >/dev/null

echo "Karmada credential Secret applied: $TARGET_NAMESPACE/$TARGET_SECRET"
