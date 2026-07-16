# contracts

`children.yaml`은 Federation이 참조할 수 있는 exact GitHub repository와 Helm chart path를
등록한다. AppProject source allowlist와 함께 검증되어 등록되지 않은 source fetch를 막는다.

`federation-release-v1alpha1.schema.json`은 `releases/<name>/release.yaml` descriptor를
검증한다. descriptor는 다음을 보장한다.

- directory와 release name 일치
- `scalex-*` namespace
- `active` 또는 사유가 있는 `disabled` state
- exact HTTPS GitHub URL과 full commit SHA
- `chart` 또는 `charts/<name>` Helm path
- 동일 directory의 `values.yaml`
- pinned 또는 tracked promotion mode

Active chart는 workload와 namespaced Karmada policy를 함께 렌더링해야 한다. Infra
dependency, Secret, cluster-scoped resource와 credential 원문은 Federation release와
feature chart 모두에서 거부한다.
