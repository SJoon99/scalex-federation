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
cuty_bootstrap="$ROOT/scripts/bootstrap-cuty-rgw-credentials.sh"
test -x "$legacy_bootstrap" || fail "approved legacy credential bootstrap is missing"
test -x "$cuty_bootstrap" || fail "approved Cuty credential bootstrap is missing"
git -C "$ROOT" show e717da4:scripts/bootstrap-rgw-credentials.sh |
  cmp -s - "$legacy_bootstrap" || fail "approved legacy credential bootstrap drifted"

mapfile -d '' -t automation_files < <(
  find "$ROOT/scripts" "$ROOT/.github/workflows" -type f \
    \( -name '*.sh' -o -name '*.yaml' -o -name '*.yml' \) -print0
)
mutation_audited_files=()
credential_audited_files=()
for file in "${automation_files[@]}"; do
  if [ "$file" != "$legacy_bootstrap" ] && [ "$file" != "$cuty_bootstrap" ]; then
    mutation_audited_files+=("$file")
  fi
  [ "$file" = "$legacy_bootstrap" ] || credential_audited_files+=("$file")
done

if contains_direct_mutation "${mutation_audited_files[@]}"; then
  fail "Federation automation contains a direct cluster mutation"
fi

if contains_credential_materialization "${credential_audited_files[@]}"; then
  fail "Federation automation contains credential materialization"
fi

test -z "$(find "$ROOT/releases/poc/rgw-analysis-web/dependencies" -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit)" ||
  fail "legacy POC dependencies must not contain deployable YAML"
test -z "$(find "$ROOT/releases/cuty/rgw-analysis-web/dependencies" -type f \( -name '*.yaml' -o -name '*.yml' \) -print -quit)" ||
  fail "Cuty dependencies must not contain deployable YAML"
rg -Fq 'TARGET_NAMESPACE=scalex-cuty-rgw-analysis-web' "$cuty_bootstrap" ||
  fail "Cuty bootstrap target namespace drifted"
rg -Fq 'TARGET_SECRET=scalex-cuty-rgw' "$cuty_bootstrap" ||
  fail "Cuty bootstrap target Secret drifted"
rg -Fq '"access-key-id": .data.AWS_ACCESS_KEY_ID' "$cuty_bootstrap" || fail "Cuty access key contract drifted"
rg -Fq '"secret-access-key": .data.AWS_SECRET_ACCESS_KEY' "$cuty_bootstrap" || fail "Cuty secret key contract drifted"
rg -Fq 'apply --server-side' "$cuty_bootstrap" || fail "Cuty bootstrap must use server-side apply"
if rg -n -- '--arg (access|secret|session)|jsonpath=.*AWS_' "$cuty_bootstrap" >/dev/null; then
  fail "Cuty bootstrap exposes credential material through process arguments"
fi
mapfile -t cuty_mutations < <(
  rg -n 'kubectl([[:space:]\\]|[^[:space:]])*[[:space:]]+(apply|create|delete|edit|patch|replace|rollout|scale|set)([[:space:]]|$)' \
    "$cuty_bootstrap"
)
[ "${#cuty_mutations[@]}" -eq 2 ] || fail "Cuty bootstrap mutation surface drifted"
printf '%s\n' "${cuty_mutations[@]}" | grep -Fq 'create namespace "$TARGET_NAMESPACE"' ||
  fail "Cuty bootstrap namespace mutation drifted"
printf '%s\n' "${cuty_mutations[@]}" | grep -Fq 'apply --server-side' ||
  fail "Cuty bootstrap Secret mutation drifted"
rg -Fq './scripts/rgw-analysis-web/observe-release.sh' "$ROOT/.github/workflows/runtime-observation.yaml" ||
  fail "runtime workflow must invoke the read-only observer"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

kubectl() {
  case "$*" in
    *"get secret"*"-o json")
      if [ "${FAKE_SOURCE_MODE:-ready}" = missing ]; then
        printf '%s\n' '{"apiVersion":"v1","kind":"Secret","data":{}}'
      else
        printf '%s\n' '{"apiVersion":"v1","kind":"Secret","data":{"AWS_ACCESS_KEY_ID":"ZmFrZS1hY2Nlc3M=","AWS_SECRET_ACCESS_KEY":"ZmFrZS1zZWNyZXQ="}}'
      fi
      ;;
    *"get namespace"*) return 0 ;;
    *"apply --server-side"*"--field-manager=scalex-credential-bootstrap"*"-f -"*)
      jq -e '
        .apiVersion == "v1" and
        .kind == "Secret" and
        .metadata.namespace == "scalex-cuty-rgw-analysis-web" and
        .metadata.name == "scalex-cuty-rgw" and
        .type == "Opaque" and
        (.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] // null) == null and
        (.data | keys | sort) == ["access-key-id", "secret-access-key"] and
        .data["access-key-id"] == "ZmFrZS1hY2Nlc3M=" and
        .data["secret-access-key"] == "ZmFrZS1zZWNyZXQ="
      ' >/dev/null
      ;;
    *) fail "unexpected bootstrap kubectl invocation: $*" ;;
  esac
}
export -f kubectl fail
bootstrap_output="$(
  TARGET_NAMESPACE=attacker TARGET_SECRET=attacker \
    B_KUBECONFIG=/fake/b KARMADA_KUBECONFIG=/fake/karmada "$cuty_bootstrap"
)"
[ "$bootstrap_output" = "Karmada credential Secret applied: scalex-cuty-rgw-analysis-web/scalex-cuty-rgw" ] ||
  fail "Cuty bootstrap success output drifted"
[[ "$bootstrap_output" != *ZmFrZS* ]] || fail "Cuty bootstrap leaked credential material"
if FAKE_SOURCE_MODE=missing B_KUBECONFIG=/fake/b KARMADA_KUBECONFIG=/fake/karmada \
  "$cuty_bootstrap" >/dev/null 2>&1; then
  fail "Cuty bootstrap accepted a source Secret without required keys"
fi

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
