# Implementation Plan: helmfile-chart-template

Source of truth: [SPEC.md](../SPEC.md)

## Overview

Build a Helm chart (Deployment + Service) that derives names from five inputs, guard it against bad input at render time, give consumers an example helmfile, and publish the chart to `oci://ghcr.io/hungnh1812dev/helmfile-chart-template` from GitHub Actions on push to `main`.

## Architecture Decisions

- **Hyphen-joined names** (`<ns>-<env>`, `<app>-<svc>-<env>`): Kubernetes names must be DNS-1123 compliant, and underscores are rejected.
- **Chart renders into `.Release.Namespace` and fails if it differs from `<appNamespace>-<appEnv>`.** The namespace stays in helmfile's control (`createNamespace: true`), and the guard catches a wrong namespace.
- **Tests are bash + `helm template` + `grep`, no `yq` or helm-unittest.** This adds no new tools, and the same script runs locally and on `ubuntu-latest`.
- **`Chart.yaml` `version` is the only version source.** CI skips the publish if that version already exists on GHCR and never overwrites it.
- **Helm is pinned in CI to v4.2.0 to match local.** The chart stays `apiVersion: v2`, so Helm 3 consumers can still use it.
- **The example helmfile points at the local chart path** so it can be verified offline. A comment shows the OCI form consumers use.

## Defaults assumed for SPEC open questions

Change these before implementation if they are wrong:

1. The GHCR package is made **public** manually after the first publish. This goes in the README and needs no code.
2. The repo name `chart-template` and the package name `helmfile-chart-template` are both kept.
3. `image.repository` and `image.tag` are required values.
4. No health probes (out of scope).

## Dependency Graph

```
Chart.yaml + values.yaml + _helpers.tpl (naming)
    │
    ├── Service ─────────┐
    ├── Deployment ──────┤
    │                    ├── Guards + schema (validate inputs used by both)
    │                    │
    │                    ├── examples/helmfile.yaml.gotmpl (renders full chart)
    │                    │
    │                    └── publish workflow (runs tests/run.sh + example, then pushes)
    │                                │
    └────────────────────────────────┴── README (documents final behavior)
```

## Task List

### Phase 1: Chart
- [x] Task 1: Chart scaffold + naming helpers + Service slice, with test harness
- [x] Task 2: Deployment slice
- [x] Task 3: Input guards + values schema + failure tests

### Checkpoint A: chart complete
- [ ] `helm lint` clean, `./tests/run.sh` green (happy path + all failure cases)
- [ ] Human reviews rendered manifests

### Phase 2: Consumption + publishing
- [x] Task 4: Example consumer helmfile
- [ ] Task 5: GitHub Actions publish workflow
- [ ] Task 6: README for consumers

### Checkpoint B: ready to ship
- [ ] All local verification commands from SPEC pass
- [ ] Human approves commit + push to `main` (the first real publish)
- [ ] After push: workflow green, package visible in GHCR, second run with same version skips
- [ ] Consumer smoke test: `helmfile template` against the OCI chart

Full task details: [todo.md](todo.md)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Workflow can't be run locally (no `act`/`actionlint`) | Med | Keep workflow logic in plain shell steps; test the "version exists?" check locally against GHCR (read-only); first real run observed at Checkpoint B |
| `helm show chart` exit behavior for a missing OCI tag differs between Helm versions | Med | Verify locally in Task 5 against a nonexistent version before relying on it |
| GHCR package private by default → consumers get 401/403 | Med | README step to set visibility public; smoke test at Checkpoint B |
| Helm 4 locally vs consumers on Helm 3 | Low | Chart `apiVersion: v2`, no Helm-4-only template functions |
| `appPort` passed as string from `requiredEnv` in helmfile | Med | Schema accepts integer; example helmfile renders it unquoted; Task 4 verifies |

## Open Questions

- Should the defaults above stand? If there are no objections, implementation proceeds with them.
