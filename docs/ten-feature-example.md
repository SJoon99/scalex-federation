# 기능 10개 확장 예시 — release별 파일

> 설계 비교를 위한 가상 구조다. 아래 10개 release를 실제로 생성하거나 활성화하지 않는다.

## 가정한 기능

| # | Release | 역할 |
|---:|---|---|
| 1 | `rgw-analysis-web` | RGW 데이터 분석 결과를 웹으로 제공 |
| 2 | `dataset-ingest` | 외부 데이터를 object storage로 수집 |
| 3 | `dataset-catalog` | 데이터셋 metadata 조회 API 제공 |
| 4 | `batch-analyzer` | 대규모 batch 분석 실행 |
| 5 | `model-training` | 분산 학습 작업 실행 |
| 6 | `model-serving` | 학습된 모델 inference API 제공 |
| 7 | `notebook-workspace` | 사용자 분석 notebook 제공 |
| 8 | `event-processor` | event stream 처리 |
| 9 | `report-generator` | 분석 결과 보고서 생성 |
| 10 | `alert-dispatcher` | 처리 결과와 장애 알림 전송 |

## Repository 구조

```text
scalex-federation/
├─ .github/
│  └─ workflows/
│     └─ federation-validate.yaml
├─ bootstrap/
│  ├─ README.md
│  ├─ appproject.yaml
│  └─ applicationset.yaml
├─ docs/
│  ├─ HOWTORUN.md
│  ├─ ci-promotion.md
│  ├─ common-contract.md
│  ├─ structure-variant.md
│  └─ ten-feature-example.md
├─ releases/
│  └─ poc/
│     ├─ rgw-analysis-web/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ dataset-ingest/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ dataset-catalog/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ batch-analyzer/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ model-training/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ model-serving/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ notebook-workspace/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ event-processor/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     ├─ report-generator/
│     │  ├─ release.yaml
│     │  └─ values.yaml
│     └─ alert-dispatcher/
│        ├─ release.yaml
│        └─ values.yaml
├─ scripts/
│  ├─ README.md
│  └─ validate.sh
├─ tests/
│  ├─ README.md
│  ├─ fixtures/
│  └─ test-validation.sh
├─ .gitignore
└─ README.md
```

## ApplicationSet 결과

각 `release.yaml`이 독립적인 generator input이 되므로 `state: active`인 release마다
Application 하나가 생성된다.

```text
federation-poc-rgw-analysis-web
federation-poc-dataset-ingest
federation-poc-dataset-catalog
federation-poc-batch-analyzer
federation-poc-model-training
federation-poc-model-serving
federation-poc-notebook-workspace
federation-poc-event-processor
federation-poc-report-generator
federation-poc-alert-dispatcher
```

예를 들어 `model-serving`만 승격하면 해당 디렉터리의 두 파일만 변경된다.

```text
releases/poc/model-serving/release.yaml  # source revision/state
releases/poc/model-serving/values.yaml   # 환경별 Helm override
```

다른 9개 release의 Git diff, rollback, CODEOWNERS 범위에는 영향을 주지 않는 것이 이
구조의 핵심이다.
