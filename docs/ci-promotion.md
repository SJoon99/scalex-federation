# CI와 promotion

Feature CI는 build/test/scan 후 immutable image와 Helm chart revision을 발행한다. 그 뒤
Federation PR에서 해당 release의 두 파일만 변경한다.

```text
release.yaml  → source.revision, state
values.yaml   → feature chart가 정의한 환경별 runtime override
```

Federation CI는 기능 구현을 다시 테스트하지 않고 다음 admission 경계만 확인한다.

- AppProject에 허용된 source URL과 full commit SHA
- release 디렉터리와 descriptor identity
- namespace 및 Application 이름 중복
- 활성 chart의 Helm render 성공
- 활성 chart가 최소 하나의 PropagationPolicy를 렌더링
- 모든 렌더링 리소스가 정확히 하나의 PropagationPolicy에 선택됨
- policy selector가 실제 렌더링 리소스를 참조함
- Secret/OBC/cluster-scoped/Cluster*Policy 미포함
- workload image가 최종 렌더 결과에서 immutable digest를 사용함
- Federation에 `policy/` 또는 `dependencies/` 재도입 금지

이미지 기본값은 feature chart 안에 있을 수도 있고 `values.yaml` override로 제공될 수도 있다.
Federation은 특정 values key 구조를 강제하지 않고, 최종 Helm render가 immutable image를
사용하는지를 검증한다. 따라서 배포 결과의 기준은 `source.revision + values.yaml` 조합이다.

CI는 cluster에 직접 apply하거나 자동 merge하지 않는다. merge된 release commit이 승격과
rollback의 기준이다.
