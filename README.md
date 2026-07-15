# scalex-federation — single-values Helm variant

ScaleX 기능 repository 목록을 하나의 `values.yaml`로 관리하고, 작은 Helm chart가 이를
Tower Argo의 child `Application`들로 렌더링하는 비교 branch다. ApplicationSet은 사용하지
않는다.

## 구조

```text
scalex-federation/
├─ Chart.yaml
├─ values.yaml
├─ templates/
│  ├─ appproject.yaml
│  └─ applications.yaml
└─ docs/
```

SmartX/mobilex에서 SmartX Helm template가 cluster values를 읽어 Application CR들을 만드는
방식과 같다. 여기서는 `templates/applications.yaml`이 feature repo 목록을 순회한다.

## 최소 release 입력

```yaml
releases:
  - repo: https://github.com/SJoon99/scalex-feature-poc.git
    revision: 4e26773509ef2d38409d320f55956d24f0fa3377
    enabled: false
```

renderer는 repo basename으로 다음 값을 자동 생성한다.

```text
scalex-feature-poc
├─ Application: federation-scalex-feature-poc
├─ namespace: scalex-feature-poc
├─ Helm releaseName: scalex-feature-poc
├─ chart path: chart
└─ destination: karmada
```

`path`와 `values`는 feature chart가 기본 계약과 다를 때만 선택적으로 추가한다. 배포
승격과 Git rollback을 보존하기 위해 활성 release의 `revision`은 full Git SHA여야 한다.

## 동작

```text
Tower Argo root Application
        │ Helm render: scalex-federation
        ├─ AppProject/scalex-federation
        └─ Application/federation-<feature-repo>
                         │ destination: karmada
                         ▼
                 Tower Karmada API
                         │ Push
                         ├─ site-b
                         └─ site-c
```

AppProject의 `sourceRepos`도 같은 release 목록에서 생성하므로 repo URL을 다른 파일에
중복 작성하지 않는다.

## 10개 비교 예시

현재 `values.yaml`에는 다음 feature repo 10개가 실제 entry로 존재한다.

```text
scalex-feature-poc
scalex-feature-dataset-ingest
scalex-feature-dataset-catalog
scalex-feature-batch-analyzer
scalex-feature-model-training
scalex-feature-model-serving
scalex-feature-notebook-workspace
scalex-feature-event-processor
scalex-feature-report-generator
scalex-feature-alert-dispatcher
```

모두 `enabled: false`다. 실제 `scalex-feature-poc`만 현재 SHA를 갖고, 나머지는 repository와
chart가 준비되기 전까지 명시적인 SHA placeholder를 유지한다. 따라서 이 branch를 Helm
render해도 child Application은 생성되지 않는다.

## Tower root 변경 형태

이 방식을 선택해 `main`에 반영할 때 Tower의 root Application source는 `bootstrap`
directory가 아니라 chart root를 가리킨다.

```yaml
source:
  repoURL: https://github.com/SJoon99/scalex-federation.git
  targetRevision: main
  path: .
  helm:
    releaseName: scalex-federation
```

비교 branch에서는 `targetRevision: experiment/single-values-catalog`로 시험할 수 있다.
