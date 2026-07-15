#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="${CATALOG:-$ROOT/values.yaml}"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

validate_policy_coverage() {
  local render="$1" namespace="$2" release="$3"

  yq e -o=json -I=0 '.' "$render" | jq -s -e --arg namespace "$namespace" '
    def requirement_matches($labels; $requirement):
      ($requirement.key // "") as $key |
      ($requirement.operator // "") as $operator |
      ($requirement.values // []) as $values |
      if $operator == "In" then
        ($labels | has($key)) and (($values | index($labels[$key])) != null)
      elif $operator == "NotIn" then
        ($labels | has($key)) and (($values | index($labels[$key])) == null)
      elif $operator == "Exists" then
        $labels | has($key)
      elif $operator == "DoesNotExist" then
        ($labels | has($key)) | not
      else
        false
      end;
    def label_selector_matches($labels; $selector):
      all((($selector.matchLabels // {}) | to_entries[]);
        . as $entry | ($labels[$entry.key] // null) == $entry.value
      ) and
      all(($selector.matchExpressions // [])[];
        . as $requirement | requirement_matches($labels; $requirement)
      );
    def selector_matches($resource; $selector; $policy_namespace; $default_namespace):
      (($selector.apiVersion // "") == ($resource.apiVersion // "")) and
      (($selector.kind // "") == ($resource.kind // "")) and
      (($selector.namespace // $policy_namespace) == ($resource.metadata.namespace // $default_namespace)) and
      (($selector.name // "") == "" or $selector.name == ($resource.metadata.name // "")) and
      label_selector_matches(($resource.metadata.labels // {}); ($selector.labelSelector // {}));

    [ .[] | select(. != null) ] as $documents |
    [ $documents[] | select(.kind != "PropagationPolicy" and .kind != "OverridePolicy") ] as $resources |
    [ $documents[] | select(.kind == "PropagationPolicy") ] as $propagations |
    [ $documents[] | select(.kind == "OverridePolicy") ] as $overrides |
    ($propagations | length) > 0 and
    all($propagations[];
      ((.spec.resourceSelectors // []) | length) > 0 and
      ((.spec.resourceSelectors | map(tojson) | length) == (.spec.resourceSelectors | map(tojson) | unique | length))
    ) and
    all($overrides[];
      ((.spec.resourceSelectors // []) | length) > 0 and
      ((.spec.resourceSelectors | map(tojson) | length) == (.spec.resourceSelectors | map(tojson) | unique | length))
    ) and
    all($resources[];
      . as $resource |
      ([
        $propagations[] as $policy |
        ($policy.spec.resourceSelectors // [])[] as $selector |
        select(selector_matches(
          $resource;
          $selector;
          ($policy.metadata.namespace // $namespace);
          $namespace
        )) |
        ($policy.metadata.name // "")
      ] | unique | length) == 1
    ) and
    all($propagations[];
      . as $policy |
      all(($policy.spec.resourceSelectors // [])[];
        . as $selector |
        any($resources[];
          selector_matches(
            .;
            $selector;
            ($policy.metadata.namespace // $namespace);
            $namespace
          )
        )
      )
    ) and
    all($overrides[];
      . as $policy |
      all(($policy.spec.resourceSelectors // [])[];
        . as $selector |
        any($resources[];
          selector_matches(
            .;
            $selector;
            ($policy.metadata.namespace // $namespace);
            $namespace
          )
        )
      )
    )
  ' >/dev/null || fail "Karmada policy selector coverage failed: $release"
}

validate_namespaced_rbac() {
  local render="$1" namespace="$2" release="$3"

  yq e -o=json -I=0 '.' "$render" | jq -s -e --arg namespace "$namespace" '
    [ .[] | select(. != null) ] as $documents |
    all($documents[] | select(.kind == "RoleBinding");
      . as $binding |
      $binding.roleRef.apiGroup == "rbac.authorization.k8s.io" and
      $binding.roleRef.kind == "Role" and
      any($documents[];
        .kind == "Role" and
        .metadata.name == $binding.roleRef.name and
        (.metadata.namespace // $namespace) == ($binding.metadata.namespace // $namespace)
      ) and
      all(($binding.subjects // [])[];
        .kind != "ServiceAccount" or
        (.namespace // ($binding.metadata.namespace // $namespace)) == $namespace
      )
    )
  ' >/dev/null || fail "namespaced RBAC must bind local Roles and stay in the release namespace: $release"
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

for tool in git helm jq tar yq; do
  require "$tool"
done

resolve_feature_root() {
  if [ -n "$FEATURE_REPOS_ROOT" ]; then
    printf '%s\n' "$FEATURE_REPOS_ROOT"
    return
  fi
  for candidate in \
    "$(dirname "$ROOT")" \
    "$(dirname "$(dirname "$ROOT")")/work" \
    "/home/joon/study/scalex/work"; do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf '%s\n' "$(dirname "$ROOT")"
}

relative_path() {
  local value="$1" field="$2"
  [ -n "$value" ] || fail "$field cannot be empty"
  case "$value" in
    /*|.*|*'..'*|*'//'*) fail "$field must be a simple relative path: $value" ;;
  esac
}

k8s_name_re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
revision_re='^[0-9a-f]{40}$'
feature_root="$(resolve_feature_root)"

for manifest in "$ROOT/bootstrap/appproject.yaml" "$ROOT/bootstrap/applicationset.yaml" "$CATALOG"; do
  test -f "$manifest" || fail "missing required manifest: ${manifest#"$ROOT"/}"
  yq e '.' "$manifest" >/dev/null
  test ! -L "$manifest" || fail "manifest cannot be a symlink: ${manifest#"$ROOT"/}"
done

[ ! -e "$ROOT/releases" ] || fail "single-values experiment must not contain a releases directory"
[ "$CATALOG" = "$ROOT/values.yaml" ] || fail "single-values experiment requires the root values.yaml catalog"

[ "$(yq e -r '.apiVersion' "$CATALOG")" = scalex.io/v1alpha1 ] || fail "unsupported catalog apiVersion"
[ "$(yq e -r '.kind' "$CATALOG")" = FederationReleaseCatalog ] || fail "unsupported catalog kind"
yq e -e '(.releases | type) == "!!seq" and (.releases | length) > 0' "$CATALOG" >/dev/null || \
  fail "catalog releases must be a non-empty sequence"

mapfile -t bootstrap_manifests < <(find "$ROOT/bootstrap" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
[ "${#bootstrap_manifests[@]}" -eq 2 ] || fail "bootstrap may contain only appproject and applicationset"
[ "$(yq e -r '[.kind, .metadata.name] | @tsv' "$ROOT/bootstrap/appproject.yaml")" = $'AppProject\tscalex-federation' ] || \
  fail "invalid AppProject identity"
[ "$(yq e -r '[.kind, .metadata.name] | @tsv' "$ROOT/bootstrap/applicationset.yaml")" = $'ApplicationSet\tscalex-federation-releases' ] || \
  fail "invalid ApplicationSet identity"

yq e -e '
  .spec.goTemplate == true and
  (.spec.generators | length) == 1 and
  .spec.generators[0].matrix.generators[0].git.repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.generators[0].matrix.generators[0].git.revision == "experiment/single-values-catalog" and
  .spec.generators[0].matrix.generators[0].git.files[0].path == "values.yaml" and
  .spec.generators[0].matrix.generators[1].list.elementsYaml == "{{ .releases | toJson }}" and
  .spec.generators[0].selector.matchLabels.state == "active" and
  .spec.template.spec.source.repoURL == "{{ .source.repoURL }}" and
  .spec.template.spec.source.targetRevision == "{{ .source.revision }}" and
  .spec.template.spec.source.path == "{{ .source.path }}" and
  .spec.template.spec.source.helm.releaseName == "{{ .helm.releaseName }}" and
  .spec.template.spec.source.helm.values == "{{ .helm.values }}" and
  .spec.template.spec.destination.name == "{{ .destination.name }}" and
  .spec.template.spec.destination.namespace == "{{ .namespace }}" and
  (.spec.template.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"])) and
  (.spec.template.spec.sources == null)
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null || fail "ApplicationSet must use native matrix git/list catalog wiring with active-state selector"

yq e -e '
  (.spec.destinations | length) == 1 and
  .spec.destinations[0].name == "karmada" and
  .spec.destinations[0].namespace == "scalex-*" and
  (.spec.sourceRepos | contains(["https://github.com/SJoon99/scalex-feature-poc.git"])) and
  (.spec.clusterResourceWhitelist | length) == 1 and
  .spec.clusterResourceWhitelist[0].group == "" and
  .spec.clusterResourceWhitelist[0].kind == "Namespace" and
  ([.spec.namespaceResourceWhitelist[] | select(.group == "objectbucket.io" or .group == "work.karmada.io" or ((.kind // "") | test("^Cluster")))] | length) == 0 and
  ([.spec.namespaceResourceWhitelist[] | select(.group == "policy.karmada.io" and (.kind == "PropagationPolicy" or .kind == "OverridePolicy"))] | length) == 2
' "$ROOT/bootstrap/appproject.yaml" >/dev/null || fail "AppProject must keep only core Namespace plus namespaced workload and Karmada policy permissions"
if yq e -r '.spec.sourceRepos[]' "$ROOT/bootstrap/appproject.yaml" | \
    grep -Ev '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$' >/dev/null; then
  fail "AppProject sourceRepos must contain exact GitHub repository URLs"
fi

: >"$tmp/apps.txt"
: >"$tmp/active-apps.txt"
: >"$tmp/namespaces.txt"
: >"$tmp/rendered-identities.txt"

release_count="$(yq e '.releases | length' "$CATALOG")"
for ((i = 0; i < release_count; i++)); do
  prefix=".releases[$i]"
  environment="$(yq e -r "$prefix.environment" "$CATALOG")"
  name="$(yq e -r "$prefix.name" "$CATALOG")"
  namespace="$(yq e -r "$prefix.namespace" "$CATALOG")"
  state="$(yq e -r "$prefix.state" "$CATALOG")"
  destination="$(yq e -r "$prefix.destination.name" "$CATALOG")"
  repo_url="$(yq e -r "$prefix.source.repoURL" "$CATALOG")"
  chart_path="$(yq e -r "$prefix.source.path" "$CATALOG")"
  revision="$(yq e -r "$prefix.source.revision" "$CATALOG")"
  release_name="$(yq e -r "$prefix.helm.releaseName" "$CATALOG")"
  values_file="$tmp/values-$i.yaml"
  yq e -r "$prefix.helm.values" "$CATALOG" >"$values_file"

  [[ "$environment" =~ $k8s_name_re ]] || fail "invalid release environment: $environment"
  [[ "$name" =~ $k8s_name_re ]] || fail "invalid release name: $name"
  [[ "$namespace" =~ ^scalex-[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid release namespace: $namespace"
  case "$state" in active|disabled) ;; *) fail "release state must be active or disabled: $environment/$name" ;; esac
  [ "$destination" = karmada ] || fail "release destination must be karmada: $environment/$name"
  [[ "$repo_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || fail "invalid source repoURL: $repo_url"
  if ! [[ "$revision" =~ $revision_re ]] || \
      [ "$revision" = 0000000000000000000000000000000000000000 ]; then
    fail "source revision must be an immutable full SHA: $environment/$name"
  fi
  relative_path "$chart_path" source.path
  [ "$release_name" = "$name" ] || fail "helm.releaseName must match release name: $environment/$name"
  yq e '.' "$values_file" >/dev/null || fail "helm values are not YAML: $environment/$name"

  printf 'federation-%s-%s\n' "$environment" "$name" >>"$tmp/apps.txt"
  if [ "$state" = active ]; then
    printf 'federation-%s-%s\n' "$environment" "$name" >>"$tmp/active-apps.txt"
  fi
  printf '%s\n' "$namespace" >>"$tmp/namespaces.txt"

  yq e -e '.. | select(tag == "!!map" and (.kind == "Secret" or .kind == "ExternalSecret" or .kind == "ObjectBucketClaim" or .kind == "ResourceBinding" or .kind == "ClusterResourceBinding"))' "$CATALOG" >/dev/null 2>&1 && \
    fail "catalog must not inline dependency or Secret resources"
  if yq e -e '.releases[] | select(has("featureChartContract") or has("placement") or has("overrides") or has("dependencies"))' "$CATALOG" >/dev/null 2>&1; then
    fail "catalog must not retain Federation-owned policy or dependency contract blocks"
  fi
  if yq e -r '.. | select(tag == "!!map") | keys | .[]' "$values_file" "$CATALOG" | \
      grep -Eix '(password|passwd|token|accessKeyId|secretAccessKey|stringData)' >/dev/null; then
    fail "catalog appears to contain inline secret-shaped fields"
  fi

  REPO_URL="$repo_url" yq e -e '.spec.sourceRepos[] == strenv(REPO_URL)' \
    "$ROOT/bootstrap/appproject.yaml" >/dev/null || \
    fail "source is not allowed by AppProject: $repo_url"
  repo_name="$(basename "${repo_url%.git}")"
  feature_repo="$feature_root/$repo_name"
  git -C "$feature_repo" rev-parse --is-inside-work-tree >/dev/null || fail "feature repository not found: $feature_repo"
  origin="$(git -C "$feature_repo" remote get-url origin)"
  case "$origin" in
    git@github.com:*) origin="https://github.com/${origin#git@github.com:}" ;;
    ssh://git@github.com/*) origin="https://github.com/${origin#ssh://git@github.com/}" ;;
  esac
  [ "$origin" = "$repo_url" ] || fail "feature origin does not match catalog: $feature_repo"
  [ "$(git -C "$feature_repo" rev-parse "$revision^{commit}")" = "$revision" ] || \
    fail "source revision did not resolve exactly: $environment/$name"
  git -C "$feature_repo" cat-file -e "$revision:$chart_path/Chart.yaml" 2>/dev/null || fail "chart path absent at pinned revision"
  if git -C "$feature_repo" ls-tree -r "$revision" -- "$chart_path" | awk '$1 == "120000" || $1 == "160000" {found=1} END {exit !found}'; then
    fail "chart tree contains a symlink or submodule: $environment/$name"
  fi
  chart_export="$tmp/source-$i"
  mkdir -p "$chart_export"
  git -C "$feature_repo" archive "$revision" "$chart_path" | tar -x -C "$chart_export"
  chart_dir="$chart_export/$chart_path"
  helm lint "$chart_dir" -f "$values_file" >/dev/null
  render="$tmp/render-$i.yaml"
  helm template "$release_name" "$chart_dir" --namespace "$namespace" -f "$values_file" >"$render"
  [ -s "$render" ] || fail "helm rendered no resources: $environment/$name"
  yq e -e 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")' \
    "$render" >/dev/null 2>&1 || fail "feature chart rendered no workload: $environment/$name"
  if yq e -e '
    select(
      .kind == "Secret" or
      .kind == "ExternalSecret" or
      .kind == "ObjectBucketClaim" or
      .kind == "PersistentVolumeClaim" or
      .kind == "Namespace" or
      .kind == "CustomResourceDefinition" or
      .kind == "ClusterRole" or
      .kind == "ClusterRoleBinding" or
      .kind == "StorageClass" or
      .kind == "ClusterPropagationPolicy" or
      .kind == "ClusterOverridePolicy"
    )
  ' "$render" >/dev/null 2>&1; then
    fail "feature chart rendered an Infra dependency or cluster-scoped resource: $environment/$name"
  fi
  NAMESPACE="$namespace" yq e -e '
    select(.metadata.namespace != null and .metadata.namespace != strenv(NAMESPACE))
  ' "$render" >/dev/null 2>&1 && fail "feature chart escaped its release namespace: $environment/$name"
  NAMESPACE="$namespace" yq e -e '
    select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
    .spec.resourceSelectors[]? |
    select(.namespace != null and .namespace != strenv(NAMESPACE))
  ' "$render" >/dev/null 2>&1 && fail "Karmada policy selector escaped its release namespace: $environment/$name"
  validate_namespaced_rbac "$render" "$namespace" "$environment/$name"
  mapfile -t rendered_images < <(yq e -r -N '.. | select(tag == "!!map") | (.containers[]?.image, .initContainers[]?.image) | select(. != null)' "$render" | sort -u)
  [ "${#rendered_images[@]}" -gt 0 ] || fail "chart renders no images: $environment/$name"
  for image in "${rendered_images[@]}"; do
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || fail "rendered image lacks digest: $image"
    [[ "$image" != *:latest@* ]] || fail "rendered latest image is forbidden: $image"
  done

  NAMESPACE="$namespace" yq e -r -N 'select(. != null) | [.apiVersion, .kind, (.metadata.namespace // strenv(NAMESPACE)), .metadata.name] | @tsv' "$render" | sort >>"$tmp/rendered-identities.txt"

  propagation_count="$(yq e -r -N 'select(.kind == "PropagationPolicy") | .kind' "$render" | wc -l | tr -d ' ')"
  if [ "$state" = active ] && [ "$propagation_count" -eq 0 ]; then
    fail "active release chart must render at least one PropagationPolicy: $environment/$name"
  fi
  if [ "$propagation_count" -gt 0 ]; then
    validate_policy_coverage "$render" "$namespace" "$environment/$name"
  fi
  if [ "$state" = disabled ] && [ "$propagation_count" -eq 0 ]; then
    echo "warning: disabled $environment/$name renders no PropagationPolicy and is filtered out of ApplicationSet generation" >&2
  fi
done

[ -z "$(sort "$tmp/apps.txt" | uniq -d)" ] || fail "duplicate release identity"
[ -z "$(sort "$tmp/active-apps.txt" | uniq -d)" ] || fail "duplicate generated Application identity"
[ -z "$(sort "$tmp/namespaces.txt" | uniq -d)" ] || fail "duplicate release namespace"
[ -z "$(sort "$tmp/rendered-identities.txt" | uniq -d)" ] || fail "duplicate rendered resource identity"

if git grep -InE '(BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|aws_secret_access_key[[:space:]]*=|AWS_SECRET_ACCESS_KEY[[:space:]]*:)' -- ':!tests/fixtures' >/dev/null; then
  fail "credential-like payload found"
fi

echo "single-catalog federation validation passed"
