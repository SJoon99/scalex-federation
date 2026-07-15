# tests

This experiment keeps lightweight validation fixtures for the single-values
catalog design. The tests exercise lifecycle state, ApplicationSet active-entry
filtering, AppProject permissions, secret/dependency rejection, immutable source
revision checks, policy selector coverage, and safe namespaced RBAC. Active releases
must render Karmada policies that select every rendered resource exactly once.

```bash
./tests/catalog/test-catalog-validation.sh
```
