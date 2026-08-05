-- `lw bootstrap` / `lw update` — author the repo-local launcher + version pin.
--
-- Fetches a release's SIGNED hash list (SHA256SUMS + .sig), verifies the
-- signature against the embedded release key, and writes lw.pin (version +
-- per-host-binary + bundle hashes), lw.sh, lw.cmd, and an idempotent
-- .gitignore entry for the machine-local cache. Management operations (spec
-- §16.24): they run as the global host and never redirect.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")
local verify = require("boot.verify")
local download = require("boot.download")
local update = require("boot.update")
local pin = require("boot.pin")

local M = {}

-- ---------------------------------------------------------------------------
-- Launcher script templates (written verbatim into the repo). Kept here as the
-- single source of truth; long-bracket strings so nothing is escape-processed.
-- ---------------------------------------------------------------------------

M.LW_SH = [==[#!/bin/sh
# loomworks repo-local launcher. Committed alongside lw.pin. Fetches the pinned,
# verified lw host binary into .nvim/cache/ and execs it; the host provisions the
# pinned bundle itself. Regenerate with `lw update`. See `lw help bootstrap`.
set -eu

# Dev / test-at-head override: run a named binary, bypassing the pin entirely.
if [ -n "${LOOMWORKS_LW:-}" ]; then
  exec "$LOOMWORKS_LW" "$@"
fi

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pin="$here/lw.pin"
[ -f "$pin" ] || { echo "lw: no lw.pin next to this launcher" >&2; exit 1; }

# --- select the host-binary asset for this OS/arch -------------------------
os=$(uname -s 2>/dev/null || echo unknown)
arch=$(uname -m 2>/dev/null || echo unknown)
case "$os" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) os=windows ;;
  *) echo "lw: unsupported OS '$os'" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=arm64 ;;
esac
case "$os-$arch" in
  linux-x86_64) asset=lw-linux-x86_64 ;;
  macos-arm64) asset=lw-macos-arm64 ;;
  windows-x86_64) asset=lw-windows-x86_64.exe ;;
  *) echo "lw: no pinned lw binary for $os/$arch" >&2; exit 1 ;;
esac

# --- read version + the asset's pinned sha256 from lw.pin ------------------
version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' "$pin" | head -n1)
want=$(sed -n "s/^[[:space:]]*sha256_$asset[[:space:]]*=[[:space:]]*//p" "$pin" | head -n1)
[ -n "$version" ] || { echo "lw: lw.pin has no version" >&2; exit 1; }
[ -n "$want" ] || { echo "lw: lw.pin has no sha256 for $asset" >&2; exit 1; }
# Reject a malicious pinned version before it reaches a download URL: a repo
# cannot redirect the fetch (a traversal like /../ would leave the origin).
case "$version" in
  *..*|*[!0-9A-Za-z._+-]*)
    echo "lw: invalid pinned version '$version'" >&2; exit 1 ;;
esac
want=$(printf '%s' "$want" | tr 'A-Z' 'a-z')

cache="$here/.nvim/cache"
bin="$cache/lw-$version-$asset"

# --- peel launcher-only flags (--insecure / --verify); forward the rest ---
insecure=0; do_verify=0
[ "${LOOMWORKS_INSECURE:-}" = "1" ] && insecure=1
new=""
for a in "$@"; do
  case "$a" in
    --insecure) insecure=1; continue ;;
    --verify) do_verify=1; continue ;;
  esac
  new="$new $(printf "%s" "$a" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/")"
done
eval "set -- $new"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else echo "lw: need sha256sum or shasum to verify the download" >&2; exit 1; fi
}

# Fetch $1 -> $2. A bare path / file:// (offline mirror) is copied, matching how
# the host reads a local LOOMWORKS_RELEASE_URL; only real URLs use curl/wget.
fetch_to() {
  case "$1" in
    file://*) cp "$(printf '%s' "$1" | sed 's,^file://,,')" "$2" ;;
    *://*)
      if command -v curl >/dev/null 2>&1; then
        k=""; [ "$insecure" = "1" ] && k="-k"
        curl -fL $k -o "$2" "$1"
      elif command -v wget >/dev/null 2>&1; then
        k=""; [ "$insecure" = "1" ] && k="--no-check-certificate"
        wget $k -O "$2" "$1"
      else
        echo "lw: need curl or wget to download the pinned binary" >&2; return 1
      fi ;;
    *) cp "$1" "$2" ;;
  esac
}

# --- ensure the pinned binary is cached + verified (hash is mandatory) ----
if [ ! -f "$bin" ] || [ "$(sha_of "$bin" | tr 'A-Z' 'a-z')" != "$want" ]; then
  rm -f "$bin"
  mkdir -p "$cache"
  if [ -n "${LOOMWORKS_RELEASE_URL:-}" ]; then
    url="$LOOMWORKS_RELEASE_URL/$asset"
  else
    url="https://github.com/samienne/loomworks.nvim/releases/download/v$version/$asset"
  fi
  echo "lw: fetching pinned lw $version ($asset)..." >&2
  tmp="$bin.dl.$$"
  fetch_to "$url" "$tmp" || { echo "lw: download failed: $url" >&2; rm -f "$tmp"; exit 1; }
  got=$(sha_of "$tmp" | tr 'A-Z' 'a-z')
  if [ "$got" != "$want" ]; then
    echo "lw: sha256 mismatch for $asset (pin $want, got $got) -- aborting" >&2
    rm -f "$tmp"; exit 1
  fi
  mv "$tmp" "$bin"
  [ "$os" = windows ] || chmod +x "$bin"
  printf 'version=%s\nasset=%s\nsha256=%s\n' "$version" "$asset" "$want" > "$cache/lw.marker"
fi

# --- optional stronger provenance check (never required) ------------------
if [ "$do_verify" = "1" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh attestation verify "$bin" --repo samienne/loomworks.nvim \
      || { echo "lw: gh attestation verify failed" >&2; exit 1; }
  else
    echo "lw: --verify: gh not found; skipping attestation (sha256 already verified)" >&2
  fi
fi

# --- exec the pinned host; it provisions the pinned bundle itself ----------
LOOMWORKS_PINNED="$version" LW_ROOT="$PWD" exec "$bin" "$@"
]==]

M.LW_CMD = [==[@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem loomworks repo-local launcher (Windows). Committed alongside lw.pin. Fetches
rem the pinned, verified lw host binary into .nvim\cache\ and runs it; the host
rem provisions the pinned bundle itself. Regenerate with `lw update`.

if not "%LOOMWORKS_LW%"=="" (
  "%LOOMWORKS_LW%" %*
  exit /b !ERRORLEVEL!
)

set "here=%~dp0"
set "pin=%here%lw.pin"
if not exist "%pin%" ( echo lw: no lw.pin next to this launcher 1>&2 & exit /b 1 )

set "asset=lw-windows-x86_64.exe"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  echo lw: no pinned lw binary for windows/arm64 1>&2 & exit /b 1
)

set "version="
set "want="
for /f "usebackq tokens=1,* delims== " %%A in ("%pin%") do (
  set "k=%%A"
  set "v=%%B"
  if /I "!k!"=="version" set "version=!v!"
  if /I "!k!"=="sha256_%asset%" set "want=!v!"
)
if "!version!"=="" ( echo lw: lw.pin has no version 1>&2 & exit /b 1 )
if "!want!"=="" ( echo lw: lw.pin has no sha256 for %asset% 1>&2 & exit /b 1 )
rem reject a malicious pinned version before it reaches a URL (a repo must not
rem be able to redirect the fetch): forbid anything outside [-0-9A-Za-z._+] or `..`
echo(!version!| findstr /r /c:"[^-0-9A-Za-z._+]" >nul && ( echo lw: invalid pinned version !version! 1>&2 & exit /b 1 )
echo(!version!| findstr /c:".." >nul && ( echo lw: invalid pinned version !version! 1>&2 & exit /b 1 )

set "cache=%here%.nvim\cache"
set "bin=%cache%\lw-!version!-%asset%"

rem detect launcher-only flags without shifting (so phase 2 still sees all args)
set "insecure=0"
if "%LOOMWORKS_INSECURE%"=="1" set "insecure=1"
set "do_verify=0"
for %%A in (%*) do (
  if /I "%%~A"=="--insecure" set "insecure=1"
  if /I "%%~A"=="--verify" set "do_verify=1"
)

set "ok=0"
if exist "%bin%" ( call :sha "%bin%" & if /I "!got!"=="!want!" set "ok=1" )
if "!ok!"=="1" goto forward

del /f /q "%bin%" 2>nul
if not exist "%cache%" mkdir "%cache%"
if defined LOOMWORKS_RELEASE_URL (
  set "url=%LOOMWORKS_RELEASE_URL%/%asset%"
) else (
  set "url=https://github.com/samienne/loomworks.nvim/releases/download/v!version!/%asset%"
)
echo lw: fetching pinned lw !version! ^(%asset%^)... 1>&2
set "tmp=%bin%.dl"
echo(!url!| find "://" >nul
if errorlevel 1 (
  rem bare path / offline mirror: copy instead of curl (matches the host)
  set "src=!url:/=\!"
  copy /y "!src!" "%tmp%" >nul
) else (
  set "kflag="
  if "!insecure!"=="1" set "kflag=-k"
  curl -fL !kflag! -o "%tmp%" "!url!"
)
if errorlevel 1 ( echo lw: download failed: !url! 1>&2 & del /f /q "%tmp%" 2>nul & exit /b 1 )
call :sha "%tmp%"
if /I not "!got!"=="!want!" (
  echo lw: sha256 mismatch for %asset% ^(pin !want!, got !got!^) -- aborting 1>&2
  del /f /q "%tmp%" 2>nul & exit /b 1
)
move /y "%tmp%" "%bin%" >nul
> "%cache%\lw.marker" (
  echo version=!version!
  echo asset=%asset%
  echo sha256=!want!
)

:forward
if "!do_verify!"=="1" (
  where gh >nul 2>nul
  if errorlevel 1 (
    echo lw: --verify: gh not found; skipping attestation ^(sha256 already verified^) 1>&2
  ) else (
    gh attestation verify "%bin%" --repo samienne/loomworks.nvim || exit /b 1
  )
)
rem Forward args with delayed expansion OFF so a forwarded arg containing `!`
rem survives; re-peel the launcher-only flags from the untouched arg list.
set "PINVER=!version!"
set "PINBIN=!bin!"
setlocal DisableDelayedExpansion
set "LOOMWORKS_PINNED=%PINVER%"
set "LW_ROOT=%CD%"
set "fwd="
:peel
if "%~1"=="" goto peeled
if /I "%~1"=="--insecure" ( shift & goto peel )
if /I "%~1"=="--verify" ( shift & goto peel )
set "fwd=%fwd% %1"
shift
goto peel
:peeled
"%PINBIN%"%fwd%
exit /b %ERRORLEVEL%

:sha
set "got="
for /f "skip=1 delims=" %%H in ('certutil -hashfile "%~1" SHA256') do if not defined got set "got=%%H"
set "got=!got: =!"
goto :eof
]==]

-- ---------------------------------------------------------------------------
-- Hash-list acquisition
-- ---------------------------------------------------------------------------

--- Parse `sha256sum`-style output ("<hex>  <name>" or "<hex> *<name>") into a
--- { name -> hex } map.
function M.parse_sums(text)
  local map = {}
  for line in (tostring(text) .. "\n"):gmatch("([^\n]-)\n") do
    local hex, name = line:match("^(%x+)%s+%*?(.-)%s*$")
    if hex and name and name ~= "" then map[name] = hex:lower() end
  end
  return map
end

--- Fetch + verify a release's SHA256SUMS for `version`, returning { name -> hex }.
--- Verifies SHA256SUMS.sig against the embedded release key before trusting any
--- hash (spec §16.24). Returns map or nil, err.
function M.fetch_hashes(version, opts)
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end
  local base = update.versioned_base(version, opts)
  local sums, e1 = download.fetch(base .. "/SHA256SUMS")
  if not sums then return nil, "fetch SHA256SUMS: " .. e1 end
  local sig, e2 = download.fetch(base .. "/SHA256SUMS.sig")
  if not sig then return nil, "fetch SHA256SUMS.sig: " .. e2 end
  local ok, verr = verify.verify_detached(sums, sig)
  if not ok then return nil, "SHA256SUMS signature: " .. verr end
  return M.parse_sums(sums)
end

--- Resolve the latest release version by fetching + verifying its manifest.
function M.latest_version(opts)
  local base = update.release_base(opts)
  local mbytes = download.fetch(base .. "/manifest.json")
  if not mbytes then return nil end
  local sig = download.fetch(base .. "/manifest.json.sig")
  if not sig then return nil end
  local m = verify.load_manifest(mbytes, sig)
  return m and m.version or nil
end

--- The assets a pin must cover for `version`: every host binary + the bundle.
function M.required_assets(version)
  local list = {}
  for _, a in pairs(pin.HOST_ASSETS) do list[#list + 1] = a end
  list[#list + 1] = pin.bundle_asset(version)
  table.sort(list)
  return list
end

--- Select the pin's hashes from a full sums map; errors if any required asset is
--- absent (a release that did not publish it).
function M.pin_hashes(version, sums)
  local hashes = {}
  for _, a in ipairs(M.required_assets(version)) do
    if not sums[a] then
      return nil, "release " .. version .. " has no published hash for '" .. a .. "'"
    end
    hashes[a] = sums[a]
  end
  return hashes
end

-- ---------------------------------------------------------------------------
-- File writers
-- ---------------------------------------------------------------------------

--- Atomic write: temp file + rename (rename_with_retry rides out Windows
--- AV/indexer locks), matching the codebase's temp-then-rename convention so a
--- crash mid-write never leaves a half-written lw.pin / launcher / .gitignore.
local function write_file(path, content)
  local tmp = path .. ".tmp"
  local f, e = io.open(tmp, "wb")
  if not f then return nil, "cannot write '" .. tmp .. "': " .. tostring(e) end
  f:write(content); f:close()
  local ok, er = update.rename_with_retry(tmp, path)
  if not ok then
    paths.rm_rf(tmp)
    return nil, "rename '" .. tmp .. "' -> '" .. path .. "': " .. tostring(er)
  end
  return true
end

function M.write_pin(root, version, hashes)
  return write_file(root .. "/lw.pin", pin.serialize(version, hashes))
end

function M.write_launchers(root)
  -- Force line endings regardless of how this file is stored: lw.sh MUST be LF
  -- (a CRLF `#!/bin/sh` breaks on Linux), lw.cmd is CRLF for cmd.exe.
  local sh = (M.LW_SH:gsub("\r\n", "\n"):gsub("\r", "\n"))
  local ok1, e1 = write_file(root .. "/lw.sh", sh)
  if not ok1 then return nil, e1 end
  if not paths.is_windows then pcall(uv.fs_chmod, root .. "/lw.sh", tonumber("755", 8)) end
  local cmd = (M.LW_CMD:gsub("\r\n", "\n"):gsub("\n", "\r\n"))
  local ok2, e2 = write_file(root .. "/lw.cmd", cmd)
  if not ok2 then return nil, e2 end
  return true
end

--- Idempotently ensure `.nvim/cache/` is ignored by `<root>/.gitignore`.
--- Append-only: never rewrites or removes existing content; creates the file if
--- absent. Returns "added" | "present" or nil, err.
function M.ensure_gitignore(root)
  local path = root .. "/.gitignore"
  local entry = ".nvim/cache/"
  local existing = ""
  local f = io.open(path, "r")
  if f then existing = f:read("*a") or ""; f:close() end
  for line in (existing .. "\n"):gmatch("([^\n]-)\n") do
    local l = line:gsub("%s+$", "")
    if l == entry or l == ".nvim/cache" then return "present" end
  end
  -- Append-only: keep existing content verbatim, add our block, atomic-write.
  local addition = (existing ~= "" and existing:sub(-1) ~= "\n") and "\n" or ""
  addition = addition ..
    "\n# loomworks: pinned lw binaries + provisioned bundle (machine-local)\n" ..
    entry .. "\n"
  local ok, e = write_file(path, existing .. addition)
  if not ok then return nil, e end
  return "added"
end

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

--- `lw bootstrap` — install lw.sh/lw.cmd/lw.pin into `root` and gitignore the
--- cache. Pins `opts.version` (else the running host's `self_version`). Returns
--- a report (list of lines) or nil, err.
function M.bootstrap(root, self_version, opts)
  opts = opts or {}
  local version = opts.version or self_version
  if not version or version == "" then
    return nil, "no version to pin -- this host has no release version; " ..
      "pass an explicit `--version <x.y.z>`"
  end
  local sums, e = M.fetch_hashes(version, opts)
  if not sums then return nil, e end
  local hashes, e2 = M.pin_hashes(version, sums)
  if not hashes then return nil, e2 end

  local out = {}
  local okp, ep = M.write_pin(root, version, hashes)
  if not okp then return nil, ep end
  out[#out + 1] = "wrote lw.pin (version " .. version .. ")"
  local okl, el = M.write_launchers(root)
  if not okl then return nil, el end
  out[#out + 1] = "wrote lw.sh and lw.cmd"
  local gi, eg = M.ensure_gitignore(root)
  if not gi then return nil, eg end
  out[#out + 1] = (gi == "added" and "added .nvim/cache/ to .gitignore"
    or ".nvim/cache/ already in .gitignore")
  out[#out + 1] = ""
  out[#out + 1] = "Commit lw.sh, lw.cmd, and lw.pin. Run `./lw.sh <cmd>` (or lw.cmd on"
  out[#out + 1] = "Windows); update the pin with `lw update`."
  return out
end

--- `lw update` — rewrite lw.pin to `opts.version` (or the latest release).
--- Validates the target release is fetchable before writing; refreshes the
--- launcher scripts. Returns a report or nil, err.
function M.update(root, opts)
  opts = opts or {}
  local version = opts.version
  if not version then
    version = M.latest_version(opts)
    if not version then return nil, "could not resolve the latest release version" end
  end
  -- Fetching the (signed) hash list both validates the release is fetchable and
  -- provides the pin's hashes; fail cleanly before touching lw.pin.
  local sums, e = M.fetch_hashes(version, opts)
  if not sums then return nil, "release " .. version .. " is not fetchable: " .. e end
  local hashes, e2 = M.pin_hashes(version, sums)
  if not hashes then return nil, e2 end

  local out = {}
  local okp, ep = M.write_pin(root, version, hashes)
  if not okp then return nil, ep end
  out[#out + 1] = "updated lw.pin -> version " .. version
  local okl = M.write_launchers(root)
  if okl then out[#out + 1] = "refreshed lw.sh / lw.cmd" end
  return out
end

return M
