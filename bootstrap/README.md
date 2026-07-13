# bootstrap

Tower Argo CD가 Federation release를 발견하는 고정 진입점이다.

- `appproject.yaml`: Federation source와 Karmada destination 경계,
  Karmada Binding 자식 리소스 표시 범위
- `applicationset.yaml`: `releases/*/*/release.yaml` 자동 발견
- `kustomization.yaml`: Tower root Application이 동기화하는 경로

ApplicationSet은 각 `release.yaml`의 `policy.renderer`를 읽는다.

- `kustomize`: policy path의 `kustomization.yaml`이 선택한 파일만 적용
- `directory`: policy path에 `directory.recurse=true`를 설정해 하위 YAML을 모두 적용

기능별 Application YAML은 두지 않는다. 신규 release는 `release.yaml`을
추가하면 ApplicationSet이 Argo `Application`을 생성한다. Karmada 설치,
member join, kubeconfig와 credential은 이 디렉터리가 관리하지 않는다.
