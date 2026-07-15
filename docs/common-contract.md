# 공통 소유권 계약

ScaleX 배포는 **Infra capability**, **release dependency**, **feature workload**를
분리한다.

| 계층 | 대표 리소스 | 적용 경로 |
|---|---|---|
| Infra | Cilium, Rook/Ceph, ObjectStore, StorageClass, RGW endpoint, OBC/PVC dependency | `eecs-k8s` + `*-k8s` → Tower Argo direct |
| Release dependency | Infra output을 참조하는 non-secret binding spec | Federation → Tower Argo → Karmada |
| Workload | Job, Deployment, Service, application ConfigMap | feature Helm + Federation values → Karmada |
| Placement | PropagationPolicy, OverridePolicy | Federation → Karmada |
| Runtime secret binding | Rook 생성 credential과 실제 bucket 이름 | 공통 management-plane runner → Karmada |

Feature chart는 cluster-neutral workload만 렌더링하고 기존 Secret/ConfigMap 이름을
참조한다. 각 `*-k8s`가 claim lifecycle을, Federation이 versioned RuntimeBinding을
소유하며, 공통 runner가 feature 이름과 무관하게 Infra provisioning 출력을
정규화한다. Secret 값은 Git에 저장하지 않는다.

새 feature는 별도 bridge script를 만들지 않는다. `runtime-binding.yaml`의
`sourceCluster`가 secure member kubeconfig directory의 파일을 선택하며, 현재 공통
adapter는 `rook-obc-s3/v1alpha1`만 지원한다.

Tower Argo의 Federation destination은 `karmada` 하나다. Karmada가 Push mode로 B/C에
복제하며 Argo가 같은 member 리소스를 직접 관리하지 않는다. 선언·render 성공은
runtime 성공 증거가 아니므로 ResourceBinding, member workload와 HTTP 결과를 별도로
관찰한다.

Cluster-scoped resource나 공유 operator는 Infra Layer에 먼저 설치한다. Federation은
그 capability를 소비하는 namespaced instance만 생성한다.
