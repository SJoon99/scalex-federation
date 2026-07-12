# scripts

로컬 개발과 CI에서 공통으로 사용하는 반복 가능한 검증 도구를 둔다.

예상 용도:

- Release render
- Policy/label validation
- Artifact revision 확인
- Smoke test 실행 보조

스크립트는 Argo CD를 우회해 운영 cluster에 직접 배포하는 경로로 사용하지 않는다.
