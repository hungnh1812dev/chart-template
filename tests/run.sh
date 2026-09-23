#!/usr/bin/env bash
# Render-time tests for the chart. Requires only helm + standard shell tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHART="$ROOT/charts/helmfile-chart-template"
VALUES="$ROOT/tests/values-ci.yaml"
NAMESPACE="shop-dev"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

# Print the single rendered document of the given kind.
doc_of_kind() {
  awk -v kind="$1" '
    /^---/ { if (found) exit; buf = ""; next }
    { buf = buf $0 "\n" }
    $0 == "kind: " kind { found = 1 }
    END { if (found) printf "%s", buf }
  ' <<<"$2"
}

assert_has() {
  local doc="$1" pattern="$2" desc="$3"
  grep -Eq -- "$pattern" <<<"$doc" || fail "$desc (pattern: $pattern)"
  pass "$desc"
}

rendered="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE")" \
  || fail "helm template failed on valid values"

# --- Service ---
svc="$(doc_of_kind Service "$rendered")"
[[ -n "$svc" ]] || fail "Service rendered"
assert_has "$svc" '^  name: shop-api-dev$'                          "Service name is <app>-<svc>-<env>"
assert_has "$svc" '^  namespace: shop-dev$'                         "Service namespace is <ns>-<env>"
assert_has "$svc" '^  type: ClusterIP$'                             "Service type is ClusterIP"
assert_has "$svc" '^    - port: 8080$'                              "Service port is appPort"
assert_has "$svc" '^      targetPort: 8080$'                        "Service targetPort is appPort"
assert_has "$svc" 'app.kubernetes.io/name: shop$'                   "label name=appName"
assert_has "$svc" 'app.kubernetes.io/component: api$'               "label component=serviceName"
assert_has "$svc" 'app.kubernetes.io/instance: shop-api-dev$'       "label instance=fullServiceName"
assert_has "$svc" 'app.kubernetes.io/part-of: shop$'                "label part-of=appNamespace"
assert_has "$svc" 'environment: dev$'                               "label environment=appEnv"
assert_has "$svc" '^  selector:$'                                   "Service has selector"
selector="$(sed -n '/^  selector:$/,$p' <<<"$svc")"
assert_has "$selector" '^    app.kubernetes.io/instance: shop-api-dev$' "selector matches on instance"

# --- Deployment ---
deploy="$(doc_of_kind Deployment "$rendered")"
[[ -n "$deploy" ]] || fail "Deployment rendered"
assert_has "$deploy" '^  name: shop-api-dev$'                       "Deployment name is <app>-<svc>-<env>"
assert_has "$deploy" '^  namespace: shop-dev$'                      "Deployment namespace is <ns>-<env>"
assert_has "$deploy" '^  replicas: 1$'                              "Deployment replicas default to 1"
assert_has "$deploy" 'image: "ghcr.io/acme/shop-api:1.2.3"$'        "container image is repository:tag"
assert_has "$deploy" 'containerPort: 8080$'                         "containerPort is appPort"
assert_has "$deploy" '^          imagePullPolicy: Always$'          "imagePullPolicy defaults to Always"
pull_override="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" --set image.pullPolicy=IfNotPresent)" \
  || fail "helm template failed with image.pullPolicy override"
assert_has "$(doc_of_kind Deployment "$pull_override")" '^          imagePullPolicy: IfNotPresent$' \
  "image.pullPolicy override is honored"
match_labels="$(sed -n '/^    matchLabels:$/,/^  template:$/p' <<<"$deploy")"
assert_has "$match_labels" 'app.kubernetes.io/instance: shop-api-dev$' "Deployment selector matches on instance"
pod_labels="$(sed -n '/^  template:$/,/^    spec:$/p' <<<"$deploy")"
assert_has "$pod_labels" 'app.kubernetes.io/instance: shop-api-dev$'   "pod labels match the Service selector"

# --- Resource count ---
kinds="$(grep -c '^kind: ' <<<"$rendered")"
[[ "$kinds" == 2 ]] || fail "exactly 2 resources rendered (got $kinds)"
pass "exactly 2 resources rendered"

# --- Golden: default render (all optional features off) must not change ---
# Regenerate on purpose only:
#   helm template test charts/helmfile-chart-template -f tests/values-ci.yaml --namespace shop-dev > tests/golden/default.yaml
GOLDEN="$ROOT/tests/golden/default.yaml"
[[ -f "$GOLDEN" ]] || fail "golden file missing: $GOLDEN"
golden_diff="$(diff -u "$GOLDEN" - <<<"$rendered")" || fail "default render differs from golden:
$golden_diff"
pass "default render matches golden"

# --- Init containers ---
INIT_VALUES="$ROOT/tests/values-init.yaml"

assert_lacks() {
  local doc="$1" pattern="$2" desc="$3"
  ! grep -Eq -- "$pattern" <<<"$doc" || fail "$desc (unexpected: $pattern)"
  pass "$desc"
}

# Pod-spec sections of a Deployment: init containers vs the app container.
init_part() { sed -n '/^      initContainers:$/,/^      containers:$/p' <<<"$1" | sed '$d'; }
app_part()  { sed -n '/^      containers:$/,$p' <<<"$1"; }

render_deploy() {
  local out
  out="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" "$@")" \
    || fail "helm template failed: $*"
  doc_of_kind Deployment "$out"
}

assert_lacks "$deploy" 'initContainers:' "default render has no initContainers"

init_deploy="$(render_deploy -f "$INIT_VALUES")"
init="$(init_part "$init_deploy")"
[[ -n "$init" ]] || fail "initContainers rendered when enabled"
assert_has "$init" '^ +(- )?name: migrate$'                       "init container name from values"
assert_has "$init" '^ +(- )?image: ghcr.io/acme/shop-api:1.2.3$'  "init container image from values"
assert_has "$init" '^ +- \./migrate$'                             "init container command from values"
init_line="$(grep -n '^      initContainers:$' <<<"$init_deploy" | cut -d: -f1)"
app_line="$(grep -n '^      containers:$' <<<"$init_deploy" | cut -d: -f1)"
(( init_line < app_line )) || fail "initContainers precedes containers"
pass "initContainers precedes containers"
assert_has "$(app_part "$init_deploy")" '^        - name: api$'  "app container still rendered with init enabled"

off_deploy="$(render_deploy -f "$INIT_VALUES" --set initContainers.enabled=false)"
assert_lacks "$off_deploy" 'initContainers:' "enabled=false renders no initContainers even with containers set"

# --- Service secret (pre-existing Secret, referenced via envFrom) ---
assert_lacks "$deploy" 'envFrom:' "default render has no envFrom"

secret_rendered="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" --set secrets.enabled=true)" \
  || fail "helm template failed with secrets.enabled=true"
secret_deploy="$(doc_of_kind Deployment "$secret_rendered")"
secret_app="$(app_part "$secret_deploy")"
assert_has "$secret_app" '^          envFrom:$'                          "secrets: app container has envFrom"
assert_has "$secret_app" '^            - secretRef:$'                    "secrets: app envFrom uses secretRef"
assert_has "$secret_app" '^                name: shop-api-secrets-dev$'  "secrets: Secret name is <app>-<svc>-secrets-<env>"
assert_lacks "$secret_deploy" 'initContainers:'                         "secrets alone renders no initContainers"
assert_lacks "$secret_rendered" '^kind: Secret$'                        "chart never renders a Secret"
kinds="$(grep -c '^kind: ' <<<"$secret_rendered")"
[[ "$kinds" == 2 ]] || fail "secrets: exactly 2 resources rendered (got $kinds)"
pass "secrets: exactly 2 resources rendered"

assert_lacks "$init" 'envFrom:' "init container has no envFrom when secrets disabled"

both_deploy="$(render_deploy -f "$INIT_VALUES" --set secrets.enabled=true)"
both_init="$(init_part "$both_deploy")"
assert_has "$both_init" '^ +- secretRef:$'                         "secrets+init: init container envFrom uses secretRef"
assert_has "$both_init" '^ +name: shop-api-secrets-dev$'           "secrets+init: init container gets the service Secret"
assert_has "$(app_part "$both_deploy")" '^                name: shop-api-secrets-dev$' \
  "secrets+init: app container still gets the service Secret"

keep_deploy="$(render_deploy --set initContainers.enabled=true --set secrets.enabled=true \
  --set-json 'initContainers.containers=[{"name":"migrate","image":"x:1","envFrom":[{"configMapRef":{"name":"shared"}}]}]')"
keep_init="$(init_part "$keep_deploy")"
assert_has "$keep_init" '^ +- configMapRef:$'                      "secrets+init: consumer envFrom entry kept"
assert_has "$keep_init" '^ +name: shared$'                         "secrets+init: consumer envFrom name kept"
cm_line="$(grep -n 'configMapRef:' <<<"$keep_init" | cut -d: -f1)"
sr_line="$(grep -n 'secretRef:' <<<"$keep_init" | cut -d: -f1)"
[[ -n "$sr_line" ]] && (( cm_line < sr_line )) || fail "secretRef appended after consumer envFrom"
pass "secretRef appended after consumer envFrom"

# Every flag combination: exactly Deployment + Service, never a Secret.
for combo in "" "-f $INIT_VALUES" "--set secrets.enabled=true" "-f $INIT_VALUES --set secrets.enabled=true"; do
  # shellcheck disable=SC2086
  out="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" $combo)" || fail "render failed: [$combo]"
  [[ "$(grep -c '^kind: ' <<<"$out")" == 2 ]] && ! grep -q '^kind: Secret$' <<<"$out" \
    || fail "expected exactly Deployment + Service for [$combo]"
done
pass "all flag combinations render exactly Deployment + Service"

# --- Guards: invalid input must fail rendering with a message naming the problem ---
# usage: expect_fail <desc> <expected error regex> [extra helm args...]
expect_fail() {
  local desc="$1" expected="$2"; shift 2
  local out
  if out="$(helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" "$@" 2>&1)"; then
    fail "$desc: rendering should have failed"
  fi
  grep -Eq -- "$expected" <<<"$out" || fail "$desc: unexpected error: $out"
  pass "$desc"
}

LONG_APP="$(printf 'a%.0s' {1..55})"   # 55 + "-api-dev" = 63 ok; 56 → 64

expect_fail "rejects missing appName"       'appName'                   --set appName=
expect_fail "rejects missing image.tag"     'tag'                       --set image.tag=
expect_fail "rejects uppercase serviceName" 'serviceName'               --set serviceName=API
expect_fail "rejects full name > 63 chars"  'exceeds 63'                --set "appName=${LONG_APP}a"
expect_fail "rejects wrong release namespace" 'must be deployed to namespace "shop-dev"' --namespace default
expect_fail "rejects appPort 0"             'appPort'                   --set appPort=0
expect_fail "rejects initContainers enabled with empty list" 'initContainers.containers is empty' \
  --set initContainers.enabled=true
expect_fail "rejects init container without image" 'containers/0.*image' \
  --set initContainers.enabled=true --set-json 'initContainers.containers=[{"name":"migrate"}]'
expect_fail "rejects uppercase init container name" 'containers/0/name' \
  --set initContainers.enabled=true --set-json 'initContainers.containers=[{"name":"Migrate","image":"x:1"}]'

helm template test "$CHART" -f "$VALUES" --namespace "$NAMESPACE" --set "appName=${LONG_APP}" >/dev/null \
  || fail "accepts full name of exactly 63 chars"
pass "accepts full name of exactly 63 chars"

# --- Example consumer helmfile (renders the local chart) ---
HELMFILE="$ROOT/examples/helmfile.yaml.gotmpl"
hf_rendered="$(APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_ENV=dev APP_PORT=8080 \
  helmfile -f "$HELMFILE" template --skip-deps 2>&1)" || fail "helmfile template failed: $hf_rendered"
hf_svc="$(doc_of_kind Service "$hf_rendered")"
hf_deploy="$(doc_of_kind Deployment "$hf_rendered")"
assert_has "$hf_svc"    '^  name: shop-api-dev$'   "helmfile: Service named from env vars"
assert_has "$hf_svc"    '^  namespace: shop-dev$'  "helmfile: release namespace is <ns>-<env>"
assert_has "$hf_svc"    '^    - port: 8080$'       "helmfile: APP_PORT reaches chart as integer"
assert_has "$hf_deploy" '^  name: shop-api-dev$'   "helmfile: Deployment named from env vars"

if out="$(APP_NAME=shop SERVICE_NAME=api APP_NAMESPACE=shop APP_PORT=8080 \
  env -u APP_ENV helmfile -f "$HELMFILE" template --skip-deps 2>&1)"; then
  fail "helmfile: missing APP_ENV should fail"
fi
grep -q 'APP_ENV' <<<"$out" || fail "helmfile: missing APP_ENV error should name it: $out"
pass "helmfile: missing APP_ENV fails and names the variable"

echo "All tests passed."
