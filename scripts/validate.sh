#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE_REPO="${FEATURE_REPO:-$(cd "$ROOT/../scalex-feature-poc" 2>/dev/null && pwd || true)}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

require helm
require kubectl
require yq

kubectl kustomize "$ROOT/bootstrap" > "$tmp/bootstrap.yaml"

mapfile -t descriptors < <(find "$ROOT/releases" -mindepth 3 -maxdepth 3 -name release.yaml -type f | sort)
if [ "${#descriptors[@]}" -eq 0 ]; then
  echo "no release descriptors found" >&2
  exit 1
fi

for descriptor in "${descriptors[@]}"; do
  release_dir="$(dirname "$descriptor")"
  name="$(yq -r '.name' "$descriptor")"
  namespace="$(yq -r '.namespace' "$descriptor")"
  revision="$(yq -r '.chart.revision' "$descriptor")"
  values_rel="$(yq -r '.valuesFile' "$descriptor")"
  policy_rel="$(yq -r '.policyPath' "$descriptor")"

  for value in "$name" "$namespace" "$revision" "$values_rel" "$policy_rel"; do
    if [ -z "$value" ] || [ "$value" = null ]; then
      echo "missing release descriptor field: $descriptor" >&2
      exit 1
    fi
  done
  if [ "$revision" = FEATURE_COMMIT_SHA ] || [ "$revision" = main ] || [ "$revision" = HEAD ]; then
    echo "feature revision must be an immutable commit: $descriptor" >&2
    exit 1
  fi
  test -f "$ROOT/$values_rel"
  test -f "$ROOT/$policy_rel/kustomization.yaml"

  policy_render="$tmp/${name}-policies.yaml"
  chart_render="$tmp/${name}-chart.yaml"
  kubectl kustomize "$ROOT/$policy_rel" > "$policy_render"

  if [ -z "$FEATURE_REPO" ] || [ ! -f "$FEATURE_REPO/chart/Chart.yaml" ]; then
    echo "feature repository not found; set FEATURE_REPO" >&2
    exit 1
  fi
  helm lint "$FEATURE_REPO/chart" -f "$ROOT/$values_rel"
  helm template "$name" "$FEATURE_REPO/chart" \
    --namespace "$namespace" \
    -f "$ROOT/$values_rel" > "$chart_render"

  while IFS=$'\t' read -r api_version kind resource_name; do
    [ -n "$resource_name" ] || continue
    API_VERSION="$api_version" KIND="$kind" RESOURCE_NAME="$resource_name" \
      yq ea -e '
        select(
          .apiVersion == strenv(API_VERSION) and
          .kind == strenv(KIND) and
          .metadata.name == strenv(RESOURCE_NAME)
        )
      ' "$chart_render" >/dev/null || {
        echo "policy selector has no rendered resource: $api_version $kind $resource_name" >&2
        exit 1
      }
  done < <(
    yq ea -r '
      select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
      .spec.resourceSelectors[] |
      [.apiVersion, .kind, .name] | @tsv
    ' "$policy_render"
  )
done

if rg -n --glob '*.y*ml' '^kind:[[:space:]]*Secret$|^[[:space:]]*(data|stringData):' \
  "$ROOT/bootstrap" "$ROOT/releases"; then
  echo "Secret values are forbidden in Federation Git" >&2
  exit 1
fi

if rg -n --glob '*.y*ml' 'destination:[[:space:]]*$' "$ROOT/bootstrap" >/dev/null; then
  if rg -n --glob '*.y*ml' '^[[:space:]]+name:[[:space:]]+(b|c)$' "$ROOT/bootstrap"; then
    echo "Federation Argo applications must target Karmada, not child clusters" >&2
    exit 1
  fi
fi

echo "federation validation passed"
