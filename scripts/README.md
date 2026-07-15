# scripts

`validate.sh`는 release catalog와 Tower Argo admission 경계만 검증한다. cluster 접근,
runtime credential 동기화, feature별 관찰 기능은 포함하지 않는다.

활성 release는 `FEATURE_REPOS_ROOT/<repository-basename>`의 exact commit에서 chart를
export하여 Helm render한다. 비활성 release는 descriptor와 values 구조만 검사한다.
