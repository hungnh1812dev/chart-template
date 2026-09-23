# Tasks: helmfile-chart-template

Spec: [SPEC.md](../SPEC.md) · Plan: [plan.md](plan.md)

Test inputs used throughout: `appName=shop serviceName=api appNamespace=shop appEnv=dev appPort=8080`, release namespace `shop-dev`.

---

## Phase 1: Chart

### - [x] Task 1: Chart scaffold + naming helpers + Service slice

**Description:** Create the chart with values defaults, the `chart.fullNamespace` / `chart.fullServiceName` / `chart.labels` / `chart.selectorLabels` helpers, and a ClusterIP Service. Add the test harness (`tests/run.sh`) with a happy-path assertion so every later task extends the same script.

**Acceptance criteria:**
- [ ] `helm template` renders a Service named `shop-api-dev` in `shop-dev`, with `port: 8080` and `targetPort: 8080`
- [ ] Service carries the 5 labels from SPEC; selector uses `app.kubernetes.io/instance: shop-api-dev`
- [ ] `tests/run.sh` exits 0 on pass and non-zero with a message on the first failed assertion

**Verification:**
- [ ] `helm lint charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev`
- [ ] `./tests/run.sh`

**Dependencies:** None

**Files:**
- `charts/helmfile-chart-template/Chart.yaml`
- `charts/helmfile-chart-template/values.yaml`
- `charts/helmfile-chart-template/templates/_helpers.tpl`
- `charts/helmfile-chart-template/templates/service.yaml`
- `tests/values-ci.yaml`, `tests/run.sh`

**Scope:** M

---

### - [x] Task 2: Deployment slice

**Description:** Add a Deployment named `<fullServiceName>` with one container using `image.repository:image.tag`, `containerPort: appPort`, `replicaCount`, `resources`, and `env`. Its pod labels must match the Service selector.

**Acceptance criteria:**
- [ ] Deployment `shop-api-dev` in `shop-dev`, `containerPort: 8080`, image from values
- [ ] Pod template labels include the Service's selector labels, so the Service routes to these pods
- [ ] Exactly 2 resources rendered (1 Deployment, 1 Service)

**Verification:**
- [ ] `./tests/run.sh` (new assertions for Deployment + resource count)
- [ ] `helm lint ...` clean

**Dependencies:** Task 1

**Files:** `templates/deployment.yaml`, `tests/run.sh`

**Scope:** S

---

### - [x] Task 3: Input guards + values schema + failure tests

**Description:** Make bad input fail at render time with clear messages: required inputs and image values, DNS-1123 name pattern, full service name ≤ 63 chars, and `.Release.Namespace` = `<appNamespace>-<appEnv>`. Add `values.schema.json` for types (appPort integer 1–65535). Extend `run.sh` with expected-failure cases.

**Acceptance criteria:**
- [ ] Each case fails non-zero with a message naming the problem: missing `appName`, missing `image.tag`, uppercase `serviceName`, 64+ char full name, release namespace `default`, `appPort: 0`
- [ ] Happy path still passes

**Verification:**
- [ ] `./tests/run.sh` (happy + 6 failure cases)
- [ ] `helm lint ...` clean

**Dependencies:** Tasks 1, 2

**Files:** `templates/_helpers.tpl`, `values.schema.json`, `tests/run.sh` (+ templates if guard include is needed there)

**Scope:** M

---

### Checkpoint A: chart complete
- [ ] `helm lint` clean, `./tests/run.sh` green
- [ ] Human reviews `helm template test charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev` output

---

## Phase 2: Consumption + publishing

### - [x] Task 4: Example consumer helmfile

**Description:** Add `examples/helmfile.yaml.gotmpl` that reads the 5 inputs via `requiredEnv` and sets release name, namespace (`createNamespace: true`), and chart values. It uses the local chart path, with a commented OCI `chart:` + `version:` for consumers.

**Acceptance criteria:**
- [ ] With the 5 env vars set, `helmfile template` renders `shop-api-dev` Deployment + Service in `shop-dev`
- [ ] With `APP_ENV` unset, helmfile fails with a clear `requiredEnv` error
- [ ] `appPort` reaches the chart as an integer (passes schema)

**Verification:**
- [ ] `APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 helmfile -f examples/helmfile.yaml.gotmpl template`
- [ ] Add this command to `tests/run.sh`

**Dependencies:** Task 3

**Files:** `examples/helmfile.yaml.gotmpl`, `tests/run.sh`

**Scope:** S

---

### - [x] Task 5: GitHub Actions publish workflow

**Description:** Add `.github/workflows/publish.yaml`, triggered only by `push` to `main`, with `packages: write` permission. Steps: set up Helm v4.2.0 and helmfile → lint → `tests/run.sh` → read `Chart.yaml` version → log in to GHCR with `GITHUB_TOKEN` → skip if the version exists → otherwise package and push.

**Acceptance criteria:**
- [ ] Trigger is `on.push.branches: [main]` only. No `pull_request` or tags.
- [ ] Publish steps can't run if a test fails
- [ ] Existing version → logs "skipping" and exits 0. New version → pushed to `oci://ghcr.io/hungnh1812dev`
- [ ] No secrets other than `GITHUB_TOKEN`

**Verification:**
- [ ] Locally confirm the "exists?" check returns non-zero for a nonexistent version (`helm show chart oci://ghcr.io/hungnh1812dev/helmfile-chart-template --version 9.9.9`)
- [ ] Manual YAML review (no actionlint available; ask before adding it)
- [ ] Real run observed at Checkpoint B

**Dependencies:** Tasks 3, 4

**Files:** `.github/workflows/publish.yaml`

**Scope:** S

---

### - [x] Task 6: README for consumers

**Description:** Cover what the chart does, the naming rules, the 5 inputs + image values, a copy-paste consumer `helmfile.yaml.gotmpl` (OCI form), how to release (bump `Chart.yaml` version, merge to main), the one-time GHCR "make public" step, and local test commands.

**Acceptance criteria:**
- [ ] Consumer snippet matches `examples/helmfile.yaml.gotmpl` except for the `chart:` line
- [ ] Release process and the skip-if-exists behavior documented

**Verification:**
- [ ] Manual review against SPEC Success Criteria

**Dependencies:** Tasks 4, 5

**Files:** `README.md`

**Scope:** XS

---

### Checkpoint B: ready to ship
- [ ] All local commands in SPEC pass
- [ ] **Ask human** before commit + push to `main`
- [ ] Workflow run green; `ghcr.io/hungnh1812dev/helmfile-chart-template:0.1.0` exists
- [ ] Re-run with unchanged version → skip, exit 0
- [ ] Package set public; `helmfile template` against the OCI chart works from a clean dir

---

# v0.2.0: Optional init containers and service secret

Spec: [SPEC.md § v0.2.0](../SPEC.md#v020-optional-init-containers-and-service-secret) · Plan: [plan.md](plan.md#v020-optional-init-containers-and-service-secret)

Fixtures: `tests/values-ci.yaml` covers the default path with both features off. `tests/values-init.yaml` sets `initContainers.enabled: true` with one container: `migrate`, image `ghcr.io/acme/shop-api:1.2.3`, command `["./migrate","up"]`. The expected Secret name is `shop-api-secrets-dev`.

---

## Phase 3: Init containers

### - [x] Task 7: Golden baseline for the default render

**Description:** Before changing any template, save the current `helm template` output for `values-ci.yaml` to `tests/golden/default.yaml`. Add a `run.sh` assertion that diffs a fresh render against it. This locks in SPEC success criterion 1: the default render stays byte-identical to 0.1.0.

**Acceptance criteria:**
- [x] `tests/golden/default.yaml` is generated from the unmodified chart at the current HEAD
- [x] `run.sh` fails and prints the diff when the default render changes
- [x] A comment in `run.sh` gives the one-line command to regenerate the golden file on purpose

**Verification:**
- [x] `./tests/run.sh` green
- [x] Manual: add a stray label to `service.yaml` temporarily, confirm `run.sh` fails with the diff, then revert

**Dependencies:** None

**Files:** `tests/golden/default.yaml`, `tests/run.sh`

**Scope:** XS

---

### - [x] Task 8: Render init containers behind a flag

**Description:** Add the `initContainers: {enabled: false, containers: []}` defaults. In `deployment.yaml`, emit `initContainers:` before `containers:` only when `enabled` is true, building the list and then calling `toYaml` once (see the plan). Add the `tests/values-init.yaml` fixture and a helper in `run.sh` that splits the Deployment into its init part and its app part.

**Acceptance criteria:**
- [x] The default render has no `initContainers:`, and the golden diff is empty
- [x] `-f values-init.yaml` renders `initContainers:` above `containers:`, containing `name: migrate`, the image and the command
- [x] `values-init.yaml` with `--set initContainers.enabled=false` renders no `initContainers:` (the flag wins)

**Verification:**
- [x] `./tests/run.sh`
- [x] `helm lint charts/helmfile-chart-template -f tests/values-ci.yaml -f tests/values-init.yaml --namespace shop-dev`

**Dependencies:** Task 7

**Files:** `values.yaml`, `templates/deployment.yaml`, `tests/values-init.yaml`, `tests/run.sh`

**Scope:** S

---

### - [ ] Task 9: Guards for init containers

**Description:** Add the schema for `initContainers`: `enabled` is a boolean and `containers` is an array. Each item requires `name` and `image`, and `name` must match `dnsName`. In `chart.validate`, fail when `enabled` is true but `containers` is empty.

**Acceptance criteria:**
- [ ] `--set initContainers.enabled=true` fails with a message containing `initContainers.containers is empty`
- [ ] An init container with no `image` fails with a message naming `image`
- [ ] An init container named `Migrate` fails on the schema; `values-ci.yaml` and `values-init.yaml` still render

**Verification:**
- [ ] `./tests/run.sh` (3 new `expect_fail` cases, with the missing-image and uppercase-name cases set through `--set-json`)
- [ ] `helm lint` clean for both fixtures

**Dependencies:** Task 8

**Files:** `values.schema.json`, `templates/_helpers.tpl`, `tests/run.sh`

**Scope:** S

---

### Checkpoint C: init containers complete
- [ ] `./tests/run.sh` green, golden diff empty
- [ ] `helm lint` clean with and without `values-init.yaml`
- [ ] Human reviews the rendered `initContainers` block

---

## Phase 4: Service secret

### - [ ] Task 10: Secret `envFrom` on the app container behind a flag

**Description:** Add the `chart.secretName` helper (`<appName>-<serviceName>-secrets-<appEnv>`), the `secrets: {enabled: false}` default with a comment that the Secret must already exist, and the schema for `secrets.enabled` (boolean). When the flag is on, the app container gets `envFrom: [{secretRef: {name: <secretName>}}]` after `env`.

**Acceptance criteria:**
- [ ] With `--set secrets.enabled=true`, the app container has `envFrom` with `name: shop-api-secrets-dev`, and there is no `initContainers:`
- [ ] The default render has no `envFrom:`, and the golden diff is empty
- [ ] No render produces `kind: Secret`, and the resource count stays 2

**Verification:**
- [ ] `./tests/run.sh`
- [ ] `helm lint ... --set secrets.enabled=true`

**Dependencies:** Task 7 (it also edits the files touched by Task 8, so it runs after Task 9)

**Files:** `templates/_helpers.tpl`, `values.yaml`, `values.schema.json`, `templates/deployment.yaml`, `tests/run.sh`

**Scope:** M

---

### - [ ] Task 11: Secret `envFrom` into init containers

**Description:** In the init container loop, when `secrets.enabled` is true, append the `secretRef` to the `envFrom` of each deep-copied item, falling back to `default list` when the item has no `envFrom`.

**Acceptance criteria:**
- [ ] With `-f values-init.yaml --set secrets.enabled=true`, both the `migrate` init container and the app container have the `secretRef` `shop-api-secrets-dev` (checked in each container's own part)
- [ ] An init container with its own `envFrom: [{configMapRef: {name: shared}}]` keeps it, and the `secretRef` comes after it
- [ ] With `values-init.yaml` alone (secrets off), the init container has no `envFrom`

**Verification:**
- [ ] `./tests/run.sh`
- [ ] `helm lint ... -f tests/values-init.yaml --set secrets.enabled=true`

**Dependencies:** Tasks 8 and 10

**Files:** `templates/deployment.yaml`, `tests/run.sh`

**Scope:** S

---

### Checkpoint D: features complete
- [ ] All four flag combinations (off/off, init only, secret only, both) render as the SPEC testing strategy describes
- [ ] No combination renders a `Secret`, and the resource count is 2 everywhere
- [ ] Human reviews the full Deployment render with both flags on

---

## Phase 5: Release

### - [ ] Task 12: Bump to 0.2.0, update the README and example helmfile

**Description:** Set `Chart.yaml` `version: 0.2.0`. Add README sections for `initContainers` and `secrets`, including the Secret naming convention, a `kubectl create secret` example, and a note that missing Secret means `CreateContainerConfigError`. Update every `0.1.0` reference in the README and example to `0.2.0`, and add commented-out usage of both options to the example helmfile.

**Acceptance criteria:**
- [ ] `Chart.yaml` is at `0.2.0`, and the golden diff is still empty (the chart has no version label)
- [ ] The README documents both flags, the Secret name convention and the pre-create requirement
- [ ] The example helmfile still renders with `helmfile template`, and its OCI comment references `0.2.0`

**Verification:**
- [ ] `./tests/run.sh` (includes the example helmfile render)
- [ ] `grep -rn '0\.1\.0' README.md examples/` returns nothing

**Dependencies:** Tasks 9 and 11

**Files:** `Chart.yaml`, `README.md`, `examples/helmfile.yaml.gotmpl`

**Scope:** S

---

### Checkpoint E: ready to ship 0.2.0
- [ ] All local verification commands from SPEC pass
- [ ] Human approves merge to `main`
- [ ] After the push, the workflow is green and `ghcr.io/hungnh1812dev/helmfile-chart-template:0.2.0` is visible
