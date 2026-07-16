#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
observer="$ROOT/scripts/rgw-analysis-web/observe-release.sh"
fixture_root="$ROOT/tests/fixtures/runtime-observation"
release_root="$ROOT/releases/scalex-feature-poc"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
real_yq="$(command -v yq)"

test -x "$observer" || {
  echo "missing runtime observer: $observer" >&2
  exit 1
}

revision="$(yq e -r '.source.revision' "$release_root/release.yaml")"
flow_image="$(yq e -r '.images.awsCli.repository + ":" + .images.awsCli.tag + "@" + .images.awsCli.digest' "$release_root/values.yaml")"
web_image="$(yq e -r '.images.nginx.repository + ":" + .images.nginx.tag + "@" + .images.nginx.digest' "$release_root/values.yaml")"
b_endpoint="$(yq e -r '.placements.runtimeEndpointOnB' "$release_root/values.yaml")"
runtime_secret="$(yq e -r '.s3.secretName' "$release_root/values.yaml")"

mkdir -p "$tmp/bin" "$tmp/fixtures"
for fixture in "$fixture_root"/*.json "$fixture_root"/*.html; do
  sed \
    -e "s|__REVISION__|$revision|g" \
    -e "s|__FLOW_IMAGE__|$flow_image|g" \
    -e "s|__WEB_IMAGE__|$web_image|g" \
    "$fixture" >"$tmp/fixtures/$(basename "$fixture")"
done

jq \
  --arg endpoint "$(yq e -r '.runtimeBinding.endpointUrl' "$release_root/values.yaml")" \
  --arg bucket "provider-generated-bucket" \
  --arg region "$(yq e -r '.runtimeBinding.region' "$release_root/values.yaml")" '
    .data.S3_ENDPOINT_URL = $endpoint |
    .data.S3_BUCKET = $bucket |
    .data.AWS_DEFAULT_REGION = $region
  ' "$fixture_root/configmap-runtime.json" >"$tmp/fixtures/configmap-runtime.updated.json"
mv "$tmp/fixtures/configmap-runtime.updated.json" "$tmp/fixtures/configmap-runtime.json"
jq --arg name "$runtime_secret" '.metadata.name = $name' \
  "$tmp/fixtures/secret.json" >"$tmp/fixtures/secret.updated.json"
mv "$tmp/fixtures/secret.updated.json" "$tmp/fixtures/secret.json"

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
    "$observer" scalex-feature-poc >"$log" 2>&1
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
run_case generic-list pass
run_case wrong-list-identity fail
run_case wrong-binding-item fail
run_case strict-context-boundary pass
run_case wrong-config-identity fail
run_case stale-config fail
run_case wrong-config-value fail
run_case legacy-loading fail

unsupported="$tmp/unsupported"
mkdir -p "$unsupported/scripts/rgw-analysis-web" "$unsupported/releases/scalex-feature-poc"
cp "$observer" "$unsupported/scripts/rgw-analysis-web/observe-release.sh"
cp "$release_root/release.yaml" "$unsupported/releases/scalex-feature-poc/release.yaml"
cp "$release_root/values.yaml" "$unsupported/releases/scalex-feature-poc/values.yaml"
yq -i '.source.path = "charts/rgw-analysis-web"' \
  "$unsupported/releases/scalex-feature-poc/release.yaml"
if PATH="$tmp/bin:$PATH" \
  FAKE_FIXTURE_ROOT="$tmp/fixtures" \
  FAKE_SCENARIO=healthy \
  REAL_YQ="$real_yq" \
  OBSERVE_ATTEMPTS=1 \
  OBSERVE_INTERVAL_SECONDS=0 \
  "$unsupported/scripts/rgw-analysis-web/observe-release.sh" scalex-feature-poc \
  >"$tmp/unsupported.log" 2>&1; then
  echo "unsupported source path unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'unsupported RGW source contract' "$tmp/unsupported.log"

echo "runtime observation fixtures passed"
