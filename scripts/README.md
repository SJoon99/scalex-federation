# scripts

로컬 개발과 CI에서 공통으로 사용하는 반복 가능한 검증 도구를 둔다.

예상 용도:

- Release render
- Policy/label validation
- Artifact revision 확인
- Smoke test 실행 보조

스크립트는 Argo CD를 우회해 운영 cluster에 직접 배포하는 경로로 사용하지 않는다.

- `validate.sh`: bootstrap, release, pinned Helm chart, recursive policy와
  multi-image digest contract 검증
- `bootstrap-rgw-credentials.sh`: Git에 저장할 수 없는 B OBC credential을
  Karmada API Secret으로 한 번 주입하는 POC bootstrap 예외. Workload 배포는
  계속 Argo/Karmada가 담당한다.

`validate.sh`는 chart repository가 `scalex-federation`과 같은 상위 디렉터리
아래에 checkout되어 있다고 가정한다. CI workspace가 다르면
`FEATURE_REPOS_ROOT`를 checkout root로 지정한다. 각 chart는 working tree가
아니라 `release.yaml`에 고정된 commit에서 export해 검증한다. CI checkout은
해당 commit을 포함하도록 전체 history 또는 필요한 SHA를 fetch해야 한다.

Pull Request CI에서는 base branch를 함께 지정해 artifact promotion 결합도
검사한다.

```bash
VALIDATE_BASE_REF=origin/main ./scripts/validate.sh
```

이 모드에서는 `values.yaml.images`가 변경됐는데
`release.yaml.chart.revision`이 그대로인 부분 승격을 거부한다. Runtime 설정이나
policy만 변경하는 PR에는 영향을 주지 않는다.
