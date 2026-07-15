#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

copy_repo() {
  local target="$1"
  mkdir -p "$target"
  tar --exclude .git --exclude .omx --exclude tests/fixtures -cf - -C "$ROOT" . | tar -xf - -C "$target"
}

expect_reject() {
  local name="$1" expected="$2"
  local fixture="$tmp/$name"
  copy_repo "$fixture"
  shift 2
  (cd "$fixture" && "$@")
  if FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-/home/joon/study/scalex/work}" "$fixture/scripts/validate.sh" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "fixture unexpectedly passed: $name" >&2
    exit 1
  fi
  grep -Fq "$expected" "$tmp/$name.err" || {
    echo "fixture failed with the wrong error: $name" >&2
    cat "$tmp/$name.err" >&2
    exit 1
  }
}

FEATURE_REPOS_ROOT="${FEATURE_REPOS_ROOT:-/home/joon/study/scalex/work}" "$ROOT/scripts/validate.sh" >/dev/null

expect_reject duplicate-release 'duplicate release identity' \
  yq e -i '.releases += [.releases[0]]' values.yaml

expect_reject per-release-directory 'single-values experiment must not contain a releases directory' \
  mkdir -p releases/poc/example

expect_reject mutable-revision 'source revision must be an immutable full SHA' \
  yq e -i '.releases[0].source.revision = "main"' values.yaml

expect_reject bad-namespace 'invalid release namespace' \
  yq e -i '.releases[0].namespace = "default"' values.yaml

expect_reject inline-secret 'catalog appears to contain inline secret-shaped fields' \
  yq e -i '.releases[0].helm.values += "\npassword: not-a-real-secret\n"' values.yaml

expect_reject retained-dependency-contract 'catalog must not retain Federation-owned policy or dependency contract blocks' \
  yq e -i '.releases[0].dependencies.objectBucketClaim.name = "rgw-analysis-web-bucket"' values.yaml

expect_reject appset-path-wiring 'ApplicationSet must use native matrix git/list catalog wiring with active-state selector' \
  yq e -i '.spec.generators[0].matrix.generators[0].git.files[0].path = "releases/*/*/release.yaml"' bootstrap/applicationset.yaml

expect_reject appset-revision-wiring 'ApplicationSet must use native matrix git/list catalog wiring with active-state selector' \
  yq e -i '.spec.generators[0].matrix.generators[0].git.revision = "main"' bootstrap/applicationset.yaml

expect_reject appset-selector-wiring 'ApplicationSet must use native matrix git/list catalog wiring with active-state selector' \
  yq e -i '.spec.generators[0].selector.matchLabels.state = "disabled"' bootstrap/applicationset.yaml


expect_reject appset-create-namespace-wiring 'ApplicationSet must use native matrix git/list catalog wiring with active-state selector' \
  yq e -i 'del(.spec.template.spec.syncPolicy.syncOptions[] | select(. == "CreateNamespace=true"))' bootstrap/applicationset.yaml

expect_reject appproject-missing-namespace-permission 'AppProject must keep only core Namespace plus namespaced workload and Karmada policy permissions' \
  yq e -i 'del(.spec.clusterResourceWhitelist)' bootstrap/appproject.yaml

expect_reject appproject-cluster-binding-permission 'AppProject must keep only core Namespace plus namespaced workload and Karmada policy permissions' \
  yq e -i '.spec.clusterResourceWhitelist += [{"group":"work.karmada.io","kind":"ClusterResourceBinding"}]' bootstrap/appproject.yaml

expect_reject appproject-obc-permission 'AppProject must keep only core Namespace plus namespaced workload and Karmada policy permissions' \
  yq e -i '.spec.namespaceResourceWhitelist += [{"group":"objectbucket.io","kind":"ObjectBucketClaim"}]' bootstrap/appproject.yaml

expect_reject appproject-binding-permission 'AppProject must keep only core Namespace plus namespaced workload and Karmada policy permissions' \
  yq e -i '.spec.namespaceResourceWhitelist += [{"group":"work.karmada.io","kind":"ResourceBinding"}]' bootstrap/appproject.yaml

expect_reject active-release-without-policy 'active release chart must render at least one PropagationPolicy' \
  yq e -i '.releases[0].state = "active" | del(.releases[0].disabledReason)' values.yaml

expect_reject wrong-destination 'release destination must be karmada' \
  yq e -i '.releases[0].destination.name = "b"' values.yaml

expect_reject wildcard-source 'AppProject sourceRepos must contain exact GitHub repository URLs' \
  yq e -i '.spec.sourceRepos += ["*"]' bootstrap/appproject.yaml

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
  .releases[0].state = "active" |
  del(.releases[0].disabledReason) |
  .releases[0].source.repoURL = "https://github.com/example/feature-contract-fixture.git" |
  .releases[0].source.path = "chart" |
  .releases[0].source.revision = strenv(REVISION) |
  .releases[0].helm.values = "image: example.invalid/scalex/fixture:v1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
' "$active_root/values.yaml"
yq -i '.spec.sourceRepos += ["https://github.com/example/feature-contract-fixture.git"]' \
  "$active_root/bootstrap/appproject.yaml"
FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >/dev/null

cp "$source_repo/chart/templates/policy.yaml" "$tmp/policy.yaml"
sed -i '0,/name: {{ .Release.Name }}/! s/name: {{ .Release.Name }}/name: does-not-exist/' \
  "$source_repo/chart/templates/policy.yaml"
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m stale-selector
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.releases[0].source.revision = strenv(REVISION)' "$active_root/values.yaml"
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
REVISION="$revision" yq -i '.releases[0].source.revision = strenv(REVISION)' "$active_root/values.yaml"
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
REVISION="$revision" yq -i '.releases[0].source.revision = strenv(REVISION)' "$active_root/values.yaml"
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
REVISION="$revision" yq -i '.releases[0].source.revision = strenv(REVISION)' "$active_root/values.yaml"
FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >/dev/null

sed -i '/^roleRef:/,/^subjects:/ s/^  kind: Role$/  kind: ClusterRole/; /^roleRef:/,/^subjects:/ s/^  name: {{ .Release.Name }}$/  name: admin/' \
  "$source_repo/chart/templates/rbac.yaml"
git -C "$source_repo" add chart
git -C "$source_repo" commit --quiet -m unsafe-role-binding
revision="$(git -C "$source_repo" rev-parse HEAD)"
REVISION="$revision" yq -i '.releases[0].source.revision = strenv(REVISION)' "$active_root/values.yaml"
if FEATURE_REPOS_ROOT="$source_root" "$active_root/scripts/validate.sh" >"$active_root/unsafe-rbac.out" 2>"$active_root/unsafe-rbac.err"; then
  echo "RoleBinding to ClusterRole unexpectedly passed" >&2
  exit 1
fi
grep -Fq 'namespaced RBAC must bind local Roles' "$active_root/unsafe-rbac.err"

echo "catalog validation adversarial fixtures passed"
