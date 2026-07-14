# releases

배포 가능한 feature/workload의 desired state를 release 단위로 관리한다.

각 release가 소유할 수 있는 항목:

- Feature chart revision
- Container image digest
- Runtime values
- 전용 namespace
- Karmada `PropagationPolicy`
- Karmada `OverridePolicy`
- 환경별 배포 설정

기능 source code와 Dockerfile은 두지 않는다. CNI, CSI, StorageClass 같은 Infra 리소스도 두지 않는다.

예상 형태:

```text
releases/
└─ <environment>/
   └─ <release-name>/
      ├─ release.yaml
      ├─ values.yaml
      ├─ dependencies/
      │  └─ *.yaml
      └─ karmada/
         ├─ propagation/
         │  └─ *.yaml
         └─ overrides/
            └─ *.yaml
```

- `release.yaml`: `scalex.io/v1alpha1` `FederationRelease` identity,
  `renderer: helm/v1`, exact source URL/path/revision, values/dependency/policy 경로와
  `tracked|pinned` promotion mode
- `values.yaml`: 여러 image의 immutable digest, endpoint, object path 등 runtime desired state
- `propagation/`: component를 member cluster에 배치하는 정책
- `overrides/`: Karmada가 소유하는 workload 복제본의 cluster별 차이

실제 image/chart blob은 Registry에 두며 이 디렉터리에는 artifact 좌표만
기록한다.

## 현재 active releases

- `poc/rgw-analysis-web`: 기존 Application identity와
  `scalex-rgw-analysis-web` namespace, B/C placement policy, POC RGW credential
  경계를 유지하면서 feature chart와 runtime image는 `smurf-child` 구현을 사용한다.

현재 active release는 하나다. 별도의 `cuty/rgw-analysis-web` Application을 만들지
않으며, `poc/rgw-analysis-web`의 source SHA와 `flow`/`web` image digest를 한 묶음으로
고정한다.

## Policy 적용 규칙

ApplicationSet은 `policy.path`에 항상 `directory.recurse=true`를 적용한다.
따라서 `karmada/` 아래의 `*.yaml`, `*.yml`은 별도 목록 파일 없이 모두
Karmada API에 동기화된다.

- `karmada/propagation/`: `PropagationPolicy`만 저장
- `karmada/overrides/`: `OverridePolicy`만 저장
- `karmada/`에는 `kustomization.yaml`, `Chart.yaml`, 일반 설정 YAML을 두지 않음
- 설명 문서는 release root의 Markdown에 기록
- 모든 policy는 release namespace를 사용

## CI promotion

Feature repository의 CI는 build/test/scan/publish를 끝낸 뒤 이 디렉터리만
변경하는 Pull Request를 만든다.

1. `release.yaml.source.revision`을 검증된 feature commit SHA로 갱신
2. `values.yaml.images.<component>`의 모든 변경 image를 digest로 갱신
3. 하나의 기능에서 여러 image가 생성되면 같은 commit에서 모두 함께 갱신
4. Federation 검증 통과 후 merge하며 cluster에는 직접 배포하지 않음

이미지 개수와 component 이름은 feature마다 달라도 된다. `images` map 전체가
하나의 release 단위로 승격되므로 chart와 여러 image의 조합이 Git commit 하나로
추적되고 rollback된다.

`poc/rgw-analysis-web`은 CI 도입 전 수동 검증 단계에서 exact Smurf child commit과
Docker Hub `flow`/`web` digest를 `pinned` mode로 고정한다. 자동 promotion은 아직
적용하지 않으며, Argo/Karmada 동작 확인 후 GHCR publication을 도입할 때 canonical
`sha-<commit>` image 좌표와 `tracked` mode로 전환한다.
