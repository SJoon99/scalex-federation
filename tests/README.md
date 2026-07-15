# tests

`test-validation.sh`는 다음 경계를 synthetic Helm chart와 임시 Git repository로 검증한다.

- immutable source revision
- release namespace uniqueness
- Federation-owned policy/dependency 재도입 금지
- values 내부 credential field 금지
- ApplicationSet destination 고정
- 활성 feature chart의 workload + PropagationPolicy 동시 렌더링
