#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPSET="$ROOT/bootstrap/applicationset.yaml"
PROJECT="$ROOT/bootstrap/appproject.yaml"
FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}"

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

for command in git helm jq tar yq; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

for manifest in "$APPSET" "$PROJECT"; do
  yq e '.' "$manifest" >/dev/null || fail "invalid YAML: ${manifest#"$ROOT/"}"
done

yq e -e '
  (.spec.generators | length == 1) and
  (.spec.generators[0].git.repoURL == "https://github.com/SJoon99/scalex-federation.git") and
  (.spec.generators[0].git.revision == "experiment/release-per-directory") and
  (.spec.generators[0].git.files | length == 1) and
  (.spec.generators[0].git.files[0].path == "releases/*/*/release.yaml") and
  (.spec.generators[0].selector.matchLabels.state == "active")
' "$APPSET" >/dev/null || fail "ApplicationSet release discovery contract drifted"

# shellcheck disable=SC2016 # Argo's $federation placeholder must stay literal.
yq e -e '
  (.spec.template.spec.sources | length == 2) and
  (.spec.template.spec.sources[0].helm.valueFiles | length == 1) and
  (.spec.template.spec.sources[0].helm.valueFiles[0] == "$federation/{{ .values.path }}") and
  (.spec.template.spec.sources[1].repoURL == "https://github.com/SJoon99/scalex-federation.git") and
  (.spec.template.spec.sources[1].targetRevision == "experiment/release-per-directory") and
  (.spec.template.spec.sources[1].ref == "federation") and
  (.spec.template.spec.sources[1] | has("path") | not) and
  (.spec.template.spec.destination.name == "karmada") and
  (.spec.template.spec.destination.namespace == "{{ .namespace }}")
' "$APPSET" >/dev/null || fail "ApplicationSet source or destination contract drifted"

yq e -e '
  (.spec.destinations | length == 1) and
  (.spec.destinations[0].name == "karmada") and
  (.spec.destinations[0].namespace == "scalex-*")
' "$PROJECT" >/dev/null || fail "AppProject destination boundary drifted"
if yq e -r '.spec.sourceRepos[]' "$PROJECT" | \
    grep -Ev '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$' >/dev/null; then
  fail "AppProject sourceRepos must contain exact GitHub repository URLs"
fi
yq e -e '.spec.namespaceResourceWhitelist[] | select(.group == "policy.karmada.io" and .kind == "PropagationPolicy")' "$PROJECT" >/dev/null || fail "AppProject must allow PropagationPolicy"
yq e -e '.spec.namespaceResourceWhitelist[] | select(.group == "policy.karmada.io" and .kind == "OverridePolicy")' "$PROJECT" >/dev/null || fail "AppProject must allow OverridePolicy"
if yq e -e '.spec.namespaceResourceWhitelist[] | select(.kind == "Secret" or .kind == "ObjectBucketClaim" or .kind == "ClusterPropagationPolicy" or .kind == "ClusterOverridePolicy")' "$PROJECT" >/dev/null 2>&1; then
  fail "AppProject allows a forbidden dependency or cluster policy kind"
fi

if find "$ROOT/releases" -type d \( -name policy -o -name dependencies \) -print -quit | grep -q .; then
  fail "Federation release must not contain policy or dependencies directories"
fi

while IFS= read -r -d '' manifest; do
  yq e '.' "$manifest" >/dev/null || fail "invalid YAML: ${manifest#"$ROOT/"}"
  if yq e -e 'select(.kind == "Secret")' "$manifest" >/dev/null 2>&1; then
    fail "Kubernetes Secret manifests are forbidden: ${manifest#"$ROOT/"}"
  fi
done < <(find "$ROOT/bootstrap" "$ROOT/releases" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)

mapfile -d '' descriptors < <(find "$ROOT/releases" -mindepth 3 -maxdepth 3 -type f -name release.yaml -print0 | sort -z)
[ "${#descriptors[@]}" -gt 0 ] || fail "no release descriptors found"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/application-identities"
: >"$tmp/namespaces"
: >"$tmp/value-paths"

for descriptor in "${descriptors[@]}"; do
  yq e '.' "$descriptor" >/dev/null || fail "invalid release YAML: ${descriptor#"$ROOT/"}"
  yq e -o=json -I=0 '.' "$descriptor" | jq -e '
    type == "object" and
    (keys | sort) == ["apiVersion","environment","kind","name","namespace","promotion","renderer","source","state","values"] and
    .apiVersion == "scalex.io/v1alpha2" and
    .kind == "FederationRelease" and
    .renderer == "helm/v1" and
    (.state == "active" or .state == "disabled") and
    (.source | keys | sort) == ["path","repoURL","revision"] and
    (.values | keys) == ["path"] and
    (.promotion | keys) == ["mode"] and
    (.promotion.mode == "tracked" or .promotion.mode == "pinned")
  ' >/dev/null || fail "invalid FederationRelease contract: ${descriptor#"$ROOT/"}"

  name="$(yq e -r '.name' "$descriptor")"
  environment="$(yq e -r '.environment' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  state="$(yq e -r '.state' "$descriptor")"
  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  chart_path="$(yq e -r '.source.path' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  values_path="$(yq e -r '.values.path' "$descriptor")"
  descriptor_rel="${descriptor#"$ROOT/"}"
  release_dir="$(dirname "$descriptor")"

  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid release name: $name"
  [[ "$environment" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid environment: $environment"
  [[ "$namespace" =~ ^scalex-[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid release namespace: $namespace"
  [ "$descriptor_rel" = "releases/$environment/$name/release.yaml" ] || fail "release path identity mismatch: $descriptor_rel"
  [ "$values_path" = "releases/$environment/$name/values.yaml" ] || fail "values path identity mismatch: $values_path"
  [ -f "$ROOT/$values_path" ] || fail "release values not found: $values_path"
  yq e '.' "$ROOT/$values_path" >/dev/null || fail "invalid release values: $values_path"
  if yq e -r '.. | select(tag == "!!map") | keys | .[]' "$ROOT/$values_path" |
      grep -Eix '(password|passwd|token|accessKeyId|secretAccessKey|stringData)' >/dev/null; then
    fail "release values appear to contain inline credential fields: $values_path"
  fi

  mapfile -t release_entries < <(find "$release_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "${release_entries[*]}" = "release.yaml values.yaml" ] || fail "release directory must contain only release.yaml and values.yaml: ${release_dir#"$ROOT/"}"

  [[ "$repo_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || fail "invalid source URL: $repo_url"
  [[ "$chart_path" =~ ^(chart|charts/[a-z0-9]([-a-z0-9]*[a-z0-9])?)$ ]] || fail "invalid chart path: $chart_path"
  if ! [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || \
      [ "$revision" = 0000000000000000000000000000000000000000 ]; then
    fail "source revision must be a full immutable SHA: $name"
  fi

  REPO_URL="$repo_url" yq e -e '.spec.sourceRepos[] == strenv(REPO_URL)' "$PROJECT" >/dev/null || fail "source is not allowed by AppProject: $repo_url"

  printf '%s\n' "$environment-$name" >>"$tmp/application-identities"
  printf '%s\n' "$namespace" >>"$tmp/namespaces"
  printf '%s\n' "$values_path" >>"$tmp/value-paths"

  [ "$state" = active ] || continue

  repo_name="$(basename "${repo_url%.git}")"
  source_repo="$FEATURE_REPOS_ROOT/$repo_name"
  [ -d "$source_repo/.git" ] || fail "active source checkout not found: $source_repo"
  [ "$(git -C "$source_repo" remote get-url origin)" = "$repo_url" ] || fail "source checkout remote mismatch: $repo_name"
  git -C "$source_repo" cat-file -e "$revision:$chart_path/Chart.yaml" 2>/dev/null || fail "pinned chart not found: $repo_name@$revision/$chart_path"

  chart_export="$tmp/$environment-$name-source"
  mkdir -p "$chart_export"
  git -C "$source_repo" archive "$revision" "$chart_path" | tar -x -C "$chart_export"
  chart_dir="$chart_export/$chart_path"
  render="$tmp/$environment-$name-render.yaml"
  helm lint "$chart_dir" -f "$ROOT/$values_path" >/dev/null
  helm template "$name" "$chart_dir" --namespace "$namespace" -f "$ROOT/$values_path" >"$render"

  yq e -e 'select(.kind == "PropagationPolicy")' "$render" >/dev/null 2>&1 || fail "active feature chart must render a PropagationPolicy: $name"
  yq e -e 'select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob")' "$render" >/dev/null 2>&1 || fail "active feature chart rendered no workload: $name"
  if yq e -e 'select(.kind == "Secret" or .kind == "ExternalSecret" or .kind == "ObjectBucketClaim" or .kind == "PersistentVolumeClaim" or .kind == "Namespace" or .kind == "CustomResourceDefinition" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "StorageClass" or .kind == "ClusterPropagationPolicy" or .kind == "ClusterOverridePolicy")' "$render" >/dev/null 2>&1; then
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

echo "federation release validation passed"
