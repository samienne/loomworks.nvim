#!/usr/bin/env bash
# Pin the plugin to a published lw release (spec 19.16 "Plugin pin").
#
#   pin.sh <version> [--no-interface-check]
#
# lw is released from samienne/loomworks (REPO_SLUG overrides it), not from
# this repository, so the pin is an ordinary plugin commit on top of any
# checkout. Downloads the published release v<version>'s SHA256SUMS,
# SHA256SUMS.sig and lw-<version>-descriptor.json (gh CLI), verifies the
# signature with keys/loomworks-release.pub.pem, checks the descriptor offers
# the interfaces the plugin needs and writes
# lua/loomworks/provision/pinned.lua (scripts/release/pin.lua).
#
#   --no-interface-check  skip the descriptor check (a release published
#                         before descriptors existed).
set -euo pipefail

version="${1:?usage: pin.sh <version> [--no-interface-check]}"
shift
extra=()
for a in "$@"; do
  case "$a" in
    --no-interface-check) extra+=(--no-interface-check) ;;
    *) echo "pin.sh: unknown option $a" >&2; exit 2 ;;
  esac
done

repo="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_SLUG="${REPO_SLUG:-samienne/loomworks}"
tag="v$version"

printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || { echo "pin.sh: version '$version' is not <n>.<n>.<n>[-pre]" >&2; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
desc="lw-$version-descriptor.json"
gh release download "$tag" -R "$REPO_SLUG" -D "$T" -p SHA256SUMS -p SHA256SUMS.sig \
  || { echo "pin.sh: no published release $tag on $REPO_SLUG" >&2; exit 1; }
gh release download "$tag" -R "$REPO_SLUG" -D "$T" -p "$desc" 2>/dev/null \
  || echo "pin.sh: $tag publishes no $desc" >&2

nvim -l "$repo/scripts/release/pin.lua" write "$version" "$T" ${extra[@]+"${extra[@]}"}

echo
echo "Next: git commit -m \"Pin the plugin to loomworks $version\" -- lua/loomworks/provision/pinned.lua"
