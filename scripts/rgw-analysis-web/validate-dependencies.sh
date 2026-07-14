#!/usr/bin/env bash
set -euo pipefail

manifest="${1:?dependency manifest is required}"
namespace="${2:?release namespace is required}"
environment="${3:?release environment is required}"
release="${4:?release name is required}"
existing_secret="${5:?existing Secret name is required}"
command -v yq >/dev/null 2>&1 || {
  echo "required command not found: yq" >&2
  exit 1
}

fail() {
  echo "invalid RGW ExternalSecret structure: $*" >&2
  exit 1
}

exact_keys() {
  local expression="$1"
  local expected="$2"
  local actual
  actual="$(yq e -r "$expression | keys | .[]" "$manifest" | LC_ALL=C sort)" || fail "$expression is not a map"
  [ "$actual" = "$expected" ] || fail "unexpected fields at $expression"
}

yq e '.' "$manifest" >/dev/null || fail "malformed YAML"
exact_keys '.' $'apiVersion\nkind\nmetadata\nspec'
exact_keys '.metadata' $'labels\nname\nnamespace'
exact_keys '.metadata.labels' $'app.kubernetes.io/part-of\nscalex.io/component\nscalex.io/release'
exact_keys '.spec' $'dataFrom\nrefreshInterval\nsecretStoreRef\ntarget'
exact_keys '.spec.secretStoreRef' $'kind\nname'
exact_keys '.spec.target' $'creationPolicy\ndeletionPolicy\nname'
exact_keys '.spec.dataFrom[0]' 'extract'
exact_keys '.spec.dataFrom[0].extract' 'key'

EXPECTED_NAME="$release-rgw" \
EXPECTED_NAMESPACE="$namespace" \
EXPECTED_RELEASE="$release" \
EXPECTED_SECRET="$existing_secret" \
EXPECTED_KEY="scalex/$environment/$release/rgw" \
yq e -e '
  .apiVersion == "external-secrets.io/v1beta1" and
  .kind == "ExternalSecret" and
  .metadata.name == strenv(EXPECTED_NAME) and
  .metadata.namespace == strenv(EXPECTED_NAMESPACE) and
  .metadata.labels["app.kubernetes.io/part-of"] == strenv(EXPECTED_RELEASE) and
  .metadata.labels["scalex.io/release"] == strenv(EXPECTED_RELEASE) and
  .metadata.labels["scalex.io/component"] == "runtime-credentials" and
  .spec.refreshInterval == "1h" and
  .spec.secretStoreRef.kind == "SecretStore" and
  .spec.secretStoreRef.name == strenv(EXPECTED_NAMESPACE) and
  .spec.target.creationPolicy == "Owner" and
  .spec.target.deletionPolicy == "Retain" and
  .spec.target.name == strenv(EXPECTED_SECRET) and
  (.spec.dataFrom | type) == "!!seq" and
  (.spec.dataFrom | length) == 1 and
  .spec.dataFrom[0].extract.key == strenv(EXPECTED_KEY)
' "$manifest" >/dev/null || fail "identity or external-key contract mismatch"

exit 0
