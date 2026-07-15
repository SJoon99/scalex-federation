# releases

기능 repository별 배포 승격 상태를 release 단위로 관리한다.

```text
releases/<feature-repository-name>/
├─ release.yaml
└─ values.yaml
```

`release.yaml`은 source와 lifecycle만 선언하고 `values.yaml`은 feature chart에 전달할
최소 배포 override만 담는다. Karmada policy와 dependency manifest는 이 디렉터리에 두지
않는다.

`state` 값:

- `disabled`: ApplicationSet이 제외한다. chart/dependency/cutover 준비 단계다.
- `active`: Application을 생성한다. 활성 chart는 workload와 PropagationPolicy를 함께
  렌더링해야 한다.

새 release를 만들 때 디렉터리명, descriptor `name`, namespace와 source repository 이름을
같은 기능 repo 식별자로 맞추고 values path도 해당 디렉터리를 정확히 가리켜야 한다.

현재 `releases/` 바로 아래에는 repo 이름을 사용한 release 10개가 있으며 모두
`state: disabled`다. `scalex-feature-poc` 이외의 예시는 전용 repo와 immutable chart SHA를
준비하기 전까지 활성화하지 않는다.
