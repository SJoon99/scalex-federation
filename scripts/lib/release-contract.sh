#!/usr/bin/env bash

contract_fail() {
  echo "$*" >&2
  exit 1
}

require_exact_keys() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local actual
  actual="$(yq e -r "$expression | keys | .[]" "$file" | LC_ALL=C sort)" || return 1
  [ "$actual" = "$expected" ] ||
    contract_fail "unexpected fields at $expression in $file"
}

require_string() {
  local file="$1"
  local expression="$2"
  yq e -e "($expression | tag) == \"!!str\" and ($expression | length) > 0" \
    "$file" >/dev/null || contract_fail "expected non-empty string at $expression in $file"
}

require_relative_path() {
  local path="$1"
  local field="$2"
  [ -n "$path" ] || contract_fail "$field cannot be empty"
  [[ "$path" != /* ]] || contract_fail "$field must be relative"
  [[ "/$path/" != *"/../"* ]] || contract_fail "$field cannot traverse parents"
  [[ "/$path/" != *"/./"* ]] || contract_fail "$field cannot contain dot segments"
  [[ "$path" != *//* ]] || contract_fail "$field cannot contain empty segments"
  [[ "$path" != *$'\n'* ]] || contract_fail "$field cannot contain newlines"
}

validate_release_descriptor() (
  set -e
  _validate_release_descriptor "$@"
)

_validate_release_descriptor() {
  local descriptor="$1"
  local expected_environment="$2"
  local expected_name="$3"
  local name environment namespace renderer repo_url source_path revision
  local values_path dependencies_path policy_path promotion_mode

  yq e '.' "$descriptor" >/dev/null || contract_fail "malformed release descriptor: $descriptor"
  require_exact_keys "$descriptor" '.' $'apiVersion\ndependencies\nenvironment\nkind\nname\nnamespace\npolicy\npromotion\nrenderer\nsource\nvalues'
  require_exact_keys "$descriptor" '.source' $'path\nrepoURL\nrevision'
  require_exact_keys "$descriptor" '.values' 'path'
  require_exact_keys "$descriptor" '.dependencies' 'path'
  require_exact_keys "$descriptor" '.policy' 'path'
  require_exact_keys "$descriptor" '.promotion' 'mode'

  local field
  for field in \
    .apiVersion .kind .name .environment .namespace .renderer \
    .source.repoURL .source.path .source.revision .values.path \
    .dependencies.path .policy.path .promotion.mode; do
    require_string "$descriptor" "$field"
  done

  [ "$(yq e -r '.apiVersion' "$descriptor")" = scalex.io/v1alpha1 ] ||
    contract_fail "unsupported release apiVersion: $descriptor"
  [ "$(yq e -r '.kind' "$descriptor")" = FederationRelease ] ||
    contract_fail "unsupported release kind: $descriptor"

  name="$(yq e -r '.name' "$descriptor")"
  environment="$(yq e -r '.environment' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  renderer="$(yq e -r '.renderer' "$descriptor")"
  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  source_path="$(yq e -r '.source.path' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  values_path="$(yq e -r '.values.path' "$descriptor")"
  dependencies_path="$(yq e -r '.dependencies.path' "$descriptor")"
  policy_path="$(yq e -r '.policy.path' "$descriptor")"
  promotion_mode="$(yq e -r '.promotion.mode' "$descriptor")"

  [ "$name" = "$expected_name" ] || contract_fail "release name must match its directory"
  [ "$environment" = "$expected_environment" ] || contract_fail "release environment must match its directory"
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || contract_fail "invalid release name"
  [[ "$environment" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || contract_fail "invalid environment"
  [ "$namespace" = "scalex-$name" ] || contract_fail "release namespace must be scalex-$name"
  [ "$renderer" = helm/v1 ] || contract_fail "unsupported renderer: $renderer"
  [[ "$repo_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ||
    contract_fail "source.repoURL must be an exact HTTPS GitHub URL"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || contract_fail "source revision must be a full commit SHA"
  [ "$revision" != 0000000000000000000000000000000000000000 ] ||
    contract_fail "source revision cannot be the all-zero placeholder"
  require_relative_path "$source_path" source.path
  require_relative_path "$values_path" values.path
  require_relative_path "$dependencies_path" dependencies.path
  require_relative_path "$policy_path" policy.path
  [ "$values_path" = "releases/$environment/$name/values.yaml" ] ||
    contract_fail "values.path does not match release identity"
  [ "$dependencies_path" = "releases/$environment/$name/dependencies" ] ||
    contract_fail "dependencies.path does not match release identity"
  [ "$policy_path" = "releases/$environment/$name/karmada" ] ||
    contract_fail "policy.path does not match release identity"
  case "$promotion_mode" in
    tracked | pinned) ;;
    *) contract_fail "promotion.mode must be tracked or pinned" ;;
  esac
}
