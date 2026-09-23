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
