# bootstrap

Tower Argo CD가 Federation release를 발견하는 고정 진입점이다.

| 파일 | 역할 |
|---|---|
| `appproject.yaml` | 허용 source, Karmada destination, namespaced resource 경계 |
| `applicationset.yaml` | `releases/*/*/release.yaml`을 발견해 release별 Application 생성 |

Tower root Application이 이 두 manifest를 한 번 읽는다. 이후 ApplicationSet은 각
release를 다음 세 source로 구성한다.

1. feature Helm chart + Federation `values.yaml`
2. Federation `policy/` Karmada policy directory
3. Federation `dependencies/` plain-YAML directory

policy와 dependency source는 `directory.recurse=true`이므로 별도 Kustomize entrypoint나
기능별 Application YAML이 필요 없다. `release.yaml` 추가가 release 등록 단위다.

bootstrap은 다음을 관리하지 않는다.

- Karmada 설치와 member join
- Argo cluster/repository credential
- private key 또는 runtime Secret 값
- management-plane binding script 실행

최초 root Application, `karmada` destination credential, private repository credential은
여전히 운영 bootstrap 경계다.
