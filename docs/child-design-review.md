# Child 구조 검토와 고도화 방향

목적: child repository를 **쉽게 만들고 쉽게 지울 수 있는가**를 기준으로 현재 구조를
검토한다. 대상은 `eecs-k8s → tower-k8s → scalex-federation ← temp-poc(child)` 경로 전체다.

결론을 먼저 적는다.

> **Tekton build 계층은 이미 child-agnostic이다. 굳어 있는 것은 child repository 자체와,
> child의 사실을 사람이 손으로 옮겨 적는 3개의 경계(PipelineRun `build-targets`,
> Federation `release` 3파일, `appproject.yaml` whitelist)다.**

즉 "temp-poc 전용 구조"라는 체감의 원인은 플랫폼이 아니라 **child 명세가 존재하지 않기
때문**이다. child가 가진 사실(이미지 몇 개, 컴포넌트 몇 개, 어디에 놓을 것인가)이
기계가 읽을 수 있는 한 곳에 선언되어 있지 않고, Dockerfile 배치 · Helm template 파일명 ·
values 키 이름 · PipelineRun JSON · Federation values에 **다섯 번 중복 표현**된다.

---

## 1. 굳어 있지 **않은** 것부터 (오해 방지)

검토 결과 아래는 이미 일반화되어 있다. 여기를 고치려 들면 낭비다.

| 계층 | 상태 |
|---|---|
| `eecs-k8s/apps/tekton-ci/templates/*.tpl` | child 이름·이미지 이름이 전혀 없다. 5개 param(`child-name`, `repo-url`, `source-revision`, `chart-path`, `build-targets`)으로 완전 파라미터화 |
| `tower-k8s/patches/tekton-ci/values.yaml` | registry/promotion 설정만. `temp-poc` 문자열 없음 |
| image 경로 공식 | `${host}/${prefix}/${child-name}/${image}` — child 수에 무관 |
| `argocd/applicationset.yaml` | `releases/*/release.yaml` glob. release 추가는 파일 추가로 끝 |
| `temp-poc/scripts/build-images.sh` | `chart/values.yaml`의 `images` map을 정렬 순회. 컴포넌트 수에 무관하게 동작 |

`temp-poc`라는 문자열이 `eecs-k8s`/`tower-k8s`에 등장하는 곳은 예시 template 1개
(`eecs-k8s/examples/tekton-ci/federation-promotion-pipelinerun.yaml.tpl`)뿐이다.

---

## 2. 굳어 있는 것 — 발견 사항

### F1. child의 컴포넌트 목록이 "파일 배치"로만 표현된다 (핵심)

`temp-poc`에서 컴포넌트 하나를 추가하려면 다음을 **전부** 손으로 만들어야 한다.

```text
images/<name>/Dockerfile
chart/templates/<name>/deployment.yaml
chart/templates/<name>/service.yaml
chart/templates/policy/propagation/<name>.yaml
chart/templates/policy/overrides/services.yaml   ← 여기에 블록 추가
chart/values.yaml  : images.<kebab-name>          ← kebab-case
chart/values.yaml  : <camelName>.replicas/...     ← camelCase (키 규칙이 다름!)
chart/values.yaml  : karmada.placements.<camelName>
chart/values.schema.json
scripts/validate-render.sh 의 expected 목록
PipelineRun의 build-targets JSON
```

11곳이다. 삭제할 때도 11곳이다. **이것이 "temp-poc 전용으로 굳어 있다"는 체감의 실체다.**

특히 `images` map은 `dataset-ingest`(kebab)인데 workload values는
`datasetIngest`(camel)로 서로 다른 표기를 쓴다. 두 표기를 잇는 규칙이 코드가 아니라
사람 머릿속에 있다.

### F2. `build-targets`가 사람이 손으로 쓰는 JSON 한 줄이다

`netai/temp-poc-dataset-ingest-pipelinerun.yaml`:

```yaml
- name: build-targets
  value: >-
    [{"name":"dataset-ingest","valuesKey":"dataset-ingest","context":".","dockerfile":"images/dataset-ingest/Dockerfile"},
     {"name":"batch-analyzer",...},{"name":"report-generator",...}]
```

이 JSON이 담은 정보는 **전부 child repository 안에 이미 존재하는 사실**이다
(`images/*/Dockerfile` 배치 + `chart/values.yaml`의 `images` 키). 그런데 child가 아니라
**PipelineRun 제출자가 다시 타이핑한다.** `valuesKey`가 `name`과 같아야 한다는 제약이
Task에 하드코딩되어 있는 것 자체가, 이 필드가 원래 불필요하다는 신호다.

`temp-poc/scripts/discover-images.sh`가 정확히 이 발견 로직을 이미 구현해 두었지만
**어디에서도 호출되지 않는다.** 발견 능력은 있는데 파이프라인에 연결되어 있지 않다.

### F3. 검증 스크립트가 리터럴 assert다

`temp-poc/scripts/validate-render.sh`:

```ruby
expected = {
  "CronJob" => ["temp-poc-batch-analyzer"],
  "Deployment" => ["temp-poc-dataset-ingest", "temp-poc-report-generator"],
  ...
}
abort "dataset placement mismatch" unless placements["temp-poc-dataset-ingest"] == ["b"]
abort "dataset address mismatch" unless addresses["temp-poc-dataset-ingest"] == "10.33.142.20"
```

이 파일을 복사한 새 child는 **반드시 깨진다.** 이름·클러스터·LB IP가 전부 리터럴이다.
검증해야 할 것은 "이름이 temp-poc-dataset-ingest인가"가 아니라 **"모든 workload가 정확히
하나의 PropagationPolicy에 선택되는가"** 같은 계약 불변식이다.

### F4. cluster topology가 child chart 기본값에 박혀 있다

`temp-poc/chart/values.yaml`:

```yaml
batchAnalyzer:
  datasetUrl: http://10.33.142.20/dataset.csv     # 클러스터 LB IP
  reportUrl:  http://10.33.142.21/result
karmada:
  placements:
    datasetIngest: { cluster: b, loadBalancerIP: 10.33.142.20 }
    batchAnalyzer: { cluster: c }
    reportGenerator:{ cluster: b, loadBalancerIP: 10.33.142.21 }
```

member cluster 이름(`b`, `c`)과 Cilium LB IP는 **Federation/Infra의 사실**이지 child의
사실이 아니다. 소유권 계약상 이것들은 `releases/<id>/runtime-values.yaml`에 있어야 하는데,
현재 `releases/temp-poc/runtime-values.yaml`은 `{}`다. 즉 **runtime/child 경계가 문서에만
있고 실물에는 없다.**

결과: child를 복제하면 남의 클러스터 IP를 그대로 들고 시작한다.

### F5. 빌드 경로가 두 개다

| 경로 | 트리거 | 태그 규칙 | 결과물 |
|---|---|---|---|
| `temp-poc/.github/workflows/promote.yaml` | `push: main` (자동) | `chart/values.yaml`의 `tag` 그대로 | GH artifact (`generated-values.yaml`) — **Federation에 도달하지 않음** |
| Tekton `child-build` | 사람이 PipelineRun 제출 | `sha-<40hex>` push 후 semver alias | promotion payload → Federation PR |

같은 계약(image digest 산출)을 두 구현이 소유하고, 태그 규칙마저 다르다. GitHub Actions
경로는 ORAS publish 단계가 주석 처리되어 **끝이 막혀 있다**. 새 사용자는 어느 쪽이
정식 경로인지 알 수 없다.

또한 GH Actions는 `runs-on: [self-hosted, linux, x64, work8]` — 특정 머신에 묶여 있어
새 child가 복사해도 동작하지 않는다.

### F6. child 하나 등록에 공유 파일 3곳을 건드린다

- `argocd/appproject.yaml` `sourceRepos` — 화이트리스트, 와일드카드 없음 (현재 12개)
- `argocd/appproject.yaml` `namespaceResourceWhitelist` — 폐쇄된 14 kind. `Ingress`,
  `Secret`, `PVC`, `NetworkPolicy` 없음
- `releases/<id>/` 3파일

앞의 두 개는 **모든 child가 공유하는 단일 파일**이다. child가 늘어날수록 merge hotspot이
되고, child를 지울 때 정리를 빠뜨리기 쉽다 (dangling sourceRepo는 조용히 남는다).

### F7. 부트스트랩 순환

`task-federation-promote.tpl`은 두 가지를 **선행 조건**으로 요구한다.

```sh
[ -f "$release_file" ] || { printf 'release not enrolled: %s\n' "$child"; exit 1; }
[ -f "$runtime" ] && [ -f "$generated" ] || { printf 'promotion values missing\n'; exit 1; }
```

즉 **CI가 만들어야 할 `values.yaml`을, CI가 돌기 전에 사람이 seed로 만들어 두어야 한다.**
첫 등록 때 존재하지 않는 digest를 임시로 채워 넣는 어색한 단계가 발생한다
(기존 문서는 `registry.k8s.io/pause`의 digest를 쓰라고 안내한다).

### F8. 트리거 계층이 없다

`EventListener`/`TriggerTemplate`/`triggers.tekton.dev`가 두 repo 전체에 **0개**다.
`tower-k8s/README.md`가 이를 명시한다("PipelineRuns are submitted from inside the Tower
control plane"). 따라서 "child가 push하면 자동으로 빌드된다"는 목표는 현재 **미구현**이며,
사람이 매번 PipelineRun YAML을 작성한다.

### F9. 입력 계약이 좁다

`task-validate-input.tpl`의 `repo-url` 정규식은 `https://github.com/*/*.git`이다.

- GitLab / 사설 Git 불가 — workspace의 `smurf-child`는 `.gitlab-ci.yml`을 쓰므로 이미 계약 밖
- private repository 불가 (`clone` Task에 credential 경로 없음)
- monorepo 안의 하위 디렉터리 child 불가

### F10. 인프라 자원이 전역 단일이다

| 자원 | 값 | child 증가 시 |
|---|---|---|
| Harbor project | `tower-ci` 하나 | 경로 prefix로만 분리. 권한 격리 없음 |
| workspace PVC | `source-workspace` RWX 10Gi 단일 | 동시 PipelineRun이 한 볼륨 공유 |
| ResourceQuota | ns `tower-ci` 전체 `pods:20 / cpu:4` | 전역 경합 |
| promotion 대상 | Federation repo 1개 | Tower당 1 Federation |

child를 지워도 Harbor repository는 Git 어디에도 흔적이 없어 **수동 삭제**해야 한다.

### F11. 문서 표류

- `temp-poc/docs/*.md`가 `scalex-federation/bootstrap/appproject.yaml`을 참조하지만 실제
  경로는 `argocd/appproject.yaml`이다. `bootstrap/` 디렉터리는 존재하지 않는다.
- `scalex-federation/docs/`의 기존 문서 5개가 uncommitted 상태로 삭제되어 있다.
- child 계약 문서가 **child repository(temp-poc) 안에** 있다. 계약의 소유자는 Federation인데
  참조 구현이 문서를 들고 있어, temp-poc를 지우면 계약도 사라진다.

### F12. 네이밍 계약 위반이 이미 존재한다

계약: "디렉터리명 = `release.yaml`의 `name` = namespace".
실제 `temp-poc`: name `temp-poc`, namespace `scalex-temp-poc`. 기준 구현이 규칙을 깨고 있어
새 사용자가 어느 쪽을 따라야 할지 모호하다.

---

## 3. 고도화 방향

### D1. child 명세를 단일 YAML 한 파일로 수렴시킨다 (가장 큰 레버)

child가 아는 사실을 repository root의 선언 파일 하나에 모은다. 이 아이디어의 선례는
이미 workspace에 있다 — `smurf-child/features.yaml`:

```yaml
apiVersion: scalex.io/features/v1
kind: FeatureRegistry
features:
  - name: rgw-analysis-web
    renderer: helm/v1
    images:
      flow: { context: images/rgw-analysis-web/flow, repository: ghcr.io/... }
    chart: charts/rgw-analysis-web
```

이 방향을 child 계약으로 승격시키면 F1·F2·F3·F7이 동시에 해소된다.

```yaml
# my-child/scalex.yaml
apiVersion: scalex.io/v1
kind: ChildSpec
metadata:
  name: scalex-my-child          # release ID = namespace
spec:
  chart:
    path: chart                  # 생성된 chart 위치 (또는 공용 chart 사용)
  images:
    - name: api
      context: .
      dockerfile: images/api/Dockerfile
      tag: v0.2.0
  components:
    - name: api
      kind: Deployment
      image: api
      replicas: 1
      port: 8080
      service: { port: 80 }
      expose: internal
      probe: { path: /healthz }
    - name: nightly
      kind: CronJob
      image: api
      schedule: "*/30 * * * *"
      args: ["analyze"]
```

여기에 **없는 것**이 중요하다: cluster 이름, LB IP, registry host, namespace prefix.
전부 Federation/Infra의 사실이므로 `runtime-values.yaml`이 채운다 (F4 해소).

효과:
- 컴포넌트 추가 = 블록 1개 추가. 삭제 = 블록 1개 삭제. **11곳 → 1곳.**
- `build-targets`는 `scalex.yaml`에서 파생 — 사람이 JSON을 쓰지 않는다.
- `release.yaml`의 초기값도 `scalex.yaml`에서 파생 가능 → F7 완화.

### D2. workload 렌더링을 컴포넌트 루프로 일반화한다

`chart/templates/<name>/deployment.yaml`을 컴포넌트마다 만드는 대신, `range`로 돈다.

```gotemplate
{{- range $c := .Values.components }}
---
apiVersion: apps/v1
kind: {{ $c.kind }}
metadata:
  name: {{ include "child.fullname" $ }}-{{ $c.name }}
...
{{- end }}
```

policy도 마찬가지로 컴포넌트당 1개를 자동 생성한다. 이렇게 하면
`PropagationPolicy` 누락(계약 위반 1순위)이 **구조적으로 불가능**해진다.

두 가지 배치안이 있다.

| 안 | 내용 | 장점 | 단점 |
|---|---|---|---|
| (a) child가 generic chart를 보유 | scaffold가 루프 template을 복사해 준다 | Federation 계약 변경 없음. child 독립 렌더 유지 | template 버그 수정이 child마다 전파 필요 |
| (b) 공용 library chart 의존 | `Chart.yaml`의 `dependencies`로 참조 | 수정이 중앙에서 전파 | chart repository 호스팅 필요. child 독립성 약화 |

**(a)를 먼저 하고, 안정화 후 (b)를 검토**하는 것을 권한다. 지금 단계에서 chart repository
운영 부담을 추가하는 것은 이르다.

### D3. 검증을 리터럴 → 계약 불변식으로 바꾼다

`validate-render.sh`가 assert해야 할 것:

- 모든 workload(Deployment/StatefulSet/DaemonSet/CronJob)가 **정확히 하나의**
  `PropagationPolicy`에 선택된다
- 모든 policy selector가 **실제로 렌더된** resource를 가리킨다 (dangling selector 없음)
- 모든 container image가 `@sha256:` digest를 갖는다
- 모든 namespaced resource가 `.Release.Namespace`를 쓴다
- 금지 kind(`Namespace`/`Secret`/`Cluster*`)가 0개다
- `karmada.enabled=false`면 policy가 0개다

이 6개는 **child 이름과 무관**하므로 복사해도 깨지지 않는다. 나아가 이 스크립트는
child가 아니라 **Federation이 소유**하고 child가 참조하는 편이 옳다.

### D4. 빌드 경로를 하나로 정리한다

Tekton `child-build`를 유일한 정식 경로로 선언하고, child의 GitHub Actions는
**PR 검증(lint/template/test)만** 담당하게 축소한다. push→build 자동화는 F8의
트리거 계층으로 해결한다. 두 경로가 같은 registry에 서로 다른 태그 규칙으로 push하는
현 상태는 digest 추적을 망가뜨릴 수 있다.

### D5. 등록/해제를 데이터 주도로 만든다

`appproject.yaml`의 `sourceRepos`를 손으로 관리하는 대신, `releases/*/release.yaml`의
`source.repoURL` 집합에서 **생성**한다. 그러면:

- child 등록 = `releases/<id>/` 디렉터리 추가 **한 번**
- child 해제 = `releases/<id>/` 디렉터리 삭제 **한 번**
- dangling sourceRepo가 구조적으로 불가능

`namespaceResourceWhitelist`도 마찬가지로 "release가 선언한 kind의 합집합"으로 넓힐 수
있으나, 이쪽은 보안 경계이므로 **명시적 승인을 유지**하는 편이 낫다 — 대신 어떤 kind가
왜 필요한지를 `release.yaml`에 선언시켜 리뷰 대상으로 만든다.

### D6. child 수명주기를 스캐폴드/철거 도구로 감싼다

"쉽게 만들고 삭제"의 마지막 조각은 **명령 2개**다.

```bash
scalex child new my-child           # scalex.yaml + chart 루프 template + validate.sh 생성
scalex child enroll my-child        # releases/<id>/ 3파일 생성 PR
scalex child offboard my-child      # disabled → 디렉터리 삭제 → Harbor 정리 체크리스트
```

현재 offboarding은 7단계 수동 절차(runbook A-11)이며 그중 Harbor 정리는 Git 바깥이다.
최소한 **체크리스트를 스크립트화**하는 것만으로도 잔여물 사고를 크게 줄인다.

### D7. 격리 축을 child 단위로 옮긴다 (중장기)

child 수가 늘면 F10이 실제 장애가 된다.

- Harbor: `tower-ci` 단일 project → child별 project + robot 계정
- workspace: 단일 RWX PVC → PipelineRun별 `volumeClaimTemplate` (temp-poc의 수동
  PipelineRun은 이미 이렇게 하고 있다 — 기본값이 뒤처져 있는 것)
- ResourceQuota: ns 전역 → child별 concurrency 제한

---

## 4. 목표 상태 요약

```text
[지금]
child repo ──(사람이 JSON 작성)──> PipelineRun ──> Harbor
                                                    │
사람이 3파일 seed ──> Federation ──(사람이 PR seed)──┘

[목표]
child repo (scalex.yaml 1개) ──push──> trigger ──> child-build
       │                                              │ payload
       └─ 명세에서 파생: build-targets, chart, release seed
                                                      ▼
                                    federation-promote ──PR──> 사람이 merge
```

사람이 판단해야 하는 지점은 **단 하나, promotion PR merge**로 남긴다. 나머지 전사(轉寫)는
전부 명세에서 파생시킨다.

구체적 실행 순서와 변경 대상 파일은
[`child-design-recommendations.md`](child-design-recommendations.md)에 있다.
