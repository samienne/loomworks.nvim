#!/usr/bin/env bash
# Host self-update end-to-end (spec §16.32): fuse a real "old" host (no release
# version) and a "new" host (release 0.0.0-test), publish the new one in a
# local mirror with a SHA256SUMS signed by the TEST key, then let the old host
# `self-update` itself — on Windows this exercises the real running-.exe
# rename-aside dance, which no unit test can.
#
#   bash scripts/ci/host-self-update-e2e.sh <luvi_binary>
#
# Needs python3 (fuse_host.sh), openssl (to sign the hash list), and
# sha256sum or shasum. Hermetic: no network; data/config dirs are sandboxed.
set -u

luvi="${1:?usage: host-self-update-e2e.sh <luvi>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fx="$repo/tests/fixtures/dist"
ver="0.0.0-test"   # the fixture bundle's version

PASS=0; FAIL=0
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  Darwin) os=macos ;;
  *) os=linux ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) arch="$(uname -m)" ;;
esac
case "$os-$arch" in
  linux-x86_64) asset=lw-linux-x86_64 ;;
  macos-arm64) asset=lw-macos-arm64 ;;
  windows-x86_64) asset=lw-windows-x86_64.exe ;;
  *) echo "no host asset for $os/$arch — skipping"; exit 0 ;;
esac
exe_name=lw; [ "$os" = windows ] && exe_name=lw.exe

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$T/install" "$T/mirror" "$T/home" "$T/work"
fuse() { bash "$repo/scripts/release/fuse_host.sh" "$luvi" "$fx/test_ec_pub.pem" "$@" >/dev/null; }
fuse "$T/install/$exe_name" || { echo "fuse (old) failed" >&2; exit 1; }
fuse "$T/mirror/$asset" "$ver" || { echo "fuse (new) failed" >&2; exit 1; }
cp "$T/install/$exe_name" "$T/old-copy"

# The mirror: the fixture bundle + signed manifest, and the signed hash list.
cp "$fx/manifest.json" "$fx/manifest.json.sig" "$fx/loomworks-lua-$ver.zip" "$T/mirror/"
# Like a real release, the list names the release's own version-bearing bundle
# (loomworks-lua-<ver>.zip) — the host refuses a list without it (anti-replay).
# `sign_sums <bundle-version>` forges another release's list (replay test).
sign_sums() {
  local bver="${1:-$ver}"
  ( cd "$T/mirror" && {
      printf '%s  %s\n' "$(sha_of "$asset")" "$asset"
      printf '%s  %s\n' "$(sha_of "loomworks-lua-$ver.zip")" "loomworks-lua-$bver.zip"
    } > SHA256SUMS )
  openssl dgst -sha256 -sign "$fx/test_ec_priv.pem" -out "$T/mirror/SHA256SUMS.sig" "$T/mirror/SHA256SUMS"
}
sign_sums

# Sandbox every per-user dir; point the release source at the mirror.
export LOCALAPPDATA="$T/home" XDG_DATA_HOME="$T/home" APPDATA="$T/home" XDG_CONFIG_HOME="$T/home"
export LOOMWORKS_RELEASE_URL="$T/mirror"
[ "$os" = windows ] && export LOOMWORKS_RELEASE_URL="$(cygpath -m "$T/mirror")"
unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LOOMWORKS_CHANNEL
cd "$T/work"
lw="$T/install/$exe_name"

echo "=== old host reports a dev build ==="
out="$("$lw" version 2>&1)"; echo "$out"
case "$out" in *"host: dev build"*) ok "unversioned host reports a dev build" ;; *) bad "unexpected version: $out" ;; esac

echo "=== self-update --no-host leaves the host alone ==="
out="$("$lw" self-update --no-host 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "--no-host exits 0" || bad "--no-host exit $code"
cmp -s "$lw" "$T/old-copy" && ok "--no-host: host binary unchanged" || bad "--no-host changed the host"

echo "=== self-update replaces the running host ==="
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "self-update exits 0" || bad "self-update exit $code"
case "$out" in *"updated host binary"*) ok "reports the host replacement" ;; *) bad "no replacement reported" ;; esac
cmp -s "$lw" "$T/mirror/$asset" && ok "installed binary is the verified new host" || bad "installed binary differs from the release asset"
if [ "$os" = windows ]; then
  [ -f "$lw.old" ] && ok "windows: running exe was renamed aside to .old" || bad "windows: no .old after swap"
fi

echo "=== new host reports its release; .old is cleaned up ==="
out="$("$lw" version 2>&1)"; echo "$out"
case "$out" in *"host: $ver "*) ok "new host reports $ver" ;; *) bad "unexpected version: $out" ;; esac
[ ! -e "$lw.old" ] && ok "no .old leftover after the next start" || bad ".old still present"

echo "=== second self-update is a no-op for the host ==="
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -eq 0 ] && ok "exits 0" || bad "exit $code"
case "$out" in *"host binary already current"*) ok "host already current" ;; *) bad "host not reported current" ;; esac

echo "=== a replayed hash list (another release's, validly signed) is refused ==="
cp "$T/old-copy" "$lw"
sign_sums 0.0.0-older
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "replayed list exits non-zero" || bad "replayed list accepted (exit 0)"
cmp -s "$lw" "$T/old-copy" && ok "original host untouched" || bad "host changed despite a replayed list"
sign_sums

echo "=== a tampered host asset is refused; the original stays ==="
cp "$T/old-copy" "$lw"
printf 'TAMPER' >> "$T/mirror/$asset"   # hash list (signed) no longer matches
out="$("$lw" self-update 2>&1)"; code=$?; echo "$out"
[ $code -ne 0 ] && ok "integrity failure exits non-zero" || bad "tampered asset accepted (exit 0)"
cmp -s "$lw" "$T/old-copy" && ok "original host untouched" || bad "host changed despite a bad hash"
[ ! -e "$lw.new" ] && ok "no staged leftover" || bad "staged .new left behind"

echo
echo "host self-update e2e: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
