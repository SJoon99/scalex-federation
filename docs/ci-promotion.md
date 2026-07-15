# CI and promotion in the single-values experiment

Promotion would update one catalog entry atomically:

- `state`: `disabled` until the pinned chart renders required Karmada policies,
  then `active` when ready for ApplicationSet generation
- `source.revision`: full immutable chart commit SHA
- `helm.values`: feature chart가 정의한 최소 환경 override와 기존 runtime
  Secret/ConfigMap reference

Feature repository의 GitHub Actions가 exact source revision, Helm lint/template,
ApplicationSet active-state contract와 Karmada policy selector를 검증한 뒤 이 repository의
`values.yaml`을 수정하는 promotion PR을 생성한다.

Federation은 특정 image values key 구조를 강제하지 않는다. Image가 chart 기본값에 있든
catalog override에 있든 최종 Helm render의 모든 workload image가 immutable digest를
사용해야 한다.

이 비교 branch 자체에는 별도 hosted workflow, `scripts/`, `tests/`를 두지 않는다. CI는
cluster에 직접 배포하지 않고 Federation PR 생성까지만 담당한다.
