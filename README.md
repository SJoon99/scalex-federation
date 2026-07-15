# scalex-federation — per-release variant

ScaleX 기능의 **배포 승인 목록**을 관리하는 GitOps repository다. 기능 구현, Karmada
정책, Object Storage claim은 더 이상 이 repository가 소유하지 않는다.

이 branch는 권장 비교안인 `release 하나 = release.yaml + values.yaml` 구조를 표현한다.
Tower의 실제 bootstrap은 아직 `main`을 사용하므로 이 branch 자체는 운영 상태를
변경하지 않는다.

## 책임

- 배포할 feature Helm chart의 exact Git revision 고정
- release namespace와 환경별 values 선택
- release 활성화·비활성화 및 Git 기반 승격/rollback
- Tower Argo의 AppProject/ApplicationSet bootstrap

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
           │ pinned revision + release values
           ▼
scalex-federation release catalog
           │
           ▼
Tower Argo CD ──sync──> Tower Karmada API ──Push──> member clusters

eecs-k8s + *-k8s ──Argo direct──> Infra와 feature dependency
```

Feature chart가 workload와 policy를 함께 렌더링하므로 이름과 selector 변경은 하나의
artifact revision에서 원자적으로 검증된다. Federation values는 기존 Infra가 제공한
Secret/ConfigMap 이름과 환경별 runtime 값만 전달한다.

## 구조

```text
bootstrap/                                  # Tower Argo 진입점
docs/                                       # 소유권·승격·실행 계약
releases/poc/                               # 현재 10개 disabled release
└─ <release>/
   ├─ release.yaml                          # source SHA, namespace, state
   └─ values.yaml                           # 환경별 최소 Helm override
```

단일 거대 values 파일과 달리 release 변경·rollback·CODEOWNERS 범위를 독립적으로 유지한다.
자세한 비교는 [`docs/structure-variant.md`](docs/structure-variant.md)를 참고한다.

## 현재 cutover 상태

`releases/poc/` 아래에 기능 10개가 실제 release 디렉터리로 존재한다. 모두
`state: disabled`이므로 현재 Tower에 Application을 생성하지 않는다. 전용 feature chart가
아직 없는 9개 release는 구조 비교용으로 `scalex-feature-poc` revision을 임시 참조한다.
각 기능의 chart와 Karmada policy가 준비된 후 source/values를 교체하고 개별적으로
`state: active`로 승격한다.
