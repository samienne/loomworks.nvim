-- Repo-local launcher templates (lw.sh / lw.cmd) and the catalogue of every
-- launcher generation a release has written (spec §16.24).
--
-- Pure and dependency-free — no openssl, no vim shim, no I/O — so both the
-- host's pin management (boot.bootstrap, luvi) and the health provider
-- (loomworks.launcher_health, nvim or luvi) can require it. Callers pass the
-- SHA-256 function they have (boot.verify.sha256_hex / vim.fn.sha256).

local M = {}

-- ---------------------------------------------------------------------------
-- Templates (written verbatim into the repo; long-bracket strings so nothing
-- is escape-processed). The single source of truth.
-- ---------------------------------------------------------------------------

M.LW_SH = [==[#!/bin/sh
# loomworks repo-local launcher. Committed alongside lw.pin. Fetches the pinned,
# verified lw host binary into .nvim/cache/ and execs it; the host provisions the
# pinned bundle itself. Regenerate with `lw bootstrap install`. See
# `lw help bootstrap`. LOOMWORKS_LAUNCHER tells lw which launcher ran it, so the
# commands it prints read ./lw.sh.
set -eu

# Dev / test-at-head override: run a named binary, bypassing the pin entirely.
if [ -n "${LOOMWORKS_LW:-}" ]; then
  LOOMWORKS_LAUNCHER=lw.sh exec "$LOOMWORKS_LW" "$@"
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

# Fetch $1 -> $2, quietly (a progress meter is noise in CI logs; errors still
# show). A bare path / file:// (offline mirror) is copied, matching how the host
# reads a local LOOMWORKS_RELEASE_URL; only real URLs use curl/wget. Status 127:
# no downloader at all (retrying cannot help).
fetch_to() {
  case "$1" in
    file://*) cp "$(printf '%s' "$1" | sed 's,^file://,,')" "$2" ;;
    *://*)
      if command -v curl >/dev/null 2>&1; then
        k=""; [ "$insecure" = "1" ] && k="-k"
        curl -fsSL $k -o "$2" "$1"
      elif command -v wget >/dev/null 2>&1; then
        k=""; [ "$insecure" = "1" ] && k="--no-check-certificate"
        wget -q $k -O "$2" "$1"
      else
        echo "lw: need curl or wget to download the pinned binary" >&2; return 127
      fi ;;
    *) cp "$1" "$2" ;;
  esac
}

# Bounded retry for a network fetch: at most 3 attempts, 1 s then 2 s apart,
# each from an empty file. A local copy is not retried. Reports its own failure.
fetch_retry() {
  remote=0
  case "$1" in file://*) ;; *://*) remote=1 ;; esac
  if [ "$remote" = 0 ]; then
    fetch_to "$1" "$2" && return 0
    echo "lw: copy failed: $1" >&2; return 1
  fi
  n=1
  while :; do
    rm -f "$2"
    rc=0; fetch_to "$1" "$2" || rc=$?
    [ "$rc" = 0 ] && return 0
    [ "$rc" = 127 ] && return 1
    if [ "$n" -ge 3 ]; then
      echo "lw: download failed after $n attempts: $1" >&2; return 1
    fi
    echo "lw: download attempt $n failed; retrying..." >&2
    sleep "$n"; n=$((n + 1))
  done
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
  echo "lw: fetching pinned lw $version ($asset) for $pin..." >&2
  tmp="$bin.dl.$$"
  fetch_retry "$url" "$tmp" || { rm -f "$tmp"; exit 1; }
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
LOOMWORKS_LAUNCHER=lw.sh LOOMWORKS_PINNED="$version" LW_ROOT="$PWD" exec "$bin" "$@"
]==]

M.LW_CMD = [==[@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem loomworks repo-local launcher (Windows). Committed alongside lw.pin. Fetches
rem the pinned, verified lw host binary into .nvim\cache\ and runs it; the host
rem provisions the pinned bundle itself. Regenerate with `lw bootstrap install`.
rem Run it as .\lw.cmd: a bare lw.cmd can resolve to another one on PATH.
rem LOOMWORKS_LAUNCHER tells lw which launcher ran it, so the commands it prints
rem read .\lw.cmd.
rem Messages are `1>&2 echo text`: a trailing ` 1>&2` would leave a space at the
rem end of every line.
rem Windows system tools (find, findstr, certutil, curl, where, ping) are called
rem by their absolute %SystemRoot%\System32 path: a bare name can resolve to a
rem same-named tool earlier on PATH (Git's usr/bin/find under Git Bash / CI).
set "LOOMWORKS_LAUNCHER=lw.cmd"

if not "%LOOMWORKS_LW%"=="" (
  "%LOOMWORKS_LW%" %*
  exit /b !ERRORLEVEL!
)

set "here=%~dp0"
set "pin=%here%lw.pin"
if not exist "%pin%" ( 1>&2 echo lw: no lw.pin next to this launcher& exit /b 1 )

set "asset=lw-windows-x86_64.exe"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
  1>&2 echo lw: no pinned lw binary for windows/arm64& exit /b 1
)

set "version="
set "want="
for /f "usebackq tokens=1,* delims== " %%A in ("%pin%") do (
  set "k=%%A"
  set "v=%%B"
  if /I "!k!"=="version" set "version=!v!"
  if /I "!k!"=="sha256_%asset%" set "want=!v!"
)
if "!version!"=="" ( 1>&2 echo lw: lw.pin has no version& exit /b 1 )
if "!want!"=="" ( 1>&2 echo lw: lw.pin has no sha256 for %asset%& exit /b 1 )
rem reject a malicious pinned version before it reaches a URL (a repo must not
rem be able to redirect the fetch): forbid anything outside [-0-9A-Za-z._+] or `..`
echo(!version!| "%SystemRoot%\System32\findstr.exe" /r /c:"[^-0-9A-Za-z._+]" >nul && ( 1>&2 echo lw: invalid pinned version !version!& exit /b 1 )
echo(!version!| "%SystemRoot%\System32\findstr.exe" /c:".." >nul && ( 1>&2 echo lw: invalid pinned version !version!& exit /b 1 )

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
1>&2 echo lw: fetching pinned lw !version! ^(%asset%^) for %pin%...
set "tmp=%bin%.dl"
set "islocal=0"
echo(!url!| "%SystemRoot%\System32\find.exe" "://" >nul
if errorlevel 1 set "islocal=1"
set "kflag="
if "!insecure!"=="1" set "kflag=-k"
rem bounded retry: at most 3 attempts, 1 s then 2 s apart (ping -n N waits N-1 s),
rem each from an empty file; a local copy is not retried. curl runs quietly
rem (-sS: no progress meter, errors still shown).
set "attempt=0"
:fetch
set /a attempt+=1
del /f /q "%tmp%" 2>nul
if "!islocal!"=="1" (
  rem bare path / offline mirror: copy instead of curl (matches the host)
  set "src=!url:/=\!"
  copy /y "!src!" "%tmp%" >nul
) else (
  "%SystemRoot%\System32\curl.exe" -fsSL !kflag! -o "%tmp%" "!url!"
)
if not errorlevel 1 goto fetched
if "!islocal!"=="1" goto fetchfail
if !attempt! GEQ 3 goto fetchfail
1>&2 echo lw: download attempt !attempt! failed; retrying...
set /a wait=attempt+1
"%SystemRoot%\System32\ping.exe" -n !wait! 127.0.0.1 >nul
goto fetch
:fetchfail
if "!islocal!"=="1" (1>&2 echo lw: copy failed: !url!) else (1>&2 echo lw: download failed after !attempt! attempts: !url!)
del /f /q "%tmp%" 2>nul
exit /b 1
:fetched
call :sha "%tmp%"
if /I not "!got!"=="!want!" (
  1>&2 echo lw: sha256 mismatch for %asset% ^(pin !want!, got !got!^) -- aborting
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
  "%SystemRoot%\System32\where.exe" gh >nul 2>nul
  if errorlevel 1 (
    1>&2 echo lw: --verify: gh not found; skipping attestation ^(sha256 already verified^)
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
rem the outer quote pair keeps cmd /c from stripping the program path's quotes
for /f "skip=1 delims=" %%H in ('""%SystemRoot%\System32\certutil.exe" -hashfile "%~1" SHA256"') do if not defined got set "got=%%H"
set "got=!got: =!"
goto :eof
]==]

-- ---------------------------------------------------------------------------
-- Rendering + generation catalogue
-- ---------------------------------------------------------------------------

--- The launcher kinds and the line ending each is written with.
M.KINDS = { sh = "lw.sh", cmd = "lw.cmd" }

--- Content with line endings normalized to LF (the form generations are
--- hashed in, so a checkout's CRLF/LF conversion never changes a verdict).
--- @param s string
--- @return string
function M.normalize(s)
  return (tostring(s):gsub("\r\n", "\n"):gsub("\r", "\n"))
end

--- The exact bytes `kind` ("sh" | "cmd") is written as: lw.sh LF (a CRLF
--- `#!/bin/sh` breaks on Linux), lw.cmd CRLF for cmd.exe.
--- @param kind "sh"|"cmd"
--- @return string
function M.render(kind)
  if kind == "sh" then return M.normalize(M.LW_SH) end
  return (M.normalize(M.LW_CMD):gsub("\n", "\r\n"))
end

-- Every launcher generation an earlier release wrote, keyed by the SHA-256 of
-- its LF-normalized content. `defects` are what a later generation fixed:
-- severity "breaks" (a run can fail — health nags) or "minor" (robustness /
-- cosmetics — health only informs). The running host's own templates are the
-- current generation and are NOT listed here (they are recognized by content).
-- When a template changes, add the OLD content's hash here with what the new
-- one fixes.
M.GENERATIONS = {
  sh = {
    -- v0.1.36-beta.1 .. v0.1.37-beta.1
    ["1fe5b9caafc2872e26eb971b4cea89411a08b8f9a3bc0f09db3ac7292c91b696"] = {
      gen = 2, releases = "0.1.36-beta.1-0.1.37-beta.1",
      defects = {
        { severity = "minor", text = "does not tell lw which launcher ran it; names the deprecated `lw update`" },
      },
    },
    -- v0.1.6 .. v0.1.35 (lw.sh unchanged by v0.1.35)
    ["c457cda8832d502450951c5f9756a05929bf01aa679426e14c9719319217e635"] = {
      gen = 1, releases = "0.1.6-0.1.35",
      defects = {
        { severity = "minor", text = "no download retry; shows a progress meter" },
      },
    },
  },
  cmd = {
    -- v0.1.6 .. v0.1.34
    ["f52183ec829018f3352a60b60411410400cffe76fd4e899fb3aeb9f7b8791b35"] = {
      gen = 1, releases = "0.1.6-0.1.34",
      defects = {
        { severity = "breaks", text = "calls find/findstr/certutil by bare name, " ..
          "so a same-named tool on PATH (Git Bash, CI) breaks it" },
        { severity = "minor", text = "no download retry; shows a progress meter" },
      },
    },
    -- v0.1.36-beta.1
    ["8fa140032b7fd103af7e401c90a1f2d40cae98f12eeab029e776ab81abde08f8"] = {
      gen = 3, releases = "0.1.36-beta.1",
      defects = {
        { severity = "minor", text = "messages end in a trailing space" },
      },
    },
    -- v0.1.36-beta.2 .. v0.1.37-beta.1
    ["bb21d2287961a73e5946474b02ab24dd2378466b1531c568e3a4599370e577e3"] = {
      gen = 4, releases = "0.1.36-beta.2-0.1.37-beta.1",
      defects = {
        { severity = "minor", text = "does not tell lw which launcher ran it (lw then prints ./lw.sh commands);" ..
          " names the deprecated `lw update`" },
      },
    },
    -- v0.1.35
    ["fb3ee139018cc1a514daf77bcd418cda9e92b04c92c77a90f6b0fc63d46e57a6"] = {
      gen = 2, releases = "0.1.35",
      defects = {
        { severity = "minor", text = "no download retry; shows a progress meter" },
      },
    },
  },
}

--- Classify launcher content against the running host's template and the
--- catalogue.
--- @param kind "sh"|"cmd"
--- @param bytes string the file's content
--- @param sha256 fun(s: string): string lowercase hex SHA-256
--- @return { status: "current"|"known"|"unknown", gen?: integer, releases?: string, defects?: table[], breaks?: boolean }
function M.classify(kind, bytes, sha256)
  local norm = M.normalize(bytes)
  if norm == M.normalize(kind == "sh" and M.LW_SH or M.LW_CMD) then
    return { status = "current" }
  end
  local g = (M.GENERATIONS[kind] or {})[sha256(norm):lower()]
  if not g then return { status = "unknown" } end
  local breaks = false
  for _, d in ipairs(g.defects or {}) do
    if d.severity == "breaks" then breaks = true end
  end
  return { status = "known", gen = g.gen, releases = g.releases,
    defects = g.defects or {}, breaks = breaks }
end

-- ---------------------------------------------------------------------------
-- Repository metadata: the rules the launcher files need, and pure parsers of
-- the git queries that check them (shared by pin management and health).
-- ---------------------------------------------------------------------------

--- The launcher cache directory, relative to the pin root.
M.CACHE_DIR = ".nvim/cache"

--- The committed files, in report order.
M.FILES = { "lw.sh", "lw.cmd", "lw.pin" }

--- The line ending each committed file needs (spec §16.21).
M.EOL = { ["lw.sh"] = "lf", ["lw.cmd"] = "crlf", ["lw.pin"] = "lf" }

--- The attribute lines pin management appends, per file.
function M.attr_line(file) return file .. " text eol=" .. M.EOL[file] end

--- Is `line` (one ignore-file line) a rule that ignores the launcher cache —
--- the cache directory itself or its `.nvim` parent? Textual fallback for when
--- git cannot answer (no git / not a repository).
--- @param line string
--- @return boolean
function M.ignore_line_covers(line)
  local l = tostring(line):gsub("%s+$", ""):gsub("^%s+", "")
  l = l:gsub("^/", ""):gsub("/$", "")
  return l == ".nvim" or l == ".nvim/cache" or l == ".nvim/*"
end

--- Does ignore-file text contain a line covering the launcher cache?
function M.ignore_text_covers(text)
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    if M.ignore_line_covers(line) then return true end
  end
  return false
end

--- Parse `git check-ignore -v` output ("<source>:<line>:<pattern>\t<path>").
--- @param out string
--- @return { source: string, pattern: string }|nil
function M.parse_check_ignore(out)
  local line = tostring(out or ""):match("^([^\r\n]+)")
  if not line then return nil end
  local src, pattern = line:match("^(.-):%d+:(.-)\t")
  if not src then return nil end
  return { source = src, pattern = pattern }
end

--- Parse `git check-attr text eol -- <files>` into { [file] = { text, eol } }.
--- @param out string
--- @return table<string, { text?: string, eol?: string }>
function M.parse_check_attr(out)
  local res = {}
  for line in (tostring(out or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local file, attr, val = line:match("^(.-): (%S+): (%S+)$")
    if file then
      res[file] = res[file] or {}
      res[file][attr] = val
    end
  end
  return res
end

--- Whether a file's effective attributes give it the line ending it needs:
--- `text` set (or `auto`, which normalizes a text file) and `eol` as required.
--- @param file string
--- @param attrs { text?: string, eol?: string }|nil
--- @return boolean
function M.attrs_ok(file, attrs)
  if not attrs then return false end
  return (attrs.text == "set" or attrs.text == "auto") and attrs.eol == M.EOL[file]
end

--- Byte offset of the end (after its line ending) of the last line in
--- attributes-file `text` that is a rule for one of the launcher files (its
--- pattern is `lw.sh`, `lw.cmd` or `lw.pin`, optionally `/`-anchored), or nil
--- when there is none. Pure.
--- @param text string
--- @return integer|nil
function M.last_rule_line_end(text)
  local names = {}
  for _, f in ipairs(M.FILES) do names[f] = true end
  local last, pos = nil, 1
  text = tostring(text or "")
  while pos <= #text do
    local nl = text:find("\n", pos, true)
    local line_end = nl or #text
    local line = text:sub(pos, nl and nl - 1 or #text):gsub("\r$", "")
    local pat = line:match("^%s*(%S+)")
    if pat and pat:sub(1, 1) ~= "#" and names[(pat:gsub("^/", ""))] and nl then
      last = line_end
    end
    pos = line_end + 1
  end
  return last
end

--- Does attributes-file text contain the exact rule for `file`? Textual
--- fallback for when git cannot answer.
function M.attr_text_has(text, file)
  local want = M.attr_line(file)
  for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    if (line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) == want then return true end
  end
  return false
end

--- Parse `git ls-files --stage -- <files>` into { [file] = mode }.
function M.parse_ls_stage(out)
  local res = {}
  for line in (tostring(out or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local mode, path = line:match("^(%d+) %x+ %d+\t(.+)$")
    if mode then res[path] = mode end
  end
  return res
end

--- Parse `git ls-files --eol -- <files>` into { [file] = { index, worktree } }
--- (`i/lf`, `w/crlf`, ... without the prefixes).
function M.parse_ls_eol(out)
  local res = {}
  for line in (tostring(out or "") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local i, w, path = line:match("^i/(%S*)%s+w/(%S*)%s+attr/.-\t(.+)$")
    if i then res[path] = { index = i, worktree = w } end
  end
  return res
end

--- If `name` is a cached host binary of the launcher cache
--- (`lw-<version>-<asset>`, asset one of `assets`, version safe), return its
--- version; else nil. Pure name check — the caller still lstat()s the file.
--- @param name string
--- @param assets string[] known host-binary asset names
--- @param valid_version fun(v: string): boolean
--- @return string|nil version
function M.cached_binary_version(name, assets, valid_version)
  if type(name) ~= "string" or name:sub(1, 3) ~= "lw-" then return nil end
  for _, a in ipairs(assets) do
    local suffix = "-" .. a
    if #name > 3 + #suffix and name:sub(-#suffix) == suffix then
      local v = name:sub(4, #name - #suffix)
      if valid_version(v) then return v end
    end
  end
  return nil
end

return M
