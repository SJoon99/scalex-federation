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

## First POC

`releases/poc/rgw-analysis-web`은 B의 RGW 입력을 C에서 분석하고 결과를 B의
Nginx로 제공하는 첫 vertical slice다. B/C 이름은 Federation policy에만
존재하며 feature chart는 cluster-neutral 상태를 유지한다.

## 기본 원칙

- Feature source와 build logic은 feature repository가 소유한다.
- Cluster Infra는 `eecs-k8s`와 각 `*-k8s` repository가 소유한다.
- Federation workload는 Tower Argo가 child cluster에 직접 배포하지 않는다.
- 동일 리소스를 Argo direct 경로와 Karmada가 동시에 관리하지 않는다.
- Revision은 tag, commit 또는 immutable image digest로 고정한다.
- Secret 값은 Git에 저장하지 않고 reference만 선언한다.
