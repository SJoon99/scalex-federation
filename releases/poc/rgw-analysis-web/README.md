# rgw-analysis-web storage ownership and migration

## Final ownership

```text
B Infra
├─ CephObjectStore/scalex-poc
├─ StorageClass/ceph-bucket
└─ RGW LoadBalancer/10.33.142.10

Feature Helm + Federation/Karmada
├─ ObjectBucketClaim/rgw-analysis-web-bucket → B
├─ bucket/rgw-analysis-web-poc
├─ dataset-seeder/result-web → B
└─ analyzer → C
```

Rook generates the OBC Secret in the feature namespace. The credential bridge
copies only that runtime value into `Secret/rgw-analysis-web-s3` in the Karmada
API, where `propagateDeps` sends it to the B/C workloads. No access key is
stored in Git or Helm values.

## One-time handoff from the legacy POC bucket

1. Install `objectbucketclaims.objectbucket.io` in the Karmada API.
2. Apply the feature OBC and its B-only `PropagationPolicy`.
3. Wait for `B/scalex-rgw-analysis-web/rgw-analysis-web-bucket` to become
   `Bound` and for its generated Secret to exist.
4. Run the credential bridge and confirm `rgw-analysis-web-s3` is fully applied
   to B and C.
5. Sync the Federation release and verify the dataset, analyzer, and result web
   against bucket `rgw-analysis-web-poc`.
6. Only then remove the legacy Infra-owned OBC `csi-rook-ceph/scalex-poc-bucket`.

The old `scalex-poc` bucket uses `reclaimPolicy: Retain`; this handoff does not
copy or delete its contents. Rollback before final cleanup by restoring the old
OBC definition and Federation values (`bucket=scalex-poc`,
`secretName=scalex-poc-rgw`). Delete the retained bucket only after an explicit
data-cleanup decision.
