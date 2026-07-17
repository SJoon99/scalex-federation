# tests

GitOps desired state가 배포되기 전에 source, render, ownership과 script 경계를 검증한다.
실제 cluster mutation은 mock 처리한다.

| 파일/영역 | 검증 내용 |
|---|---|
| `test-runtime-bindings.sh` | B/C binding 발견, kubeconfig 선택, normalized 객체와 secret 비노출 |
| `contracts/test-script-boundaries.sh` | release directory와 runtime script 권한 경계 |
| `contracts/test-release-contract.sh` | flat descriptor schema와 path identity |
| `contracts/test-release-promotion.sh` | tracked/pinned 승격과 SHA·tag·digest 원자성 |
| `contracts/test-validation-fixtures.sh` | 잘못된 source, image, policy와 Infra resource 거부 |
| `contracts/test-multi-release-coexistence.sh` | 복수 active release와 namespace/path 충돌 거부 |
| `runtime-observation/test-observe-release.sh` | 보존된 RGW 설정의 Karmada/member read-only 관찰 |

`scripts/validate.sh`는 active release에 대해 다음을 검사한다.

- enrolled child URL/path, full chart SHA와 pinned Git tree
- Helm strict lint와 render
- 모든 workload image의 immutable digest
- workload별 정확히 하나의 `PropagationPolicy` selector
- release namespace 밖으로 나가는 manifest와 policy selector 부재
- Secret/OBC/PVC와 cluster-scoped resource 부재
- namespaced RoleBinding이 같은 render의 local Role만 참조하는지
- ApplicationSet의 flat discovery, two-source와 namespace ownership 계약

Live Argo sync, Infra provisioning과 Karmada Push 성공은 별도 runtime 단계에서 확인한다.
