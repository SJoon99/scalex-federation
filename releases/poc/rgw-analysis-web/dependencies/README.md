# dependencies

이 디렉터리는 `rgw-analysis-web` release가 필요로 하는 **workload 외 선행 리소스**를
plain YAML로 선언한다. ApplicationSet이 디렉터리를 재귀적으로 읽으므로 여기에 있는
모든 YAML은 Karmada API에 적용된다.

## 현재 파일

| 파일 | 역할 | 실제 배치 |
|---|---|---|
| `object-bucket-claim.yaml` | 기능 전용 bucket/credential provisioning 요청 | 정책으로 B에 Push |
| `object-storage-binding.yaml` | source OBC 출력과 target runtime binding의 non-secret 매핑 | Karmada API에만 유지 |

binding ConfigMap 자체는 B/C에 배포할 애플리케이션 설정이 아니다. management-plane
script가 이를 읽어 Rook 출력 Secret+ConfigMap을 정규화한 target Secret+ConfigMap을
Karmada에 만든다.

## 허용 규칙

- release namespace의 namespaced claim과 non-secret binding 명세만 허용
- Secret/ExternalSecret, workload, Karmada policy, cluster-scoped resource 금지
- CNI/CSI/CephObjectStore/StorageClass/RGW Service 등 Infra 구성 금지
- `kustomization.yaml`, Helm chart, 문서용 YAML 금지
- credential 또는 kubeconfig 값 금지

현재 고정 bucket 이름은 기존 POC 데이터 보존용 compatibility 예외다.
