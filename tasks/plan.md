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
- [x] Task 5: GitHub Actions publish workflow
- [x] Task 6: README for consumers

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

---

# v0.2.0: Optional init containers and service secret

Source of truth: [SPEC.md § v0.2.0](../SPEC.md#v020-optional-init-containers-and-service-secret)

## Overview

This release adds two opt-in features to the Deployment, both off by default:

- `initContainers.enabled` with `initContainers.containers`: a raw list of container specs
- `secrets.enabled`: loads the pre-existing Secret `<appName>-<serviceName>-secrets-<appEnv>` through `envFrom` into the app container and every init container

The default render must stay byte-identical to 0.1.0.

## Architecture Decisions

- **Golden file for backward compatibility.** Before touching any template, capture the current default render in `tests/golden/default.yaml` and add a `diff` assertion to `run.sh`. SPEC success criterion 1 then becomes a permanent regression test rather than a one-time check. Future intentional changes regenerate the golden file on purpose and show up in the diff.
- **Build the init container list first, then call `toYaml` once.** In the template, range over `containers`, `deepCopy` each item, append the `secretRef` to its `envFrom` when `secrets.enabled`, collect the results into a list, then emit `toYaml $list | nindent 8`. This avoids the indentation gymnastics sketched in the SPEC and never changes the consumer's values in place.
- **The `secretRef` is non-optional**, following the SPEC. A missing Secret is a deploy-time error (`CreateContainerConfigError`), not a render-time error, because the chart can't see the cluster.
- **The `envFrom` preservation test uses `--set-json`**, which Helm has supported since 3.10, so no extra fixture file is needed. Only `tests/values-init.yaml` is added.
- **Scoped assertions.** `run.sh` gets a small helper that slices the Deployment into its `initContainers:` part and its app `containers:` part. Each `envFrom` assertion is then checked against the right container, not just anywhere in the document.

## Dependency Graph

```
tests/golden/default.yaml (baseline, captured at current HEAD)
    │
    ├── Init containers: render (values, deployment, fixture)
    │       │
    │       └── Init containers: guards (schema, chart.validate)
    │
    ├── Secret: app container (chart.secretName, values, schema, deployment)
    │       │
    │       └── Secret: into init containers ← also needs init render
    │
    └── Version bump + README + example (documents final behavior)
```

The two feature tracks are independent until Task 11. They are kept sequential anyway because they edit the same `deployment.yaml` and `run.sh`.

## Task List

### Phase 3: Init containers
- [ ] Task 7: Golden baseline for the default render
- [ ] Task 8: Render init containers behind a flag
- [ ] Task 9: Guards for init containers (schema + enabled-but-empty)

### Checkpoint C: init containers complete
- [ ] `./tests/run.sh` green, golden diff empty
- [ ] `helm lint` clean with and without `values-init.yaml`
- [ ] Human reviews the rendered `initContainers` block

### Phase 4: Service secret
- [ ] Task 10: Secret `envFrom` on the app container behind a flag
- [ ] Task 11: Secret `envFrom` into init containers, keeping the consumer's `envFrom`

### Checkpoint D: features complete
- [ ] All four flag combinations render as the SPEC testing strategy describes
- [ ] No combination renders a `Secret`, and the resource count is 2 everywhere

### Phase 5: Release
- [ ] Task 12: Bump to 0.2.0, update the README and example helmfile

### Checkpoint E: ready to ship 0.2.0
- [ ] All local verification commands pass
- [ ] Human approves merge to `main`, then CI publishes `:0.2.0`

Full task details: [todo.md](todo.md#v020-optional-init-containers-and-service-secret)

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| `deepCopy`/`set`/`append` on values maps behaves unexpectedly (nil `envFrom`, typed lists) | Med | Task 11 tests both the nil case and the existing-`envFrom` case; `default list` handles nil |
| Helm 4 schema error text differs from Helm 3, so `expect_fail` regexes are fragile | Low | Match only the field name (`image`, `name`), as the existing guards do |
| Golden file breaks on harmless whitespace changes | Low | The whitespace change is intended to be caught. Regenerate the golden file on purpose with the command documented in `run.sh` |
| `toYaml` key ordering (alphabetical) surprises consumers reading the manifest | Low | The order has no effect on Kubernetes; assertions check the fields, not their order |
| A consumer enables `secrets` before creating the Secret, and pods get stuck | Med | The README states the Secret must already exist and gives the `kubectl create secret` command; the error is visible in `kubectl describe pod` |

## Open Questions

- Should the golden file cover only the default render, or also one "all flags on" render? The plan covers only the default, because regex assertions already cover the feature paths.
