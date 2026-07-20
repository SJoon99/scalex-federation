# 확정 구조 — release별 파일

Federation catalog는 다음 구조를 사용한다.

```text
release 하나 = release.yaml + values.yaml
```

release 디렉터리는 환경 이름이 아니라 기능 repository 이름을 그대로 사용한다.

```text
releases/scalex-feature-<name>/
```

## 장점

- feature별 PR, rollback, history가 독립적이다.
- 서로 다른 팀의 동시 promotion이 같은 YAML을 수정하지 않는다.
- directory 단위 CODEOWNERS를 적용할 수 있다.
- Git file generator가 release 파일 하나를 Application 하나로 자연스럽게 변환한다.
- 한 release의 YAML 오류를 해당 release 경계에서 진단하기 쉽다.

## 비용

- release마다 두 파일과 디렉터리가 생긴다.
- 공통 values를 반복할 수 있으므로 feature chart default를 잘 설계해야 한다.
- 전체 release 목록을 보려면 검색 또는 생성된 요약이 필요하다.

비권장 비교안 `experiment/single-values-catalog`은 모든 release를 하나의 values catalog에
넣어 초기 파일 수를 줄이는 대신 merge hotspot과 일괄 장애 범위를 의도적으로 보여준다.
