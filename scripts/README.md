# scripts

로컬 개발과 CI에서 공통으로 사용하는 반복 가능한 검증 도구를 둔다.

예상 용도:

- Release render
- Policy/label validation
- Artifact revision 확인
- Smoke test 실행 보조

스크립트는 Argo CD를 우회해 운영 cluster에 직접 배포하는 경로로 사용하지 않는다.

- `validate.sh`: standards-compliant JSON Schema가 적용된 strict v1alpha1 descriptor,
  exact child enrollment/origin,
  pinned Helm chart, recursive dependency/policy와 multi-image digest contract 검증
- `bootstrap-rgw-credentials.sh`: 기능 namespace의 B OBC가 생성한 credential을
  기다린 뒤 Karmada API의 runtime Secret으로 server-side apply하는 POC bridge
- `bootstrap-cuty-rgw-credentials.sh`: 향후 Smurf/Cuty 계약 검증용 호환 bootstrap
- release dependency path에는 deployable YAML을 두지 않는다. Bootstrap 이외의
  검증 script는 cluster나 credential source에 쓰지 않는다.
- `rgw-analysis-web/verify-public-images.sh`: 인자 없이 실행하면 모든 active release
  descriptor의 values를 읽어 tag와 digest manifest를 확인한다. 특정 values path를
  인자로 전달하면 그 release들만 검사한다.

POC의 기본 credential 흐름은 다음과 같다.

```text
B/scalex-rgw-analysis-web/rgw-analysis-web-bucket
  -> Karmada/scalex-rgw-analysis-web/rgw-analysis-web-s3
  -> workload propagateDeps -> B/C
```

bridge는 credential 값을 Git이나 Helm values에 기록하지 않는다. 장기적으로는
동일 계약을 External Secrets 또는 전용 credential controller로 대체한다.

`validate.sh`는 chart repository가 `scalex-federation`과 같은 상위 디렉터리
아래에 checkout되어 있다고 가정한다. CI workspace가 다르면
`FEATURE_REPOS_ROOT`를 checkout root로 지정한다. 각 chart는 working tree가
아니라 `release.yaml`에 고정된 commit에서 export해 검증한다. CI checkout은
해당 commit을 포함하도록 전체 history 또는 필요한 SHA를 fetch해야 한다.
`check-jsonschema`는 정확히 `0.33.3`이어야 한다. Schema 구조 검증이 먼저 통과한 뒤
cross-field semantic 검증을 실행한다.

Pull Request CI에서는 base branch를 함께 지정해 artifact promotion 결합도
검사한다.

```bash
VALIDATE_BASE_REF=origin/main ./scripts/validate.sh
```

이 모드에서는 `values.yaml.images`가 변경됐는데
`release.yaml.source.revision`이 그대로인 부분 승격을 거부한다. Runtime 설정이나
policy만 변경하는 PR에는 영향을 주지 않는다.
