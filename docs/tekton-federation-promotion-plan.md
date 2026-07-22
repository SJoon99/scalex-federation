# Tekton → ScaleX Federation Promotion 구현 계획

> 기준 저장소: `dev/eecs-k8s`, `dev/tower-k8s`, `dev/scalex-federation`

## 목표

Child 개발자는 자신의 repository에 commit/push만 수행한다. Tower Tekton은 승인된 Child 설정을 사용해 source를 검증하고 container image를 build/push한 뒤 immutable digest를 산출한다. 별도 promotion Pipeline은 `scalex-federation`에 branch와 PR을 생성하며, 사람의 merge를 배포 승인 경계로 유지한다.

## 책임 경계

```text
Child repository
  source + Dockerfile + Helm chart
        │
        ▼
Tekton child-build
  exact SHA clone + Helm 검증 + image build/push
        │ promotion payload
        ▼
Tekton federation-promote
  release metadata + generated values 갱신 + PR 생성
        │ human merge
        ▼
Argo CD → Karmada → member clusters
```

- Child chart와 렌더 결과를 Federation에 복사하지 않는다.
- Federation은 Child chart의 effective revision과 generated image values만 고정한다.
- Build credential과 Federation GitHub credential을 분리한다.
- Federation `main`에 직접 push하지 않는다.

## Revision 계약

`source.revision`은 사용자 pin이며 존재하면 항상 우선한다. 생략된 tracking release는 Tekton이 기록한 `promotion.resolvedRevision`을 사용한다.

```text
effectiveRevision = source.revision ?? promotion.resolvedRevision
```

`promotion.resolvedRevision`은 raw Git HEAD가 아니라 성공 후 promotion PR로 승인·merge된 최신 CI SHA다. 이를 통해 최신 commit의 build 실패나 미승인 상태에서도 이전 승인 artifact를 유지한다.

Tracking 예시:

```yaml
source:
  repoURL: https://github.com/BellTigerLee/temp-poc.git
  path: chart
  branch: main
promotion:
  mode: tracking
  resolvedRevision: d62d00a9c07067c4c620cee42ab9e760acf606cc
```

Pinned 예시:

```yaml
source:
  repoURL: https://github.com/BellTigerLee/temp-poc.git
  path: chart
  branch: main
  revision: d62d00a9c07067c4c620cee42ab9e760acf606cc
promotion:
  mode: pinned
```

Active release에서 explicit revision과 resolved revision이 모두 없으면 계약 오류다.

## Values 소유권

```text
releases/<child>/release.yaml
  사용자 의도 + Tekton resolvedRevision

releases/<child>/runtime-values.yaml
  사람이 관리하는 placement, endpoint, dependency 값

releases/<child>/values.yaml
  Tekton이 관리하는 image repository/tag/digest/sourceRevision
```

Helm value 적용 순서는 `runtime-values.yaml` 다음 `values.yaml`이다. generated image identity가 마지막에 적용되어 runtime override가 image digest를 덮지 못하게 한다. 존재하지 않는 `runtime-values.yaml`은 Argo CD의 `ignoreMissingValueFiles`로 허용한다.

## Promotion payload

```json
{
  "schemaVersion": "v1",
  "childName": "temp-poc",
  "sourceRevision": "d62d00a9c07067c4c620cee42ab9e760acf606cc",
  "pipelineRun": "temp-poc-dataset-ingest-...",
  "image": {
    "name": "dataset-ingest",
    "valuesKey": "datasetIngest",
    "repository": "10.34.25.18/tower-ci/temp-poc/dataset-ingest",
    "tag": "sha-d62d00a9c07067c4c620cee42ab9e760acf606cc",
    "digest": "sha256:..."
  }
}
```

Payload는 build 결과에서 생성하며 digest 또는 exact SHA가 없으면 실패한다.

## Promotion actor

Promotion actor는 Tekton의 `federation-promote` Pipeline이다. GitHub App/PAT는 actor가 GitHub API를 호출할 때 사용하는 machine identity다.

최소 권한:

```text
scalex-federation Contents: read/write
scalex-federation Pull requests: read/write
Metadata: read
```

수동 검증부터 GitHub App private key로 짧은 수명의 installation token을 실행마다 발급한다. static PAT은 사용하지 않는다.

## Phase 1 — Revision 계약

수정 대상:

- `argocd/applicationset.yaml`
- `releases/temp-poc/release.yaml`
- `docs/ci-promotion.md`
- `docs/common-contract.md`
- `releases/README.md`
- 신규 계약 테스트

완료 조건:

- explicit `source.revision` 우선
- tracking은 `promotion.resolvedRevision` 사용
- active release에 effective revision이 없으면 테스트 실패
- pinned revision은 promotion이 덮어쓰지 않음

## Phase 2 — Generated/runtime values 분리

수정 대상:

- `releases/temp-poc/runtime-values.yaml` 생성
- `releases/temp-poc/values.yaml`을 image/build metadata 전용으로 축소
- ApplicationSet에 runtime/generated value-file 순서 적용

완료 조건:

- 기존 temp-poc runtime 설정 보존
- 기존 image 설정 보존
- generated values가 마지막에 적용
- runtime 파일이 없는 기존 disabled release도 ApplicationSet 계약 유지

## Phase 3 — Promotion payload

수정 대상:

- `dev/eecs-k8s/apps/tekton-ci/templates/task-create-promotion-payload.tpl`
- `pipeline-child-build.tpl`
- `values.yaml`
- `tests/tekton-ci-regression.sh`

완료 조건:

- build 성공 후 payload 생성
- exact SHA와 `sha256:` digest 검증
- Pipeline result로 payload 노출
- payload에 PipelineRun provenance 포함

## Phase 4 — Federation promotion Pipeline

수정 대상:

- `task-federation-promote.tpl`
- `pipeline-federation-promote.tpl`
- 공용/Tower values
- 회귀 테스트

동작:

1. Federation clone
2. payload 검증
3. release mode/pin 확인
4. stale build 차단
5. generated values 결정적 갱신
6. tracking resolvedRevision 갱신
7. 허용 파일 이외 diff 차단
8. promotion branch push
9. GitHub PR 생성

완료 조건:

- `main` 직접 push 없음
- release 디렉터리 밖 변경 없음
- 같은 payload 재실행 시 불필요한 중복 diff 없음
- GitHub credential은 promotion Task에만 mount

## Phase 5 — 수동 end-to-end

1. `child-build` 성공 결과 확보
2. 수동 `federation-promote` PipelineRun 생성
3. PR URL 결과 확인
4. PR diff가 `release.yaml`, `values.yaml`로 제한되는지 확인
5. 사람이 merge
6. Argo Application effective revision과 image digest 확인

필수 bootstrap:

- `tower-ci/Secret/federation-promotion-github-app` 생성
- 키 `appID`, `installationID`, `privateKey` 저장
- Secret 원문은 Git에 저장하지 않음

## 이후 Phase

- Phase 6: Child push webhook 또는 outbound poller로 PipelineRun 자동 생성
- Phase 7: Child별 Harbor project/Robot Secret/enrollment와 동시성 제한

## Stale build 규칙

동일 Child에서 늦게 끝난 과거 build가 최신 promotion을 덮지 못해야 한다.

- Child별 promotion concurrency 1
- candidate SHA가 현재 resolved revision보다 오래되면 PR 생성 안 함
- tracking은 최신 성공 build만 promotion candidate로 만들고, merge된 candidate만 resolved revision이 됨
- pinned는 explicit revision과 일치하는 build만 허용

## Reference 비교

- `eecs-k8s/apps/openark-gitops/templates/github/`: GitHub App/EventSource/Sensor 패턴
- `smartx-k8s/apps/openark-gitops/templates/github/`: 동일 공용 패턴
- `mobilex-k8s/patches/openark-gitops/values.yaml`: cluster-specific installation ID override

세 reference에는 Tekton 기반 Federation promotion 구현이 없으므로 인증·이벤트 패턴만 참고하고 promotion 계약은 본 설계에 따라 신규 구현한다.

## 검증 명령

```bash
# Federation contract
python3 tests/test_promotion_contract.py

# Tekton chart
helm lint apps/tekton-ci \
  -f apps/tekton-ci/values.yaml \
  -f ../tower-k8s/patches/tekton-ci/values.yaml
./tests/tekton-ci-regression.sh

git diff --check
```

## 비목표

- Federation main 자동 merge
- Argo sync 직접 호출
- Karmada apply 직접 호출
- Helm chart OCI package/push
- 외부 webhook 자동화(Phase 6)
