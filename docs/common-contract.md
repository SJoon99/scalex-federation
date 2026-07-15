# 소유권 계약

| 계층 | 책임 |
|---|---|
| feature repository | source, image, Helm workload, PropagationPolicy/OverridePolicy |
| `scalex-federation` values | feature repo 등록, immutable revision, 활성 상태, 선택적 최소 override |
| `scalex-federation` Helm templates | AppProject와 repo별 Argo Application 렌더링 |
| `eecs-k8s` + `*-k8s` | CNI/CSI, storage, bucket/OBC, runtime Secret/ConfigMap 등 Infra dependency |
| Tower Argo | Federation chart 및 생성된 child Application reconcile |
| Tower Karmada | policy 해석 후 member cluster에 Push |

## 파생 identity

repo basename을 단일 identity로 사용한다.

```text
repo: https://github.com/SJoon99/scalex-feature-example.git
name/namespace/Helm releaseName: scalex-feature-example
```

별도 name, namespace, destination을 values에 반복하지 않는다. 모든 feature Application은
고정된 `karmada` destination을 사용한다.

## 단일 writer

Argo direct Infra 경로와 Federation/Karmada 경로가 동일한
`cluster + namespace + apiVersion/kind + name`을 함께 소유하지 않는다. Cluster-scoped
operator와 CRD는 Infra Layer가 소유하고, feature chart는 namespaced workload와 policy를
소유한다.
