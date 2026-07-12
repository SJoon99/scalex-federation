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
| Secret | 값은 Git 금지, Karmada API의 동일 namespace에 bootstrap |
| Placement | `PropagationPolicy`에서만 member cluster 선택 |
| Override | Federation workload만 대상, Infra resource 수정 금지 |

Argo direct 경로와 Karmada 경로가 동일한 `cluster + namespace + kind + name`
을 동시에 소유하면 안 된다.
