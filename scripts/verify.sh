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
# The code index's GitHub App: its ID, its installation's and its private key,
# as an install passes them from SSM.
printf '5116570\n' >"$out/ci-app-id"
printf ' 166002914\n' >"$out/ci-app-installation-id"
printf 'ci-app-key\n\n' >"$out/ci-app-key"
app_key=(--set-file "platformTokens.codeIndexGithubAppId=$out/ci-app-id"
  --set-file "platformTokens.codeIndexGithubAppInstallationId=$out/ci-app-installation-id"
  --set-file "platformTokens.codeIndexGithubAppPrivateKey=$out/ci-app-key")
install=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/install-values.yaml"
  --set-file "imageCredentials.password=$out/ci-password"
  --set-file "platformTokens.cloudflareApiToken=$out/ci-cloudflare-token" "${backup_key[@]}")
# The same install with its backups in Google Cloud Storage: no key, the Jobs'
# ServiceAccounts reach the bucket; Barman's archive is not offered there.
install_gcs=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/install-values.yaml"
  --set-file "imageCredentials.password=$out/ci-password"
  --set-file "platformTokens.cloudflareApiToken=$out/ci-cloudflare-token"
  --set "backup.bucket=darkshift-preprod-backup,backup.endpoint=https://storage.googleapis.com,backup.region=us-central1"
  --set backup.postgres.archive=false)

step "helm lint"
for v in "" ci/digests-values.yaml ci/adopted-values.yaml ci/ecr-values.yaml ci/extensions-values.yaml ci/ghcr-values.yaml ci/stores-adopted-values.yaml ci/registry-token-values.yaml ci/aws-values.yaml; do
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
backups=(-f "$chart/ci/backup-values.yaml")
restore=(-f "$chart/ci/restore-values.yaml")
if helm lint --strict "$chart" "${install[@]}" "${gitea[@]}" "${backups[@]}" "${restore[@]}" >"$out/lint.log" 2>&1; then ok "lint a restore with Gitea and backups"
else cat "$out/lint.log"; bad "lint a restore with Gitea and backups"; fi
if helm lint --strict "$chart" "${install_gcs[@]}" "${gitea[@]}" "${backups[@]}" "${restore[@]}" --set backup.postgres.archive=false >"$out/lint.log" 2>&1; then ok "lint a restore with Gitea and backups in Google Cloud Storage"
else cat "$out/lint.log"; bad "lint a restore with Gitea and backups in Google Cloud Storage"; fi
if helm lint --strict "$chart" "${install[@]}" -f "$chart/ci/code-index-values.yaml" "${app_key[@]}" >"$out/lint.log" 2>&1; then
  ok "lint install with the code index, its record and its GitHub App"
else cat "$out/lint.log"; bad "lint install with the code index"; fi

step "helm template"
helm template infrared "$chart" -n infrared --include-crds >"$out/defaults.yaml"
helm template infrared "$chart" -n infrared --include-crds -f "$chart/ci/digests-values.yaml" >"$out/digests.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/adopted-values.yaml" >"$out/adopted.yaml"
# The MCP Secrets under names of a person's own choosing.
helm template infrared "$chart" -n infrared --set mcp.existingSecret=ci-mcp-token,mcp.access.existingSecret=ci-mcp-access \
  >"$out/mcp-existing.yaml"
helm template other "$chart" -n ir-test >"$out/other.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ecr-values.yaml" >"$out/ecr.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/extensions-values.yaml" >"$out/extensions.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" >"$out/ghcr.yaml"
# A Google install: the registry token, and after Argo CD adopts the release.
helm template infrared "$chart" -n infrared -f "$chart/ci/registry-token-values.yaml" >"$out/registry-token.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/registry-token-values.yaml" -f "$chart/ci/adopted-values.yaml" \
  -f "$chart/ci/stores-adopted-values.yaml" >"$out/registry-token-adopted.yaml"
# A control plane on AWS (ADR 0033): ECR's images, chart and token, on an EC2
# node's role (hostNetwork); on EKS through IRSA (roleArn); and once Argo CD has
# adopted it, from the values the gitops template writes (no `cloud`: the ECR
# registry, chart repository and token are handed on).
helm template infrared "$chart" -n infrared -f "$chart/ci/aws-values.yaml" >"$out/aws.yaml"
helm template infrared "$chart" -n infrared --set cloud=aws,registryToken.aws.region=us-east-1 \
  --set registryToken.aws.roleArn=arn:aws:iam::977456087177:role/ci-registry-reader >"$out/aws-irsa.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/adopted-values.yaml" -f "$chart/ci/stores-adopted-values.yaml" \
  --set image.registry=977456087177.dkr.ecr.us-east-1.amazonaws.com \
  --set gitops.chartRepository=977456087177.dkr.ecr.us-east-1.amazonaws.com/charts \
  --set registryToken.aws.region=us-east-1,registryToken.registry=977456087177.dkr.ecr.us-east-1.amazonaws.com >"$out/aws-adopted.yaml"
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
# Backups: a fresh install with Gitea and every backup setting; without Gitea;
# and what Argo CD renders once it adopts the first, whose `infrared`
# Application carries the same backup values. And a restore at install, of the
# newest backup at or before a time, and of one backup by its stamp.
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" "${backups[@]}" >"$out/backups.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" "${backups[@]}" >"$out/backups-nogitea.yaml"
# The Application carries the cluster's name, the install's.
helm template infrared "$chart" -n infrared "${adopted[@]}" -f "$chart/ci/gitea-adopted-values.yaml" "${backups[@]}" \
  --set managementCluster.name=ci-install >"$out/backups-adopted.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" "${backups[@]}" "${restore[@]}" >"$out/restore.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" "${gitea[@]}" "${backups[@]}" "${restore[@]}" \
  --set restore.from= --set restore.point=20261006T010500Z >"$out/restore-point.yaml"
# The same backups and restore with the bucket in Google Cloud Storage: the
# values after ci/backup-values.yaml turn Barman's archive off again.
helm template infrared "$chart" -n infrared "${install_gcs[@]}" "${gitea[@]}" "${backups[@]}" \
  --set backup.postgres.archive=false >"$out/backups-gcs.yaml"
helm template infrared "$chart" -n infrared "${install_gcs[@]}" "${gitea[@]}" "${backups[@]}" "${restore[@]}" \
  --set backup.postgres.archive=false >"$out/restore-gcs.yaml"
# Substrate's test actors turned on: at install, and once the template's
# Application carries substrate.testActors as well.
helm template infrared "$chart" -n infrared "${install[@]}" --set substrate.testActors=true >"$out/test-actors.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/adopted-values.yaml" \
  -f "$chart/ci/stores-adopted-values.yaml" --set substrate.testActors=true >"$out/test-actors-adopted.yaml"
# Infrared's code index on: at install with its record alone (no token), with
# the install's tokens and its GitHub App, and with a record that names no ref;
# once the template's Application carries codeIndex and
# platformTokens.existingSecret; as a template from before that carries
# codeIndex alone; and with the record in values as an org's values file might.
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" >"$out/code-index.yaml"
helm template infrared "$chart" -n infrared "${install[@]}" -f "$chart/ci/code-index-values.yaml" "${app_key[@]}" \
  >"$out/code-index-install.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" \
  --set codeIndex.knowledge.ref= >"$out/code-index-main.yaml"
code_index_adopted=(-f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/adopted-values.yaml"
  -f "$chart/ci/stores-adopted-values.yaml" -f "$chart/ci/code-index-adopted-values.yaml")
helm template infrared "$chart" -n infrared "${code_index_adopted[@]}" >"$out/code-index-adopted.yaml"
helm template infrared "$chart" -n infrared "${code_index_adopted[@]}" --set platformTokens.existingSecret= \
  >"$out/code-index-adopted-old.yaml"
helm template infrared "$chart" -n infrared "${code_index_adopted[@]}" \
  --set codeIndex.knowledge.url=https://github.com/example-org/knowledge.git >"$out/code-index-adopted-record.yaml"
# The name named by hand as well: listed once.
helm template infrared "$chart" -n infrared --set stores.enabled=true --set registry.address=10.43.0.50:5000 \
  --set 'components.disabled={substrate-test-actors}' >"$out/test-actors-named.yaml"
ok "rendered defaults, digests, adopted, mcp-existing, other-release, ecr, extensions, ghcr, install, ghcr-adopted, stores-adopted, backup-key, gitea, gitea-adopted, backups, backups-nogitea, backups-adopted, backups-gcs, restore, restore-point, restore-gcs, test-actors, test-actors-adopted, test-actors-named, code-index, code-index-install, code-index-main, code-index-adopted, code-index-adopted-old, code-index-adopted-record, registry-token, registry-token-adopted, aws, aws-irsa, aws-adopted"

# envs <render>: every literal env entry of a render as NAME=value, one per line,
# into <render>.env, for assertions on the operator's inputs.
envs() {
  awk '/^ +- name: [A-Z0-9_]+$/ {n=$3; next} n && /^ +value: / {sub(/^ +value: /, ""); print n "=" $0} {n=""}' \
    "$out/$1.yaml" >"$out/$1.env"
}
for f in defaults digests ecr ghcr install ghcr-adopted stores-adopted gitea gitea-adopted backups backups-adopted backups-gcs restore restore-point restore-gcs \
    test-actors test-actors-adopted test-actors-named code-index code-index-install code-index-adopted registry-token registry-token-adopted aws aws-irsa aws-adopted; do envs "$f"; done
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
check defaults.yaml "default images are the pinned preprod builds" 'image: us-central1-docker\.pkg\.dev/darkshift-preprod/infrared/infrared-(operator|api|ui|mcp):v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}$' 4
check defaults.yaml "operator runs steps in the pinned runner" 'value: "us-central1-docker\.pkg\.dev/darkshift-preprod/infrared/infrared-runner:v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}"$' 1
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
check digests.yaml "pinned images render tag@digest" 'image: us-central1-docker\.pkg\.dev/darkshift-preprod/infrared/infrared-(operator|api|ui|mcp):v0.1.0@sha256:[0-9a-f]{64}$' 4
check digests.yaml "pull secret on every pod" '^        - name: ghcr-pull$' 4
check digests.yaml "first pull secret handed to the operator" 'value: "ghcr-pull"' 1
check digests.yaml "extra operator rule appended" '^  - ci.example.com$' 1
check digests.yaml "external URL passed to the api" 'value: "https://infrared.example.com"' 1
check adopted.yaml "adoption renders no Secrets" '^kind: Secret$' 0
check defaults.yaml "mcp access Secret generated" '^  name: infrared-mcp-access$' 1
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
# The operator runs the backup CronJob in its own image, read from here.
has ghcr.env "the operator's own image handed to it, by tag and digest" \
  'INFRARED_OPERATOR_IMAGE="ghcr.io/darkshiftio/infrared-operator:one-install-0000001@sha256:0000000000000000000000000000000000000000000000000000000000000021"'
check defaults.env "the operator's own image handed to it, the default pin" \
  '^INFRARED_OPERATOR_IMAGE="us-central1-docker\.pkg\.dev/darkshift-preprod/infrared/infrared-operator:v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}"$' 1
check ghcr.yaml "no pull Secret without imageCredentials" '^type: kubernetes\.io/dockerconfigjson$' 0
has ghcr-adopted.env "after adoption the operator still gets the registry" 'INFRARED_IMAGE_REGISTRY="ghcr.io/darkshiftio"'
has ghcr-adopted.env "after adoption the operator still gets every pin" "INFRARED_IMAGES=\"$ghcr_pins\""
check ghcr-adopted.yaml "after adoption no Secret is rendered, so the install's stay as they are" '^kind: Secret$' 0
check ghcr-adopted.yaml "after adoption every pod still pulls with the pull secret" '^        - name: ghcr-pull$' 4
# The default registry: the chart version's own pins, nothing handed on (and the
# default in values.yaml matches infrared.defaultRegistry).
for f in defaults digests; do
  check "$f.env" "$f: no registry or pins handed to the operator" '^INFRARED_(IMAGE_REGISTRY|IMAGES)=' 0
done
# ECR was the default before 0.1.0-alpha.146; now it is another registry, handed on like ghcr's.
has ecr.env "ecr: the registry handed to the operator" 'INFRARED_IMAGE_REGISTRY="977456087177.dkr.ecr.us-east-1.amazonaws.com"'
# The Installation's edge and previews, and the two Secrets rendered from values:
# none of it by default, so the default render is what it was.
check defaults.env "no edge or previews by default" '^INFRARED_(EDGE|PREVIEWS)=' 0
check defaults.yaml "no pull Secret by default" '^type: kubernetes\.io/dockerconfigjson$' 0
check defaults.yaml "no platform tokens Secret by default" '^  name: infrared-platform-tokens$' 0
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
  has "$f.env" "$f: the components left out, as JSON, Substrate's test actors among them by default" \
    'INFRARED_DISABLED_COMPONENTS="[\"infisical\",\"substrate-test-actors\"]"'
done
# Substrate's test actors (sandbox-v1 runs any command it is sent) are off
# unless substrate.testActors is true, at install and after adoption alike;
# without the stores and a registry the template runs no Substrate, and the
# chart hands on nothing for them.
for f in test-actors test-actors-adopted; do
  has "$f.env" "$f: substrate.testActors leaves only the components named" 'INFRARED_DISABLED_COMPONENTS="[\"infisical\"]"'
done
has test-actors-named.env "substrate-test-actors named by hand is handed on once" 'INFRARED_DISABLED_COMPONENTS="[\"substrate-test-actors\"]"'
check ghcr-adopted.env "no stores and no registry: nothing left out for the test actors" '^INFRARED_DISABLED_COMPONENTS=' 0
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

# Infrared's code index: off by default, so no render above names it; on, its
# pin joins the images handed to the operator, at install and after adoption,
# and the chart renders nothing more of its own: the gitops template runs it.
for f in defaults digests ecr ghcr install ghcr-adopted stores-adopted; do
  check "$f.env" "$f: no code index handed on" 'code-index' 0
done
ci_pins='{\"api\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000022\",\"tag\":\"one-install-0000002\"},\"code-index\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000026\",\"tag\":\"one-install-0000006\"},\"mcp\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000024\",\"tag\":\"one-install-0000004\"},\"operator\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000021\",\"tag\":\"one-install-0000001\"},\"runner\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000025\",\"tag\":\"one-install-0000005\"},\"ui\":{\"digest\":\"sha256:0000000000000000000000000000000000000000000000000000000000000023\",\"tag\":\"one-install-0000003\"}}'
for f in code-index code-index-adopted; do
  has "$f.env" "$f: the code index's pin handed to the operator among the images, as code-index" "INFRARED_IMAGES=\"$ci_pins\""
  has "$f.env" "$f: with the registry it is named by" 'INFRARED_IMAGE_REGISTRY="ghcr.io/darkshiftio"'
done
check code-index.yaml "the code index adds no object of the chart's own: four Deployments" '^kind: Deployment$' 4
# The chart's own pin, by default: enabled alone runs the image it names.
helm template infrared "$chart" -n infrared -f "$chart/ci/ghcr-values.yaml" --set codeIndex.enabled=true >"$out/code-index-default.yaml"
envs code-index-default
if grep -qF '\"code-index\":{\"digest\":\"sha256:'"$(awk '/^codeIndex:/ {f = 1} f && /^    digest:/ {print $2; exit}' "$chart/values.yaml" | sed 's/^sha256://')"'\",\"tag\":\"'"$(awk '/^codeIndex:/ {f = 1} f && /^    tag:/ {print $2; exit}' "$chart/values.yaml")"'\"}' "$out/code-index-default.env" &&
   grep -qE '^    tag: one-install-[0-9a-f]{7}$' <(sed -n '/^codeIndex:/,/^[a-z]/p' "$chart/values.yaml") &&
   grep -qE '^    digest: sha256:[0-9a-f]{64}$' <(sed -n '/^codeIndex:/,/^[a-z]/p' "$chart/values.yaml"); then
  ok "codeIndex.enabled alone hands on the chart's own pin, a one-install build by digest"
else bad "codeIndex.enabled alone does not hand on the chart's pin by digest"; fi
# objects <render>: each object's kind and name, sorted.
objects() { awk '/^---/ {k = ""} /^kind: / {k = $2} /^  name: / && k {print k "/" $2; k = ""}' "$out/$1.yaml" | sort; }
if diff <(objects stores-adopted) <(objects code-index-adopted) >"$out/code-index.diff"; then
  ok "after adoption the code index renders the same objects as without it"
else cat "$out/code-index.diff"; bad "the code index adds or drops objects of the chart's own"; fi
# Its record and its GitHub App go into infrared-platform-tokens at the install:
# five keys, which the gitops template copies to code-index (code-index-settings
# and code-index-credentials). Without an App its three keys are empty, which
# the code index reads as no credential, so the template's copies always find
# their keys; the record alone renders the Secret; an empty ref is main.
# keys <render>: the data keys of infrared-platform-tokens in that render.
keys() { obj "$1" Secret infrared-platform-tokens | awk '/^data:/ {f = 1; next} f && /^  [a-z]/ {sub(/:.*/, ""); sub(/^  /, ""); print}' | tr '\n' ' ' | sed 's/ $//'; }
ci_keys="code-index-knowledge-url code-index-knowledge-ref code-index-github-app-id code-index-github-app-installation-id code-index-github-app-private-key"
if [[ "$(keys code-index-install)" == "cloudflare-api-token backup-access-key-id backup-secret-access-key $ci_keys" &&
      "$(secret code-index-install infrared-platform-tokens code-index-knowledge-url)" == https://github.com/example-org/knowledge.git &&
      "$(secret code-index-install infrared-platform-tokens code-index-knowledge-ref)" == release-1 &&
      "$(secret code-index-install infrared-platform-tokens code-index-github-app-id)" == 5116570 &&
      "$(secret code-index-install infrared-platform-tokens code-index-github-app-installation-id)" == 166002914 &&
      "$(secret code-index-install infrared-platform-tokens code-index-github-app-private-key)" == ci-app-key &&
      "$(secret code-index-install infrared-platform-tokens cloudflare-api-token)" == ci-cloudflare-token ]]; then
  ok "install: the code index's record and GitHub App in infrared-platform-tokens beside the tokens, trimmed"
else bad "install: infrared-platform-tokens does not hold the code index's record and App as given"; fi
if [[ "$(keys code-index)" == "$ci_keys" &&
      "$(secret code-index infrared-platform-tokens code-index-knowledge-ref)" == release-1 &&
      -z "$(for k in id installation-id private-key; do secret code-index infrared-platform-tokens "code-index-github-app-$k"; done)" ]]; then
  ok "the record alone renders infrared-platform-tokens, the App's three keys empty: public repositories only"
else bad "the code index's record alone does not render its five keys, the App's empty"; fi
if [[ "$(secret code-index-main infrared-platform-tokens code-index-knowledge-ref)" == main ]]; then
  ok "a record with no ref reads main"
else bad "an empty codeIndex.knowledge.ref is not written as main"; fi
check install.yaml "without the code index, none of its keys" '^  code-index-' 0
check code-index-install.yaml "every Secret from values is kept, the tokens' with the code index's keys" '^    helm\.sh/resource-policy: keep$' 7
# Argo CD's render never makes the Secret again: the template's Application
# carries platformTokens.existingSecret with the code index, so even a record
# in an org's values file renders none; and a template from before that, which
# carries codeIndex alone, needs no record and renders none either.
check code-index-adopted.yaml "after adoption with the code index, no Secret: its record and App stay in the install's" '^kind: Secret$' 0
check code-index-adopted-record.yaml "platformTokens.existingSecret: no infrared-platform-tokens from Argo CD, even with the record in values" '^kind: Secret$' 0
check code-index-adopted-old.yaml "a template that carries codeIndex alone renders no Secret and needs no record" '^kind: Secret$' 0
# Agent steps get Infrared's MCP server, with the code tools, at its in-cluster
# listener, only while the code index runs; without it the API's code endpoints
# answer 501 (INFRARED_CODE_INDEX_URL=off).
for f in code-index code-index-adopted; do
  has "$f.env" "$f: steps reach the MCP server's in-cluster listener" 'INFRARED_MCP_URL="http://infrared-mcp.infrared.svc:8081/mcp"'
  has "$f.env" "$f: the runner's proxy holds the MCP access Secret's token" 'INFRARED_MCP_ACCESS_SECRET="infrared-mcp-access"'
  check "$f.env" "$f: the API reaches the code index at its default address" '^INFRARED_CODE_INDEX_URL=' 0
  if [[ "$(objn "$f" Service infrared-mcp '^    - name: (http|code)$')" == 2 && "$(objn "$f" Service infrared-mcp '^      port: 8081$')" == 1 ]] &&
     [[ "$(objn "$f" Deployment infrared-mcp '^              containerPort: 8081$')" == 1 ]]; then
    ok "$f: infrared-mcp listens for steps on 8081 (code), its Service with it"
  else bad "$f: infrared-mcp has no in-cluster listener on 8081"; fi
done
for f in defaults ghcr install ghcr-adopted stores-adopted; do
  has "$f.env" "$f: no code index, so the API's code endpoints answer 501" 'INFRARED_CODE_INDEX_URL="off"'
  check "$f.env" "$f: no MCP server for steps without the code index" '^INFRARED_MCP_(URL|ACCESS_SECRET)=' 0
  if [[ "$(objn "$f" Service infrared-mcp '^    - name: ')" == 1 ]]; then ok "$f: infrared-mcp's Service has its one public port"
  else bad "$f: infrared-mcp's Service has more than its public port"; fi
done
# infrared-mcp gets its two tokens both ways (workspace TODO 156). As files
# from the Secrets' volumes, mounted read-only and never through a subPath,
# which the kubelet does not update: infrared-mcp 640546c and later reads each
# again at every use, in place of its variable, so a rotation, or a restore
# writing the saved tokens back, needs no restart. And as the two secretKeyRef
# variables, exactly as before, so that an image from before the files still
# asks for a token and never serves /mcp open. The Secrets are the chart's,
# under the release's names, or the existingSecret each names in their place,
# which the chart then does not render. None is optional: without its Secret or
# its key the pod does not start.
mcp_token_files() { # mcp_token_files <render> <Deployment> <token Secret> <access Secret>
  local d
  d="$(obj "$1" Deployment "$2")"
  [[ "$(grep -A4 -xF '            - name: INFRARED_API_TOKEN' <<<"$d")" == "            - name: INFRARED_API_TOKEN
              valueFrom:
                secretKeyRef:
                  name: $3
                  key: token" ]] &&
    [[ "$(grep -A4 -xF '            - name: INFRARED_MCP_TOKEN' <<<"$d")" == "            - name: INFRARED_MCP_TOKEN
              valueFrom:
                secretKeyRef:
                  name: $4
                  key: token" ]] &&
    [[ "$(grep -A1 -xF '            - name: INFRARED_API_TOKEN_FILE' <<<"$d")" == '            - name: INFRARED_API_TOKEN_FILE
              value: "/var/run/infrared/api-token/token"' ]] &&
    [[ "$(grep -A1 -xF '            - name: INFRARED_MCP_TOKEN_FILE' <<<"$d")" == '            - name: INFRARED_MCP_TOKEN_FILE
              value: "/var/run/infrared/mcp-access/token"' ]] &&
    [[ "$d" == *"        - name: api-token
          secret:
            items:
            - key: token
              path: token
            secretName: $3
        - name: mcp-access
          secret:
            items:
            - key: token
              path: token
            secretName: $4
      containers:"* ]] &&
    [[ "$d" == *"            - mountPath: /var/run/infrared/api-token
              name: api-token
              readOnly: true
            - mountPath: /var/run/infrared/mcp-access
              name: mcp-access
              readOnly: true
          args:"* ]] &&
    ! grep -qE 'subPath|optional:' <<<"$d"
}
for c in "defaults infrared-mcp infrared-mcp-token infrared-mcp-access" \
    "adopted infrared-mcp infrared-mcp-token infrared-mcp-access" \
    "mcp-existing infrared-mcp ci-mcp-token ci-mcp-access" \
    "other other-infrared-mcp other-infrared-mcp-token other-infrared-mcp-access"; do
  read -r f d token access <<<"$c"
  if mcp_token_files "$f" "$d" "$token" "$access"; then
    ok "$f: $d gets its tokens from $token and $access as the two variables and as files, mounted read-only"
  else bad "$f: $d does not get its tokens from $token and $access as the two variables and as files, mounted read-only without a subPath"; fi
done
check mcp-existing.yaml "mcp-existing: the chart renders neither MCP Secret nor infrared-api-tokens" \
  '^  name: (infrared-mcp-token|infrared-mcp-access|infrared-api-tokens|ci-mcp-token|ci-mcp-access)$' 0

# lines <object text> <whole lines...>: true when every line is in the object.
lines() { local o="$1" l; shift; for l in "$@"; do grep -qxF -- "$l" <<<"$o" || { echo "  missing: $l"; return 1; }; done; }

# Backups: the operator writes the backup CronJob from the Installation's
# spec.backup, and the chart renders none, and no CronJob at all. The backup
# values only seed spec.backup: none by default, so every render above hands
# nothing on; set, they reach the operator as INFRARED_BACKUP and
# INFRARED_COPIES in spec.backup's own shape, the same after adoption, whose
# `infrared` Application carries the same values.
check defaults.env "no backup settings, Zot retention or restore handed on by default" '^INFRARED_(COPIES|REGISTRY_RETENTION|RESTORE)=' 0
for f in defaults digests adopted ghcr install ghcr-adopted stores-adopted gitea gitea-adopted backups backups-nogitea backups-adopted restore; do
  check "$f.yaml" "$f: no CronJob, and nothing of the old copies" '^kind: CronJob$|infrared-objects-copy|infrared-gitea-dump|objects-copy-s3|gitea-dump-s3|copy-objects' 0
done
for f in defaults digests adopted ghcr install ghcr-adopted stores-adopted gitea gitea-adopted; do
  check "$f.yaml" "$f: no restore" '^  name: (infrared-restore|infrared-gitea-restore)$' 0
done
recipient=age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
backup_json='{\"bucket\":\"ci-backup\",\"endpoint\":\"https://backup.example.com\",\"prefix\":\"ci-mgmt\",\"region\":\"us-east-1\"}'
copies_json='{\"mirror\":{\"schedule\":\"47 * * * *\"},\"postgres\":{\"archive\":true},\"recipients\":[\"'"$recipient"'\"],\"retention\":\"10d\",\"schedule\":\"35 * * * *\"}'
retention_json='{\"gcDelay\":\"30m\",\"gcInterval\":\"2h\",\"keepNewest\":20,\"keepTags\":[\"^v[0-9]\",\"^release-\"],\"untaggedAfter\":\"48h\"}'
for f in backups backups-adopted; do
  has "$f.env" "$f: the backup bucket and its prefix, as JSON, for spec.backup.destination" "INFRARED_BACKUP=\"$backup_json\""
  has "$f.env" "$f: the backups' settings in spec.backup's shape, as JSON" "INFRARED_COPIES=\"$copies_json\""
  has "$f.env" "$f: Zot's retention handed to the operator, as JSON" "INFRARED_REGISTRY_RETENTION=\"$retention_json\""
done
# A setting alone hands on only what is set, under spec.backup's names.
helm template infrared "$chart" -n infrared --set backup.recipients[0]="$recipient" >"$out/recipient-alone.yaml"
helm template infrared "$chart" -n infrared --set backup.postgres.archive=true --set-string 'backup.mirror.schedule=17 * * * *' \
  >"$out/archive-alone.yaml"
envs recipient-alone; envs archive-alone
has recipient-alone.env "a recipient alone: only the recipients" "INFRARED_COPIES=\"{\\\"recipients\\\":[\\\"$recipient\\\"]}\""
has archive-alone.env "the archive and the mirror's schedule alone: only those" 'INFRARED_COPIES="{\"mirror\":{\"schedule\":\"17 * * * *\"},\"postgres\":{\"archive\":true}}"'
check recipient-alone.env "...and no bucket handed on without one" '^INFRARED_BACKUP=' 0
# The backup Job's account, which the operator's CronJob names: rendered
# always, since the destination and the recipients can be set in Infrared
# after the install; read only, as infrared-objects-copy was; the same after
# adoption.
same=1
for f in defaults install backups-adopted other; do
  ns=infrared; [[ "$f" == other ]] && ns=ir-test
  # The binding names the role (roleRef) and the account in the release's namespace.
  [[ "$(objn "$f" ServiceAccount infrared-backup "^  namespace: $ns\$")" == 1 ]] \
    && [[ "$(objn "$f" ClusterRoleBinding infrared-backup '^  name: infrared-backup$')" == 2 ]] \
    && [[ "$(objn "$f" ClusterRoleBinding infrared-backup "^    name: infrared-backup\$|^    namespace: $ns\$")" == 2 ]] || same=0
done
backup_role="$(obj defaults ClusterRole infrared-backup)"
if [[ "$same" == 1 ]] && [[ "$(grep -E '^ +verbs:' <<<"$backup_role" | sort -u)" == '    verbs: ["get", "list"]' ]] \
    && grep -qxF '  - apiGroups: ["infrared.darkshift.io"]' <<<"$backup_role" \
    && grep -qxF '    resources: ["namespaces", "secrets", "configmaps"]' <<<"$backup_role" \
    && [[ "$(obj install ClusterRole infrared-backup)" == "$(obj backups-adopted ClusterRole infrared-backup)" ]]; then
  ok "infrared-backup: the backup Job's account, rendered always, reads Infrared's kinds, namespaces, Secrets and ConfigMaps, and writes nothing"
else bad "the backup Job's account infrared-backup is missing, bound wrong, or not read-only"; fi
# The operator writes the backup CronJob: its rules let it (hack/sync-operator.sh,
# from the operator's role).
op_rules="$(awk '/BEGIN GENERATED RULES/{f=1;next} /END GENERATED RULES/{f=0} f' "$chart/templates/operator/clusterrole.yaml")"
if grep -A12 -xF -- '- apiGroups:' <<<"$op_rules" | awk '/^- apiGroups:/ {g = ""} /^  - batch$/ {g = "batch"} g == "batch" && /^  - cronjobs$/ {c = 1} END {exit !c}' \
    && [[ "$(awk '/^  - cronjobs$/ {f = 1; next} f && /^  verbs:/ {v = 1; next} v && /^  - / {printf "%s ", $2; next} v {exit}' <<<"$op_rules")" == "create delete get list patch update watch " ]]; then
  ok "the operator may create, update and delete CronJobs, for the backup CronJob it writes"
else bad "the operator's generated rules do not cover cronjobs (run hack/sync-operator.sh against an operator that has them)"; fi
# The Installation keeps spec.backup and status.backup: without them in the CRD
# the API server would drop what the operator seeds and reports.
check defaults.yaml "Installation CRD has spec.backup and status.backup" '^              backup:$' 2

# A restore at install: the operator, the API and the Job infrared-restore get
# INFRARED_RESTORE; the Job's every right is in the ClusterRoleBinding
# infrared-restore; Gitea starts with no pod, and infrared-gitea-restore fills
# its volume as Gitea's user, reading the restore's plan alone. The identity is
# a Secret made before the install: the chart renders none. Argo CD's render,
# which carries no restore, renders none of it (backups-adopted, above). A
# restore names its backup by a time, or by its stamp (restore.point, what `ir
# restore --backup-artifact` passes), never both.
has restore.env "the operator, the API and the restore Job get INFRARED_RESTORE, as JSON" 'INFRARED_RESTORE="{\"from\":\"2026-10-03T05:00:00Z\"}"' 3
has restore-point.env "...and with restore.point, the backup by its stamp" 'INFRARED_RESTORE="{\"point\":\"20261006T010500Z\"}"' 3
has restore.env "the operator and both restore Jobs read the bucket and its prefix" "INFRARED_BACKUP=\"$backup_json\"" 3
# The bucket's key: both restore Jobs read it from infrared-platform-tokens for
# an S3 bucket (Linode's among them); with Google Cloud Storage, no Job and no
# Secret carries a key: the ServiceAccounts infrared-restore and
# infrared-gitea-restore are the identity, granted the bucket's role outside
# Infrared, as the operator's own and infrared-backup's are. The operator still
# gets the bucket as JSON, with Google's endpoint.
check restore.yaml "both restore Jobs read the bucket's key from infrared-platform-tokens" '^ +key: backup-(access-key-id|secret-access-key)$' 4
check restore-gcs.yaml "with Google Cloud Storage no restore Job mounts a key" '^ +- name: AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)$' 0
check restore-gcs.yaml "...and both restore Jobs still run as their ServiceAccounts" '^      serviceAccountName: infrared-(gitea-)?restore$' 2
check restore-gcs.yaml "...infrared-backup's ServiceAccount, ClusterRole and binding are rendered as always" '^  name: infrared-backup$' 4
check backups-gcs.yaml "...and infrared-platform-tokens holds the Cloudflare token alone, no bucket key" '^  backup-(access-key-id|secret-access-key): ' 0
check backups-gcs.yaml "...the Secret itself still rendered for the Cloudflare token" '^  name: infrared-platform-tokens$' 1
has restore-gcs.env "...the operator and both restore Jobs read the Google bucket, its region the location" \
  'INFRARED_BACKUP="{\"bucket\":\"darkshift-preprod-backup\",\"endpoint\":\"https://storage.googleapis.com\",\"prefix\":\"ci-mgmt\",\"region\":\"us-central1\"}"' 3
check backups-gcs.env "...and INFRARED_COPIES carries no archive with Google Cloud Storage" 'INFRARED_COPIES=.*archive' 0
check backups-adopted.yaml "after adoption no restore is rendered" 'INFRARED_RESTORE|^  name: infrared-(gitea-)?restore$' 0
# Each reader takes its whole input: one that stops early fails the pipe (SIGPIPE).
op_image="$(obj restore Deployment infrared-operator | awk '/^ +image: / && !n {print $2; n = 1}')"
rj="$(obj restore Job infrared-restore)"
if lines "$rj" '      serviceAccountName: infrared-restore' "          image: $op_image" '            - restore' \
    '            - --identity-file=/var/run/infrared/backup-identity/identity' '          values: [2, 3]' \
    '            secretName: infrared-backup-identity' '            optional: true' '            defaultMode: 0440' '        fsGroup: 65532' \
    '                  name: infrared-platform-tokens' '                  key: backup-access-key-id'; then
  ok "infrared-restore: the operator's restore mode, the identity from a Secret made before the install, read by its group alone"
else bad "the Job infrared-restore is wrong"; fi
# The Postgres step (agreed with the operator's restore mode): a native sidecar
# from the platform's Postgres image shares the memory-backed emptyDir
# postgres-restore at /restore/postgres with the restore container, as the
# pod's user (libpq ignores a .pgpass another uid could read); the Job's
# failure policy reads the restore container's exit code alone.
pg_image="$(awk '/^  postgresImage: / {gsub(/"/, "", $2); print $2}' "$chart/values.yaml")"
pg_side="$(awk '/^        - name: postgres$/ {p = 1} p && /^      containers:$/ {exit} p' <<<"$rj")"
if lines "$pg_side" "          image: \"$pg_image\"" '          restartPolicy: Always' '              value: postgres-rw.stores.svc' \
      '              value: require' '              value: /restore/postgres/.pgpass' '              mountPath: /restore/postgres' \
    && lines "$rj" '          containerName: restore' '        - name: postgres-restore' '            medium: Memory' '            sizeLimit: 512Mi' \
    && [[ "$(grep -c '^              mountPath: /restore/postgres$' <<<"$rj")" == 2 ]] \
    && ! grep -q 'runAsUser' <<<"$pg_side" \
    && [[ "$pg_image" == *@sha256:* ]] \
    && [[ "$(grep -c '^  postgresImage: ' "$chart/values.yaml")" == 1 ]]; then
  ok "infrared-restore's Postgres sidecar: restore.postgresImage, the shared memory-backed emptyDir at /restore/postgres, the pod's user, the restore container's exit code alone"
else bad "infrared-restore's Postgres sidecar, its volume or the Job's failure policy is wrong"; fi
# The sidecar's script, run against fakes of psql and pg_restore: it restores
# each database listed in ready once, as its role, with the note in the same
# transaction; a retry finds the note and restores nothing; a database with
# tables and no note, a ready without a point, or a name it cannot quote is
# refused with `failed`.
pg_script="$(awk '/^            - \|$/ {s = 1; next} s && /^              / {sub(/^              /, ""); print; next} s && /^$/ {print; next} s {exit}' <<<"$pg_side")"
fakes="$out/pg-fakes" && rm -rf "$fakes" && mkdir -p "$fakes/bin"
cat >"$fakes/bin/psql" <<'FAKE'
#!/usr/bin/env bash
# A fake psql over files in $FAKE: note-<db> (the database's comment) and
# tables-<db> (its count of tables); -f runs a restore, logged in $FAKE/log.
db="" cmd="" file=""
while [ $# -gt 0 ]; do
  case "$1" in --dbname=*) db="${1#--dbname=}" ;; -c) cmd="$2"; shift ;; -f) file="$2"; shift ;; esac
  shift
done
if [ -n "$file" ]; then
  echo "restore $db: $(head -1 "$file")" >>"$FAKE/log"
  sed -n "s/^COMMENT ON DATABASE \"$db\" IS '\(.*\)';\$/\1/p" "$file" >"$FAKE/note-$db"
  echo 1 >"$FAKE/tables-$db"
  exit 0
fi
case "$cmd" in
  "SELECT 1") echo 1 ;;
  *shobj_description*) cat "$FAKE/note-$db" 2>/dev/null || true ;;
  *pg_tables*) cat "$FAKE/tables-$db" 2>/dev/null || echo 0 ;;
esac
FAKE
cat >"$fakes/bin/pg_restore" <<'FAKE'
#!/usr/bin/env bash
# A fake pg_restore: the dump's lines as SQL, after the flags it was given.
out="" args=""
while [ $# -gt 1 ]; do
  case "$1" in -f) out="$2"; shift ;; *) args="$args $1" ;; esac
  shift
done
{ echo "-- pg_restore$args"; cat "$1"; } >"$out"
FAKE
chmod +x "$fakes/bin/psql" "$fakes/bin/pg_restore"
# pg_run <case> <ready file's text>: runs the script until it writes done or
# failed (10 s at most), then stops it; prints which, and the file's text.
pg_run() {
  local dir="$fakes/$1" pid
  mkdir -p "$dir"
  rm -f "$dir/done" "$dir/failed"
  printf 'CREATE TABLE runs (id int);\n' >"$dir/substrate.dump"
  printf '%s\n' "$2" >"$dir/ready"
  RESTORE_DIR="$dir" FAKE="$fakes" PATH="$fakes/bin:$PATH" sh -ec "$pg_script" >"$dir/log" 2>&1 & pid=$!
  for _ in $(seq 1 100); do
    if [ -f "$dir/done" ] || [ -f "$dir/failed" ]; then break; fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [ -f "$dir/done" ]; then echo "done"; elif [ -f "$dir/failed" ]; then echo "failed: $(cat "$dir/failed")"; else echo none; fi
}
rm -f "$fakes"/note-* "$fakes"/tables-* "$fakes/log"
first="$(pg_run first $'point 20261006T010500Z\nsubstrate substrate')"
again="$(pg_run again $'point 20261006T010500Z\nsubstrate substrate')"
pg_log='restore substrate: -- pg_restore --no-owner --no-privileges --no-comments --role=substrate'
if [[ "$first" == "done" && "$again" == "done" && "$(cat "$fakes/log")" == "$pg_log" ]] \
    && [[ "$(cat "$fakes/note-substrate")" == "infrared-restore 20261006T010500Z: restored" ]] \
    && grep -qF 'restored substrate from its dump, as substrate' "$fakes/first/log" && [ ! -e "$fakes/first/substrate.sql" ] \
    && grep -qF 'was restored for the restore from 20261006T010500Z already' "$fakes/again/log"; then
  ok "the Postgres sidecar restores each database once, as its role, with the note; a retry restores nothing"
else bad "the Postgres sidecar's restore is wrong (first: $first; again: $again; log: $(cat "$fakes/log" 2>/dev/null))"; fi
other="$(pg_run other $'point 20261007T010500Z\nsubstrate substrate')"
nopoint="$(pg_run nopoint 'substrate substrate')"
quoted="$(pg_run quoted $'point 20261006T010500Z\nSubstrate substrate')"
if [[ "$other" == "failed: substrate is not empty (1 tables) and carries no note of the restore from 20261007T010500Z: refusing to restore over it" ]] \
    && [[ "$nopoint" == failed:*"names no point"* ]] && [[ "$quoted" == failed:*"lowercase names" ]] \
    && [[ "$(cat "$fakes/log")" == "$pg_log" ]]; then
  ok "the Postgres sidecar refuses a database with tables and no note of this restore, a ready without a point, and a name it cannot quote"
else bad "the Postgres sidecar's refusals are wrong (other: $other; no point: $nopoint; quoted: $quoted)"; fi
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
refuse "a bucket key with Google Cloud Storage fails" "Google Cloud Storage (backup.endpoint https://storage.googleapis.com) takes none" \
  "${install_gcs[@]}" "${backup_key[@]}"
refuse "Barman's archive with Google Cloud Storage fails" "backup.postgres.archive is not offered with Google Cloud Storage yet" \
  "${install_gcs[@]}" "${gitea[@]}" "${backups[@]}" --set backup.postgres.archive=true
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
refuse "a recipient that is not an age key fails" "at '/backup/recipients/0'" --set 'backup.recipients[0]=ssh-ed25519'
refuse "a backup schedule of six fields fails" "at '/backup/schedule'" --set-string 'backup.schedule=0 5 * * * *'
refuse "a mirror schedule of six fields fails" "at '/backup/mirror/schedule'" --set-string 'backup.mirror.schedule=0 17 * * * *'
refuse "a retention in hours fails" "at '/backup/retention'" --set backup.retention=168h
refuse "a prefix with a slash fails" "at '/backup/prefix'" \
  --set backup.bucket=ci-backup,backup.endpoint=https://backup.example.com,backup.region=us-east-1,backup.prefix=ci/mgmt
refuse "a prefix without the bucket fails" "at '/backup/bucket'" --set backup.prefix=ci-mgmt
refuse "postgres.archive as a string fails" "at '/backup/postgres/archive'" --set-string backup.postgres.archive=true
refuse "the copies values are gone: the backup values take them" "'copies'" --set "copies.recipients[0]=$recipient"
refuse "Zot keeping more than 1000 newest tags fails" "at '/registry/retention/keepNewest'" --set registry.retention.keepNewest=1001
refuse "a restore time that is not UTC fails" "at '/restore/from'" --set restore.from=2026-10-03T05:00:00+02:00
refuse "a restore point that is not a backup's stamp fails" "at '/restore/point'" --set restore.point=2026-10-06T01:05:00Z
refuse "a restore by both a point and a time fails" "restore.point and restore.from both name the backup to restore" \
  -f "$chart/ci/install-values.yaml" "${restore[@]}" --set restore.point=20261006T010500Z
refuse "a restore without the stores fails" "restore.enabled needs stores.enabled" --set restore.enabled=true
refuse "a restore without a backup bucket fails" "restore.enabled needs backup.bucket" --set restore.enabled=true,stores.enabled=true
refuse "a restore with Gitea running fails" "needs --set gitea.replicaCount=0" -f "$chart/ci/install-values.yaml" -f "$chart/ci/gitea-values.yaml" --set restore.enabled=true
# The code index on the default registry (Artifact Registry, since 0.1.0-alpha.146) renders, and the
# default registry is handed to the operator: the template names the code index's image by it.
helm template infrared "$chart" -n infrared -f "$chart/ci/code-index-values.yaml" >"$out/code-index-default.yaml"
check code-index-default.yaml "the code index on the default registry hands that registry to the operator" \
  'value: "us-central1-docker\.pkg\.dev/darkshift-preprod/infrared"$' 1
refuse "the code index without a pin fails" "codeIndex.enabled needs codeIndex.image.tag or codeIndex.image.digest" \
  -f "$chart/ci/ghcr-values.yaml" --set codeIndex.enabled=true,codeIndex.image.tag=,codeIndex.image.digest=
refuse "a code index digest that is not sha256 fails" "at '/codeIndex/image/digest'" \
  -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" --set codeIndex.image.digest=sha256:abc
refuse "codeIndex.enabled as a string fails" "at '/codeIndex/enabled'" --set-string codeIndex.enabled=true
refuse "the code index without its record fails where the tokens render" "codeIndex.enabled needs codeIndex.knowledge.url" \
  "${install[@]}" -f "$chart/ci/code-index-values.yaml" --set codeIndex.knowledge.url=
refuse "a knowledge URL that is not https:// or http:// fails" "at '/codeIndex/knowledge/url'" \
  --set codeIndex.knowledge.url=git@github.com:example-org/knowledge.git
refuse "a knowledge ref the code index refuses fails" "at '/codeIndex/knowledge/ref'" --set codeIndex.knowledge.ref=-x
refuse "the code index's App without its private key fails" "go together, the code index's GitHub App" \
  -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" \
  --set-file "platformTokens.codeIndexGithubAppId=$out/ci-app-id" --set-file "platformTokens.codeIndexGithubAppInstallationId=$out/ci-app-installation-id"
refuse "the code index's private key alone fails" "go together, the code index's GitHub App" \
  -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" --set-file "platformTokens.codeIndexGithubAppPrivateKey=$out/ci-app-key"
refuse "the code index's App without the code index fails" "they need codeIndex.enabled" "${install[@]}" "${app_key[@]}"
# (helm applies --set-file after --set-string, so the ID is not passed by file here)
refuse "an App ID that is not a number fails" "are numbers" \
  -f "$chart/ci/ghcr-values.yaml" -f "$chart/ci/code-index-values.yaml" --set-string platformTokens.codeIndexGithubAppId=app \
  --set-file "platformTokens.codeIndexGithubAppInstallationId=$out/ci-app-installation-id" --set-file "platformTokens.codeIndexGithubAppPrivateKey=$out/ci-app-key"
refuse "an App ID given as a YAML number fails" "at '/platformTokens/codeIndexGithubAppId'" --set platformTokens.codeIndexGithubAppId=5116570
refuse "the registry token beside a pull secret fails" "leave imagePullSecrets and imageCredentials empty" \
  -f "$chart/ci/registry-token-values.yaml" --set 'imagePullSecrets[0].name=ghcr-pull'
refuse "the registry token beside imageCredentials fails" "leave imagePullSecrets and imageCredentials empty" \
  -f "$chart/ci/registry-token-values.yaml" --set imageCredentials.username=ci-reader
refuse "the registry token with images on another registry fails" "but image.registry is on ghcr.io" \
  -f "$chart/ci/registry-token-values.yaml" --set image.registry=ghcr.io/darkshiftio,registryToken.registry=us-central1-docker.pkg.dev
refuse "the registry token with the chart on another registry fails" "but gitops.chartRepository is on ghcr.io" \
  -f "$chart/ci/registry-token-values.yaml" --set gitops.chartRepository=ghcr.io/darkshiftio/charts
refuse "a registry token for a user, not a service account, fails" "at '/registryToken/gcpServiceAccount'" \
  --set registryToken.gcpServiceAccount=someone@example.com
refuse "a registry token's registry with a path fails" "at '/registryToken/registry'" \
  -f "$chart/ci/registry-token-values.yaml" --set registryToken.registry=us-central1-docker.pkg.dev/darkshift-preprod
refuse "the token Job's image without a digest fails" "at '/registryToken/image'" --set registryToken.image=docker.io/alpine/k8s:1.37.0
refuse "a chart repository with oci:// fails" "at '/gitops/chartRepository'" \
  --set gitops.chartRepository=oci://us-central1-docker.pkg.dev/darkshift-preprod/infrared/charts
refuse "a cloud other than gcp or aws fails" "at '/cloud'" --set cloud=azure
refuse "both kinds of registry token fail" "two kinds of registry token: set one" \
  -f "$chart/ci/registry-token-values.yaml" --set registryToken.aws.region=us-east-1
refuse "an ECR token for Artifact Registry's images fails" "but its registry is us-central1-docker.pkg.dev" \
  --set registryToken.aws.region=us-east-1
refuse "an ECR token in another region than the registry fails" "registryToken.aws is for ECR in us-west-2" \
  -f "$chart/ci/aws-values.yaml" --set registryToken.aws.region=us-west-2
refuse "an IRSA role without a region fails" "need registryToken.aws.region" \
  --set registryToken.aws.roleArn=arn:aws:iam::977456087177:role/ci-registry-reader
refuse "an IRSA role that is not a role ARN fails" "at '/registryToken/aws/roleArn'" \
  -f "$chart/ci/aws-values.yaml" --set registryToken.aws.roleArn=ci-registry-reader
refuse "an ECR region that is not a region fails" "at '/registryToken/aws/region'" --set cloud=aws,registryToken.aws.region=east

# The registry token (a Google install): a ServiceAccount bound to the Google
# service account, a Role on its one Secret, the first token at the install and
# a CronJob every 30 minutes, and that Secret as the install's pull secret, with
# the operator told where Substrate's images and the chart come from.
gsa=registry-reader@darkshift-preprod.iam.gserviceaccount.com
for f in registry-token registry-token-adopted; do
  has "$f.env" "$f: registry-token is the pull secret handed to the operator" 'INFRARED_IMAGE_PULL_SECRET="registry-token"'
  has "$f.env" "$f: the token's account and registry handed to the operator, as JSON" \
    "INFRARED_REGISTRY_TOKEN=\"{\\\"gcpServiceAccount\\\":\\\"$gsa\\\",\\\"registry\\\":\\\"us-central1-docker.pkg.dev\\\"}\""
  has "$f.env" "$f: Substrate's images from beside Infrared's own" \
    'INFRARED_SUBSTRATE_REGISTRY="us-central1-docker.pkg.dev/darkshift-preprod/infrared/substrate"'
  has "$f.env" "$f: the chart's repository handed to the operator" \
    'INFRARED_CHART_REPO="us-central1-docker.pkg.dev/darkshift-preprod/infrared/charts"'
  check "$f.yaml" "$f: no pod names a pull secret: the nodes pull as their own account" 'imagePullSecrets:' 0
  check "$f.yaml" "$f: the chart renders no pull Secret: the Job writes it" '^type: kubernetes\.io/dockerconfigjson$' 0
  sa="$(obj "$f" ServiceAccount registry-token)"
  if [[ "$sa" == *"iam.gke.io/gcp-service-account: \"$gsa\""* ]]; then ok "$f: ServiceAccount registry-token bound to $gsa"
  else bad "$f: ServiceAccount registry-token is not annotated with $gsa"; fi
  role="$(obj "$f" Role registry-token | awk '/^rules:/ {f=1; next} f')"
  want_role='  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["registry-token"]
    verbs: ["get", "update", "patch"]'
  if [[ "$role" == "$want_role" ]]; then ok "$f: the Role creates Secrets and gets, updates and patches registry-token alone"
  else bad "$f: the Role registry-token is not exactly create, and get/update/patch on registry-token: $role"; fi
  cron="$(obj "$f" CronJob registry-token)"
  first="$(obj "$f" Job registry-token-first)"
  for job in cron first; do
    body="${!job}"
    if grep -qxE ' +serviceAccountName: registry-token' <<<"$body"; then
      ok "$f: the $job Job runs as registry-token"
    else bad "$f: the $job Job does not run as registry-token"; fi
    if grep -qE 'image: "docker\.io/alpine/k8s:[0-9.]+@sha256:[0-9a-f]{64}"$' <<<"$body"; then ok "$f: the $job Job's image is pinned by digest"
    else bad "$f: the $job Job's image is not pinned by digest"; fi
    # It creates or replaces the Secret, never applies it (the token would stay
    # in an annotation), and prints only names.
    # shellcheck disable=SC2016 # $tok is the script's own word, matched literally
    if grep -q 'kubectl replace -f /work/secret.json' <<<"$body" && grep -q 'kubectl create -f /work/secret.json' <<<"$body" \
       && ! grep -q 'kubectl apply' <<<"$body" && ! grep -qE 'echo .*(\$tok|token\.json|secret\.json)' <<<"$body"; then
      ok "$f: the $job Job creates or replaces the Secret, never applies it, and prints no token"
    else bad "$f: the $job Job applies the Secret or prints the token"; fi
  done
  if grep -qxF '  schedule: "*/30 * * * *"' <<<"$cron" && grep -qxF '  concurrencyPolicy: Forbid' <<<"$cron"; then
    ok "$f: the CronJob writes a new token every 30 minutes, one at a time"
  else bad "$f: the CronJob's schedule is not every 30 minutes"; fi
  if grep -qxF '    helm.sh/hook: post-install,post-upgrade' <<<"$first"; then ok "$f: the first token at the install and every upgrade (a hook)"
  else bad "$f: the first token is not a post-install,post-upgrade hook"; fi
done
check defaults.yaml "no registry token by default" '^  name: registry-token' 0
check defaults.env "no registry token or Substrate registry handed by default" '^INFRARED_(REGISTRY_TOKEN|SUBSTRATE_REGISTRY)=' 0
has defaults.env "the chart's repository handed to the operator, Artifact Registry by default" \
  'INFRARED_CHART_REPO="us-central1-docker.pkg.dev/darkshift-preprod/infrared/charts"'

# A control plane on AWS (ADR 0033): every image and the chart from darkshift's
# ECR, ECR's token as the install's pull secret, and the registry handed on so
# Argo CD keeps it after adoption.
ecr=977456087177.dkr.ecr.us-east-1.amazonaws.com
check aws.yaml "aws: every component image from ECR, pinned by digest" \
  'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):v0\.1\.0-alpha\.[0-9]+@sha256:[0-9a-f]{64}$' 4
check aws.yaml "aws: nothing from Artifact Registry" 'us-central1-docker\.pkg\.dev' 0
for f in aws aws-irsa aws-adopted; do
  has "$f.env" "$f: the chart from ECR" "INFRARED_CHART_REPO=\"$ecr/charts\""
  has "$f.env" "$f: Substrate's images from ECR" "INFRARED_SUBSTRATE_REGISTRY=\"$ecr/substrate\""
  has "$f.env" "$f: ECR handed to the operator, so adoption keeps it" "INFRARED_IMAGE_REGISTRY=\"$ecr\""
  has "$f.env" "$f: registry-token is the pull secret handed to the operator" 'INFRARED_IMAGE_PULL_SECRET="registry-token"'
  # shellcheck disable=SC2016 # $AWS_REGION is the Job's own word, matched literally
  check "$f.yaml" "$f: the token Job asks ECR, as AWS" 'aws ecr get-login-password --region "\$AWS_REGION"' 2
  check "$f.yaml" "$f: the Secret's user is AWS" 'username: "AWS"' 2
  check "$f.yaml" "$f: no Google metadata server" 'metadata\.google\.internal' 0
done
has aws.env "aws: the token as JSON, the node's role on the node's network" "INFRARED_REGISTRY_TOKEN=\"{\\\"aws\\\":{\\\"hostNetwork\\\":true,\\\"region\\\":\\\"us-east-1\\\"},\\\"registry\\\":\\\"$ecr\\\"}\""
has aws-irsa.env "aws-irsa: the token as JSON, with the IRSA role" \
  "INFRARED_REGISTRY_TOKEN=\"{\\\"aws\\\":{\\\"region\\\":\\\"us-east-1\\\",\\\"roleArn\\\":\\\"arn:aws:iam::977456087177:role/ci-registry-reader\\\"},\\\"registry\\\":\\\"$ecr\\\"}\""
check aws.yaml "aws: hostNetwork for the node's role, on the CronJob and the first Job" '^ +hostNetwork: true$' 2
check aws.yaml "aws: no IRSA annotation without roleArn" 'eks\.amazonaws\.com/role-arn' 0
check aws-irsa.yaml "aws-irsa: the ServiceAccount annotated with the role" \
  '^    eks\.amazonaws\.com/role-arn: "arn:aws:iam::977456087177:role/ci-registry-reader"$' 1
check aws-irsa.yaml "aws-irsa: not on the host's network" 'hostNetwork' 0
check aws-adopted.yaml "aws-adopted: adoption renders no Secrets" '^kind: Secret$' 0

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

step "cloud identity (ADR 0033: CloudAccount)"
# The install's identity for cloud accounts: the ServiceAccount infrared-cloud,
# always rendered, annotated for the mode set, and INFRARED_CLOUD_IDENTITY on the
# operator and the API in the exact JSON the operator parses
# (infrared-operator internal/controller/cloud_identity.go).
ci_gsa=infrared-cloud@darkshift-preprod.iam.gserviceaccount.com
ci_role=arn:aws:iam::977456087177:role/ci-infrared-cloud
helm template infrared "$chart" -n infrared --set cloudIdentity.gcpServiceAccount=$ci_gsa >"$out/cloud-gcp.yaml"
helm template infrared "$chart" -n infrared --set cloudIdentity.aws.roleARN=$ci_role >"$out/cloud-irsa.yaml"
helm template infrared "$chart" -n infrared --set cloudIdentity.aws.hostNetwork=true >"$out/cloud-ec2.yaml"
helm template infrared "$chart" -n infrared --set cloudIdentity.gcpServiceAccount=$ci_gsa --set cloudIdentity.aws.webIdentity=true >"$out/cloud-web.yaml"
check defaults.yaml "the ServiceAccount infrared-cloud is always made" '^  name: infrared-cloud$' 1
check defaults.yaml "infrared-cloud's token is not mounted" '^automountServiceAccountToken: false$' 1
check defaults.yaml "no cloud identity: no INFRARED_CLOUD_IDENTITY" 'name: INFRARED_CLOUD_IDENTITY$' 0
check defaults.yaml "no cloud identity: infrared-cloud unannotated" '(iam\.gke\.io/gcp-service-account|eks\.amazonaws\.com/role-arn): ' 0
check cloud-gcp.yaml "Google: infrared-cloud bound by Workload Identity" "^    iam\.gke\.io/gcp-service-account: \"$ci_gsa\"$" 1
check cloud-gcp.yaml "Google: the operator and the API get the service account" "value: \"\{\\\\\"gcpServiceAccount\\\\\":\\\\\"$ci_gsa\\\\\"\}\"$" 2
check cloud-irsa.yaml "IRSA: infrared-cloud annotated with the role" "^    eks\.amazonaws\.com/role-arn: \"$ci_role\"$" 1
check cloud-irsa.yaml "IRSA: the role in the JSON" "value: \"\{\\\\\"aws\\\\\":\{\\\\\"roleARN\\\\\":\\\\\"$ci_role\\\\\"\}\}\"$" 2
check cloud-ec2.yaml "EC2: hostNetwork in the JSON, no annotation" 'value: "\{\\"aws\\":\{\\"hostNetwork\\":true\}\}"$' 2
check cloud-ec2.yaml "EC2: infrared-cloud unannotated" '(iam\.gke\.io/gcp-service-account|eks\.amazonaws\.com/role-arn): ' 0
check cloud-web.yaml "both clouds: web identity beside the service account" "value: \"\{\\\\\"aws\\\\\":\{\\\\\"webIdentity\\\\\":true\},\\\\\"gcpServiceAccount\\\\\":\\\\\"$ci_gsa\\\\\"\}\"$" 2
refuse "two AWS modes fail" "set at most one of roleARN, hostNetwork and webIdentity" \
  --set cloudIdentity.aws.hostNetwork=true --set cloudIdentity.aws.webIdentity=true
refuse "a cloud identity that is not a Google service account fails" "at '/cloudIdentity/gcpServiceAccount'" \
  --set cloudIdentity.gcpServiceAccount=someone@example.com
refuse "a role that is not an IAM role ARN fails" "at '/cloudIdentity/aws/roleARN'" \
  --set cloudIdentity.aws.roleARN=arn:aws:s3:::bucket
# The CloudAccount CRD and the operator's rights to it (hack/sync-operator.sh).
check defaults.yaml "the CloudAccount CRD is included" '^    kind: CloudAccount$' 1
cr="$(awk '/^kind: ClusterRole$/{c=1} c' "$out/defaults.yaml")"
if grep -qxF '  - cloudaccounts/status' <<<"$cr" && grep -qxF '  - cloudaccounts' <<<"$cr"; then ok "the operator may read CloudAccounts and write their status"
else bad "the operator's ClusterRole lacks cloudaccounts or cloudaccounts/status (run hack/sync-operator.sh)"; fi
# With a sibling operator checkout named, its CRD must be this chart's, byte for byte.
if [[ -n "${INFRARED_OPERATOR_DIR:-}" ]]; then
  if cmp -s "$INFRARED_OPERATOR_DIR/config/crd/bases/infrared.darkshift.io_cloudaccounts.yaml" "$chart/crds/infrared.darkshift.io_cloudaccounts.yaml"; then
    ok "the CloudAccount CRD matches $INFRARED_OPERATOR_DIR"
  else bad "the CloudAccount CRD differs from $INFRARED_OPERATOR_DIR (run hack/sync-operator.sh)"; fi
fi

step "org registries' credentials (ADR 0033: Registry)"
# The namespace the credential Jobs write tokens to, where infrared-cloud may
# create and update Secrets and nothing else; the operator learns its name.
helm template infrared "$chart" -n infrared --set registryCredentials.namespace=ci-registry-creds >"$out/registry-creds.yaml"
check defaults.yaml "the credentials namespace is made" '^  name: infrared-registry-credentials$' 1
check defaults.yaml "infrared-cloud may create and update Secrets there, nothing more" '^    verbs: \["create", "update"\]$' 1
subj="$(yq 'select(.kind == "RoleBinding" and .metadata.name == "infrared-cloud-registry-credentials") | .subjects[0] | .kind + " " + .namespace + "/" + .name' "$out/defaults.yaml")"
if [[ "$subj" == "ServiceAccount infrared/infrared-cloud" ]]; then ok "the RoleBinding's subject is infrared/infrared-cloud"
else bad "the credentials RoleBinding binds '$subj', not ServiceAccount infrared/infrared-cloud"; fi
check defaults.yaml "the operator learns the credentials namespace" 'name: INFRARED_REGISTRY_CREDENTIALS_NAMESPACE$' 1
check registry-creds.yaml "another namespace: made and handed to the operator" '^  name: ci-registry-creds$|value: "ci-registry-creds"$' 2
refuse "a credentials namespace that is not a DNS label fails" "at '/registryCredentials/namespace'" \
  --set registryCredentials.namespace=Not_A_Name
# The Registry CRD, the Organization's buildRegistry and the operator's rights to Registries.
check defaults.yaml "the Registry CRD is included" '^    kind: Registry$' 1
check defaults.yaml "the Organization CRD has buildRegistry" '^              buildRegistry:$' 1
cr="$(awk '/^kind: ClusterRole$/{c=1} c' "$out/defaults.yaml")"
if grep -qxF '  - registries' <<<"$cr" && grep -qxF '  - registries/status' <<<"$cr" && grep -qxF '  - registries/finalizers' <<<"$cr"; then ok "the operator may manage Registries, their status and finalizers"
else bad "the operator's ClusterRole lacks registries, registries/status or registries/finalizers (run hack/sync-operator.sh)"; fi
if [[ -n "${INFRARED_OPERATOR_DIR:-}" ]]; then
  for c in registries organizations; do
    if cmp -s "$INFRARED_OPERATOR_DIR/config/crd/bases/infrared.darkshift.io_$c.yaml" "$chart/crds/infrared.darkshift.io_$c.yaml"; then
      ok "the $c CRD matches $INFRARED_OPERATOR_DIR"
    else bad "the $c CRD differs from $INFRARED_OPERATOR_DIR (run hack/sync-operator.sh)"; fi
  done
fi

step "kubeconform"
for f in defaults digests adopted other ecr extensions ghcr install ghcr-adopted stores-adopted backup-key gitea gitea-adopted backups backups-nogitea backups-adopted backups-gcs restore restore-point restore-gcs code-index code-index-install registry-token registry-token-adopted aws aws-irsa aws-adopted cloud-gcp cloud-irsa cloud-ec2 cloud-web registry-creds; do
  if kubeconform -strict -ignore-missing-schemas -summary "$out/$f.yaml"; then ok "kubeconform $f"
  else bad "kubeconform $f"; fi
done

echo
if (( fail )); then echo "verify: FAILED"; exit 1; fi
echo "verify: all checks passed"
