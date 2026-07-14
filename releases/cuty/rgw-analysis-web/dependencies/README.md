# Release dependencies

This release has no deployable dependency manifests. Its RGW credential Secret
is prepared in the Karmada API through
`scripts/bootstrap-cuty-rgw-credentials.sh` before reconciliation, matching the
legacy POC credential boundary.
