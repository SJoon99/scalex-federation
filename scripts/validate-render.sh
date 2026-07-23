#!/bin/sh
# ScaleX child chart — 렌더 결과 계약 검증
#
# child 이름·cluster 이름·IP가 등장하지 않는 불변식만 검사한다.
# 따라서 어떤 child가 복사해도 깨지지 않는다.
#
# 구현 제약: POSIX sh + yq(mikefarah v4) 만 사용한다.
#   Tekton ci.images에는 ruby/python이 없다. bash 확장(배열, [[ ]], <<<)도 쓰지 않는다.
#
# Usage:
#   validate-render.sh --profile=child      --namespace NS  RENDERED.yaml
#   validate-render.sh --profile=federation --namespace NS  --appproject PATH  RENDERED.yaml
#   validate-render.sh --profile=child --namespace NS --expect-no-policy  RENDERED.yaml
#
# Options:
#   --profile=child|federation  child: V1 V2 V4 V5 / federation: + V3 V6
#   --namespace NS              release namespace (필수)
#   --appproject PATH           argocd/appproject.yaml 경로 (federation profile에서 V6용)
#   --expect-no-policy          V7: policy가 0개여야 함 (karmada.enabled=false 렌더 검증용)
#   --strict-namespace          V4b(metadata.namespace 누락)를 WARN이 아니라 ERROR로 취급
#   --allow-kinds K1,K2         V5에서 허용할 cluster-scoped kind.
#                               release.yaml의 requiredKinds와 같은 값을 넘긴다.
#                               --appproject를 주면 clusterResourceWhitelist가 자동 합산된다.
#
# Environment:
#   YQ_BIN   yq 실행 파일 (기본: yq)

set -eu

YQ="${YQ_BIN:-yq}"

profile=""
namespace=""
appproject=""
expect_no_policy=false
strict_namespace=false
allow_kinds=""
rendered=""

die() { printf 'validate-render: %s\n' "$1" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile=*)        profile="${1#--profile=}"; shift ;;
    --profile)          profile="${2:-}"; shift 2 ;;
    --namespace=*)      namespace="${1#--namespace=}"; shift ;;
    --namespace|-n)     namespace="${2:-}"; shift 2 ;;
    --appproject=*)     appproject="${1#--appproject=}"; shift ;;
    --appproject)       appproject="${2:-}"; shift 2 ;;
    --expect-no-policy) expect_no_policy=true; shift ;;
    --strict-namespace) strict_namespace=true; shift ;;
    --allow-kinds=*)    allow_kinds="$(printf '%s' "${1#--allow-kinds=}" | tr ',' ' ')"; shift ;;
    --allow-kinds)      allow_kinds="$(printf '%s' "${2:-}" | tr ',' ' ')"; shift 2 ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    -*)                 die "unknown option: $1" ;;
    *)                  [ -z "$rendered" ] || die "only one manifest may be given"; rendered="$1"; shift ;;
  esac
done

[ -n "$profile" ] || die "--profile is required (child|federation)"
[ -n "$namespace" ] || die "--namespace is required"
[ -n "$rendered" ] || die "rendered manifest path is required"
[ -f "$rendered" ] || die "rendered manifest not found: $rendered"
case "$profile" in
  child|federation) ;;
  *) die "--profile must be child or federation" ;;
esac
if [ "$profile" = federation ] && [ -z "$appproject" ]; then
  die "--appproject is required for --profile=federation (V6)"
fi
[ -z "$appproject" ] || [ -f "$appproject" ] || die "appproject not found: $appproject"
command -v "$YQ" >/dev/null 2>&1 || die "required command not found: $YQ"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

errors=0
warns=0
fail()  { printf '  [FAIL] %s\n' "$1"; errors=$((errors + 1)); }
warn()  { printf '  [WARN] %s\n' "$1"; warns=$((warns + 1)); }
ok()    { printf '  [ ok ] %s\n' "$1"; }

# ---------------------------------------------------------------- 데이터 추출

# resources.tsv : apiVersion \t kind \t name \t namespace
"$YQ" -r '
  select(. != null) |
  [(.apiVersion // ""), (.kind // ""), (.metadata.name // ""), (.metadata.namespace // "")] | @tsv
' "$rendered" > "$tmp/resources.tsv"

# selectors.tsv : policyKind \t policyName \t selApiVersion \t selKind \t selName \t selNamespace
"$YQ" -r '
  select(. != null) |
  select(.kind == "PropagationPolicy" or .kind == "OverridePolicy") |
  [(.kind // ""), (.metadata.name // "")] as $p |
  (.spec.resourceSelectors // [])[] |
  ($p + [(.apiVersion // ""), (.kind // ""), (.name // ""), (.namespace // "")]) | @tsv
' "$rendered" > "$tmp/selectors.tsv"

# images.tsv : kind \t name \t image
"$YQ" -r '
  select(. != null) |
  [(.kind // ""), (.metadata.name // "")] as $r |
  [
    (.spec.template.spec.containers // [])[],
    (.spec.template.spec.initContainers // [])[],
    (.spec.jobTemplate.spec.template.spec.containers // [])[],
    (.spec.jobTemplate.spec.template.spec.initContainers // [])[]
  ] | .[] |
  ($r + [(.image // "")]) | @tsv
' "$rendered" > "$tmp/images.tsv"

WORKLOAD_KINDS="Deployment StatefulSet DaemonSet ReplicaSet Job CronJob"

# child가 어떤 경우에도 렌더해서는 안 되는 kind.
# AppProject가 열어 주더라도 계약상 child의 소유가 아니다
# (Namespace는 Argo의 CreateNamespace가, Secret은 infra(*-k8s)가 만든다).
HARD_FORBIDDEN_KINDS="Namespace Secret"

# cluster-scoped kind. 기본은 거부하고, AppProject clusterResourceWhitelist에 있거나
# --allow-kinds로 명시된 경우에만 허용한다. release.yaml의 requiredKinds와 짝을 이룬다.
CLUSTER_SCOPED_KINDS="PersistentVolume StorageClass PriorityClass
CustomResourceDefinition APIService ClusterRole ClusterRoleBinding
ClusterPropagationPolicy ClusterOverridePolicy
ValidatingWebhookConfiguration MutatingWebhookConfiguration"

is_workload() {
  for k in $WORKLOAD_KINDS; do [ "$1" = "$k" ] && return 0; done
  return 1
}

in_list() {
  needle="$1"; shift
  for k in $*; do [ "$needle" = "$k" ] && return 0; done
  return 1
}

# 리소스의 실효 namespace: 비어 있으면 release namespace로 배치된다
effective_ns() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "$namespace"; }

printf 'validate-render: profile=%s namespace=%s manifest=%s\n' "$profile" "$namespace" "$rendered"
printf 'documents=%s policies=%s\n\n' \
  "$(grep -c . "$tmp/resources.tsv" || true)" \
  "$(awk -F'\t' '$2=="PropagationPolicy"||$2=="OverridePolicy"' "$tmp/resources.tsv" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- V7

if [ "$expect_no_policy" = true ]; then
  printf 'V7  karmada 비활성 렌더에 policy가 0개인가\n'
  n="$(awk -F'\t' '$2=="PropagationPolicy"||$2=="OverridePolicy"' "$tmp/resources.tsv" | wc -l | tr -d ' ')"
  if [ "$n" -eq 0 ]; then ok "policy 0개"; else fail "karmada.enabled=false 인데 policy가 $n 개 렌더됨"; fi
  printf '\n'
  printf 'result: errors=%s warns=%s\n' "$errors" "$warns"
  [ "$errors" -eq 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------- V1

printf 'V1  모든 workload가 정확히 1개의 PropagationPolicy에 선택되는가\n'
v1_checked=0
while IFS="$(printf '\t')" read -r api kind name ns; do
  [ -n "$kind" ] || continue
  is_workload "$kind" || continue
  v1_checked=$((v1_checked + 1))
  rns="$(effective_ns "$ns")"
  hits="$(awk -F'\t' -v k="$kind" -v n="$name" -v rns="$rns" -v api="$api" '
    $1=="PropagationPolicy" && $4==k && $5==n &&
    ($3=="" || $3==api) &&
    ($6=="" || $6==rns) { print $2 }
  ' "$tmp/selectors.tsv" | sort -u)"
  count="$(printf '%s' "$hits" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then
    ok "$kind/$name ← $hits"
  elif [ "$count" -eq 0 ]; then
    fail "$kind/$name 을 선택하는 PropagationPolicy가 없다 (member cluster에 배포되지 않음)"
  else
    fail "$kind/$name 이 $count 개 policy에 중복 선택됨: $(printf '%s' "$hits" | tr '\n' ' ')"
  fi
done < "$tmp/resources.tsv"
[ "$v1_checked" -gt 0 ] || fail "workload가 하나도 렌더되지 않았다"
printf '\n'

# ---------------------------------------------------------------- V2

printf 'V2  모든 policy resourceSelector가 실제 렌더된 리소스를 가리키는가 (dangling 0)\n'
if [ ! -s "$tmp/selectors.tsv" ]; then
  fail "resourceSelector가 하나도 없다 (policy 누락 또는 selector 비어 있음)"
else
  while IFS="$(printf '\t')" read -r pkind pname sapi skind sname sns; do
    [ -n "$skind" ] || continue
    hit=0
    while IFS="$(printf '\t')" read -r api kind name ns; do
      [ "$kind" = "$skind" ] || continue
      [ -z "$sname" ] || [ "$name" = "$sname" ] || continue
      [ -z "$sapi" ] || [ "$api" = "$sapi" ] || continue
      [ -z "$sns" ] || [ "$(effective_ns "$ns")" = "$sns" ] || continue
      hit=1; break
    done < "$tmp/resources.tsv"
    if [ "$hit" -eq 1 ]; then
      ok "$pkind/$pname → $skind/$sname"
    else
      fail "$pkind/$pname 의 selector가 렌더되지 않은 리소스를 가리킨다: $sapi $skind/$sname (ns=$sns)"
    fi
  done < "$tmp/selectors.tsv"
fi
printf '\n'

# ---------------------------------------------------------------- V4

printf 'V4  namespaced 리소스가 release namespace를 쓰는가\n'
missing_ns=0
while IFS="$(printf '\t')" read -r api kind name ns; do
  [ -n "$kind" ] || continue
  if [ -z "$ns" ]; then
    missing_ns=$((missing_ns + 1))
  elif [ "$ns" != "$namespace" ]; then
    fail "$kind/$name 의 namespace가 release namespace와 다르다: $ns != $namespace"
  fi
done < "$tmp/resources.tsv"
if [ "$missing_ns" -gt 0 ]; then
  msg="$missing_ns 개 리소스에 metadata.namespace가 없다 (release namespace로 배치되므로 동작은 하나, 계약은 명시를 요구한다)"
  if [ "$strict_namespace" = true ]; then fail "$msg"; else warn "$msg"; fi
else
  ok "모든 리소스가 명시적으로 $namespace 를 쓴다"
fi
printf '\n'

# ---------------------------------------------------------------- V5

printf 'V5  금지 kind가 0개인가 (child는 infra/cluster-scoped를 소유하지 않는다)\n'

# 허용된 cluster-scoped kind 집합: --allow-kinds + AppProject clusterResourceWhitelist
allowed_cluster_kinds="$allow_kinds"
if [ -n "$appproject" ]; then
  allowed_cluster_kinds="$allowed_cluster_kinds $("$YQ" -r \
    '(.spec.clusterResourceWhitelist // [])[] | .kind' "$appproject" | tr '\n' ' ')"
fi

v5_hit=0
while IFS="$(printf '\t')" read -r api kind name ns; do
  [ -n "$kind" ] || continue
  if in_list "$kind" "$HARD_FORBIDDEN_KINDS"; then
    fail "child가 소유할 수 없는 kind가 렌더되었다: $kind/$name"
    v5_hit=1
  elif in_list "$kind" "$CLUSTER_SCOPED_KINDS"; then
    if in_list "$kind" "$allowed_cluster_kinds"; then
      ok "$kind/$name (cluster-scoped, 명시적으로 허용됨)"
    else
      fail "cluster-scoped kind가 허용되지 않았다: $kind/$name (release.yaml의 requiredKinds와 AppProject를 확인하라)"
      v5_hit=1
    fi
  fi
done < "$tmp/resources.tsv"
[ "$v5_hit" -eq 1 ] || ok "금지 kind 없음"
printf '\n'

# ---------------------------------------------------------------- V3 (federation)

if [ "$profile" = federation ]; then
  printf 'V3  모든 container image에 @sha256 digest가 있는가\n'
  if [ ! -s "$tmp/images.tsv" ]; then
    fail "container image가 하나도 없다"
  else
    while IFS="$(printf '\t')" read -r kind name image; do
      [ -n "$image" ] || continue
      if printf '%s' "$image" | grep -Eq '@sha256:[0-9a-f]{64}$'; then
        ok "$kind/$name $(printf '%s' "$image" | sed 's/.*@/@/' | cut -c1-19)…"
      else
        fail "$kind/$name 의 image에 digest가 없다: $image"
      fi
    done < "$tmp/images.tsv"
  fi
  printf '\n'

  printf 'V6  렌더된 모든 kind가 AppProject whitelist 안에 있는가\n'
  "$YQ" -r '
    [(.spec.namespaceResourceWhitelist // [])[], (.spec.clusterResourceWhitelist // [])[]] |
    .[] | .kind
  ' "$appproject" | sort -u > "$tmp/whitelist.txt"
  awk -F'\t' '$2!=""{print $2}' "$tmp/resources.tsv" | sort -u > "$tmp/kinds.txt"
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    if grep -qx "$kind" "$tmp/whitelist.txt"; then
      ok "$kind"
    else
      fail "$kind 가 AppProject whitelist에 없다 (Argo가 sync 시점에 거부한다)"
    fi
  done < "$tmp/kinds.txt"
  printf '\n'
fi

# ---------------------------------------------------------------- 결과

printf 'result: errors=%s warns=%s\n' "$errors" "$warns"
[ "$errors" -eq 0 ] || exit 1
exit 0
