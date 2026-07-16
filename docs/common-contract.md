# 공통 소유권 계약

| 계층 | 소유 대상 | 배포 경로 |
|---|---|---|
| `eecs-k8s` + `*-k8s` | CNI/CSI, Ceph/RGW, workload namespace, OBC/PVC와 runtime dependency | Tower Argo direct |
| feature repository | source, image, workload Helm template, PropagationPolicy/OverridePolicy | Federation을 통해 Karmada API |
| `scalex-federation` | 활성 release, exact revision, namespace와 최소 values | Tower Argo |
| Tower Karmada | policy 해석, ResourceBinding/Work와 member 복제본 | Push mode |

Feature chart는 dependency를 생성하지 않고 Infra가 제공한 이름이나 endpoint를 values로
소비한다. Secret 값은 Git에 저장하지 않는다. 교차 cluster credential이 필요하면
External Secrets 또는 승인된 management-plane binding이 선행되어야 한다.

동일한 `cluster + namespace + apiVersion/kind + name`에는 writer가 하나만 있어야 한다.
Infra dependency와 feature workload는 같은 namespace에 존재할 수 있지만 서로 다른
resource identity와 owner를 가져야 한다.

Federation ApplicationSet은 Karmada source namespace만 만들고 member namespace를 자동
전파하지 않는다. `ResourceBinding`과 `ClusterResourceBinding` 허용은 관찰을 위한 것이며
Federation이 생성 리소스를 직접 선언하거나 수정한다는 의미가 아니다.
