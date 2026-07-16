# scripts

검증과 승인된 management-plane 보조 작업을 반복 가능하게 만든다. CI 검증 script와
runtime mutation script의 경계를 명확히 유지한다.

## 주요 script

| 파일 | 역할 | cluster write |
|---|---|---|
| `validate.sh` | flat descriptor/source/chart/Karmada policy/image 계약 검증 | 없음 |
| `rgw-analysis-web/verify-public-images.sh` | image tag가 선언 digest를 가리키는지 검증 | 없음 |
| `rgw-analysis-web/observe-release.sh` | Karmada placement, B/C workload, HTTP read-only 관찰 | 없음 |
| `sync-runtime-bindings.sh` | 모든 선언형 RuntimeBinding의 source output → Karmada runtime 객체 동기화 | Karmada binding만 |

## RuntimeBinding runner 원리

```text
Karmada RuntimeBinding ConfigMap                   # non-secret declaration
├─ sourceCluster                                   # b, c, ...
├─ bindingType                                     # rook-obc-s3
└─ target Secret/ConfigMap identity
                     │
                     ├─ sourceCluster=b → b.kubeconfig
                     └─ sourceCluster=c → c.kubeconfig
                     ↓
source Rook OBC Secret+ConfigMap
                     ↓
sync-runtime-bindings.sh
                     ↓
Karmada normalized Secret+ConfigMap
```

`--all`은 `scalex.io/runtime-binding=true` label로 모든 binding을 발견한다.
`--binding <namespace>/<name>`은 하나만 재처리한다. member credential은
`MEMBER_KUBECONFIG_DIR/<sourceCluster>.kubeconfig`에서 찾으므로 release·cluster별 script가
필요하지 않다.

현재 지원 계약은 `rook-obc-s3/v1alpha1`이다. runner는 exact source OBC/Secret/ConfigMap을
읽고, idempotent server-side apply로 target Secret+ConfigMap을 생성한다. credential을
명령 인자나 로그에 노출하지 않으며 target 객체에는 binding ConfigMap ownerReference를
설정한다. workload나 policy를 직접 배포하지 않고 Argo/Karmada desired-state 경로를
우회하지 않는다.

`rook-obc-s3` adapter의 field-manager는 기존 runtime 객체의 managedFields와 credential
rotation 호환성을 위해 `scalex-object-storage-binding`을 유지한다. 이 문자열은 script
이름이 아니라 저장소 binding 소유권 ID이므로 managedFields migration 없이 변경하지
않는다.

다음은 의도적으로 지원하지 않는다.

- feature/release 이름별 분기
- 임의 namespace 간 복사
- 임의 key/resource mapping
- source credential을 Git에 저장

새 dependency 종류는 범용 복사 옵션이 아니라 공통 runner의 명시적 adapter와 테스트로
추가한다. 같은 `rook-obc-s3` 계약을 사용하는 feature는 선언 ConfigMap만 추가하면 된다.
기존 Cuty 전용 credential bootstrap은 이 원칙에 따라 제거했다. 다른 key 형식을 요구하는
release는 활성화 전에 새 versioned adapter와 검증 계약을 추가해야 하며, feature 전용
script를 복원하지 않는다.

전용 controller는 현재 도입하지 않는다. 지속 reconciliation이나 자동 rotation SLA가
필요해질 때 동일 binding 계약을 Tower CronJob 또는 controller가 구현하도록 교체한다.
현재 runner는 fail-fast이며 `--all` 실행 주기와 재시도는 management-plane 운영 절차가
담당한다.

`validate.sh`는 source repository가 Federation과 같은 상위 디렉터리 아래 checkout되어
있다고 가정한다. 다르면 `FEATURE_REPOS_ROOT`를 지정한다. active chart는 working tree가 아니라
`release.yaml`의 pinned commit에서 export해 검증한다. `check-jsonschema`는 0.33.3을
사용한다.
