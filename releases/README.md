# releases

배포 가능한 feature/workload의 desired state를 **release 단위**로 관리한다.
기능 소스나 Infra 구현이 아니라, 검증된 artifact를 어떤 runtime 계약과 placement로
실행할지를 선언하는 디렉터리다.

## 구조와 역할

```text
releases/
└─ <environment>/
   └─ <release-name>/
      ├─ release.yaml       # source SHA와 각 source 경로
      ├─ values.yaml        # workload values와 기존 binding 이름
      ├─ dependencies/      # 비밀이 아닌 runtime binding 명세
      └─ policy/
         ├─ propagation/    # member placement
         └─ overrides/      # Karmada 복제본의 cluster별 차이
```

| 경로 | 소유하는 것 | 소유하지 않는 것 |
|---|---|---|
| `release.yaml` | namespace, exact chart URL/path/SHA, values/dependency/policy 경로 | mutable branch/tag |
| `values.yaml` | image tag+digest, workload 설정, 기존 Secret/ConfigMap 이름 | credential 값, cluster placement |
| `dependencies/` | Infra가 제공한 dependency를 참조하는 non-secret binding specification | OBC/PVC, CNI/CSI/ObjectStore/StorageClass, workload, Secret, Karmada policy |
| `policy/propagation/` | workload의 B/C placement | workload 또는 Infra manifest |
| `policy/overrides/` | Karmada가 소유한 복제본의 cluster별 endpoint·Service 차이 | Argo direct Infra 수정 |

`dependencies/`는 Helm chart에 넣기 어려운 임의 manifest 저장소가 아니다. 다음 조건을
모두 만족하는 **runtime binding 명세**만 둔다.

1. credential 원문 없이 source/target identity만 선언한다.
2. Infra가 미리 제공한 dependency output을 참조한다.
3. workload나 cluster-scoped resource를 생성하지 않는다.
4. 해당 release namespace 밖의 임의 Secret을 복사하지 않는다.

## 적용 원리

ApplicationSet은 하나의 Argo Application에 세 source를 결합한다.

```text
feature Helm chart + values.yaml
              + dependencies/**/*.yaml
              + policy/**/*.yaml
                         ↓
                    Karmada API
                         ↓ Push
                      B / C
```

`dependencies.path`와 `policy.path`는 plain directory의 `recurse=true`로 읽는다.
따라서 `kustomization.yaml`이나 별도 파일 목록은 사용하지 않는다. 배포 대상이 아닌
YAML은 이 경로에 두면 안 된다.

## Object storage 규칙

- `eecs-k8s`와 `*-k8s`: Rook/Ceph, ObjectStore, bucket StorageClass, RGW endpoint와 OBC 제공
- Federation dependency: Infra OBC output을 가리키는 non-secret binding 명세만 선언
- Feature Helm: 정규화된 runtime Secret/ConfigMap 이름만 참조
- 공통 management-plane runner: member Rook의 OBC 출력 Secret/ConfigMap을 읽어 Karmada runtime
  Secret/ConfigMap으로 정규화
- Karmada: workload의 `propagateDeps: true`로 필요한 runtime dependency를 B/C에 전달

현재 POC의 고정 bucket 이름은 기존 데이터를 보존하는 B Infra migration compatibility다.
새 release의 bucket naming과 lifecycle도 대상 cluster Infra가 결정하고, 실제
`BUCKET_NAME`은 공통 RuntimeBinding runner가 Infra OBC ConfigMap에서 읽어 전달한다.

Object Storage를 사용하는 새 release는 `runtime-binding.yaml`에 다음만 선언한다.

- `contractVersion: v1alpha1`
- `bindingType: rook-obc-s3`
- source cluster/OBC identity
- target Secret/ConfigMap identity
- non-secret endpoint/region

공통 runner가 label로 모든 binding을 발견하므로 release별 script를 추가하지 않는다.
source/target namespace는 binding namespace와 같아야 하며, 같은 target identity를
여러 binding이 공유할 수 없다. target ConfigMap 이름이 binding ConfigMap 자체와 같아
선언을 덮어쓰는 구성도 거부한다.

## CI promotion

Feature CI는 build/test/scan/publish 후 다음을 하나의 Federation PR에서 갱신한다.

1. `release.yaml.source.revision`: 검증된 chart commit SHA
2. `values.yaml.images.<component>`: 함께 동작하는 모든 image의 tag+digest

CI는 child cluster나 Karmada API를 직접 수정하지 않는다. merge된 Git commit이
배포·rollback의 원자 단위다.

## 현재 active release

- `poc/rgw-analysis-web`: B RGW 입력 → C 분석 → B nginx 결과 제공
