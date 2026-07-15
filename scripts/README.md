# scripts

검증과 승인된 management-plane 보조 작업을 반복 가능하게 만든다. CI 검증 script와
runtime mutation script의 경계를 명확히 유지한다.

## 주요 script

| 파일 | 역할 | cluster write |
|---|---|---|
| `validate.sh` | descriptor/source/chart/dependency/policy/image 계약 검증 | 없음 |
| `rgw-analysis-web/verify-public-images.sh` | image tag가 선언 digest를 가리키는지 검증 | 없음 |
| `rgw-analysis-web/observe-release.sh` | Karmada placement, B/C workload, HTTP read-only 관찰 | 없음 |
| `sync-object-storage-binding.sh` | B Rook OBC 출력 → Karmada runtime Secret+ConfigMap 동기화 | Karmada binding만 |
| `bootstrap-cuty-rgw-credentials.sh` | 향후 Smurf/Cuty 호환 실험용 | 별도 승인 필요 |

## Storage binding 원리

```text
Karmada ConfigMap/rgw-analysis-web-storage-binding   # non-secret mapping
B Secret/rgw-analysis-web-bucket                    # Rook credential
B ConfigMap/rgw-analysis-web-bucket                 # actual BUCKET_NAME
                     ↓
sync-object-storage-binding.sh
                     ↓
Karmada Secret/rgw-analysis-web-s3
Karmada ConfigMap/rgw-analysis-web-runtime
```

스크립트는 idempotent server-side apply를 사용하고 credential을 명령 인자나 로그에
노출하지 않는다. 최초 provisioning과 OBC credential/bucket 재생성 시 실행한다.
workload나 policy를 직접 배포하지 않으며 Argo/Karmada desired-state 경로를 우회하지
않는다.

전용 controller는 현재 도입하지 않는다. 지속 reconciliation이나 자동 rotation SLA가
필요해질 때 동일 binding 계약을 External Secrets/controller가 구현하도록 교체한다.

`validate.sh`는 source repository가 Federation과 같은 상위 디렉터리 아래 checkout되어
있다고 가정한다. 다르면 `FEATURE_REPOS_ROOT`를 지정한다. chart는 working tree가 아니라
`release.yaml`의 pinned commit에서 export해 검증한다. `check-jsonschema`는 0.33.3을
사용한다.
