# 소유권 계약

| 계층 | 소유 대상 | 배포 경로 |
|---|---|---|
| `eecs-k8s` + `*-k8s` | CNI/CSI, Ceph/RGW, bucket/OBC, runtime Secret·ConfigMap 등 Infra dependency | Tower Argo direct |
| feature repository | source, image, workload Helm template, PropagationPolicy/OverridePolicy template | Federation release를 통해 Karmada API |
| `scalex-federation` | 활성 release 목록, exact revision, namespace, 환경별 최소 values | Tower Argo |
| Tower Karmada | policy 해석, ResourceBinding/Work, member 복제본 | Push mode |

## Dependency 계약

Feature chart는 dependency를 생성하지 않고 이름으로 소비한다.

```yaml
s3:
  secretName: rgw-analysis-web-s3
  configMapName: rgw-analysis-web-runtime
```

개발 단계에서는 Infra가 제공한 공용 test bucket을 사용할 수 있다. 안정화 승격 전에는
각 `*-k8s` repository가 기능 전용 bucket/OBC와 credential 전달 경로를 제공해야 한다.
B에서 생성한 credential을 C workload도 사용한다면 External Secrets 또는 별도
management-plane binding 같은 안전한 교차 클러스터 전달 계층이 선행되어야 한다.

Feature workload가 Kubernetes API 권한을 필요로 하면 chart가 release namespace 안의
`Role`/`RoleBinding`을 함께 렌더링할 수 있다. `RoleBinding`은 같은 render에 포함된 local
`Role`만 참조할 수 있으며 `ClusterRole` 참조와 다른 namespace의 ServiceAccount subject는
admission에서 거부한다.

## 단일 writer 원칙

동일한 `cluster + namespace + apiVersion/kind + name`을 Argo direct와 Karmada가 동시에
관리하지 않는다. Infra dependency와 feature workload는 같은 namespace에 존재할 수
있지만 서로 다른 resource identity와 owner를 가져야 한다.
