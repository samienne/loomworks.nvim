-- Host self-update (spec §16.32): replace the running `lw` host binary with the
-- target release's, after `self-update` has handled the bundle.
--
-- Flow: decide (skip for --no-host / pinned / dev / source runs / a running
-- host at or newer than the target release — upgrade-only)
-- -> probe that the install dir is writable -> fetch the release's SIGNED
-- SHA256SUMS + .sig and verify the signature with the key embedded in THIS
-- (already-trusted) host -> require the list to name the target's own bundle
-- (anti-replay: binds the signed list to the target release) -> download this
-- platform's host asset next to the installed binary and verify it against its
-- hash (boot.update
-- ensure_host_binary — mandatory, never relaxed) -> swap it into place.
--
-- The swap never leaves a half-written binary and any failure leaves the
-- original installed and runnable:
--   * Unix: rename the verified staged file over the target (atomic).
--   * Windows: a running .exe cannot be overwritten but CAN be renamed, so the
--     running binary is renamed to `<exe>.old`, the new one renamed into place,
--     and `<exe>.old` is deleted best-effort by the next invocation
--     (cleanup_old, called early in main.lua). A failed second rename rolls the
--     `.old` rename back.
--
-- Kept light at load time (main.lua requires it on every Windows start for the
-- `.old` cleanup): heavier boot modules are required lazily inside functions.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")
local pin = require("boot.pin")

local M = {}

-- Suffix of the renamed-aside running binary on Windows.
M.OLD_SUFFIX = ".old"
-- Suffix of the verified replacement staged next to the installed binary.
M.NEW_SUFFIX = ".new"

--- The running executable's path, forward-slashed.
function M.exe_path()
  local ok, p = pcall(uv.exepath)
  if not ok or type(p) ~= "string" or p == "" then return nil end
  return (p:gsub("\\", "/"))
end

--- Default filesystem seam (tests inject their own to simulate failures).
local function default_fs()
  return {
    rename = function(a, b) return uv.fs_rename(a, b) end,
    unlink = function(p) return uv.fs_unlink(p) end,
    exists = function(p) return uv.fs_stat(p) ~= nil end,
    --- Can new files be created in `dir`? Create + remove a probe file.
    writable = function(dir)
      local probe = dir .. "/.lw-write-probe-" .. tostring(uv.os_getpid and uv.os_getpid() or os.time())
      local f = io.open(probe, "wb")
      if not f then return false end
      f:close()
      uv.fs_unlink(probe)
      return true
    end,
  }
end

--- Best-effort removal of a leftover `<exe>.old` from a previous Windows swap.
--- Silent on every failure (e.g. still in use by another running old process).
--- @param exe? string running executable (default: uv.exepath())
--- @param fs? table filesystem seam
function M.cleanup_old(exe, fs)
  exe = exe or M.exe_path()
  if not exe then return end
  fs = fs or default_fs()
  pcall(fs.unlink, exe .. M.OLD_SUFFIX)
end

--- Should the running host replace itself? Pure — all inputs explicit.
--- @param o { exe?: string, running_version?: string, target_version?: string, no_host?: boolean, pinned?: boolean, dev?: boolean, fused_system_lua?: boolean }
--- @return "swap"|"current"|"skip" action, string reason
function M.decide(o)
  if o.no_host then return "skip", "--no-host" end
  if o.pinned then
    return "skip", "running in pinned context (lw.pin owns this host's version)"
  end
  local exe = (o.exe or ""):gsub("\\", "/"):lower()
  if exe:find("/.nvim/cache/", 1, true) then
    return "skip", "running from a repo-local pinned launcher cache (lw.pin owns this host)"
  end
  local base = (exe:match("([^/]+)$") or ""):gsub("%.exe$", "")
  if base == "luvi" then
    return "skip", "running from the bare luvi runtime (a source run)"
  end
  if o.dev then return "skip", "running a development source" end
  if o.fused_system_lua then
    return "skip", "this is a development build (system Lua fused into the binary)"
  end
  -- Upgrade-only (§16.32): replace only an unknown host (nil — released before
  -- version identity existed) or one strictly older than the target. The
  -- bundle never downgrades either (the newest installed release runs), so a
  -- channel switch that resolves an older release leaves the host alone.
  local running, target = o.running_version, o.target_version
  if running and target then
    if running == target or paths.compare_versions(running, target) == 0 then
      return "current", "host already at " .. running
    end
    if not paths.version_gt(target, running) then
      return "skip", "lw binary " .. running .. " is newer than " .. target ..
        "; not downgrading"
    end
  end
  return "swap", (running or "unknown version") .. " -> " .. tostring(target)
end

--- Move the verified `new` binary over `exe`. Unix: one atomic rename. Windows:
--- rename the (running) exe aside to `<exe>.old`, then `new` into place, rolling
--- the first rename back if the second fails. `new` is left for the caller to
--- remove on failure. Returns true, or nil, err, fatal — `fatal` set only when a
--- Windows rollback also failed (the original then sits at `<exe>.old`).
--- @param opts? { fs?: table, is_windows?: boolean, sleep?: fun(ms:integer), attempts?: integer }
function M.swap(exe, new, opts)
  opts = opts or {}
  local fs = opts.fs or default_fs()
  local is_windows = opts.is_windows
  if is_windows == nil then is_windows = paths.is_windows end
  local update = require("boot.update")
  local function mv(a, b)
    -- Rides out transient AV/indexer locks on the freshly written file.
    return update.rename_with_retry(a, b, {
      rename = fs.rename, sleep = opts.sleep, attempts = opts.attempts or 8,
    })
  end

  if not is_windows then
    local ok, err = mv(new, exe)
    if not ok then return nil, "replace " .. exe .. ": " .. tostring(err) end
    return true
  end

  local old = exe .. M.OLD_SUFFIX
  -- A leftover from an earlier swap that startup cleanup could not remove (it
  -- was still running then). If it is STILL in use, we cannot rename onto it.
  if fs.exists(old) then pcall(fs.unlink, old) end
  if fs.exists(old) then
    return nil, "cannot remove leftover " .. old .. " (is another lw still running?)"
  end
  local ok1, e1 = mv(exe, old)
  if not ok1 then return nil, "rename running host aside: " .. tostring(e1) end
  local ok2, e2 = mv(new, exe)
  if ok2 then return true end
  local okb, eb = mv(old, exe)
  if not okb then
    return nil, "move new host into place: " .. tostring(e2) ..
      "; ROLLBACK FAILED (" .. tostring(eb) .. ") — the previous host is at " ..
      old .. "; rename it back to " .. exe, true
  end
  return nil, "move new host into place: " .. tostring(e2)
end

--- Replace the running host with `o.target_version`'s host binary (§16.32).
---
--- Result `status`:
---   "replaced" — swapped in; `from`/`to` set.
---   "current"  — running host already is the target release.
---   "skipped"  — not a self-replacing host (--no-host / pinned / dev / source),
---                or the running host is newer than the target (no downgrade).
---   "warning"  — not replaced, original intact, bundle update stands (exit 0):
---                unwritable location, host asset/hash list unobtainable.
---   "error"    — integrity failure (hash-list signature / a list that is not
---                the target's / binary hash), or a failed rollback. Caller
---                exits non-zero.
--- `message` explains; `manual` (warning/error) says how to replace it by hand.
---
--- @param o { target_version: string, url?: string, exe?: string, running_version?: string, asset?: string, no_host?: boolean, pinned?: boolean, dev?: boolean, fused_system_lua?: boolean, fs?: table, is_windows?: boolean, sleep?: fun(ms:integer), attempts?: integer }
--- @return { status: string, message: string, from?: string, to?: string, exe?: string, manual?: string }
function M.update_host(o)
  local verify = require("boot.verify")
  local update = require("boot.update")
  local download = require("boot.download")
  local exe = o.exe or M.exe_path()
  exe = exe and exe:gsub("\\", "/") or nil
  local running = o.running_version
  if running == nil then running = verify.RELEASE_VERSION end
  local target = o.target_version

  local action, reason = M.decide({
    exe = exe, running_version = running, target_version = target,
    no_host = o.no_host, pinned = o.pinned, dev = o.dev,
    fused_system_lua = o.fused_system_lua,
  })
  if action == "skip" then return { status = "skipped", message = reason } end
  if action == "current" then return { status = "current", message = reason } end
  if not exe then
    return { status = "warning", message = "cannot determine the running executable's path" }
  end
  if not pin.valid_version(target) then
    return { status = "error", message = "unsafe release version '" .. tostring(target) .. "'" }
  end

  local asset, aerr = o.asset, nil
  if not asset then asset, aerr = pin.detect_asset() end
  if not asset then
    return { status = "warning", message = "no host binary is published for this platform (" ..
      tostring(aerr) .. ")" }
  end
  local base = update.versioned_base(target, { url = o.url })
  local manual = "replace " .. exe .. " with the `" .. asset .. "` asset of release " ..
    target .. " (" .. base .. "/" .. asset .. "), verified against its signed " ..
    "SHA256SUMS as in the README's \"Installing lw\""

  local fs = o.fs or default_fs()
  local dir = exe:match("^(.*)/[^/]*$") or "."
  if not fs.writable(dir) then
    return { status = "warning", manual = manual,
      message = "cannot write to " .. dir .. " (a system or package-managed install?)" }
  end

  -- Signed hash list for exactly the release the bundle came from (same origin:
  -- versioned_base honors the same release-url override as self_update).
  local sums, e1 = download.fetch(base .. "/SHA256SUMS")
  if not sums then
    return { status = "warning", manual = manual, message = "fetch SHA256SUMS: " .. tostring(e1) }
  end
  local sig, e2 = download.fetch(base .. "/SHA256SUMS.sig")
  if not sig then
    return { status = "warning", manual = manual, message = "fetch SHA256SUMS.sig: " .. tostring(e2) }
  end
  local okv, ev = verify.verify_detached(sums, sig)
  if not okv then
    return { status = "error", manual = manual, message = "SHA256SUMS signature: " .. tostring(ev) }
  end
  local list = require("boot.bootstrap").parse_sums(sums)
  -- The signature proves this is SOME release's genuine list, not the target's:
  -- a hostile origin could replay an older release's signed list (and its older
  -- host) for a newer target. Bind the list to the target by requiring the
  -- target's own version-bearing entry — its bundle, `loomworks-lua-<ver>.zip`,
  -- which every release's SHA256SUMS covers. Absent -> integrity error.
  local own = pin.bundle_asset(target)
  if not list[own] then
    return { status = "error", manual = manual,
      message = "SHA256SUMS is not release " .. target .. "'s hash list (no '" ..
        own .. "' entry — a replayed or mismatched list)" }
  end
  local sha = list[asset]
  if not sha then
    return { status = "warning", manual = manual,
      message = "release " .. target .. " publishes no hash for '" .. asset .. "'" }
  end

  -- Stage next to the target (same filesystem, so the swap is a rename).
  -- ensure_host_binary verifies the hash (mandatory) before the staged file
  -- exists under its final staging name, and deletes a mismatching download.
  local new = exe .. M.NEW_SUFFIX
  pcall(fs.unlink, new)
  local okd, ed = update.ensure_host_binary(target, asset, sha, new, { url = o.url })
  if not okd then
    pcall(fs.unlink, new)
    local integrity = tostring(ed):match("^verify ") ~= nil
    return { status = integrity and "error" or "warning", manual = manual,
      message = tostring(ed) }
  end

  local oks, es, fatal = M.swap(exe, new, {
    fs = fs, is_windows = o.is_windows, sleep = o.sleep, attempts = o.attempts,
  })
  if not oks then
    pcall(fs.unlink, new)
    return { status = fatal and "error" or "warning", manual = manual, message = es }
  end
  return { status = "replaced", message = "replaced " .. exe, exe = exe,
    from = running, to = target }
end

return M
