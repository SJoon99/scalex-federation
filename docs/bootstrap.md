# Bootstrap

Tower bootstraps ScaleX Federation by applying exactly these root files from path `.`:

1. `project.yaml`
2. `release-applicationset.yaml`

The include must be non-recursive and exact. Tower should not apply `docs/`, `releases/`, generated output, scripts, workflows, or feature application manifests from this repository.

After bootstrap, Argo CD owns release discovery. If `releases/` contains no `*/release.yaml` file with `state: active`, the ApplicationSet renders no active Applications.
