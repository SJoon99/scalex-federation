# Releases

Place release metadata at `releases/<release-name>/release.yaml`.

Only releases with `state: active` are selected. With no matching release files, the root ApplicationSet creates no Applications.

Expected shape:

```yaml
name: example-release
state: active
namespace: scalex-example
source:
  repoURL: https://github.com/SmartX-Team/scalex-example.git
  path: chart
  revision: 0123456789abcdef0123456789abcdef01234567
values:
  path: releases/example-release/values.yaml
```

The source revision should be an immutable commit SHA. Runtime Helm values live beside the release metadata.
