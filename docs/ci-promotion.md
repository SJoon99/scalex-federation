# CI and promotion in the single-values experiment

Promotion would update one catalog entry atomically:

- `state`: `disabled` until the pinned chart renders required Karmada policies,
  then `active` when ready for ApplicationSet generation
- `source.revision`: full immutable chart commit SHA
- `helm.values`: feature chart가 정의한 최소 환경 override와 기존 runtime
  Secret/ConfigMap reference

Hosted validation은 이 comparison branch push 또는 수동 실행 시 exact source revision을
가져와 catalog shape, ApplicationSet active-state filtering, Helm lint/template를 검사한다.
Active entry는 chart가 `PropagationPolicy`를 렌더링하지 않거나 selector가 실제 workload를
정확히 한 번 선택하지 않으면 실패한다.

Federation은 특정 image values key 구조를 강제하지 않는다. Image가 chart 기본값에 있든
catalog override에 있든 최종 Helm render의 모든 workload image가 immutable digest를
사용해야 한다.
