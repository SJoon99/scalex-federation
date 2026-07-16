# releases

기능 repository별 배포 승격 상태를 release 단위로 관리한다.

```text
releases/<feature-repository-name>/
├─ release.yaml
└─ values.yaml
```

`release.yaml`은 Kubernetes Custom Resource가 아니라 ApplicationSet Git generator가
읽는 descriptor다. `name`, `namespace`, `state`, pinned Helm source, values path와
promotion mode를 선언한다.

`values.yaml`은 feature chart에 전달할 배포 override다. credential 원문과 Infra
dependency manifest는 둘 수 없다. Workload와 namespaced Karmada policy는 feature
chart가 소유하므로 release directory에 `policy/`나 `dependencies/`를 만들지 않는다.

- `disabled`: ApplicationSet에서 제외한다.
- `active`: Application을 생성한다. chart는 workload와 `PropagationPolicy`를 함께
  렌더링하고 workload image를 digest로 고정해야 한다.

현재 release는 다음 두 개다.

- `temp-poc`: active, B → C → B HTTP multi-cluster POC
- `scalex-feature-poc`: 기존 main 설정값 보존, policy 미지원으로 disabled
