# bootstrap

Tower Argo CD reads these two manifests as the fixed entrypoint for the
single-values catalog experiment.

| File | Role |
|---|---|
| `appproject.yaml` | Allows the feature chart source, core `Namespace`, and namespaced workload plus Karmada policy kinds in the `karmada` destination. |
| `applicationset.yaml` | Expands active entries from root `values.yaml` into release Applications. |

The ApplicationSet uses native generator semantics only:

1. Git file generator reads root `values.yaml` from
   `experiment/single-values-catalog`.
2. List generator expands `{{ .releases | toJson }}` with `elementsYaml`.
3. Generator selector `state=active` filters out disabled releases.
4. The template points each active Application at the pinned feature chart and
   passes the catalog's inline Helm values.

No Federation policy, dependency, ObjectBucketClaim, RuntimeBinding,
ResourceBinding, or Work source is attached in this experiment.
