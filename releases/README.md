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
      ├─ dependencies/      # release-scoped claim·비밀이 아닌 binding 명세
      └─ policy/
         ├─ propagation/    # member placement
         └─ overrides/      # Karmada 복제본의 cluster별 차이
```

| 경로 | 소유하는 것 | 소유하지 않는 것 |
|---|---|---|
| `release.yaml` | namespace, exact chart URL/path/SHA, values/dependency/policy 경로 | mutable branch/tag |
| `values.yaml` | image tag+digest, workload 설정, 기존 Secret/ConfigMap 이름 | credential 값, cluster placement |
| `dependencies/` | OBC/PVC 같은 release-scoped claim, non-secret binding specification | CNI/CSI/ObjectStore/StorageClass, workload, Secret, Karmada policy |
| `policy/propagation/` | workload와 claim의 B/C placement | workload manifest |
| `policy/overrides/` | Karmada가 소유한 복제본의 cluster별 endpoint·Service 차이 | Argo direct Infra 수정 |

`dependencies/`는 Helm chart에 넣기 어려운 임의 manifest 저장소가 아니다. 다음 조건을
모두 만족하는 **release lifecycle dependency**만 둔다.

1. 기능 전용 namespace에 속한다.
2. 해당 release와 함께 생성·폐기된다.
3. 기존 Infra capability를 소비할 뿐 Infra 자체를 구성하지 않는다.
4. credential 원문을 포함하지 않는다.

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

- `eecs-k8s`와 `*-k8s`: Rook/Ceph, ObjectStore, bucket StorageClass, RGW endpoint 제공
- Federation dependency: 기능 namespace의 OBC와 non-secret binding 명세 선언
- Feature Helm: 정규화된 runtime Secret/ConfigMap 이름만 참조
- 관리-plane script: member Rook의 OBC 출력 Secret/ConfigMap을 읽어 Karmada runtime
  Secret/ConfigMap으로 정규화
- Karmada: workload의 `propagateDeps: true`로 필요한 runtime dependency를 B/C에 전달

현재 POC의 고정 bucket 이름은 기존 데이터를 보존하는 migration compatibility다.
새 release는 특별한 호환 사유가 없다면 Rook이 이름을 생성하도록 설계하고, 실제
`BUCKET_NAME`은 binding script가 OBC ConfigMap에서 읽어 전달한다.

## CI promotion

Feature CI는 build/test/scan/publish 후 다음을 하나의 Federation PR에서 갱신한다.

1. `release.yaml.source.revision`: 검증된 chart commit SHA
2. `values.yaml.images.<component>`: 함께 동작하는 모든 image의 tag+digest

CI는 child cluster나 Karmada API를 직접 수정하지 않는다. merge된 Git commit이
배포·rollback의 원자 단위다.

## 현재 active release

- `poc/rgw-analysis-web`: B RGW 입력 → C 분석 → B nginx 결과 제공
