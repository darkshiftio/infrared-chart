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

step "helm lint"
for v in "" ci/digests-values.yaml ci/adopted-values.yaml ci/ecr-values.yaml; do
  if helm lint --strict "$chart" ${v:+-f "$chart/$v"} >"$out/lint.log" 2>&1; then
    ok "lint ${v:-defaults}"
  else
    cat "$out/lint.log"; bad "lint ${v:-defaults}"
  fi
done

step "helm template"
helm template infrared "$chart" -n infrared --include-crds >"$out/defaults.yaml"
helm template infrared "$chart" -n infrared --include-crds -f "$chart/ci/digests-values.yaml" >"$out/digests.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/adopted-values.yaml" >"$out/adopted.yaml"
helm template other "$chart" -n ir-test >"$out/other.yaml"
helm template infrared "$chart" -n infrared -f "$chart/ci/ecr-values.yaml" >"$out/ecr.yaml"
ok "rendered defaults, digests, adopted, other-release, ecr"

step "assertions"
check() { # check <file> <description> <grep -E pattern> [count]
  local n; n="$(grep -cE -- "$3" "$out/$1" || true)"
  if [[ -n "${4:-}" ]]; then
    if [[ "$n" == "$4" ]]; then ok "$2"; else bad "$2 (found $n, want $4)"; fi
  elif (( n > 0 )); then ok "$2"
  else bad "$2"; fi
}
check defaults.yaml "UI Service is named exactly 'infrared', port 80 -> http" '^  name: infrared$'
check defaults.yaml "default images are the pinned preprod builds" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):main@sha256:[0-9a-f]{64}$' 4
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
check ecr.yaml "ECR registry prefixes every image" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-(operator|api|ui|mcp):' 4
check ecr.yaml "ECR pinned operator renders tag@digest" 'image: 977456087177\.dkr\.ecr\.us-east-1\.amazonaws\.com/infrared-operator:v0\.1\.0@sha256:[0-9a-f]{64}$' 1
check ecr.yaml "ECR values need no pull secret" 'imagePullSecrets:' 0
check other.yaml "other release names its UI Service <release>-infrared" '^  name: other-infrared$'
check other.yaml "other release proxies to its own api" 'value: "http://other-infrared-api:8080"'

# The generated operator rules must be present (hack/sync-operator.sh ran).
if awk '/BEGIN GENERATED RULES/{f=1;next} /END GENERATED RULES/{f=0} f' \
     "$chart/templates/operator/clusterrole.yaml" | grep -q '^- apiGroups'; then
  ok "operator ClusterRole carries generated rules"
else bad "operator ClusterRole has no generated rules (run hack/sync-operator.sh)"; fi

step "kubeconform"
for f in defaults digests adopted other ecr; do
  if kubeconform -strict -ignore-missing-schemas -summary "$out/$f.yaml"; then ok "kubeconform $f"
  else bad "kubeconform $f"; fi
done

echo
if (( fail )); then echo "verify: FAILED"; exit 1; fi
echo "verify: all checks passed"
