# tests

`test-credential-bridge.sh` verifies that the POC bridge reads the
feature-owned B OBC Secret, writes the distinct Karmada runtime Secret with
server-side apply, and keeps credential values out of repository files.

GitOps desired state가 merge되기 전에 정적 검증과 smoke 검증을 수행한다.

향후 검증 범위:

- Helm chart와 plain YAML policy render 성공 여부
- Kubernetes schema 정합성
- Karmada policy selector와 workload label 연결
- Resource ownership 중복
- 금지 namespace 및 cluster-scoped resource
- Full chart commit과 모든 image digest의 immutable 여부
- Secret 및 credential 노출 여부

실제 cluster를 변경하는 테스트는 명시적인 별도 단계로 격리한다.

현재 `scripts/validate.sh`가 다음을 검사한다.

- strict `scalex.io/v1alpha1` descriptor, `helm/v1` renderer와 immutable feature revision
- pinned `check-jsonschema 0.33.3` structural validation과 shell cross-field semantics
- exact child URL/path enrollment, AppProject parity, local origin과 pinned tree identity
- path traversal, symlink/submodule와 mutable/stale artifact 거부; dirty checkout과 무관한 pinned Git tree 검증
- bootstrap manifest와 ApplicationSet directory source 정합성
- bootstrap에 허용된 두 manifest 외 자동 적용 YAML/JSON이 없는지
- release별 `policy/` recursive plain YAML policy render
- feature chart의 pinned commit export 및 Helm render
- 여러 component image의 digest와 rendered image pin
- CI base ref 기준 image와 chart revision의 부분 승격 방지
- policy selector가 실제 chart resource를 가리키는지
- Federation Git 내부 평문 Secret 부재
- source contract별 dependency 검증(legacy POC와 Smurf 모두 YAML 0개)
- release namespace/Application/rendered identity/명시적 LoadBalancer IP의 전역 충돌 거부
- committed active inventory의 exact path 집합과 안정 identity 검증; POC SHA는 baseline으로
  고정하고 synthetic Smurf canary fixture로 multi-release 충돌 검증
- Federation script의 credential materialization과 직접 cluster mutation 부재
- malformed descriptor, duplicate identity, empty Service annotation과 selector mismatch
- child cluster를 Argo destination으로 직접 사용하지 않는지
- Karmada Binding 자식 표시의 전제인 AppProject 허용 목록
