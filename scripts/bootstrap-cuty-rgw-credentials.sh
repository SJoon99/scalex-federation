#!/usr/bin/env bash
set -euo pipefail

: "${B_KUBECONFIG:?set B_KUBECONFIG to a site-b kubeconfig}"
: "${KARMADA_KUBECONFIG:?set KARMADA_KUBECONFIG to the Tower Karmada kubeconfig}"

SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-csi-rook-ceph}"
SOURCE_SECRET="${SOURCE_SECRET:-scalex-poc-bucket}"
TARGET_NAMESPACE=scalex-cuty-rgw-analysis-web
TARGET_SECRET=scalex-cuty-rgw

if ! kubectl --kubeconfig "$B_KUBECONFIG" -n "$SOURCE_NAMESPACE" \
  get secret "$SOURCE_SECRET" -o json |
  jq -e '
    (.data.AWS_ACCESS_KEY_ID | type) == "string" and
    (.data.AWS_ACCESS_KEY_ID | length) > 0 and
    (.data.AWS_SECRET_ACCESS_KEY | type) == "string" and
    (.data.AWS_SECRET_ACCESS_KEY | length) > 0
  ' >/dev/null; then
  echo "source OBC Secret is not ready: $SOURCE_NAMESPACE/$SOURCE_SECRET" >&2
  exit 1
fi

kubectl --kubeconfig "$KARMADA_KUBECONFIG" get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1 \
  || kubectl --kubeconfig "$KARMADA_KUBECONFIG" create namespace "$TARGET_NAMESPACE" >/dev/null

kubectl --kubeconfig "$B_KUBECONFIG" -n "$SOURCE_NAMESPACE" \
  get secret "$SOURCE_SECRET" -o json |
jq -e \
  --arg namespace "$TARGET_NAMESPACE" \
  --arg name "$TARGET_SECRET" \
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
        "app.kubernetes.io/part-of": "scalex-federation-cuty",
        "scalex.io/release": "rgw-analysis-web",
        "scalex.io/credential-source": "b-obc"
      }
    },
    type: "Opaque",
    data: ({
      "access-key-id": .data.AWS_ACCESS_KEY_ID,
      "secret-access-key": .data.AWS_SECRET_ACCESS_KEY
    } + (if (.data.AWS_SESSION_TOKEN // "") == "" then {} else {
      "session-token": .data.AWS_SESSION_TOKEN
    } end))
  }' |
kubectl --kubeconfig "$KARMADA_KUBECONFIG" apply --server-side \
  --field-manager=scalex-credential-bootstrap -f - >/dev/null

echo "Karmada credential Secret applied: $TARGET_NAMESPACE/$TARGET_SECRET"
