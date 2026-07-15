# Helm app-of-apps 실행과 승격

## Feature repository 계약

각 기능 repo는 다음 공통 계약을 따른다.

- repository basename: `scalex-feature-*`
- Helm chart 기본 경로: `chart`
- workload와 namespaced Karmada policy를 같은 chart에서 렌더링
- Infra가 제공한 Secret/ConfigMap 등 dependency는 이름으로 참조

## Release 등록

`values.yaml`에 entry 하나를 추가한다.

```yaml
releases:
  - repo: https://github.com/SJoon99/scalex-feature-example.git
    revision: <full-git-sha>
    enabled: false
    values:
      s3:
        configMapName: feature-example-runtime
        secretName: feature-example-s3
      resultWeb:
        replicas: 2
        service:
          type: LoadBalancer
```

`values` 아래에는 feature repo의 `chart/values.yaml`에서 배포 시 선택할 값만 적는다.
이 map은 생성되는 child Application의 `spec.source.helm.valuesObject`로 그대로 전달되며,
명시하지 않은 값은 feature chart의 기본값을 사용한다. override가 없으면 `values: {}`로 둔다.

```text
feature repo chart/values.yaml 기본값
                  +
Federation release.values 최소 override
                  ↓
Argo CD가 feature chart를 최종 렌더링
```

1. feature CI에서 chart lint/template와 Karmada policy selector를 검증한다.
2. 검증된 full Git SHA를 `revision`에 기록한다.
3. Infra dependency와 credential 전달 경로를 확인한다.
4. 같은 promotion PR에서 `enabled: true`로 변경한다.
5. Tower Argo가 Federation chart를 다시 렌더링한다.
6. 생성된 child Application이 Karmada API로 sync한다.

entry를 다시 비활성화하거나 제거하면 parent chart가 child Application을 prune하고,
Application finalizer가 Karmada API의 해당 release 리소스도 함께 정리한다.

기본 경로가 `chart`가 아니면 `path`를 추가할 수 있다. 이미지의 기본 구성, 포트, 템플릿
동작은 feature repo가 소유하고, Federation에는 placement, Infra dependency 이름, replica,
노출 방식처럼 release마다 달라지는 값만 둔다.

## 로컬 확인

```bash
helm lint .
helm template scalex-federation . --namespace argo
```

현재 비교 entry는 모두 비활성화되어 있으므로 기본 render 결과에는 AppProject만 존재한다.
