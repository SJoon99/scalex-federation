# tests

GitOps desired state가 merge되기 전에 정적 검증과 smoke 검증을 수행한다.

향후 검증 범위:

- Helm/Kustomize render 성공 여부
- Kubernetes schema 정합성
- Karmada policy selector와 workload label 연결
- Resource ownership 중복
- 금지 namespace 및 cluster-scoped resource
- Mutable image tag 사용 여부
- Secret 및 credential 노출 여부

실제 cluster를 변경하는 테스트는 명시적인 별도 단계로 격리한다.
