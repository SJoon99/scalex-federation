# releases

기능 repository별 배포 승격 상태를 release 단위로 관리한다.

```text
releases/<feature-repository-name>/
├─ release.yaml
├─ runtime-values.yaml
└─ values.yaml
```

`release.yaml`은 source와 lifecycle만 선언하는 **Git descriptor**다. Kubernetes API에
apply하는 Custom Resource가 아니며, ApplicationSet Git generator가 일반 YAML 데이터로
읽어 실제 Argo `Application`을 생성한다. 문서 유형은 `releases/<feature>/release.yaml`
경로와 필수 필드 계약으로 구분한다.

`runtime-values.yaml`은 사람이 관리하는 placement, endpoint와 dependency reference를
담는다. 파일이 없으면 빈 override로 취급한다. `values.yaml`은 Tekton promotion이
관리하는 image repository/tag/digest/sourceRevision만 담으며 generated values가 마지막에
적용된다. Karmada policy와 dependency manifest는 이 디렉터리에 두지 않는다.

`source.revision`은 선택적인 사용자 pin이다. 존재하면 항상 우선한다. 생략한 tracking
release는 `promotion.resolvedRevision`의 최신 성공 후 승인·merge된 CI SHA를 사용한다. `state: active`인
release는 두 값 중 하나로 effective revision을 제공해야 한다.

`state` 값:

- `disabled`: ApplicationSet이 제외한다. chart/dependency/cutover 준비 단계다.
- `active`: Application을 생성한다. 활성 chart는 workload와 PropagationPolicy를 함께
  렌더링해야 한다.

새 release를 만들 때 디렉터리명, descriptor `name`, namespace와 source repository 이름을
같은 기능 repo 식별자로 맞춘다. values path도 해당 디렉터리를 정확히 가리켜야 한다.

현재 `releases/` 바로 아래에는 release 11개가 있다. `temp-poc`만 승인·merge된 성공 CI SHA와
Karmada policy를 검증해 `state: active`로 승격했으며, AppProject의 `scalex-*` namespace
경계에 맞춰 `scalex-temp-poc`에 배포한다. 나머지 예시는 전용 repo와 immutable chart
SHA를 준비하기 전까지 활성화하지 않는다.
