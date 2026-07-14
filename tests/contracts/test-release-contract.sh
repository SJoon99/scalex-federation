#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/scripts/lib/release-contract.sh"
SCHEMA_VALIDATOR="$ROOT/scripts/lib/validate-release-schema.sh"

[ -f "$LIB" ] || {
  echo "missing release contract library: $LIB" >&2
  exit 1
}
[ -x "$SCHEMA_VALIDATOR" ] || {
  echo "missing executable release schema validator: $SCHEMA_VALIDATOR" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || {
  echo "SKIP: yq v4 is required" >&2
  exit 77
}

# shellcheck source=scripts/lib/release-contract.sh
source "$LIB"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$ROOT/tests/fixtures/contracts/valid-release.yaml" "$tmp/release.yaml"
"$SCHEMA_VALIDATOR" "$tmp/release.yaml"
validate_release_descriptor "$tmp/release.yaml" "poc" "rgw-analysis-web"
"$SCHEMA_VALIDATOR" "$ROOT/tests/fixtures/contracts/pinned-release.yaml"
validate_release_descriptor "$ROOT/tests/fixtures/contracts/pinned-release.yaml" "poc" "rgw-analysis-web"
"$SCHEMA_VALIDATOR" "$ROOT/releases/poc/rgw-analysis-web/release.yaml"
[ "$(yq e -r '.promotion.mode' "$ROOT/releases/poc/rgw-analysis-web/release.yaml")" = pinned ] || {
  echo "active manual release must use pinned promotion" >&2
  exit 1
}
mkdir -p "$tmp/wrong-version-bin"
printf '%s\n' '#!/usr/bin/env bash' 'echo "check-jsonschema, version 0.33.4"' > "$tmp/wrong-version-bin/check-jsonschema"
chmod +x "$tmp/wrong-version-bin/check-jsonschema"
if PATH="$tmp/wrong-version-bin:$PATH" "$SCHEMA_VALIDATOR" "$tmp/release.yaml" >/dev/null 2>&1; then
  echo "wrong check-jsonschema version unexpectedly passed" >&2
  exit 1
fi

expect_reject() {
  local name="$1"
  shift
  cp "$ROOT/tests/fixtures/contracts/valid-release.yaml" "$tmp/$name.yaml"
  "$@" "$tmp/$name.yaml"
  if validate_release_descriptor "$tmp/$name.yaml" "poc" "rgw-analysis-web" >/dev/null 2>&1; then
    echo "expected rejection: $name" >&2
    exit 1
  fi
}

expect_schema_reject() {
  local name="$1"
  shift
  cp "$ROOT/tests/fixtures/contracts/valid-release.yaml" "$tmp/schema-$name.yaml"
  "$@" "$tmp/schema-$name.yaml"
  if "$SCHEMA_VALIDATOR" "$tmp/schema-$name.yaml" >/dev/null 2>&1; then
    echo "expected JSON Schema rejection: $name" >&2
    exit 1
  fi
}

expect_schema_accept_semantic_reject() {
  local name="$1"
  shift
  cp "$ROOT/tests/fixtures/contracts/valid-release.yaml" "$tmp/semantic-$name.yaml"
  "$@" "$tmp/semantic-$name.yaml"
  "$SCHEMA_VALIDATOR" "$tmp/semantic-$name.yaml" >/dev/null
  if validate_release_descriptor "$tmp/semantic-$name.yaml" "poc" "rgw-analysis-web" >/dev/null 2>&1; then
    echo "expected cross-field semantic rejection: $name" >&2
    exit 1
  fi
}

add_unknown_field() {
  yq -i '.unexpected = true' "$1"
}

set_unknown_renderer() {
  yq -i '.renderer = "kustomize/v1"' "$1"
}

set_mutable_revision() {
  yq -i '.source.revision = "main"' "$1"
}

set_zero_revision() {
  yq -i '.source.revision = "0000000000000000000000000000000000000000"' "$1"
}

set_traversal_path() {
  yq -i '.source.path = "../charts/rgw-analysis-web"' "$1"
}

set_bad_identity() {
  yq -i '.name = "another-release"' "$1"
}

set_bad_promotion() {
  yq -i '.promotion.mode = "automatic"' "$1"
}

set_cross_field_namespace() {
  yq -i '.namespace = "scalex-another-release"' "$1"
}

set_cross_field_values_path() {
  yq -i '.values.path = "releases/poc/another-release/values.yaml"' "$1"
}

expect_schema_reject unknown-field add_unknown_field
expect_schema_reject unknown-renderer set_unknown_renderer
expect_schema_reject mutable-revision set_mutable_revision
expect_schema_reject zero-revision set_zero_revision
expect_schema_reject traversal-path set_traversal_path
expect_schema_reject unknown-promotion set_bad_promotion
expect_schema_accept_semantic_reject directory-identity set_bad_identity
expect_schema_accept_semantic_reject namespace-identity set_cross_field_namespace
expect_schema_accept_semantic_reject values-path-identity set_cross_field_values_path

expect_reject unknown-field add_unknown_field
expect_reject unknown-renderer set_unknown_renderer
expect_reject mutable-revision set_mutable_revision
expect_reject zero-revision set_zero_revision
expect_reject traversal-path set_traversal_path
expect_reject mismatched-identity set_bad_identity
expect_reject unknown-promotion set_bad_promotion

echo "release contract tests passed"
