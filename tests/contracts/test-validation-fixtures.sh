#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in check-jsonschema git helm jq tar yq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "SKIP: missing $tool" >&2
    exit 77
  }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_source() {
  local target="$1"
  mkdir -p "$target/charts/rgw-analysis-web"
  cp -R "$ROOT/tests/fixtures/feature-chart/." "$target/charts/rgw-analysis-web/"
  git -C "$target" init -q
  git -C "$target" config user.email fixture@example.invalid
  git -C "$target" config user.name fixture
  git -C "$target" remote add origin https://github.com/BellTigerLee/smurf-child.git
  git -C "$target" add charts
  git -C "$target" commit -qm fixture
}

make_federation() {
  local target="$1"
  local source="$2"
  local revision
  mkdir -p "$target"
  cp -R "$ROOT/bootstrap" "$ROOT/contracts" "$ROOT/releases" "$ROOT/scripts" "$target/"
  rm -rf "$target/releases"
  mkdir -p "$target/releases/poc"
  cp -R "$ROOT/releases/cuty/rgw-analysis-web" "$target/releases/poc/"
  revision="$(git -C "$source" rev-parse HEAD)"
  cp "$ROOT/tests/fixtures/contracts/valid-release.yaml" "$target/releases/poc/rgw-analysis-web/release.yaml"
  cp "$ROOT/tests/fixtures/contracts/valid-values.yaml" "$target/releases/poc/rgw-analysis-web/values.yaml"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$target/releases/poc/rgw-analysis-web/release.yaml"
  REVISION="$revision" yq -i '
    .images.flow.tag = "sha-" + strenv(REVISION) |
    .images.web.tag = "sha-" + strenv(REVISION) |
    .images.flow.sourceRevision = strenv(REVISION) |
    .images.web.sourceRevision = strenv(REVISION)
  ' "$target/releases/poc/rgw-analysis-web/values.yaml"
  find "$target/releases/poc/rgw-analysis-web/dependencies" \
    "$target/releases/poc/rgw-analysis-web/karmada" -type f \
    \( -name '*.yaml' -o -name '*.yml' \) -exec \
    sed -i 's/scalex-cuty-rgw-analysis-web/scalex-rgw-analysis-web/g; s#scalex/cuty/rgw-analysis-web/rgw#scalex/poc/rgw-analysis-web/rgw#g; s/scalex-cuty-rgw/scalex-poc-rgw/g' {} +
}

expect_reject() {
  local name="$1"
  local expected="$2"
  local federation="$tmp/$name-federation"
  local source="$tmp/$name-sources/smurf-child"
  mkdir -p "$(dirname "$source")"
  make_source "$source"
  make_federation "$federation" "$source"
  shift 2
  "$@" "$federation" "$source"
  if FEATURE_REPOS_ROOT="$(dirname "$source")" "$federation/scripts/validate.sh" >"$tmp/$name.log" 2>&1; then
    echo "expected validation rejection: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$name.log" || {
    echo "wrong failure for $name" >&2
    cat "$tmp/$name.log" >&2
    exit 1
  }
}

set_unknown_field() {
  yq -i '.unknown = true' "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_invalid_namespace_shape() {
  yq -i '.namespace = "other"' "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_invalid_chart_path_shape() {
  yq -i '.source.path = "deploy/rgw-analysis-web"' "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_cross_field_values_path() {
  yq -i '.values.path = "releases/poc/another-release/values.yaml"' "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_mutable_tag() {
  yq -i '.images.flow.tag = "latest"' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_stale_revision() {
  yq -i '.images.web.sourceRevision = "2222222222222222222222222222222222222222"' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_missing_digest() {
  yq -i '.images.web.digest = ""' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_manual_pinned_images() {
  yq -i '.promotion.mode = "pinned"' "$1/releases/poc/rgw-analysis-web/release.yaml"
  yq -i '
    .images.flow.repository = "belltigerlee/test-image-flow" |
    .images.web.repository = "belltigerlee/test-image-web"
  ' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_tracked_manual_repository() {
  yq -i '.images.flow.repository = "belltigerlee/test-image-flow"' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_unapproved_pinned_repository() {
  set_manual_pinned_images "$1" "$2"
  yq -i '.images.web.repository = "example/other-web"' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_selector_mismatch() {
  yq -i '.spec.resourceSelectors[0].name = "missing"' "$1/releases/poc/rgw-analysis-web/karmada/propagation/analyzer-to-c.yaml"
}

set_empty_annotations() {
  yq -i '.resultWeb.service.annotations = {}' "$1/releases/poc/rgw-analysis-web/values.yaml"
}

set_dirty_source() {
  touch "$2/charts/rgw-analysis-web/untracked"
}

promote_revision() {
  local federation="$1"
  local source="$2"
  local revision
  revision="$(git -C "$source" rev-parse HEAD)"
  REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$federation/releases/poc/rgw-analysis-web/release.yaml"
  REVISION="$revision" yq -i '
    .images.flow.tag = "sha-" + strenv(REVISION) |
    .images.web.tag = "sha-" + strenv(REVISION) |
    .images.flow.sourceRevision = strenv(REVISION) |
    .images.web.sourceRevision = strenv(REVISION)
  ' "$federation/releases/poc/rgw-analysis-web/values.yaml"
}

set_symlink_source() {
  ln -s Chart.yaml "$2/charts/rgw-analysis-web/link"
  git -C "$2" add charts
  git -C "$2" commit -qm symlink
  promote_revision "$1" "$2"
}

set_forbidden_secret() {
  printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'metadata:' '  name: forbidden' > "$2/charts/rgw-analysis-web/templates/secret.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm secret
  promote_revision "$1" "$2"
}

set_origin_mismatch() {
  git -C "$2" remote set-url origin https://github.com/example/other.git
}

set_unapproved_source() {
  yq -i '.source.repoURL = "https://github.com/example/other.git"' "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_project_wildcard() {
  yq -i '.spec.sourceRepos[1] = "https://github.com/*"' "$1/bootstrap/appproject.yaml"
}

set_extra_applicationset_source() {
  yq -i '.spec.template.spec.sources += [{"repoURL":"https://github.com/SJoon99/scalex-federation.git","targetRevision":"main","path":"extras"}]' \
    "$1/bootstrap/applicationset.yaml"
}

set_generator_repository_mismatch() {
  yq -i '.spec.generators[0].git.repoURL = "https://github.com/example/other.git"' \
    "$1/bootstrap/applicationset.yaml"
}

set_generator_path_mismatch() {
  yq -i '.spec.generators[0].git.files[0].path = "releases/other/*.yaml"' \
    "$1/bootstrap/applicationset.yaml"
}

set_policy_source_repository_mismatch() {
  yq -i '.spec.template.spec.sources[1].repoURL = "https://github.com/example/other.git"' \
    "$1/bootstrap/applicationset.yaml"
}

set_dependency_source_repository_mismatch() {
  yq -i '.spec.template.spec.sources[2].repoURL = "https://github.com/example/other.git"' \
    "$1/bootstrap/applicationset.yaml"
}

set_application_name_template_mismatch() {
  yq -i '.spec.template.metadata.name = "federation-{{ .name }}"' \
    "$1/bootstrap/applicationset.yaml"
}

set_malformed_descriptor() {
  printf '%s\n' 'apiVersion: scalex.io/v1alpha1' 'source: [' > "$1/releases/poc/rgw-analysis-web/release.yaml"
}

set_external_secret_template_payload() {
  yq -i '.spec.target.template.data.AWS_SECRET_ACCESS_KEY = "embedded-value"' \
    "$1/releases/poc/rgw-analysis-web/dependencies/external-secret.yaml"
}

set_external_secret_extra_remote_ref() {
  yq -i '.spec.data = [{"secretKey":"extra","remoteRef":{"key":"another/key"}}]' \
    "$1/releases/poc/rgw-analysis-web/dependencies/external-secret.yaml"
}

set_duplicate_policy() {
  cp "$1/releases/poc/rgw-analysis-web/karmada/propagation/analyzer-to-c.yaml" \
    "$1/releases/poc/rgw-analysis-web/karmada/propagation/analyzer-copy.yaml"
}

set_feature_policy() {
  printf '%s\n' \
    'apiVersion: policy.karmada.io/v1alpha1' \
    'kind: PropagationPolicy' \
    'metadata:' \
    '  name: child-owned' > "$2/charts/rgw-analysis-web/templates/placement.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm placement
  promote_revision "$1" "$2"
}

set_cluster_resource() {
  printf '%s\n' 'apiVersion: v1' 'kind: Namespace' 'metadata:' '  name: child-owned' > "$2/charts/rgw-analysis-web/templates/namespace.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm namespace
  promote_revision "$1" "$2"
}

set_service_selector_mismatch() {
  sed -i '/kind: Service/,$ s/scalex.io\/component: result-web/scalex.io\/component: wrong/' "$2/charts/rgw-analysis-web/templates/web.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm selector
  promote_revision "$1" "$2"
}

set_hardcoded_rendered_image() {
  sed -i '0,/image:/s|image:.*|image: "example.invalid/unapproved:fixed@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"|' \
    "$2/charts/rgw-analysis-web/templates/jobs.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm hardcoded-image
  promote_revision "$1" "$2"
}

set_unplaced_workload() {
  cp "$2/charts/rgw-analysis-web/templates/jobs.yaml" "$2/charts/rgw-analysis-web/templates/unplaced.yaml"
  sed -i \
    -e 's/rgw-analysis-web-dataset-seeder/rgw-analysis-web-unplaced/g' \
    -e 's/dataset-seeder/unplaced/g' \
    -e '/^---$/,$d' \
    "$2/charts/rgw-analysis-web/templates/unplaced.yaml"
  git -C "$2" add charts
  git -C "$2" commit -qm unplaced-workload
  promote_revision "$1" "$2"
}

set_unplaced_service() {
  cat > "$2/charts/rgw-analysis-web/templates/unplaced-service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: rgw-analysis-web-unplaced
  annotations:
    scalex.io/exposure: internal
spec:
  type: ClusterIP
  selector:
    scalex.io/release: rgw-analysis-web
    scalex.io/component: result-web
  ports:
    - name: http
      port: 81
      targetPort: 8080
EOF
  git -C "$2" add charts
  git -C "$2" commit -qm unplaced-service
  promote_revision "$1" "$2"
}

set_unsafe_image_override() {
  cp "$1/releases/poc/rgw-analysis-web/karmada/overrides/runtime-on-b.yaml" \
    "$1/releases/poc/rgw-analysis-web/karmada/overrides/unsafe-image.yaml"
  yq -i '
    .metadata.name = "rgw-analysis-web-unsafe-image" |
    .spec.resourceSelectors = [{
      "apiVersion": "apps/v1",
      "kind": "Deployment",
      "name": "rgw-analysis-web-result-web",
      "namespace": "scalex-rgw-analysis-web"
    }] |
    .spec.overrideRules[0].overriders.plaintext = [{
      "path": "/spec/template/spec/containers/0/image",
      "operator": "replace",
      "value": "example.invalid/attacker:latest"
    }]
  ' "$1/releases/poc/rgw-analysis-web/karmada/overrides/unsafe-image.yaml"
}

set_malformed_policy_identity() {
  yq -i 'del(.apiVersion) | del(.metadata.name)' \
    "$1/releases/poc/rgw-analysis-web/karmada/overrides/runtime-on-b.yaml"
}

set_wrong_analyzer_placement() {
  yq -i '.spec.placement.clusterAffinity.clusterNames = ["b"]' \
    "$1/releases/poc/rgw-analysis-web/karmada/propagation/analyzer-to-c.yaml"
}

set_submodule_source() {
  local dependency="$2-dependency"
  mkdir -p "$dependency"
  git -C "$dependency" init -q
  git -C "$dependency" config user.email fixture@example.invalid
  git -C "$dependency" config user.name fixture
  touch "$dependency/content"
  git -C "$dependency" add content
  git -C "$dependency" commit -qm dependency
  git -C "$2" -c protocol.file.allow=always submodule add -q "$dependency" charts/rgw-analysis-web/vendor
  git -C "$2" commit -qam submodule
  promote_revision "$1" "$2"
}

source="$tmp/pass-sources/smurf-child"
federation="$tmp/pass-federation"
mkdir -p "$(dirname "$source")"
make_source "$source"
make_federation "$federation" "$source"
if ! FEATURE_REPOS_ROOT="$(dirname "$source")" "$federation/scripts/validate.sh" >"$tmp/pass.log" 2>&1; then
  cat "$tmp/pass.log" >&2
  exit 1
fi
grep -Fq 'federation validation passed' "$tmp/pass.log"
set_dirty_source "$federation" "$source"
if ! FEATURE_REPOS_ROOT="$(dirname "$source")" "$federation/scripts/validate.sh" >"$tmp/dirty-source-pass.log" 2>&1; then
  cat "$tmp/dirty-source-pass.log" >&2
  exit 1
fi
grep -Fq 'federation validation passed' "$tmp/dirty-source-pass.log"

manual_source="$tmp/manual-pass-sources/smurf-child"
manual_federation="$tmp/manual-pass-federation"
mkdir -p "$(dirname "$manual_source")"
make_source "$manual_source"
make_federation "$manual_federation" "$manual_source"
set_manual_pinned_images "$manual_federation" "$manual_source"
if ! FEATURE_REPOS_ROOT="$(dirname "$manual_source")" "$manual_federation/scripts/validate.sh" >"$tmp/manual-pass.log" 2>&1; then
  cat "$tmp/manual-pass.log" >&2
  exit 1
fi
grep -Fq 'federation validation passed' "$tmp/manual-pass.log"

expect_reject unknown-field 'release schema validation failed' set_unknown_field
expect_reject invalid-namespace-shape 'release schema validation failed' set_invalid_namespace_shape
expect_reject invalid-chart-path-shape 'release schema validation failed' set_invalid_chart_path_shape
expect_reject cross-field-values-path 'values.path does not match release identity' set_cross_field_values_path
expect_reject mutable-tag 'image tag must be explicit and non-latest' set_mutable_tag
expect_reject stale-revision 'image sourceRevision is stale' set_stale_revision
expect_reject missing-digest 'image digest is not immutable' set_missing_digest
expect_reject tracked-manual-repository 'unexpected tracked Smurf image repository' set_tracked_manual_repository
expect_reject unapproved-pinned-repository 'unexpected pinned Smurf image repository' set_unapproved_pinned_repository
expect_reject selector-mismatch 'invalid smurf-child RGW propagation policy contract' set_selector_mismatch
expect_reject service-selector-mismatch 'workload labels or Service selectors do not match' set_service_selector_mismatch
expect_reject hardcoded-rendered-image 'rendered images do not exactly match release values' set_hardcoded_rendered_image
expect_reject unplaced-workload 'rendered workload must have exactly one propagation selector' set_unplaced_workload
expect_reject unplaced-service 'rendered workload must have exactly one propagation selector' set_unplaced_service
expect_reject unsafe-image-override 'invalid smurf-child RGW override policy contract' set_unsafe_image_override
expect_reject malformed-policy-identity 'invalid Karmada policy structure' set_malformed_policy_identity
expect_reject wrong-analyzer-placement 'invalid smurf-child RGW propagation policy contract' set_wrong_analyzer_placement
expect_reject empty-annotations 'base Services must be annotated ClusterIP resources' set_empty_annotations
expect_reject symlink-source 'chart tree contains a symlink or submodule' set_symlink_source
expect_reject submodule-source 'chart tree contains a symlink or submodule' set_submodule_source
expect_reject origin-mismatch 'feature origin does not match enrollment' set_origin_mismatch
expect_reject unapproved-source 'source URL/path is not enrolled' set_unapproved_source
expect_reject project-wildcard 'AppProject sourceRepos and children enrollment differ' set_project_wildcard
expect_reject malformed-descriptor 'release schema validation failed' set_malformed_descriptor
expect_reject external-secret-template-payload 'invalid RGW ExternalSecret structure' set_external_secret_template_payload
expect_reject external-secret-extra-remote-ref 'invalid RGW ExternalSecret structure' set_external_secret_extra_remote_ref
expect_reject extra-applicationset-source 'ApplicationSet sources must exactly match the v1 Helm release contract' set_extra_applicationset_source
expect_reject generator-repository-mismatch 'ApplicationSet generator must exactly discover Federation releases' set_generator_repository_mismatch
expect_reject generator-path-mismatch 'ApplicationSet generator must exactly discover Federation releases' set_generator_path_mismatch
expect_reject policy-source-repository-mismatch 'ApplicationSet sources must exactly match the v1 Helm release contract' set_policy_source_repository_mismatch
expect_reject dependency-source-repository-mismatch 'ApplicationSet sources must exactly match the v1 Helm release contract' set_dependency_source_repository_mismatch
expect_reject application-name-template-mismatch 'ApplicationSet name template must include environment and release' set_application_name_template_mismatch
expect_reject duplicate-policy 'invalid smurf-child RGW propagation policy contract' set_duplicate_policy
expect_reject forbidden-secret 'feature chart renders a forbidden or cluster-specific resource' set_forbidden_secret
expect_reject feature-policy 'feature chart renders a forbidden or cluster-specific resource' set_feature_policy
expect_reject cluster-resource 'feature chart renders a forbidden or cluster-specific resource' set_cluster_resource

echo "validation fixture tests passed"
