# CI와 release promotion

`.github/workflows/federation-validate.yaml`은 Pull Request, `main` push와 수동 실행에서
동작한다. 로컬 `scripts/validate.sh`가 exact source, chart render, enrollment, image
digest와 Karmada selector를 검증한다. PR/push 검증에서는 base commit과 비교해 tracked
release의 source revision과 전체 image metadata가 반드시 함께 바뀌었는지도 검사한다.

Feature CI가 promotion payload를 만들 때 source commit, chart path/version, 모든
변경 component의 `sha-<full-commit>` tag와 registry digest를 하나로 묶는다.
`tracked` release만 GitHub App의 단기 installation token으로 bot branch와 Pull
Request를 갱신한다. child workflow는 registry에 세 이미지를 push하고 registry가 반환한
digest로 payload를 만든 뒤 `scripts/promote-release.sh`를 실행한다. `pinned` release는
교차-repository 변경 없이 종료한다. 장기 PAT, `main` 직접 push, CI의 자동 merge는
사용하지 않는다.

승격 PR은 다음 두 파일을 원자적으로 바꾼다.

- `release.yaml`의 exact source revision
- `values.yaml`의 모든 변경 image tag/digest/sourceRevision

검증 통과는 merge 승인이 아니다. 사람이 PR을 검토하고 merge하며 Git history가
promotion과 rollback 기록이다. Hosted workflow가 선언되어 있어도 실제 GitHub run,
registry publication 또는 배포가 수행됐다는 뜻은 아니다.

## GitHub App 권한

child repository에는 `SCALEX_PROMOTION_APP_ID` Actions variable과
`SCALEX_PROMOTION_APP_PRIVATE_KEY` secret을 등록한다. App은
`SJoon99/scalex-federation`에만 설치하고 repository `Contents: write`,
`Pull requests: write` 권한만 부여한다. Docker Hub publication에는
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` secret을 사용한다. installation token은 job이
끝날 때 폐기된다. `promote/temp-poc` bot branch와 open PR은 새 child commit이 올 때마다
최신 candidate로 갱신되며 자동 merge하지 않는다.
