# 기능 10개 확장 예시 — 단일 values catalog

> 설계 비교를 위한 가상 구조다. 아래 10개 release를 실제로 생성하거나 활성화하지 않는다.

## 가정한 기능

권장안과 동일한 기능 집합을 사용해 저장 구조만 비교한다.

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

기능이 10개로 늘어나도 feature별 디렉터리는 생기지 않는다.

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
│  └─ ten-feature-example.md
├─ values.yaml                    # 10개 release와 모든 inline Helm values
├─ scripts/
│  ├─ README.md
│  └─ validate.sh
├─ tests/
│  ├─ README.md
│  ├─ catalog/
│  └─ fixtures/
├─ .gitignore
└─ README.md
```

`values.yaml` 내부를 구조로 표현하면 다음과 같다.

```text
values.yaml
└─ releases[10]
   ├─ [0] rgw-analysis-web
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [1] dataset-ingest
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [2] dataset-catalog
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [3] batch-analyzer
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [4] model-training
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [5] model-serving
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [6] notebook-workspace
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [7] event-processor
   │      ├─ state/source/destination
   │      └─ helm.values
   ├─ [8] report-generator
   │      ├─ state/source/destination
   │      └─ helm.values
   └─ [9] alert-dispatcher
          ├─ state/source/destination
          └─ helm.values
```

## ApplicationSet 결과

Git generator가 `values.yaml`을 한 번 읽고 List generator가 `releases[]`를 펼치므로,
최종 Application 이름은 권장안과 동일하다.

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

차이는 결과가 아니라 변경 경계다. `model-serving` 하나만 승격해도 모든 팀이 공유하는
루트 `values.yaml`을 수정한다. 따라서 기능 수가 늘수록 merge conflict, CODEOWNERS 분리,
부분 rollback, 한 파일의 YAML 오류에 따른 전체 catalog 영향이 커진다.
