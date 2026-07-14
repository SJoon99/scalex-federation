# bootstrap

Tower Argo CD가 Federation release를 발견하는 고정 진입점이다.

- `appproject.yaml`: Federation source와 Karmada destination 경계,
  Karmada Binding 자식 리소스 표시를 위한 허용 범위
- `applicationset.yaml`: `releases/*/*/release.yaml` 자동 발견

Tower root Application은 이 디렉터리의 두 manifest를 plain directory로 읽는다.
하위 manifest가 없으므로 bootstrap에는 재귀 탐색이 필요하지 않다.
ApplicationSet은 각 release의 `policy.path`에 `directory.recurse=true`를
적용하므로 `karmada/` 아래 Kubernetes YAML은 모두 배포 대상이다. 문서용
YAML이나 미완성 manifest는 이 경로에 두지 않는다.
`dependencies.path`도 plain directory로 재귀 처리하며, 현재 POC에서는 Federation이
소유하는 `ExternalSecret`만 둔다. Feature chart source는 `renderer: helm/v1` 계약에
따라 exact repository/path/full SHA에서 읽는다.

기능별 Application YAML은 두지 않는다. 신규 release는 `release.yaml`을
추가하면 ApplicationSet이 Argo `Application`을 생성한다. Karmada 설치,
member join, kubeconfig와 credential은 이 디렉터리가 관리하지 않는다.
