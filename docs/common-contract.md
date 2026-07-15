# Single-values ownership contract

This branch tests a compact release catalog while preserving the renewed
ownership boundaries.

| Layer | Owns in this experiment | Does not own |
|---|---|---|
| Federation | Bootstrap, Karmada API release Namespace creation, one catalog, lifecycle state, pinned chart revision, minimal Helm values | OBCs, RuntimeBinding objects, dependency manifests, standalone policy YAML |
| Dev feature chart | Workload templates and Karmada `PropagationPolicy` / `OverridePolicy` templates | Bucket provisioning, credential delivery, Infra setup |
| `*-k8s` / Infra | Bucket/OBC lifecycle, storage capability, cross-cluster credential delivery, existing runtime Secret/ConfigMap surface | Feature workload source |
| Karmada | Replication of chart-rendered original resources | Direct Argo ownership of member-cluster copies |

Federation values may reference existing runtime objects, for example
`rgw-analysis-web-runtime` and `rgw-analysis-web-s3`, but must not define how
those objects are provisioned or copied across clusters.

Feature chart는 필요한 경우 release namespace 안의 `Role`/`RoleBinding`을 소유할 수 있다.
다만 `RoleBinding`은 같은 render에 포함된 local `Role`만 참조하며, `ClusterRole` 참조나
다른 namespace의 ServiceAccount subject는 admission에서 거부된다.

An active catalog release must point at a chart revision that renders Karmada
policies. The current pinned POC chart does not, so the entry is disabled.
