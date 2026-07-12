# bootstrap

Tower Argo CD가 `scalex-federation`의 release를 발견하고 동기화하기 위한 GitOps 진입점을 둔다.

향후 포함할 수 있는 항목:

- Federation 전용 `AppProject`
- Karmada API를 destination으로 사용하는 Argo `Application`
- 여러 release를 묶는 root Application 또는 ApplicationSet

이 디렉터리는 Karmada 설치나 member join을 담당하지 않는다. Cluster credential, kubeconfig, token도 저장하지 않는다.
