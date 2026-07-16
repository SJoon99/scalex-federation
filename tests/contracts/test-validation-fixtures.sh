#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INPUT_FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"

for tool in check-jsonschema git helm jq tar yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: missing $tool" >&2
    exit 77
  }
done

test -d "$INPUT_FEATURE_REPOS_ROOT/temp-poc/.git" || {
  echo "temp-poc repository not found: $INPUT_FEATURE_REPOS_ROOT/temp-poc" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
VALIDATION_FEATURE_REPOS_ROOT="$INPUT_FEATURE_REPOS_ROOT"

make_federation() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT/bootstrap" "$ROOT/contracts" "$ROOT/releases" "$ROOT/scripts" "$target/"
}

expect_reject() {
  local name="$1"
  local expected="$2"
  local mutation="$3"
  local federation="$tmp/$name-federation"
  make_federation "$federation"
  VALIDATION_FEATURE_REPOS_ROOT="$INPUT_FEATURE_REPOS_ROOT"
  "$mutation" "$federation"
  if PATH="$PATH" FEATURE_REPOS_ROOT="$VALIDATION_FEATURE_REPOS_ROOT" \
    "$federation/scripts/validate.sh" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "validation mutation unexpectedly passed: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$name.err" || {
    cat "$tmp/$name.err" >&2
    exit 1
  }
}

set_unknown_descriptor_field() {
  yq -i '.unknown = true' "$1/releases/temp-poc/release.yaml"
}

set_mutable_revision() {
  yq -i '.source.revision = "main"' "$1/releases/temp-poc/release.yaml"
}

set_disallowed_source() {
  yq -i '.source.repoURL = "https://github.com/example/other.git"' \
    "$1/releases/temp-poc/release.yaml"
}

set_mismatched_values_path() {
  yq -i '.values.path = "releases/scalex-feature-poc/values.yaml"' \
    "$1/releases/temp-poc/release.yaml"
}

set_mutable_image() {
  yq -i '.images.datasetIngest.tag = "latest" | .images.datasetIngest.digest = ""' \
    "$1/releases/temp-poc/values.yaml"
}

make_source_fixture() {
  local federation="$1"
  local scenario="$2"
  local source="$tmp/$scenario-source/temp-poc"
  mkdir -p "$(dirname "$source")"
  git clone --quiet --local "$INPUT_FEATURE_REPOS_ROOT/temp-poc" "$source"
  git -C "$source" remote set-url origin https://github.com/BellTigerLee/temp-poc.git
  git -C "$source" config user.email fixture@example.invalid
  git -C "$source" config user.name fixture
  printf '%s\n' "$source"
}

set_missing_policy() {
  local federation="$1"
  local source
  source="$(make_source_fixture "$federation" missing-policy)"
  git -C "$source" rm --quiet chart/templates/karmada/batch-analyzer-propagation-policy.yaml \
    chart/templates/karmada/dataset-ingest-propagation-policy.yaml \
    chart/templates/karmada/report-generator-propagation-policy.yaml
  git -C "$source" commit --quiet -m missing-policy
  revision="$(git -C "$source" rev-parse HEAD)"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' \
    "$federation/releases/temp-poc/release.yaml"
  VALIDATION_FEATURE_REPOS_ROOT="$(dirname "$source")"
}

set_stale_selector() {
  local federation="$1"
  local source
  source="$(make_source_fixture "$federation" stale-selector)"
  sed -i 's/name: {{ include "temp-poc.fullname" . }}-batch-analyzer/name: missing/g' \
    "$source/chart/templates/karmada/batch-analyzer-propagation-policy.yaml"
  git -C "$source" add chart
  git -C "$source" commit --quiet -m stale-selector
  revision="$(git -C "$source" rev-parse HEAD)"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' \
    "$federation/releases/temp-poc/release.yaml"
  VALIDATION_FEATURE_REPOS_ROOT="$(dirname "$source")"
}

set_forbidden_secret() {
  local federation="$1"
  local source
  source="$(make_source_fixture "$federation" forbidden-secret)"
  printf '%s\n' \
    'apiVersion: v1' \
    'kind: Secret' \
    'metadata:' \
    '  name: forbidden' \
    'type: Opaque' >"$source/chart/templates/forbidden-secret.yaml"
  git -C "$source" add chart
  git -C "$source" commit --quiet -m forbidden-secret
  revision="$(git -C "$source" rev-parse HEAD)"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' \
    "$federation/releases/temp-poc/release.yaml"
  VALIDATION_FEATURE_REPOS_ROOT="$(dirname "$source")"
}

happy="$tmp/happy-federation"
make_federation "$happy"
FEATURE_REPOS_ROOT="$INPUT_FEATURE_REPOS_ROOT" "$happy/scripts/validate.sh" >/dev/null

expect_reject unknown-field 'release schema validation failed' set_unknown_descriptor_field
expect_reject mutable-revision 'release schema validation failed' set_mutable_revision
expect_reject disallowed-source 'source is not allowed by AppProject' set_disallowed_source
expect_reject mismatched-values 'values.path does not match release identity' set_mismatched_values_path
expect_reject mutable-image 'active workload images must use immutable digests' set_mutable_image

expect_reject missing-policy 'active feature chart must render a PropagationPolicy' set_missing_policy
expect_reject stale-selector 'Karmada policy selector coverage failed' set_stale_selector
expect_reject forbidden-secret 'active feature chart rendered an Infra dependency' set_forbidden_secret

echo "federation validation fixtures passed"
