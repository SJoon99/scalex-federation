#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

copy_repo() {
  local target="$1"
  mkdir -p "$target"
  cp -a "$ROOT/.github" "$ROOT/bootstrap" "$ROOT/docs" \
    "$ROOT/releases" "$ROOT/scripts" "$ROOT/tests" "$ROOT/README.md" "$target/"
}

expect_failure() {
  local target="$1"
  local expected="$2"
  if "$target/scripts/validate.sh" >"$target/test.out" 2>"$target/test.err"; then
    echo "validation unexpectedly passed: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$target/test.err" || {
    cat "$target/test.err" >&2
    exit 1
  }
}

"$ROOT/scripts/validate.sh" >/dev/null

case_root="$tmp/mutable-revision"
copy_repo "$case_root"
yq -i '.source.revision = "main"' "$case_root/releases/poc/rgw-analysis-web/release.yaml"
expect_failure "$case_root" "source revision must be a full immutable SHA"

case_root="$tmp/duplicate-namespace"
copy_repo "$case_root"
mkdir -p "$case_root/releases/poc/second-release"
cp "$case_root/releases/poc/rgw-analysis-web/"{release.yaml,values.yaml} "$case_root/releases/poc/second-release/"
yq -i '
  .name = "second-release" |
  .values.path = "releases/poc/second-release/values.yaml"
' "$case_root/releases/poc/second-release/release.yaml"
expect_failure "$case_root" "duplicate release namespaces"

case_root="$tmp/federation-policy"
copy_repo "$case_root"
mkdir -p "$case_root/releases/poc/rgw-analysis-web/policy"
expect_failure "$case_root" "must not contain policy or dependencies"

case_root="$tmp/inline-credential"
copy_repo "$case_root"
printf '\npassword: test-only\n' >>"$case_root/releases/poc/rgw-analysis-web/values.yaml"
expect_failure "$case_root" "appear to contain inline credential fields"

case_root="$tmp/wrong-destination"
copy_repo "$case_root"
yq -i '.spec.template.spec.destination.name = "b"' "$case_root/bootstrap/applicationset.yaml"
expect_failure "$case_root" "ApplicationSet source or destination contract drifted"

case_root="$tmp/wildcard-source"
copy_repo "$case_root"
yq -i '.spec.sourceRepos += ["*"]' "$case_root/bootstrap/appproject.yaml"
expect_failure "$case_root" "AppProject sourceRepos must contain exact GitHub repository URLs"

active_root="$tmp/active-contract"
copy_repo "$active_root"
source_root="$active_root/source-root"
source_repo="$source_root/feature-contract-fixture"
mkdir -p "$source_repo/chart"
cp -a "$ROOT/tests/fixtures/feature-chart/." "$source_repo/chart/"
git -C "$source_repo" init --quiet
git -C "$source_repo" config user.name test
git -C "$source_repo" config user.email test@example.invalid
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m fixture
git -C "$source_repo" remote add origin https://github.com/example/feature-contract-fixture.git
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '
  .state = "active" |
  .source.repoURL = "https://github.com/example/feature-contract-fixture.git" |
  .source.path = "chart" |
  .source.revision = strenv(REVISION)
' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
yq -i '.spec.sourceRepos += ["https://github.com/example/feature-contract-fixture.git"]' "$active_root/bootstrap/appproject.yaml"
FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >/dev/null

cp "$source_repo/chart/templates/policy.yaml" "$tmp/policy.yaml"
sed -i '0,/name: {{ .Release.Name }}/! s/name: {{ .Release.Name }}/name: does-not-exist/' \
  "$source_repo/chart/templates/policy.yaml"
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m stale-selector
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/stale-selector.out" 2>"$active_root/stale-selector.err"; then
  echo "stale Karmada selector unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'Karmada policy selector coverage failed' "$active_root/stale-selector.err"

cp "$tmp/policy.yaml" "$source_repo/chart/templates/policy.yaml"
cat >"$source_repo/chart/templates/service.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  selector:
    app.kubernetes.io/name: fixture
  ports:
    - port: 80
      targetPort: 8080
EOF
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m unselected-service
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/unselected-service.out" 2>"$active_root/unselected-service.err"; then
  echo "unselected Service unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'Karmada policy selector coverage failed' "$active_root/unselected-service.err"

rm "$source_repo/chart/templates/service.yaml"
cp "$tmp/policy.yaml" "$source_repo/chart/templates/policy.yaml"
sed -i '/^  placement:/i\    - apiVersion: batch/v1\n      kind: Job\n      name: {{ .Release.Name }}\n      namespace: {{ .Release.Namespace }}' \
  "$source_repo/chart/templates/policy.yaml"
git -C "$source_repo" add -A
git -C "$source_repo" commit --quiet -m duplicate-selector
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/duplicate-selector.out" 2>"$active_root/duplicate-selector.err"; then
  echo "duplicate Karmada selector unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'Karmada policy selector coverage failed' "$active_root/duplicate-selector.err"

cp "$tmp/policy.yaml" "$source_repo/chart/templates/policy.yaml"
cat >"$source_repo/chart/templates/rbac.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ .Release.Name }}
subjects:
  - kind: ServiceAccount
    name: default
    namespace: {{ .Release.Namespace }}
---
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: {{ .Release.Name }}-rbac
  namespace: {{ .Release.Namespace }}
spec:
  resourceSelectors:
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: Role
      name: {{ .Release.Name }}
      namespace: {{ .Release.Namespace }}
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      name: {{ .Release.Name }}
      namespace: {{ .Release.Namespace }}
  placement:
    clusterAffinity:
      clusterNames:
        - fixture-member
EOF
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m safe-role-binding
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >/dev/null

sed -i '/^roleRef:/,/^subjects:/ s/^  kind: Role$/  kind: ClusterRole/; /^roleRef:/,/^subjects:/ s/^  name: {{ .Release.Name }}$/  name: admin/' \
  "$source_repo/chart/templates/rbac.yaml"
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m unsafe-role-binding
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/unsafe-rbac.out" 2>"$active_root/unsafe-rbac.err"; then
  echo "RoleBinding to ClusterRole unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'namespaced RBAC must bind local Roles' "$active_root/unsafe-rbac.err"

rm "$source_repo/chart/templates/rbac.yaml"
cp "$tmp/policy.yaml" "$source_repo/chart/templates/policy.yaml"
git -C "$source_repo" add -A
git -C "$source_repo" commit --quiet -m restore-policy
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >/dev/null

rm "$source_repo/chart/templates/policy.yaml"
git -C "$source_repo" add -u
git -C "$source_repo" commit --quiet -m no-policy
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.source.revision = strenv(REVISION)' "$active_root/releases/poc/rgw-analysis-web/release.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/no-policy.out" 2>"$active_root/no-policy.err"; then
  echo "active chart without Karmada policy unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'active feature chart must render a PropagationPolicy' "$active_root/no-policy.err"

echo "federation validation fixtures passed"
