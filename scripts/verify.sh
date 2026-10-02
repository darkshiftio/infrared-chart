#!/usr/bin/env bash
# =============================================================================
# What has to stay true about the chart, asserted rather than eyeballed.
# Needs: helm (v3.8+ or v4), kubeconform. Run via `make verify`; CI runs it too.
# =============================================================================
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
chart="$root/charts/infrared"
out="${OUT_DIR:-$root/out/verify}"
mkdir -p "$out"
fail=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }
step() { printf '\n== %s\n' "$*"; }

step "shell"
for f in "$root"/hack/*.sh "$root"/scripts/*.sh; do
  rel="${f#"$root"/}"
  if bash -n "$f"; then ok "bash -n $rel"; else bad "bash -n $rel"; fi
done
if command -v shellcheck >/dev/null; then
  if shellcheck "$root"/hack/*.sh "$root"/scripts/*.sh; then ok shellcheck; else bad shellcheck; fi
fi

# A fresh install outside AWS passes its two secrets with --set-file, from files
# that end in a newline; these stand in for them.
printf 'ci-password\n' >"$out/ci-password"
printf '  ci-cloudflare-token\n\n' >"$out/ci-cloudflare-token"
install=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/install-values.yaml"
  --set-file "imageCredentials.password=$out/ci-password"
  --set-file "platformTokens.cloudflareApiToken=$out/ci-cloudflare-token")

step "helm lint"
for v in "" ci/digests-values.yaml ci/adopted-values.yaml ci/ecr-values.yaml ci/extensions-values.yaml ci/ghcr-values.yaml; do
  if helm lint --strict "$chart" ${v:+-f "$chart/$v"} >"$out/lint.log" 2>&1; then
    ok "lint ${v:-defaults}"
  else
    cat "$out/lint.log"; bad "lint ${v:-defaults}"
  fi
done
if helm lint --strict "$chart" "${install[@]}" >"$out/lint.log" 2>&1; then ok "lint install (ghcr + install values, secrets by --set-file)"
else cat "$out/lint.log"; bad "lint install"; fi

step "helm template"
helm template infrared "$chart" -n infrared --include-crds >"$out/defaults.yaml"
helm template infrared "$chart" -n infrared --include-crds -f "$chart/ci/digests-values.yaml" >"$out/digests.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/adopted-values.yaml" >"$out/adopted.yaml"
helm template other "$chart" -n ir-test >"$out/other.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ecr-values.yaml" >"$out/ecr.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/extensions-values.yaml" >"$out/extensions.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" >"$out/ghcr.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" >"$out/install.yaml"
# What Argo CD renders once it adopts a release outside AWS: the template's
# values carry the registry, the pins and the pull secret's name, and no secret.
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/adopted-values.yaml" >"$out/ghcr-adopted.yaml"
ok "rendered defaults, digests, adopted, other-release, ecr, extensions, ghcr, install, ghcr-adopted"

# envs <render>: every literal env entry of a render as NAME=value, one per line,
# into <render>.env, for assertions on the operator's inputs.
envs() {
  awk '/^ +- name: [A-Z0-9_]+$/ {n=$3; next} n && /^ +value: / {sub(/^ +value: /, ""); print n "=" $0} {n=""}' \
    "$out/$1.yaml" >"$out/$1.env"
}
for f in defaults digests ecr ghcr install ghcr-adopted; do envs "$f"; done
# secret <render> <Secret> <key>: that key of that Secret, decoded.
secret() {
  awk -v s="$2" -v k="$3" '
    /^---/ {n=""} /^  name: / {n=$2}
    n == s && $1 == k":" {gsub(/"/, "", $2); print $2}' "$out/$1.yaml" | base64 --decode
}

step "assertions"
check() { # check <file> <description> <grep -E pattern> [count]
  local n; n="$(grep -cE -- "$3" "$out/$1" || true)"
  if [[ -n "${4:-}" ]]; then
    if [[ "$n" == "$4" ]]; then ok "$2"; else bad "$2 (found $n, want $4)"; fi
  elif (( n > 0 )); then ok "$2"
  else bad "$2"; fi
}
check defaults.yaml "UI Service is named exactly 'infrared', port 80 -> http" '^  name: infrared$'
check defaults.yaml "default images are the pinned preprod builds" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}$' 4
check defaults.yaml "operator runs steps in the pinned runner" 'value: "977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-runner:v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}"$' 1
check defaults.yaml "Go toolchain image pinned by digest" 'value: "golang:[0-9.]+@sha256:[0-9a-f]{64}"$' 1
check defaults.yaml "operator knows the API's cluster address for alert webhooks" 'value: "http://infrared-api.infrared.svc:8080"$' 1
check defaults.yaml "API reads SLOs from VictoriaMetrics" 'value: "http://vmsingle-victoria-metrics-k8s-stack.monitoring.svc:8428"$' 1
check defaults.yaml "API reads runner pod logs" '^    resources: \["pods/log"\]$' 1
check defaults.yaml "four Deployments" '^kind: Deployment$' 4
check defaults.yaml "generated Secrets: setup, session, mcp token, api tokens" '^  name: infrared-(setup|session|mcp-token|api-tokens)$' 4
check defaults.yaml "CRDs included" '^kind: CustomResourceDefinition$'
check defaults.yaml "operator runs with --leader-elect" '^            - --leader-elect$' 1
check defaults.yaml "mcp runs 'serve'" '^            - serve$' 1
check defaults.yaml "UI proxies to infrared-api" 'value: "http://infrared-api:8080"'
check defaults.yaml "UI proxies to infrared-mcp" 'value: "http://infrared-mcp:8080"'
check defaults.yaml "every container read-only root fs" 'readOnlyRootFilesystem: true' 4
check defaults.yaml "every container drops ALL" 'drop:$' 4
check defaults.yaml "cluster name default" 'value: "infrared-mgmt"'
check digests.yaml "pinned images render tag@digest" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):v0.1.0@sha256:[0-9a-f]{64}$' 4
check digests.yaml "pull secret on every pod" '^        - name: ghcr-pull$' 4
check digests.yaml "first pull secret handed to the operator" 'value: "ghcr-pull"' 1
check digests.yaml "extra operator rule appended" '^  - ci.example.com$' 1
check digests.yaml "external URL passed to the api" 'value: "https://infrared.example.com"' 1
check adopted.yaml "adoption renders no Secrets" '^kind: Secret$' 0
check adopted.yaml "mcp reads the existing token Secret" '^                  name: infrared-mcp-token$' 1
check adopted.yaml "mcp enforces the existing access Secret" '^                  name: infrared-mcp-access$' 1
check defaults.yaml "mcp access Secret generated" '^  name: infrared-mcp-access$' 1
check defaults.yaml "mcp enforces a bearer token" '^            - name: INFRARED_MCP_TOKEN$' 1
check ecr.yaml "ECR registry prefixes every image" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):' 4
check ecr.yaml "ECR pinned operator renders tag@digest" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-operator:v0\.1\.0@sha256:[0-9a-f]{64}$' 1
check ecr.yaml "ECR values need no pull secret" 'imagePullSecrets:' 0
# A cluster outside AWS: every image from ghcr by digest, one pull secret for every pod and runner Job.
check ghcr.yaml "ghcr registry prefixes every component, pinned by digest" 'image: ghcr\.io/darkshiftio/infrared-(operator|api|ui|mcp):one-install-[0-9a-f]{7}@sha256:[0-9a-f]{64}$' 4
check ghcr.yaml "operator runs steps in the ghcr runner, pinned by digest" 'value: "ghcr\.io/darkshiftio/infrared-runner:one-install-[0-9a-f]{7}@sha256:[0-9a-f]{64}"$' 1
check ghcr.yaml "the one pull secret on every pod" '^        - name: ghcr-pull$' 4
check ghcr.yaml "the pull secret handed to the operator for runner Jobs" 'value: "ghcr-pull"' 1
check ghcr.yaml "nothing pulls from ECR" '977456087177' 0
# has <file> <description> <whole line, fixed string> [count]
has() {
  local n; n="$(grep -cxF -- "$3" "$out/$1" || true)"
  if [[ "$n" == "${4:-1}" ]]; then ok "$2"; else bad "$2 (found $n, want ${4:-1})"; fi
}
ghcr_pins='{\"api\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000022\",\"tag\":\"one-install-0000002\"},\"mcp\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000024\",\"tag\":\"one-install-0000004\"},\"operator\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000021\",\"tag\":\"one-install-0000001\"},\"runner\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000025\",\"tag\":\"one-install-0000005\"},\"ui\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000023\",\"tag\":\"one-install-0000003\"}}'
# The operator hands a registry other than the default, and every pin, to the
# gitops template (INFRARED_IMAGE_REGISTRY, INFRARED_IMAGES), which writes them
# into the `infrared` Application, so Argo CD keeps them once it adopts the release.
has ghcr.env "registry outside AWS handed to the operator" 'INFRARED_IMAGE_REGISTRY="ghcr.io/darkshiftio"'
has ghcr.env "every pin handed to the operator, as JSON" "INFRARED_IMAGES=\"$ghcr_pins\""
check ghcr.yaml "no pull Secret without imageCredentials" '^type: kubernetes\.io/dockerconfigjson$' 0
has ghcr-adopted.env "after adoption the operator still gets the registry" 'INFRARED_IMAGE_REGISTRY="ghcr.io/darkshiftio"'
has ghcr-adopted.env "after adoption the operator still gets every pin" "INFRARED_IMAGES=\"$ghcr_pins\""
check ghcr-adopted.yaml "after adoption no Secret is rendered, so the install's stay as they are" '^kind: Secret$' 0
check ghcr-adopted.yaml "after adoption every pod still pulls with the pull secret" '^        - name: ghcr-pull$' 4
# The default registry: the chart version's own pins, nothing handed on (and the
# default in values.yaml matches infrared.defaultRegistry).
for f in defaults digests ecr; do
  check "$f.env" "$f: no registry or pins handed to the operator" '^INFRARED_(IMAGE_REGISTRY|IMAGES)=' 0
done
# The Installation's edge and previews, and the two Secrets rendered from values:
# none of it by default, so the default render is what it was.
check defaults.env "no edge or previews by default" '^INFRARED_(EDGE|PREVIEWS)=' 0
check defaults.yaml "no pull Secret by default" '^type: kubernetes\.io/dockerconfigjson$' 0
check defaults.yaml "no platform tokens Secret by default" 'infrared-platform-tokens' 0
# A fresh install from one values file: everything the operator writes to the
# Installation, and every token where it is used.
has install.env "the edge the operator writes to spec.edge" 'INFRARED_EDGE="gateway"'
has install.env "the previews the operator writes to spec.previews, as JSON" \
  'INFRARED_PREVIEWS="{\"domain\":\"preview.example.com\",\"managedRoots\":[],\"signInURL\":\"https://infrared.example.com\"}"'
has install.env "the gitops template at a commit" 'INFRARED_GITOPS_TEMPLATE_VERSION="0123456789abcdef0123456789abcdef01234567"'
has install.env "a trailing slash on the registry is trimmed" 'INFRARED_IMAGE_REGISTRY="ghcr.io/darkshiftio"'
check install.yaml "images name the registry without a double slash" 'ghcr\.io/darkshiftio//' 0
check install.yaml "pull Secret named by imagePullSecrets[0], a dockerconfigjson" '^type: kubernetes\.io/dockerconfigjson$' 1
check install.yaml "the pull Secret is ghcr-pull" '^  name: ghcr-pull$' 1
check install.yaml "platform tokens in Secret infrared-platform-tokens" '^  name: infrared-platform-tokens$' 1
check install.yaml "every Secret from values is kept, like the generated ones" '^    helm\.sh/resource-policy: keep$' 7
want_auth="$(printf 'ci-reader:ci-password' | base64)"
got="$(secret install ghcr-pull .dockerconfigjson)"
if [[ "$got" == "{\"auths\":{\"ghcr.io\":{\"auth\":\"$want_auth\",\"password\":\"ci-password\",\"username\":\"ci-reader\"}}}" ]]; then
  ok "pull Secret holds one ghcr.io entry, the password trimmed"
else bad "pull Secret's .dockerconfigjson is not the one ghcr.io entry expected"; fi
if [[ "$(secret install infrared-platform-tokens cloudflare-api-token)" == ci-cloudflare-token ]]; then
  ok "Cloudflare token under key cloudflare-api-token, whitespace trimmed"
else bad "infrared-platform-tokens' cloudflare-api-token is not the token, trimmed"; fi
check other.yaml "other release names its UI Service <release>-infrared" '^  name: other-infrared$'
check other.yaml "other release proxies to its own api" 'value: "http://other-infrared-api:8080"'

# Extensions: off by default; with ui.extensions, the UI proxies only the declared paths.
check defaults.yaml "no extensions by default: no ConfigMap" '^kind: ConfigMap$' 0
check defaults.yaml "no extensions by default: no mount" 'infrared-ui/extensions' 0
check defaults.yaml "no extensions by default: no proxy secret env" 'INFRARED_EXT_PROXY_SECRET' 0
check defaults.yaml "no extensions by default: no checksum annotation" 'checksum/extensions' 0
check extensions.yaml "extensions ConfigMap <fullname>-ui-extensions" '^  name: infrared-ui-extensions$' 1
check extensions.yaml "extensions ConfigMap keys" '^  (extensions\.json|http\.conf|server\.conf): \|$' 3
check extensions.yaml "extensions.json carries no upstream" '"upstream"' 0
check extensions.yaml "extensions.json defaults the entry" '"entry": "/ext/ledger/ui/entry\.js"' 1
check extensions.yaml "extensions.json defaults the icon" '"icon": "puzzle"' 1
check extensions.yaml "one resolver, filled in by start-nginx" '^    resolver __EXT_RESOLVER__ valid=30s;$' 1
check extensions.yaml "upstream ext_<id> with '-' as '_'" '^    upstream ext_(ledger|field_notes) \{$' 2
check extensions.yaml "upstream resolves its FQDN at run time" '^      server ledger\.ledger\.svc\.cluster\.local:8080 resolve;$' 1
check extensions.yaml "ledger proxies v1 and ui only" '^    location \^~ /ext/ledger/[a-z0-9_-]+/ \{$' 2
check extensions.yaml "v1 prefix stripped to the upstream" '^      proxy_pass http://ext_ledger/v1/;$' 1
check extensions.yaml "declared paths only for field-notes" '^    location \^~ /ext/field-notes/(api|ui)/ \{$' 2
check extensions.yaml "everything else under /ext/<id>/ is 404" '^    location \^~ /ext/(ledger|field-notes)/ \{$' 2
check extensions.yaml "every proxied location asks /_ext_auth first" '^      auth_request /_ext_auth;$' 4
check extensions.yaml "login from the auth response" '^      proxy_set_header X-Infrared-Github [$]ext_github;$' 4
check extensions.yaml "proxy secret placeholder" '^      proxy_set_header X-Infrared-Proxy-Secret "__EXT_PROXY_SECRET__";$' 4
check extensions.yaml "browser cookies never reach an extension" '^      proxy_set_header Cookie "";$' 4
check extensions.yaml "browser Authorization never reaches an extension" '^      proxy_set_header Authorization "";$' 4
check extensions.yaml "an extension's Set-Cookie never reaches the browser" '^      proxy_hide_header Set-Cookie;$' 4
check extensions.yaml "the /api/ proxy headers are repeated" '^      proxy_set_header (Host|X-Forwarded-Proto|X-Forwarded-Host|X-Forwarded-For|X-Forwarded-Prefix|Connection) ' 24
check extensions.yaml "no add_header, so the server's security headers apply" '^ +add_header ' 0
check extensions.yaml "UI mounts the ConfigMap read-only" '^            - mountPath: /etc/infrared-ui/extensions$' 1
check extensions.yaml "UI reads the proxy secret from the existing Secret" '^                  name: "infrared-ext-proxy"$' 1
check extensions.yaml "UI rolls when the ConfigMap changes" '^        checksum/extensions: [0-9a-f]{64}$' 1
# refuse <description> <expected error> <helm template args...>: the render must fail with that error.
refuse() {
  local desc="$1" want="$2"; shift 2
  if helm template infrared "$chart" -n infrared "$@" >/dev/null 2>"$out/refuse.log"; then bad "$desc (rendered)"
  elif grep -qF -- "$want" "$out/refuse.log"; then ok "$desc"
  else cat "$out/refuse.log"; bad "$desc (wrong error)"; fi
}
ext='ui.extensions[0].id=ledger,ui.extensions[0].title=Ledger,ui.extensions[0].upstream=ledger.ledger.svc.cluster.local:8080'
refuse "extensions without a proxy Secret fail" "ui.extensionsProxySecret.existingSecret must name" --set "$ext"
refuse "an upstream that is not an FQDN fails" "/ui/extensions/0/upstream" \
  --set "$ext,ui.extensions[0].upstream=ledger:8080,ui.extensionsProxySecret.existingSecret=x"
refuse "a duplicate extension id fails" 'id "ledger" is listed more than once' \
  --set "$ext,ui.extensions[1].id=ledger,ui.extensions[1].title=Again,ui.extensions[1].upstream=a.b.svc:80,ui.extensionsProxySecret.existingSecret=x"
refuse "an edge other than traefik or gateway fails" "at '/installation/edge'" --set installation.edge=nginx
refuse "previews without a signInURL fail" "missing property 'signInURL'" --set installation.previews.domain=preview.example.com
refuse "a signInURL that is not https fails" "at '/installation/previews/signInURL'" \
  --set installation.previews.domain=preview.example.com,installation.previews.signInURL=http://infrared.example.com
refuse "a template version that is a branch fails" "at '/gitops/templateVersion'" --set gitops.templateVersion=main
refuse "a short commit SHA fails" "at '/gitops/templateVersion'" --set gitops.templateVersion=0123456
refuse "imageCredentials without imagePullSecrets fail" "imageCredentials needs imagePullSecrets[0].name" \
  --set imageCredentials.username=u,imageCredentials.password=p
refuse "a username without a password fails" "imageCredentials needs both username and password" \
  --set 'imageCredentials.username=u,imagePullSecrets[0].name=ghcr-pull'
refuse "platform tokens under another Secret name fail" "at '/platformTokens/existingSecret'" \
  --set platformTokens.existingSecret=other

# The generated operator rules must be present (hack/sync-operator.sh ran).
if awk '/BEGIN GENERATED RULES/{f=1;next} /END GENERATED RULES/{f=0} f' \
     "$chart/templates/operator/clusterrole.yaml" | grep -q '^- apiGroups'; then
  ok "operator ClusterRole carries generated rules"
else bad "operator ClusterRole has no generated rules (run hack/sync-operator.sh)"; fi

step "kubeconform"
for f in defaults digests adopted other ecr extensions ghcr install ghcr-adopted; do
  if kubeconform -strict -ignore-missing-schemas -summary "$out/$f.yaml"; then ok "kubeconform $f"
  else bad "kubeconform $f"; fi
done

echo
if (( fail )); then echo "verify: FAILED"; exit 1; fi
echo "verify: all checks passed"
