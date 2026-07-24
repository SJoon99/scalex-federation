# Architecture

ScaleX Federation is a small Argo CD control repository.

Tower applies only the two root YAMLs from path `.` with a non-recursive exact include: `project.yaml` and `release-applicationset.yaml`. The root resources create:

- an `AppProject` named `scalex-federation` in namespace `argo`
- an `ApplicationSet` named `scalex-releases` in namespace `argo`

The ApplicationSet scans `releases/*/release.yaml` in `https://github.com/SmartX-Team/scalex-federation.git` at `main`. Releases are rendered only when `state: active` is present. Generated Applications use Argo CD multi-source Helm configuration and deploy to destination name `karmada`, with the namespace supplied by each release.

The project source policy is limited to this repository and scoped SmartX-Team ScaleX feature repositories. Feature charts own namespaced workloads, `PropagationPolicy`, and `OverridePolicy`. Karmada alone creates `ResourceBinding` and `Work` objects.
