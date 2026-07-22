# scalex-federation

ScaleX 기능의 **배포 승인 목록**을 관리하는 GitOps repository다. 기능 구현, Karmada
정책, Object Storage claim은 더 이상 이 repository가 소유하지 않는다.

배포 단위는 `release 하나 = release.yaml + values.yaml` 구조를 사용한다.

## 책임

- 배포할 feature Helm chart의 explicit pin 또는 latest promoted successful Git revision 고정
- 기능 repo와 동일한 release 식별자, namespace, effective source revision 고정
- 기능 chart에 전달할 최소 배포 values 선택
- release 활성화·비활성화 및 Git 기반 승격/rollback
- Tower Argo의 AppProject/ApplicationSet 선언

## 책임지지 않는 것

- 기능 source, image build 또는 Helm template 구현
- PropagationPolicy/OverridePolicy template 작성
- OBC/PVC, bucket, credential 또는 runtime binding 생성
- CNI, CSI, Ceph, RGW 등 Infra 구성
- child cluster 직접 변경

## 배포 흐름

```text
feature repository
├─ workload Helm templates
└─ Karmada policy Helm templates
           │ effective revision + runtime/generated values
           ▼
scalex-federation release catalog
           │
           ▼
Tower Argo CD ──sync──> Tower Karmada API ──Push──> member clusters

eecs-k8s + *-k8s ──Argo direct──> Infra와 feature dependency
```

Feature chart가 workload와 policy를 함께 렌더링하므로 이름과 selector 변경은 하나의
artifact revision에서 원자적으로 검증된다. 사람이 관리하는 runtime values와 Tekton이
관리하는 generated image values를 분리한다.

## 구조

```text
argocd/                                     # Tower Argo CD 진입점
docs/                                       # 소유권·승격·실행 계약
releases/                                   # 기능 repo 단위 release
├─ scalex-feature-poc/
│  ├─ release.yaml                          # Git descriptor: repo/SHA, namespace, state
│  ├─ runtime-values.yaml                   # 사람이 관리하는 runtime override
│  └─ values.yaml                           # Tekton generated image identity
└─ scalex-feature-<name>/
   ├─ release.yaml
   ├─ runtime-values.yaml
   └─ values.yaml
```

단일 거대 values 파일과 달리 release 변경·rollback·CODEOWNERS 범위를 독립적으로 유지한다.
자세한 비교는 [`docs/structure-variant.md`](docs/structure-variant.md)를 참고한다.

## 현재 release 상태

`releases/` 바로 아래에 기능 repo 이름과 동일한 release 디렉터리 11개가 존재한다.
`poc` 같은 환경 중간 계층은 사용하지 않는다. 각 디렉터리명, `release.yaml`의 `name`,
`namespace`, `source.repoURL`은 같은 기능 repo 식별자를 따른다.

`temp-poc`은 latest promoted successful chart SHA를 추적해 `state: active`로 운영하며, 나머지 10개는
전용 repo와 chart가 준비된 후 full SHA와 values를 채워 개별적으로 활성화한다.
