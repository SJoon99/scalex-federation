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
         ├─ kustomization.yaml
         ├─ propagation/
         └─ overrides/
```

- `release.yaml`: ApplicationSet이 읽는 chart 좌표, immutable revision,
  namespace와 policy 경로
- `values.yaml`: image revision, endpoint, object path 등 runtime desired state
- `propagation/`: component를 member cluster에 배치하는 정책
- `overrides/`: Karmada가 소유하는 workload 복제본의 cluster별 차이

실제 image/chart blob은 Registry에 두며 이 디렉터리에는 artifact 좌표만
기록한다.
