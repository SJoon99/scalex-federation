# contracts

Infra Layer, feature repository, Federation과 Karmada 사이의 소유권 계약이다.

## 책임 표

| 계층 | 소유하는 것 | 금지되는 것 |
|---|---|---|
| `eecs-k8s` + `*-k8s` | CNI/CSI, Rook/Ceph, ObjectStore, StorageClass, RGW endpoint, OBC 등 외부 dependency | workload |
| feature repository | source, image build, cluster-neutral Helm workload, binding reference | cluster 이름, policy, OBC, Secret 값 |
| Federation dependency | Infra output을 가리키는 non-secret binding 명세 | OBC/PVC, platform Infra, workload, credential |
| Federation policy | placement와 Karmada-owned replica override | Argo direct Infra patch |
| common binding runner | 모든 versioned binding 발견, source member 출력 → Karmada runtime object 정규화 | feature 이름 하드코딩, 임의 Secret 복사 |
| Karmada | B/C workload 복제본과 dependency propagation | Infra Layer 공동 소유 |

## 핵심 불변식

1. 동일한 `cluster + namespace + apiVersion/kind + name`을 Argo direct와 Karmada가
   동시에 소유하지 않는다.
2. cluster-scoped resource는 Infra Layer가 소유한다.
3. User/Dev resource는 release 전용 `scalex-*` namespace를 사용한다.
4. Feature chart는 member 이름과 Karmada policy를 모른다.
5. Secret 값은 Git·Helm values·프로세스 인자·로그에 넣지 않는다.
6. chart commit은 full SHA, image는 tag+digest로 고정한다.

## Object-storage dependency 계약

```text
Infra ObjectStore + StorageClass + ObjectBucketClaim
            ↓ source member Rook produces
        Secret + ConfigMap
            ↓ common management-plane runner
Karmada normalized Secret + ConfigMap
            ↓ workload propagateDeps
          target members
            ↓ consumes
       feature Helm workload
```

OBC는 namespace-scoped Kubernetes claim이지만 실제 bucket 이름은 Object Store의 전역
영역일 수 있으므로 대상 `*-k8s` Infra가 이름과 lifecycle을 단독 소유한다. 현재
`rgw-analysis-web-poc` 고정 이름은 기존 데이터 보존을 위한 명시적 예외다.

`dependencies/runtime-binding.yaml`에는 type/version, 이름과 endpoint 같은 non-secret
계약만 둔다. runner는 source OBC ConfigMap에서 실제 `BUCKET_NAME`을 읽으므로 새 release가
생성형 bucket 이름을 사용해도 feature values를 다시 렌더링할 필요가 없다.

`rook-obc-s3/v1alpha1`은 Rook이 생성하는 정해진 key만 읽어 normalized S3
Secret/ConfigMap을 만든다. 사용자가 임의 Secret, jq expression 또는 output template을
지정하는 범용 복사 기능은 제공하지 않는다. source/target namespace를 binding
namespace로 제한하고 target identity 중복도 거부한다.

## Script와 controller 선택 기준

현재는 공통 runner의 `--all`이 여러 release와 source cluster를 처리하며, credential
변경 빈도가 낮아 명시적 실행이 최소 복잡도다. 다음 중 하나가 필요해질 때만 Tower
CronJob/controller/External
Secrets 도입을 검토한다.

- 다수 release의 지속 reconciliation
- 자동 credential rotation
- 장애 후 무인 self-healing SLA
- source member가 여러 개라 event-driven 동기화가 필요한 경우

## Placement와 override

- member 선택은 `PropagationPolicy`에서만 한다.
- `OverridePolicy`는 Karmada가 소유하는 release 복제본만 수정한다.
- OBC는 source member의 Infra GitOps 경로에서만 관리한다.
- runtime Secret/ConfigMap은 workload가 참조하며 `propagateDeps: true`로 전달한다.
- B/C Infra 리소스는 Federation override 대상으로 삼지 않는다.
