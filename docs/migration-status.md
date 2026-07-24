# Migration Status

ScaleX Federation currently provides only the minimal root GitOps contract:

- `project.yaml` defines the scoped Argo CD project.
- `release-applicationset.yaml` discovers active release metadata.
- `releases/` is intentionally empty except for documentation.

No active releases, feature apps, generated Karmada resources, scripts, tests, or workflows have been migrated into this repository.
