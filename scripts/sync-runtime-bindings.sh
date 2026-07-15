#!/usr/bin/env bash
set -euo pipefail

: "${KARMADA_KUBECONFIG:?set KARMADA_KUBECONFIG to the Tower Karmada kubeconfig}"
: "${MEMBER_KUBECONFIG_DIR:?set MEMBER_KUBECONFIG_DIR to the secure member kubeconfig directory}"

KUBECTL="${KUBECTL:-kubectl}"
SOURCE_WAIT_SECONDS="${SOURCE_WAIT_SECONDS:-600}"
SOURCE_POLL_INTERVAL_SECONDS="${SOURCE_POLL_INTERVAL_SECONDS:-5}"
# Compatibility identity for objects created by the retired storage-only runner.
# Renaming it would leave the old manager owning credential fields and break rotation.
OBJECT_STORAGE_FIELD_MANAGER="scalex-object-storage-binding"
mode=""
binding_ref=""

usage() {
  cat >&2 <<'USAGE'
Usage:
  sync-runtime-bindings.sh --all
  sync-runtime-bindings.sh --binding <namespace>/<name>
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$mode" ] || { usage; exit 2; }
      mode=all
      shift
      ;;
    --binding)
      [ -z "$mode" ] && [ "$#" -ge 2 ] || { usage; exit 2; }
      mode=one
      binding_ref="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$mode" ] || { usage; exit 2; }
[[ "$SOURCE_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "SOURCE_WAIT_SECONDS must be a positive integer" >&2
  exit 1
}
[[ "$SOURCE_POLL_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "SOURCE_POLL_INTERVAL_SECONDS must be a positive integer" >&2
  exit 1
}
[ -d "$MEMBER_KUBECONFIG_DIR" ] || {
  echo "member kubeconfig directory does not exist: $MEMBER_KUBECONFIG_DIR" >&2
  exit 1
}
for tool in "$KUBECTL" jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "required runtime binding tool is unavailable: $tool" >&2
    exit 1
  }
done

is_dns_name() {
  [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && [ "${#1}" -le 63 ]
}

is_label_value() {
  [[ "$1" =~ ^[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] && [ "${#1}" -le 63 ]
}

tmp="$(mktemp -d)"
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
bindings_json="$tmp/bindings.json"
kubectl_error="$tmp/kubectl.err"

if [ "$mode" = all ]; then
  "$KUBECTL" --kubeconfig "$KARMADA_KUBECONFIG" \
    get configmaps -A -l scalex.io/runtime-binding=true -o json \
    >"$bindings_json" 2>"$kubectl_error" || {
      cat "$kubectl_error" >&2
      exit 1
    }
else
  binding_namespace="${binding_ref%%/*}"
  binding_name="${binding_ref#*/}"
  if [ "$binding_namespace" = "$binding_ref" ] || ! is_dns_name "$binding_namespace" || ! is_dns_name "$binding_name"; then
    echo "--binding must be a valid <namespace>/<name> reference" >&2
    exit 1
  fi
  "$KUBECTL" --kubeconfig "$KARMADA_KUBECONFIG" -n "$binding_namespace" \
    get configmaps -l scalex.io/runtime-binding=true -o json \
    >"$bindings_json" 2>"$kubectl_error" || {
      cat "$kubectl_error" >&2
      exit 1
    }
fi

jq -e '
  .apiVersion == "v1" and
  (.kind == "List" or .kind == "ConfigMapList") and
  (.items | type) == "array" and
  all(.items[];
    .apiVersion == "v1" and
    .kind == "ConfigMap" and
    .metadata.labels["scalex.io/runtime-binding"] == "true")
' "$bindings_json" >/dev/null || {
  echo "Karmada returned an invalid runtime binding list" >&2
  exit 1
}
jq -e '
  ([.items[] | [.data.targetNamespace, .data.targetSecretName]] |
    sort | group_by(.) | all(length == 1)) and
  ([.items[] | [.data.targetNamespace, .data.targetConfigMapName]] |
    sort | group_by(.) | all(length == 1))
' "$bindings_json" >/dev/null || {
  echo "runtime bindings contain a duplicate target identity" >&2
  exit 1
}

if [ "$mode" = one ]; then
  selected_bindings="$tmp/selected-bindings.json"
  jq --arg namespace "$binding_namespace" --arg name "$binding_name" '
    .items = [.items[] |
      select(.metadata.namespace == $namespace and .metadata.name == $name)]
  ' "$bindings_json" >"$selected_bindings"
  [ "$(jq '.items | length' "$selected_bindings")" -eq 1 ] || {
    echo "runtime binding not found: $binding_ref" >&2
    exit 1
  }
  mv "$selected_bindings" "$bindings_json"
fi

binding_count="$(jq '.items | length' "$bindings_json")"
if [ "$binding_count" -eq 0 ]; then
  echo "no runtime bindings found"
  exit 0
fi

process_binding() {
  local binding_file="$1"
  local binding_name binding_namespace binding_uid release part_of label_type
  local contract_version binding_type source_cluster source_namespace source_claim_name
  local source_secret_name source_config_name target_namespace target_secret_name target_config_name
  local endpoint_url region member_kubeconfig deadline source_ready
  local claim_ready secret_ready config_ready source_claim_json source_secret_json source_config_json

  jq -e '
    (.metadata.name | type) == "string" and (.metadata.name | length) > 0 and
    (.metadata.namespace | type) == "string" and (.metadata.namespace | length) > 0 and
    (.metadata.uid | type) == "string" and (.metadata.uid | length) > 0 and
    (.metadata.labels["app.kubernetes.io/part-of"] | type) == "string" and
    (.metadata.labels["scalex.io/release"] | type) == "string" and
    .metadata.labels["scalex.io/component"] == "runtime-binding" and
    .metadata.labels["scalex.io/runtime-binding"] == "true" and
    (.metadata.labels["scalex.io/binding-type"] | type) == "string" and
    (.data | keys | sort) == [
      "bindingType",
      "contractVersion",
      "endpointUrl",
      "region",
      "sourceClaimName",
      "sourceCluster",
      "sourceConfigMapName",
      "sourceNamespace",
      "sourceSecretName",
      "targetConfigMapName",
      "targetNamespace",
      "targetSecretName"
    ]
  ' "$binding_file" >/dev/null || {
    echo "runtime binding metadata or data contract is invalid" >&2
    return 1
  }

  binding_name="$(jq -r '.metadata.name' "$binding_file")"
  binding_namespace="$(jq -r '.metadata.namespace' "$binding_file")"
  binding_uid="$(jq -r '.metadata.uid' "$binding_file")"
  release="$(jq -r '.metadata.labels["scalex.io/release"]' "$binding_file")"
  part_of="$(jq -r '.metadata.labels["app.kubernetes.io/part-of"]' "$binding_file")"
  label_type="$(jq -r '.metadata.labels["scalex.io/binding-type"]' "$binding_file")"
  contract_version="$(jq -r '.data.contractVersion' "$binding_file")"
  binding_type="$(jq -r '.data.bindingType' "$binding_file")"
  source_cluster="$(jq -r '.data.sourceCluster' "$binding_file")"
  source_namespace="$(jq -r '.data.sourceNamespace' "$binding_file")"
  source_claim_name="$(jq -r '.data.sourceClaimName' "$binding_file")"
  source_secret_name="$(jq -r '.data.sourceSecretName' "$binding_file")"
  source_config_name="$(jq -r '.data.sourceConfigMapName' "$binding_file")"
  target_namespace="$(jq -r '.data.targetNamespace' "$binding_file")"
  target_secret_name="$(jq -r '.data.targetSecretName' "$binding_file")"
  target_config_name="$(jq -r '.data.targetConfigMapName' "$binding_file")"
  endpoint_url="$(jq -r '.data.endpointUrl' "$binding_file")"
  region="$(jq -r '.data.region' "$binding_file")"

  if [ "$contract_version" != v1alpha1 ] || [ "$binding_type" != rook-obc-s3 ] || \
    [ "$label_type" != "$binding_type" ]; then
    echo "unsupported runtime binding contract: $contract_version/$binding_type" >&2
    return 1
  fi
  for value in "$binding_name" "$binding_namespace" "$source_cluster" "$source_namespace" \
    "$source_claim_name" "$source_secret_name" "$source_config_name" "$target_namespace" \
    "$target_secret_name" "$target_config_name"; do
    is_dns_name "$value" || {
      echo "runtime binding contains an invalid Kubernetes name" >&2
      return 1
    }
  done
  is_label_value "$release" && is_label_value "$part_of" || {
    echo "runtime binding contains an invalid ownership label" >&2
    return 1
  }
  if [ "$source_namespace" != "$binding_namespace" ] || [ "$target_namespace" != "$binding_namespace" ]; then
    echo "source and target namespaces must match the binding namespace" >&2
    return 1
  fi
  if [ "$source_claim_name" != "$source_secret_name" ] || [ "$source_claim_name" != "$source_config_name" ]; then
    echo "rook-obc-s3 source Secret and ConfigMap must match the OBC name" >&2
    return 1
  fi
  if [ "$target_config_name" = "$binding_name" ]; then
    echo "target ConfigMap cannot overwrite the binding declaration" >&2
    return 1
  fi
  [[ "$endpoint_url" =~ ^https?://[^[:space:]]+$ ]] || {
    echo "runtime binding endpointUrl must be an HTTP(S) URL" >&2
    return 1
  }
  [[ "$region" =~ ^[-._A-Za-z0-9]+$ ]] || {
    echo "runtime binding region is invalid" >&2
    return 1
  }

  member_kubeconfig="$MEMBER_KUBECONFIG_DIR/$source_cluster.kubeconfig"
  [ -f "$member_kubeconfig" ] && [ -r "$member_kubeconfig" ] || {
    echo "member kubeconfig is unavailable for source cluster: $source_cluster" >&2
    return 1
  }

  source_claim_json="$tmp/$binding_namespace-$binding_name-source-claim.json"
  source_secret_json="$tmp/$binding_namespace-$binding_name-source-secret.json"
  source_config_json="$tmp/$binding_namespace-$binding_name-source-config.json"
  deadline=$((SECONDS + SOURCE_WAIT_SECONDS))
  source_ready=false

  while (( SECONDS < deadline )); do
    claim_ready=false
    secret_ready=false
    config_ready=false

    if "$KUBECTL" --kubeconfig "$member_kubeconfig" -n "$source_namespace" \
      get objectbucketclaim "$source_claim_name" -o json >"$source_claim_json" 2>"$kubectl_error"; then
      jq -e \
        --arg name "$source_claim_name" \
        --arg namespace "$source_namespace" '
          .apiVersion == "objectbucket.io/v1alpha1" and
          .kind == "ObjectBucketClaim" and
          .metadata.name == $name and
          .metadata.namespace == $namespace and
          .status.phase == "Bound"
        ' "$source_claim_json" >/dev/null && claim_ready=true
    elif ! grep -Eqi '(notfound|not found)' "$kubectl_error"; then
      cat "$kubectl_error" >&2
      return 1
    fi

    if "$KUBECTL" --kubeconfig "$member_kubeconfig" -n "$source_namespace" \
      get secret "$source_secret_name" -o json >"$source_secret_json" 2>"$kubectl_error"; then
      jq -e '
        (.data.AWS_ACCESS_KEY_ID | type) == "string" and
        (.data.AWS_ACCESS_KEY_ID | length) > 0 and
        (.data.AWS_SECRET_ACCESS_KEY | type) == "string" and
        (.data.AWS_SECRET_ACCESS_KEY | length) > 0
      ' "$source_secret_json" >/dev/null && secret_ready=true
    elif ! grep -Eqi '(notfound|not found)' "$kubectl_error"; then
      cat "$kubectl_error" >&2
      return 1
    fi

    if "$KUBECTL" --kubeconfig "$member_kubeconfig" -n "$source_namespace" \
      get configmap "$source_config_name" -o json >"$source_config_json" 2>"$kubectl_error"; then
      jq -e '(.data.BUCKET_NAME | type) == "string" and (.data.BUCKET_NAME | length) > 0' \
        "$source_config_json" >/dev/null && config_ready=true
    elif ! grep -Eqi '(notfound|not found)' "$kubectl_error"; then
      cat "$kubectl_error" >&2
      return 1
    fi

    if [ "$claim_ready" = true ] && [ "$secret_ready" = true ] && [ "$config_ready" = true ]; then
      source_ready=true
      break
    fi
    sleep "$SOURCE_POLL_INTERVAL_SECONDS"
  done

  if [ "$source_ready" != true ]; then
    echo "source rook-obc-s3 output is not ready: $source_cluster/$source_namespace/$source_claim_name" >&2
    return 1
  fi

  jq -n \
    --slurpfile sourceSecret "$source_secret_json" \
    --slurpfile sourceConfig "$source_config_json" \
    --arg bindingName "$binding_name" \
    --arg bindingUid "$binding_uid" \
    --arg sourceCluster "$source_cluster" \
    --arg sourceNamespace "$source_namespace" \
    --arg sourceClaim "$source_claim_name" \
    --arg targetNamespace "$target_namespace" \
    --arg targetSecret "$target_secret_name" \
    --arg targetConfig "$target_config_name" \
    --arg endpointUrl "$endpoint_url" \
    --arg region "$region" \
    --arg release "$release" \
    --arg partOf "$part_of" '
      def owner: [{
        apiVersion: "v1",
        kind: "ConfigMap",
        name: $bindingName,
        uid: $bindingUid,
        controller: false,
        blockOwnerDeletion: false
      }];
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
              ownerReferences: owner,
              labels: {
                "app.kubernetes.io/part-of": $partOf,
                "scalex.io/release": $release,
                "scalex.io/runtime-binding-owner": $bindingName,
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
              ownerReferences: owner,
              labels: {
                "app.kubernetes.io/part-of": $partOf,
                "scalex.io/release": $release,
                "scalex.io/component": "runtime",
                "scalex.io/runtime-binding-owner": $bindingName,
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
      }
    ' | "$KUBECTL" --kubeconfig "$KARMADA_KUBECONFIG" apply \
      --server-side \
      --field-manager="$OBJECT_STORAGE_FIELD_MANAGER" \
      -f - >/dev/null

  echo "runtime binding applied: $binding_namespace/$binding_name -> $target_secret_name, $target_config_name"
}

index=0
while IFS= read -r binding; do
  index=$((index + 1))
  binding_file="$tmp/binding-$index.json"
  printf '%s\n' "$binding" >"$binding_file"
  process_binding "$binding_file"
done < <(jq -c '.items | sort_by(.metadata.namespace, .metadata.name)[]' "$bindings_json")

printf 'runtime binding reconciliation completed: %d binding(s)\n' "$binding_count"
