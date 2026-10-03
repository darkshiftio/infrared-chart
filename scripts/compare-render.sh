#!/usr/bin/env bash
# =============================================================================
# compare-render.sh <ref> [--include-crds]
# =============================================================================
# Proves that a change to the chart renders today's objects unchanged. It renders
# the chart at <ref> and in this tree with the same values, in the cases
# scripts/verify.sh renders (this tree's ci/ files for both), and fails unless
# each render is the same byte for byte. The generated Secrets are given fixed
# values, so both renders are deterministic. CRDs are compared only with
# --include-crds, since `make sync-operator` changes them on purpose.
#
#   scripts/compare-render.sh origin/main
#   scripts/compare-render.sh origin/feat/one-install --include-crds
#
# Needs: git, helm. A <ref> with dependencies gets `helm dependency build`.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ref="${1:?usage: scripts/compare-render.sh <ref> [--include-crds]}"
crds=()
[[ "${2:-}" == --include-crds ]] && crds=(--include-crds)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ref"
git archive --format=tar "$ref" charts | tar -x -C "$work/ref"
[[ -f "$work/ref/charts/infrared/Chart.lock" ]] && helm dependency build "$work/ref/charts/infrared" >/dev/null
hack/deps.sh >/dev/null

ci=charts/infrared/ci
printf 'ci-secret\n' >"$work/secret"
fixed=(--set "setup.token=ci-setup,session.key=ci-session,mcp.token=ci-mcp,mcp.access.token=ci-mcp-access")
secrets="--set-file imageCredentials.password=$work/secret --set-file platformTokens.cloudflareApiToken=$work/secret"
cases=(
  "defaults"
  "digests -f $ci/digests-values.yaml"
  "ecr -f $ci/ecr-values.yaml"
  "extensions -f $ci/extensions-values.yaml"
  "ghcr -f $ci/ghcr-values.yaml"
  "install -f $ci/ghcr-values.yaml -f $ci/install-values.yaml $secrets"
  "adopted -f $ci/ghcr-values.yaml -f $ci/adopted-values.yaml -f $ci/stores-adopted-values.yaml"
)
fail=0
for c in "${cases[@]}"; do
  read -r name flags <<<"$c"
  # shellcheck disable=SC2086
  helm template infrared "$work/ref/charts/infrared" -n infrared ${crds[@]+"${crds[@]}"} "${fixed[@]}" $flags >"$work/$name.ref.yaml"
  # shellcheck disable=SC2086
  helm template infrared charts/infrared -n infrared ${crds[@]+"${crds[@]}"} "${fixed[@]}" $flags >"$work/$name.tree.yaml"
  if cmp -s "$work/$name.ref.yaml" "$work/$name.tree.yaml"; then
    echo "same: $name"
  else
    echo "FAIL: $name differs:"
    diff "$work/$name.ref.yaml" "$work/$name.tree.yaml" | head -n 20 || true
    fail=1
  fi
done
if (( fail )); then echo "compare-render: FAILED against $ref ($(git rev-parse --short "$ref"))" >&2; exit 1; fi
echo "compare-render: ${#cases[@]} renders the same byte for byte as $ref ($(git rev-parse --short "$ref"))${crds[*]+, CRDs included}"
