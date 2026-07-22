# CI와 promotion

Feature CI는 build/test/scan 후 immutable image와 exact source SHA를 발행한다. 별도
promotion Pipeline이 Federation branch와 PR을 만들며 main에는 직접 push하지 않는다.

```text
release.yaml        → 사용자 pin 또는 latest promoted successful resolvedRevision
runtime-values.yaml → 사람이 관리하는 runtime override
values.yaml         → Tekton이 관리하는 image identity
```

Tower Tekton과 Federation 승격 PR review는 다음 경계를 확인해야 한다.

- AppProject에 허용된 source URL과 effective full commit SHA
- release 디렉터리와 descriptor identity
- namespace 및 Application 이름 중복
- 활성 chart의 Helm render 성공
- 활성 chart가 최소 하나의 PropagationPolicy를 렌더링
- 모든 렌더링 리소스가 정확히 하나의 PropagationPolicy에 선택됨
- policy selector가 실제 렌더링 리소스를 참조함
- Secret/OBC/cluster-scoped/Cluster*Policy 미포함
- workload image가 최종 렌더 결과에서 immutable digest를 사용함
- Federation에 `policy/` 또는 `dependencies/` 재도입 금지

`source.revision`이 있으면 사용자 pin으로 항상 우선한다. 없으면
`promotion.resolvedRevision`의 최신 성공 후 PR로 승인·merge된 CI SHA를 사용한다. Tekton은 `values.yaml`의
repository/tag/digest/sourceRevision을 결정적으로 갱신하며 runtime 설정은 별도 파일에
보존한다. 따라서 배포 결과의 기준은 `effective revision + generated values` 조합이다.

Promotion Pipeline은 cluster에 직접 apply하거나 자동 merge하지 않고 Federation PR만
생성한다. merge된 release commit이 승격과 rollback의 기준이다.
