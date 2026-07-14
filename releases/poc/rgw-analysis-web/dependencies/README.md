# Release dependencies

This release has no declarative dependency manifests. The feature-owned B OBC
creates its credential in the release namespace. The approved
`scripts/bootstrap-rgw-credentials.sh` bridge publishes that runtime value as
Karmada native Secret `rgw-analysis-web-s3` before workload reconciliation.
