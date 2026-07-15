# CI와 promotion

Feature repository의 GitHub Actions는 source test, image build/scan, Helm lint/template와
Karmada policy 검증을 완료한 뒤 Federation promotion PR을 만든다.

기본 변경 범위는 한 entry의 다음 필드뿐이다.

```yaml
repo: https://github.com/SJoon99/scalex-feature-example.git
revision: <full-immutable-git-sha>
enabled: true
```

CI는 child cluster나 Karmada API에 직접 apply하지 않는다. Federation PR merge 후 Tower
Argo가 Helm chart를 렌더링하며, Git revert가 release rollback 기준이 된다.

활성 entry는 full SHA만 허용한다. `main`, mutable tag, SHA placeholder는 Helm render
단계에서 거부한다.
