# scalex-federation

ScaleX User/Dev Layer의 배포 승인 목록을 관리하는 GitOps repository다. Tower Argo CD가
활성 release를 읽어 Karmada control plane에 동기화하고, Karmada가 선택된 member
cluster에 workload를 배포한다.

## 소유권

- Feature repository: source, image, workload Helm template, namespaced Karmada policy
- `scalex-federation`: 활성 release, exact chart revision, namespace, 환경별 Helm values
- `eecs-k8s`와 `*-k8s`: CNI/CSI, Ceph/RGW, OBC/PVC, workload namespace 등 Infra dependency
- Tower Karmada: placement 해석과 B/C member 복제본

동일한 리소스를 Argo direct와 Karmada가 동시에 관리하지 않는다. Federation의
ApplicationSet은 Karmada source namespace에
`namespace.karmada.io/skip-auto-propagation=true`를 설정해 member namespace ownership을
Infra repository에 남긴다.

## 배포 흐름

```text
feature repository
├─ workload Helm templates
└─ PropagationPolicy/OverridePolicy templates
              │ pinned revision + release values
              ▼
scalex-federation releases/<repo>/
              │
              ▼
Tower Argo CD → Tower Karmada API → B/C member clusters
```

## 디렉터리

| 경로 | 역할 |
|---|---|
| `bootstrap/` | AppProject와 flat release ApplicationSet |
| `releases/<repo>/` | repository별 `release.yaml`과 `values.yaml` |
| `contracts/` | source enrollment과 release descriptor 계약 |
| `scripts/` | 로컬 검증과 기존 runtime binding/observation 도구 |
| `tests/` | release, Karmada policy, 보안 경계 회귀 검증 |

현재 `temp-poc`가 active다. B의 dataset service에서 C의 analyzer가 데이터를 읽고,
분석 결과를 B의 report service로 다시 전송한다. `scalex-feature-poc`의 기존 RGW/S3,
image, runtime binding, placement 값은 보존하지만 chart가 policy를 렌더링하지 않으므로
disabled 상태다.

```bash
PATH=/path/to/yq:$PATH \
FEATURE_REPOS_ROOT=/path/to/checkouts \
./scripts/validate.sh
```

실제 image/chart blob은 각 feature repository와 registry가 소유한다. 이 repository에는
credential 원문을 저장하지 않고 immutable source와 image 좌표만 기록한다.
