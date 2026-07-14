#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENVIRONMENT="${1:-poc}"
RELEASE="${2:-rgw-analysis-web}"
KARMADA_CONTEXT="${KARMADA_CONTEXT:-karmada}"
MEMBER_CONTEXTS="${MEMBER_CONTEXTS:-b,c}"
OBSERVE_ATTEMPTS="${OBSERVE_ATTEMPTS:-30}"
OBSERVE_INTERVAL_SECONDS="${OBSERVE_INTERVAL_SECONDS:-10}"
KUBECTL="${KUBECTL:-kubectl}"
CURL_BIN="${CURL_BIN:-curl}"
RELEASE_DIR="$ROOT/releases/$ENVIRONMENT/$RELEASE"
DESCRIPTOR="$RELEASE_DIR/release.yaml"
VALUES="$RELEASE_DIR/values.yaml"
LAST_ERROR="observation did not run"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

for tool in "$KUBECTL" "$CURL_BIN" jq yq; do
  command -v "$tool" >/dev/null 2>&1 || fail "required observation tool is unavailable: $tool"
done

[[ "$ENVIRONMENT" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid environment"
[[ "$RELEASE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "invalid release"
[ "$KARMADA_CONTEXT" = karmada ] || fail "KARMADA_CONTEXT must be karmada"
[ "$MEMBER_CONTEXTS" = b,c ] || fail "MEMBER_CONTEXTS must be b,c"
[[ "$OBSERVE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || fail "OBSERVE_ATTEMPTS must be positive"
[[ "$OBSERVE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || fail "OBSERVE_INTERVAL_SECONDS must be non-negative"
test -f "$DESCRIPTOR" || fail "release descriptor not found"
test -f "$VALUES" || fail "release values not found"

descriptor_environment="$(yq e -r '.environment' "$DESCRIPTOR")"
descriptor_name="$(yq e -r '.name' "$DESCRIPTOR")"
[ "$descriptor_environment" = "$ENVIRONMENT" ] || fail "release descriptor environment does not match its directory"
[ "$descriptor_name" = "$RELEASE" ] || fail "release descriptor name does not match its directory"
NAMESPACE="$(yq e -r '.namespace' "$DESCRIPTOR")"
[[ "$NAMESPACE" =~ ^scalex-[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "release namespace is invalid"

expected_revision="$(yq e -r '.source.revision' "$DESCRIPTOR")"
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || fail "release revision is not immutable"
renderer="$(yq e -r '.renderer' "$DESCRIPTOR")"
[ "$renderer" = helm/v1 ] || fail "runtime observer supports only helm/v1 releases"
source_repository="$(yq e -r '.source.repoURL' "$DESCRIPTOR")"
source_path="$(yq e -r '.source.path' "$DESCRIPTOR")"
case "$source_repository|$source_path" in
  https://github.com/BellTigerLee/smurf-child.git\|charts/rgw-analysis-web) source_contract=smurf-child ;;
  https://github.com/SJoon99/scalex-feature-poc.git\|chart) source_contract=legacy-poc ;;
  *) fail "unsupported RGW source contract: $source_repository/$source_path" ;;
esac
expected_run_id=""
if [ "$source_contract" = smurf-child ]; then
  expected_run_id="$(yq e -r '.runId' "$VALUES")"
  [[ "$expected_run_id" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    fail "Smurf child runId is missing or invalid"
fi
if [ "$source_contract" = smurf-child ]; then
  storage_path=storage
  expected_secret="$(yq e -r '.credentials.existingSecret' "$VALUES")"
  expected_access_key="$(yq e -r '.credentials.accessKeyIdKey' "$VALUES")"
  expected_secret_key="$(yq e -r '.credentials.secretAccessKeyKey' "$VALUES")"
else
  storage_path=s3
  expected_secret="$(yq e -r '.s3.secretName' "$VALUES")"
  expected_access_key=AWS_ACCESS_KEY_ID
  expected_secret_key=AWS_SECRET_ACCESS_KEY
fi
[[ "$expected_secret" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "runtime Secret name is invalid"
[[ "$expected_access_key" =~ ^[-._a-zA-Z0-9]+$ ]] || fail "runtime access-key field is invalid"
[[ "$expected_secret_key" =~ ^[-._a-zA-Z0-9]+$ ]] || fail "runtime secret-key field is invalid"
expected_endpoint="$(STORAGE_PATH="$storage_path" yq e -r '.[strenv(STORAGE_PATH)].endpointUrl' "$VALUES")"
expected_bucket="$(STORAGE_PATH="$storage_path" yq e -r '.[strenv(STORAGE_PATH)].bucket' "$VALUES")"
expected_region="$(STORAGE_PATH="$storage_path" yq e -r '.[strenv(STORAGE_PATH)].region' "$VALUES")"
expected_wait_seconds="$(STORAGE_PATH="$storage_path" yq e -r '.[strenv(STORAGE_PATH)].waitSeconds' "$VALUES")"
expected_poll_seconds="$(STORAGE_PATH="$storage_path" yq e -r '.[strenv(STORAGE_PATH)].pollIntervalSeconds' "$VALUES")"
yq e -r '.images | to_entries[] | .value.repository + ":" + .value.tag + "@" + .value.digest' "$VALUES" |
  LC_ALL=C sort -u > "$tmp/expected-images"
[ -s "$tmp/expected-images" ] || fail "release has no expected images"
yq e -e '[.images[] | .tag != "latest"] | all' "$VALUES" >/dev/null || fail "release contains a latest image tag"
if grep -Ev '^[^[:space:]@]+:[^[:space:]@]+@sha256:[0-9a-f]{64}$' "$tmp/expected-images" | grep -q .; then
  fail "release contains a mutable image coordinate"
fi

read_object() {
  local context="$1"
  local namespace="$2"
  local resource="$3"
  local name="$4"
  local api_version="$5"
  local kind="$6"
  local output="$7"
  if ! "$KUBECTL" --context "$context" -n "$namespace" get "$resource" "$name" -o json >"$output" 2>"$tmp/kubectl.err"; then
    LAST_ERROR="unable to read $context $resource/$name"
    return 1
  fi
  jq -e \
    --arg apiVersion "$api_version" \
    --arg kind "$kind" \
    --arg name "$name" \
    --arg namespace "$namespace" '
      type == "object" and
      .apiVersion == $apiVersion and
      .kind == $kind and
      .metadata.name == $name and
      .metadata.namespace == $namespace
    ' "$output" >/dev/null || {
    LAST_ERROR="wrong identity returned for $context $resource/$name"
    return 1
  }
}

read_bindings() {
  local output="$1"
  if ! "$KUBECTL" --context "$KARMADA_CONTEXT" -n "$NAMESPACE" \
    get resourcebindings.work.karmada.io -o json >"$output" 2>"$tmp/kubectl.err"; then
    LAST_ERROR="unable to read karmada resource bindings"
    return 1
  fi
  jq -e --arg namespace "$NAMESPACE" '
    .apiVersion == "work.karmada.io/v1alpha2" and
    .kind == "ResourceBindingList" and
    (.items | type) == "array" and
    all(.items[];
      .apiVersion == "work.karmada.io/v1alpha2" and
      .kind == "ResourceBinding" and
      (.metadata.name | type) == "string" and
      (.metadata.name | length) > 0 and
      .metadata.namespace == $namespace)
  ' "$output" >/dev/null || {
    LAST_ERROR="invalid resource binding response"
    return 1
  }
}

expected_endpoint_for_context() {
  local context="$1"
  local override_root="$RELEASE_DIR/karmada/overrides"
  local candidate_file="$tmp/endpoint-overrides-$context.txt"
  local -a override_files=()
  local -a candidates=()
  CONTEXT_ENDPOINT="$expected_endpoint"
  [ -d "$override_root" ] || return 0
  mapfile -t override_files < <(find "$override_root" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  [ "${#override_files[@]}" -gt 0 ] || return 0
  if ! CLUSTER="$context" yq e -r -N '
    select(.kind == "OverridePolicy") |
    .spec.resourceSelectors[] as $selector |
    select($selector.apiVersion == "v1" and $selector.kind == "ConfigMap" and $selector.name == "rgw-analysis-web-runtime") |
    .spec.overrideRules[] |
    .targetCluster.clusterNames[] as $cluster |
    select($cluster == strenv(CLUSTER)) |
    .overriders.plaintext[] |
    select(.path == "/data/S3_ENDPOINT_URL" and .operator == "replace") |
    .value
  ' "${override_files[@]}" | sed '/^[[:space:]]*$/d' > "$candidate_file"; then
    LAST_ERROR="unable to evaluate S3 endpoint overrides for member $context"
    return 1
  fi
  mapfile -t candidates < "$candidate_file"
  if [ "${#candidates[@]}" -gt 1 ]; then
    LAST_ERROR="multiple S3 endpoint overrides target member $context"
    return 1
  fi
  if [ "${#candidates[@]}" -eq 1 ]; then
    CONTEXT_ENDPOINT="${candidates[0]}"
  fi
}

check_bindings() {
  local file="$1"
  jq -e --arg namespace "$NAMESPACE" --arg profile "$source_contract" '
    def applied($clusters):
      ([.status.aggregatedStatus[]? |
        select(.applied == true) | .clusterName] | sort) == ($clusters | sort);
    def placed($apiVersion; $kind; $name; $clusters):
      [.items[] |
        select(.spec.resource.apiVersion == $apiVersion and
               .spec.resource.kind == $kind and
               .spec.resource.namespace == $namespace and
               .spec.resource.name == $name and
               (([.spec.clusters[].name] | sort) == ($clusters | sort)) and
               applied($clusters))] | length == 1;
    placed("batch/v1"; "Job"; "rgw-analysis-web-dataset-seeder"; ["b"]) and
    placed("batch/v1"; "Job"; "rgw-analysis-web-analyzer"; ["c"]) and
    placed("apps/v1"; "Deployment"; "rgw-analysis-web-result-web"; ["b"]) and
    placed("v1"; "Service"; "rgw-analysis-web-result-web"; ["b"])
  ' "$file" >/dev/null || {
    LAST_ERROR="Karmada placement is missing, partial, or not fully applied"
    return 1
  }
}

check_configmap() {
  local file="$1"
  local config="$2"
  local context="${3:-}"
  if [ "$config" = scripts ]; then
    jq -e --arg release "$RELEASE" '
      .metadata.labels["scalex.io/release"] == $release and
      (.data["dataset-seeder.sh"] | type) == "string" and
      (.data["dataset-seeder.sh"] | length) > 0 and
      (.data["analyzer.sh"] | type) == "string" and
      (.data["analyzer.sh"] | length) > 0 and
      (.data["result-sync.sh"] | type) == "string" and
      (.data["result-sync.sh"] | length) > 0
    ' "$file" >/dev/null || {
      LAST_ERROR="member scripts ConfigMap is stale or incomplete"
      return 1
    }
  elif [ "$source_contract" = legacy-poc ]; then
    expected_endpoint_for_context "$context" || return 1
    jq -e \
      --arg release "$RELEASE" \
      --arg endpoint "$CONTEXT_ENDPOINT" \
      --arg bucket "$expected_bucket" \
      --arg region "$expected_region" '
      .metadata.labels["scalex.io/release"] == $release and
      .metadata.labels["scalex.io/component"] == "result-web" and
      .data.S3_ENDPOINT_URL == $endpoint and
      .data.S3_BUCKET == $bucket and
      .data.AWS_DEFAULT_REGION == $region and
      (.data["nginx.conf"] | type) == "string" and
      (.data["nginx.conf"] | length) > 0
    ' "$file" >/dev/null || {
      LAST_ERROR="member runtime ConfigMap is stale or incomplete"
      return 1
    }
  else
    expected_endpoint_for_context "$context" || return 1
    jq -e \
      --arg release "$RELEASE" \
      --arg endpoint "$CONTEXT_ENDPOINT" \
      --arg bucket "$expected_bucket" \
      --arg region "$expected_region" \
      --arg wait_seconds "$expected_wait_seconds" \
      --arg poll_seconds "$expected_poll_seconds" '
      .metadata.labels["scalex.io/release"] == $release and
      .metadata.labels["scalex.io/component"] == "runtime" and
      .data.S3_ENDPOINT_URL == $endpoint and
      .data.S3_BUCKET == $bucket and
      .data.AWS_DEFAULT_REGION == $region and
      .data.S3_WAIT_SECONDS == $wait_seconds and
      .data.S3_POLL_INTERVAL_SECONDS == $poll_seconds
    ' "$file" >/dev/null || {
      LAST_ERROR="member Smurf runtime ConfigMap is stale or incomplete"
      return 1
    }
  fi
}

check_runtime_secret() {
  local file="$1"
  jq -e \
    --arg access_key "$expected_access_key" \
    --arg secret_key "$expected_secret_key" '
    .type == "Opaque" and
    (.data | type) == "object" and
    (.data[$access_key] | type) == "string" and
    (.data[$access_key] | length) > 0 and
    (.data[$secret_key] | type) == "string" and
    (.data[$secret_key] | length) > 0
  ' "$file" >/dev/null || {
    LAST_ERROR="runtime Secret is missing required credential keys"
    return 1
  }
}

check_deployment() {
  local file="$1"
  jq -e '
    (.spec.replicas // 1) as $wanted |
    .status.observedGeneration >= .metadata.generation and
    (.status.updatedReplicas // 0) == $wanted and
    (.status.availableReplicas // 0) == $wanted and
    (.status.unavailableReplicas // 0) == 0
  ' "$file" >/dev/null || {
    LAST_ERROR="result web Deployment is not ready"
    return 1
  }
}

check_job() {
  local file="$1"
  local label="$2"
  jq -e '
    (.status.failed // 0) == 0 and
    (.status.succeeded // 0) > 0 and
    any(.status.conditions[]?; .type == "Complete" and .status == "True")
  ' "$file" >/dev/null || {
    LAST_ERROR="$label Job is incomplete or failed"
    return 1
  }
}

check_images() {
  jq -r '.spec.template.spec | (.initContainers[]?.image, .containers[]?.image)' \
    "$tmp/deployment.json" "$tmp/seeder.json" "$tmp/analyzer.json" |
    LC_ALL=C sort -u > "$tmp/actual-images"
  if ! cmp -s "$tmp/expected-images" "$tmp/actual-images"; then
    LAST_ERROR="member workload images do not match the release digests"
    return 1
  fi
}

check_http() {
  local file="$1"
  local host port url
  host="$(jq -r '.status.loadBalancer.ingress[0] | .ip // .hostname // empty' "$file")"
  port="$(jq -r '.spec.ports[] | select(.name == "http" or .port == 80) | .port' "$file" | head -n 1)"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || {
    LAST_ERROR="result web Service has no safe reachable address"
    return 1
  }
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || {
    LAST_ERROR="result web Service has no HTTP port"
    return 1
  }
  [ "$port" -le 65535 ] || {
    LAST_ERROR="result web Service HTTP port is invalid"
    return 1
  }
  url="http://$host:$port/"
  if ! "$CURL_BIN" --proto '=http,https' --max-time 10 --fail --silent --show-error "$url" > "$tmp/result.html"; then
    LAST_ERROR="result web HTTP endpoint is unreachable"
    return 1
  fi
  if [ "$source_contract" = smurf-child ]; then
    if ! grep -Fq 'data-state="success"' "$tmp/result.html" ||
      ! grep -Fq 'aria-busy="false"' "$tmp/result.html" ||
      ! grep -Fq 'Analysis complete' "$tmp/result.html" ||
      ! grep -Fq "data-field=\"run-id\">$expected_run_id</code>" "$tmp/result.html"; then
      LAST_ERROR="Smurf result web response is loading, stale, or for a different run"
      return 1
    fi
  else
    if ! grep -Fq 'RGW Analysis Result' "$tmp/result.html" ||
      ! grep -Fq '<dl>' "$tmp/result.html" ||
      ! grep -Fq '<dt>Rows</dt>' "$tmp/result.html" ||
      ! grep -Fq '<dt>Amount sum</dt>' "$tmp/result.html" ||
      ! grep -Fq '<dt>Amount average</dt>' "$tmp/result.html" ||
      grep -Fq 'Waiting for analyzer output' "$tmp/result.html"; then
      LAST_ERROR="legacy result web response is loading, stale, or incomplete"
      return 1
    fi
  fi
}

check_once() {
  read_bindings "$tmp/bindings.json" || return 1
  check_bindings "$tmp/bindings.json" || return 1

  local context
  for context in b c; do
    read_object "$context" "$NAMESPACE" secrets "$expected_secret" \
      v1 Secret "$tmp/secret-$context.json" || return 1
    check_runtime_secret "$tmp/secret-$context.json" || return 1
    if [ "$source_contract" = legacy-poc ]; then
      read_object "$context" "$NAMESPACE" configmaps rgw-analysis-web-scripts \
        v1 ConfigMap "$tmp/scripts-$context.json" || return 1
      check_configmap "$tmp/scripts-$context.json" scripts || return 1
    fi
    read_object "$context" "$NAMESPACE" configmaps rgw-analysis-web-runtime \
      v1 ConfigMap "$tmp/runtime-$context.json" || return 1
    check_configmap "$tmp/runtime-$context.json" runtime "$context" || return 1
  done

  read_object b "$NAMESPACE" deployments.apps rgw-analysis-web-result-web \
    apps/v1 Deployment "$tmp/deployment.json" || return 1
  read_object b "$NAMESPACE" jobs.batch rgw-analysis-web-dataset-seeder \
    batch/v1 Job "$tmp/seeder.json" || return 1
  read_object c "$NAMESPACE" jobs.batch rgw-analysis-web-analyzer \
    batch/v1 Job "$tmp/analyzer.json" || return 1
  read_object b "$NAMESPACE" services rgw-analysis-web-result-web \
    v1 Service "$tmp/service.json" || return 1
  check_deployment "$tmp/deployment.json" || return 1
  check_job "$tmp/seeder.json" dataset-seeder || return 1
  check_job "$tmp/analyzer.json" analyzer || return 1
  check_images || return 1
  check_http "$tmp/service.json" || return 1
}

for ((attempt = 1; attempt <= OBSERVE_ATTEMPTS; attempt++)); do
  if check_once; then
    echo "runtime observation passed for Karmada/member evidence: $ENVIRONMENT/$RELEASE $source_contract desired revision $expected_revision; Tower Argo sync/health NOT RUN"
    exit 0
  fi
  if [ "$attempt" -lt "$OBSERVE_ATTEMPTS" ]; then
    sleep "$OBSERVE_INTERVAL_SECONDS"
  fi
done

fail "runtime observation failed after $OBSERVE_ATTEMPTS attempt(s): $LAST_ERROR"
