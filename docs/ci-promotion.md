# CI와 release promotion

`.github/workflows/federation-validate.yaml`은 Pull Request와 `main` push를 검증한다.
checksum과 version이 고정된 Helm/yq를 설치하고, release가 선언한 공개 child를 exact
commit으로 가져온 뒤 chart export/render, enrollment, image digest, promotion
atomicity와 Karmada selector fixture를 검사한다. 권한은 `contents: read`뿐이며
cluster credential을 사용하지 않는다.

Feature CI가 promotion payload를 만들 때 source commit, chart path/version, 모든
변경 component의 `sha-<full-commit>` tag와 registry digest를 하나로 묶는다.
`tracked` release만 GitHub App의 단기 installation token으로 bot branch와 Pull
Request를 갱신한다. `pinned` release는 교차-repository 변경 없이 종료한다. 장기 PAT,
직접 push, CI의 자동 merge는 사용하지 않는다.

승격 PR은 다음 두 파일을 원자적으로 바꾼다.

- `release.yaml`의 exact source revision
- `values.yaml`의 모든 변경 image tag/digest/sourceRevision

검증 통과는 merge 승인이 아니다. 사람이 PR을 검토하고 merge하며 Git history가
promotion과 rollback 기록이다. Hosted workflow가 선언되어 있어도 실제 GitHub run,
registry publication 또는 배포가 수행됐다는 뜻은 아니다.
