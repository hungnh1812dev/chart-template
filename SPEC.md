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

---

# v0.2.0: Optional init containers and service secret

## Objective

Add two opt-in features. Both are **off by default**, so every 0.1.0 consumer upgrading to 0.2.0 gets identical rendered output with no values changes.

1. **Init containers:** run one or more containers before the app container, for example DB migrations, waiting on a dependency, or fetching config.
2. **Service secret:** load a pre-existing Kubernetes Secret named by convention into the app container and every init container as environment variables.

**Decisions (confirmed):**

- **Init container shape:** the flag plus a raw list of standard Kubernetes container specs. The chart does not inherit the image and has no opinionated fields.
- **The flag wins:** `initContainers.enabled: false` renders nothing, even when `containers` is non-empty.
- **Init container guard:** `enabled: true` with an empty `containers` list fails the render.
- **Secret name:** `<appName>-<serviceName>-secrets-<appEnv>` (e.g. `shop-api-secrets-dev`), derived from the existing inputs with no new input. (`APP_SERVICE_NAME` in the request is the existing `SERVICE_NAME`.)
- **Secret consumption:** `envFrom: [{secretRef: {name: <secretName>}}]`, so each key becomes an env var.
- **Secret scope:** the app container and every rendered init container.
- **Secret ownership:** the Secret is created outside the chart, for example with kubectl, External Secrets or sealed-secrets. The chart only references it and never holds secret values. A separate flag, `secrets.enabled` (default `false`), turns the reference on.
- **Secret must exist:** the `secretRef` is not `optional`. If the flag is on and the Secret is missing, pods fail with `CreateContainerConfigError`. That is intended, because a missing secret is a deploy error.

## Values (additions to `values.yaml`)

```yaml
initContainers:
  enabled: false     # set true to render spec.template.spec.initContainers
  containers: []     # plain Kubernetes container specs
  # - name: migrate
  #   image: ghcr.io/acme/shop-api:1.2.3
  #   command: ["./migrate", "up"]

secrets:
  enabled: false     # set true to load Secret <appName>-<serviceName>-secrets-<appEnv>
                     # into the app container and all init containers via envFrom.
                     # The Secret must already exist in <appNamespace>-<appEnv>.
```

## Rendering

**New helper (`_helpers.tpl`):**

```yaml
{{- define "chart.secretName" -}}
{{- printf "%s-%s-secrets-%s" .Values.appName .Values.serviceName .Values.appEnv -}}
{{- end -}}
```

It needs no length guard: `fullServiceName` is 63 characters or fewer, so `secretName` is 71 or fewer, well under the 253-character Secret name limit.

**`templates/deployment.yaml`, pod spec:**

- **Init containers** are rendered before `containers:`, only when `initContainers.enabled` is true. When `secrets.enabled` is also true, each item is deep-copied and the `secretRef` is **appended** to its `envFrom`. Any `envFrom` entries the consumer already has are kept, and the consumer's values are never changed in place.

  ```yaml
      {{- if .Values.initContainers.enabled }}
      initContainers:
        {{- range .Values.initContainers.containers }}
        {{- $c := deepCopy . }}
        {{- if $.Values.secrets.enabled }}
        {{- $_ := set $c "envFrom" (append ($c.envFrom | default list) (dict "secretRef" (dict "name" (include "chart.secretName" $)))) }}
        {{- end }}
        - {{- toYaml $c | nindent 10 | trim | nindent 10 }}
        {{- end }}
      {{- end }}
  ```

  The exact indentation technique will be settled during implementation. The contract is that the output is a valid list of container specs.
- **App container:** when `secrets.enabled` is true, it gets `envFrom: [{secretRef: {name: <secretName>}}]` after `env`.

## Validation

- **Schema (`values.schema.json`):**
  - `initContainers` is an object with `enabled` (boolean) and `containers` (array). Each item is an object that requires `name` and `image`, and `name` must match `dnsName`.
  - `secrets` is an object with `enabled` (boolean).
- **Template guard (`chart.validate`):** if `initContainers.enabled` is true and `containers` is empty, fail with `initContainers.enabled is true but initContainers.containers is empty`.

## Consumer usage

```bash
# one-time, outside helm (or via External Secrets / sealed-secrets)
kubectl -n shop-dev create secret generic shop-api-secrets-dev \
  --from-literal=DATABASE_URL=postgres://...
```

```yaml
    version: 0.2.0
    values:
      - # ...5 inputs + image as before...
        secrets:
          enabled: true
        initContainers:
          enabled: true
          containers:
            - name: migrate
              image: ghcr.io/acme/shop-api:1.2.3
              command: ["./migrate", "up"]   # sees DATABASE_URL from the secret
```

## Files touched

| File | Change |
|---|---|
| `charts/helmfile-chart-template/Chart.yaml` | `version: 0.2.0` |
| `charts/helmfile-chart-template/values.yaml` | add `initContainers` and `secrets` blocks |
| `charts/helmfile-chart-template/values.schema.json` | add `initContainers` and `secrets` schemas |
| `charts/helmfile-chart-template/templates/_helpers.tpl` | `chart.secretName` helper, plus the enabled-but-empty guard in `chart.validate` |
| `charts/helmfile-chart-template/templates/deployment.yaml` | conditional `initContainers:`, plus `envFrom` injection |
| `tests/run.sh` | new assertions (below) |
| `tests/values-init.yaml` | new fixture: `initContainers.enabled: true` with one container |
| `README.md`, `examples/helmfile.yaml.gotmpl` | document both options, the Secret naming convention and the need to pre-create the Secret, and bump version refs to `0.2.0` |

`tests/values-ci.yaml` stays as-is, so it keeps covering the default (both features off) path.

## Testing Strategy (extends `tests/run.sh`)

- **Default off:** the existing render has no `initContainers:`, `envFrom:` or `secrets` reference. Existing assertions stay green, and the resource count is still 2 (the chart never renders a Secret).
- **Init containers only** (`-f values-init.yaml`): `initContainers:` appears before `containers:`, with `name: migrate`, its image and its command, and no `envFrom`.
- **The init container flag wins:** `values-init.yaml` plus `--set initContainers.enabled=false` renders no `initContainers:`.
- **Secrets only** (`--set secrets.enabled=true`): the app container has `envFrom` with `secretRef.name: shop-api-secrets-dev`, and there is no `initContainers:`.
- **Both on** (`-f values-init.yaml --set secrets.enabled=true`): both the app container and the `migrate` init container have the `secretRef` `shop-api-secrets-dev`.
- **Consumer's `envFrom` is kept:** an init container with its own `envFrom` (a `configMapRef`) keeps it, and the `secretRef` is added after it.
- **Guards (`expect_fail`):**
  - `--set initContainers.enabled=true` with empty containers fails, with a message containing `initContainers.containers is empty`
  - an init container with no `image` fails on the schema, with a message naming `image`
  - an init container named `Migrate` (uppercase) fails on the schema
- `helm lint` passes for each fixture combination

## Boundaries (in addition to v0.1.0)

- **Always:** keep the default render (both flags off) byte-identical to 0.1.0; derive the Secret name only through `chart.secretName`
- **Ask first:** making the `secretRef` optional; mounting the Secret as files; inheriting the image from `.Values.image`; shared volumes; sidecars
- **Never:**
  - render a `Secret` resource or accept secret values through Helm values
  - enable either feature by default
  - change a consumer's init container spec in any way beyond appending the `secretRef` to `envFrom` when `secrets.enabled`

## Success Criteria

1. With `tests/values-ci.yaml` alone, `helm template` output is identical to 0.1.0 (`diff` of the renders before and after the change is empty)
2. `initContainers.enabled: true` with one container renders exactly that container under `initContainers`, and `enabled: false` renders none
3. `initContainers.enabled: true` with `containers: []` fails the render with the message above
4. An init container missing `name` or `image`, or with a non-DNS name, fails schema validation
5. `secrets.enabled: true` adds `envFrom.secretRef.name: shop-api-secrets-dev` to the app container and to every rendered init container, keeping any existing `envFrom` entries
6. No test combination renders a `Secret` resource, and the resource count stays 2
7. `tests/run.sh` and `helm lint` pass, `Chart.yaml` is at `0.2.0`, and README and the example are updated
8. After merging to `main`, CI publishes `ghcr.io/hungnh1812dev/helmfile-chart-template:0.2.0`

## Open Questions

1. Should consumers be able to override the Secret name, for example `secrets.name`, when the convention doesn't fit? This is out of scope for 0.2.0.

---

# v0.3.0: Health probes and image pull policy

Requested as 0.2.1. It is released as **0.3.0** because it adds a feature (probes) and changes a default (`pullPolicy`). Under SemVer that is a minor bump, so consumers pinned to `0.2.x` won't get the new default by accident.

## Objective

1. **Always pull the image:** change the `image.pullPolicy` default from `IfNotPresent` to `Always`. The kubelet then re-pulls the tag on every pod start, so a re-pushed tag is picked up when pods restart. Consumers can still override it. `image.tag` stays required.
2. **Health probes:** optional HTTP liveness and readiness probes against the app port, **off by default** and turned on with one flag. This follows the same pattern as `initContainers` and `secrets`.

**Decisions (confirmed):**

- The version is `0.3.0`.
- The `pullPolicy` default becomes `Always`; there is no tag default and no forced rollout annotation.
- Probes are off by default, and `probes.enabled` turns them on.
- Probes are `httpGet` on the named port `http` (= `appPort`), with a configurable path and timing per probe.

**Defaults I chose (change them if they're wrong):**

- Both probes default to path `/healthz`, so an app with one health endpoint works without extra settings. Set `readiness.path` separately if the app has a dedicated readiness endpoint.
- One flag controls both probes; each probe can't be turned on or off separately.

**What "Always" does *not* do:** it only pulls when a pod starts. `helmfile apply` with an unchanged tag and values makes no change to the Deployment, so no pods restart and nothing is re-pulled. To pick up a re-pushed mutable tag, restart the pods (`kubectl rollout restart`) or deploy a new tag. The README must say this.

## Values (changes to `values.yaml`)

```yaml
image:
  repository: ""
  tag: ""
  pullPolicy: Always       # was IfNotPresent

probes:
  enabled: false           # set true to add liveness + readiness httpGet probes on appPort
  liveness:
    path: /healthz
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 1
    failureThreshold: 3
  readiness:
    path: /healthz
    initialDelaySeconds: 0
    periodSeconds: 5
    timeoutSeconds: 1
    failureThreshold: 3
```

## Rendering (`templates/deployment.yaml`, app container)

When `probes.enabled` is true, render after `ports`:

```yaml
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            failureThreshold: 3
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 1
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            ...
```

The timing fields come from the probe's values minus `path` (`omit . "path" | toYaml`), so a consumer who overrides one field keeps the defaults for the others through Helm's value merge. The probes point at the named port `http`, so they follow `appPort` automatically. Init containers never get probes; Kubernetes doesn't allow them there.

## Validation (`values.schema.json`)

- `probes.enabled`: boolean
- `probes.liveness` and `probes.readiness`: objects with `additionalProperties: false`, which catches typos like `periodSecond`
  - `path`: a string starting with `/`
  - `initialDelaySeconds`: an integer, 0 or more
  - `periodSeconds`, `timeoutSeconds` and `failureThreshold`: integers, 1 or more
- `image.pullPolicy`: unchanged (the enum `Always | IfNotPresent | Never`)

## Files touched

| File | Change |
|---|---|
| `charts/helmfile-chart-template/Chart.yaml` | `version: 0.3.0` |
| `charts/helmfile-chart-template/values.yaml` | set the `pullPolicy` default to `Always`, add the `probes` block |
| `charts/helmfile-chart-template/values.schema.json` | add the `probes` schema |
| `charts/helmfile-chart-template/templates/deployment.yaml` | conditional liveness and readiness probes on the app container |
| `tests/golden/default.yaml` | regenerated on purpose; the **only** diff is `imagePullPolicy: IfNotPresent` → `Always` |
| `tests/run.sh` | new assertions (below) |
| `README.md`, `examples/helmfile.yaml.gotmpl` | document both changes, including the "Always ≠ redeploy" caveat, and bump version refs to `0.3.0` |

## Testing Strategy (extends `tests/run.sh`)

- **Pull policy:**
  - The default render has `imagePullPolicy: Always`.
  - `--set image.pullPolicy=IfNotPresent` renders `IfNotPresent`.
  - The golden file is regenerated in the same commit as the default change, and `git diff` on the golden file shows exactly that one line.
- **Probes off by default:** the default render has no `livenessProbe` or `readinessProbe`, and the golden file shows no probe lines.
- **Probes on** (`--set probes.enabled=true`): the app container has both probes, with `path: /healthz`, `port: http` and the default timings.
- **Override:**
  - `--set probes.readiness.path=/readyz` changes only the readiness path.
  - `--set probes.liveness.periodSeconds=30` keeps the other liveness defaults.
- **Init containers stay probe-free:** with `-f values-init.yaml --set probes.enabled=true`, the init section has no probes.
- **Guards (`expect_fail`):**
  - `probes.liveness.path=healthz` (no leading `/`) fails
  - `probes.liveness.periodSeconds=0` fails
  - an unknown key `probes.readiness.periodSecond=5` fails
- The resource count is still 2 in every combination.

## Boundaries (in addition to v0.1.0 and v0.2.0)

- **Always:** regenerate the golden file only in the commit that intentionally changes the default, and make sure its diff shows exactly the intended change
- **Ask first:**
  - startup probes, or turning each probe on and off separately
  - `tcpSocket` or `exec` probes
  - a forced-rollout annotation such as `rollme`
  - defaulting `image.tag` to `latest`
- **Never:**
  - enable probes by default
  - put probes on init containers
  - hard-code the probe port as a number instead of the named port `http`

## Success Criteria

1. The default render differs from 0.2.0 only in `imagePullPolicy: Always`, as the golden file diff shows
2. `image.pullPolicy` overrides still work
3. `probes.enabled: true` renders liveness and readiness `httpGet` probes on `port: http`, with `/healthz` and the documented timings
4. Overriding one probe field keeps the other defaults
5. An invalid path, a non-positive period, or an unknown probe key fails the render
6. Init containers never get probes
7. `tests/run.sh` and `helm lint` pass, `Chart.yaml` is at `0.3.0`, and the README (including the "Always only pulls on pod start" caveat) and the example are updated

## Open Questions

1. Is `/healthz` for both probes right, or should readiness default to `/readyz`?
2. Should each probe be switchable on its own (e.g. readiness only)? This is currently out of scope, under Ask first.
