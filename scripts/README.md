# scripts

Only `validate.sh` remains in this comparison branch. It validates:

- single root `values.yaml` layout
- release lifecycle state
- ApplicationSet branch and `state=active` selector wiring
- immutable full-SHA chart revisions
- release and namespace uniqueness
- absence of inline Secret/dependency resources
- AppProject restriction to core Namespace plus namespaced workload and Karmada policy kinds
- Helm lint/render of pinned charts
- active releases render at least one `PropagationPolicy`
- every rendered resource is selected by exactly one `PropagationPolicy`
- stale/duplicate policy selectors and unsafe `ClusterRole` bindings are rejected

Runtime binding, image-verification, and observation scripts were removed because
Federation no longer owns dependency delivery or runtime observation in this
experiment.
