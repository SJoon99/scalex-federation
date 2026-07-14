# 보호된 runtime 관찰

`.github/workflows/runtime-observation.yaml`은 `main`의 Federation Validation 성공 뒤
또는 수동 실행으로 시작한다. job은 GitHub environment `scalex-release`, self-hosted
labels `self-hosted`, `linux`, `scalex-management`와 environment secret
`SCALEX_RELEASE_KUBECONFIG`를 요구한다.
같은 보호 경계 안에서 legacy `poc/rgw-analysis-web`을 먼저 관찰하고 additive
`cuty/rgw-analysis-web`을 이어서 관찰하며, 둘 중 하나라도 실패하면 job이 실패한다.
`.github/actionlint.yaml`은 이 중 custom label인 `scalex-management` 하나만 선언하며
workflow lint에서 runner-label 검사를 비활성화하지 않는다.

Kubeconfig는 shell trace를 끈 상태에서 권한 `0600`인 runner 임시 파일로 한 번만
기록하고 payload 변수를 즉시 해제하며 마지막 step에서 제거한다. CI contract는 이
write와 cleanup을 exact allowlist로 검사해 stdout/stderr, environment dump, command
substitution 또는 파일 표시 경로를 거부한다. Runtime job과 각 step의 허용 key도
고정하고 모든 run step에 exact `shell: bash`를 요구하므로 custom shell wrapper가
run body 전에 environment나 kubeconfig를 읽는 경로도 거부한다.
관찰 script는 고정 context `karmada`, `b`, `c`에서 `get`만 수행한다. `apply`,
`patch`, `delete`, `exec`와 Argo sync는 수행하지 않으므로 desired state를 바꾸지
않는다.

관찰 성공에는 다음 증거가 모두 필요하다.

- 모든 named 응답의 exact apiVersion/kind/name/namespace identity
- Karmada ResourceBindingList/item identity, 예상 `b`/`c` placement와 cluster별 `applied: true`
- 양쪽 member의 source-specific native Secret identity와 필수 credential key 존재 여부
- 양쪽 member의 source-specific runtime ConfigMap identity, release label과 필수 data surface
- result-web Deployment ready, seeder/analyzer Job complete
- member workload의 image 집합이 release values의 exact tag+digest 집합과 일치
- B의 result-web LoadBalancer HTTP 응답에 완료된 결과 surface가 존재

관찰 namespace는 경로/이름으로 재구성하지 않고 release descriptor의 `namespace`를
그대로 사용한다. ConfigMap 검사는 descriptor의 `renderer`와 exact source URL/path를 먼저
확인한다. 기존 `scalex-feature-poc`에는 legacy scripts/runtime contract를 적용하고,
tracked promotion 이후 `BellTigerLee/smurf-child`에는 실제 chart가 렌더링하는 단일
`rgw-analysis-web-runtime` ConfigMap, component `runtime`, S3와 polling key contract를
적용한다. 다른 renderer 또는 URL/path 조합은 추측하지 않고 실패한다. Fixture test는 workspace에
Smurf child chart가 있으면 그 chart를 Helm render해 resource/image/runtime contract가
관찰 fixture와 계속 일치하는지도 검사한다.

HTTP 완료 판정도 source-specific이다. Legacy POC는 heading과 함께 결과 `<dl>` 및
Rows/sum/average field를 요구하고 waiting page를 거부한다. Smurf child는
bootstrap/loading page에도 같은 heading이 있으므로 heading만으로 PASS하지
않고 `data-state="success"`, `aria-busy="false"`, `Analysis complete`와 release
`values.runId`에 일치하는 `data-field="run-id"`를 모두 요구한다. Loading page나 다른
run의 완료 page는 stale evidence로 실패한다.

Tower Argo Application은 Tower control cluster의 API에 있고 `karmada` API에는 없다.
이 workflow에 허용된 kubeconfig context는 `karmada`, `b`, `c`뿐이므로 Application을
`karmada` context에서 조회하지 않는다. Tower의 Application `Synced`/`Healthy`와
실제 reconciled source revision은 별도로 권한이 부여된 Tower 관찰 surface가 없는
현재 workflow에서 **NOT RUN**이다. 그 증거가 필요하면 별도 승인된 Tower context와
독립된 read-only workflow를 추가해야 하며, 이 workflow의 PASS로 대체하지 않는다.

기본적으로 10초 간격으로 30회 읽고 하나라도 stale, partial, wrong-image,
not-ready 또는 unreachable이면 실패한다. Timeout이나 API 접근 불가를 성공으로
간주하지 않는다. Workflow 결과는 선언된 image digest와 Karmada/member surface의
관찰 증거이며 Tower Argo sync 또는 이후 상태까지 보증하지 않는다.

로컬에서는 fake API fixture로 안전하게 contract를 재현할 수 있다.

```bash
./tests/runtime-observation/test-observe-release.sh
```

실제 cluster 관찰은 보호 environment와 명시적 운영 권한이 있는 workflow에서만
실행한다.
