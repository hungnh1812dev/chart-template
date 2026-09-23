# Spec: helmfile-chart-template

## Objective

Provide one reusable Helm chart, published to GitHub Container Registry (GHCR) as an OCI artifact, that other projects consume from their own `helmfile.yaml`. A consuming project deploys a service by supplying five inputs and nothing else chart-specific:

| Input           | Example   | Meaning                          |
|-----------------|-----------|----------------------------------|
| `APP_NAME`      | `shop`    | Application / product name       |
| `SERVICE_NAME`  | `api`     | Service within the application   |
| `APP_NAMESPACE` | `shop`    | Base namespace                   |
| `APP_ENV`       | `dev`     | Environment (dev, staging, prod) |
| `APP_PORT`      | `8080`    | Container + Service port         |

Derived names (hyphen-joined, since Kubernetes names must be DNS-1123 — `_` is rejected):

- **Full namespace:** `<APP_NAMESPACE>-<APP_ENV>` → `shop-dev`
- **Full service name:** `<APP_NAME>-<SERVICE_NAME>-<APP_ENV>` → `shop-api-dev`

**Users:** engineers in other repos who need a standard Deployment + Service without writing their own chart.

**Why GHCR holds a chart, not a helmfile:** Helmfile cannot pull a `helmfile.yaml` from an OCI registry. The shareable unit is the Helm chart; this repo also ships an example `helmfile.yaml.gotmpl` that consumers copy.

### Consumer usage (target experience)

```yaml
# consumer repo: helmfile.yaml.gotmpl (helmfile v1 renders templates only in *.gotmpl)
releases:
  - name: {{ requiredEnv "APP_NAME" }}-{{ requiredEnv "SERVICE_NAME" }}-{{ requiredEnv "APP_ENV" }}
    namespace: {{ requiredEnv "APP_NAMESPACE" }}-{{ requiredEnv "APP_ENV" }}
    createNamespace: true
    chart: oci://ghcr.io/hungnh1812dev/helmfile-chart-template
    version: 0.1.0
    values:
      - appName: {{ requiredEnv "APP_NAME" }}
        serviceName: {{ requiredEnv "SERVICE_NAME" }}
        appNamespace: {{ requiredEnv "APP_NAMESPACE" }}
        appEnv: {{ requiredEnv "APP_ENV" }}
        appPort: {{ requiredEnv "APP_PORT" }}
        image:
          repository: ghcr.io/acme/shop-api
          tag: "1.2.3"
```

```bash
APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 helmfile apply
```

## Tech Stack

- Helm 3 (OCI registry support, `helm push oci://`), chart `apiVersion: v2`
- Helmfile (consumer side + local example validation)
- GitHub Actions: `actions/checkout`, `azure/setup-helm`
- Registry: `ghcr.io/hungnh1812dev` (auth via built-in `GITHUB_TOKEN`, `packages: write`)

## Commands

```bash
# Lint chart with example values
helm lint charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev

# Render manifests locally
helm template test charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev

# Run template assertion tests (naming, ports, validation failures)
./tests/run.sh

# Render the example helmfile against the local chart
APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 \
  helmfile -f examples/helmfile.yaml.gotmpl template

# Package + publish (what CI does)
helm package charts/helmfile-chart-template -d dist/
helm push dist/helmfile-chart-template-<version>.tgz oci://ghcr.io/hungnh1812dev
```

## Project Structure

```
charts/helmfile-chart-template/
  Chart.yaml              → name, version (source of truth for published version)
  values.yaml             → defaults; the 5 inputs + image + resources
  values.schema.json      → required fields + types (appPort int, names lowercase DNS)
  templates/_helpers.tpl  → fullNamespace, fullServiceName, labels, validation
  templates/deployment.yaml
  templates/service.yaml
examples/
  helmfile.yaml.gotmpl    → consumer template; `chart:` points at local path, comment shows OCI form
tests/
  values-ci.yaml          → valid sample inputs
  run.sh                  → helm template + grep/yq assertions, incl. expected-failure cases
.github/workflows/
  publish.yaml            → lint, test, package, push to GHCR (main only)
README.md                 → consumer instructions
SPEC.md
```

## Chart Behavior

**Values (`values.yaml`):**

```yaml
appName: ""        # required
serviceName: ""    # required
appNamespace: ""   # required
appEnv: ""         # required
appPort: 8080      # required, 1-65535

image:
  repository: ""   # required
  tag: ""          # required
  pullPolicy: IfNotPresent

replicaCount: 1
resources: {}
env: []            # extra container env vars
```

**Rendered resources:**

- `Deployment` named `<fullServiceName>`, one container, `containerPort: appPort`
- `Service` (ClusterIP) named `<fullServiceName>`, `port: appPort` → `targetPort: appPort`
- Both in `.Release.Namespace`; labels `app.kubernetes.io/name=<appName>`, `app.kubernetes.io/component=<serviceName>`, `app.kubernetes.io/instance=<fullServiceName>`, `app.kubernetes.io/part-of=<appNamespace>`, `environment=<appEnv>`
- Selector matches on `app.kubernetes.io/instance`

**Guards (fail at render time with a clear message):**

- Any of the 5 inputs or `image.repository`/`image.tag` empty
- `.Release.Namespace` ≠ `<appNamespace>-<appEnv>` (prevents deploying into the wrong namespace)
- `fullServiceName` longer than 63 chars
- Names not matching `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`

Namespace creation is left to helmfile (`createNamespace: true`), not the chart.

## Code Style

```yaml
{{/* templates/_helpers.tpl */}}
{{- define "chart.fullNamespace" -}}
{{- printf "%s-%s" (required "appNamespace is required" .Values.appNamespace) (required "appEnv is required" .Values.appEnv) -}}
{{- end -}}

{{- define "chart.fullServiceName" -}}
{{- $name := printf "%s-%s-%s" .Values.appName .Values.serviceName .Values.appEnv -}}
{{- if gt (len $name) 63 -}}{{- fail (printf "full service name %q exceeds 63 chars" $name) -}}{{- end -}}
{{- $name -}}
{{- end -}}
```

- camelCase value keys; helpers prefixed `chart.`
- Whitespace-trimmed template actions (`{{-`/`-}}`); 2-space YAML indent
- No hard-coded names — everything derives from helpers

## Testing Strategy

- **Lint:** `helm lint` with `tests/values-ci.yaml` (schema validation included)
- **Render assertions (`tests/run.sh`):** plain bash + `helm template` + `grep`/`yq`
  - happy path: Service/Deployment named `shop-api-dev`, port 8080 on both, labels present
  - failure cases: missing `appName`, wrong release namespace, uppercase name, 64+ char name → `helm template` exits non-zero with expected message
- **Example helmfile:** `helmfile template` on `examples/helmfile.yaml.gotmpl` renders successfully
- All three run in CI before package/push; no cluster required

## CI/CD — `.github/workflows/publish.yaml`

- **Trigger:** `on: push: branches: [main]` only (covers direct pushes and merged PRs). No PR / tag triggers.
- **Permissions:** `contents: read`, `packages: write`
- **Steps:**
  1. Checkout, set up Helm
  2. Lint + `tests/run.sh` + example helmfile template (fail → no publish)
  3. Read `version` from `Chart.yaml`
  4. `helm registry login ghcr.io` with `GITHUB_TOKEN`
  5. If `helm show chart oci://ghcr.io/hungnh1812dev/helmfile-chart-template --version <v>` succeeds → log "version exists, skipping" and exit 0 (never overwrite)
  6. Otherwise `helm package` + `helm push oci://ghcr.io/hungnh1812dev`

## Boundaries

- **Always:** bump `Chart.yaml` `version` (SemVer) for any chart change; keep `examples/helmfile.yaml.gotmpl` and README in sync with values; run `tests/run.sh` before committing
- **Ask first:** adding resources beyond Deployment/Service (Ingress, HPA, ConfigMap…); adding Helm plugins or new CI dependencies; changing derived naming rules (breaking for consumers); changing registry/owner
- **Never:** overwrite an existing published version; commit secrets or PATs (use `GITHUB_TOKEN`); use `_` in Kubernetes object names; trigger publishing from non-main branches

## Success Criteria

1. `helm lint` and `tests/run.sh` pass locally and in CI
2. With inputs `shop/api/shop/dev/8080`, rendered output contains exactly one Deployment and one Service named `shop-api-dev` in namespace `shop-dev`, both using port 8080
3. Rendering fails with a readable error for each guard case listed above
4. Pushing to `main` with a new `Chart.yaml` version publishes `ghcr.io/hungnh1812dev/helmfile-chart-template:<version>`
5. Pushing to `main` with an unchanged version succeeds without re-publishing
6. Pushes to other branches and PRs do not run the workflow
7. A consumer can run `helmfile template` against the OCI chart using only the 5 env vars + image values

## Open Questions

1. **Package visibility:** GHCR packages are private on first publish. Should it be made **public** (manual one-time step in GitHub package settings), or will consumers authenticate with a token?
2. **Repo name vs package name:** the remote is `hungnh1812dev/chart-template`; the package will be `helmfile-chart-template`. OK as-is?
3. **Image input:** the 5 inputs don't include the container image, so `image.repository`/`image.tag` are added as required values. Acceptable, or should image come from another convention (e.g. `ghcr.io/<owner>/<APP_NAME>-<SERVICE_NAME>`)?
4. **Health probes:** add optional liveness/readiness probes on `APP_PORT` (disabled by default)? Currently out of scope.
