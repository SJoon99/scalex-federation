# ScaleX Federation

ScaleX Federation is the GitOps release catalog for the ScaleX multi-cluster sandbox.

TowerX applies exactly two root resources from path `.` with a non-recursive exact include:

- `project.yaml`
- `release-applicationset.yaml`

Only `state: active` descriptors under `releases/*/release.yaml` become Argo CD Applications. An empty catalog creates no workloads.

## Repository layout

```text
.
├── README.md
├── project.yaml
├── release-applicationset.yaml
├── docs/
│   ├── architecture.md
│   ├── bootstrap.md
│   └── migration-status.md
└── releases/
    └── README.md
```

## Scope

Feature repositories own workload charts and Karmada policies. This repository owns only release revisions and runtime values. It stores no credentials, cluster endpoints, or Karmada-generated objects.
