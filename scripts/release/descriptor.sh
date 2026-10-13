#!/usr/bin/env bash
# Write a release's binary descriptor (spec §16.41) next to its assets.
#
#   descriptor.sh <version> <dir> [<host>]
#
# Runs <host> (default <dir>/lw-linux-x86_64, a released host binary) as
# `lw version --json` with this release's bundle (<dir>/loomworks-lua-<version>.zip,
# unpacked into a sandboxed data dir as lua-<version>/, the layout an installed
# bundle has) and writes <dir>/lw-<version>-descriptor.json. The descriptor is
# what the published release implements, computed by the release itself — the
# same document a user's `lw version --json` prints — so nothing is listed by
# hand. Fails unless the descriptor names <version> as a release (not a
# development build).
set -euo pipefail

version="${1:?usage: descriptor.sh <version> <dir> [<host>]}"
dir="${2:?missing dir}"
host="${3:-$dir/lw-linux-x86_64}"
bundle="$dir/loomworks-lua-${version}.zip"
out="$dir/lw-${version}-descriptor.json"

[ -f "$bundle" ] || { echo "descriptor.sh: no bundle $bundle" >&2; exit 1; }
[ -f "$host" ] || { echo "descriptor.sh: no host binary $host" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/data" "$T/home"
python3 -m zipfile -e "$bundle" "$T/data/lua-$version"
cp "$host" "$T/lw"
chmod +x "$T/lw"

# Sandbox every per-user location; nothing below may download or read the
# runner's own settings. `version` never resolves a workspace, never redirects.
(
  cd "$T"
  unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LOOMWORKS_INSTALL_DIR LW_ROOT
  LOOMWORKS_DATA_DIR="$T/data" LOOMWORKS_NO_HOUSEKEEPING=1 \
    HOME="$T/home" XDG_DATA_HOME="$T/home" XDG_CONFIG_HOME="$T/home" \
    LOCALAPPDATA="$T/home" APPDATA="$T/home" \
    ./lw version --json
) > "$T/descriptor.json"

python3 - "$T/descriptor.json" "$version" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
d = json.load(open(path))
b = d.get("binary") or {}
if b.get("lw_version") != version or b.get("dev") is not False:
    sys.exit("descriptor.sh: the descriptor names %r (dev=%r), not release %s" % (b.get("lw_version"), b.get("dev"), version))
if not d.get("objects") or not d.get("transport"):
    sys.exit("descriptor.sh: the descriptor lists no objects or no transport")
print("descriptor: lw %s, transport %s..%s, %d objects" % (version, d["transport"]["min"], d["transport"]["max"], len(d["objects"])))
PY
cp "$T/descriptor.json" "$out"
echo "wrote $out"
