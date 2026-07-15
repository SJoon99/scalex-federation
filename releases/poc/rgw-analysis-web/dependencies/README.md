# dependencies

이 디렉터리는 `rgw-analysis-web`이 Infra dependency를 소비하는 데 필요한
**non-secret runtime binding**만 plain YAML로 선언한다. ApplicationSet이 디렉터리를
재귀적으로 읽으므로 여기에 있는 YAML은 Karmada API에 적용된다.

## 현재 파일

| 파일 | 역할 | 실제 배치 |
|---|---|---|
| `runtime-binding.yaml` | B Infra OBC output과 workload runtime object 사이의 versioned `rook-obc-s3` non-secret 매핑 | Karmada API에만 유지 |

binding ConfigMap 자체는 B/C에 배포할 애플리케이션 설정이 아니다. 공통 management-plane
runner가 label로 이를 발견해 `sourceCluster`의 kubeconfig를 선택하고, Rook 출력
Secret+ConfigMap을 정규화한 target Secret+ConfigMap을
Karmada에 만든다.

## 허용 규칙

- non-secret binding 명세만 허용
- OBC/PVC, Secret/ExternalSecret, workload, Karmada policy, cluster-scoped resource 금지
- CNI/CSI/CephObjectStore/StorageClass/RGW Service 등 Infra 구성 금지
- `kustomization.yaml`, Helm chart, 문서용 YAML 금지
- credential 또는 kubeconfig 값 금지
- source/target namespace는 binding namespace와 동일
- 지원 type/version 외 임의 resource/key mapping 금지
- 새 feature를 위한 별도 sync/bootstrap script 금지

source OBC와 고정 bucket 이름의 lifecycle은 `b-k8s`가 소유한다.
