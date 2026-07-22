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

1. exact repository URL을 `argocd/appproject.yaml` sourceRepos에 추가한다.
2. `releases/<feature-repo-name>/release.yaml`, generated `values.yaml`과 필요 시
   `runtime-values.yaml`을 만든다.
3. 디렉터리명, release `name`, namespace와 source repo 이름을 동일하게 맞춘다.
4. tracking은 Tekton이 `promotion.resolvedRevision`과 generated image values를 기록하고,
   pinned release는 사용자가 full `source.revision`을 명시한다.
5. Infra dependency와 교차 클러스터 credential이 준비될 때까지 `state: disabled`를 유지한다.
6. 모든 gate 통과 후 Tekton이 promotion branch/PR을 만들고 사람이 merge한다.

Helm lint/template와 Karmada policy 검증은 Tower Tekton이 담당한다. Federation에서는
계약 테스트로 effective revision, generated/runtime values 경계와 promotion 변경 범위를
검증한다.
