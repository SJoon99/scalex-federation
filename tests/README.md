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

현재 `scripts/validate.sh`가 다음을 검사한다.

- release descriptor 필수 경로와 immutable feature revision
- bootstrap render 및 release별 Kustomize/Directory policy render
- `policy.renderer` enum과 renderer별 entrypoint 정합성
- feature Helm render
- policy selector가 실제 chart resource를 가리키는지
- Federation Git 내부 평문 Secret 부재
- child cluster를 Argo destination으로 직접 사용하지 않는지
- Karmada Binding 자식 표시의 전제인 AppProject 허용 목록
