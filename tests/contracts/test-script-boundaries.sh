#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "$*" >&2
  exit 1
}

contains_direct_mutation() {
  rg -n --glob '*.sh' --glob '*.yaml' --glob '*.yml' \
    'kubectl([[:space:]\\]|[^[:space:]])*[[:space:]]+(apply|create|delete|edit|patch|replace|rollout|scale|set)([[:space:]]|$)' \
    "$@" >/dev/null
}

contains_credential_materialization() {
  rg -n --glob '*.sh' --glob '*.yaml' --glob '*.yml' \
    '(create[[:space:]]+secret|--from-literal|stringData:|AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)[[:space:]]*=)' \
    "$@" >/dev/null
}

legacy_bootstrap="$ROOT/scripts/bootstrap-rgw-credentials.sh"
test -x "$legacy_bootstrap" || fail "approved legacy credential bootstrap is missing"
git -C "$ROOT" show e717da4:scripts/bootstrap-rgw-credentials.sh |
  cmp -s - "$legacy_bootstrap" || fail "approved legacy credential bootstrap drifted"

mapfile -d '' -t automation_files < <(
  find "$ROOT/scripts" "$ROOT/.github/workflows" -type f \
    \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) -print0
)
audited_files=()
for file in "${automation_files[@]}"; do
  [ "$file" = "$legacy_bootstrap" ] || audited_files+=("$file")
done

if contains_direct_mutation "${audited_files[@]}"; then
  fail "Federation automation contains a direct cluster mutation"
fi

if contains_credential_materialization "${audited_files[@]}"; then
  fail "Federation automation contains credential materialization"
fi

test -z "$(find "$ROOT/releases/poc/rgw-analysis-web/dependencies" -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit)" ||
  fail "legacy POC dependencies must not contain deployable YAML"
rg -Fq 'ExternalSecret' "$ROOT/releases/cuty/rgw-analysis-web/dependencies/external-secret.yaml" ||
  fail "Cuty ESO ExternalSecret dependency is missing"
rg -Fq './scripts/rgw-analysis-web/observe-release.sh' "$ROOT/.github/workflows/runtime-observation.yaml" ||
  fail "runtime workflow must invoke the read-only observer"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/workflows"
printf '%s\n' '#!/usr/bin/env bash' 'kubectl --kubeconfig /tmp/kubeconfig apply -f release.yaml' > "$tmp/scripts/direct-apply.sh"
contains_direct_mutation "$tmp/scripts" || fail "direct apply mutation was not detected"
printf '%s\n' '#!/usr/bin/env bash' 'kubectl create secret generic runtime --from-literal=key=value' > "$tmp/scripts/credential.sh"
contains_credential_materialization "$tmp/scripts" || fail "credential materialization mutation was not detected"
mkdir -p "$tmp/scripts/nested"
printf '%s\n' '#!/usr/bin/env bash' 'kubectl apply -f attacker.yaml' > \
  "$tmp/scripts/nested/bootstrap-rgw-credentials.sh"
contains_direct_mutation "$tmp/scripts/nested" ||
  fail "nested same-basename mutation escaped the exact bootstrap exception"

echo "script boundary tests passed"
