#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
observer="$ROOT/scripts/rgw-analysis-web/observe-release.sh"
fixture_root="$ROOT/tests/fixtures/runtime-observation"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_yq="$(command -v yq)"

test -x "$observer" || {
  echo "missing runtime observer: $observer" >&2
  exit 1
}

revision="$(yq e -r '.source.revision' "$ROOT/releases/poc/rgw-analysis-web/release.yaml")"
if yq e -e '.images.flow and .images.web' "$ROOT/releases/poc/rgw-analysis-web/values.yaml" >/dev/null 2>&1; then
  flow_key=flow
  web_key=web
else
  flow_key=awsCli
  web_key=nginx
fi
flow_image="$(KEY="$flow_key" yq e -r '.images[strenv(KEY)].repository + ":" + .images[strenv(KEY)].tag + "@" + .images[strenv(KEY)].digest' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
web_image="$(KEY="$web_key" yq e -r '.images[strenv(KEY)].repository + ":" + .images[strenv(KEY)].tag + "@" + .images[strenv(KEY)].digest' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
run_id="$(yq e -r '.runId // ""' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
b_endpoint="$(yq e -r -N '
  select(.kind == "OverridePolicy") |
  .spec.overrideRules[] |
  select(.targetCluster.clusterNames[] == "b") |
  .overriders.plaintext[] |
  select(.path == "/data/S3_ENDPOINT_URL" and .operator == "replace") |
  .value
' "$ROOT/releases/poc/rgw-analysis-web/karmada/overrides"/*.yaml | sed '/^[[:space:]]*$/d')"

mkdir -p "$tmp/bin" "$tmp/fixtures"
for fixture in "$fixture_root"/*.json "$fixture_root"/*.html; do
  sed \
    -e "s|__REVISION__|$revision|g" \
    -e "s|__FLOW_IMAGE__|$flow_image|g" \
    -e "s|__WEB_IMAGE__|$web_image|g" \
    "$fixture" > "$tmp/fixtures/$(basename "$fixture")"
done

if [ "$flow_key" = flow ]; then
  endpoint="$(yq e -r '.storage.endpointUrl' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
  bucket="$(yq e -r '.storage.bucket' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
  region="$(yq e -r '.storage.region' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
  wait_seconds="$(yq e -r '.storage.waitSeconds' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
  poll_seconds="$(yq e -r '.storage.pollIntervalSeconds' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")"
  jq \
    --arg endpoint "$endpoint" \
    --arg bucket "$bucket" \
    --arg region "$region" \
    --arg wait_seconds "$wait_seconds" \
    --arg poll_seconds "$poll_seconds" '
      .data.S3_ENDPOINT_URL = $endpoint |
      .data.S3_BUCKET = $bucket |
      .data.AWS_DEFAULT_REGION = $region |
      .data.S3_WAIT_SECONDS = $wait_seconds |
      .data.S3_POLL_INTERVAL_SECONDS = $poll_seconds
    ' "$fixture_root/configmap-runtime-smurf.json" > "$tmp/fixtures/configmap-runtime.json"
  sed "s|run-20260714-001|$run_id|g" \
    "$fixture_root/result-smurf-success.html" > "$tmp/fixtures/result.html"
else
  jq \
    --arg endpoint "$(yq e -r '.s3.endpointUrl' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")" \
    --arg bucket "$(yq e -r '.s3.bucket' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")" \
    --arg region "$(yq e -r '.s3.region' "$ROOT/releases/poc/rgw-analysis-web/values.yaml")" '
      .data.S3_ENDPOINT_URL = $endpoint |
      .data.S3_BUCKET = $bucket |
      .data.AWS_DEFAULT_REGION = $region
    ' "$tmp/fixtures/configmap-runtime.json" > "$tmp/fixtures/configmap-runtime.updated.json"
  mv "$tmp/fixtures/configmap-runtime.updated.json" "$tmp/fixtures/configmap-runtime.json"
fi

cp "$fixture_root/fake-kubectl.sh" "$tmp/bin/kubectl"
cp "$fixture_root/fake-curl.sh" "$tmp/bin/curl"
cp "$fixture_root/fake-yq.sh" "$tmp/bin/yq"
chmod +x "$tmp/bin/kubectl" "$tmp/bin/curl" "$tmp/bin/yq"

run_case() {
  local scenario="$1"
  local expected_status="$2"
  local log="$tmp/$scenario.log"
  set +e
  PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$tmp/fixtures" \
    FAKE_SCENARIO="$scenario" \
    EXPECTED_B_ENDPOINT="$b_endpoint" \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$observer" poc rgw-analysis-web >"$log" 2>&1
  local status=$?
  set -e
  if [ "$expected_status" = pass ]; then
    [ "$status" -eq 0 ] || {
      cat "$log" >&2
      exit 1
    }
    grep -Fq 'runtime observation passed' "$log"
  else
    [ "$status" -ne 0 ] || {
      echo "scenario unexpectedly passed: $scenario" >&2
      exit 1
    }
    grep -Fq 'runtime observation failed' "$log"
  fi
}

run_case healthy pass
run_case stale fail
run_case partial fail
run_case wrong-image fail
run_case not-ready fail
run_case unreachable fail
run_case wrong-object fail
run_case wrong-name fail
run_case wrong-namespace fail
run_case wrong-list-identity fail
run_case wrong-binding-item fail
run_case strict-context-boundary pass
run_case wrong-config-identity fail
run_case stale-config fail
run_case wrong-config-value fail
run_case yq-failure fail
run_case legacy-loading fail

run_malformed_override_contract() {
  local federation="$tmp/malformed-override-federation"
  mkdir -p "$federation/scripts/rgw-analysis-web" "$federation/releases/poc"
  cp "$observer" "$federation/scripts/rgw-analysis-web/observe-release.sh"
  chmod +x "$federation/scripts/rgw-analysis-web/observe-release.sh"
  cp -R "$ROOT/releases/poc/rgw-analysis-web" "$federation/releases/poc/"
  printf '%s\n' 'apiVersion: [' > \
    "$federation/releases/poc/rgw-analysis-web/karmada/overrides/malformed.yaml"
  if PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$tmp/fixtures" \
    FAKE_SCENARIO=healthy \
    EXPECTED_B_ENDPOINT="$b_endpoint" \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$federation/scripts/rgw-analysis-web/observe-release.sh" poc rgw-analysis-web \
    > "$tmp/malformed-override.log" 2>&1; then
    echo "malformed override unexpectedly passed runtime observation" >&2
    exit 1
  fi
  grep -Fq 'unable to evaluate S3 endpoint overrides' "$tmp/malformed-override.log"
}

run_malformed_override_contract

run_unsupported_source_path_contract() {
  local federation="$tmp/unsupported-source-path-federation"
  mkdir -p "$federation/scripts/rgw-analysis-web" "$federation/releases/poc"
  cp "$observer" "$federation/scripts/rgw-analysis-web/observe-release.sh"
  chmod +x "$federation/scripts/rgw-analysis-web/observe-release.sh"
  cp -R "$ROOT/releases/poc/rgw-analysis-web" "$federation/releases/poc/"
  yq -i '.source.path = "charts/rgw-analysis-web"' \
    "$federation/releases/poc/rgw-analysis-web/release.yaml"
  if PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$tmp/fixtures" \
    FAKE_SCENARIO=healthy \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$federation/scripts/rgw-analysis-web/observe-release.sh" poc rgw-analysis-web \
    >"$tmp/unsupported-source-path.log" 2>&1; then
    echo "unsupported source URL/path unexpectedly passed runtime observation" >&2
    exit 1
  fi
  grep -Fq 'unsupported RGW source contract' "$tmp/unsupported-source-path.log"
}

run_unsupported_source_path_contract

run_smurf_contract() {
  local federation="$tmp/smurf-federation"
  local fixtures="$tmp/smurf-fixtures"
  local source_root
  local smurf_child
  local exact_smurf_child="$tmp/exact-smurf-child"
  local values="$ROOT/releases/cuty/rgw-analysis-web/values.yaml"
  local descriptor="$ROOT/releases/cuty/rgw-analysis-web/release.yaml"
  local active_revision revision flow_image web_image namespace run_id
  source_root="${FEATURE_REPOS_ROOT:-$(dirname "$ROOT")}";
  smurf_child="${SMURF_CHILD_ROOT:-$source_root/smurf-child}"
  active_revision="$(yq e -r '.source.revision' "$descriptor")"
  revision="$active_revision"
  namespace="$(yq e -r '.namespace' "$descriptor")"
  run_id="$(yq e -r '.runId' "$values")"
  flow_image="$(yq e -r '.images.flow.repository + ":" + .images.flow.tag + "@" + .images.flow.digest' "$values")"
  web_image="$(yq e -r '.images.web.repository + ":" + .images.web.tag + "@" + .images.web.digest' "$values")"

  test -d "$smurf_child/.git" || {
    echo "exact Smurf child checkout is required: $smurf_child" >&2
    exit 1
  }
  [ "$(git -C "$smurf_child" rev-parse HEAD)" = "$active_revision" ] || {
    echo "Smurf child checkout does not match the active release revision" >&2
    exit 1
  }
  mkdir -p "$exact_smurf_child"
  git -C "$smurf_child" archive "$active_revision" \
    charts/rgw-analysis-web \
    src/rgw-analysis-web/web/fixtures/loading.html \
    src/rgw-analysis-web/web/fixtures/success.html |
    tar -x -C "$exact_smurf_child"
  smurf_child="$exact_smurf_child"
  test -f "$smurf_child/charts/rgw-analysis-web/Chart.yaml" || {
    echo "Smurf child chart is missing from the exact checkout" >&2
    exit 1
  }
  test -f "$smurf_child/src/rgw-analysis-web/web/fixtures/loading.html" || {
    echo "Smurf child loading fixture is missing from the exact checkout" >&2
    exit 1
  }
  test -f "$smurf_child/src/rgw-analysis-web/web/fixtures/success.html" || {
    echo "Smurf child success fixture is missing from the exact checkout" >&2
    exit 1
  }

  mkdir -p "$federation/scripts/rgw-analysis-web" "$federation/releases/cuty" "$fixtures"
  cp "$observer" "$federation/scripts/rgw-analysis-web/observe-release.sh"
  chmod +x "$federation/scripts/rgw-analysis-web/observe-release.sh"
  cp -R "$ROOT/releases/cuty/rgw-analysis-web" "$federation/releases/cuty/"

  for fixture in bindings.json deployment.json external-secret.json job-analyzer.json job-seeder.json service.json; do
    sed \
      -e "s|__REVISION__|$revision|g" \
      -e "s|__FLOW_IMAGE__|$flow_image|g" \
      -e "s|__WEB_IMAGE__|$web_image|g" \
      "$fixture_root/$fixture" |
      sed "s/scalex-rgw-analysis-web/$namespace/g" > "$fixtures/$fixture"
  done
  jq \
    --arg namespace "$namespace" \
    --arg endpoint "$(yq e -r '.storage.endpointUrl' "$values")" \
    --arg bucket "$(yq e -r '.storage.bucket' "$values")" \
    --arg region "$(yq e -r '.storage.region' "$values")" \
    --arg wait_seconds "$(yq e -r '.storage.waitSeconds' "$values")" \
    --arg poll_seconds "$(yq e -r '.storage.pollIntervalSeconds' "$values")" '
      .metadata.namespace = $namespace |
      .data.S3_ENDPOINT_URL = $endpoint |
      .data.S3_BUCKET = $bucket |
      .data.AWS_DEFAULT_REGION = $region |
      .data.S3_WAIT_SECONDS = $wait_seconds |
      .data.S3_POLL_INTERVAL_SECONDS = $poll_seconds
    ' "$fixture_root/configmap-runtime-smurf.json" > "$fixtures/configmap-runtime.json"

  command -v helm >/dev/null 2>&1 || {
    echo "helm is required to verify the current Smurf child chart" >&2
    exit 1
  }
  helm template rgw-analysis-web "$smurf_child/charts/rgw-analysis-web" \
    --namespace "$namespace" -f "$values" > "$tmp/smurf-render.yaml"
  yq e -e '
    select(.kind == "ConfigMap" and .metadata.name == "rgw-analysis-web-runtime") |
    .metadata.labels["scalex.io/component"] == "runtime" and
    (.data | keys | sort | join(",")) == "AWS_DEFAULT_REGION,S3_BUCKET,S3_ENDPOINT_URL,S3_POLL_INTERVAL_SECONDS,S3_WAIT_SECONDS"
  ' "$tmp/smurf-render.yaml" >/dev/null
  if yq e -e 'select(.kind == "ConfigMap" and .metadata.name == "rgw-analysis-web-scripts")' \
    "$tmp/smurf-render.yaml" >/dev/null 2>&1; then
    echo "Smurf child chart unexpectedly rendered the legacy scripts ConfigMap" >&2
    exit 1
  fi
  yq e -r -N 'select(.kind != null) | [.kind, .metadata.name] | @tsv' "$tmp/smurf-render.yaml" |
    LC_ALL=C sort > "$tmp/smurf-identities"
  printf '%s\n' \
    $'ConfigMap\trgw-analysis-web-runtime' \
    $'Deployment\trgw-analysis-web-result-web' \
    $'Job\trgw-analysis-web-analyzer' \
    $'Job\trgw-analysis-web-dataset-seeder' \
    $'Service\trgw-analysis-web-result-web' |
    LC_ALL=C sort > "$tmp/expected-smurf-identities"
  cmp -s "$tmp/expected-smurf-identities" "$tmp/smurf-identities" || {
    echo "Smurf child rendered resource inventory drifted" >&2
    exit 1
  }
  yq e -r -N '.. | select(tag == "!!map") | (.containers[]?.image, .initContainers[]?.image) | select(. != null)' \
    "$tmp/smurf-render.yaml" | LC_ALL=C sort -u > "$tmp/smurf-images"
  printf '%s\n' "$flow_image" "$web_image" | LC_ALL=C sort -u > "$tmp/expected-smurf-images"
  cmp -s "$tmp/expected-smurf-images" "$tmp/smurf-images" || {
    echo "Smurf child rendered image contract drifted" >&2
    exit 1
  }

  local loading_page="$smurf_child/src/rgw-analysis-web/web/fixtures/loading.html"
  local success_page="$smurf_child/src/rgw-analysis-web/web/fixtures/success.html"

  local scenario
  for scenario in wrong-api-version wrong-kind; do
    cp "$success_page" "$fixtures/result.html"
    if PATH="$tmp/bin:$PATH" \
      FAKE_FIXTURE_ROOT="$fixtures" \
      FAKE_SCENARIO="$scenario" \
      EXPECTED_B_ENDPOINT="$b_endpoint" \
      REAL_YQ="$real_yq" \
      OBSERVE_ATTEMPTS=1 \
      OBSERVE_INTERVAL_SECONDS=0 \
      "$federation/scripts/rgw-analysis-web/observe-release.sh" cuty rgw-analysis-web \
      >"$tmp/smurf-$scenario.log" 2>&1; then
      echo "Smurf child ExternalSecret scenario unexpectedly passed: $scenario" >&2
      exit 1
    fi
    grep -Fq 'runtime observation failed' "$tmp/smurf-$scenario.log"
  done

  cp "$loading_page" "$fixtures/result.html"
  if PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$fixtures" \
    FAKE_SCENARIO=smurf-child \
    EXPECTED_B_ENDPOINT="$b_endpoint" \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$federation/scripts/rgw-analysis-web/observe-release.sh" cuty rgw-analysis-web \
    >"$tmp/smurf-loading.log" 2>&1; then
    echo "Smurf child loading page unexpectedly passed runtime observation" >&2
    exit 1
  fi

  cp "$success_page" "$fixtures/result.html"
  sed 's/run-20260714-001/different-run/' "$fixtures/result.html" > "$fixtures/result-wrong-run.html"
  mv "$fixtures/result-wrong-run.html" "$fixtures/result.html"
  if PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$fixtures" \
    FAKE_SCENARIO=smurf-child \
    EXPECTED_B_ENDPOINT="$b_endpoint" \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$federation/scripts/rgw-analysis-web/observe-release.sh" cuty rgw-analysis-web \
    >"$tmp/smurf-wrong-run.log" 2>&1; then
    echo "Smurf child success page with the wrong run ID unexpectedly passed" >&2
    exit 1
  fi

  sed "s/run-20260714-001/$run_id/" "$success_page" > "$fixtures/result.html"
  PATH="$tmp/bin:$PATH" \
    FAKE_FIXTURE_ROOT="$fixtures" \
    FAKE_SCENARIO=smurf-child \
    EXPECTED_B_ENDPOINT="$b_endpoint" \
    REAL_YQ="$real_yq" \
    OBSERVE_ATTEMPTS=1 \
    OBSERVE_INTERVAL_SECONDS=0 \
    "$federation/scripts/rgw-analysis-web/observe-release.sh" cuty rgw-analysis-web \
    >"$tmp/smurf-child.log" 2>&1 || {
      cat "$tmp/smurf-child.log" >&2
      exit 1
    }
  grep -Fq 'runtime observation passed for Karmada/member evidence' "$tmp/smurf-child.log"
  echo "Smurf child chart runtime contract passed"
}

run_smurf_contract

echo "runtime observation fixtures passed"
