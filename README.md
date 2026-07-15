# scalex-federation single-values catalog experiment

This worktree is an intentionally **non-recommended comparison branch** for
collapsing `scalex-federation` to bootstrap, docs, validation, and one central
release catalog/values file.

The renewed ownership model is stricter than the earlier draft:

- Federation owns Argo bootstrap, Karmada API release namespace creation, plus one catalog of release identity, lifecycle
  state, pinned chart source, and minimal environment Helm values.
- Dev feature charts own Karmada `PropagationPolicy` and `OverridePolicy`
  templates.
- `*-k8s` / Infra repos own bucket/OBC provisioning and cross-cluster credential
  delivery. Federation and the feature chart only reference already-existing
  runtime Secret/ConfigMap names through Helm values.

## Runtime flow

```text
values.yaml
        ↓ ApplicationSet matrix git + list.elementsYaml
active catalog entries only
        ↓ one Argo Application per active release
feature Helm chart + inline environment values
        ↓ destination.name = karmada
Karmada API original workload + chart-rendered policies
        ↓
member clusters
```

`bootstrap/applicationset.yaml` points at this experiment branch
(`experiment/single-values-catalog`) and filters generated parameters with the
ApplicationSet generator selector `state=active`. Disabled releases remain in the
catalog for compatibility rendering and review, but do not generate Argo
Applications.

## Current POC entry

`poc/rgw-analysis-web` is pinned to `scalex-feature-poc` commit
`4e26773509ef2d38409d320f55956d24f0fa3377` and is intentionally marked
`state: disabled` because that chart revision does not render Karmada policies.
Its Helm values retain only workload settings and existing runtime references:

- `s3.configMapName: rgw-analysis-web-runtime`
- `s3.secretName: rgw-analysis-web-s3`

The catalog does not declare OBCs, RuntimeBinding objects, policy placement, or
cluster-specific overrides.

## Benefits

- Very small Federation repository surface.
- One native ApplicationSet path can generate all active release Applications.
- Dev feature charts can version workload and Karmada policy templates together.
- Disabled lifecycle state makes non-deployable comparison entries explicit.
- Helm values are chart-defined rather than forced into a Federation-specific
  value schema.

## Drawbacks

- A single catalog file becomes a merge hotspot as releases grow.
- Dev chart authors must maintain Karmada policy templates correctly.
- Platform-owned policy review is less explicit than standalone Federation YAML.
- Argo diffs for inline Helm values are less ergonomic than separate values
  files.
- Cutover is blocked until the pinned feature chart renders the required
  policies.

## Validate locally

```bash
FEATURE_REPOS_ROOT=/home/joon/study/scalex/work ./scripts/validate.sh
./tests/catalog/test-catalog-validation.sh
```
