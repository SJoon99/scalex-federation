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
  local expected_name="$2"
  local name namespace state renderer repo_url source_path revision values_path promotion_mode
  local expected_keys

  yq e '.' "$descriptor" >/dev/null || contract_fail "malformed release descriptor: $descriptor"
  state="$(yq e -r '.state' "$descriptor")"
  if [ "$state" = disabled ]; then
    expected_keys=$'disabledReason\nname\nnamespace\npromotion\nrenderer\nsource\nstate\nvalues'
    require_string "$descriptor" '.disabledReason'
  else
    expected_keys=$'name\nnamespace\npromotion\nrenderer\nsource\nstate\nvalues'
  fi
  require_exact_keys "$descriptor" '.' "$expected_keys"
  require_exact_keys "$descriptor" '.source' $'path\nrepoURL\nrevision'
  require_exact_keys "$descriptor" '.values' 'path'
  require_exact_keys "$descriptor" '.promotion' 'mode'

  local field
  for field in \
    .name .namespace .state .renderer .source.repoURL .source.path \
    .source.revision .values.path .promotion.mode; do
    require_string "$descriptor" "$field"
  done

  name="$(yq e -r '.name' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  renderer="$(yq e -r '.renderer' "$descriptor")"
  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  source_path="$(yq e -r '.source.path' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  values_path="$(yq e -r '.values.path' "$descriptor")"
  promotion_mode="$(yq e -r '.promotion.mode' "$descriptor")"

  [ "$name" = "$expected_name" ] || contract_fail "release name must match its directory"
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || contract_fail "invalid release name"
  [[ "$namespace" =~ ^scalex-[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
    contract_fail "release namespace must be a scalex-prefixed DNS label"
  case "$state" in
    active | disabled) ;;
    *) contract_fail "release state must be active or disabled" ;;
  esac
  [ "$renderer" = helm/v1 ] || contract_fail "unsupported renderer: $renderer"
  [[ "$repo_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ||
    contract_fail "source.repoURL must be an exact HTTPS GitHub URL"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || contract_fail "source revision must be a full commit SHA"
  [ "$revision" != 0000000000000000000000000000000000000000 ] ||
    contract_fail "source revision cannot be the all-zero placeholder"
  require_relative_path "$source_path" source.path
  require_relative_path "$values_path" values.path
  [ "$values_path" = "releases/$name/values.yaml" ] ||
    contract_fail "values.path does not match release identity"
  case "$promotion_mode" in
    tracked | pinned) ;;
    *) contract_fail "promotion.mode must be tracked or pinned" ;;
  esac
}
