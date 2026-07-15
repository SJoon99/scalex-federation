# tests

GitOps desired state가 merge되기 전에 source, render, ownership과 script 경계를
검증한다. 실제 cluster mutation은 테스트에서 mock 처리한다.

## 주요 테스트

| 파일/영역 | 검증 내용 |
|---|---|
| `test-storage-binding.sh` | B OBC Secret+ConfigMap 입력, normalized Karmada List 출력, idempotent SSA와 secret 비노출 |
| `contracts/test-script-boundaries.sh` | dependency inventory와 script 권한/책임 경계 |
| `contracts/test-release-contract.sh` | strict FederationRelease schema와 path identity |
| `contracts/test-validation-fixtures.sh` | 잘못된 dependency/policy/source를 validator가 거부하는지 |
| `contracts/test-multi-release-coexistence.sh` | namespace/resource/LB IP 충돌 방지 |
| `runtime-observation/test-observe-release.sh` | Karmada Binding, B/C workload와 HTTP read-only 관찰 계약 |

`scripts/validate.sh`는 추가로 다음을 검사한다.

- exact child URL/path, full chart SHA와 pinned Git tree
- 모든 rendered image의 immutable digest
- feature chart가 OBC/Secret/policy/cluster-scoped resource를 렌더링하지 않는지
- POC `dependencies/`가 OBC와 non-secret binding ConfigMap만 포함하는지
- policy selector가 chart/dependency 또는 binding-generated runtime ConfigMap을 가리키는지
- OBC는 B에만, workload는 의도한 B/C에 배치되는지
- Federation Git 내부 평문 credential 부재
- ApplicationSet의 Helm/dependency/policy source 계약
- release 간 namespace, resource identity와 명시적 LoadBalancer IP 충돌

전체 검증은 mock 기반이며 live Argo sync, Rook provisioning, Karmada Push와 HTTP 성공은
별도 runtime 검증 단계에서 확인한다.
