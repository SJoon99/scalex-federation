# releases

환경별 배포 승격 상태를 release 단위로 관리한다.

```text
releases/<environment>/<release>/
├─ release.yaml
└─ values.yaml
```

`release.yaml`은 source와 lifecycle만 선언하고 `values.yaml`은 feature chart에 전달할
환경별 override만 담는다. Karmada policy와 dependency manifest는 이 디렉터리에 두지
않는다.

`state` 값:

- `disabled`: ApplicationSet이 제외한다. chart/dependency/cutover 준비 단계다.
- `active`: Application을 생성한다. 활성 chart는 workload와 PropagationPolicy를 함께
  렌더링해야 한다.

새 release를 복사할 때 경로의 environment/name, descriptor 값, namespace와 values path가
서로 정확히 일치해야 한다.

현재 `poc`에는 구조 비교를 위한 release 10개가 실제 디렉터리로 존재하며 모두
`state: disabled`다. 전용 feature chart가 없는 항목은 임시 source를 실제 source로
교체하기 전까지 활성화하지 않는다.
