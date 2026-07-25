---
name: federation-release-chart
description: Architecture and Helm-chart rules for ScaleX Federation release repositories built as a values-driven app catalog. Use this skill whenever creating a new Federation release repo, adding an app to a release, editing chart/values.yaml, values.schema.json, _helpers.tpl, the apps templates, or any workload template, wiring a new service/image/Dockerfile, or reviewing a release repo against best practice — even if the user only says "add a service", "add an app", "new chart", "fix the values", or "make this deployable to the federation".
---

# Federation release chart — app-catalog architecture

A ScaleX Federation release repo owns **one Helm chart plus the app code and
Dockerfiles behind it**, deployed only by `scalex-federation` promoting it as
a release. The chart is an **app catalog**: `values.yaml` declares apps and
shared templates range over them. `scalex-release-template` is the reference
implementation.

## Canonical layout

```text
.
├── AGENTS.md                   # agent operating guide (invariants)
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml             # app catalog + repo defaults
│   ├── values.schema.json      # platform contract — copied, never forked
│   ├── templates/
│   │   ├── _helpers.tpl        # name/labels/image/appFullname helpers
│   │   ├── app/                # deployment.yaml + service.yaml (range apps.*)
│   │   └── policy/propagation.yaml  # one PropagationPolicy per app
│   └── tests/                  # helm-unittest specs (local and opt-in CI)
├── services/<name>/            # per-app code + language dependency manifest + tests
├── images/<name>/Dockerfile    # per-app image, repo-root build context (tower-ci)
├── scaffolds/                  # Go/Rust starting points (NOT build targets)
├── examples/                   # release examples + github-actions/ci.yaml (opt-in)
├── docs/adding-an-app.md       # worked example: new app → another member
└── Justfile
```

## The app-catalog rule

Apps are **values entries, not templates**. One entry:

```yaml
images:
  <name>: { repository: ..., tag: ..., pullPolicy: IfNotPresent }
apps:
  <name>:
    enabled: true
    port: 8080
    targetCluster: edgex     # the ONE placement knob (twinx/datax/... per app)
    env: { KEY: value }
    service: { enabled: true, type: LoadBalancer, port: 80, lbPool: <pool> }
    resources: { ... }
```

renders one Deployment, one optional Service, one PropagationPolicy. Never
add per-app template files; if an app needs a genuinely new capability
(volumes, extra ports), extend the shared templates behind an optional
values field so every app benefits.

Three-way name sync: `services/<name>/` ↔ `images/<name>/Dockerfile` ↔
`images.<name>`/`apps.<name>`. tower-ci builds one image per Dockerfile with
the **repository root** as context — check all three on every add/rename.

## Values ownership

| Owner | Writes |
|---|---|
| This repo (`chart/values.yaml`) | catalog defaults: ports, env, resources, default `targetCluster`/`lbPool` |
| Federation runtime values | `images.<n>.digest`/`sourceRevision`, authoritative fleet facts — final `targetCluster`, pool names, `karmada.enabled: true` |
| tower-ci | image coordinates + tag rule (never duplicate semver enforcement in the schema) |

`targetCluster`/`lbPool` deliberately live in both lanes: repo sets a
working default; the Federation may override per release, so retargeting an
app is a federation-side one-line change with no repo commit.

## Exposure: Cilium pools, never static IPs

Services must not set `loadBalancerIP`. `service.lbPool` renders the
`lbipam.cilium.io/pool` annotation plus a `scalex.io/lb-pool` label (for
selector-based `CiliumLoadBalancerIPPool`s). Pool names are fleet facts;
the pool must exist on the app's target member.

## Required helpers

`name` / `fullname` (defaults to `.Release.Name` — the Federation passes the
release name) / `chart` / `labels` / `selectorLabels`, plus:

- `appFullname` — `<release>-<app>`; every resource name and every policy
  selector derives from it, so names can never drift apart.
- `image` — `repo:tag` normally, `repo:tag@digest` once the Federation
  injects `.digest`. All containers use it.

## Workload baseline (non-negotiable)

`runAsNonRoot: true` + `runAsUser: 65532` + `seccompProfile: RuntimeDefault`
+ `automountServiceAccountToken: false`; per container
`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`,
`capabilities.drop: [ALL]`; `/healthz` readiness+liveness; explicit
requests/limits; labels from the shared helpers with
`app.kubernetes.io/component: <app>`.

## Services, scaffolds, images

- `services/<name>/` carries the language's dependency manifest next to the
  code (`pyproject.toml` src-layout + pytest; `go.mod`; `Cargo.toml` +
  committed `Cargo.lock`) and its tests. Standard-library-only unless a
  dependency earns its place (update the lockfile in the same commit).
- `scaffolds/` holds Go/Rust starting points that are **not** build targets
  (no Dockerfile) but must keep compiling — local verification and the opt-in
  CI template check them. New apps start
  by copying a scaffold into `services/`.
- Dockerfiles: multi-stage for compiled languages; final stage non-root
  `65532`, read-only-rootfs-compatible; `rust:*-alpine` build stages need
  `apk add musl-dev`.

## Definition of done

`just lint && just test` green, plus a helm-unittest assertion for any
behavior you changed — including the `karmada.enabled: false` zero-policy
case, the retarget case (edgex→twinx), and a multi-app case with a second
target (datax pattern). Before touching `chart/templates/policy/`, read
`.claude/skills/karmada-policy-templates/SKILL.md`; for registering or
promoting, `.claude/skills/federation-release-promotion/SKILL.md`.
