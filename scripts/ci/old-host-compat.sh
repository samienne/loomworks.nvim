#!/usr/bin/env bash
# Old-host compatibility (spec §16.14): run the bundle built from THIS checkout
# under real, previously released host binaries.
#
# The host binary fuses lua/boot/* + main.lua; the release bundle carries only
# lua/loomworks/**. `lw self-update` installs the newest bundle on any host, and
# hosts before v0.1.29 never replace themselves, so a new bundle must still run
# on old hosts. This script:
#   1. builds the bundle with scripts/release/build_bundle.sh (TEST key, as
#      `make dist` does) at a version higher than any release, and unpacks it
#      into a sandboxed data dir as <data>/lua-<ver>/ — the layout an installed
#      bundle has (every host resolves the newest <data>/lua-*/, with
#      LOOMWORKS_DATA_DIR overriding <data> since v0.1.0);
#   2. downloads each old host from its GitHub release and verifies it against
#      that release's SHA256SUMS, whose signature is checked with the committed
#      release key (keys/loomworks-release.pub.pem);
#   3. runs a few commands with sandboxed data/config dirs and a release-url
#      pointing at an empty local directory (so nothing fetches from the
#      network), asserting the exit code and that no boot module is missing.
#
#   bash scripts/ci/old-host-compat.sh [<host version> ...]
#
# Default hosts: OLD_HOSTS or "0.1.2 0.1.28 0.1.33 0.1.37 0.1.42". Set HOST_CACHE to a
# directory to reuse downloads. Needs curl, openssl, python3, sha256sum/shasum.
set -u

repo="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_SLUG="${REPO_SLUG:-samienne/loomworks.nvim}"
BUNDLE_VER="999.0.0"   # above every real release, so the hosts pick it
if [ $# -gt 0 ]; then hosts="$*"; else hosts="${OLD_HOSTS:-0.1.2 0.1.28 0.1.33 0.1.37 0.1.42}"; fi

PASS=0; FAIL=0
ok()  { printf '  ok  : %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

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
# Release host asset per platform (the same names since v0.1.1; Intel macOS was
# never published).
case "$os-$arch" in
  linux-x86_64) asset=lw-linux-x86_64 ;;
  macos-arm64) asset=lw-macos-arm64 ;;
  windows-x86_64) asset=lw-windows-x86_64.exe ;;
  *) echo "no released host for $os/$arch — skipping"; exit 0 ;;
esac

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# Native path for env vars read by a Windows exe.
native() { if [ "$os" = windows ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cache="${HOST_CACHE:-$T/hosts}"
mkdir -p "$cache" "$T/data" "$T/home" "$T/empty-mirror" "$T/proj/App"

echo "=== build the bundle from this checkout (test key) ==="
bash "$repo/scripts/release/build_bundle.sh" "$BUNDLE_VER" "$T/dist" \
  "$repo/tests/fixtures/dist/test_ec_priv.pem" >/dev/null || { echo "bundle build failed" >&2; exit 1; }
python3 -m zipfile -e "$T/dist/loomworks-lua-$BUNDLE_VER.zip" "$T/data/lua-$BUNDLE_VER" \
  || { echo "bundle unpack failed" >&2; exit 1; }
[ -f "$T/data/lua-$BUNDLE_VER/loomworks/cli.lua" ] && ok "bundle unpacked as lua-$BUNDLE_VER/" \
  || { echo "unexpected bundle layout" >&2; exit 1; }

# A tiny workspace for status/health (no toolchain needed).
printf '{ "projects": { "App": { "typescript": {} } } }\n' > "$T/proj/loomworks.json"

# Sandbox every per-user dir; point the release source at an empty local dir.
export LOOMWORKS_DATA_DIR="$(native "$T/data")"
# No startup housekeeping (spec 16.40) against the runner's real temp dirs;
# `lw cleanup` below is checked explicitly.
export LOOMWORKS_NO_HOUSEKEEPING=1
export LOCALAPPDATA="$(native "$T/home")" APPDATA="$(native "$T/home")"
export XDG_DATA_HOME="$(native "$T/home")" XDG_CONFIG_HOME="$(native "$T/home")"
export LOOMWORKS_RELEASE_URL="$(native "$T/empty-mirror")"
unset LOOMWORKS_LUA LOOMWORKS_PINNED LOOMWORKS_LW LOOMWORKS_CHANNEL LOOMWORKS_LAUNCHER LW_ROOT

# fetch_host <ver> -> path of a verified host binary
fetch_host() {
  local v="$1" d="$cache/v$1" base="https://github.com/$REPO_SLUG/releases/download/v$1"
  mkdir -p "$d"
  for f in "$asset" SHA256SUMS SHA256SUMS.sig; do
    [ -s "$d/$f" ] || curl -fsSL --retry 3 -o "$d/$f" "$base/$f" || { echo "download $f failed" >&2; return 1; }
  done
  openssl dgst -sha256 -verify "$repo/keys/loomworks-release.pub.pem" \
    -signature "$d/SHA256SUMS.sig" "$d/SHA256SUMS" >/dev/null \
    || { echo "v$v: SHA256SUMS signature does not verify" >&2; return 1; }
  local want; want="$(awk -v a="$asset" '$2 == a || $2 == "*"a { print $1 }' "$d/SHA256SUMS" | tr -d '\r')"
  [ -n "$want" ] && [ "$(sha_of "$d/$asset")" = "$want" ] \
    || { echo "v$v: $asset does not match SHA256SUMS" >&2; return 1; }
  chmod +x "$d/$asset" 2>/dev/null || true
  printf '%s' "$d/$asset"
}

# check <lw> <label> <expected exit codes (space-separated)> <args...>
check() {
  local lw="$1" label="$2" codes="$3"; shift 3
  local out err code
  out="$("$lw" "$@" 2>"$T/stderr")"; code=$?
  err="$(cat "$T/stderr")"
  case " $codes " in
    *" $code "*) ok "$label: lw $* exits $code" ;;
    *) bad "$label: lw $* exit $code (want $codes)"; printf '%s\n%s\n' "$out" "$err" | tail -15 >&2 ;;
  esac
  case "$out$err" in
    *"module 'boot."*|*"no release file for 'boot."*|*"no bundle file for 'boot."*)
      bad "$label: lw $*: a boot module is missing"; printf '%s\n' "$err" | tail -15 >&2 ;;
  esac
  case "$out$err" in
    *"stack traceback"*) bad "$label: lw $*: Lua error"; printf '%s\n' "$err" | tail -15 >&2 ;;
  esac
  LAST_OUT="$out"
}

for v in $hosts; do
  echo "=== host v$v ($asset) ==="
  lw="$(fetch_host "$v")" || { bad "v$v: could not obtain a verified host"; continue; }
  ok "v$v: host verified against its signed SHA256SUMS"
  cd "$T/proj" || exit 1
  check "$lw" "v$v" "0" --version
  case "$LAST_OUT" in *"$BUNDLE_VER"*) ok "v$v: runs the sandboxed bundle $BUNDLE_VER" ;;
    *) bad "v$v: not running the sandboxed bundle: $LAST_OUT" ;; esac
  check "$lw" "v$v" "0" help
  check "$lw" "v$v" "0" help self-update
  case "$LAST_OUT" in *self-update*) ok "v$v: help self-update has text" ;;
    *) bad "v$v: help self-update empty: $LAST_OUT" ;; esac
  # Release notes (spec §16.37) are bundle-only: they must work on every host.
  check "$lw" "v$v" "0" release-notes -n 1
  case "$LAST_OUT" in *"loomworks "*) ok "v$v: release-notes prints the bundle's notes" ;;
    *) bad "v$v: release-notes printed no notes: $LAST_OUT" ;; esac
  check "$lw" "v$v" "0" tools
  check "$lw" "v$v" "0" status
  # lw cleanup (spec 16.40) is bundle-side: every host runs it.
  : > "$T/data/.dl-0.0.1.zip"; touch -t 200101010000 "$T/data/.dl-0.0.1.zip"
  check "$lw" "v$v" "0" cleanup --dry-run
  case "$LAST_OUT" in *".dl-0.0.1.zip"*) ok "v$v: cleanup --dry-run lists a leftover" ;;
    *) bad "v$v: cleanup --dry-run: $LAST_OUT" ;; esac
  check "$lw" "v$v" "0" cleanup --yes
  [ ! -e "$T/data/.dl-0.0.1.zip" ] && ok "v$v: cleanup --yes removed it" || bad "v$v: the leftover remains"
  # health exits non-zero when it reports actionable items; either is fine here.
  check "$lw" "v$v" "0 1" health
  # A host from before self-update (< v0.1.29) cannot be replaced by it: health
  # must say so (the update check degrades to this item on an old boot.update).
  if [ "$(printf '%s
' "$v" 0.1.29 | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != 0.1.29 ]; then
    case "$LAST_OUT" in *"predates self-update"*) ok "v$v: health flags the pre-self-update host" ;;
      *) bad "v$v: health lacks the 'predates self-update' item" ;; esac
  fi
  # The workspace daemon (spec §19.10): the host re-executes itself as
  # `daemon run` with LOOMWORKS_LUA forwarded, so even the oldest host runs
  # the same bundle as the daemon; stop then ends that process.
  check "$lw" "v$v" "0" daemon restart
  dpid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$T/proj/.nvim/loomworks.daemon.lock" 2>/dev/null)"
  check "$lw" "v$v" "0" daemon status
  case "$LAST_OUT" in *"answers      1 client"*) ok "v$v: the daemon answers" ;;
    *) bad "v$v: daemon status: $LAST_OUT" ;; esac
  check "$lw" "v$v" "0" daemon stop
  if [ -n "$dpid" ]; then
    gone=no
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if [ "$os" = windows ]; then
        tasklist //FI "PID eq $dpid" 2>/dev/null | grep -q " $dpid " || { gone=yes; break; }
      else
        kill -0 "$dpid" 2>/dev/null || { gone=yes; break; }
      fi
      sleep 0.5
    done
    if [ "$gone" = yes ]; then ok "v$v: daemon pid $dpid exited"; else
      bad "v$v: daemon pid $dpid still running"
      if [ "$os" = windows ]; then taskkill //F //T //PID "$dpid" >/dev/null 2>&1; else kill -9 "$dpid"; fi
    fi
  else
    bad "v$v: no daemon lock after restart"
  fi
  cd "$repo" || exit 1
done

echo
echo "old-host compat: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
