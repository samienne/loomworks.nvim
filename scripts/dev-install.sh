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

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    out="$stage/lw.exe"
    luvi "$(cygpath -w "$repo/lua")" --output "$(cygpath -w "$out")" ;;
  *)
    luvi "$repo/lua" --output "$out" ;;
esac

# Install the freshly-fused host (skip the release-bundle fetch: it's fused).
"$out" install --no-bundle "$@"

echo
echo "Point --dev at this checkout (once):"
echo "  lw config set dev-lua $repo/lua"
