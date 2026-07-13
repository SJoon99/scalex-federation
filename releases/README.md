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
      └─ karmada/
         ├─ kustomization.yaml   # renderer=kustomize일 때만 사용
         ├─ propagation/
         └─ overrides/
```

- `release.yaml`: ApplicationSet이 읽는 chart 좌표, immutable revision,
  namespace, policy 경로와 renderer
- `values.yaml`: image revision, endpoint, object path 등 runtime desired state
- `propagation/`: component를 member cluster에 배치하는 정책
- `overrides/`: Karmada가 소유하는 workload 복제본의 cluster별 차이

실제 image/chart blob은 Registry에 두며 이 디렉터리에는 artifact 좌표만
기록한다.

## Policy renderer 선택

Release마다 다음 두 방식 중 하나를 선택한다.

### Kustomize — 적용 파일을 명시적으로 선택

```yaml
policy:
  path: releases/poc/example/karmada
  renderer: kustomize
```

`policy.path`에 `kustomization.yaml`을 두고 `resources`에 적용할 파일을
명시한다. 파일이 디렉터리에 추가돼도 자동 적용되지 않으므로 운영 release의
기본값으로 권장한다.

### Directory — 하위 YAML을 재귀적으로 모두 적용

```yaml
policy:
  path: releases/dev/example/karmada
  renderer: directory
```

ApplicationSet이 해당 source에 `directory.recurse: true`를 생성한다. 지정한
경로 아래의 `*.yaml`, `*.yml`이 모두 적용되므로 작은 실험용 release에는
간결하지만, 문서용 YAML이나 미완성 manifest도 배포될 수 있다.

Directory 경로에는 `kustomization.yaml`이나 `Chart.yaml`을 함께 두지 않는다.
두 renderer를 하나의 release에서 동시에 사용하는 것이 아니라, release별로
둘 중 하나를 선택한다.
