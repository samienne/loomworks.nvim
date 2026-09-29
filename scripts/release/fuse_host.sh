#!/usr/bin/env bash
# Fuse a host binary: stage the bootstrap (main.lua + boot/), embed the given
# public key (the production key for a release — which the committed source
# already carries — or a test key for a test fuse) and, for a release, the
# release version into boot/verify.lua, then fuse it into a copy of luvi.
#
#   fuse_host.sh <luvi_binary> <public_key.pem> <out_path> [<release_version>]
#
# <release_version> (no leading v) becomes the host's M.RELEASE_VERSION
# (spec §16.32): `lw version` reports it, and `lw self-update` compares it to
# the target release to decide whether to replace the host. Omit it for a
# local fuse — the host then reports an unknown release (it fuses only the
# bootstrap, like a release host) and `lw self-update` would replace it.
#
# Run on the target OS/arch with that platform's luvi — `luvi --output` fuses
# the running luvi, so there is no cross-fusing. The result is a single
# self-contained `lw` binary that carries NO loomworks system Lua (that ships
# as the separately-fetched, verified release bundle).
set -euo pipefail

luvi="${1:?usage: fuse_host.sh <luvi> <pubkey.pem> <out>}"
pub="${2:?missing public key}"
outp="${3:?missing out path}"
relver="${4:-}"

# The version is baked into Lua source and later compared/interpolated, so hold
# it to the same safe-version grammar the host enforces (boot.pin.valid_version).
if [ -n "$relver" ]; then
  case "$relver" in
    *..*|[!0-9A-Za-z]*|*[!0-9A-Za-z._+-]*)
      echo "fuse_host.sh: invalid release version '$relver'" >&2; exit 1 ;;
  esac
fi

repo="$(cd "$(dirname "$0")/../.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

cp "$repo/lua/main.lua" "$stage/main.lua"
cp -r "$repo/lua/boot" "$stage/boot"

# The committed boot/verify.lua already embeds the PRODUCTION public key
# (keys/loomworks-release.pub.pem, spec §16.12). Embed the given key — a test
# fuse (`make dist`, scripts/ci/host-self-update-e2e.sh) passes the test key —
# and warn when that is not the production key. Inject the release version when
# one was given.
python3 - "$stage/boot/verify.lua" "$pub" "$relver" "$repo/keys/loomworks-release.pub.pem" <<'PY'
import sys, re
vf, pubf, relver, prodf = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def norm(s): return s.replace("\r", "").strip()
pub = norm(open(pubf).read())
prod = norm(open(prodf).read())
src = open(vf).read()
new, n = re.subn(r'M\.PUBLIC_KEY_PEM = \[\[.*?\]\]',
                 'M.PUBLIC_KEY_PEM = [[\n' + pub + '\n]]', src, flags=re.S)
assert n == 1, "expected exactly one M.PUBLIC_KEY_PEM block, found %d" % n
if pub == prod:
    print("embedded the production public key in boot/verify.lua")
else:
    print("WARNING: fusing with a public key that is NOT the production release "
          "key (keys/loomworks-release.pub.pem): this host cannot verify official "
          "releases", file=sys.stderr)
if relver:
    new, n = re.subn(r'^M\.RELEASE_VERSION = nil$',
                     'M.RELEASE_VERSION = "' + relver + '"', new, flags=re.M)
    assert n == 1, "expected exactly one 'M.RELEASE_VERSION = nil' line, found %d" % n
    print("injected release version " + relver + " into boot/verify.lua")
open(vf, "w").write(new)
PY

# luvi on Windows (git-bash) needs native paths for the bundle + --output.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    "$luvi" "$(cygpath -w "$stage")" --output "$(cygpath -w "$outp")" ;;
  *)
    "$luvi" "$stage" --output "$outp" ;;
esac

echo "fused host -> $outp"
