# rgw-analysis-web POC

B의 Object Storage 데이터를 C에서 분석하고, 결과를 다시 B의 nginx로 제공하는
멀티클러스터 vertical slice다.

## 리소스와 소유권

```text
B Infra (*-k8s + eecs-k8s)
├─ CephObjectStore/scalex-poc
├─ StorageClass/ceph-bucket
└─ RGW endpoint/10.33.142.10

Federation release
├─ dependencies/ObjectBucketClaim/rgw-analysis-web-bucket → B
├─ dependencies/ConfigMap/rgw-analysis-web-storage-binding → Karmada only
├─ Job/dataset-seeder → B
├─ Job/analyzer → C
└─ Deployment+Service/result-web → B

Feature Helm
└─ 위 workload만 렌더링하고 기존 runtime Secret/ConfigMap을 소비
```

`object-storage-binding`은 credential이 아니라 source/target 리소스 이름, endpoint,
region만 담는 선언이다. `scripts/sync-object-storage-binding.sh`가 B의 Rook 생성
Secret과 ConfigMap을 읽어 Karmada에 다음 형태로 정규화한다.

```text
Secret/rgw-analysis-web-s3
├─ AWS_ACCESS_KEY_ID
└─ AWS_SECRET_ACCESS_KEY

ConfigMap/rgw-analysis-web-runtime
├─ S3_ENDPOINT_URL
├─ S3_BUCKET
└─ AWS_DEFAULT_REGION
```

Karmada는 workload policy의 `propagateDeps: true`를 통해 이 두 dependency를
workload와 같은 member에 전달한다. key 값은 Git, Helm values, 로그에 저장하지 않는다.

## 안전한 적용 순서

1. Argo가 dependency OBC·binding 명세와 Karmada policy를 sync한다.
2. B에서 OBC가 `Bound`되고 같은 이름의 Secret/ConfigMap이 생겼는지 확인한다.
3. management plane에서 `sync-object-storage-binding.sh`를 실행한다.
4. Karmada runtime Secret/ConfigMap이 생성되고 B/C에 `FullyApplied`인지 확인한다.
5. release를 다시 sync하여 one-shot Job을 재실행하고 결과 HTTP를 검증한다.

스크립트는 idempotent server-side apply이므로 OBC credential/bucket이 재생성된 경우
다시 실행할 수 있다. 현재 규모에서는 전용 controller를 두지 않는다. release 수,
rotation 빈도 또는 자동복구 SLA가 커지면 External Secrets나 전용 reconciler로
교체한다.

## 기존 bucket 호환 규칙

현재 OBC는 `bucketName: rgw-analysis-web-poc`을 유지한다. 이는 기존 POC 데이터를
삭제하거나 새 bucket으로 복사하지 않고 소유권만 feature chart에서 Federation
`dependencies/`로 넘기기 위한 예외다. ObjectBucket의 reclaim policy는 `Retain`이며,
명시적인 데이터 삭제 결정 없이 OBC/ObjectBucket을 삭제하지 않는다.
