#!/usr/bin/env bash
# =============================================================================
# Vendor the chart's dependencies into charts/infrared/charts/ with
# `helm dependency build`, at the versions in charts/infrared/Chart.lock, and
# check each archive against its sha256 below. A version on a registry can be
# pushed again; its archive cannot change without failing here. The archives
# are not committed (*.tgz is ignored): make deps runs this, and make verify,
# lint, template and package run make deps.
#
#   hack/deps.sh           build what is missing or wrong, then check
#   hack/deps.sh --check   check only: exit 1 unless every archive is right
#
# To bump a dependency: change its version in Chart.yaml, run
# `helm dependency update charts/infrared`, and put the new archive's sha256
# below, from the chart repository's index (gitea: https://dl.gitea.com/charts/index.yaml,
# the same archive as oci://docker.gitea.com/charts/gitea).
# =============================================================================
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
chart="$here/charts/infrared"

# One line per dependency: <archive> <sha256>.
sums='gitea-12.7.0.tgz 5881ef9c59400bee2d5547e77c4cd0efb925143c2f5d93fb4f38446db76b0167'

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

# The archives Chart.lock names, and the ones listed above, must be the same.
locked="$(awk '/^- name: / {n = $3} /^  version: / {print n "-" $2 ".tgz"}' "$chart/Chart.lock" | sort)"
listed="$(awk '{print $1}' <<<"$sums" | sort)"
if [[ "$locked" != "$listed" ]]; then
  echo "deps: Chart.lock names $(tr '\n' ' ' <<<"$locked")but the sums here list $(tr '\n' ' ' <<<"$listed")" >&2
  exit 1
fi

# check: every archive is there with its sha256, and nothing else is.
check() {
  local archive want present
  while read -r archive want; do
    [[ -f "$chart/charts/$archive" && "$(sha256 "$chart/charts/$archive")" == "$want" ]] || return 1
  done <<<"$sums"
  present="$(find "$chart/charts" -maxdepth 1 -type f -name '*.tgz' -exec basename {} \; 2>/dev/null | sort)"
  [[ "$present" == "$listed" ]]
}

if [[ "${1:-}" == --check ]]; then
  check && exit 0
  echo "deps: charts/infrared/charts/ does not hold exactly $(tr '\n' ' ' <<<"$listed")with their sha256; run make deps" >&2
  exit 1
fi

if ! check; then
  helm dependency build "$chart"
fi
while read -r archive want; do
  got="$(sha256 "$chart/charts/$archive" 2>/dev/null || true)"
  if [[ "$got" != "$want" ]]; then
    echo "deps: $archive has sha256 ${got:-none}, want $want" >&2
    exit 1
  fi
done <<<"$sums"
check || { echo "deps: charts/infrared/charts/ holds more than $(tr '\n' ' ' <<<"$listed")" >&2; exit 1; }
echo "deps: $(tr '\n' ' ' <<<"$listed")vendored, each sha256 checked"
