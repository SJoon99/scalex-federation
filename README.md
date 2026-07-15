# scalex-federation

ScaleX의 단일·멀티클러스터 User/Dev Layer 배포 상태를 관리하는 GitOps release repository다.

Tower Argo CD가 이 repository를 읽어 Karmada control plane에 원하는 상태를 동기화하고, Karmada가 선택된 member cluster에 workload를 배포한다.

## 책임

- 배포할 feature/workload의 chart 및 image revision 고정
- runtime values와 namespace 선언
- Karmada propagation/override policy 관리
- 배포 승격과 rollback을 Git history로 관리
- Infra Layer와 User/Dev Layer 사이의 ownership contract 유지

## 책임지지 않는 것

- 기능 source code와 container build
- CNI, CSI, Ceph 등 cluster Infra 구성
- Karmada control plane 설치와 member join
- child cluster 직접 배포
- 평문 credential 보관

## 기본 흐름

```text
feature repository artifact
        ↓ promotion
scalex-federation desired state
        ↓ GitOps sync
Tower Argo CD
        ↓
Tower Karmada control plane
        ↓ Push
member clusters
```

## 디렉터리

| 경로 | 역할 |
|---|---|
| [`bootstrap/`](bootstrap/README.md) | Tower Argo가 Federation release를 읽기 위한 진입점 |
| [`releases/`](releases/README.md) | 배포 revision, values, Karmada policy |
| [`contracts/`](contracts/README.md) | naming, label, ownership, secret 계약 |
| [`tests/`](tests/README.md) | render 및 정책 정합성 검증 |
| [`scripts/`](scripts/README.md) | 반복 가능한 로컬·CI 검증 도구 |
| [`docs/common-contract.md`](docs/common-contract.md) | Infra·feature·Federation 공통 소유권 계약 |
| [`docs/HOWTORUN.md`](docs/HOWTORUN.md) | child feature 연결 절차 |

## Release discovery

```text
releases/<environment>/<release>/release.yaml
                   │
                   ▼
bootstrap/ApplicationSet
                   │ Argo Application 생성
                   ▼
feature Helm chart + Federation values + Karmada policies
                   │
                   ▼
Tower Karmada API → member clusters
```

실제 image/chart blob은 Registry에 저장한다. 이 repository에는 immutable
revision, runtime values, placement와 override만 저장한다.

ApplicationSet은 feature chart와 release `values.yaml`을 렌더링하고,
`dependencies/`의 release-scoped 선행 리소스와 `policy/`의 Karmada policy YAML을
재귀적으로 함께 읽는다. 별도 Kustomize entrypoint나 기능별 Application 파일은
사용하지 않는다.

## CI promotion 경계

각 feature repository의 CI가 기능별 build/test/scan을 소유한다. CI 성공 후
다음 두 좌표를 하나의 Federation Pull Request에서 원자적으로 갱신한다.

- `release.yaml`: 검증된 feature chart commit SHA
- `values.yaml`: 해당 build에서 변경된 모든 image의 repository/tag/digest

한 기능이 API, worker, sidecar 등 여러 image를 만들더라도 `images.<component>`
map에 모두 기록한다. CI는 child cluster에 직접 접근하지 않으며 merge된 desired
state만 Tower Argo와 Karmada가 배포한다.

## First POC

`releases/poc/rgw-analysis-web`은 B의 RGW 입력을 C에서 분석하고 결과를 B의
Nginx로 제공하는 첫 vertical slice다. B/C 이름은 Federation policy에만
존재하며 feature chart는 cluster-neutral 상태를 유지한다.

이 release가 사용하는 OBC는 `b-k8s`가 B Infra dependency로 소유한다.
Federation `dependencies/`에는 credential이 아닌 runtime binding 명세만 남기고,
Feature Helm은 workload와 기존 runtime Secret/ConfigMap 이름만 참조한다.

```text
B Infra OBC --> B Rook
                 ├─ Secret credential
                 └─ ConfigMap actual bucket name
                            ↓ common RuntimeBinding runner
               Karmada runtime Secret + ConfigMap
                            ↓ propagateDeps
                          B / C workloads
```

`sync-runtime-bindings.sh`는 `scalex.io/runtime-binding=true` 선언을 모두 발견하고,
각 선언의 `sourceCluster`를 보안 kubeconfig directory의 `<cluster>.kubeconfig`로
해석한다. release·namespace·target 이름도 선언에서 읽으므로 새 feature를 위해
별도 script를 만들지 않는다. 현재 지원 type은 `rook-obc-s3/v1alpha1` 하나이며,
임의 Secret 복사를 허용하지 않는 제한된 공통 adapter다.

현재는 controller 대신 idempotent runner를 명시적으로 실행한다. 지속 reconciliation과
자동 rotation이 필요해질 때 같은 계약을 Tower CronJob 또는 controller로 승격한다.

## 기본 원칙

- Feature source와 build logic은 feature repository가 소유한다.
- Cluster Infra와 OBC 같은 외부 dependency는 `eecs-k8s`와 각 `*-k8s` repository가 소유한다.
- Federation은 non-secret runtime binding과 workload placement만 소유한다.
- Feature Helm은 workload와 기존 runtime binding 참조만 소유한다.
- 새 feature는 Infra dependency를 해당 cluster repo에 요청하고, 필요한 RuntimeBinding만 Federation에 선언한다.
- Federation workload는 Tower Argo가 child cluster에 직접 배포하지 않는다.
- 동일 리소스를 Argo direct 경로와 Karmada가 동시에 관리하지 않는다.
- Revision은 tag, commit 또는 immutable image digest로 고정한다.
- Secret 값은 Git에 저장하지 않고 reference만 선언한다.

## Argo에서 보이는 범위

Federation Application의 destination은 member `b`/`c`가 아니라 `karmada`다.

```text
Argo CD  ──소유──> Karmada API의 원본 workload/policy
Karmada  ──소유──> b/c에 Push된 실제 복제본
```

따라서 Argo Application은 Karmada API의 원본 리소스, policy, 원본에 집계된
health/status를 중심으로 보여준다. `AppProject`는 Karmada가 만든
`ResourceBinding`/`ClusterResourceBinding`도 자식 리소스로 표시할 수 있도록
허용한다. Karmada의 Argo 연동 모델에서는 Binding이 placement와 applied 상태를
설명한다.

반면 member cluster의 Pod/ReplicaSet과 실행 namespace의 `Work`까지 하나의
Argo Application 트리에 모두 직접 소유 리소스로 넣지는 않는다. 서로 다른
Kubernetes API의 복제본을 Argo가 다시 추적하게 하면 Karmada와 소유권이
겹칠 수 있기 때문이다. 전체 복제본 조회는 Karmada API/Dashboard/Search를
사용하고, Argo에서는 원본의 집계 상태를 확인한다.

현재 Tower의 `karmada` destination credential은 `ResourceBinding`과 `Work`의
get/list/watch 권한을 갖는다. `AppProject`의 Binding 허용도 자식 resource tree
표시의 전제다. 다만 현재 Tower Argo CD v3.2.6의 실제 tree에서는 원본의 집계
health는 보이지만 Binding 노드는 노출되지 않는 상태다. 따라서 현 버전에서는
Binding과 Work 상세를 Karmada API에서 조회하고, Argo 업그레이드 시 공식 연동
tree 동작을 다시 검증한다. 이 권한은 관찰용이며 Federation Git이 해당 생성
리소스를 직접 선언하거나 수정한다는 뜻이 아니다.
