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
