# Release 등록과 cutover

## Feature 준비

Feature repository가 다음을 하나의 Helm chart로 렌더링해야 한다.

- workload와 application ConfigMap/ServiceAccount
- namespaced `PropagationPolicy`
- 필요한 namespaced `OverridePolicy`
- 기존 Infra dependency의 Secret/ConfigMap reference

로컬 직접 설치를 지원한다면 `karmada.enabled=false` 같은 chart option으로 policy
template를 비활성화한다. Federation 경로에서는 반드시 policy가 렌더링되어야 한다.

## Federation 등록

1. exact repository URL을 `bootstrap/appproject.yaml` sourceRepos에 추가한다.
2. `releases/<feature-repo-name>/release.yaml`과 `values.yaml`을 만든다.
3. 디렉터리명, release `name`, namespace와 source repo 이름을 동일하게 맞춘다.
4. 검증된 full source SHA와 필요한 최소 배포 values를 기록한다.
5. Infra dependency와 교차 클러스터 credential이 준비될 때까지 `state: disabled`를 유지한다.
6. 모든 gate 통과 후 한 PR에서 revision/values와 `state: active`를 승격한다.

이 비교 branch에는 별도 `scripts/`와 `tests/`를 두지 않는다. Helm lint/template와
Karmada policy 검증은 feature repository의 GitHub Actions가 담당하고, Federation에서는
승격 PR의 source SHA, namespace, state와 values 변경 범위만 검토한다.
