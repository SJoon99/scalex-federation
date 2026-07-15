# How to promote a catalog entry

1. Find the release entry in root `values.yaml`.
2. Replace the temporary source with the feature repository's exact chart SHA.
3. Match entry `name`, namespace, source repository basename, and Helm release name.
4. Replace inline `helm.values` with the feature-specific deployment values.
5. Confirm Infra dependencies and cross-cluster credentials already exist.
6. Change only that entry from `state: disabled` to `state: active`.
7. Review and merge the Federation PR.

This comparison branch has no repository-local validation script or test suite.
Helm lint/template and Karmada policy checks belong to the feature repository's
GitHub Actions before it opens the Federation promotion PR.
