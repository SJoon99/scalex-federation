#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW_ROOT="${WORKFLOW_ROOT:-$ROOT}"
validate="$WORKFLOW_ROOT/.github/workflows/federation-validate.yaml"
observe="$WORKFLOW_ROOT/.github/workflows/runtime-observation.yaml"
actionlint_config="$WORKFLOW_ROOT/.github/actionlint.yaml"
runtime="$WORKFLOW_ROOT/scripts/rgw-analysis-web/observe-release.sh"

fail() {
  echo "$*" >&2
  exit 1
}

for file in "$validate" "$observe" "$runtime"; do
  test -f "$file" || fail "missing hosted workflow contract: ${file#"$ROOT"/}"
done
test -f "$actionlint_config" || fail "missing actionlint custom runner declaration"
yq e '.' "$actionlint_config" >/dev/null
[ "$(yq e -r '. | keys | sort | join(",")' "$actionlint_config")" = self-hosted-runner ] ||
  fail "actionlint config contains a broad or unknown section"
[ "$(yq e -r '."self-hosted-runner" | keys | sort | join(",")' "$actionlint_config")" = labels ] ||
  fail "actionlint self-hosted runner config is not exact"
[ "$(yq e -r '."self-hosted-runner".labels | join(",")' "$actionlint_config")" = scalex-management ] ||
  fail "actionlint custom runner labels are not exact"

for file in "$validate" "$observe"; do
  yq e '.' "$file" >/dev/null
  if grep -Eiq 'kubectl[[:space:]].*(apply|create|delete|edit|exec|patch|replace|rollout|scale|set)' "$file"; then
    fail "workflow contains a cluster mutation command: ${file#"$ROOT"/}"
  fi
  if grep -Eiq '(echo|set -x).*(KUBECONFIG|SCALEX_RELEASE_KUBECONFIG)' "$file"; then
    fail "workflow may expose kubeconfig material: ${file#"$ROOT"/}"
  fi
done

yq e -e '.on.pull_request != null and .on.push.branches[0] == "main"' "$validate" >/dev/null ||
  fail "validation must gate pull requests and main pushes"
yq e -e '.permissions.contents == "read" and (.jobs | length) == 1' "$validate" >/dev/null ||
  fail "validation permissions must be read-only"
grep -Fq 'scripts/validate.sh' "$validate" || fail "validation entry point is not executed"
grep -Fq 'tests/contracts/test-script-boundaries.sh' "$validate" || fail "script boundary contract is not executed"
grep -Fq 'tests/contracts/test-validation-fixtures.sh' "$validate" || fail "adversarial fixtures are not executed"
validation_gate_run="$(yq e -r '.jobs.validate.steps[] | select(.name == "Run exact-source Federation gates") | .run' "$validate")"
printf '%s\n' "$validation_gate_run" | grep -Fxq './tests/contracts/test-multi-release-coexistence.sh' ||
  fail "multi-release active inventory contract is not executed"
grep -Fq 'verify-public-images.sh' "$validate" || fail "public image digests are not verified"
grep -Fq 'VALIDATE_BASE_REF' "$validate" || fail "promotion atomicity base ref is not passed"
grep -Fq '[[ "$repo_url" =~ ^https://github\.com/' "$validate" || fail "source fetch protocol is not constrained"
grep -Fq 'contracts/children.yaml' "$validate" || fail "source fetch is not enrollment-gated"
enrollment_line="$(grep -n 'contracts/children.yaml' "$validate" | head -n 1 | cut -d: -f1)"
fetch_line="$(grep -n 'git -C "$target" fetch' "$validate" | head -n 1 | cut -d: -f1)"
[ "$enrollment_line" -lt "$fetch_line" ] || fail "untrusted source is fetched before enrollment validation"
source_resolution_run="$(yq e -r '.jobs.validate.steps[] | select(.name == "Resolve exact enrolled source revisions") | .run' "$validate")"
printf '%s\n' "$source_resolution_run" | grep -Fq "yq e -r -N '[.source.repoURL, .source.path, .source.revision] | @tsv'" ||
  fail "hosted source extraction must suppress YAML document separators"
mapfile -t source_rows < <(
  yq e -r -N '[.source.repoURL, .source.path, .source.revision] | @tsv' \
    "$ROOT"/releases/*/*/release.yaml
)
[ "${#source_rows[@]}" -eq 2 ] || fail "active source extraction must produce exactly two rows"
if printf '%s\n' "${source_rows[@]}" | grep -Fxq -- '---'; then
  fail "active source extraction emitted a bogus YAML document row"
fi

yq e -e '
  .on.workflow_run.workflows[0] == "Federation Validation" and
  .on.workflow_run.types[0] == "completed" and
  .on.workflow_run.branches[0] == "main" and
  .on.workflow_dispatch != null
' "$observe" >/dev/null || fail "runtime observation triggers must be post-merge and manual"
yq e -e '
  .jobs.observe.environment == "scalex-release" and
  (.jobs.observe."runs-on" | join(",")) == "self-hosted,linux,scalex-management" and
  .jobs.observe.permissions.contents == "read"
' "$observe" >/dev/null || fail "runtime observation protection boundary is incomplete"
expected_observe_if="github.event_name == 'workflow_dispatch' || (github.event_name == 'workflow_run' && github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push' && github.event.workflow_run.head_branch == 'main' && github.event.workflow_run.head_repository.full_name == github.repository)"
[ "$(yq e -r '.jobs.observe.if | sub("[[:space:]]+"; " ")' "$observe")" = "$expected_observe_if" ] ||
  fail "runtime observation must reject pull-request, fork, and non-main workflow runs"
grep -Fq 'secrets.SCALEX_RELEASE_KUBECONFIG' "$observe" || fail "protected kubeconfig secret is not used"
grep -Fq 'KARMADA_CONTEXT: karmada' "$observe" || fail "karmada context is not fixed"
grep -Fq 'MEMBER_CONTEXTS: b,c' "$observe" || fail "member contexts are not fixed"
grep -Fq 'observe-release.sh' "$observe" || fail "runtime observation entry point is not executed"
[ "$(yq e -r '.jobs.observe.steps | map(.name) | join("|")' "$observe")" = \
  "Check out observed desired state|Install checksum-verified yq|Observe merged release without changing desired state|Remove ephemeral kubeconfig" ] ||
  fail "runtime observation step list is not exact"
yq e -e '
  (.jobs | keys | sort | join(",")) == "observe" and
  (.jobs.observe | keys | sort | join(",")) == "environment,if,permissions,runs-on,steps,timeout-minutes" and
  (.jobs.observe.steps[0] | keys | sort | join(",")) == "name,uses,with" and
  (.jobs.observe.steps[1] | keys | sort | join(",")) == "name,run,shell" and
  .jobs.observe.steps[1].shell == "bash" and
  (.jobs.observe.steps[2] | keys | sort | join(",")) == "env,name,run,shell" and
  .jobs.observe.steps[2].shell == "bash" and
  (.jobs.observe.steps[3] | keys | sort | join(",")) == "if,name,run,shell" and
  .jobs.observe.steps[3].shell == "bash"
' "$observe" >/dev/null || fail "runtime job step keys and shells are not exact"
[ "$(yq e -r '.jobs.observe.steps[] | select(.name == "Observe merged release without changing desired state") | (.env | keys | sort | join(","))' "$observe")" = \
  "OBSERVE_ATTEMPTS,OBSERVE_INTERVAL_SECONDS,SCALEX_RELEASE_KUBECONFIG" ] ||
  fail "runtime credential environment is not exact"
[ "$(yq e -r '.jobs.observe.steps[] | select(.name == "Observe merged release without changing desired state") | .env.SCALEX_RELEASE_KUBECONFIG' "$observe")" = \
  '${{ secrets.SCALEX_RELEASE_KUBECONFIG }}' ] || fail "protected environment secret mapping is not exact"
[ "$(yq e -r '.jobs.observe.steps[] | select(.name == "Remove ephemeral kubeconfig") | .run' "$observe")" = \
  'rm -f "$RUNNER_TEMP/scalex-release.kubeconfig"' ] || fail "runtime credential cleanup is not exact"

expected_observe_run=$'set -euo pipefail\nset +x\numask 077\nkubeconfig="$RUNNER_TEMP/scalex-release.kubeconfig"\ninstall -m 0600 /dev/null "$kubeconfig"\nprintf \'%s\' "$SCALEX_RELEASE_KUBECONFIG" > "$kubeconfig"\nunset SCALEX_RELEASE_KUBECONFIG\ntest -s "$kubeconfig"\nKUBECONFIG="$kubeconfig" ./scripts/rgw-analysis-web/observe-release.sh poc rgw-analysis-web\nKUBECONFIG="$kubeconfig" ./scripts/rgw-analysis-web/observe-release.sh cuty rgw-analysis-web'
actual_observe_run="$(yq e -r '.jobs.observe.steps[] | select(.name == "Observe merged release without changing desired state") | .run' "$observe")"
[ "$actual_observe_run" = "$expected_observe_run" ] || fail "runtime credential handling differs from the safe whitelist"
[ "$(grep -Fo 'secrets.SCALEX_RELEASE_KUBECONFIG' "$observe" | wc -l)" -eq 1 ] || fail "protected secret expression must appear exactly once"
[ "$(grep -Fo '$SCALEX_RELEASE_KUBECONFIG' "$observe" | wc -l)" -eq 1 ] || fail "kubeconfig payload may only be used by the whitelisted file write"

while IFS= read -r action; do
  [[ "$action" =~ @[0-9a-f]{40}$ ]] || fail "GitHub Action is not commit-pinned: $action"
done < <(yq e -r -N '.. | select(tag == "!!map" and has("uses")) | .uses' "$validate" "$observe")

grep -Eq '^[[:space:]]*HELM_VERSION: v[0-9]+\.[0-9]+\.[0-9]+$' "$validate" || fail "Helm version is not pinned"
grep -Eq '^[[:space:]]*YQ_VERSION: v[0-9]+\.[0-9]+\.[0-9]+$' "$validate" || fail "yq version is not pinned"
grep -Eq '^[[:space:]]*HELM_SHA256: [0-9a-f]{64}$' "$validate" || fail "Helm checksum is not pinned"
grep -Eq '^[[:space:]]*YQ_SHA256: [0-9a-f]{64}$' "$validate" || fail "yq checksum is not pinned"
grep -Eq '^[[:space:]]*CHECK_JSONSCHEMA_VERSION: 0\.33\.3$' "$validate" || fail "check-jsonschema version is not pinned"
grep -Eq '^[[:space:]]*PYTHON_VERSION: 3\.13\.13$' "$validate" || fail "schema validator Python is not pinned"
grep -Fq 'check-jsonschema==$CHECK_JSONSCHEMA_VERSION' "$validate" || fail "check-jsonschema is not installed at the pinned version"
yq e -e '
  .jobs.validate.steps[] |
  select(.uses == "astral-sh/setup-uv@d0cc045d04ccac9d8b7881df0226f9e82c39688e") |
  . as $step |
  (
    ($step.with.version == "0.11.16") and
    (([$step.with | to_entries[] | select(.key == "enable-cache" and .value == false)] | length) == 1)
  )
' "$validate" >/dev/null || fail "uv installer is not pinned with cache disabled"

if grep -Eiq '\$KUBECTL.*[[:space:]](apply|create|delete|edit|exec|patch|replace|rollout|scale|set)([[:space:]]|$)' "$runtime"; then
  fail "runtime observer contains a forbidden kubectl verb"
fi
grep -Fq -- '--context "$KARMADA_CONTEXT"' "$runtime" || fail "observer does not use the karmada context"
grep -Fq -- '--context "$context"' "$runtime" || fail "observer does not use member contexts"
grep -Fq ' get ' "$runtime" || fail "observer does not use the read-only get verb"
if grep -Fq 'applications.argoproj.io' "$runtime"; then
  fail "runtime observer must not query Tower Argo through the karmada context"
fi

echo "workflow contracts passed"

if [ "${SKIP_WORKFLOW_MUTATIONS:-0}" = 0 ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  expect_workflow_reject() {
    local name="$1"
    local fixture="$tmp/$name"
    mkdir -p "$fixture/.github/workflows" "$fixture/scripts/rgw-analysis-web"
    cp "$validate" "$fixture/.github/workflows/federation-validate.yaml"
    cp "$observe" "$fixture/.github/workflows/runtime-observation.yaml"
    cp "$actionlint_config" "$fixture/.github/actionlint.yaml"
    cp "$runtime" "$fixture/scripts/rgw-analysis-web/observe-release.sh"
    case "$name" in
      secret-stdout)
        sed -i 's|printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG" > "$kubeconfig"|printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG"|' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      extra-secret-stdout)
        sed -i '/test -s "$kubeconfig"/a\          printf '\''%s\\n'\'' "$SCALEX_RELEASE_KUBECONFIG"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      echo-secret)
        sed -i '/test -s "$kubeconfig"/a\          echo "$SCALEX_RELEASE_KUBECONFIG"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      tee-secret)
        sed -i '/test -s "$kubeconfig"/a\          printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG" | tee "$RUNNER_TEMP/leak"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      trace-shell)
        sed -i '/umask 077/a\          set -x' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      dump-environment)
        sed -i '/umask 077/a\          env' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      secret-substitution)
        sed -i 's|printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG" > "$kubeconfig"|payload="$(printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG")"\n          printf '\''%s'\'' "$payload" > "$kubeconfig"|' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      display-file)
        sed -i '/test -s "$kubeconfig"/a\          cat "$kubeconfig"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      secret-stderr)
        sed -i 's|printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG" > "$kubeconfig"|printf '\''%s'\'' "$SCALEX_RELEASE_KUBECONFIG" >&2|' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      custom-observe-shell)
        yq -i '(.jobs.observe.steps[] | select(.name == "Observe merged release without changing desired state").shell) = "bash -c '\''env | base64 >&2; bash {0}'\''"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      custom-cleanup-shell)
        yq -i '(.jobs.observe.steps[] | select(.name == "Remove ephemeral kubeconfig").shell) = "bash -c '\''base64 \"$RUNNER_TEMP/scalex-release.kubeconfig\" >&2; bash {0}'\''"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
      custom-shell-option)
        yq -i '(.jobs.observe.steps[] | select(.name == "Observe merged release without changing desired state").shell) = "bash --noprofile {0}"' "$fixture/.github/workflows/runtime-observation.yaml"
        ;;
    esac
    if WORKFLOW_ROOT="$fixture" SKIP_WORKFLOW_MUTATIONS=1 "$0" >"$tmp/$name.log" 2>&1; then
      echo "unsafe workflow mutation unexpectedly passed: $name" >&2
      exit 1
    fi
  }

  expect_workflow_reject secret-stdout
  expect_workflow_reject extra-secret-stdout
  expect_workflow_reject echo-secret
  expect_workflow_reject tee-secret
  expect_workflow_reject trace-shell
  expect_workflow_reject dump-environment
  expect_workflow_reject secret-substitution
  expect_workflow_reject display-file
  expect_workflow_reject secret-stderr
  expect_workflow_reject custom-observe-shell
  expect_workflow_reject custom-cleanup-shell
  expect_workflow_reject custom-shell-option
  echo "workflow leakage mutations passed"
fi
