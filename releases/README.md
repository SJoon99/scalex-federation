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
      ├─ values.yaml
      └─ karmada/
```
