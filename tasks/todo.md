# Tasks: helmfile-chart-template

Spec: [SPEC.md](../SPEC.md) · Plan: [plan.md](plan.md)

Test inputs used throughout: `appName=shop serviceName=api appNamespace=shop appEnv=dev appPort=8080`, release namespace `shop-dev`.

---

## Phase 1: Chart

### - [ ] Task 1: Chart scaffold + naming helpers + Service slice

**Description:** Create the chart with values defaults, the `chart.fullNamespace` / `chart.fullServiceName` / `chart.labels` / `chart.selectorLabels` helpers, and a ClusterIP Service. Add the test harness (`tests/run.sh`) with a happy-path assertion so every later task extends the same script.

**Acceptance criteria:**
- [ ] `helm template` renders a Service named `shop-api-dev` in `shop-dev`, with `port: 8080` and `targetPort: 8080`
- [ ] Service carries the 5 labels from SPEC; selector uses `app.kubernetes.io/instance: shop-api-dev`
- [ ] `tests/run.sh` exits 0 on pass and non-zero with a message on the first failed assertion

**Verification:**
- [ ] `helm lint charts/helmfile-chart-template -f tests/values-ci.yaml`
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

### - [ ] Task 2: Deployment slice

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

### - [ ] Task 3: Input guards + values schema + failure tests

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

### - [ ] Task 4: Example consumer helmfile

**Description:** Add `examples/helmfile.yaml` that reads the 5 inputs via `requiredEnv` and sets release name, namespace (`createNamespace: true`), and chart values. It uses the local chart path, with a commented OCI `chart:` + `version:` for consumers.

**Acceptance criteria:**
- [ ] With the 5 env vars set, `helmfile template` renders `shop-api-dev` Deployment + Service in `shop-dev`
- [ ] With `APP_ENV` unset, helmfile fails with a clear `requiredEnv` error
- [ ] `appPort` reaches the chart as an integer (passes schema)

**Verification:**
- [ ] `APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 helmfile -f examples/helmfile.yaml template`
- [ ] Add this command to `tests/run.sh`

**Dependencies:** Task 3

**Files:** `examples/helmfile.yaml`, `tests/run.sh`

**Scope:** S

---

### - [ ] Task 5: GitHub Actions publish workflow

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

### - [ ] Task 6: README for consumers

**Description:** Cover what the chart does, the naming rules, the 5 inputs + image values, a copy-paste consumer `helmfile.yaml` (OCI form), how to release (bump `Chart.yaml` version, merge to main), the one-time GHCR "make public" step, and local test commands.

**Acceptance criteria:**
- [ ] Consumer snippet matches `examples/helmfile.yaml` except for the `chart:` line
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
