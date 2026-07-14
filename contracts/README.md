# contracts

Infra Layer, feature repository, Federation 사이에서 공통으로 지켜야 하는 계약을 문서화한다.

주요 계약 대상:

- Namespace naming과 ownership
- Workload/component label
- Karmada resource selector
- Cluster capability label
- Cluster-scoped resource 제한
- Secret reference와 credential 처리
- Artifact revision과 promotion 규칙

실제 workload manifest보다 경계와 규칙을 우선 기록한다.

## Release contract

| 항목 | 규칙 |
|---|---|
| Namespace | descriptor에 `scalex-` prefix namespace를 명시하고 모든 active release에서 유일하게 사용 |
| Release label | `scalex.io/release=<release>` |
| Component label | `scalex.io/component=<component>` |
| Infra ownership | Ceph/ObjectStore/bucket StorageClass/RGW endpoint/LB pool은 `b-k8s`와 `eecs-k8s`가 소유 |
| Bucket claim ownership | 기능별 OBC는 feature Helm이 선언하고 Federation/Karmada가 기능 namespace에 배치 |
| Workload ownership | Job/Deployment/Service는 Federation/Karmada가 소유 |
| Secret | Feature는 Secret 이름만 참조하고 값은 Git에 저장하지 않음. 승인된 bootstrap bridge 또는 Secret Store가 Rook 생성 credential을 Karmada native `Secret`으로 전달 |
| Placement | `PropagationPolicy`에서만 member cluster 선택 |
| Override | Federation workload만 대상, Infra resource 수정 금지 |
| Chart pin | `release.yaml.source.revision`은 full Git commit SHA |
| Image pin | `values.yaml.images.*.digest`는 immutable `sha256` digest |
| Promotion | chart revision과 해당 build에서 변경된 모든 image를 하나의 PR에서 함께 갱신 |
| Feature source | `children.yaml`에 URL과 chart path가 정확히 등록된 repository만 허용 |

Argo direct 경로와 Karmada 경로가 동일한 `cluster + namespace + kind + name`
을 동시에 소유하면 안 된다.

Object-storage lifecycle은 다음 네 단계로 분리한다.

```text
*-k8s Infra capability
  → feature Helm ObjectBucketClaim
  → Federation placement
  → member Rook bucket/credential provisioning
```

Karmada는 OBC를 member에 전달하지만 Rook이 member에서 생성한 Secret을 다른
클러스터로 역수집하지 않는다. Cross-cluster 소비자는 Tower credential bridge
또는 중앙 Secret Store를 사용한다.

## Artifact promotion contract

Feature CI가 image를 몇 개 생성하는지는 Federation의 고정 스키마가 결정하지
않는다. 각 chart의 component 이름을 `images` map의 key로 사용한다.

```yaml
images:
  api:
    repository: ghcr.io/example/feature-api
    tag: "1.2.3"
    digest: sha256:<64-hex>
    pullPolicy: IfNotPresent
  worker:
    repository: ghcr.io/example/feature-worker
    tag: "1.2.3"
    digest: sha256:<64-hex>
    pullPolicy: IfNotPresent
```

CI promotion의 입력은 검증된 chart commit과 component별 image digest 집합이다.
출력은 해당 release의 `release.yaml`과 `values.yaml`만 바꾸는 Pull Request다.
부분 승격을 피하기 위해 한 build에서 함께 동작하는 image는 한 commit에서 모두
갱신한다. 배포와 rollback의 원자 단위도 이 Federation commit이다.

새 feature repository는 `contracts/children.yaml`의 exact URL/path allowlist와
`bootstrap/appproject.yaml`에 함께 등록한다. Wildcard repository 권한은 사용하지
않는다. `FederationRelease`의 유일한 현재 renderer는 `helm/v1`이며, 새 renderer는
별도 API/version 계약으로 추가한다. Private repository credential 등록은 Tower
Argo 운영 경계이며 이 repository에 credential을 저장하지 않는다.

## RGW runtime credential reference

`rgw-analysis-web`의 dependency directory에는 배포 YAML을 두지 않는다.
승인된 bootstrap script가 B의 기능 소유 OBC Secret을 읽고 release values가 참조하는 이름과 key로
Karmada API에 native `Secret`을 생성한다. workload `PropagationPolicy`의
`propagateDeps: true`가 Pod dependency를 member로 전달한다. 어느 경로도 credential 값이나
kubeconfig를 Git에 저장하지 않는다.
