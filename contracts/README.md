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

## POC contract

| 항목 | 규칙 |
|---|---|
| Namespace | release마다 `scalex-<release>` 전용 namespace 사용 |
| Release label | `scalex.io/release=<release>` |
| Component label | `scalex.io/component=<component>` |
| Infra ownership | RGW/Ceph/LB pool은 `b-k8s`와 `eecs-k8s`가 소유 |
| Workload ownership | Job/Deployment/Service는 Federation/Karmada가 소유 |
| Secret | 값은 Git 금지, Federation 소유 `ExternalSecret`이 external store에서 생성 |
| Placement | `PropagationPolicy`에서만 member cluster 선택 |
| Override | Federation workload만 대상, Infra resource 수정 금지 |
| Chart pin | `release.yaml.source.revision`은 full Git commit SHA |
| Image pin | `values.yaml.images.*.digest`는 immutable `sha256` digest |
| Promotion | chart revision과 해당 build에서 변경된 모든 image를 하나의 PR에서 함께 갱신 |
| Feature source | `children.yaml`에 URL과 chart path가 정확히 등록된 repository만 허용 |

Argo direct 경로와 Karmada 경로가 동일한 `cluster + namespace + kind + name`
을 동시에 소유하면 안 된다.

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

`rgw-analysis-web`은 `ExternalSecret/rgw-analysis-web-rgw`만 소유한다. 이 resource는
각 대상 cluster에 이미 운영자가 제공한 `SecretStore/scalex-poc-rgw-analysis-web`을
참조하고 external key `scalex/poc/rgw-analysis-web/rgw`에서 target
`Secret/scalex-poc-rgw`를 만든다. Git에는 external key 이름과 resource identity만
기록하며 credential 값이나 kubeconfig를 저장하지 않고 cluster mutation을 실행하지 않는다.
