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
    version: 0.1.0
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

**Optional values:** `replicaCount` (default `1`), `resources`, `env` (a list of extra container env vars), and `image.pullPolicy` (default `IfNotPresent`). See [values.yaml](charts/helmfile-chart-template/values.yaml).

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

The full requirements are in [SPEC.md](SPEC.md).
