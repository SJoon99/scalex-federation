# argocd

Tower Argo CD가 활성 release를 발견하는 고정 진입점이다.

| 파일 | 역할 |
|---|---|
| `appproject.yaml` | 허용 source, `karmada` destination, namespaced kind 경계 |
| `applicationset.yaml` | `releases/*/release.yaml` 중 `state=active`인 기능 repo별 Application 생성 |

Application은 source 두 개만 사용한다.

1. feature repository의 Helm chart
2. Federation repository의 release별 `values.yaml` reference

Karmada policy는 첫 번째 source인 feature chart가 렌더링한다. Federation의 별도
`policy/`, `dependencies/`, Kustomize source는 존재하지 않는다.

ApplicationSet의 Git generator와 values source는 모두 운영 branch인 `main`을 읽는다.
