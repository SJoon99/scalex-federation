---
name: federation-release-promotion
description: The scalex-federation release contract — how a release chart gets registered, promoted, and deployed via Argo CD (Tower) and optionally Karmada. Use this skill whenever registering a release repo in the catalog, writing or editing the release descriptor (releases/NAME/release.yaml) or the Federation runtime values, activating/deactivating a release, injecting image digests or fleet facts, or answering "how do I deploy this chart", "register this in the federation", "promote a new version", or "why isn't my release showing up in Argo CD".
---

# Federation release & promotion contract

`scalex-federation` is a small Argo CD control repository — a GitOps release
catalog. Understanding its contract prevents the two classic failure modes:
releases that never appear, and configuration leaking into the wrong repo.

## How the machinery works

- Tower bootstraps by applying exactly two root files from path `.` with a
  non-recursive exact include: `project.yaml` (AppProject
  `scalex-federation`) and `release-applicationset.yaml` (ApplicationSet
  `scalex-releases`). Nothing else in the repo is applied directly.
- The ApplicationSet's **Git file generator** scans
  `releases/*/release.yaml` and renders only files whose labels match
  `state: active`. Empty catalog ⇒ zero Applications ⇒ zero workloads —
  a deliberately safe default.
- Generated Applications are **multi-source**: source 1 is the release repo's
  chart at a pinned revision; source 2 is the federation repo itself as
  `ref: federation`, providing the runtime values file via
  `$federation/<path>`. Sync policy is automated (prune + selfHeal) with
  `CreateNamespace`, `ServerSideApply`, and the namespace labeled
  `namespace.karmada.io/skip-auto-propagation: "true"`.
- The ApplicationSet uses `goTemplateOptions: missingkey=error` — a missing
  field in `release.yaml` fails at render time, so a malformed descriptor is
  the first thing to check when a release doesn't materialize.

## The release descriptor

`releases/<release-name>/release.yaml`:

```yaml
name: my-release                # becomes Application "federation-my-release"
state: active                 # anything else ⇒ not rendered at all
namespace: scalex-my-release    # must match the AppProject's scalex-* destination pattern
source:
  repoURL: https://github.com/SmartX-Team/<release-repo>.git   # must be in AppProject sourceRepos
  path: chart
  revision: 0123456789abcdef0123456789abcdef01234567         # IMMUTABLE commit SHA
values:
  path: releases/my-release/values.yaml   # runtime values, beside this file
```

Rules that are contracts, not suggestions:

- **`revision` is a 40-hex commit SHA.** Never a branch or tag — promotion
  means changing this SHA in a reviewed commit, and rollback means changing
  it back. This is what makes a release reproducible.
- **`namespace` follows `scalex-*`** or the AppProject destination rejects it.
- **Deactivate by flipping `state`**, not by deleting the directory — the
  history of what was released stays in Git either way, but flipping keeps
  the runtime values around for reactivation.

## Runtime values — what the Federation owns

`releases/<name>/values.yaml` carries everything that is per-release or
per-fleet, and only that:

- `images.<n>.digest` (`sha256:<64hex>`) and `images.<n>.sourceRevision`
  (`<40hex>`) — injected by the promotion pipeline; the chart renders
  tag-only until these arrive.
- Fleet facts: the authoritative per-app placement and exposure when they
  differ from repo defaults — `apps.<name>.targetCluster` (e.g. move an app
  from edgex to twinx federation-side, no repo commit) and
  `apps.<name>.service.lbPool` (Cilium LB-IPAM pool on the target member;
  never a static IP).
- The deployment-model switch: multi-cluster releases must set
  `karmada.enabled: true` (platform contract); whether policies actually
  render is verified by rendered-output checks, not the schema.

What must **never** appear anywhere in the federation repo: credentials,
cluster endpoints, Karmada-generated objects (`ResourceBinding`, `Work`),
or repo-owned defaults duplicated "for convenience" (they drift).

## Scope boundary (who owns what)

| Repository | Owns |
|---|---|
| release repo | chart templates, repo defaults, service code, Dockerfiles, tests |
| scalex-federation | release pinning, runtime values, digests, fleet facts, AppProject/ApplicationSet |
| tower-ci (Tekton) | build, push, semver tag enforcement, digest production |
| Karmada | ResourceBinding/Work — runtime only, never Git |

## Known gaps to compensate for (2026-07 review)

When working in the federation repo, know that the minimal contract has no
enforcement layer yet; add or recommend these rather than assuming they
exist:

1. No JSON Schema / CI validation for `release.yaml` — typos surface only at
   ApplicationSet render time (`missingkey=error`). Prefer adding a schema +
   PR check (SHA format, `scalex-*` namespace, required keys).
2. No environment/ring structure — `releases/` is flat; a dev→prod
   promotion path needs `releases/<env>/<name>/` or label-based rings.
3. `sourceRepos` wildcard (`scalex-*.git`) is broad; tightening to an
   explicit allowlist is safer as the org grows.
4. `SkipDryRunOnMissingResource=true` is applied globally; scoping it to the
   Karmada CRD kinds via per-resource annotation is the stricter form.

## Promotion walkthrough

1. Child CI is green at commit `<sha>`; tower-ci built and pushed images and
   produced digests for `<sha>`.
2. In `scalex-federation`, write/update `releases/<name>/values.yaml` with
   the new digests + `sourceRevision`, and set `release.yaml`'s
   `source.revision: <sha>`.
3. One PR, reviewed, merged to `main`. Argo CD reconciles: the Application
   re-renders from the pinned SHA with the new values and syncs — to the
   single destination cluster, or to the Karmada API which then propagates
   to member clusters when `karmada.enabled: true`.
4. Rollback = revert that commit.
