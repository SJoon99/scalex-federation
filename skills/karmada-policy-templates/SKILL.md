---
name: karmada-policy-templates
description: How to write and modify Karmada PropagationPolicy (and OverridePolicy) Helm templates in ScaleX Federation release charts. Use this skill whenever placing an app on a member cluster, retargeting an app to another member (edgex/twinx/datax), editing chart/templates/policy/, adding placement for a new app, or debugging why a workload does not appear on its member — even if the user just says "deploy this to edgex", "move it to twinx", "send the new app to datax", or "placement".
---

# Karmada placement policies for release charts

Karmada distributes resources created on its control plane to member
clusters according to `PropagationPolicy`. In a Federation release chart the
policies are **part of the chart**, generated per app from the catalog — the
repo owns the topology defaults, the Federation runtime values own the final
fleet decision.

## Non-negotiable frame

- **Gate on `karmada.enabled`.** The whole policy template is wrapped in
  `{{- if .Values.karmada.enabled }}`; the disabled mode (local plain-cluster
  dev) must render zero policy documents.
- **One policy per app, generated from the catalog.** Range over
  `.Values.apps`; never a shared policy for multiple apps, never a
  hardcoded cluster name in a template. The only placement knob is
  `apps.<name>.targetCluster`, so retargeting is a values change
  (edgex → twinx) and a new app carries its own target (datax) without
  touching templates.
- **Safe spec defaults on every policy:**
  ```yaml
  conflictResolution: Abort   # never silently overwrite existing resources
  preemption: Never           # never steal placements from other policies
  propagateDeps: true         # carry dependent objects along
  ```
- **Select by name.** `resourceSelectors` reference `<release>-<app>` (from
  the shared `appFullname` helper) in the release namespace — the policy can
  never capture another app's objects, and helper-derived names cannot drift
  from selectors. Include the app's Service in the same policy when
  `service.enabled`.
- **Fail loudly on missing placement.** Resolve the target with
  `required`: a catalog entry without `targetCluster` must break `helm
  template`, not deploy nowhere.
- **Karmada-generated objects (`ResourceBinding`, `Work`) never appear in
  Git or charts.** Only Policies do.

## The pin pattern (this template's default)

```yaml
placement:
  clusterAffinity:
    clusterNames:
      - {{ $app.targetCluster | quote }}
```

An app lands on exactly one member. "The workload didn't appear" debugging
order: (1) is `karmada.enabled` true in the effective values, (2) does the
rendered policy's `clusterNames` say the member you expect, (3) does the
member cluster object exist under that exact name in Karmada, (4) check the
app's `ResourceBinding`/`Work` on the control plane (read-only — never
commit them).

## Beyond pinning (when a release genuinely needs it)

Karmada also supports label-selected members (`clusterAffinity.labelSelector`),
multi-member spreading (`spreadConstraints`), and per-cluster mutation
(`OverridePolicy` with plaintext JSON-pointer overriders). Introduce these
only when an app truly must run on several members at once, and follow the
same frame: generated from values (never hardcoded members), gated,
name-selected, covered by rendered-output tests. For per-cluster overrides,
note that `operator: add` at a path conflicts if the base template already
defines that path — document such preconditions next to the template.

## Cross-member reachability

Propagation places pods; it does not make them reachable from other
members. An app consumed across members needs a cross-cluster address — in
this fleet, a LoadBalancer Service drawing from the target member's Cilium
LB-IPAM pool (`service.lbPool`), never a static `loadBalancerIP`.

## Testing placement

Every placement behavior gets a helm-unittest assertion in
`chart/tests/policies_test.yaml`:

- disabled mode → `hasDocuments: count: 0`;
- default target renders (hello → edgex), and retargeting via `set` moves it
  (→ twinx);
- multi-app: each app's policy carries its own target (datax example);
- the Service rides in the app's policy when exposed.

A policy change without a matching test is not done — rendered-output tests,
not the values schema, are what verify placement.
