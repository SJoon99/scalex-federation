# 권장 수정 방향

[`child-design-review.md`](child-design-review.md)의 발견 사항(F1~F12)에 대한 실행 계획이다.
각 항목은 **변경 대상 · 수용 기준 · 위험 · 비목표**를 갖는다.

이 문서는 제안이며, **기존 코드는 아직 변경하지 않았다.**

우선순위 원칙: *child 이름이 등장하는 곳의 개수를 줄이는 변경을 먼저 한다.*

| # | 제안 | 해소 | 크기 | 순서 |
|---|---|---|---|---|
| P1 | child 명세 `scalex.yaml` 도입 | F1 F2 F7 | M | 1 |
| P2 | 컴포넌트 루프 chart scaffold | F1 F4 | M | 2 |
| P3 | 계약 기반 render 검증 | F3 | S | 2 |
| P4 | `build-targets` 자동 파생 | F2 F8 | M | 3 |
| P5 | topology를 `runtime-values.yaml`로 이관 | F4 F12 | S | 3 |
| P6 | 빌드 경로 단일화 | F5 | S | 3 |
| P7 | `sourceRepos` 생성화 + offboard 절차 | F6 F10 | M | 4 |
| P8 | 입력 계약 확장 (private/GitLab) | F9 | L | 5 |
| P9 | 계약 문서 소유권 이전 | F11 | S | 1 |

---

## P1. child 명세 `scalex.yaml` 도입

### 무엇을

child repository root에 기계가 읽는 선언 파일 하나를 계약으로 추가한다. 이 파일이
**child에 관한 유일한 진실**이 된다.

```yaml
apiVersion: scalex.io/v1
kind: ChildSpec

metadata:
  name: scalex-my-child            # release ID = namespace. ^scalex-[a-z0-9-]+$

spec:
  chart:
    path: chart

  images:
    - name: api                    # kebab-case. chart values의 images 키와 동일
      context: .
      dockerfile: images/api/Dockerfile
      tag: v0.2.0                  # semver. release마다 상승

  components:
    - name: api
      kind: Deployment             # Deployment | StatefulSet | DaemonSet | CronJob | Job
      image: api                   # spec.images[].name 참조
      replicas: 1
      containerPort: 8080
      service:
        port: 80
        exposure: internal         # internal | member-lb
      probe:
        path: /healthz
      env:
        - name: LOG_LEVEL
          value: info

    - name: nightly
      kind: CronJob
      image: api
      schedule: "*/30 * * * *"
      args: ["analyze"]

  placement:
    # child는 "같이 붙어야 한다 / 떨어져야 한다"는 의도만 선언한다.
    # 실제 member cluster 이름과 LB IP는 Federation runtime-values.yaml이 채운다.
    groups:
      - name: frontend
        components: [api]
      - name: batch
        components: [nightly]
```

명세에 **넣지 않는** 것 (Federation/Infra 소유):

```text
member cluster 이름 (b, c)      registry host (10.34.25.18)
Cilium LB IP                    Harbor project prefix (tower-ci)
namespace 전체 이름              image digest
```

### 왜 이 형태인가

- `images`와 `components`를 분리해 **하나의 이미지를 여러 컴포넌트가 재사용**할 수 있게 한다
  (`temp-poc`는 이미 그런 구조인데 표현 수단이 없어 중복 정의한다).
- `placement.groups`는 cluster 이름을 담지 않는다. child가 토폴로지를 알면 복제 시
  남의 IP를 들고 간다 (F4).
- `name`을 `scalex-` 강제로 두어 F12의 네이밍 비대칭을 처음부터 차단한다.

### 변경 대상

| 파일 | 변경 |
|---|---|
| `scalex-federation/docs/child-spec.md` (신규) | 스키마 정의 |
| `scalex-federation/schemas/childspec.v1.json` (신규) | JSON Schema |
| `scalex-federation/tests/test_childspec.py` (신규) | 스키마 검증 테스트 |
| `sample-poc/scalex.yaml` (신규) | 최소 예시 |

### 수용 기준

- `sample-poc`와 `temp-poc` 둘 다 이 스키마로 **손실 없이** 표현된다
  (표현 불가능한 필드가 나오면 스키마를 고친다 — 이것이 스키마 타당성 검증이다)
- `scalex.yaml` 없이도 기존 child는 계속 동작한다 (하위 호환)

### 위험

`temp-poc`의 `OverridePolicy`(Service→LoadBalancer + Cilium IP)가 스키마로 표현
가능한지가 관건이다. `service.exposure: member-lb`로 추상화하고 실제 IP는
`runtime-values.yaml`이 채우는 형태를 먼저 검증한다.

### 비목표

`scalex.yaml`을 Kubernetes CRD로 만들지 않는다. Git 파일로만 존재한다.

---

## P2. 컴포넌트 루프 chart scaffold

### 무엇을

컴포넌트당 template 파일을 만드는 방식을 버리고, `.Values.components`를 `range`로 도는
template 세트를 표준 scaffold로 제공한다.

```text
chart/templates/
├── _helpers.tpl
├── workloads.yaml        # range → Deployment | StatefulSet | DaemonSet | CronJob
├── services.yaml         # range → Service (service 필드가 있는 컴포넌트만)
└── karmada.yaml          # range → PropagationPolicy (+ 필요 시 OverridePolicy)
```

`karmada.yaml`이 컴포넌트마다 policy를 **자동 생성**하므로 "policy 누락"이라는 계약 위반
1순위가 구조적으로 불가능해진다.

```gotemplate
{{- range $c := .Values.components }}
{{- $placement := index $.Values.placement (default "default" $c.placementGroup) }}
---
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: {{ include "child.fullname" $ }}-{{ $c.name }}
  namespace: {{ $.Release.Namespace }}
spec:
  conflictResolution: Abort
  preemption: Never
  propagateDeps: true
  resourceSelectors:
    - apiVersion: {{ include "child.apiVersion" $c }}
      kind: {{ $c.kind }}
      name: {{ include "child.fullname" $ }}-{{ $c.name }}
      namespace: {{ $.Release.Namespace }}
    {{- if $c.service }}
    - apiVersion: v1
      kind: Service
      name: {{ include "child.fullname" $ }}-{{ $c.name }}
      namespace: {{ $.Release.Namespace }}
    {{- end }}
  placement:
    clusterAffinity:
      clusterNames:
        - {{ required "placement cluster must come from runtime-values.yaml" $placement.cluster }}
{{- end }}
```

`required`를 쓰는 것이 핵심이다. **cluster 이름이 child 기본값에 없으면 렌더가 실패**하므로
F4가 재발할 수 없다.

### 배치 결정

**child가 template을 보유한다(안 a).** 공용 library chart(안 b)는 chart repository 운영이
필요하므로 지금 단계에서는 보류한다. 안정화 후 재검토한다.

### 변경 대상

`sample-poc/chart/templates/` — 신규 scaffold. **`temp-poc`는 건드리지 않는다**
(참조 구현으로 보존하고, 마이그레이션은 P2 안정화 이후 별도 판단).

### 수용 기준

- `sample-poc`가 컴포넌트 1개 → 3개로 늘 때 `values.yaml` 블록 추가만으로 끝난다
- 컴포넌트 삭제 시 잔여 policy/service가 남지 않는다
- `helm template`이 P3의 계약 검증을 통과한다

---

## P3. 계약 기반 render 검증

### 무엇을

`validate-render.sh`의 리터럴 assert를 이름 무관 불변식으로 교체하고, **소유권을
Federation으로 옮긴다.**

```text
scalex-federation/scripts/validate-render.sh   ← 여기가 정본
```

검증 항목 (child 이름이 등장하지 않는다):

| # | 불변식 |
|---|---|
| V1 | 모든 workload가 정확히 하나의 `PropagationPolicy`에 선택된다 |
| V2 | 모든 policy `resourceSelectors`가 실제 렌더된 resource를 가리킨다 (dangling 0) |
| V3 | 모든 container `image`가 `@sha256:<64hex>`를 갖는다 |
| V4 | 모든 namespaced resource의 `metadata.namespace`가 release namespace와 같다 |
| V5 | `Namespace`/`Secret`/`Cluster*` kind가 0개다 |
| V6 | 렌더된 모든 kind가 AppProject `namespaceResourceWhitelist`에 있다 |
| V7 | `karmada.enabled=false` 렌더에서 policy가 0개다 |

V6는 특히 가치가 크다 — Argo가 sync 시점에 거부하는 대신 **CI에서 미리 잡는다**.
`argocd/appproject.yaml`을 읽어 대조하므로 whitelist가 바뀌면 자동으로 따라간다.

### 변경 대상

- `scalex-federation/scripts/validate-render.sh` (신규)
- `eecs-k8s/apps/tekton-ci/templates/task-helm-validate.tpl` — 렌더 후 이 스크립트 호출 추가
- child의 `scripts/validate.sh` — 위 스크립트를 내려받아 실행 (또는 submodule)

### 위험

`task-helm-validate.tpl` 변경은 eecs-k8s 회귀 테스트(`tests/tekton-ci-regression.sh`)에
영향을 준다. child 측 로컬 스크립트를 먼저 도입하고, Tekton 통합은 검증 후 진행한다.

---

## P4. `build-targets` 자동 파생

### 무엇을

`build-targets` param을 **선택적**으로 만들고, 비어 있으면 clone된 repo의 `scalex.yaml`에서
파생한다.

```text
[현재]  PipelineRun ── build-targets JSON ──> build-push
[제안]  clone ──> derive-build-targets (scalex.yaml 읽기) ──> build-push
                        ↑ param이 주어지면 그것을 우선 (하위 호환)
```

### 변경 대상

| 파일 | 변경 |
|---|---|
| `eecs-k8s/apps/tekton-ci/templates/pipeline-child-build.tpl` | `build-targets` default `""`, `derive-targets` Task를 `clone` 뒤에 삽입 |
| `eecs-k8s/apps/tekton-ci/templates/task-derive-build-targets.tpl` (신규) | `scalex.yaml` → JSON 배열 (yq) |
| `eecs-k8s/tests/tekton-ci-regression.sh` | 파생 경로 회귀 추가 |

`valuesKey` 필드는 `name`과 같아야 한다는 제약이 이미 있으므로, 파생 시 **제거하고
`name`으로 통일**한다.

### 수용 기준

- `build-targets`를 명시한 기존 PipelineRun이 그대로 동작한다 (하위 호환)
- `scalex.yaml`만 있는 child가 param 없이 빌드된다
- `scalex.yaml`도 param도 없으면 명확한 오류로 실패한다

### 후속 (P4-b, 별도 판단)

트리거 계층(F8). Tekton Triggers `EventListener` + GitHub App webhook, 또는 인바운드
엔드포인트 없이 가는 outbound poller. **인바운드 공개 IP가 없다는 것이 현재 제약**이므로
poller 쪽이 현실적이다. P4가 끝나야 트리거가 만들 PipelineRun이 단순해진다 — 순서를 지킨다.

---

## P5. topology를 `runtime-values.yaml`로 이관

### 무엇을

child chart 기본값에서 cluster 이름과 LB IP를 제거하고, Federation이 채운다.

```yaml
# releases/scalex-my-child/runtime-values.yaml   ← 사람이 관리
placement:
  frontend:
    cluster: b
    loadBalancerIP: 10.33.142.20
  batch:
    cluster: c

endpoints:                       # 컴포넌트 간 참조도 여기서
  datasetUrl: http://10.33.142.20/dataset.csv
```

child chart의 `values.yaml`에는 `placement: {}`만 남기고, P2의 `required`가
Federation 렌더에서 값 주입을 강제한다.

### 부수 효과

`temp-poc`의 `runtime-values.yaml`이 `{}`인 현 상태는 "runtime override가 없다"가 아니라
"runtime 값이 잘못된 곳에 있다"는 뜻이었다. 이 이관으로 문서상 계약과 실물이 일치한다.

### 위험

`temp-poc`를 실제로 마이그레이션하면 **재배포가 발생**한다. 새 child에 먼저 적용하고
`temp-poc`는 유지보수 시점에 옮긴다.

---

## P6. 빌드 경로 단일화

### 무엇을

- **정식 경로**: Tekton `child-build` → `federation-promote` → PR → 사람이 merge
- child의 GitHub Actions는 **PR 검증 전용**으로 축소: `helm lint`, `helm template`,
  P3 계약 검증, 단위 테스트. **image push 금지, Federation 접근 금지.**

`temp-poc/.github/workflows/promote.yaml`은 Harbor push와 promotion payload 생성을 하지만
결과가 GitHub artifact에서 끝난다(ORAS publish 주석 처리). 이 경로는 **완결되지 않은 채
registry에 다른 태그 규칙으로 push**하고 있다.

### 변경 대상

- `sample-poc/.github/workflows/validate.yaml` — 검증 전용 템플릿 확정
- `scalex-federation/docs/child-onboarding-runbook.md` — 정식 경로 명시 (이미 반영됨)
- `temp-poc/.github/workflows/promote.yaml` — **당장 삭제하지 않는다.** P4 트리거가
  동작을 대체한 뒤 제거한다

### 수용 기준

새 child scaffold에는 image push 권한이 필요한 CI가 존재하지 않는다.
`runs-on: [self-hosted, ..., work8]` 같은 머신 고정 의존이 없다.

---

## P7. `sourceRepos` 생성화 + offboarding 절차화

### P7-a. `sourceRepos`를 release에서 파생

`argocd/appproject.yaml`의 `sourceRepos`를 손으로 유지하는 대신
`releases/*/release.yaml`의 `source.repoURL` 합집합 + Federation 자기 자신으로 생성한다.

두 가지 구현안:

| 안 | 방법 | 평가 |
|---|---|---|
| (a) 생성 스크립트 + CI 검증 | `scripts/render-appproject.sh`가 생성, CI가 drift 검사 | 단순. Argo 동작 변경 없음. **권장** |
| (b) AppProject를 Helm/ApplicationSet으로 렌더 | Argo가 직접 생성 | 부트스트랩 순환 위험 |

(a)를 권한다. `tests/test_promotion_contract.py`에 다음을 추가한다.

```python
declared = {r["source"]["repoURL"] for r in releases}
allowed  = set(appproject["spec"]["sourceRepos"]) - {FEDERATION_URL}
assert declared == allowed, "sourceRepos drift"
```

이것만으로 **dangling sourceRepo가 CI에서 잡힌다.**

### P7-b. offboarding 스크립트

runbook A-11의 7단계를 스크립트로 만든다.

```bash
scripts/offboard-child.sh scalex-my-child
#  1) state != disabled 면 중단하고 안내
#  2) releases/<id>/ 삭제
#  3) render-appproject.sh 재실행
#  4) test_promotion_contract.py 실행
#  5) Harbor tower-ci/<child>/* 잔여 목록 출력  ← 삭제는 사람이 확인 후
```

Git 밖 자원(Harbor repository)은 **자동 삭제하지 않고 목록만 제시**한다. 되돌릴 수 없는
작업을 스크립트가 조용히 수행하지 않게 한다.

### 수용 기준

- child 등록이 `releases/<id>/` 디렉터리 추가 1회로 끝난다
- child 해제 후 `appproject.yaml`에 잔여 URL이 없음이 CI로 보증된다

---

## P8. 입력 계약 확장

`task-validate-input.tpl`의 `repo-url` 정규식 `https://github.com/*/*.git`이
GitLab·사설 Git·private repository를 막는다. workspace의 `smurf-child`는 GitLab CI를 쓰므로
**이미 계약 밖**이다.

단계적으로 간다.

1. **allowlist를 values화** — `ci.source.allowedHostPatterns`를 `tower-k8s/patches/tekton-ci`
   에서 설정. 정규식을 template에서 빼낸다.
2. **private repo 지원** — `task-clone-exact-sha.tpl`에 선택적 credential workspace 추가.
   자격증명은 Secret 이름으로만 참조하고 Git에 넣지 않는다.
3. **monorepo 하위 경로 child** — `chart-path`는 이미 상대경로를 받으므로,
   `context`/`dockerfile`에 동일 규칙을 적용하면 대체로 동작한다.

크기가 크고 보안 경계를 넓히므로 **P1~P7이 끝난 뒤** 착수한다.

---

## P9. 계약 문서 소유권 이전

현재 child 계약 문서가 `temp-poc/docs/` 안에 있다. 계약의 소유자는 Federation이므로
`scalex-federation/docs/`가 정본이어야 한다. 또한 기존 문서가 실재하지 않는 경로
`scalex-federation/bootstrap/appproject.yaml`을 참조하고 있다 (실제는 `argocd/`).

### 조치

- 정본을 `scalex-federation/docs/`에 둔다 (이 문서 세트가 그 시작이다)
- `temp-poc/docs/*.md`는 Federation 문서를 링크하는 stub으로 축소 — **P9 승인 후 수행**
- `scalex-federation/docs/`의 삭제된 문서 5개(`HOWTORUN.md`, `ci-promotion.md`,
  `common-contract.md`, `structure-variant.md`, `tekton-federation-promotion-plan.md`)를
  복원할지 결정한다. 내용 상당 부분이 runbook에 통합되었으므로 **`common-contract.md`
  (소유권 표)와 `tekton-federation-promotion-plan.md`(구현 계획)만 복원**을 권한다

---

## 단계별 실행 순서

```text
Step 1  P1 스키마 확정 + P9 문서 정본화
        └ 산출물: child-spec.md, childspec.v1.json, sample-poc/scalex.yaml
        └ 게이트: temp-poc와 sample-poc가 손실 없이 표현된다

Step 2  P2 루프 chart scaffold + P3 계약 검증
        └ 산출물: sample-poc/chart/templates/*, federation/scripts/validate-render.sh
        └ 게이트: 컴포넌트 추가/삭제가 values 블록 1개로 끝난다

Step 3  P4 build-targets 파생 + P5 topology 이관 + P6 빌드 경로 단일화
        └ 산출물: task-derive-build-targets.tpl
        └ 게이트: PipelineRun에 JSON을 손으로 쓰지 않는다

Step 4  P7 sourceRepos 생성화 + offboard 스크립트
        └ 게이트: 등록/해제가 각각 1회 디렉터리 조작

Step 5  P4-b 트리거 계층, P8 입력 계약 확장
        └ 게이트: child push만으로 promotion PR이 생성된다
```

Step 1~2는 **기존 배포에 전혀 영향을 주지 않는다** (신규 파일만 추가). Step 3부터
`eecs-k8s`의 pipeline template을 건드리므로 회귀 테스트가 필요하다.

---

## 유지해야 할 것 (비목표)

이번 고도화에서 **바꾸지 않는다**. 지금 잘 작동하고 있는 안전장치들이다.

- Federation `main` 직접 push 금지 — 승인 경계는 사람의 PR merge로 유지
- `source-revision`은 40자 SHA만 허용 — branch/tag 배포 금지
- image는 digest로 배포 — `latest` 해석 금지
- promotion Task의 diff allowlist (`releases/<child>/` 밖 변경 abort)
- stale build 차단 (candidate가 이전 promoted revision의 자손이어야 함)
- child가 `Namespace`/`Secret`/cluster-scoped resource를 만들지 않는다는 경계
- Argo direct 경로와 Karmada 경로의 단일 writer 원칙
- Secret 원문을 Git에 저장하지 않는다

---

## 검증 명령

```bash
# Federation 계약
cd scalex-federation && python3 tests/test_promotion_contract.py

# Tekton chart
cd eecs-k8s
helm lint apps/tekton-ci -f apps/tekton-ci/values.yaml \
  -f ../tower-k8s/patches/tekton-ci/values.yaml
./tests/tekton-ci-regression.sh

# App-of-Apps 렌더
helm template smartx eecs-k8s -f tower-k8s/values.yaml >/dev/null
```
