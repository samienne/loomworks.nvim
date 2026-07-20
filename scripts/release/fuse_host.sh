#!/usr/bin/env bash
# Fuse a host binary: stage the bootstrap (main.lua + boot/), inject the
# production public key into boot/verify.lua, then fuse it into a copy of luvi.
#
#   fuse_host.sh <luvi_binary> <public_key.pem> <out_path>
#
# Run on the target OS/arch with that platform's luvi — `luvi --output` fuses
# the running luvi, so there is no cross-fusing. The result is a single
# self-contained `lw` binary that carries NO loomworks system Lua (that ships
# as the separately-fetched, verified release bundle).
set -euo pipefail

luvi="${1:?usage: fuse_host.sh <luvi> <pubkey.pem> <out>}"
pub="${2:?missing public key}"
outp="${3:?missing out path}"

repo="$(cd "$(dirname "$0")/../.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp "$repo/lua/main.lua" "$stage/main.lua"
cp -r "$repo/lua/boot" "$stage/boot"

# Replace the embedded (test) public key with the production one.
python3 - "$stage/boot/verify.lua" "$pub" <<'PY'
import sys, re
vf, pubf = sys.argv[1], sys.argv[2]
pub = open(pubf).read().strip()
src = open(vf).read()
new, n = re.subn(r'M\.PUBLIC_KEY_PEM = \[\[.*?\]\]',
                 'M.PUBLIC_KEY_PEM = [[\n' + pub + '\n]]', src, flags=re.S)
assert n == 1, "expected exactly one M.PUBLIC_KEY_PEM block, found %d" % n
open(vf, "w").write(new)
print("injected public key into boot/verify.lua")
PY

# luvi on Windows (git-bash) needs native paths for the bundle + --output.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    "$luvi" "$(cygpath -w "$stage")" --output "$(cygpath -w "$outp")" ;;
  *)
    "$luvi" "$stage" --output "$outp" ;;
esac

echo "fused host -> $outp"
