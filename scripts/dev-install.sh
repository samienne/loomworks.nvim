#!/usr/bin/env bash
# Build a fused-everything lw host from the working tree and install it for the
# current user (dev dogfood / stable local install). The installed binary is a
# FROZEN snapshot of the tree at build time — it does not change as you edit the
# repo; use `lw --dev` to run the live checkout.
#
#   make install            # or: bash scripts/dev-install.sh [extra lw install args]
#
# Re-run to update the installed snapshot to the current tree.
set -euo pipefail
command -v luvi >/dev/null 2>&1 || { echo "luvi not found on PATH"; exit 1; }

repo="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
out="$stage/lw"

# Fuse a staged copy of lua/ with the release notes beside the loomworks tree,
# where a release bundle carries them (loomworks/CHANGELOG.md), so
# `lw release-notes` works in a dev build too.
src="$stage/src"
cp -R "$repo/lua" "$src"
[ -f "$repo/CHANGELOG.md" ] && cp "$repo/CHANGELOG.md" "$src/loomworks/CHANGELOG.md"
# The protocol's schema documents (spec 19.20), served by Root.schema, as a
# release bundle carries them (loomworks/protocol/; the frozen snapshots stay
# in the source tree).
mkdir -p "$src/loomworks/protocol"
cp "$repo/spec/protocol/transport.json" "$src/loomworks/protocol/"
cp -R "$repo/spec/protocol/meta" "$repo/spec/protocol/interfaces" "$src/loomworks/protocol/"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    out="$stage/lw.exe"
    luvi "$(cygpath -w "$src")" --output "$(cygpath -w "$out")" ;;
  *)
    luvi "$src" --output "$out" ;;
esac

# Install the freshly-fused host (skip the release-bundle fetch: it's fused).
# `-y`: `make install` IS the request to replace the installed lw, so don't ask
# the "replace existing binary?" question `lw install` otherwise asks.
"$out" install -y --no-bundle "$@"

echo
echo "This is a development build: \`lw self-update\` never replaces it (re-run"
echo "\`make install\` instead), and a release bundle already installed in the data"
echo "dir takes precedence over its fused code. It carries the release key, so"
echo "\`lw bootstrap install --version <x.y.z>\` and \`lw bootstrap upgrade\` work against real releases."
echo
echo "Point --dev at this checkout (once):"
echo "  lw settings set dev-lua $repo/lua"
