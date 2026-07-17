#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_atomic_promotions() {
  local base_ref="${VALIDATE_BASE_REF:-}"
  [ -n "$base_ref" ] || return 0
  [[ "$base_ref" =~ ^[0-9a-f]{40}$ ]] ||
    fail "VALIDATE_BASE_REF must be a full commit SHA"
  git -C "$ROOT" cat-file -e "$base_ref^{commit}" 2>/dev/null ||
    fail "VALIDATE_BASE_REF commit is unavailable: $base_ref"

  local descriptor release_path values_path mode revision old_revision
  local current_images old_images
  for descriptor in "${descriptors[@]}"; do
    mode="$(yq e -r '.promotion.mode' "$descriptor")"
    [ "$mode" = tracked ] || continue

    release_path="${descriptor#"$ROOT/"}"
    values_path="$(yq e -r '.values.path' "$descriptor")"
    revision="$(yq e -r '.source.revision' "$descriptor")"
    current_images="$(yq e -o=json -I=0 '.images // {}' "$ROOT/$values_path" | jq -S -c .)"

    if git -C "$ROOT" cat-file -e "$base_ref:$release_path" 2>/dev/null; then
      old_revision="$(git -C "$ROOT" show "$base_ref:$release_path" | yq e -r '.source.revision' -)"
    else
      old_revision=""
    fi
    if git -C "$ROOT" cat-file -e "$base_ref:$values_path" 2>/dev/null; then
      old_images="$(git -C "$ROOT" show "$base_ref:$values_path" |
        yq e -o=json -I=0 '.images // {}' - | jq -S -c .)"
    else
      old_images='{}'
    fi

    if [ "$revision" != "$old_revision" ]; then
      git -C "$ROOT" diff --quiet "$base_ref" -- "$values_path" &&
        fail "tracked promotion must update release and image values together: $release_path"
      REVISION="$revision" yq e -o=json -I=0 '.images // {}' "$ROOT/$values_path" | jq -e '
        length > 0 and
        all(.[];
          .tag == ("sha-" + env.REVISION) and
          .sourceRevision == env.REVISION and
          (.digest | test("^sha256:[0-9a-f]{64}$"))
        )
      ' >/dev/null || fail "tracked promotion image metadata must match source revision: $values_path"
    elif [ "$current_images" != "$old_images" ]; then
      fail "tracked image metadata cannot change without the source revision: $values_path"
    fi
  done
}

normalize_github_url() {
  case "$1" in
    git@github.com:*) printf 'https://github.com/%s\n' "${1#git@github.com:}" ;;
    https://github.com/*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
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

for tool in check-jsonschema git helm jq tar yq; do
  require "$tool"
done

source "$ROOT/scripts/lib/release-contract.sh"
jq empty "$ROOT/contracts/federation-release-v1alpha1.schema.json"
mapfile -t descriptors < <(find "$ROOT/releases" -mindepth 2 -maxdepth 2 -name release.yaml -type f | sort)
[ "${#descriptors[@]}" -gt 0 ] || fail "no release descriptors found"
"$ROOT/scripts/lib/validate-release-schema.sh" "${descriptors[@]}"
validate_atomic_promotions

for manifest in "$ROOT/bootstrap/appproject.yaml" "$ROOT/bootstrap/applicationset.yaml"; do
  yq e '.' "$manifest" >/dev/null || fail "invalid bootstrap manifest: ${manifest#"$ROOT/"}"
done

yq e -e '
  (.spec.generators | length) == 1 and
  .spec.generators[0].git.repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.generators[0].git.revision == "main" and
  (.spec.generators[0].git.files | length) == 1 and
  .spec.generators[0].git.files[0].path == "releases/*/release.yaml" and
  .spec.generators[0].selector.matchLabels.state == "active"
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "ApplicationSet release discovery contract drifted"

FEDERATION_VALUE_FILE='$federation/{{ .values.path }}' yq e -e '
  .spec.template.metadata.name == "federation-{{ .name }}" and
  (.spec.template.spec.sources | length) == 2 and
  .spec.template.spec.sources[0].repoURL == "{{ .source.repoURL }}" and
  .spec.template.spec.sources[0].targetRevision == "{{ .source.revision }}" and
  .spec.template.spec.sources[0].path == "{{ .source.path }}" and
  .spec.template.spec.sources[0].helm.releaseName == "{{ .name }}" and
  .spec.template.spec.sources[0].helm.valueFiles[0] == strenv(FEDERATION_VALUE_FILE) and
  .spec.template.spec.sources[1].repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.template.spec.sources[1].targetRevision == "main" and
  .spec.template.spec.sources[1].ref == "federation" and
  (.spec.template.spec.sources[1] | has("path") | not) and
  .spec.template.spec.destination.name == "karmada" and
  .spec.template.spec.destination.namespace == "{{ .namespace }}" and
  .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels."namespace.karmada.io/skip-auto-propagation" == "true" and
  (.spec.template.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]))
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "ApplicationSet source, destination, or namespace ownership contract drifted"

yq e -e '
  (.spec.destinations | length) == 1 and
  .spec.destinations[0].name == "karmada" and
  .spec.destinations[0].namespace == "scalex-*"
' "$ROOT/bootstrap/appproject.yaml" >/dev/null ||
  fail "AppProject destination must be the Karmada ScaleX boundary"

if yq e -r '.spec.sourceRepos[]' "$ROOT/bootstrap/appproject.yaml" |
    grep -Ev '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$' >/dev/null; then
  fail "AppProject sourceRepos must contain exact GitHub repository URLs"
fi
for binding in ResourceBinding ClusterResourceBinding; do
  BINDING="$binding" yq e -e '
    (.spec.namespaceResourceWhitelist[]?, .spec.clusterResourceWhitelist[]?) |
    select(.group == "work.karmada.io" and .kind == strenv(BINDING))
  ' "$ROOT/bootstrap/appproject.yaml" >/dev/null ||
    fail "AppProject must preserve Karmada $binding observation"
done
for kind in PropagationPolicy OverridePolicy; do
  KIND="$kind" yq e -e '
    .spec.namespaceResourceWhitelist[] |
    select(.group == "policy.karmada.io" and .kind == strenv(KIND))
  ' "$ROOT/bootstrap/appproject.yaml" >/dev/null ||
    fail "AppProject must allow $kind"
done
if yq e -e '
  .spec.namespaceResourceWhitelist[] |
  select(.kind == "Secret" or .kind == "ObjectBucketClaim" or
         .kind == "ClusterPropagationPolicy" or .kind == "ClusterOverridePolicy")
' "$ROOT/bootstrap/appproject.yaml" >/dev/null 2>&1; then
  fail "AppProject allows a forbidden dependency or cluster policy kind"
fi

children="$ROOT/contracts/children.yaml"
yq e '.' "$children" >/dev/null || fail "invalid children enrollment"
[ "$(yq e -r '.apiVersion' "$children")" = scalex.io/v1alpha1 ] ||
  fail "unsupported children apiVersion"
[ "$(yq e -r '.kind' "$children")" = ChildRepositoryEnrollmentList ] ||
  fail "unsupported children kind"

: >"$tmp/application-identities"
: >"$tmp/namespaces"
: >"$tmp/value-paths"

for descriptor in "${descriptors[@]}"; do
  name="$(basename "$(dirname "$descriptor")")"
  validate_release_descriptor "$descriptor" "$name"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  state="$(yq e -r '.state' "$descriptor")"
  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  chart_path="$(yq e -r '.source.path' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  values_path="$(yq e -r '.values.path' "$descriptor")"
  release_dir="$(dirname "$descriptor")"

  [ -f "$ROOT/$values_path" ] || fail "release values not found: $values_path"
  yq e '.' "$ROOT/$values_path" >/dev/null || fail "invalid release values: $values_path"
  if yq e -r '.. | select(tag == "!!map") | keys | .[]' "$ROOT/$values_path" |
      grep -Eix '(password|passwd|token|accessKeyId|secretAccessKey|stringData)' >/dev/null; then
    fail "release values appear to contain inline credential fields: $values_path"
  fi
  mapfile -t release_entries < <(find "$release_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "${release_entries[*]}" = "release.yaml values.yaml" ] ||
    fail "release directory must contain only release.yaml and values.yaml: ${release_dir#"$ROOT/"}"

  REPO_URL="$repo_url" yq e -e '.spec.sourceRepos[] == strenv(REPO_URL)' \
    "$ROOT/bootstrap/appproject.yaml" >/dev/null ||
    fail "source is not allowed by AppProject: $repo_url"
  REPO_URL="$repo_url" CHART_PATH="$chart_path" yq e -e '
    .repositories[] |
    select(.repoURL == strenv(REPO_URL)) |
    .paths[] == strenv(CHART_PATH)
  ' "$children" >/dev/null || fail "source is not enrolled in children contract: $repo_url/$chart_path"

  printf '%s\n' "$name" >>"$tmp/application-identities"
  printf '%s\n' "$namespace" >>"$tmp/namespaces"
  printf '%s\n' "$values_path" >>"$tmp/value-paths"

  [ "$state" = active ] || continue

  repo_name="$(basename "${repo_url%.git}")"
  source_repo="$FEATURE_REPOS_ROOT/$repo_name"
  [ -d "$source_repo/.git" ] || fail "active source checkout not found: $source_repo"
  actual_remote="$(normalize_github_url "$(git -C "$source_repo" remote get-url origin)")"
  [ "$actual_remote" = "$repo_url" ] || fail "source checkout remote mismatch: $repo_name"
  git -C "$source_repo" cat-file -e "$revision:$chart_path/Chart.yaml" 2>/dev/null ||
    fail "pinned chart not found: $repo_name@$revision/$chart_path"

  chart_export="$tmp/$name-source"
  mkdir -p "$chart_export"
  git -C "$source_repo" archive "$revision" "$chart_path" | tar -x -C "$chart_export"
  chart_dir="$chart_export/$chart_path"
  render="$tmp/$name-render.yaml"
  helm lint --strict "$chart_dir" -f "$ROOT/$values_path" >/dev/null
  helm template "$name" "$chart_dir" --namespace "$namespace" -f "$ROOT/$values_path" >"$render"

  yq e -e 'select(.kind == "PropagationPolicy")' "$render" >/dev/null 2>&1 ||
    fail "active feature chart must render a PropagationPolicy: $name"
  yq e -e '
    select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or
           .kind == "Job" or .kind == "CronJob")
  ' "$render" >/dev/null 2>&1 || fail "active feature chart rendered no workload: $name"
  if yq e -e '
    select(.kind == "Secret" or .kind == "ExternalSecret" or .kind == "ObjectBucketClaim" or
           .kind == "PersistentVolumeClaim" or .kind == "Namespace" or
           .kind == "CustomResourceDefinition" or .kind == "ClusterRole" or
           .kind == "ClusterRoleBinding" or .kind == "StorageClass" or
           .kind == "ClusterPropagationPolicy" or .kind == "ClusterOverridePolicy")
  ' "$render" >/dev/null 2>&1; then
    fail "active feature chart rendered an Infra dependency or cluster-scoped resource: $name"
  fi
  NAMESPACE="$namespace" yq e -e '
    select(.metadata.namespace != null and .metadata.namespace != strenv(NAMESPACE))
  ' "$render" >/dev/null 2>&1 && fail "active feature chart escaped its release namespace: $name"
  NAMESPACE="$namespace" yq e -e '
    select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
    .spec.resourceSelectors[]? |
    select(.namespace != null and .namespace != strenv(NAMESPACE))
  ' "$render" >/dev/null 2>&1 && fail "Karmada policy selector escaped its release namespace: $name"
  validate_policy_coverage "$render" "$namespace" "$name"
  validate_namespaced_rbac "$render" "$namespace" "$name"
  yq e -o=json -I=0 '.' "$render" | jq -s -e '
    [ .[] | .. | objects | .image? // empty ] as $images |
    ($images | length) > 0 and
    all($images[]; test("@sha256:[0-9a-f]{64}$"))
  ' >/dev/null || fail "active workload images must use immutable digests: $name"
done

for inventory in application-identities namespaces value-paths; do
  [ -z "$(sort "$tmp/$inventory" | uniq -d)" ] || fail "duplicate release $inventory"
done

echo "federation validation passed"
