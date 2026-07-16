# bootstrap

Tower Argo CD가 활성 release를 발견하는 고정 진입점이다.

| 파일 | 역할 |
|---|---|
| `appproject.yaml` | 허용 source, `karmada` destination, namespaced kind와 Binding 관찰 경계 |
| `applicationset.yaml` | `releases/*/release.yaml` 중 `state=active`인 release별 Application 생성 |

각 Application은 source 두 개를 사용한다.

1. feature repository의 pinned Helm chart
2. Federation repository의 release별 `values.yaml` reference

Workload와 `PropagationPolicy`/`OverridePolicy`는 같은 feature chart revision에서 함께
렌더링된다. ApplicationSet은 `CreateNamespace=true`를 사용하지만 Karmada source
namespace에 skip-auto-propagation label을 설정하므로 member namespace는 Infra가
계속 소유한다.
