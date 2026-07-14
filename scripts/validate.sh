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

for tool in check-jsonschema git helm jq tar yq; do
  require "$tool"
done

source "$ROOT/scripts/lib/release-contract.sh"
jq empty "$ROOT/contracts/federation-release-v1alpha1.schema.json"
mapfile -t descriptors < <(find "$ROOT/releases" -mindepth 3 -maxdepth 3 -name release.yaml -type f | sort)
[ "${#descriptors[@]}" -gt 0 ] || fail "no release descriptors found"
"$ROOT/scripts/lib/validate-release-schema.sh" "${descriptors[@]}"

for manifest in "$ROOT/bootstrap/appproject.yaml" "$ROOT/bootstrap/applicationset.yaml"; do
  test -f "$manifest" || fail "missing bootstrap manifest: $manifest"
  yq e '.' "$manifest" >/dev/null
done

mapfile -t bootstrap_manifests < <(
  find "$ROOT/bootstrap" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort
)
[ "${#bootstrap_manifests[@]}" -eq 2 ] || fail "bootstrap may contain only two manifests"

mapfile -t appproject_identities < <(yq e -r -N 'select(. != null) | [.kind, .metadata.name] | @tsv' "$ROOT/bootstrap/appproject.yaml")
[ "${#appproject_identities[@]}" -eq 1 ] && [ "${appproject_identities[0]}" = $'AppProject\tscalex-federation' ] ||
  fail "invalid AppProject identity"
mapfile -t applicationset_identities < <(yq e -r -N 'select(. != null) | [.kind, .metadata.name] | @tsv' "$ROOT/bootstrap/applicationset.yaml")
[ "${#applicationset_identities[@]}" -eq 1 ] && [ "${applicationset_identities[0]}" = $'ApplicationSet\tscalex-federation-releases' ] ||
  fail "invalid ApplicationSet identity"
yq e -e '.spec.template.spec.destination.name == "karmada"' \
  "$ROOT/bootstrap/applicationset.yaml" >/dev/null || fail "ApplicationSet must target karmada"
yq e -e '
  (.spec.generators | type) == "!!seq" and
  (.spec.generators | length) == 1 and
  (.spec.generators[0] | keys | sort | join(",")) == "git" and
  (.spec.generators[0].git | keys | sort | join(",")) == "files,repoURL,revision" and
  .spec.generators[0].git.repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.generators[0].git.revision == "main" and
  (.spec.generators[0].git.files | type) == "!!seq" and
  (.spec.generators[0].git.files | length) == 1 and
  (.spec.generators[0].git.files[0] | keys | sort | join(",")) == "path" and
  .spec.generators[0].git.files[0].path == "releases/*/*/release.yaml"
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "ApplicationSet generator must exactly discover Federation releases"
yq e -e '
  (.spec.template.spec.sources | type) == "!!seq" and
  (.spec.template.spec.sources | length) == 3 and
  (.spec.template.spec.sources[0] | keys | sort | join(",")) == "helm,path,repoURL,targetRevision" and
  .spec.template.spec.sources[0].repoURL == "{{ .source.repoURL }}" and
  .spec.template.spec.sources[0].targetRevision == "{{ .source.revision }}" and
  .spec.template.spec.sources[0].path == "{{ .source.path }}" and
  (.spec.template.spec.sources[0].helm | keys | sort | join(",")) == "releaseName,valueFiles" and
  .spec.template.spec.sources[0].helm.releaseName == "{{ .name }}" and
  (.spec.template.spec.sources[0].helm.valueFiles | type) == "!!seq" and
  (.spec.template.spec.sources[0].helm.valueFiles | length) == 1 and
  .spec.template.spec.sources[0].helm.valueFiles[0] == "$federation/{{ .values.path }}" and
  (.spec.template.spec.sources[1] | keys | sort | join(",")) == "directory,path,ref,repoURL,targetRevision" and
  .spec.template.spec.sources[1].repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.template.spec.sources[1].targetRevision == "main" and
  .spec.template.spec.sources[1].ref == "federation" and
  .spec.template.spec.sources[1].path == "{{ .policy.path }}" and
  (.spec.template.spec.sources[1].directory | keys | sort | join(",")) == "recurse" and
  .spec.template.spec.sources[1].directory.recurse == true and
  (.spec.template.spec.sources[2] | keys | sort | join(",")) == "directory,path,repoURL,targetRevision" and
  .spec.template.spec.sources[2].repoURL == "https://github.com/SJoon99/scalex-federation.git" and
  .spec.template.spec.sources[2].targetRevision == "main" and
  .spec.template.spec.sources[2].path == "{{ .dependencies.path }}" and
  (.spec.template.spec.sources[2].directory | keys | sort | join(",")) == "recurse" and
  .spec.template.spec.sources[2].directory.recurse == true
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "ApplicationSet sources must exactly match the v1 Helm release contract"
yq e -e '
  (.spec.destinations | length) == 1 and
  .spec.destinations[0].name == "karmada" and
  .spec.destinations[0].namespace == "scalex-*"
' "$ROOT/bootstrap/appproject.yaml" >/dev/null || fail "AppProject destination must be the Karmada ScaleX boundary"
yq e -e '
  .spec.template.spec.sources[] |
  select(.ref == "federation" and .path == "{{ .policy.path }}" and .directory.recurse == true)
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null || fail "policy source must recurse"
yq e -e '
  .spec.template.spec.sources[] |
  select(.path == "{{ .dependencies.path }}" and .directory.recurse == true)
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null || fail "dependency source must recurse"
yq e -e '
  .spec.template.spec.sources[] |
  select(.helm != null) |
  select(.repoURL == "{{ .source.repoURL }}" and .targetRevision == "{{ .source.revision }}") |
  select(.path == "{{ .source.path }}") |
  .helm.valueFiles[] == "$federation/{{ .values.path }}"
' "$ROOT/bootstrap/applicationset.yaml" >/dev/null || fail "Helm source does not match v1 descriptor"
yq e -e '.spec.template.metadata.name == "federation-{{ .environment }}-{{ .name }}"' \
  "$ROOT/bootstrap/applicationset.yaml" >/dev/null ||
  fail "ApplicationSet name template must include environment and release"
yq e -e '
  .spec.namespaceResourceWhitelist[] |
  select(.group == "external-secrets.io" and .kind == "ExternalSecret")
' "$ROOT/bootstrap/appproject.yaml" >/dev/null || fail "AppProject must allow ExternalSecret"
for binding in ResourceBinding ClusterResourceBinding; do
  BINDING="$binding" yq e -e '
    (.spec.namespaceResourceWhitelist[]?, .spec.clusterResourceWhitelist[]?) |
    select(.group == "work.karmada.io" and .kind == strenv(BINDING))
  ' "$ROOT/bootstrap/appproject.yaml" >/dev/null || fail "AppProject must expose Karmada child resource: $binding"
done

children="$ROOT/contracts/children.yaml"
yq e '.' "$children" >/dev/null
[ "$(yq e -r '.apiVersion' "$children")" = scalex.io/v1alpha1 ] || fail "unsupported children apiVersion"
[ "$(yq e -r '.kind' "$children")" = ChildRepositoryEnrollmentList ] || fail "unsupported children kind"
[ "$(yq e -r '. | keys | sort | join(",")' "$children")" = apiVersion,kind,repositories ] ||
  fail "unknown children contract fields"
yq e -e '(.repositories | type) == "!!seq" and (.repositories | length) > 0' "$children" >/dev/null ||
  fail "children.repositories must be non-empty"

while IFS=$'\t' read -r child_name repo_url path_count entry_keys; do
  [ "$entry_keys" = name,paths,repoURL ] || fail "unknown child enrollment fields: $child_name"
  [[ "$child_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid child name"
  [[ "$repo_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] ||
    fail "invalid child repoURL: $repo_url"
  [ "$path_count" -gt 0 ] || fail "child paths cannot be empty: $child_name"
done < <(yq e -r '.repositories[] | [.name, .repoURL, (.paths | length), (. | keys | sort | join(","))] | @tsv' "$children")

while IFS= read -r enrolled_path; do
  require_relative_path "$enrolled_path" children.paths
done < <(yq e -r '.repositories[].paths[]' "$children")

duplicates="$(yq e -r '.repositories[] | .repoURL as $url | .paths[] | [$url, .] | @tsv' "$children" | sort | uniq -d)"
[ -z "$duplicates" ] || fail "duplicate child enrollment identity"
[ -z "$(yq e -r '.repositories[].name' "$children" | sort | uniq -d)" ] || fail "duplicate child enrollment name"
[ -z "$(yq e -r '.repositories[].repoURL' "$children" | sort | uniq -d)" ] || fail "duplicate child enrollment repository"

mapfile -t enrolled_repos < <(yq e -r '.repositories[].repoURL' "$children" | sort -u)
mapfile -t project_repos < <(
  yq e -r '.spec.sourceRepos[]' "$ROOT/bootstrap/appproject.yaml" |
    grep -v '^https://github.com/SJoon99/scalex-federation.git$' | sort -u
)
[ "$(printf '%s\n' "${enrolled_repos[@]}")" = "$(printf '%s\n' "${project_repos[@]}")" ] ||
  fail "AppProject sourceRepos and children enrollment differ"
yq e -e '.spec.sourceRepos[] == "https://github.com/SJoon99/scalex-federation.git"' \
  "$ROOT/bootstrap/appproject.yaml" >/dev/null || fail "AppProject must enroll the Federation source"

if [ -n "$VALIDATE_BASE_REF" ]; then
  git -C "$ROOT" rev-parse --verify "${VALIDATE_BASE_REF}^{commit}" >/dev/null ||
    fail "validation base ref is not a commit: $VALIDATE_BASE_REF"
fi

: >"$tmp/application-identities.txt"
: >"$tmp/release-namespaces.txt"
: >"$tmp/rendered-identities.txt"
: >"$tmp/external-secret-targets.txt"
: >"$tmp/load-balancer-ip-claims.txt"

for descriptor in "${descriptors[@]}"; do
  release_dir="$(dirname "$descriptor")"
  expected_environment="$(basename "$(dirname "$release_dir")")"
  expected_name="$(basename "$release_dir")"
  validate_release_descriptor "$descriptor" "$expected_environment" "$expected_name"
  environment="$(yq e -r '.environment' "$descriptor")"
  name="$(yq e -r '.name' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  policy_rel="$(yq e -r '.policy.path' "$descriptor")"
  printf 'federation-%s-%s\n' "$environment" "$name" >>"$tmp/application-identities.txt"
  printf '%s\n' "$namespace" >>"$tmp/release-namespaces.txt"
  if [ -d "$ROOT/$policy_rel" ]; then
    mapfile -t preflight_policy_files < <(
      find "$ROOT/$policy_rel" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort
    )
    if [ "${#preflight_policy_files[@]}" -gt 0 ]; then
      yq e -r -N '
        select(.kind == "OverridePolicy") |
        .spec.overrideRules[].overriders.plaintext[]? |
        select(.path == "/metadata/annotations/lbipam.cilium.io~1ips") |
        .value
      ' "${preflight_policy_files[@]}" | sed '/^[[:space:]]*$/d' >>"$tmp/load-balancer-ip-claims.txt"
    fi
  fi
done

[ -z "$(sort "$tmp/application-identities.txt" | uniq -d)" ] || fail "duplicate generated Application identity"
[ -z "$(sort "$tmp/release-namespaces.txt" | uniq -d)" ] || fail "duplicate release namespace"
[ -z "$(sort "$tmp/load-balancer-ip-claims.txt" | uniq -d)" ] || fail "duplicate explicit LoadBalancer IP"

for descriptor in "${descriptors[@]}"; do
  release_dir="$(dirname "$descriptor")"
  release_rel="${release_dir#"$ROOT"/}"
  descriptor_rel="${descriptor#"$ROOT"/}"
  environment="$(basename "$(dirname "$release_dir")")"
  name="$(basename "$release_dir")"
  validate_release_descriptor "$descriptor" "$environment" "$name"

  repo_url="$(yq e -r '.source.repoURL' "$descriptor")"
  chart_path="$(yq e -r '.source.path' "$descriptor")"
  revision="$(yq e -r '.source.revision' "$descriptor")"
  values_rel="$(yq e -r '.values.path' "$descriptor")"
  dependencies_rel="$(yq e -r '.dependencies.path' "$descriptor")"
  policy_rel="$(yq e -r '.policy.path' "$descriptor")"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  promotion_mode="$(yq e -r '.promotion.mode' "$descriptor")"

  REPO_URL="$repo_url" CHART_PATH="$chart_path" yq e -e '
    .repositories[] | select(.repoURL == strenv(REPO_URL)) | .paths[] == strenv(CHART_PATH)
  ' "$children" >/dev/null || fail "source URL/path is not enrolled: $repo_url/$chart_path"

  case "$repo_url|$chart_path" in
    https://github.com/SJoon99/scalex-feature-poc.git\|chart)
      source_contract=legacy-poc
      ;;
    https://github.com/BellTigerLee/smurf-child.git\|charts/rgw-analysis-web)
      source_contract=smurf-child
      ;;
    *)
      fail "enrolled source has no validation contract: $repo_url/$chart_path"
      ;;
  esac

  repo_name="$(basename "${repo_url%.git}")"
  feature_repo="$FEATURE_REPOS_ROOT/$repo_name"
  git -C "$feature_repo" rev-parse --is-inside-work-tree >/dev/null || fail "feature repository not found: $feature_repo"
  origin="$(git -C "$feature_repo" remote get-url origin)"
  case "$origin" in
    git@github.com:*) origin="https://github.com/${origin#git@github.com:}" ;;
    ssh://git@github.com/*) origin="https://github.com/${origin#ssh://git@github.com/}" ;;
  esac
  [ "$origin" = "$repo_url" ] || fail "feature origin does not match enrollment: $feature_repo"
  git -C "$feature_repo" cat-file -e "${revision}^{commit}" 2>/dev/null || fail "unavailable source revision: $revision"
  [ "$(git -C "$feature_repo" rev-parse "${revision}^{commit}")" = "$revision" ] || fail "source revision did not resolve exactly"
  git -C "$feature_repo" cat-file -e "$revision:$chart_path" 2>/dev/null || fail "chart path absent at pinned revision"
  if git -C "$feature_repo" ls-tree -r "$revision" -- "$chart_path" | awk '$1 == "120000" || $1 == "160000" {found=1} END {exit !found}'; then
    fail "chart tree contains a symlink or submodule"
  fi

  chart_export="$tmp/sources/$environment-$name"
  mkdir -p "$chart_export"
  git -C "$feature_repo" archive "$revision" "$chart_path" | tar -x -C "$chart_export"
  chart_dir="$chart_export/$chart_path"
  test -f "$chart_dir/Chart.yaml" || fail "pinned chart has no Chart.yaml"

  values_file="$ROOT/$values_rel"
  dependencies_root="$ROOT/$dependencies_rel"
  policy_root="$ROOT/$policy_rel"
  test -f "$values_file" || fail "missing values file: $values_rel"
  test ! -L "$values_file" || fail "values file cannot be a symlink: $values_rel"
  test -d "$dependencies_root" || fail "missing dependencies path: $dependencies_rel"
  test -d "$policy_root" || fail "missing policy path: $policy_rel"
  [ -z "$(find "$dependencies_root" "$policy_root" -type l -print -quit)" ] || fail "release paths cannot contain symlinks"
  yq e '.' "$values_file" >/dev/null
  yq e -e '(.images | type) == "!!map" and (.images | length) > 0' "$values_file" >/dev/null ||
    fail "values.images must be a non-empty map"

  while IFS=$'\t' read -r component repository tag digest pull_policy source_revision; do
    [ -n "$repository" ] || fail "image repository is empty: $component"
    [ -n "$tag" ] && [ "$tag" != latest ] || fail "image tag must be explicit and non-latest: $component"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$digest" != sha256:0000000000000000000000000000000000000000000000000000000000000000 ] ||
      fail "image digest is not immutable: $component"
    case "$pull_policy" in Always | IfNotPresent | Never) ;; *) fail "invalid pullPolicy: $component" ;; esac
    [ -z "$source_revision" ] || [ "$source_revision" = "$revision" ] || fail "image sourceRevision is stale: $component"
  done < <(yq e -r '.images | to_entries[] | [.key, (.value.repository // ""), (.value.tag // ""), (.value.digest // ""), (.value.pullPolicy // ""), (.value.sourceRevision // "")] | @tsv' "$values_file")

  if [ "$source_contract" = smurf-child ]; then
    [ "$(yq e -r '.images | keys | sort | join(",")' "$values_file")" = flow,web ] || fail "smurf child release requires flow and web images"
    for component in flow web; do
      case "$promotion_mode" in
        tracked) expected="ghcr.io/belltigerlee/smurf-child-$component" ;;
        pinned) expected="belltigerlee/test-image-$component" ;;
        *) fail "unsupported Smurf promotion mode" ;;
      esac
      [ "$(COMPONENT="$component" yq e -r '.images[strenv(COMPONENT)].repository' "$values_file")" = "$expected" ] ||
        fail "unexpected $promotion_mode Smurf image repository: $component"
      [ "$(COMPONENT="$component" yq e -r '.images[strenv(COMPONENT)].tag' "$values_file")" = "sha-$revision" ] ||
        fail "image tag must match source revision: $component"
      [ "$(COMPONENT="$component" yq e -r '.images[strenv(COMPONENT)].sourceRevision' "$values_file")" = "$revision" ] ||
        fail "image sourceRevision is stale: $component"
    done
  fi

  mapfile -t dependency_files < <(find "$dependencies_root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  if find "$dependencies_root" -type f \( -name '*.json' -o -name 'Chart.yaml' -o -iname 'kustomization.yaml' \) -print -quit | grep -q .; then
    fail "dependency path supports recursive plain YAML only"
  fi
  dependency_render="$tmp/$environment-$name-dependencies.yaml"
  : >"$dependency_render"
  if [ "${#dependency_files[@]}" -gt 0 ]; then
    yq e '.' "${dependency_files[@]}" > "$dependency_render"
  fi
  mapfile -t dependency_kinds < <(
    yq e -r -N 'select(. != null) | .kind // ""' "$dependency_render" |
      sed '/^[[:space:]]*$/d'
  )
  case "$source_contract" in
    legacy-poc)
      [ "${#dependency_kinds[@]}" -eq 0 ] ||
        fail "legacy POC dependency path must contain no YAML resources"
      ;;
    smurf-child)
      [ "${#dependency_kinds[@]}" -eq 1 ] && [ "${dependency_kinds[0]}" = ExternalSecret ] ||
        fail "Smurf dependency path must contain exactly one ExternalSecret"
      feature_dependency_validator="$ROOT/scripts/rgw-analysis-web/validate-dependencies.sh"
      test -x "$feature_dependency_validator" || fail "missing Smurf dependency validator"
      existing_secret="$(yq e -r '.credentials.existingSecret' "$values_file")"
      "$feature_dependency_validator" "$dependency_render" "$namespace" "$environment" "$name" "$existing_secret"
      ;;
  esac

  mapfile -t policy_files < <(find "$policy_root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  [ "${#policy_files[@]}" -gt 0 ] || fail "policy path found no YAML"
  if find "$policy_root" -type f \( -name '*.json' -o -name 'Chart.yaml' -o -iname 'kustomization.yaml' \) -print -quit | grep -q .; then
    fail "policy path supports recursive plain YAML only"
  fi
  policy_render="$tmp/$environment-$name-policies.yaml"
  yq e '.' "${policy_files[@]}" > "$policy_render"
  for policy_file in "${policy_files[@]}"; do
    case "$policy_file" in
      "$policy_root"/propagation/*) expected_kind=PropagationPolicy ;;
      "$policy_root"/overrides/*) expected_kind=OverridePolicy ;;
      *) fail "policy YAML must be under propagation or overrides" ;;
    esac
    if EXPECTED_KIND="$expected_kind" yq e -e 'select(. != null and .kind != strenv(EXPECTED_KIND))' "$policy_file" >/dev/null 2>&1; then
      fail "wrong policy kind in $policy_file"
    fi
  done
  if NAMESPACE="$namespace" yq e -e 'select(. != null and .metadata.namespace != strenv(NAMESPACE))' "$policy_render" >/dev/null 2>&1; then
    fail "policy namespace mismatch"
  fi
  if NAMESPACE="$namespace" yq e -e '
    select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
    .spec.resourceSelectors[] | select(.namespace != strenv(NAMESPACE))
  ' "$policy_render" >/dev/null 2>&1; then
    fail "policy selector namespace mismatch"
  fi
  yq e -o=json -I=0 "$policy_render" | jq -s -e --arg namespace "$namespace" '
    all(.[];
      type == "object" and
      .apiVersion == "policy.karmada.io/v1alpha1" and
      (.kind == "PropagationPolicy" or .kind == "OverridePolicy") and
      (.metadata.name | type) == "string" and
      (.metadata.name | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")) and
      .metadata.namespace == $namespace and
      (.spec.resourceSelectors | type) == "array" and
      (.spec.resourceSelectors | length) > 0 and
      all(.spec.resourceSelectors[];
        (. | keys | sort) == ["apiVersion", "kind", "name", "namespace"] and
        (.apiVersion | type) == "string" and (.apiVersion | length) > 0 and
        (.kind | type) == "string" and (.kind | length) > 0 and
        (.name | type) == "string" and (.name | length) > 0 and
        .namespace == $namespace) and
      (if .kind == "PropagationPolicy" then
        (.spec.propagateDeps | type) == "boolean" and
        (.spec.placement.clusterAffinity.clusterNames | type) == "array" and
        (.spec.placement.clusterAffinity.clusterNames | length) > 0 and
        all(.spec.placement.clusterAffinity.clusterNames[]; . == "b" or . == "c")
      else
        (.spec.overrideRules | type) == "array" and
        (.spec.overrideRules | length) > 0
      end))
  ' >/dev/null || fail "invalid Karmada policy structure"

  yq e -o=json -I=0 "$policy_render" | jq -s -e \
    --arg namespace "$namespace" \
    --arg profile "$source_contract" '
      def selector($api; $kind; $name): {
        "apiVersion": $api,
        "kind": $kind,
        "name": $name,
        "namespace": $namespace
      };
      def exact_rule($operations):
        (. | length) == 1 and
        (.[0] | keys | sort) == ["overriders", "targetCluster"] and
        .[0].targetCluster == {"clusterNames": ["b"]} and
        .[0].overriders == {"plaintext": $operations};
      [.[] | select(.kind == "OverridePolicy")] as $overrides |
      ($overrides | length) == 2 and
      any($overrides[];
        .metadata.name == "rgw-analysis-web-runtime-on-b" and
        (.spec | keys | sort) == ["overrideRules", "overriders", "resourceSelectors"] and
        .spec.overriders == {} and
        .spec.resourceSelectors == [selector("v1"; "ConfigMap"; "rgw-analysis-web-runtime")] and
        (.spec.overrideRules | exact_rule([{
          "path": "/data/S3_ENDPOINT_URL",
          "operator": "replace",
          "value": "http://scalex-poc-rgw.csi-rook-ceph"
        }]))) and
      any($overrides[];
        .metadata.name == "rgw-analysis-web-result-web-on-b" and
        (.spec | keys | sort) == ["overrideRules", "overriders", "resourceSelectors"] and
        .spec.overriders == {} and
        .spec.resourceSelectors == [selector("v1"; "Service"; "rgw-analysis-web-result-web")] and
        (.spec.overrideRules | exact_rule(
          if $profile == "legacy-poc" then
            [{"path":"/spec/type","operator":"replace","value":"LoadBalancer"},
             {"path":"/metadata/annotations/lbipam.cilium.io~1ips","operator":"add","value":"10.33.142.20"}]
          else
            [{"path":"/spec/type","operator":"replace","value":"LoadBalancer"}]
          end)))
    ' >/dev/null || fail "invalid $source_contract RGW override policy contract"

  yq e -o=json -I=0 "$policy_render" | jq -s -e \
    --arg namespace "$namespace" \
    --arg profile "$source_contract" '
      def selector($api; $kind; $name): {
        "apiVersion": $api,
        "kind": $kind,
        "name": $name,
        "namespace": $namespace
      };
      def exact_propagation($name; $selectors; $clusters; $propagate_deps; $spread):
        .metadata.name == $name and
        (.spec | keys | sort) == ["conflictResolution", "placement", "preemption", "priority",
          "propagateDeps", "resourceSelectors", "schedulerName"] and
        .spec.conflictResolution == "Abort" and
        .spec.preemption == "Never" and
        .spec.priority == 0 and
        .spec.schedulerName == "default-scheduler" and
        .spec.resourceSelectors == $selectors and
        .spec.propagateDeps == $propagate_deps and
        .spec.placement == ({"clusterAffinity": {"clusterNames": $clusters}} +
          (if $spread then {"spreadConstraints": [{"spreadByField":"cluster","minGroups":1,"maxGroups":1}]} else {} end));
      [.[] | select(.kind == "PropagationPolicy")] as $policies |
      ($policies | length) == (if $profile == "smurf-child" then 4 else 3 end) and
      any($policies[]; exact_propagation("rgw-analysis-web-dataset-seeder-to-b";
        [selector("batch/v1"; "Job"; "rgw-analysis-web-dataset-seeder")]; ["b"]; true; true)) and
      any($policies[]; exact_propagation("rgw-analysis-web-analyzer-to-c";
        [selector("batch/v1"; "Job"; "rgw-analysis-web-analyzer")]; ["c"]; true; true)) and
      any($policies[]; exact_propagation("rgw-analysis-web-result-web-to-b";
        [selector("apps/v1"; "Deployment"; "rgw-analysis-web-result-web"),
         selector("v1"; "Service"; "rgw-analysis-web-result-web")]; ["b"]; true; true)) and
      (if $profile == "smurf-child" then
        any($policies[]; exact_propagation("rgw-analysis-web-runtime-credentials-to-b-c";
          [selector("external-secrets.io/v1beta1"; "ExternalSecret"; "rgw-analysis-web-rgw")];
          ["b", "c"]; false; false))
       else true end)
    ' >/dev/null || fail "invalid $source_contract RGW propagation policy contract"

  helm lint "$chart_dir" -f "$values_file"
  chart_render="$tmp/$environment-$name-chart.yaml"
  helm template "$name" "$chart_dir" --namespace "$namespace" -f "$values_file" > "$chart_render"
  yq e -e 'select(.kind == "Secret" or .kind == "ExternalSecret" or .kind == "PropagationPolicy" or .kind == "OverridePolicy" or .kind == "Namespace" or .kind == "StorageClass" or .kind == "CustomResourceDefinition" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")' "$chart_render" >/dev/null 2>&1 &&
    fail "feature chart renders a forbidden or cluster-specific resource"
  if [ "$source_contract" = smurf-child ]; then
    endpoint="$(yq e -r '.storage.endpointUrl' "$values_file")"
    bucket="$(yq e -r '.storage.bucket' "$values_file")"
    region="$(yq e -r '.storage.region' "$values_file")"
    wait_seconds="$(yq e -r '.storage.waitSeconds' "$values_file")"
    poll_seconds="$(yq e -r '.storage.pollIntervalSeconds' "$values_file")"
    yq e -o=json -I=0 'select(.kind == "ConfigMap" and .metadata.name == "rgw-analysis-web-runtime")' "$chart_render" |
      jq -s -e \
        --arg endpoint "$endpoint" \
        --arg bucket "$bucket" \
        --arg region "$region" \
        --arg wait_seconds "$wait_seconds" \
        --arg poll_seconds "$poll_seconds" '
          length == 1 and
          .[0].data == {
            "S3_ENDPOINT_URL": $endpoint,
            "S3_BUCKET": $bucket,
            "AWS_DEFAULT_REGION": $region,
            "S3_WAIT_SECONDS": $wait_seconds,
            "S3_POLL_INTERVAL_SECONDS": $poll_seconds
          }
        ' >/dev/null || fail "rendered Smurf runtime ConfigMap does not match release values"
  fi

  mapfile -t rendered_images < <(yq e -r -N '.. | select(tag == "!!map") | (.containers[]?.image, .initContainers[]?.image) | select(. != null)' "$chart_render" | sort -u)
  [ "${#rendered_images[@]}" -gt 0 ] || fail "chart renders no images"
  for image in "${rendered_images[@]}"; do
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] || fail "rendered image lacks a digest: $image"
    [[ "$image" != *:latest@* ]] || fail "rendered latest image is forbidden"
  done
  yq e -r -N '.images[] | .repository + ":" + .tag + "@" + .digest' "$values_file" |
    LC_ALL=C sort -u > "$tmp/$environment-$name-expected-images.txt"
  printf '%s\n' "${rendered_images[@]}" |
    LC_ALL=C sort -u > "$tmp/$environment-$name-rendered-images.txt"
  cmp -s "$tmp/$environment-$name-expected-images.txt" "$tmp/$environment-$name-rendered-images.txt" ||
    fail "rendered images do not exactly match release values"
  yq e -e 'select(.kind == "Service") | select(.spec.type != "ClusterIP" or (.metadata.annotations | type) != "!!map" or (.metadata.annotations | length) == 0)' "$chart_render" >/dev/null 2>&1 &&
    fail "base Services must be annotated ClusterIP resources"
  yq e -o=json -I=0 "$chart_render" | jq -s -e --arg release "$name" '
    def selector_matches($selector; $labels):
      ($selector | type) == "object" and ($selector | length) > 0 and
      ($selector | to_entries | all(. as $entry | $labels[$entry.key] == $entry.value));
    ([.[] | select(.kind == "Deployment" or .kind == "Job") |
      select(.metadata.labels["scalex.io/release"] != $release or
             (.metadata.labels["scalex.io/component"] // "") == "" or
             .spec.template.metadata.labels["scalex.io/release"] != $release or
             (.spec.template.metadata.labels["scalex.io/component"] // "") == "")] | length) == 0 and
    ([.[] as $service | select($service.kind == "Service") |
      select(any(.[]; .kind == "Deployment" and
        selector_matches($service.spec.selector; .spec.template.metadata.labels)) | not)] | length) == 0
  ' >/dev/null || fail "workload labels or Service selectors do not match"

  while IFS=$'\t' read -r api_version kind resource_name; do
    API_VERSION="$api_version" KIND="$kind" RESOURCE_NAME="$resource_name" yq e -e '
      select(.apiVersion == strenv(API_VERSION) and .kind == strenv(KIND) and .metadata.name == strenv(RESOURCE_NAME))
    ' "$chart_render" "$dependency_render" >/dev/null || fail "policy selector has no rendered resource: $kind/$resource_name"
  done < <(yq e -r -N 'select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") | .spec.resourceSelectors[] | [.apiVersion, .kind, .name] | @tsv' "$policy_render")

  while IFS=$'\t' read -r api_version kind resource_name; do
    selector_count="$(yq e -r -N '
      select(.kind == "PropagationPolicy") | .spec.resourceSelectors[] |
      [.apiVersion, .kind, .name] | @tsv
    ' "$policy_render" | awk -F '\t' -v api="$api_version" -v kind="$kind" -v name="$resource_name" '
      $1 == api && $2 == kind && $3 == name { count++ }
      END { print count + 0 }
    ')"
    [ "$selector_count" -eq 1 ] || fail "rendered workload must have exactly one propagation selector: $kind/$resource_name"
  done < <(
    yq e -r -N '
      select(.kind == "Deployment" or .kind == "Job" or .kind == "Service" or .kind == "ExternalSecret") |
      [.apiVersion, .kind, .metadata.name] | @tsv
    ' "$chart_render" "$dependency_render" |
      sed '/^[[:space:]]*$/d'
  )

  identities="$tmp/$environment-$name-identities.txt"
  NAMESPACE="$namespace" yq e -r -N '
    select(. != null) |
    [.apiVersion, .kind, (.metadata.namespace // strenv(NAMESPACE)), .metadata.name] | @tsv
  ' "$chart_render" "$dependency_render" "$policy_render" | sort > "$identities"
  [ -z "$(uniq -d "$identities")" ] || fail "duplicate rendered resource identity"
  cat "$identities" >>"$tmp/rendered-identities.txt"

  NAMESPACE="$namespace" yq e -r -N '
    select(.kind == "ExternalSecret") |
    [(.metadata.namespace // strenv(NAMESPACE)), .spec.target.name] | @tsv
  ' "$dependency_render" >>"$tmp/external-secret-targets.txt"

  if [ -n "$VALIDATE_BASE_REF" ] && git -C "$ROOT" cat-file -e "$VALIDATE_BASE_REF:$descriptor_rel" 2>/dev/null; then
    previous_revision="$(git -C "$ROOT" show "$VALIDATE_BASE_REF:$descriptor_rel" | yq e -r '.source.revision')"
    previous_images="$(git -C "$ROOT" show "$VALIDATE_BASE_REF:$values_rel" | yq e -o=json -I=0 '.images // {}')"
    current_images="$(yq e -o=json -I=0 '.images // {}' "$values_file")"
    [ "$previous_images" = "$current_images" ] || [ "$previous_revision" != "$revision" ] ||
      fail "image promotion must update source revision atomically: $release_rel"
  fi
done

[ -z "$(sort "$tmp/application-identities.txt" | uniq -d)" ] || fail "duplicate generated Application identity"
[ -z "$(sort "$tmp/release-namespaces.txt" | uniq -d)" ] || fail "duplicate release namespace"
[ -z "$(sort "$tmp/rendered-identities.txt" | uniq -d)" ] || fail "duplicate aggregate rendered resource identity"
[ -z "$(sort "$tmp/external-secret-targets.txt" | uniq -d)" ] || fail "duplicate namespace-scoped ExternalSecret target"
[ -z "$(sort "$tmp/load-balancer-ip-claims.txt" | uniq -d)" ] || fail "duplicate explicit LoadBalancer IP"

mapfile -t federation_yaml < <(find "$ROOT/bootstrap" "$ROOT/releases" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
for manifest in "${federation_yaml[@]}"; do
  yq e '.' "$manifest" >/dev/null
  yq e -e 'select(.kind == "Secret")' "$manifest" >/dev/null 2>&1 && fail "Secret resources are forbidden: $manifest"
done

echo "federation validation passed"
