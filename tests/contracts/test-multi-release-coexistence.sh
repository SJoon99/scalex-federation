#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPECTED="$ROOT/tests/fixtures/contracts/multi-release-active.tsv"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"; readonly FEATURE_REPOS_ROOT
export FEATURE_REPOS_ROOT

for tool in check-jsonschema git helm jq tar yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: missing $tool" >&2
    exit 77
  }
done

test -f "$EXPECTED" || {
  echo "missing multi-release expectations fixture" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

assert_exact_release_inventory() {
  local federation_root="$1"
  local expected="$2"
  local evidence_root="$3"
  local -a missing unexpected
  mkdir -p "$evidence_root"
  awk -F '\t' 'NF > 0 { print $1 }' "$expected" | LC_ALL=C sort -u >"$evidence_root/expected-paths.txt"
  find "$federation_root/releases" -mindepth 3 -maxdepth 3 -name release.yaml -type f |
    sed "s#^$federation_root/##" | LC_ALL=C sort -u >"$evidence_root/actual-paths.txt"
  mapfile -t missing < <(comm -23 "$evidence_root/expected-paths.txt" "$evidence_root/actual-paths.txt")
  mapfile -t unexpected < <(comm -13 "$evidence_root/expected-paths.txt" "$evidence_root/actual-paths.txt")
  if [ "${#missing[@]}" -eq 0 ] && [ "${#unexpected[@]}" -eq 0 ]; then
    return 0
  fi
  local path
  for path in "${missing[@]}"; do
    echo "expected active descriptor missing: $path" >&2
  done
  for path in "${unexpected[@]}"; do
    echo "unexpected active descriptor: $path" >&2
  done
  return 1
}

assert_exact_release_inventory "$ROOT" "$EXPECTED" "$tmp/active-inventory"

mapfile -t descriptors < <(find "$ROOT/releases" -mindepth 3 -maxdepth 3 -name release.yaml -type f | LC_ALL=C sort)
[ "${#descriptors[@]}" -gt 0 ] || {
  echo "no active release descriptors" >&2
  exit 1
}

: >"$tmp/apps.txt"
: >"$tmp/namespaces.txt"
for descriptor in "${descriptors[@]}"; do
  environment="$(yq e -r '.environment' "$descriptor")"
  name="$(yq e -r '.name' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  app="federation-$environment-$name"
  relative="${descriptor#"$ROOT"/}"
  printf 'ACTIVE\t%s\t%s\t%s\t%s@%s\n' "$relative" "$app" "$namespace" "$repo_url" "$revision"
  printf '%s\n' "$app" >>"$tmp/apps.txt"
  printf '%s\n' "$namespace" >>"$tmp/namespaces.txt"
done

assert_expected_release_contract() (
  local federation_root="$1"
  local expected="$2"
  local relative expected_app expected_namespace expected_repo expected_path revision_contract
  local descriptor environment name actual_app actual_revision
  while IFS=$'\t' read -r relative expected_app expected_namespace expected_repo expected_path revision_contract; do
    descriptor="$federation_root/$relative"
    test -f "$descriptor" || {
      echo "expected active descriptor missing: $relative" >&2
      return 1
    }
    environment="$(yq e -r '.environment' "$descriptor")"
    name="$(yq e -r '.name' "$descriptor")"
    actual_app="federation-$environment-$name"
    [ "$actual_app" = "$expected_app" ] || {
      echo "unexpected generated Application identity: $relative" >&2
      return 1
    }
    [ "$(yq e -r '.namespace' "$descriptor")" = "$expected_namespace" ] || {
      echo "unexpected release namespace: $relative" >&2
      return 1
    }
    [ "$(yq e -r '.source.repoURL' "$descriptor")" = "$expected_repo" ] || {
      echo "unexpected child repository pin: $relative" >&2
      return 1
    }
    [ "$(yq e -r '.source.path' "$descriptor")" = "$expected_path" ] || {
      echo "unexpected child chart path: $relative" >&2
      return 1
    }
    actual_revision="$(yq e -r '.source.revision' "$descriptor")"
    case "$revision_contract" in
      full-sha)
        [[ "$actual_revision" =~ ^[0-9a-f]{40}$ ]] &&
          [ "$actual_revision" != 0000000000000000000000000000000000000000 ] || {
          echo "active release revision is not a full SHA: $relative" >&2
          return 1
        }
        ;;
      *)
        [ "$actual_revision" = "$revision_contract" ] || {
          echo "unexpected child revision pin: $relative" >&2
          return 1
        }
        ;;
    esac
  done <"$expected"
)

assert_expected_release_contract "$ROOT" "$EXPECTED"

[ -z "$(LC_ALL=C sort "$tmp/apps.txt" | uniq -d)" ] || {
  echo "duplicate generated Application identity" >&2
  exit 1
}
[ -z "$(LC_ALL=C sort "$tmp/namespaces.txt" | uniq -d)" ] || {
  echo "duplicate release namespace" >&2
  exit 1
}

yq e -e '
  .spec.template.metadata.name == "federation-{{ .environment }}-{{ .name }}" and
  .spec.generators[0].git.files[0].path == "releases/*/*/release.yaml"
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null || {
  echo "ApplicationSet does not preserve the multi-release identity contract" >&2
  exit 1
}

record_aggregate_identities() {
  local descriptor environment name namespace repo_url repo_name revision chart_path values_path
  local feature_repo chart_export chart_render dependencies_path policy_path
  local -a manifests
  : >"$tmp/rendered-identities.txt"
  : >"$tmp/external-secret-targets.txt"
  for descriptor in "${descriptors[@]}"; do
    environment="$(yq e -r '.environment' "$descriptor")"
    name="$(yq e -r '.name' "$descriptor")"
    namespace="$(yq e -r '.namespace' "$descriptor")"
    repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
    repo_name="$(basename "${repo_url%.git}")"
    revision="$(yq e -r '.source.revision' "$descriptor")"
    chart_path="$(yq e -r '.source.path' "$descriptor")"
    values_path="$(yq e -r '.values.path' "$descriptor")"
    dependencies_path="$(yq e -r '.dependencies.path' "$descriptor")"
    policy_path="$(yq e -r '.policy.path' "$descriptor")"
    feature_repo="$FEATURE_REPOS_ROOT/$repo_name"
    chart_export="$tmp/sources/$environment-$name"
    chart_render="$tmp/$environment-$name-chart.yaml"
    mkdir -p "$chart_export"
    git -C "$feature_repo" archive "$revision" "$chart_path" | tar -x -C "$chart_export"
    helm template "$name" "$chart_export/$chart_path" --namespace "$namespace" \
      -f "$ROOT/$values_path" >"$chart_render"
    mapfile -t manifests < <(
      find "$ROOT/$dependencies_path" "$ROOT/$policy_path" -type f \
        \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort
    )
    manifests=("$chart_render" "${manifests[@]}")
    NAMESPACE="$namespace" yq e -r -N '
      select(. != null) |
      [.apiVersion, .kind, (.metadata.namespace // strenv(NAMESPACE)), .metadata.name] |
      @tsv
    ' "${manifests[@]}" >>"$tmp/rendered-identities.txt"
    NAMESPACE="$namespace" yq e -r -N '
      select(.kind == "ExternalSecret") |
      [(.metadata.namespace // strenv(NAMESPACE)), .spec.target.name] |
      @tsv
    ' "${manifests[@]}" >>"$tmp/external-secret-targets.txt"
  done
}

record_aggregate_identities
[ -z "$(LC_ALL=C sort "$tmp/rendered-identities.txt" | uniq -d)" ] || {
  echo "happy-path releases contain duplicate rendered resource identity" >&2
  exit 1
}
[ -z "$(LC_ALL=C sort "$tmp/external-secret-targets.txt" | uniq -d)" ] || {
  echo "happy-path releases contain duplicate namespace-scoped ExternalSecret target" >&2
  exit 1
}
mapfile -t cuty_load_balancer_ips < <(
  find "$ROOT/releases/cuty/rgw-analysis-web/karmada" -type f \
    \( -name '*.yaml' -o -name '*.yml' \) -print0 |
    LC_ALL=C sort -z |
    xargs -0 -r yq e -r -N '
      select(.kind == "OverridePolicy") |
      .spec.overrideRules[].overriders.plaintext[]? |
      select(.path == "/metadata/annotations/lbipam.cilium.io~1ips") |
      .value
    ' | sed '/^[[:space:]]*$/d'
)
if printf '%s\n' "${cuty_load_balancer_ips[@]}" | grep -Fxq '10.33.142.20'; then
  echo "Cuty release reuses the POC explicit LoadBalancer IP" >&2
  exit 1
fi

make_case() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT/bootstrap" "$ROOT/contracts" "$ROOT/releases" "$ROOT/scripts" "$target/"
}

set_unexpected_release() {
  local target="$1"
  mkdir -p "$target/releases/extra/unexpected"
  cp "$target/releases/poc/rgw-analysis-web/release.yaml" \
    "$target/releases/extra/unexpected/release.yaml"
}

set_release_revision() {
  local target="$1"
  local environment="$2"
  local revision="$3"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' \
    "$target/releases/$environment/rgw-analysis-web/release.yaml"
}

validate_case() {
  local target="$1"
  "$target/scripts/validate.sh"
}

expect_reject() {
  local name="$1"
  local expected="$2"
  local target="$tmp/$name"
  shift 2
  make_case "$target"
  "$@" "$target"
  if validate_case "$target" >"$tmp/$name.log" 2>&1; then
    echo "expected multi-release rejection: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$name.log" || {
    echo "wrong multi-release failure: $name" >&2
    cat "$tmp/$name.log" >&2
    exit 1
  }
}

set_duplicate_namespace() {
  yq -i '.namespace = "scalex-rgw-analysis-web"' "$1/releases/cuty/rgw-analysis-web/release.yaml"
}

set_descriptor_environment_mismatch() {
  yq -i '.environment = "poc"' "$1/releases/cuty/rgw-analysis-web/release.yaml"
}

set_duplicate_load_balancer_ip() {
  local legacy_ip cuty_override candidate
  local -a legacy_ips
  mapfile -t legacy_ips < <(
    find "$1/releases/poc/rgw-analysis-web/karmada" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 |
      LC_ALL=C sort -z |
      xargs -0 yq e -r -N '
        select(.kind == "OverridePolicy") |
        .spec.overrideRules[].overriders.plaintext[]? |
        select(.path == "/metadata/annotations/lbipam.cilium.io~1ips") |
        .value
      ' | sed '/^[[:space:]]*$/d'
  )
  [ "${#legacy_ips[@]}" -eq 1 ] || {
    echo "legacy release must declare exactly one explicit LoadBalancer IP" >&2
    exit 1
  }
  legacy_ip="${legacy_ips[0]}"
  cuty_override=""
  while IFS= read -r candidate; do
    if yq e -e '
      select(.kind == "OverridePolicy") |
      .spec.resourceSelectors[]? |
      select(.apiVersion == "v1" and .kind == "Service")
    ' "$candidate" >/dev/null; then
      cuty_override="$candidate"
      break
    fi
  done < <(
    find "$1/releases/cuty/rgw-analysis-web/karmada" -type f \
      \( -name '*.yaml' -o -name '*.yml' \) | LC_ALL=C sort
  )
  test -n "$cuty_override" || {
    echo "Smurf release has no Service OverridePolicy" >&2
    exit 1
  }
  VALUE="$legacy_ip" yq -i '
    .spec.overrideRules[0].overriders.plaintext += [{
      "path": "/metadata/annotations/lbipam.cilium.io~1ips",
      "operator": "add",
      "value": strenv(VALUE)
    }]
  ' "$cuty_override"
}

pass="$tmp/pass"
make_case "$pass"
if ! validate_case "$pass" >"$tmp/pass.log" 2>&1; then
  cat "$tmp/pass.log" >&2
  exit 1
fi
grep -Fq 'federation validation passed' "$tmp/pass.log" || {
  echo "multi-release validation produced misleading success output" >&2
  exit 1
}
echo "validated multi-release happy path"

unexpected_inventory="$tmp/unexpected-inventory"
make_case "$unexpected_inventory"
set_unexpected_release "$unexpected_inventory"
if assert_exact_release_inventory "$unexpected_inventory" "$EXPECTED" \
  "$tmp/unexpected-inventory-evidence" >"$tmp/unexpected-inventory.log" 2>&1; then
  echo "unexpected active release descriptor escaped the exact inventory contract" >&2
  exit 1
fi
grep -Fq 'unexpected active descriptor: releases/extra/unexpected/release.yaml' \
  "$tmp/unexpected-inventory.log" || {
  cat "$tmp/unexpected-inventory.log" >&2
  exit 1
}
echo "validated unexpected active descriptor rejection"

cuty_revision_case="$tmp/cuty-revision-change"
make_case "$cuty_revision_case"
set_release_revision "$cuty_revision_case" cuty 1111111111111111111111111111111111111111
assert_expected_release_contract "$cuty_revision_case" "$EXPECTED" || {
  echo "valid Cuty full-SHA promotion was blocked by stable inventory identity" >&2
  exit 1
}
echo "validated mutable Cuty full-SHA inventory contract"

poc_revision_case="$tmp/poc-revision-drift"
make_case "$poc_revision_case"
set_release_revision "$poc_revision_case" poc 1111111111111111111111111111111111111111
if assert_expected_release_contract "$poc_revision_case" "$EXPECTED" \
  >"$tmp/poc-revision-drift.log" 2>&1; then
  echo "POC baseline pin drift escaped the inventory contract" >&2
  exit 1
fi
grep -Fq 'unexpected child revision pin: releases/poc/rgw-analysis-web/release.yaml' \
  "$tmp/poc-revision-drift.log" || {
  cat "$tmp/poc-revision-drift.log" >&2
  exit 1
}
echo "validated fixed POC revision rejection"

expect_reject duplicate-namespace 'duplicate release namespace' set_duplicate_namespace
echo "validated duplicate namespace rejection"
expect_reject descriptor-environment-mismatch 'release environment must match its directory' set_descriptor_environment_mismatch
echo "validated descriptor directory mismatch rejection"
expect_reject duplicate-load-balancer-ip 'duplicate explicit LoadBalancer IP' set_duplicate_load_balancer_ip

echo "multi-release coexistence contract tests passed"
