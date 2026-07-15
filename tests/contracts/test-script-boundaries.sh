#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "$*" >&2
  exit 1
}

contains_direct_mutation() {
  grep -RInE --include='*.sh' --include='*.yaml' --include='*.yml' \
    'kubectl([[:space:]\\]|[^[:space:]])*[[:space:]]+(apply|create|delete|edit|patch|replace|rollout|scale|set)([[:space:]]|$)' \
    "$@" >/dev/null
}

contains_credential_materialization() {
  grep -RInE --include='*.sh' --include='*.yaml' --include='*.yml' \
    '(create[[:space:]]+secret|--from-literal|stringData:|AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)[[:space:]]*=)' \
    "$@" >/dev/null
}

runner="$ROOT/scripts/sync-runtime-bindings.sh"
test -x "$runner" || fail "generic runtime binding runner is missing"
"$ROOT/tests/test-runtime-bindings.sh" >/dev/null
[ ! -e "$ROOT/scripts/sync-object-storage-binding.sh" ] ||
  fail "release-specific object storage binding script must be removed"
[ ! -e "$ROOT/scripts/bootstrap-cuty-rgw-credentials.sh" ] ||
  fail "feature-specific credential bootstrap must be removed"
[ ! -e "$ROOT/tests/test-storage-binding.sh" ] ||
  fail "release-specific storage binding test must be removed"

grep -Fq 'get configmaps -A -l scalex.io/runtime-binding=true' "$runner" ||
  fail "runtime binding discovery contract drifted"
grep -Fq 'MEMBER_KUBECONFIG_DIR/$source_cluster.kubeconfig' "$runner" ||
  fail "member kubeconfig resolver contract drifted"
grep -Fq 'OBJECT_STORAGE_FIELD_MANAGER="scalex-object-storage-binding"' "$runner" ||
  fail "runtime binding object-storage field ownership identity drifted"
if grep -nE -- '--arg (access|secret)|jsonpath=.*AWS_' "$runner" >/dev/null; then
  fail "runtime binding runner exposes credential material through process arguments"
fi
if grep -nE '(sourceCluster[[:space:]]*=[[:space:]]*b|B_KUBECONFIG|rgw-analysis-web)' "$runner" >/dev/null; then
  fail "runtime binding runner contains release or source-cluster hardcoding"
fi

mapfile -d '' -t automation_files < <(
  find "$ROOT/scripts" "$ROOT/.github/workflows" -type f \
    \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) -print0
)
mutation_audited_files=()
credential_audited_files=()
for file in "${automation_files[@]}"; do
  if [ "$file" != "$runner" ]; then
    mutation_audited_files+=("$file")
    credential_audited_files+=("$file")
  fi
done

if contains_direct_mutation "${mutation_audited_files[@]}"; then
  fail "Federation automation contains a direct cluster mutation outside the generic runner"
fi
if contains_credential_materialization "${credential_audited_files[@]}"; then
  fail "Federation automation contains credential materialization outside the generic runner"
fi

dependency_root="$ROOT/releases/poc/rgw-analysis-web/dependencies"
mapfile -t dependency_files < <(find "$dependency_root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[ "${#dependency_files[@]}" -eq 2 ] || fail "POC dependencies must contain exactly the claim and binding manifests"
yq e -o=json -I=0 "${dependency_files[@]}" | jq -s -e '
  length == 2 and
  any(.[];
    .apiVersion == "objectbucket.io/v1alpha1" and
    .kind == "ObjectBucketClaim" and
    .metadata.name == "rgw-analysis-web-bucket") and
  any(.[];
    .apiVersion == "v1" and
    .kind == "ConfigMap" and
    .metadata.name == "rgw-analysis-web-storage-binding" and
    .metadata.labels["scalex.io/runtime-binding"] == "true" and
    .metadata.labels["scalex.io/binding-type"] == "rook-obc-s3" and
    .data.contractVersion == "v1alpha1" and
    .data.bindingType == "rook-obc-s3") and
  all(.[];
    .kind != "Secret" and
    .kind != "PropagationPolicy" and
    .kind != "OverridePolicy" and
    .kind != "Deployment" and
    .kind != "Job")
' >/dev/null || fail "POC dependencies violate the runtime binding boundary"

grep -Fq './scripts/rgw-analysis-web/observe-release.sh' "$ROOT/.github/workflows/runtime-observation.yaml" ||
  fail "runtime workflow must invoke the read-only observer"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts/nested"
printf '%s\n' '#!/usr/bin/env bash' 'kubectl apply -f attacker.yaml' > \
  "$tmp/scripts/nested/sync-runtime-bindings.sh"
contains_direct_mutation "$tmp/scripts/nested" ||
  fail "nested same-basename mutation escaped the exact runner exception"
printf '%s\n' '#!/usr/bin/env bash' 'kubectl create secret generic runtime --from-literal=key=value' > \
  "$tmp/scripts/credential.sh"
contains_credential_materialization "$tmp/scripts" ||
  fail "credential materialization mutation was not detected"

echo "script boundary tests passed"
