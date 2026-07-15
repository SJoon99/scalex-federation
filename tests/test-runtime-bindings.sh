#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/sync-runtime-bindings.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

[ -x "$RUNNER" ] || {
  echo "missing generic runtime binding runner: $RUNNER" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/member-kubeconfigs" "$tmp/applies"
: >"$tmp/karmada.kubeconfig"
for cluster in b c; do
  : >"$tmp/member-kubeconfigs/$cluster.kubeconfig"
  chmod 600 "$tmp/member-kubeconfigs/$cluster.kubeconfig"
done

cat >"$tmp/bindings.json" <<'JSON'
{
  "apiVersion": "v1",
  "kind": "ConfigMapList",
  "items": [
    {
      "apiVersion": "v1",
      "kind": "ConfigMap",
      "metadata": {
        "name": "alpha-storage-binding",
        "namespace": "scalex-alpha",
        "uid": "11111111-1111-1111-1111-111111111111",
        "labels": {
          "app.kubernetes.io/part-of": "scalex-federation",
          "scalex.io/release": "alpha",
          "scalex.io/component": "runtime-binding",
          "scalex.io/runtime-binding": "true",
          "scalex.io/binding-type": "rook-obc-s3"
        }
      },
      "data": {
        "contractVersion": "v1alpha1",
        "bindingType": "rook-obc-s3",
        "sourceCluster": "b",
        "sourceNamespace": "scalex-alpha",
        "sourceClaimName": "alpha-bucket",
        "sourceSecretName": "alpha-bucket",
        "sourceConfigMapName": "alpha-bucket",
        "targetNamespace": "scalex-alpha",
        "targetSecretName": "alpha-s3",
        "targetConfigMapName": "alpha-runtime",
        "endpointUrl": "http://10.33.142.10",
        "region": "scalex-alpha"
      }
    },
    {
      "apiVersion": "v1",
      "kind": "ConfigMap",
      "metadata": {
        "name": "beta-storage-binding",
        "namespace": "scalex-beta",
        "uid": "22222222-2222-2222-2222-222222222222",
        "labels": {
          "app.kubernetes.io/part-of": "scalex-federation",
          "scalex.io/release": "beta",
          "scalex.io/component": "runtime-binding",
          "scalex.io/runtime-binding": "true",
          "scalex.io/binding-type": "rook-obc-s3"
        }
      },
      "data": {
        "contractVersion": "v1alpha1",
        "bindingType": "rook-obc-s3",
        "sourceCluster": "c",
        "sourceNamespace": "scalex-beta",
        "sourceClaimName": "beta-bucket",
        "sourceSecretName": "beta-bucket",
        "sourceConfigMapName": "beta-bucket",
        "targetNamespace": "scalex-beta",
        "targetSecretName": "beta-s3",
        "targetConfigMapName": "beta-runtime",
        "endpointUrl": "http://10.33.143.10",
        "region": "scalex-beta"
      }
    }
  ]
}
JSON

cat >"$tmp/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

kubeconfig=""
namespace=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --kubeconfig) kubeconfig="${args[$((i + 1))]}" ;;
    -n|--namespace) namespace="${args[$((i + 1))]}" ;;
  esac
done
command_line="$*"

if [ "$kubeconfig" = "$MOCK_KARMADA_KUBECONFIG" ]; then
  case "$command_line" in
    *'get configmaps -A -l scalex.io/runtime-binding=true -o json'*)
      cat "$MOCK_BINDINGS"
      ;;
    *'get configmaps -l scalex.io/runtime-binding=true -o json'*)
      jq --arg namespace "$namespace" \
        '{apiVersion, kind, items: [.items[] | select(.metadata.namespace == $namespace)]}' \
        "$MOCK_BINDINGS"
      ;;
    *'apply --server-side --field-manager=scalex-object-storage-binding -f -'*)
      count=0
      [ ! -f "$MOCK_COUNTER" ] || count="$(cat "$MOCK_COUNTER")"
      count=$((count + 1))
      printf '%s' "$count" >"$MOCK_COUNTER"
      cat >"$MOCK_APPLY_DIR/$count.json"
      ;;
    *)
      echo "unexpected Karmada kubectl call: $command_line" >&2
      exit 1
      ;;
  esac
  exit 0
fi

cluster="$(basename "$kubeconfig" .kubeconfig)"
case "$cluster:$namespace:$command_line" in
  b:scalex-alpha:*'get objectbucketclaim alpha-bucket -o json'*)
    printf '%s' '{"apiVersion":"objectbucket.io/v1alpha1","kind":"ObjectBucketClaim","metadata":{"name":"alpha-bucket","namespace":"scalex-alpha"},"status":{"phase":"Bound"}}'
    ;;
  b:scalex-alpha:*'get secret alpha-bucket -o json'*)
    if [ "${MOCK_SOURCE_FORBIDDEN:-false}" = true ]; then
      echo 'Error from server (Forbidden): secrets is forbidden' >&2
      exit 1
    fi
    printf '%s' '{"data":{"AWS_ACCESS_KEY_ID":"QUxQSEEtS0VZ","AWS_SECRET_ACCESS_KEY":"QUxQSEEtU0VDUkVU"}}'
    ;;
  b:scalex-alpha:*'get configmap alpha-bucket -o json'*)
    if [ "${MOCK_SOURCE_CONFIG_INVALID:-false}" = true ]; then
      printf '%s' '{"data":{"BUCKET_HOST":"rook-ceph-rgw"}}'
    else
      printf '%s' '{"data":{"BUCKET_NAME":"alpha-generated-bucket"}}'
    fi
    ;;
  c:scalex-beta:*'get objectbucketclaim beta-bucket -o json'*)
    printf '%s' '{"apiVersion":"objectbucket.io/v1alpha1","kind":"ObjectBucketClaim","metadata":{"name":"beta-bucket","namespace":"scalex-beta"},"status":{"phase":"Bound"}}'
    ;;
  c:scalex-beta:*'get secret beta-bucket -o json'*)
    printf '%s' '{"data":{"AWS_ACCESS_KEY_ID":"QkVUQS1LRVk=","AWS_SECRET_ACCESS_KEY":"QkVUQS1TRUNSRVQ="}}'
    ;;
  c:scalex-beta:*'get configmap beta-bucket -o json'*)
    printf '%s' '{"data":{"BUCKET_NAME":"beta-generated-bucket"}}'
    ;;
  *)
    echo "unexpected member kubectl call: $cluster $namespace $command_line" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/bin/kubectl"

export MOCK_BINDINGS="$tmp/bindings.json"
export MOCK_KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig"
export MOCK_APPLY_DIR="$tmp/applies"
export MOCK_COUNTER="$tmp/counter"
export MOCK_LOG="$tmp/kubectl.log"

PATH="$tmp/bin:$PATH" \
KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
SOURCE_WAIT_SECONDS=1 \
SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/runner.out" 2>"$tmp/runner.err"

[ "$(cat "$tmp/counter")" -eq 2 ] || {
  echo "generic runner did not apply both bindings" >&2
  exit 1
}

jq -s -e '
  length == 2 and
  any(.[].items[];
    .kind == "Secret" and
    .metadata.namespace == "scalex-alpha" and
    .metadata.name == "alpha-s3" and
    .metadata.labels["scalex.io/release"] == "alpha" and
    .metadata.ownerReferences == [{
      "apiVersion":"v1",
      "kind":"ConfigMap",
      "name":"alpha-storage-binding",
      "uid":"11111111-1111-1111-1111-111111111111",
      "controller":false,
      "blockOwnerDeletion":false
    }] and
    .data.AWS_ACCESS_KEY_ID == "QUxQSEEtS0VZ") and
  any(.[].items[];
    .kind == "ConfigMap" and
    .metadata.namespace == "scalex-beta" and
    .metadata.name == "beta-runtime" and
    .metadata.labels["scalex.io/release"] == "beta" and
    .data.S3_BUCKET == "beta-generated-bucket" and
    .data.S3_ENDPOINT_URL == "http://10.33.143.10")
' "$tmp/applies/1.json" "$tmp/applies/2.json" >/dev/null

grep -Fq "$tmp/member-kubeconfigs/b.kubeconfig" "$tmp/kubectl.log"
grep -Fq "$tmp/member-kubeconfigs/c.kubeconfig" "$tmp/kubectl.log"
grep -Fq 'runtime binding applied: scalex-alpha/alpha-storage-binding' "$tmp/runner.out"
grep -Fq 'runtime binding applied: scalex-beta/beta-storage-binding' "$tmp/runner.out"
if grep -Fq 'QUxQSEEtU0VDUkVU' "$tmp/runner.out" "$tmp/runner.err" "$tmp/kubectl.log"; then
  echo "generic runner leaked credential material" >&2
  exit 1
fi

PATH="$tmp/bin:$PATH" \
KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
SOURCE_WAIT_SECONDS=1 \
SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --binding scalex-alpha/alpha-storage-binding \
  >"$tmp/single.out" 2>"$tmp/single.err"
[ "$(cat "$tmp/counter")" -eq 3 ] || {
  echo "generic runner did not reconcile one explicitly selected binding" >&2
  exit 1
}
grep -Fq 'runtime binding applied: scalex-alpha/alpha-storage-binding' "$tmp/single.out"

unsupported="$tmp/unsupported.json"
jq '.items = [.items[0]] | .items[0].metadata.labels["scalex.io/binding-type"] = "arbitrary-copy" | .items[0].data.bindingType = "arbitrary-copy"' \
  "$tmp/bindings.json" >"$unsupported"
if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$unsupported" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/unsupported.out" 2>"$tmp/unsupported.err"; then
  echo "generic runner accepted an unsupported binding type" >&2
  exit 1
fi
grep -Fq 'unsupported runtime binding contract' "$tmp/unsupported.err"

cross_namespace="$tmp/cross-namespace.json"
jq '.items = [.items[0]] | .items[0].data.targetNamespace = "another-namespace"' \
  "$tmp/bindings.json" >"$cross_namespace"
if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$cross_namespace" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/cross.out" 2>"$tmp/cross.err"; then
  echo "generic runner accepted a cross-namespace binding" >&2
  exit 1
fi
grep -Fq 'source and target namespaces must match the binding namespace' "$tmp/cross.err"

alpha_only="$tmp/alpha-only.json"
jq '.items = [.items[0]]' "$tmp/bindings.json" >"$alpha_only"
if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$alpha_only" MOCK_SOURCE_FORBIDDEN=true \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/forbidden.out" 2>"$tmp/forbidden.err"; then
  echo "generic runner accepted a source authorization failure" >&2
  exit 1
fi
grep -Fq 'Forbidden' "$tmp/forbidden.err"

if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$alpha_only" MOCK_SOURCE_CONFIG_INVALID=true \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/invalid-source.out" 2>"$tmp/invalid-source.err"; then
  echo "generic runner accepted a source ConfigMap without BUCKET_NAME" >&2
  exit 1
fi
grep -Fq 'source rook-obc-s3 output is not ready' "$tmp/invalid-source.err"

duplicate="$tmp/duplicate.json"
jq '
  .items[1].metadata.namespace = "scalex-alpha" |
  .items[1].data.sourceCluster = "b" |
  .items[1].data.sourceNamespace = "scalex-alpha" |
  .items[1].data.sourceClaimName = "alpha-bucket" |
  .items[1].data.sourceSecretName = "alpha-bucket" |
  .items[1].data.sourceConfigMapName = "alpha-bucket" |
  .items[1].data.targetNamespace = "scalex-alpha" |
  .items[1].data.targetSecretName = "alpha-s3" |
  .items[1].data.targetConfigMapName = "alpha-runtime"
' "$tmp/bindings.json" >"$duplicate"
if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$duplicate" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/duplicate.out" 2>"$tmp/duplicate.err"; then
  echo "generic runner accepted duplicate target identities" >&2
  exit 1
fi
grep -Fq 'runtime bindings contain a duplicate target identity' "$tmp/duplicate.err"

if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$duplicate" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --binding scalex-alpha/alpha-storage-binding \
  >"$tmp/duplicate-single.out" 2>"$tmp/duplicate-single.err"; then
  echo "single-binding mode bypassed duplicate target validation" >&2
  exit 1
fi
grep -Fq 'runtime bindings contain a duplicate target identity' "$tmp/duplicate-single.err"

self_target="$tmp/self-target.json"
jq '
  .items = [.items[0]] |
  .items[0].data.targetConfigMapName = "alpha-storage-binding"
' "$tmp/bindings.json" >"$self_target"
if PATH="$tmp/bin:$PATH" \
  MOCK_BINDINGS="$self_target" \
  KARMADA_KUBECONFIG="$tmp/karmada.kubeconfig" \
  MEMBER_KUBECONFIG_DIR="$tmp/member-kubeconfigs" \
  SOURCE_WAIT_SECONDS=1 SOURCE_POLL_INTERVAL_SECONDS=1 \
  "$RUNNER" --all >"$tmp/self-target.out" 2>"$tmp/self-target.err"; then
  echo "generic runner allowed a target ConfigMap to overwrite its binding" >&2
  exit 1
fi
grep -Fq 'target ConfigMap cannot overwrite the binding declaration' "$tmp/self-target.err"

echo "runtime binding runner tests passed"
