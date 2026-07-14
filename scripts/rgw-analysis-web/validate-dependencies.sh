#!/usr/bin/env bash
set -euo pipefail

manifest="${1:?dependency manifest is required}"
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

yq e -e '
  .apiVersion == "external-secrets.io/v1beta1" and
  .kind == "ExternalSecret" and
  .metadata.name == "rgw-analysis-web-rgw" and
  .metadata.namespace == "scalex-rgw-analysis-web" and
  .metadata.labels["app.kubernetes.io/part-of"] == "rgw-analysis-web" and
  .metadata.labels["scalex.io/release"] == "rgw-analysis-web" and
  .metadata.labels["scalex.io/component"] == "runtime-credentials" and
  .spec.refreshInterval == "1h" and
  .spec.secretStoreRef.kind == "SecretStore" and
  .spec.secretStoreRef.name == "scalex-poc-rgw-analysis-web" and
  .spec.target.creationPolicy == "Owner" and
  .spec.target.deletionPolicy == "Retain" and
  .spec.target.name == "scalex-poc-rgw" and
  (.spec.dataFrom | type) == "!!seq" and
  (.spec.dataFrom | length) == 1 and
  .spec.dataFrom[0].extract.key == "scalex/poc/rgw-analysis-web/rgw"
' "$manifest" >/dev/null || fail "identity or external-key contract mismatch"

exit 0
