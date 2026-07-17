# child repository 최소 연동 계약

Federation은 feature child repository를 원격 Helm source로 참조한다. child는 복수
feature 디렉터리를 노출하지 않고, 하나의 chart 경로를 stable contract로 제공해야 한다.

## 허용하는 child 구조

```text
<child-repository>/
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json       # 선택
│   └── templates/
├── src/                         # 선택
├── images/                      # 선택
└── docs/                        # 선택
```

최소 요구사항은 다음 세 가지다.

1. `chart/Chart.yaml`이 존재하는 Helm v3 application chart
2. `chart/values.yaml`이 chart의 기본값을 선언
3. `chart/templates/`가 `helm lint chart`와 `helm template`을 통과

## release descriptor 매핑

각 child release는 다음처럼 등록한다.

```yaml
# releases/<release-name>/release.yaml
name: <release-name>
namespace: <workload-namespace>
state: active
renderer: helm/v1
source:
  repoURL: https://github.com/<owner>/<child-repository>.git
  path: chart
  revision: <40-character commit SHA>
values:
  path: releases/<release-name>/values.yaml
promotion:
  mode: tracked
```

`releases/<release-name>/values.yaml`은 child chart의 `chart/values.yaml`에 덮어쓸
배포 값이다. image의 `repository`, `tag`, `digest`, `sourceRevision`은 하나의 promotion
단위로 갱신하며, `revision`과 image `sourceRevision`은 같은 child commit을 가리켜야 한다.

## 소유권과 검증

- child는 source, Helm template, workload policy를 소유한다.
- Federation은 active release, exact source SHA, release values를 소유한다.
- cluster namespace와 infra dependency는 각 `*-k8s` repository가 소유한다.
- child workflow는 promotion branch/PR을 만들 수 있지만 Federation `main`에 직접 push하지
  않는다.
- 검증은 `scripts/validate.sh`로 descriptor schema, child enrollment, chart path, Helm
  render, image digest, namespace 경계를 확인한다.

eecs-k8s와 smartx-k8s의 `apps/template/application.yaml`은 원격 source의 chart와
`values.yaml`을 cluster values와 병합하는 동일한 convention을 사용하며,
mobilex-k8s의 `charts/ssh/kangryeol/application.yaml`은 별도 child values 파일을
`$cluster` ref로 주입하는 형태다. 이 Federation 계약은 그 convention에 맞춰 child의
chart path와 release values path를 명시적으로 고정한다.
