#!/usr/bin/env bash
set -euo pipefail

context=""
resource=""
name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    -n|--namespace|-l|-o) shift 2 ;;
    get)
      resource="$2"
      shift 2
      if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then
        name="$1"
        shift
      fi
      ;;
    *) shift ;;
  esac
done

if [ "${FAKE_SCENARIO:-healthy}" = unreachable ] && [ "$context" = b ]; then
  echo "simulated member API outage" >&2
  exit 1
fi

case "$context:$resource:$name" in
  karmada:applications.argoproj.io:federation-poc-rgw-analysis-web)
    echo "Application API is not served by the karmada context" >&2
    exit 1
    ;;
  karmada:resourcebindings.work.karmada.io:)
    if [ "${FAKE_SCENARIO:-healthy}" = stale ]; then
      jq '.items[0].status.aggregatedStatus[0].applied = false' "$FAKE_FIXTURE_ROOT/bindings.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = wrong-binding-item ]; then
      jq '.items[0].metadata.namespace = "another-namespace"' "$FAKE_FIXTURE_ROOT/bindings.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = wrong-list-identity ]; then
      jq '.kind = "List"' "$FAKE_FIXTURE_ROOT/bindings.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = generic-list ]; then
      jq '.apiVersion = "v1" | .kind = "List"' "$FAKE_FIXTURE_ROOT/bindings.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = partial ]; then
      jq 'del(.items[] | select(.spec.resource.name == "rgw-analysis-web-analyzer"))' "$FAKE_FIXTURE_ROOT/bindings.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/bindings.json"
    fi
    ;;
  b:secrets:rgw-analysis-web-s3|c:secrets:rgw-analysis-web-s3|b:secrets:scalex-poc-rgw|c:secrets:scalex-poc-rgw|b:secrets:scalex-cuty-rgw|c:secrets:scalex-cuty-rgw)
    if [ "${FAKE_SCENARIO:-healthy}" = wrong-api-version ] && [ "$context" = b ]; then
      jq '.apiVersion = "v2"' "$FAKE_FIXTURE_ROOT/secret.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = wrong-kind ] && [ "$context" = b ]; then
      jq '.kind = "ConfigMap"' "$FAKE_FIXTURE_ROOT/secret.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = missing-secret-key ] && [ "$context" = c ]; then
      jq 'del(.data["secret-access-key"], .data.AWS_SECRET_ACCESS_KEY)' "$FAKE_FIXTURE_ROOT/secret.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/secret.json"
    fi
    ;;
  b:configmaps:rgw-analysis-web-scripts|c:configmaps:rgw-analysis-web-scripts)
    jq '.' "$FAKE_FIXTURE_ROOT/configmap-scripts.json"
    ;;
  b:configmaps:rgw-analysis-web-runtime|c:configmaps:rgw-analysis-web-runtime)
    if [ "${FAKE_SCENARIO:-healthy}" = wrong-config-identity ] && [ "$context" = c ]; then
      jq '.metadata.name = "different-runtime"' "$FAKE_FIXTURE_ROOT/configmap-runtime.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = stale-config ] && [ "$context" = b ]; then
      jq 'del(.data.S3_BUCKET)' "$FAKE_FIXTURE_ROOT/configmap-runtime.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = wrong-config-value ] && [ "$context" = b ]; then
      jq --arg endpoint "${EXPECTED_B_ENDPOINT:-}" \
        '.data.S3_ENDPOINT_URL = ($endpoint // .data.S3_ENDPOINT_URL) | .data.S3_BUCKET = "wrong-but-present"' \
        "$FAKE_FIXTURE_ROOT/configmap-runtime.json"
    elif [ "$context" = b ] && [ -n "${EXPECTED_B_ENDPOINT:-}" ]; then
      jq --arg endpoint "$EXPECTED_B_ENDPOINT" '.data.S3_ENDPOINT_URL = $endpoint' \
        "$FAKE_FIXTURE_ROOT/configmap-runtime.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/configmap-runtime.json"
    fi
    ;;
  b:deployments.apps:rgw-analysis-web-result-web)
    if [ "${FAKE_SCENARIO:-healthy}" = wrong-object ]; then
      jq '.metadata.name = "different-result-web" | .metadata.namespace = "another-namespace"' "$FAKE_FIXTURE_ROOT/deployment.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = not-ready ]; then
      jq '.status.availableReplicas = 0 | .status.unavailableReplicas = 1' "$FAKE_FIXTURE_ROOT/deployment.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/deployment.json"
    fi
    ;;
  b:jobs.batch:rgw-analysis-web-dataset-seeder)
    jq '.' "$FAKE_FIXTURE_ROOT/job-seeder.json"
    ;;
  c:jobs.batch:rgw-analysis-web-analyzer)
    if [ "${FAKE_SCENARIO:-healthy}" = wrong-name ]; then
      jq '.metadata.name = "different-analyzer"' "$FAKE_FIXTURE_ROOT/job-analyzer.json"
    elif [ "${FAKE_SCENARIO:-healthy}" = wrong-image ]; then
      jq '.spec.template.spec.containers[0].image = "ghcr.io/example/wrong:sha-bad@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$FAKE_FIXTURE_ROOT/job-analyzer.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/job-analyzer.json"
    fi
    ;;
  b:services:rgw-analysis-web-result-web)
    if [ "${FAKE_SCENARIO:-healthy}" = wrong-namespace ]; then
      jq '.metadata.namespace = "another-namespace"' "$FAKE_FIXTURE_ROOT/service.json"
    else
      jq '.' "$FAKE_FIXTURE_ROOT/service.json"
    fi
    ;;
  *)
    echo "unexpected fake kubectl request: $context $resource $name" >&2
    exit 2
    ;;
esac
