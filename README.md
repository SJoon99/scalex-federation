# scalex-federation single-values catalog experiment

This worktree is an intentionally **non-recommended comparison branch** for
collapsing `scalex-federation` to bootstrap, docs, and one central release
catalog/values file.

The renewed ownership model is stricter than the earlier draft:

- Federation owns Argo bootstrap, Karmada API release namespace creation, plus one catalog of feature-repo identity,
  lifecycle state, pinned chart source, and minimal deployment Helm values.
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
feature Helm chart + inline deployment values
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

## Current feature repository entries

Root `values.yaml` contains ten actual catalog entries. An entry name is the exact
feature repository name; there is no intermediate `poc` environment layer. Its
`name`, namespace, source repository basename, and Helm release name use the same
identifier.

All entries are `state: disabled`, so this branch currently generates no Tower
Application. Only `scalex-feature-poc` points to an existing pinned revision; the
other nine entries retain explicit replacement revisions until their repositories
and charts exist.

```text
scalex-feature-poc                 scalex-feature-dataset-ingest
scalex-feature-dataset-catalog     scalex-feature-batch-analyzer
scalex-feature-model-training      scalex-feature-model-serving
scalex-feature-notebook-workspace  scalex-feature-event-processor
scalex-feature-report-generator    scalex-feature-alert-dispatcher
```

`scalex-feature-poc` keeps its chart-specific runtime references, for example:

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
- Cutover is blocked until each feature has its own chart revision and required
  policies.

This comparison branch intentionally has no `scripts/` or `tests/` directory.
Feature chart validation belongs to each feature repository's GitHub Actions;
this repository only shows the resulting shared release catalog shape.
