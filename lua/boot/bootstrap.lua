-- `lw bootstrap` / `lw update` — author the repo-local launcher + version pin.
--
-- Fetches a release's SIGNED hash list (SHA256SUMS + .sig), verifies the
-- signature against the embedded release key, and writes lw.pin (version +
-- per-host-binary + bundle hashes) and lw.sh / lw.cmd (boot.launcher), then
-- brings the repository metadata up to date (boot.repo_meta: ignore rule,
-- line-ending attributes, lw.sh exec bit) and prunes old cached binaries.
-- Reports only what changed. Management operations (spec §16.24): they run as
-- the invoked host and never redirect.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")
local verify = require("boot.verify")
local download = require("boot.download")
local update = require("boot.update")
local pin = require("boot.pin")
local launcher = require("boot.launcher")
local repo_meta = require("boot.repo_meta")

local M = {}

-- The launcher templates live in boot.launcher (pure, shared with the health
-- provider); re-exported here for existing callers.
M.LW_SH = launcher.LW_SH
M.LW_CMD = launcher.LW_CMD

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

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

--- Write one launcher unless it is already exactly what this host writes.
--- Refuses to overwrite content that is not a known launcher generation (a
--- hand edit, or a newer host's) unless `force` (spec §16.24).
--- @param root string
--- @param kind "sh"|"cmd"
--- @param force boolean|nil
--- @return "written"|"refreshed"|"eol"|"replaced"|"kept"|"same"|nil status, table|string|nil info
function M.write_launcher(root, kind, force)
  local name = launcher.KINDS[kind]
  local path = root .. "/" .. name
  local want = launcher.render(kind)
  local have = read(path)
  if have == want then return "same" end
  local status = "written"
  local info
  if have ~= nil then
    local c = launcher.classify(kind, have, verify.sha256_hex)
    if c.status == "current" then
      status = "eol"                       -- same content, wrong line endings
    elseif c.status == "known" then
      status, info = "refreshed", c
    elseif force then
      status = "replaced"
    else
      return "kept"
    end
  end
  local ok, e = write_file(path, want)
  if not ok then return nil, e end
  if kind == "sh" and not paths.is_windows then
    pcall(uv.fs_chmod, path, tonumber("755", 8))
  end
  return status, info
end

--- Write both launchers (kept for callers/tests that just want them written).
function M.write_launchers(root, force)
  for _, kind in ipairs({ "sh", "cmd" }) do
    local st, e = M.write_launcher(root, kind, force)
    if st == nil then return nil, e end
  end
  return true
end

--- Idempotently ensure the launcher cache is ignored by the repository (see
--- boot.repo_meta.ensure_gitignore). Returns "added" | "present" | "covered"
--- or nil, err.
function M.ensure_gitignore(root)
  return repo_meta.ensure_gitignore(root, repo_meta.toplevel(root), write_file)
end

--- One line per launcher write outcome worth reporting.
local function launcher_line(kind, status, info)
  local name = launcher.KINDS[kind]
  if status == "written" then return "wrote " .. name end
  if status == "refreshed" then
    return "refreshed " .. name .. " (was the launcher from lw " .. tostring(info and info.releases or "?") .. ")"
  end
  if status == "eol" then
    return "rewrote " .. name .. " with " .. (kind == "sh" and "LF" or "CRLF") .. " line endings"
  end
  if status == "replaced" then return "replaced " .. name .. " (--force)" end
  if status == "kept" then
    return "kept " .. name .. ": it differs from every launcher lw wrote (local edits?);" ..
      " rerun with --force to replace it"
  end
  return nil
end

--- Shared tail of bootstrap/update: write the pin + launchers, update the
--- repository metadata, prune the launcher cache. Returns the change lines
--- (empty when nothing changed) or nil, err.
local function apply(root, version, hashes, opts)
  local changes = {}
  local function add(line) if line then changes[#changes + 1] = line end end

  local old = pin.read(root)
  local want_pin = pin.serialize(version, hashes)
  local have_pin = read(root .. "/lw.pin")
  local pin_changed = have_pin == nil
    or have_pin:gsub("\r\n", "\n") ~= want_pin
  -- Same content with CR LF endings (a checkout without the eol attribute):
  -- the POSIX launcher would read `version = x\r` — rewrite it with LF.
  local pin_eol = not pin_changed and have_pin ~= want_pin
  if pin_changed or pin_eol then
    local okp, ep = M.write_pin(root, version, hashes)
    if not okp then return nil, ep end
  end
  if pin_eol then add("rewrote lw.pin with LF line endings") end

  local wrote_launcher = false
  for _, kind in ipairs({ "sh", "cmd" }) do
    local st, info = M.write_launcher(root, kind, opts.force)
    if st == nil then return nil, info end
    if st ~= "same" and st ~= "kept" then wrote_launcher = true end
    add(launcher_line(kind, st, info))
  end

  local top = repo_meta.toplevel(root)
  local gi, eg = repo_meta.ensure_gitignore(root, top, write_file)
  if not gi then return nil, eg end
  if gi == "added" then add("added " .. launcher.CACHE_DIR .. "/ to .gitignore") end

  local appended, problem, ea = repo_meta.ensure_gitattributes(root, top, write_file)
  if not appended then return nil, ea end
  if #appended > 0 then
    add("added line-ending rules for " .. table.concat(appended, ", ") .. " to .gitattributes")
  end
  add(problem)

  local xb, xproblem = repo_meta.ensure_exec_bit(root, top)
  if xb == "staged" then add("staged lw.sh as executable (git mode 100755)") end
  if xb == "set" then add("set lw.sh executable in the git index (mode 100755)") end
  add(xproblem)

  local removed, bytes = repo_meta.prune_cache(root, version, opts.running_exe)
  if removed > 0 then
    add(string.format("removed %d old pinned lw binar%s from %s (%.1f MB)", removed,
      removed == 1 and "y" or "ies", launcher.CACHE_DIR, bytes / 1048576))
  end

  return changes, { old = old, pin_changed = pin_changed, wrote_launcher = wrote_launcher }
end

--- The hint when a host older than the target wrote the launchers: it can only
--- write its own generation (spec §16.24 "Updating through the launcher").
local function older_host_hint(version, opts, st)
  local self = opts.self_version
  if not (self and st and st.pin_changed and paths.version_gt(version, self)) then return nil end
  return "lw.sh / lw.cmd are the launchers of lw " .. self .. " (the lw that ran this);" ..
    " run `./lw.sh update --version " .. version .. "` once more to take " .. version .. "'s"
end

local SIGNED = "hashes from the release's signed SHA256SUMS (signature verified)"

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

--- `lw bootstrap` — install lw.sh/lw.cmd/lw.pin into `root` and bring the
--- repository metadata up to date. Pins `opts.version` (else the running
--- host's `self_version`). `opts.force` replaces launchers that are not a known
--- generation; `opts.running_exe` is never pruned. Returns a report (list of
--- lines) or nil, err.
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

  local o = opts
  local changes, st = apply(root, version, hashes, o)
  if not changes then return nil, st end

  local out = {}
  if st.pin_changed then
    out[#out + 1] = "wrote lw.pin (version " .. version .. "; " .. SIGNED .. ")"
  else
    out[#out + 1] = "lw.pin already at " .. version .. " (" .. SIGNED .. ")"
  end
  for _, l in ipairs(changes) do out[#out + 1] = l end
  out[#out + 1] = older_host_hint(version, o, st)
  out[#out + 1] = ""
  out[#out + 1] = "Commit lw.sh, lw.cmd and lw.pin (and .gitignore / .gitattributes if changed)."
  out[#out + 1] = "Run it as:  ./lw.sh <cmd>    (Linux, macOS, Git Bash on Windows)"
  out[#out + 1] = "            .\\lw.cmd <cmd>   (cmd, PowerShell)"
  out[#out + 1] = "Move the pin later with `./lw.sh update`."
  return out
end

--- `lw update` — rewrite lw.pin to `opts.version` (or the latest release).
--- Validates the target release is fetchable before writing; refreshes the
--- launchers only when they differ; reports only what changed. `opts.force`,
--- `opts.running_exe`, `opts.self_version` as for bootstrap. Returns a report
--- or nil, err.
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

  local changes, st = apply(root, version, hashes, opts)
  if not changes then return nil, st end

  if not st.pin_changed and #changes == 0 then
    return { "lw.pin already at " .. version .. " - no changes (" .. SIGNED .. ")" }
  end
  local out = {}
  local old_v = st.old and st.old.version
  if not st.pin_changed then
    out[#out + 1] = "lw.pin: " .. version .. " unchanged (" .. SIGNED .. ")"
  elseif old_v and old_v ~= version then
    out[#out + 1] = "lw.pin: " .. old_v .. " -> " .. version .. " (" .. SIGNED .. ")"
  elseif old_v then
    out[#out + 1] = "lw.pin: " .. version .. " hashes updated (" .. SIGNED .. ")"
  else
    out[#out + 1] = "lw.pin: wrote version " .. version .. " (" .. SIGNED .. ")"
  end
  for _, l in ipairs(changes) do out[#out + 1] = l end
  out[#out + 1] = older_host_hint(version, opts, st)
  return out
end

return M
