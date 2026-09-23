# helmfile-chart-template

A shared Helm chart that deploys one service (a Deployment and a ClusterIP Service). You supply five inputs, and the chart derives every name from them.

Published to GHCR at `oci://ghcr.io/hungnh1812dev/helmfile-chart-template`.

## Inputs

| Env var         | Chart value    | Example | Meaning                          |
|-----------------|----------------|---------|----------------------------------|
| `APP_NAME`      | `appName`      | `shop`  | Application / product name       |
| `SERVICE_NAME`  | `serviceName`  | `api`   | Service within the application   |
| `APP_NAMESPACE` | `appNamespace` | `shop`  | Base namespace                   |
| `APP_ENV`       | `appEnv`       | `dev`   | Environment                      |
| `APP_PORT`      | `appPort`      | `8080`  | Container and Service port       |

You must also set `image.repository` and `image.tag`.

**Derived names:**

- Namespace: `<APP_NAMESPACE>-<APP_ENV>`, e.g. `shop-dev`
- Deployment and Service name: `<APP_NAME>-<SERVICE_NAME>-<APP_ENV>`, e.g. `shop-api-dev`

Names are joined with `-` because Kubernetes rejects `_` in namespace and Service names.

**Rules (rendering fails with a clear error if any is broken):**

- The four name inputs use only lowercase letters, digits and `-`, and start and end with a letter or digit.
- The full service name is at most 63 characters.
- `APP_PORT` is an integer from 1 to 65535.
- The release is installed into exactly `<APP_NAMESPACE>-<APP_ENV>`.

## Use it from your project

Create `helmfile.yaml.gotmpl` in your project. Helmfile v1 only renders templates such as `requiredEnv` in `*.gotmpl` files, so a plain `helmfile.yaml` will not work.

```yaml
{{- $appName      := requiredEnv "APP_NAME" }}
{{- $serviceName  := requiredEnv "SERVICE_NAME" }}
{{- $appNamespace := requiredEnv "APP_NAMESPACE" }}
{{- $appEnv       := requiredEnv "APP_ENV" }}
{{- $appPort      := requiredEnv "APP_PORT" }}

releases:
  - name: {{ $appName }}-{{ $serviceName }}-{{ $appEnv }}
    namespace: {{ $appNamespace }}-{{ $appEnv }}
    createNamespace: true
    chart: oci://ghcr.io/hungnh1812dev/helmfile-chart-template
    version: 0.3.0
    values:
      - appName: {{ $appName }}
        serviceName: {{ $serviceName }}
        appNamespace: {{ $appNamespace }}
        appEnv: {{ $appEnv }}
        appPort: {{ $appPort }}
        image:
          repository: ghcr.io/acme/shop-api
          tag: "1.2.3"
```

Then deploy:

```bash
APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 helmfile apply
```

If an env var is missing, helmfile stops with `required env var APP_ENV is not set`.

**Optional values:** `replicaCount` (default `1`), `resources`, `env` (a list of extra container env vars), and `image.pullPolicy` (default `Always`, see below). See [values.yaml](charts/helmfile-chart-template/values.yaml).

### Service secret

Set `secrets.enabled: true` to load a Secret into the app container, and into every init container, as environment variables (`envFrom`). The Secret name is derived:

- Secret name: `<APP_NAME>-<SERVICE_NAME>-secrets-<APP_ENV>`, e.g. `shop-api-secrets-dev`

**The chart does not create the Secret.** Create it in the release namespace before deploying, using kubectl, External Secrets or sealed-secrets:

```bash
kubectl -n shop-dev create secret generic shop-api-secrets-dev \
  --from-literal=DATABASE_URL=postgres://...
```

If the Secret is missing, pods do not start. `kubectl describe pod` shows `CreateContainerConfigError` with `secret "shop-api-secrets-dev" not found`.

### Init containers

Set `initContainers.enabled: true` and list plain Kubernetes container specs under `initContainers.containers`. They run in order before the app container.

```yaml
        secrets:
          enabled: true
        initContainers:
          enabled: true
          containers:
            - name: migrate
              image: ghcr.io/acme/shop-api:1.2.3
              command: ["./migrate", "up"]   # sees DATABASE_URL from the secret
```

- Each container needs a `name` (lowercase letters, digits and `-`) and an `image`. Any other container field is passed through unchanged.
- When `secrets.enabled` is true, the chart adds the Secret to the end of each init container's `envFrom`. It keeps any `envFrom` entries you set.
- `enabled: false` renders no init containers, even if `containers` is set, so you can switch them off per environment.
- `enabled: true` with an empty `containers` list fails rendering.

### Health probes

Set `probes.enabled: true` to add HTTP liveness and readiness probes to the app container. Both call `GET <path>` on `APP_PORT` (the container port named `http`). Init containers never get probes.

**Make sure your app serves the path before you turn probes on.** Otherwise Kubernetes keeps restarting the pod (liveness) or never sends it traffic (readiness).

```yaml
        probes:
          enabled: true
          liveness:
            path: /healthz          # default
          readiness:
            path: /readyz           # default /healthz
```

| Setting               | Liveness default | Readiness default |
|-----------------------|------------------|-------------------|
| `path`                | `/healthz`       | `/healthz`        |
| `initialDelaySeconds` | `10`             | `0`               |
| `periodSeconds`       | `10`             | `5`               |
| `timeoutSeconds`      | `1`              | `1`               |
| `failureThreshold`    | `3`              | `3`               |

Override only the fields you need; the rest keep their defaults. The path must start with `/`. Unknown keys, such as a typo like `periodSecond`, fail rendering.

### Image pull policy

Since 0.3.0, `image.pullPolicy` defaults to `Always`: the node pulls the image tag again every time a pod starts, so a re-pushed tag is picked up.

`Always` does **not** redeploy anything by itself. If you run `helmfile apply` with the same tag and values, the Deployment is unchanged and no pods restart, so nothing is pulled. To pick up a re-pushed tag, restart the pods:

```bash
kubectl -n shop-dev rollout restart deployment/shop-api-dev
```

Or deploy a new tag, which is the more reproducible option. To go back to the pre-0.3.0 behavior, set `image.pullPolicy: IfNotPresent`.

## Upgrading

Change `version:` in your helmfile, then check the notes for every version you skip.

### To 0.3.0

- **Behavior change:** `image.pullPolicy` now defaults to `Always` instead of `IfNotPresent`. Every pod start pulls from the registry, which adds a registry call and means a pod can't start while the registry is unreachable. To keep the old behavior, set it explicitly:

  ```yaml
          image:
            pullPolicy: IfNotPresent
  ```

  If you already set `image.pullPolicy`, nothing changes for you.
- **New, off by default:** health probes (`probes.enabled`). See [Health probes](#health-probes).

### To 0.2.0

- No changes needed. With the new options left off, the rendered manifests are identical to 0.1.0.
- **New, off by default:** init containers (`initContainers.enabled`) and the service Secret (`secrets.enabled`). Create the Secret before you set `secrets.enabled: true`. See [Service secret](#service-secret).

## Releasing a new version

1. Change the chart under `charts/helmfile-chart-template/`.
2. Bump `version` in [Chart.yaml](charts/helmfile-chart-template/Chart.yaml), using SemVer.
3. Merge to `main`.

The [Publish chart](.github/workflows/publish.yaml) workflow runs only on pushes to `main`. It lints and tests the chart, then pushes it to GHCR.

**The workflow never overwrites a published version.** If the `Chart.yaml` version already exists on GHCR, it logs `already published, skipping` and succeeds without publishing. Forgetting to bump the version therefore means your change is not released.

### One-time setup after the first publish

GHCR creates new packages as **private**. To let other projects pull the chart without a token, go to GitHub → your profile → **Packages** → `helmfile-chart-template` → **Package settings** and set visibility to **Public**.

If you keep it private, consumers must log in first:

```bash
echo "$TOKEN" | helm registry login ghcr.io -u <user> --password-stdin
```

## Development

The tests need `helm` (v3.8+ or v4) and `helmfile` v1. They don't need a cluster.

```bash
helm lint charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev
./tests/run.sh
```

[tests/run.sh](tests/run.sh) renders the chart and the example [examples/helmfile.yaml.gotmpl](examples/helmfile.yaml.gotmpl). It checks the names, ports and labels, and checks that each kind of invalid input is rejected.

It also compares the default render against [tests/golden/default.yaml](tests/golden/default.yaml), so optional features can't change output for consumers who don't enable them. If you change the default output on purpose, regenerate the golden file:

```bash
helm template test charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev > tests/golden/default.yaml
```

The full requirements are in [SPEC.md](SPEC.md).
