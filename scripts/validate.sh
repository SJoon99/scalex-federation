#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"
VALIDATE_BASE_REF="${VALIDATE_BASE_REF:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require git
require helm
require tar
require yq

if [ -n "$VALIDATE_BASE_REF" ]; then
  git -C "$ROOT" rev-parse --verify "${VALIDATE_BASE_REF}^{commit}" >/dev/null ||
    fail "validation base ref is not a commit: $VALIDATE_BASE_REF"
fi

bootstrap_files=(
  "$ROOT/bootstrap/appproject.yaml"
  "$ROOT/bootstrap/applicationset.yaml"
)

for manifest in "${bootstrap_files[@]}"; do
  test -f "$manifest" || fail "missing bootstrap manifest: $manifest"
  yq e '.' "$manifest" >/dev/null
done

mapfile -t appproject_resources < <(
  yq e -r -N '
    select(. != null) | [.kind, .metadata.name] | @tsv
  ' "$ROOT/bootstrap/appproject.yaml"
)
if [ "${#appproject_resources[@]}" -ne 1 ] ||
  [ "${appproject_resources[0]}" != $'AppProject\tscalex-federation' ]; then
  fail "appproject.yaml must contain only AppProject/scalex-federation"
fi

mapfile -t applicationset_resources < <(
  yq e -r -N '
    select(. != null) | [.kind, .metadata.name] | @tsv
  ' "$ROOT/bootstrap/applicationset.yaml"
)
if [ "${#applicationset_resources[@]}" -ne 1 ] ||
  [ "${applicationset_resources[0]}" != $'ApplicationSet\tscalex-federation-releases' ]; then
  fail "applicationset.yaml must contain only ApplicationSet/scalex-federation-releases"
fi

mapfile -t bootstrap_manifests < <(
  find "$ROOT/bootstrap" -maxdepth 1 -type f \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort
)
[ "${#bootstrap_manifests[@]}" -eq "${#bootstrap_files[@]}" ] ||
  fail "bootstrap may contain only appproject.yaml and applicationset.yaml"

yq ea '.' "${bootstrap_files[@]}" > "$tmp/bootstrap.yaml"

for binding in ResourceBinding ClusterResourceBinding; do
  BINDING="$binding" yq e -e '
    select(.kind == "AppProject" and .metadata.name == "scalex-federation") |
    (
      .spec.namespaceResourceWhitelist[]?,
      .spec.clusterResourceWhitelist[]?
    ) |
    select(.group == "work.karmada.io" and .kind == strenv(BINDING))
  ' "$tmp/bootstrap.yaml" >/dev/null ||
    fail "AppProject must expose Karmada child resource: $binding"
done

yq e -e '.spec.template.spec.destination.name == "karmada"' \
  "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "Federation ApplicationSet must target the Karmada destination"

yq e -e '
  .spec.template.spec.sources[] |
  select(.ref == "federation") |
  select(.path == "{{ .policy.path }}") |
  select(.directory.recurse == true)
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "Federation policy source must recursively read policy.path"

yq e -e '
  .spec.template.spec.sources[] |
  select(.helm != null) |
  .helm.valueFiles[] == "$federation/{{ .valuesFile }}"
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "feature chart must consume values from the Federation source"

mapfile -t descriptors < <(
  find "$ROOT/releases" -mindepth 3 -maxdepth 3 -name release.yaml -type f | sort
)
[ "${#descriptors[@]}" -gt 0 ] || fail "no release descriptors found"

for descriptor in "${descriptors[@]}"; do
  yq e '.' "$descriptor" >/dev/null

  release_dir="$(dirname "$descriptor")"
  release_rel="${release_dir#"$ROOT"/}"
  descriptor_rel="${descriptor#"$ROOT"/}"
  expected_environment="$(basename "$(dirname "$release_dir")")"
  expected_name="$(basename "$release_dir")"

  name="$(yq -r '.name' "$descriptor")"
  environment="$(yq -r '.environment' "$descriptor")"
  namespace="$(yq -r '.namespace' "$descriptor")"
  chart_repo_url="$(yq -r '.chart.repoURL' "$descriptor")"
  chart_path="$(yq -r '.chart.path' "$descriptor")"
  revision="$(yq -r '.chart.revision' "$descriptor")"
  values_rel="$(yq -r '.valuesFile' "$descriptor")"
  policy_rel="$(yq -r '.policy.path' "$descriptor")"

  for value in \
    "$name" "$environment" "$namespace" "$chart_repo_url" "$chart_path" \
    "$revision" "$values_rel" "$policy_rel"; do
    [ -n "$value" ] && [ "$value" != null ] ||
      fail "missing release descriptor field: $descriptor"
  done

  [ "$name" = "$expected_name" ] ||
    fail "release name must match its directory: $descriptor"
  [ "$environment" = "$expected_environment" ] ||
    fail "release environment must match its directory: $descriptor"
  [[ "$namespace" == scalex-* ]] ||
    fail "release namespace must use the scalex- prefix: $descriptor"
  [[ "$chart_repo_url" == https://github.com/SJoon99/scalex-feature-*.git ]] ||
    fail "feature repository is outside the AppProject source allowlist: $descriptor"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] ||
    fail "feature revision must be a full immutable commit SHA: $descriptor"
  [ "$values_rel" = "$release_rel/values.yaml" ] ||
    fail "valuesFile must be $release_rel/values.yaml"
  [ "$policy_rel" = "$release_rel/karmada" ] ||
    fail "policy.path must be $release_rel/karmada"
  yq e -e '.policy | has("renderer") | not' "$descriptor" >/dev/null ||
    fail "policy.renderer is obsolete; policies are always plain recursive YAML: $descriptor"

  values_file="$ROOT/$values_rel"
  policy_root="$ROOT/$policy_rel"
  test -f "$values_file" || fail "release values not found: $values_rel"
  test -d "$policy_root" || fail "release policy directory not found: $policy_rel"
  yq e '.' "$values_file" >/dev/null

  yq e -e '(.images | type) == "!!map" and (.images | length) > 0' \
    "$values_file" >/dev/null ||
    fail "release values must declare at least one image: $values_rel"

  while IFS=$'\t' read -r component repository tag digest pull_policy; do
    [ -n "$component" ] || fail "image component name is empty: $values_rel"
    [ -n "$repository" ] || fail "image repository is empty for $component: $values_rel"
    [ -n "$tag" ] && [ "$tag" != latest ] ||
      fail "image tag must be explicit and non-latest for $component: $values_rel"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
      fail "image digest must be immutable for $component: $values_rel"
    case "$pull_policy" in
      Always | IfNotPresent | Never) ;;
      *) fail "invalid image pullPolicy for $component: $values_rel" ;;
    esac
  done < <(
    yq -r '
      .images | to_entries[] |
      [
        .key,
        (.value.repository // ""),
        (.value.tag // ""),
        (.value.digest // ""),
        (.value.pullPolicy // "")
      ] | @tsv
    ' "$values_file"
  )

  if [ -n "$VALIDATE_BASE_REF" ] &&
    git -C "$ROOT" ls-tree -r --name-only "$VALIDATE_BASE_REF" -- "$descriptor_rel" |
      grep -Fxq "$descriptor_rel"; then
    previous_revision="$(
      git -C "$ROOT" show "$VALIDATE_BASE_REF:$descriptor_rel" |
        yq -r '.chart.revision'
    )"
    previous_images="$(
      git -C "$ROOT" show "$VALIDATE_BASE_REF:$values_rel" |
        yq -o=json -I=0 '.images // {}'
    )"
    current_images="$(yq -o=json -I=0 '.images // {}' "$values_file")"

    if [ "$previous_images" != "$current_images" ] &&
      [ "$previous_revision" = "$revision" ]; then
      fail "image promotion must update chart.revision in the same change: $release_rel"
    fi
  fi

  if find "$policy_root" -type f \
    \( -name 'kustomization.yaml' -o -name 'kustomization.yml' -o -name 'Kustomization' -o -name 'Chart.yaml' \) \
    -print -quit | grep -q .; then
    fail "policy path cannot contain Kustomize or Helm entrypoints: $policy_rel"
  fi
  if find "$policy_root" -type f -name '*.json' -print -quit | grep -q .; then
    fail "policy path supports YAML manifests only: $policy_rel"
  fi

  mapfile -t policy_files < <(
    find "$policy_root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort
  )
  [ "${#policy_files[@]}" -gt 0 ] || fail "policy path found no YAML: $policy_rel"

  policy_render="$tmp/${environment}-${name}-policies.yaml"
  yq ea '.' "${policy_files[@]}" > "$policy_render"

  for policy_file in "${policy_files[@]}"; do
    case "$policy_file" in
      "$policy_root"/propagation/*) expected_kind=PropagationPolicy ;;
      "$policy_root"/overrides/*) expected_kind=OverridePolicy ;;
      *) fail "policy YAML must be under propagation/ or overrides/: $policy_file" ;;
    esac

    mapfile -t policy_kinds < <(
      yq e -r -N 'select(. != null) | .kind // ""' "$policy_file"
    )
    [ "${#policy_kinds[@]}" -gt 0 ] ||
      fail "policy YAML contains no Kubernetes resource: $policy_file"
    for kind in "${policy_kinds[@]}"; do
      [ "$kind" = "$expected_kind" ] ||
        fail "$policy_file must contain only $expected_kind resources"
    done
  done

  while IFS=$'\t' read -r api_version kind resource_name resource_namespace; do
    [ -n "$api_version" ] && [ -n "$kind" ] && [ -n "$resource_name" ] ||
      fail "policy YAML must contain Kubernetes resources with apiVersion/kind/name: $policy_rel"
    [ "$resource_namespace" = "$namespace" ] ||
      fail "policy namespace must match release namespace: $kind/$resource_name"
  done < <(
    yq e -r -N '
      select(. != null) |
      [
        (.apiVersion // ""),
        (.kind // ""),
        (.metadata.name // ""),
        (.metadata.namespace // "")
      ] | @tsv
    ' "$policy_render"
  )

  duplicates="$(
    yq e -r -N '
      select(. != null) |
      [.apiVersion, .kind, .metadata.namespace, .metadata.name] | @tsv
    ' "$policy_render" | sort | uniq -d
  )"
  [ -z "$duplicates" ] || fail "duplicate policy resource identity:\n$duplicates"

  repo_name="$(basename "${chart_repo_url%.git}")"
  feature_repo="$FEATURE_REPOS_ROOT/$repo_name"
  git -C "$feature_repo" rev-parse --is-inside-work-tree >/dev/null ||
    fail "feature repository not found: $feature_repo (set FEATURE_REPOS_ROOT)"
  git -C "$feature_repo" cat-file -e "${revision}^{commit}" ||
    fail "feature commit is unavailable locally: $repo_name@$revision"

  chart_export="$tmp/sources/${environment}-${name}"
  mkdir -p "$chart_export"
  git -C "$feature_repo" archive "$revision" "$chart_path" |
    tar -x -C "$chart_export"
  chart_dir="$chart_export/$chart_path"
  test -f "$chart_dir/Chart.yaml" ||
    fail "chart not found at pinned revision: $repo_name@$revision/$chart_path"

  chart_render="$tmp/${environment}-${name}-chart.yaml"
  helm lint "$chart_dir" -f "$values_file"
  helm template "$name" "$chart_dir" \
    --namespace "$namespace" \
    -f "$values_file" > "$chart_render"

  mapfile -t rendered_images < <(
    yq e -r -N '
      .. | select(tag == "!!map") |
      (
        .containers[]?.image,
        .initContainers[]?.image,
        .ephemeralContainers[]?.image,
        .container?.image,
        .script?.image,
        .containerSet?.containers[]?.image,
        .steps[]?.image,
        .sidecars[]?.image
      ) |
      select(. != null)
    ' \
      "$chart_render" | sort -u
  )
  [ "${#rendered_images[@]}" -gt 0 ] ||
    fail "rendered chart contains no container images: $descriptor"
  for image in "${rendered_images[@]}"; do
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] ||
      fail "rendered image is not digest pinned: $image"
  done

  while IFS=$'\t' read -r api_version kind resource_name; do
    [ -n "$resource_name" ] || continue
    API_VERSION="$api_version" KIND="$kind" RESOURCE_NAME="$resource_name" \
      yq e -e '
        select(
          .apiVersion == strenv(API_VERSION) and
          .kind == strenv(KIND) and
          .metadata.name == strenv(RESOURCE_NAME)
        )
      ' "$chart_render" >/dev/null ||
      fail "policy selector has no rendered resource: $api_version $kind $resource_name"
  done < <(
    yq e -r -N '
      select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
      .spec.resourceSelectors[] |
      [.apiVersion, .kind, .name] | @tsv
    ' "$policy_render"
  )
done

mapfile -t federation_yaml < <(
  find "$ROOT/bootstrap" "$ROOT/releases" -type f \
    \( -name '*.yaml' -o -name '*.yml' \) | sort
)
for manifest in "${federation_yaml[@]}"; do
  yq e '.' "$manifest" >/dev/null
  secret_kinds="$(
    yq e -r -N 'select(.kind == "Secret") | .kind' "$manifest"
  )"
  if [ -n "$secret_kinds" ]; then
    fail "Kubernetes Secret resources are forbidden in Federation Git: $manifest"
  fi
done

echo "federation validation passed"
