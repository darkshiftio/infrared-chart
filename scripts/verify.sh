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

# The gitea chart, vendored by make deps (hack/deps.sh) at Chart.lock's version.
step "dependencies"
if "$root/hack/deps.sh" --check; then ok "charts/ holds the gitea chart Chart.lock names, its sha256 checked"
else bad "dependencies: run make deps"; fi

# A fresh install outside AWS passes its secrets with --set-file, from files
# that end in a newline; these stand in for them.
printf 'ci-password\n' >"$out/ci-password"
printf '  ci-cloudflare-token\n\n' >"$out/ci-cloudflare-token"
printf 'ci-backup-key-id\n' >"$out/ci-backup-key-id"
printf 'ci-backup-secret\n' >"$out/ci-backup-secret"
backup_key=(--set-file "platformTokens.backupAccessKeyId=$out/ci-backup-key-id"
  --set-file "platformTokens.backupSecretAccessKey=$out/ci-backup-secret")
install=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/install-values.yaml"
  --set-file "imageCredentials.password=$out/ci-password"
  --set-file "platformTokens.cloudflareApiToken=$out/ci-cloudflare-token" "${backup_key[@]}")

step "helm lint"
for v in "" ci/digests-values.yaml ci/adopted-values.yaml ci/ecr-values.yaml ci/extensions-values.yaml ci/ghcr-values.yaml ci/stores-adopted-values.yaml; do
  if helm lint --strict "$chart" ${v:+-f "$chart/$v"} >"$out/lint.log" 2>&1; then
    ok "lint ${v:-defaults}"
  else
    cat "$out/lint.log"; bad "lint ${v:-defaults}"
  fi
done
if helm lint --strict "$chart" "${install[@]}" >"$out/lint.log" 2>&1; then ok "lint install (ghcr + install values, secrets by --set-file)"
else cat "$out/lint.log"; bad "lint install"; fi
gitea=(-f "$chart/ci/gitea-values.yaml")
adopted=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/adopted-values.yaml" -f "$chart/ci/stores-adopted-values.yaml")
if helm lint --strict "$chart" "${install[@]}" "${gitea[@]}" >"$out/lint.log" 2>&1; then ok "lint install with Gitea"
else cat "$out/lint.log"; bad "lint install with Gitea"; fi
if helm lint --strict "$chart" "${adopted[@]}" -f "$chart/ci/gitea-adopted-values.yaml" >"$out/lint.log" 2>&1; then ok "lint Gitea after adoption"
else cat "$out/lint.log"; bad "lint Gitea after adoption"; fi
copies=(-f "$chart/ci/copies-values.yaml")
restore=(-f "$chart/ci/restore-values.yaml")
if helm lint --strict "$chart" "${install[@]}" "${gitea[@]}" "${copies[@]}" "${restore[@]}" >"$out/lint.log" 2>&1; then ok "lint a restore with Gitea and the copies"
else cat "$out/lint.log"; bad "lint a restore with Gitea and the copies"; fi

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
# ...and once the template's Application carries the stores, the backup bucket
# and the components left out as well.
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/adopted-values.yaml" \
  -f "$chart/ci/stores-adopted-values.yaml" >"$out/stores-adopted.yaml"
# The backup bucket's key alone, without a Cloudflare token.
helm template infrared "$chart" -n infrared "${backup_key[@]}" >"$out/backup-key.yaml"
# Gitea as the forge: a fresh install, and what Argo CD renders once it adopts it.
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" >"$out/gitea.yaml"
helm template infrared "$chart" -n infrared "${adopted[@]}" -f "$chart/ci/gitea-adopted-values.yaml" >"$out/gitea-adopted.yaml"
# The copies: a fresh install with Gitea and every copy's setting; without
# Gitea; and what Argo CD renders once it adopts the first, whose `infrared`
# Application carries the same copies. And a restore at install.
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" "${copies[@]}" >"$out/copies.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" "${copies[@]}" >"$out/copies-nogitea.yaml"
# The Application carries the cluster's name, the install's.
helm template infrared "$chart" -n infrared "${adopted[@]}" -f "$chart/ci/gitea-adopted-values.yaml" "${copies[@]}" \
  --set managementCluster.name=ci-install >"$out/copies-adopted.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" "${copies[@]}" "${restore[@]}" >"$out/restore.yaml"
ok "rendered defaults, digests, adopted, other-release, ecr, extensions, ghcr, install, ghcr-adopted, stores-adopted, backup-key, gitea, gitea-adopted, copies, copies-nogitea, copies-adopted, restore"

# envs <render>: every literal env entry of a render as NAME=value, one per line,
# into <render>.env, for assertions on the operator's inputs.
envs() {
  awk '/^ +- name: [A-Z0-9_]+$/ {n=$3; next} n && /^ +value: / {sub(/^ +value: /, ""); print n "=" $0} {n=""}' \
    "$out/$1.yaml" >"$out/$1.env"
}
for f in defaults digests ecr ghcr install ghcr-adopted stores-adopted gitea gitea-adopted copies copies-adopted restore; do envs "$f"; done
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
# The operator writes installation.edge to spec.edge: without the field in the
# CRD, the API server would drop it (synced from an operator that has it).
check defaults.yaml "Installation CRD has spec.edge" '^              edge:$' 1
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
if [[ "$(secret install infrared-platform-tokens backup-access-key-id)" == ci-backup-key-id &&
      "$(secret install infrared-platform-tokens backup-secret-access-key)" == ci-backup-secret ]]; then
  ok "the backup bucket's key under backup-access-key-id and backup-secret-access-key, trimmed"
else bad "infrared-platform-tokens' backup-access-key-id or backup-secret-access-key is not the key, trimmed"; fi
# The stores, the backup bucket and the components left out: none by default,
# each handed to the operator for the gitops template from the install's values,
# and still handed on once the template's Application carries them.
check defaults.env "no stores, backup bucket or components left out by default" '^INFRARED_(STORES|BACKUP|DISABLED_COMPONENTS)=' 0
for f in install stores-adopted; do
  has "$f.env" "$f: the stores on" 'INFRARED_STORES="true"'
  has "$f.env" "$f: the backup bucket, as JSON" \
    'INFRARED_BACKUP="{\"bucket\":\"ci-backup\",\"endpoint\":\"https://backup.example.com\",\"region\":\"us-east-1\"}"'
  has "$f.env" "$f: the components left out, as JSON" 'INFRARED_DISABLED_COMPONENTS="[\"infisical\"]"'
done
check stores-adopted.yaml "after adoption with the stores, still no Secret" '^kind: Secret$' 0
check backup-key.yaml "the backup bucket's key alone renders infrared-platform-tokens" '^  name: infrared-platform-tokens$' 1
check backup-key.yaml "...with no Cloudflare key" 'cloudflare-api-token' 0
check backup-key.yaml "...and both of the bucket's keys" '^  backup-(access-key-id|secret-access-key): ' 2
# The install's own registry: none by default, so the default render is what it
# was; handed to the operator and the API from the install's values, and still
# once the template's Application carries it.
check defaults.env "no install registry by default" '^INFRARED_REGISTRY=' 0
for f in install stores-adopted; do
  has "$f.env" "$f: the install's registry, to the operator and the API" 'INFRARED_REGISTRY="10.43.0.50:5000"' 2
done

# Gitea: off by default, so every other render leaves it out.
# obj <render> <kind> <name>: that object's document; objn: how many of its lines match.
obj() {
  awk -v k="$2" -v n="$3" '
    function flush() { if (kind == k && name == n) printf "%s", doc; doc = ""; kind = ""; name = "" }
    /^---/ { flush(); next }
    { doc = doc $0 "\n" }
    /^kind: / { kind = $2 }
    /^  name: / && name == "" { name = $2 }
    END { flush() }' "$out/$1.yaml"
}
objn() { obj "$1" "$2" "$3" | grep -cE -- "$4" || true; }
for f in defaults digests adopted other ecr extensions ghcr install ghcr-adopted stores-adopted backup-key; do
  check "$f.yaml" "$f: no Gitea" '^  name: (gitea|gitea-http|gitea-ssh|gitea-shared-storage|infrared-gitea-admin)$' 0
done
check defaults.env "no Gitea address or admin Secret handed on by default" '^INFRARED_GITEA_' 0
# A fresh install with Gitea: one pod of Gitea 1.27.3 on one volume, its admin
# Secret generated once and kept, its address and that Secret handed on.
gitea_url=http://gitea-http.infrared.svc.cluster.local:3000
has gitea.env "the operator and the API reach Gitea at its Service" "INFRARED_GITEA_URL=\"$gitea_url\"" 2
has gitea.env "the API reads Gitea's admin from infrared-gitea-admin" 'INFRARED_GITEA_ADMIN_SECRET="infrared-gitea-admin"'
check gitea.yaml "five Deployments: Infrared's four and Gitea" '^kind: Deployment$' 5
check gitea.yaml "Gitea 1.27.3, rootless, by digest, in each of its four containers" \
  'image: "docker\.gitea\.com/gitea:1\.27\.3-rootless@sha256:[0-9a-f]{64}"$' 4
if [[ "$(objn gitea Deployment gitea '^  replicas: 1$|^    type: Recreate$')" == 2 ]]; then
  ok "one Gitea pod, replaced with Recreate: its volume is ReadWriteOnce"
else bad "Gitea is not one pod with strategy Recreate"; fi
if [[ "$(objn gitea Deployment gitea '^ +name: infrared-gitea-admin$')" == 2 ]]; then
  ok "Gitea's admin username and password come from infrared-gitea-admin"
else bad "Gitea does not read its admin from infrared-gitea-admin"; fi
if [[ "$(secret gitea infrared-gitea-admin username) $(secret gitea infrared-gitea-admin email)" == "gitea_admin gitea_admin@gitea.local" &&
      "$(secret gitea infrared-gitea-admin password)" =~ ^[A-Za-z0-9]{32}$ &&
      "$(objn gitea Secret infrared-gitea-admin '^    helm\.sh/resource-policy: keep$')" == 1 ]]; then
  ok "infrared-gitea-admin: the admin's username and email, 32 random characters, kept"
else bad "infrared-gitea-admin is not the admin's username, email and a generated password, kept"; fi
svc="$(obj gitea Service gitea-http)"
if grep -qx '  type: ClusterIP' <<<"$svc" && grep -qx '    port: 3000' <<<"$svc" && ! grep -q 'clusterIP: None' <<<"$svc"; then
  ok "Service gitea-http: ClusterIP, not headless, port 3000"
else bad "Service gitea-http is not a ClusterIP Service on port 3000"; fi
pvc="$(obj gitea PersistentVolumeClaim gitea-shared-storage)"
if grep -qx '  storageClassName: "linode-block-storage-retain"' <<<"$pvc" && grep -qx '      storage: 10Gi' <<<"$pvc" &&
   grep -qx '    - ReadWriteOnce' <<<"$pvc" && grep -qx '    helm.sh/resource-policy: keep' <<<"$pvc" &&
   grep -qx '    argocd.argoproj.io/sync-options: Prune=false,Delete=false' <<<"$pvc"; then
  ok "Gitea's claim: 10Gi of the class from values, ReadWriteOnce, kept by helm and never pruned or deleted by Argo CD"
else bad "Gitea's claim is not 10Gi of linode-block-storage-retain, kept and never pruned"; fi
cfg="$(obj gitea Secret gitea-inline-config)"
missing=""
for want in DB_TYPE=sqlite3 ADAPTER=memory TYPE=level DISABLE_REGISTRATION=true REQUIRE_SIGNIN_VIEW=true \
    ENABLE_BASIC_AUTHENTICATION=true DISABLE_SSH=true START_SSH_SERVER=false OFFLINE_MODE=true "ROOT_URL=$gitea_url/"; do
  # A section with one key renders on its own line: `database: DB_TYPE=sqlite3`.
  grep -qxE " +([^ :]+: )?$want" <<<"$cfg" || missing="$missing $want"
done
if [[ -z "$missing" ]] && ! grep -q DISABLE_REGULAR_ORG_CREATION <<<"$cfg"; then
  ok "Gitea: SQLite, memory cache, LevelDB queue, sign-in, no registration, basic auth, no SSH, ROOT_URL is INFRARED_GITEA_URL/"
else bad "Gitea's settings lack:$missing (or refuse users new organizations, which the API's bot needs)"; fi
check gitea.yaml "Gitea has no Ingress" '^kind: Ingress$' 0
check gitea.yaml "no database, cache or test pod of the gitea chart's own" '^# Source: infrared/charts/gitea/charts/|helm\.sh/hook' 0
# What Argo CD renders once it adopts the release: no admin Secret, which Gitea
# still reads; the address and the Secret's name still handed on; and every
# object of Gitea's as the install rendered it, so adoption changes nothing.
check gitea-adopted.yaml "after adoption infrared-gitea-admin is not rendered" '^  name: infrared-gitea-admin$' 0
check gitea-adopted.yaml "...and Gitea still reads it" '^ +name: infrared-gitea-admin$' 2
has gitea-adopted.env "after adoption the operator and the API still reach Gitea" "INFRARED_GITEA_URL=\"$gitea_url\"" 2
has gitea-adopted.env "after adoption the API still reads Gitea's admin Secret" 'INFRARED_GITEA_ADMIN_SECRET="infrared-gitea-admin"'
check gitea-adopted.yaml "after adoption the only Secrets are Gitea's scripts and settings" '^kind: Secret$' 3
gitea_objs() { awk '/^---/ {p = 0} /^# Source: infrared\/charts\/gitea\// {p = 1} p' "$out/$1.yaml"; }
if [[ -n "$(gitea_objs gitea)" ]] && diff <(gitea_objs gitea) <(gitea_objs gitea-adopted) >"$out/gitea-adoption.diff"; then
  ok "after adoption every object of Gitea's renders as the install's: adoption changes nothing of it"
else cat "$out/gitea-adoption.diff"; bad "Argo CD's render of Gitea differs from the install's"; fi
check other.yaml "other release names its UI Service <release>-infrared" '^  name: other-infrared$'
check other.yaml "other release proxies to its own api" 'value: "http://other-infrared-api:8080"'

# The copies: none by default, so every render above is what it was. With a
# recipient, two CronJobs run the operator's copy-objects and put modes, on the
# schedules set, and the settings reach the operator for the gitops template;
# Argo CD's render after adoption, whose `infrared` Application carries the same
# copies, renders them byte for byte.
check defaults.env "no copies, Zot retention or restore handed on by default" '^INFRARED_(COPIES|REGISTRY_RETENTION|RESTORE)=' 0
for f in defaults digests adopted ghcr install ghcr-adopted stores-adopted gitea gitea-adopted; do
  check "$f.yaml" "$f: no copy and no restore" '^  name: (infrared-objects-copy|infrared-gitea-dump|infrared-restore|infrared-gitea-restore)$' 0
done
recipient=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
copies_json='{\"gitea\":{\"retention\":\"8d\",\"schedule\":\"40 * * * *\"},\"mirror\":{\"retention\":\"10d\",\"schedule\":\"47 * * * *\"},\"objects\":{\"retention\":\"9d\",\"schedule\":\"35 * * * *\"},\"postgres\":{\"retention\":\"14d\",\"schedule\":\"0 30 2 * * *\"},\"recipients\":[\"'"$recipient"'\"]}'
retention_json='{\"gcDelay\":\"30m\",\"gcInterval\":\"2h\",\"keepNewest\":20,\"keepTags\":[\"^v[0-9]\",\"^release-\"],\"untaggedAfter\":\"48h\"}'
for f in copies copies-adopted; do
  has "$f.env" "$f: the copies handed to the operator, as JSON" "INFRARED_COPIES=\"$copies_json\""
  has "$f.env" "$f: Zot's retention handed to the operator, as JSON" "INFRARED_REGISTRY_RETENTION=\"$retention_json\""
done
# lines <object text> <whole lines...>: true when every line is in the object.
lines() { local o="$1" l; shift; for l in "$@"; do grep -qxF -- "$l" <<<"$o" || { echo "  missing: $l"; return 1; }; done; }
oc="$(obj copies CronJob infrared-objects-copy)"
gd="$(obj copies CronJob infrared-gitea-dump)"
# Each reader takes its whole input: one that stops early fails the pipe (SIGPIPE).
op_image="$(obj copies Deployment infrared-operator | awk '/^ +image: / && !n {print $2; n = 1}')"
# Each copy's manifest names the version: the chart's appVersion, as the operator's.
app_version="$(awk '/^appVersion:/ {print $2}' "$chart/Chart.yaml")"
gitea_image="$(obj copies Deployment gitea | awk '/^ +image: / && !n {print $2; n = 1}')"
if lines "$oc" '  schedule: "35 * * * *"' '  timeZone: Etc/UTC' '  concurrencyPolicy: Forbid' '      activeDeadlineSeconds: 900' \
    '          serviceAccountName: infrared-objects-copy' "              image: $op_image" '                - copy-objects' \
    '                - --bucket=infrared-objects' '                - --endpoint=http://seaweedfs-s3.stores.svc:8333' \
    '                - --retention=9d' "                - --recipient=$recipient" '                      name: objects-copy-s3' \
    '                - name: INFRARED_VERSION' "                  value: \"$app_version\""; then
  ok "infrared-objects-copy: the operator's copy-objects at 35 past, Forbid, 15 minutes, into infrared-objects, kept 9d, as objects-copy, naming $app_version"
else bad "infrared-objects-copy is not the copy of Infrared's objects the copies values ask for"; fi
if [[ "$(obj copies ClusterRole infrared-objects-copy | grep -E '^ +verbs:' | sort -u)" == '    verbs: ["get", "list"]' ]] \
    && [[ "$(objn copies ClusterRoleBinding infrared-objects-copy '^    name: infrared-objects-copy$')" == 1 ]]; then
  ok "infrared-objects-copy reads Infrared's kinds, namespaces, Secrets and ConfigMaps, and writes nothing"
else bad "infrared-objects-copy's ClusterRole is not read-only"; fi
# shellcheck disable=SC2016,SC1003 # the dump's own command line, matched as it renders
if [[ -n "$gitea_image" ]] && lines "$gd" '  schedule: "40 * * * *"' '  concurrencyPolicy: Forbid' '      activeDeadlineSeconds: 900' \
    '          automountServiceAccountToken: false' '            runAsUser: 1000' '                      app.kubernetes.io/name: gitea' \
    '                      app.kubernetes.io/instance: infrared' '                  topologyKey: kubernetes.io/hostname' \
    "              image: $gitea_image" '                  gitea dump --config "$GITEA_APP_INI" --type tar.gz --skip-log --skip-index \' \
    "              image: $op_image" '                - put' '                - --dir=/dump' '                - --bucket=gitea-dumps' \
    '                - --retention=8d' "                - --recipient=$recipient" '                claimName: gitea-shared-storage' \
    '                      name: gitea-dump-s3' '                - name: INFRARED_VERSION' "                  value: \"$app_version\""; then
  ok "infrared-gitea-dump: Gitea's own image dumps on Gitea's node, then the operator's put, at 40 past, Forbid, 15 minutes, into gitea-dumps, naming $app_version"
else bad "infrared-gitea-dump is not Gitea's dump the copies values ask for"; fi
check copies-nogitea.yaml "without Gitea, the copy of Infrared's objects (its account, rules, binding and CronJob)" '^  name: infrared-objects-copy$' 5
check copies-nogitea.yaml "...no CronJob infrared-gitea-dump" '^  name: infrared-gitea-dump$' 0
same=1
for o in "CronJob infrared-objects-copy" "CronJob infrared-gitea-dump" "ClusterRole infrared-objects-copy" "ClusterRoleBinding infrared-objects-copy" "ServiceAccount infrared-objects-copy"; do
  # shellcheck disable=SC2086 # kind and name
  [[ -n "$(obj copies $o)" && "$(obj copies $o)" == "$(obj copies-adopted $o)" ]] || { echo "  differs after adoption: $o"; same=0; }
done
if [[ "$same" == 1 ]]; then ok "after adoption the copies' CronJobs and RBAC render as the install's"
else bad "Argo CD's render of the copies differs from the install's"; fi

# A restore at install: the operator, the API and the Job infrared-restore get
# INFRARED_RESTORE; the Job's every right is in the ClusterRoleBinding
# infrared-restore; Gitea starts with no pod, and infrared-gitea-restore fills
# its volume as Gitea's user, reading the restore's plan alone. The identity is
# a Secret made before the install: the chart renders none. Argo CD's render,
# which carries no restore, renders none of it (copies-adopted, above).
has restore.env "the operator, the API and the restore Job get INFRARED_RESTORE, as JSON" 'INFRARED_RESTORE="{\"from\":\"2026-10-03T05:00:00Z\"}"' 3
check copies-adopted.yaml "after adoption no restore is rendered" 'INFRARED_RESTORE|^  name: infrared-(gitea-)?restore$' 0
rj="$(obj restore Job infrared-restore)"
if lines "$rj" '      serviceAccountName: infrared-restore' "          image: $op_image" '            - restore' \
    '            - --identity-file=/var/run/infrared/backup-identity/identity' '          values: [2, 3]' \
    '            secretName: infrared-backup-identity' '            optional: true' '            defaultMode: 0440' '        fsGroup: 65532' \
    '                  name: infrared-platform-tokens' '                  key: backup-access-key-id'; then
  ok "infrared-restore: the operator's restore mode, the identity from a Secret made before the install, read by its group alone"
else bad "the Job infrared-restore is wrong"; fi
if [[ "$(objn restore ClusterRoleBinding infrared-restore '^  name: infrared-restore$')" == 2 ]] \
    && [[ "$(grep -cE '^kind: (Role|RoleBinding)$' <<<"$(obj restore Role infrared-restore; obj restore RoleBinding infrared-restore)" || true)" == 0 ]] \
    && [[ "$(obj restore ClusterRole infrared-restore | grep -cE '"delete"' || true)" == 0 ]]; then
  ok "infrared-restore's rights are all in the ClusterRoleBinding infrared-restore, and none deletes"
else bad "infrared-restore's rights are not all in its one ClusterRoleBinding, or one deletes"; fi
gr="$(obj restore Job infrared-gitea-restore)"
if lines "$gr" '      serviceAccountName: infrared-gitea-restore' "          image: $op_image" '            - gitea-restore' '            - --data=/data' \
    '            claimName: gitea-shared-storage' '        runAsUser: 1000' '        fsGroup: 1000' '            defaultMode: 0440' \
    && [[ "$(obj restore Role infrared-gitea-restore | grep -E '^ +(resourceNames|verbs):' | tr -s ' ')" == $' resourceNames: ["infrared-restore"]\n verbs: ["get"]' ]] \
    && [[ "$(objn restore Deployment gitea '^  replicas: 0$')" == 1 ]]; then
  ok "infrared-gitea-restore fills Gitea's volume as Gitea's user, reading the restore's plan alone, while Gitea has no pod"
else bad "the Job infrared-gitea-restore, its Role, or Gitea's replicas are wrong"; fi
check restore.yaml "the chart renders no identity Secret" '^  name: infrared-backup-identity$' 0

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
refuse "a backup key ID without its secret fails" "platformTokens.backupAccessKeyId and platformTokens.backupSecretAccessKey go together" \
  --set-file "platformTokens.backupAccessKeyId=$out/ci-backup-key-id"
refuse "a backup secret without its key ID fails" "platformTokens.backupAccessKeyId and platformTokens.backupSecretAccessKey go together" \
  --set-file "platformTokens.backupSecretAccessKey=$out/ci-backup-secret"
refuse "a backup bucket without its endpoint and region fails" "at '/backup'" --set backup.bucket=ci-backup
refuse "a backup endpoint over http fails" "at '/backup/endpoint'" \
  --set backup.bucket=ci-backup,backup.endpoint=http://backup.example.com,backup.region=us-east-1
refuse "a backup endpoint with a path fails" "at '/backup/endpoint'" \
  --set backup.bucket=ci-backup,backup.endpoint=https://backup.example.com/ci,backup.region=us-east-1
refuse "a bucket name in capitals fails" "at '/backup/bucket'" \
  --set backup.bucket=CI-Backup,backup.endpoint=https://backup.example.com,backup.region=us-east-1
refuse "stores.enabled as a string fails" "at '/stores/enabled'" --set-string stores.enabled=true
refuse "a component left out twice fails" "at '/components/disabled'" --set 'components.disabled={infisical,infisical}'
refuse "a component name in capitals fails" "at '/components/disabled/0'" --set 'components.disabled={Infisical}'
refuse "gitea.enabled as a string fails" "at '/gitea/enabled'" --set-string gitea.enabled=true
refuse "Gitea's admin Secret under another name fails" "at '/giteaAdmin/existingSecret'" --set giteaAdmin.existingSecret=other
refuse "Gitea reading its admin from another Secret fails" "at '/gitea/gitea/admin/existingSecret'" \
  --set gitea.enabled=true,gitea.gitea.admin.existingSecret=other
refuse "Gitea under another name than gitea-http fails" "at '/gitea/fullnameOverride'" --set gitea.fullnameOverride=forge
refuse "a volume size that is not a quantity fails" "at '/gitea/persistence/size'" --set gitea.persistence.size=10
refuse "a registry address with a scheme fails" "at '/registry/address'" --set registry.address=http://10.43.0.50:5000
refuse "a registry address with a path fails" "at '/registry/address'" --set registry.address=10.43.0.50:5000/acme
refuse "a recipient that is not an age key fails" "at '/copies/recipients/0'" --set 'copies.recipients[0]=ssh-ed25519'
refuse "a Postgres schedule of five fields fails" "at '/copies/postgres/schedule'" --set-string 'copies.postgres.schedule=0 3 * * *'
refuse "a retention in hours fails" "at '/copies/objects/retention'" --set copies.objects.retention=168h
refuse "Zot keeping more than 1000 newest tags fails" "at '/registry/retention/keepNewest'" --set registry.retention.keepNewest=1001
refuse "a restore time that is not UTC fails" "at '/restore/from'" --set restore.from=2026-10-03T05:00:00+02:00
refuse "a restore without the stores fails" "restore.enabled needs stores.enabled" --set restore.enabled=true
refuse "a restore without a backup bucket fails" "restore.enabled needs backup.bucket" --set restore.enabled=true,stores.enabled=true
refuse "a restore with Gitea running fails" "needs --set gitea.replicaCount=0" -f "$chart/ci/install-values.yaml" -f "$chart/ci/gitea-values.yaml" --set restore.enabled=true

# The generated operator rules must be present (hack/sync-operator.sh ran).
if awk '/BEGIN GENERATED RULES/{f=1;next} /END GENERATED RULES/{f=0} f' \
     "$chart/templates/operator/clusterrole.yaml" | grep -q '^- apiGroups'; then
  ok "operator ClusterRole carries generated rules"
else bad "operator ClusterRole has no generated rules (run hack/sync-operator.sh)"; fi
check defaults.yaml "the operator writes each org's builder ServiceAccount" '^  - serviceaccounts$' 1
# On a Gateway edge the API reads each zone's HTTPRoute for its links
# (workspace TODO item 89): get, nothing more.
route_rule="$(obj defaults ClusterRole infrared-api | awk '/^  - apiGroups: \["gateway\.networking\.k8s\.io"\]$/ {f=1; print; next} f && /^  (- apiGroups:|#)/ {f=0} f')"
if [[ "$route_rule" == *'resources: ["httproutes"]'* && "$route_rule" == *'verbs: ["get"]'* && "$(grep -c . <<<"$route_rule")" == 3 ]]; then
  ok "the API may get HTTPRoutes"
else bad "the API's ClusterRole has no rule to get HTTPRoutes"; fi
# The platform by layer (workspace TODO item 91): the API reads Argo CD's
# controller, the stores' Postgres and its Backups, and the bucket copy's
# CronJob. get and list, nothing more.
api_rules="$(obj defaults ClusterRole infrared-api)"
for rule in 'apps|"statefulsets"' 'batch|"cronjobs"' 'postgresql.cnpg.io|"clusters", "backups"'; do
  group="${rule%%|*}" resources="${rule#*|}"
  # The rule's three lines: its group, its resources, get and list.
  if grep -A2 -xF "  - apiGroups: [\"$group\"]" <<<"$api_rules" | grep -A1 -xF "    resources: [$resources]" |
       grep -qxF '    verbs: ["get", "list"]'; then
    ok "the API may get and list ${resources//\"/} ($group), for the platform by layer"
  else bad "the API's ClusterRole has no rule to get and list ${resources//\"/} ($group)"; fi
done

step "kubeconform"
for f in defaults digests adopted other ecr extensions ghcr install ghcr-adopted stores-adopted backup-key gitea gitea-adopted copies copies-nogitea copies-adopted restore; do
  if kubeconform -strict -ignore-missing-schemas -summary "$out/$f.yaml"; then ok "kubeconform $f"
  else bad "kubeconform $f"; fi
done

echo
if (( fail )); then echo "verify: FAILED"; exit 1; fi
echo "verify: all checks passed"
