#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"

for tool in check-jsonschema git helm jq tar yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: missing $tool" >&2
    exit 77
  }
done

test -d "$FEATURE_REPOS_ROOT/temp-poc/.git" || {
  echo "temp-poc repository not found: $FEATURE_REPOS_ROOT/temp-poc" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_federation() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT/bootstrap" "$ROOT/contracts" "$ROOT/releases" "$ROOT/scripts" "$target/"
}

add_canary() {
  local target="$1"
  mkdir -p "$target/releases/temp-poc-canary"
  cp "$target/releases/temp-poc/release.yaml" "$target/releases/temp-poc-canary/release.yaml"
  cp "$target/releases/temp-poc/values.yaml" "$target/releases/temp-poc-canary/values.yaml"
  yq -i '
    .name = "temp-poc-canary" |
    .namespace = "scalex-temp-poc-canary" |
    .values.path = "releases/temp-poc-canary/values.yaml"
  ' "$target/releases/temp-poc-canary/release.yaml"
}

happy="$tmp/happy"
make_federation "$happy"
add_canary "$happy"
FEATURE_REPOS_ROOT="$FEATURE_REPOS_ROOT" "$happy/scripts/validate.sh" >/dev/null

mapfile -t active_names < <(
  yq e -r -N 'select(.state == "active") | .name' "$happy"/releases/*/release.yaml |
    sed '/^[[:space:]]*$/d' | sort
)
[ "${active_names[*]}" = "temp-poc temp-poc-canary" ] || {
  echo "active release inventory drifted" >&2
  exit 1
}

duplicate_namespace="$tmp/duplicate-namespace"
make_federation "$duplicate_namespace"
add_canary "$duplicate_namespace"
yq -i '.namespace = "scalex-temp-poc"' \
  "$duplicate_namespace/releases/temp-poc-canary/release.yaml"
if FEATURE_REPOS_ROOT="$FEATURE_REPOS_ROOT" "$duplicate_namespace/scripts/validate.sh" \
  >"$tmp/duplicate-namespace.out" 2>"$tmp/duplicate-namespace.err"; then
  echo "duplicate namespace unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'duplicate release namespaces' "$tmp/duplicate-namespace.err"

mismatched_identity="$tmp/mismatched-identity"
make_federation "$mismatched_identity"
add_canary "$mismatched_identity"
yq -i '.name = "another-name"' \
  "$mismatched_identity/releases/temp-poc-canary/release.yaml"
if FEATURE_REPOS_ROOT="$FEATURE_REPOS_ROOT" "$mismatched_identity/scripts/validate.sh" \
  >"$tmp/mismatched-identity.out" 2>"$tmp/mismatched-identity.err"; then
  echo "mismatched release identity unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'release name must match its directory' "$tmp/mismatched-identity.err"

mismatched_values="$tmp/mismatched-values"
make_federation "$mismatched_values"
add_canary "$mismatched_values"
yq -i '.values.path = "releases/temp-poc/values.yaml"' \
  "$mismatched_values/releases/temp-poc-canary/release.yaml"
if FEATURE_REPOS_ROOT="$FEATURE_REPOS_ROOT" "$mismatched_values/scripts/validate.sh" \
  >"$tmp/mismatched-values.out" 2>"$tmp/mismatched-values.err"; then
  echo "mismatched values path unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'values.path does not match release identity' "$tmp/mismatched-values.err"

echo "multi-release coexistence tests passed"
