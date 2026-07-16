# 실행 절차

1. feature repository에서 workload와 namespaced Karmada policy를 하나의 Helm chart로
   렌더링한다.
2. workload image를 immutable digest로 고정한다.
3. `bootstrap/appproject.yaml`과 `contracts/children.yaml`에 exact repository와 chart
   path를 등록한다.
4. `releases/<repository>/release.yaml`과 `values.yaml`을 만든다.
5. Infra dependency와 member namespace는 대상 `*-k8s` repository에서 준비한다.
6. 로컬 검증 후 `state: active`로 승격한다.

```bash
PATH=/path/to/yq:$PATH \
FEATURE_REPOS_ROOT=/path/to/checkouts \
./scripts/validate.sh
```

검증은 descriptor schema, source enrollment, chart SHA, Helm lint/render, namespace 경계,
Karmada selector coverage, namespaced RBAC와 image digest를 확인한다. CI나 feature
repository가 child cluster에 직접 apply하지 않으며, merge된 desired state만 Tower
Argo와 Karmada가 배포한다.
