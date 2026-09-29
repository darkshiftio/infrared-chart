#!/usr/bin/env bash
# =============================================================================
# Pull the operator's generated artefacts into the chart:
#   ../infrared-operator/config/crd/bases/*.yaml  -> charts/infrared/crds/
#   ../infrared-operator/config/rbac/role.yaml    -> the rules between the
#       markers in charts/infrared/templates/operator/clusterrole.yaml
# The template keeps its own name and labels; only the rules are replaced.
# Run after `make manifests` in infrared-operator, then review the diff.
#
#   hack/sync-operator.sh [path-to-infrared-operator]
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
op="${1:-${INFRARED_OPERATOR_DIR:-$here/../infrared-operator}}"
op="$(cd "$op" && pwd)"
crd_src="$op/config/crd/bases"
role_src="$op/config/rbac/role.yaml"
crd_dst="$here/charts/infrared/crds"
tpl="$here/charts/infrared/templates/operator/clusterrole.yaml"
begin='# BEGIN GENERATED RULES (hack/sync-operator.sh)'
end='# END GENERATED RULES'

[[ -d "$crd_src" ]] || { echo "no CRDs at $crd_src" >&2; exit 1; }
[[ -f "$role_src" ]] || { echo "no role at $role_src" >&2; exit 1; }
if ! grep -qF "$begin" "$tpl" || ! grep -qF "$end" "$tpl"; then
  echo "markers missing in $tpl" >&2; exit 1
fi

# CRDs: mirror exactly (removed CRDs disappear from the chart too).
mkdir -p "$crd_dst"
find "$crd_dst" -maxdepth 1 -name '*.yaml' -delete
shopt -s nullglob
crds=("$crd_src"/*.yaml)
(( ${#crds[@]} )) || { echo "no CRD files in $crd_src" >&2; exit 1; }
cp "${crds[@]}" "$crd_dst/"

# Rules: everything after the top-level `rules:` key of the generated role
# (controller-gen writes the list at column 0, so it drops in unindented).
rules="$(mktemp)"
trap 'rm -f "$rules"' EXIT
awk 'f && /^[^ #-]/ {exit} f {print} /^rules:/ {f=1}' "$role_src" > "$rules"
[[ -s "$rules" ]] || { echo "no rules found in $role_src" >&2; exit 1; }

tmp="$(mktemp)"
awk -v b="$begin" -v e="$end" -v r="$rules" '
  $0 == b { print; while ((getline l < r) > 0) print l; skip=1; next }
  $0 == e { skip=0 }
  !skip { print }
' "$tpl" > "$tmp"
mv "$tmp" "$tpl"

rev="$(git -C "$op" rev-parse --short HEAD 2>/dev/null || echo unknown)"
dirty="$(git -C "$op" status --porcelain -- config 2>/dev/null | head -1)"
echo "synced ${#crds[@]} CRDs and $(grep -c '^- apiGroups' "$rules") rules from $op @ $rev${dirty:+ (uncommitted changes in config/)} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
