# sample-poc 멀티클러스터 메트릭 시나리오 — 설계 스펙

> 대상 리포: `dev/sample-poc`(child) · `dev/scalex-federation`(배선·시나리오)
> 목적: 기존 sample-poc "identity beacon"(단일 멤버 배치 확인)을 **두 멤버 클러스터가
> 앱 레벨에서 실제 데이터를 주고받는 파이프라인**으로 진화시켜, Karmada 배포 + CI/GitOps를
> 하나의 서사 안에서 증명한다.
> 상태: 설계 승인됨(2026-07-24). 구현 미착수.

참조(AGENTS.md 계약): 아래 사실은 `eecs-k8s/`·`smartx-k8s(=b-k8s/c-k8s)`·`tower-k8s/`를
직접 확인해 인용했다. 인용 경로는 각 절에 표기한다.

---

## 1. 배경과 현재 한계

현재 `sample-poc`는 pod/node 정체를 되돌려주는 stdlib HTTP beacon 1개다.

- 이미지 1개(`app`), feature 폴더 1개(`scalex-return-feature`), Deployment+Service 각 1개
  (`sample-poc/chart/templates/scalex-return-feature/`).
- `PropagationPolicy`가 `clusterNames:[c]` + `spreadConstraints minGroups/maxGroups:1`로
  **단일 멤버 배치**만 확인한다(`.../policy/propagation/scalex-return-feature.yaml`).
- `templates/policy/overrides/`는 `.gitkeep`만 있는 빈 폴더 — OverridePolicy 미사용.
- `releases/scalex-sample-poc/runtime-values.yaml`은 `{}` — placement가 child 기본값에 박혀
  있고, "endpoint는 runtime-values가 주입한다"는 설계 정본(`releases/README.md`)이 아직
  실체화되지 않았다.

즉 "멀티클러스터"라기보다 단일 멤버 배치 확인이다. 이 스펙은 그 한계를 넘어선다.

## 2. 플랫폼이 실제로 제공하는 것 (검증된 사실)

| 사실 | 인용 경로 |
|---|---|
| 멤버 2개 `b`·`c`가 `scalex.io/site`·`scalex.io/role: child`·`scalex.io/topology` 라벨로 join | `tower-k8s/patches/karmada-members/values.yaml` (members b,c) |
| Karmada v1.18.1, `installMode: host`, featureGate `PropagateDeps: true` | `tower-k8s/patches/karmada/values.yaml`, `eecs-k8s/apps/karmada/values.yaml` |
| **b = 데이터 사이트**: Ceph RGW S3가 `10.33.142.10`에 고정, Cilium LB 풀 `10.33.142.0/24` | `b-k8s/patches/rook-ceph-rgw/values.yaml`, `b-k8s/patches/cilium-lb-ipam/values.yaml` |
| **c = 연산 사이트**: `nvidia.com/gpu`·`isaac-saas`·`nucleus`, Cilium LB 풀 `10.33.143.0/24` | `c-k8s/values.yaml`, `c-k8s/patches/cilium-lb-ipam/values.yaml` |
| 두 클러스터 모두 `scalex-sample-poc` 네임스페이스를 인프라로 선언(자동 전파 opt-out) | `b-k8s`/`c-k8s` `patches/workload-namespace/values.yaml` |
| AppProject가 `OverridePolicy`·`ConfigMap`·`Service`·`Deployment`·`PVC` 등을 이미 허용 | `scalex-federation/argocd/appproject.yaml` (T6 확장) |

**없는 것(경계)**: karmada-scheduler-estimator(→ `dynamicWeight: AvailableReplicas` 불가),
descheduler, karmada-search, submariner 등 클러스터 간 오버레이 네트워킹. 앱 레벨 통신은
**같은 L2 위 Cilium LoadBalancer IP 직접 호출**에 의존한다(§8 가정·대안 참조).

의도적으로 닫힌 경계: `Secret`은 child가 소유하지 않는다(`appproject.yaml` 주석). 이 설계는
**Secret을 0개** 사용해 경계를 건드리지 않는다.

## 3. 시나리오 개요

c(연산 사이트)에서 노드 메트릭을 수집·분석하고, b(데이터 사이트)에 저장·표시한다.
실제 클러스터 성격(c=GPU/연산, b=Ceph/스토리지)에 그대로 대응한다.

```
① metrics-collector — /proc에서 노드 cpu·memory 샘플 생성
        │  POST /samples   (c → b, 크로스클러스터)
        ▼
② ring-store (b) — (site,category)별 최근 50개만 유지. 51번째 = 가장 오래된 것 제거
        │  GET /samples    (c → b)
        ▼
③ stats-analyzer (c) — (site,category)별 max/avg/min 계산
        │  POST /summary   (c → b)
        ▼
④ ring-store (b) — 버퍼 + 최신 summary를 HTML로 표시  ("b에서 또 그 값을 보여준다")
```

collector는 **b·c 양쪽**에 확산되어 각 사이트의 노드 메트릭을 수집한다. 따라서 store 버퍼는
`(b,cpu) (b,mem) (c,cpu) (c,mem)` 4개, analyzer는 site×category별로 통계를 낸다.

## 4. 컴포넌트 계약 (이미지 3개, 전부 stdlib Python)

| 이미지 | 배치 | 역할 | HTTP 엔드포인트 |
|---|---|---|---|
| `metrics-collector` | **b + c** (spread) | `COLLECT_INTERVAL`초마다 `/proc/stat`·`/proc/meminfo` 읽어 `{site, category, value, ts}` 샘플을 store에 POST | 없음(아웃바운드만) + `/healthz`(로컬 프로브용 self-serve) |
| `stats-analyzer` | **c** | `ANALYZE_INTERVAL`초마다 store에서 최근 50개 GET → (site,category)별 max/avg/min 계산 → store에 summary POST | 없음(아웃바운드만) + `/healthz` |
| `ring-store` | **b** | 인메모리 `deque(maxlen=50)`를 (site,category)별 유지. 샘플 수신/조회 + summary 저장 + HTML 표시 | `POST /samples` · `GET /samples` · `POST /summary` · `GET /summary` · `GET /`(HTML) · `GET /healthz` |

공통 규칙:

- **stdlib 전용**: `http.server`/`urllib`만. 기존 beacon과 동일한 보안 컨텍스트
  (`runAsNonRoot`, `runAsUser: 65532`, `readOnlyRootFilesystem: true`, `drop: [ALL]`,
  `automountServiceAccountToken: false`)를 3개 워크로드 모두 유지한다.
- **노드 메트릭의 정직성**: LXCFS가 없는 일반 컨테이너에서 `/proc/meminfo`·`/proc/stat`은
  **호스트(=노드) 값**을 보여준다. 따라서 host 마운트·privileged 없이 노드 메트릭을 읽는다.
  샘플에는 downward API `NODE_NAME`도 함께 실어 어느 노드인지 표기한다.
- **cpu 산출**: `/proc/stat`의 `cpu` 라인 두 스냅샷 차분으로 busy%를 계산(간단한 근사).
  memory: `/proc/meminfo`의 `MemTotal`·`MemAvailable`로 used% 계산.
- **category 확장성**: category는 문자열 키일 뿐 — 코드에 category를 하나 추가하면
  store·analyzer·표시가 자동으로 새 키를 다룬다(§7 5막 GitOps 왕복의 근거).

### 4.1 링 버퍼 규칙 (사용자 요구)

- store는 `dict[(site,category)] -> deque(maxlen=50)`를 유지한다.
- `POST /samples`가 51번째를 넣으면 가장 오래된 샘플이 자동으로 밀려 사라진다(`deque(maxlen)`).
- 각 샘플은 `ts`(수신 시각)를 보관 → 표시 화면이 "마지막 수신 N초 전"을 계산(장애 드릴 관찰점).
- **인메모리**다. store 파드 재시작 시 버퍼는 리셋된다(POC로 수용, 장애 드릴 볼거리). PVC로의
  영속화는 범위 밖(AppProject는 PVC를 허용하므로 후속 확장 가능).

### 4.2 엔드포인트/사이트 주입 (앱에 하드코딩 금지)

- collector·analyzer의 `STORE_URL`은 federation `runtime-values.yaml`이 `http://10.33.142.20`
  (b의 Cilium LB IP)로 주입한다. store만 LoadBalancer가 필요하다.
- collector 파드는 자신이 어느 멤버에 있는지 downward API로 알 수 없다. 그래서
  **OverridePolicy가 클러스터별로 `SITE_NAME` env를 주입**한다(b→`b`, c→`c`). 이것이 여태
  비어 있던 `templates/policy/overrides/`의 첫 사용처다.
- **수집 주기는 두 사이트 동일**하다(`COLLECT_INTERVAL`을 base values에 공통으로 둔다).
  OverridePolicy는 오직 `SITE_NAME` 주입만 담당한다.
- collector가 b 파드에서 b 자신의 LB IP(`10.33.142.20`)로 hairpin 접속하는 것과 c 파드에서
  같은 IP로 접속하는 것 모두 동일 env로 동작한다(단일 Deployment spec).

## 5. Karmada 정책 (templates/policy/)

| 정책 | kind | placement / override |
|---|---|---|
| `metrics-collector` | PropagationPolicy | resourceSelector: Deployment. `clusterAffinity.labelSelector: scalex.io/role=child` + `spreadConstraints spreadByField: cluster, minGroups: 2, maxGroups: 2` → **b·c 동시** |
| `stats-analyzer` | PropagationPolicy | resourceSelector: Deployment. `clusterAffinity.clusterNames`(runtime-values 주입, 기본 `[c]`) |
| `ring-store` | PropagationPolicy | resourceSelector: Deployment + Service. `clusterAffinity.clusterNames`(기본 `[b]`) |
| `metrics-collector` | **OverridePolicy** | targetCluster `b` → env append `SITE_NAME=b`; targetCluster `c` → env append `SITE_NAME=c` |

세부:

- OverridePolicy env 주입은 Karmada `plaintext` overrider의 JSONPatch
  `op: add, path: /spec/template/spec/containers/0/env/-`(인덱스 없는 append)를 쓴다.
  컨테이너가 단일이라 index `0`은 안정적이며, `env/-`는 기존 env 배열 인덱스에 의존하지 않는다.
- store는 b에만 배치되므로 `Service.type: LoadBalancer`와 `lbipam.cilium.io/ips` 주석을
  **base 템플릿/values에 직접** 둔다(override 불필요). LB IP 값만 runtime-values로 주입 가능.
- AppProject는 `PropagationPolicy`·`OverridePolicy`·`Service`·`Deployment`를 모두 이미 허용
  → 화이트리스트 변경 불필요. `sourceRepos`에 sample-poc는 이미 등록됨.

## 6. 리포/차트 레이아웃

sample-poc chart `version`/`appVersion`을 `0.1.0` → `0.2.0`으로 올린다. `helm create` 후
적응하는 기존 규칙(온보딩 런북 S1)을 그대로 따른다: workload는 `templates/<기능명>/`, 정책은
`templates/policy/{propagation,overrides}/`.

```
sample-poc/
├── manifests/                              # 사람이 쓰는 순수 k8s YAML(진실의 원천)
│   ├── collector-deployment.yaml
│   ├── analyzer-deployment.yaml
│   ├── store-deployment.yaml
│   └── store-service.yaml
├── src/{collector,analyzer,store}.py       # 3개 앱(stdlib)
├── images/
│   ├── metrics-collector/Dockerfile        # COPY src/collector.py
│   ├── stats-analyzer/Dockerfile           # COPY src/analyzer.py
│   └── ring-store/Dockerfile               # COPY src/store.py
└── chart/
    ├── Chart.yaml (version 0.2.0, appVersion "0.2.0")
    ├── values.yaml (images 3개 · app 설정 · store.service LB · karmada.placement)
    ├── values.schema.json                  # 변경 불필요(§9)
    └── templates/
        ├── _helpers.tpl                    # sample-poc.image helper 재사용
        ├── metrics-collector/deployment.yaml
        ├── stats-analyzer/deployment.yaml
        ├── ring-store/{deployment.yaml,service.yaml}
        └── policy/
            ├── propagation/{metrics-collector,stats-analyzer,ring-store}.yaml
            └── overrides/metrics-collector.yaml   # ← 처음으로 채워짐(.gitkeep 대체)
```

> 기존 `scalex-return-feature/` 폴더와 그 propagation 정책은 제거하고 위 3개 기능 폴더로
> 대체한다(기능이 근본적으로 달라졌으므로). `images/app/`도 3개 이미지로 대체.

### 6.1 values.yaml 형태(요지)

```yaml
images:
  metrics-collector: { repository: 10.34.25.18/tower-ci/sample-poc/metrics-collector, tag: v0.2.0, pullPolicy: IfNotPresent }
  stats-analyzer:    { repository: 10.34.25.18/tower-ci/sample-poc/stats-analyzer,    tag: v0.2.0, pullPolicy: IfNotPresent }
  ring-store:        { repository: 10.34.25.18/tower-ci/sample-poc/ring-store,        tag: v0.2.0, pullPolicy: IfNotPresent }

collector: { intervalSeconds: 5, bufferSize: 50 }   # 두 사이트 공통 주기
analyzer:  { intervalSeconds: 10 }
store:
  service: { type: LoadBalancer, loadBalancerIP: 10.33.142.20, port: 80, targetPort: 8080 }

karmada:
  enabled: true
  placement:
    analyzer: { clusterNames: [c] }
    store:    { clusterNames: [b] }
    # collector는 labelSelector+spread라 clusterNames 불필요
```

## 7. Federation 배선 (`releases/scalex-sample-poc/`)

- `release.yaml`: `state: active` 유지, `promotion.mode: tracking`(현행 유지).
- `values.yaml`: promote(T10)가 image **3개**의 repository/tag/digest/sourceRevision을 채운다
  (사람 미편집).
- `runtime-values.yaml`(`{}` → 실체화):

```yaml
store:
  service:
    loadBalancerIP: 10.33.142.20
karmada:
  placement:
    analyzer: { clusterNames: [c] }
    store:    { clusterNames: [b] }
# STORE_URL은 chart가 store.service.loadBalancerIP에서 구성한다(collector/analyzer env).
```

> `runtime-values.yaml`이 처음으로 의미를 갖는다: placement와 endpoint를 사람이 관리한다는
> `releases/README.md`의 정본이 실체화된다.

## 8. 시나리오 5막 (성공 판정 포함)

관례상 관찰(👀)·판단(🧑‍⚖️) 지점을 표기한다. 명령은 온보딩 런북 S9의 컨텍스트를 재사용한다.

| 막 | 행동 | 성공 기준(👀) |
|---|---|---|
| **1. 배포** | sample-poc v0.2.0 push → child-build PipelineRun 1회 | `derive-targets`가 이미지 **3개** 파생 · `build-push` 3개 push · promote PR에 **digest 3개** · 사람 merge 후 Argo가 `federation-scalex-sample-poc` sync |
| **2. 멀티클러스터 확산** | Karmada 확산 확인 | `kubectl --context c -n scalex-sample-poc get deploy` → collector 1 + analyzer 1 · `kubectl --context b ...` → collector 1 + store 1. **하나의 collector Deployment가 두 클러스터에 존재** |
| **3. 데이터 순환** | b store `GET /`(또는 LB IP) 열기 | 버퍼 4종 `(b,cpu)(b,mem)(c,cpu)(c,mem)` 채워지고 각 길이 ≤ 50 · summary에 site×category별 max/avg/min · **c 샘플이 b 화면에 보임 = 크로스클러스터 왕복 성공** |
| **4. 장애 드릴** | `kubectl --context c -n scalex-sample-poc scale deploy/<collector> --replicas=0` | b 화면에서 `site=c`가 stale("마지막 수신 N초 전" 증가)로 표시 · analyzer의 c 통계 정지 · b(site=b)는 계속 정상 · **`--replicas=1` 복구 시 자동 회복** |
| **5. GitOps 왕복** | collector에 3번째 category(예: `load` = `/proc/loadavg`) 추가 → `chart/values.yaml` tag `v0.2.1` → push → PipelineRun → promote PR merge | Argo가 새 digest로 sync → b 화면에 **`load` 카테고리가 새로 등장**. 코드 한 줄 변경이 CI→promote→GitOps로 두 사이트에 반영됨 |

🧑‍⚖️ 배포 승인 경계는 온보딩 런북 S7과 동일: promote PR을 사람이 merge하는 것이 곧 배포 승인.

## 9. 스키마·계약 영향

- `chart/values.schema.json`: **변경 불필요**. 루트가 `additionalProperties: true`이고 이미지
  키 패턴 `^[a-z0-9]+(-[a-z0-9]+)*$`가 `metrics-collector`·`stats-analyzer`·`ring-store`를
  모두 허용한다(`sample-poc/chart/values.schema.json`, 정본은
  `scalex-federation/docs/child-values-schema.md`).
- 계약 render 검증(온보딩 런북 S2/b): 다음 불변식으로 갱신한다 —
  - 금지 kind 없음(`Namespace`·`Secret`·`ClusterRole`·`Ingress` 등)
  - 모든 리소스 namespace == `scalex-sample-poc`
  - PropagationPolicy가 **3개**, 각 workload와 selector 1:1 대응(dangling 없음)
  - OverridePolicy 1개가 collector Deployment를 대상으로 함
  - `karmada.enabled=false`면 propagation/override가 모두 사라짐(로컬 설치 지원)
- `tests/test_promotion_contract.py`: 이미지 3키·digest 3개를 promote가 채우는 것을 계약으로
  본다(기존 다중 이미지 사례 temp-poc와 동형).

## 10. 가정과 대안 경로

- **핵심 가정(미검증)**: b LB 풀 `10.33.142.0/24`와 c LB 풀 `10.33.143.0/24`가 같은 L2
  세그먼트라 **c 파드가 `10.33.142.20`에 도달**한다. 배포 직후 1차 검증:
  `kubectl --context c -n scalex-sample-poc exec deploy/<collector> -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://10.33.142.20/healthz', timeout=3).read())"`.
- **대안 A(네트워크 미도달 시)**: store를 b의 기존 Ceph RGW S3(`10.33.142.10`, 이미 존재)
  공유 버스로 대체 — collector가 S3에 put, analyzer/표시가 get. 단 c 네임스페이스에 S3
  credential Secret이 필요하고 Secret은 child 소유가 아니므로 c-k8s 인프라 선행작업이 붙는다
  (경계 밖). 그래서 LB 직접호출을 1순위로 둔다.
- **대안 B(확산 정책 미동작 시)**: `spreadConstraints`가 estimator 부재로 원하는 대로 안 퍼지면
  collector도 `clusterNames:[b,c]` 명시로 폴백(확산은 되지만 "자동 스프레드" 서사는 약화).

## 11. 범위 밖(YAGNI)

- 가중 분산(`staticWeight`/`dynamicWeight`), descheduler, karmada-search 연동.
- 버퍼 영속화(PVC), 인증/Secret, TLS.
- child repo 분리(agent/store를 별도 repo로). 본 스펙은 sample-poc **단일 child** 안에서
  다중 이미지·다중 기능으로 해결한다.

## 12. 작업 순서(개요 — 상세는 구현 계획에서)

1. `src/{collector,analyzer,store}.py` 작성 + 로컬 단위 검증(순수 python 실행).
2. `manifests/*` 순수 YAML 작성 → `helm create` 골격 적응 → 3 기능 폴더 + 정책 3+1.
3. 로컬 검증: `helm lint --strict`, `helm template` 후 계약 불변식(§9), `karmada.enabled=false`
   토글 0, `docker build` 3개 + 컨테이너 구동 스모크.
4. sample-poc commit/push → child SHA 기록.
5. Federation `runtime-values.yaml` 실체화 PR(§7).
6. child-build PipelineRun 1회 → promote PR(digest 3개) → 검토 merge.
7. `state: active`는 이미 active이므로 유지. Argo sync 후 §8 5막 실행.
