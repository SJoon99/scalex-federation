# bootstrap

Tower Argo CD가 Federation release를 발견하는 고정 진입점이다.

- `appproject.yaml`: Federation source와 Karmada destination 경계
- `applicationset.yaml`: `releases/*/*/release.yaml` 자동 발견
- `kustomization.yaml`: Tower root Application이 동기화하는 경로

기능별 Application YAML은 두지 않는다. 신규 release는 `release.yaml`을
추가하면 ApplicationSet이 Argo `Application`을 생성한다. Karmada 설치,
member join, kubeconfig와 credential은 이 디렉터리가 관리하지 않는다.
