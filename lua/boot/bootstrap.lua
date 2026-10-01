-- Pin management (spec §16.24): `lw bootstrap` (the read-only status page),
-- `lw bootstrap install` (converge: first install, repair, bump), and the
-- `upgrade` alias, which only presets install's options. (`lw update`, the
-- deprecated alias, is removed; main.lua only points at its replacements.)
--
-- install fetches a release's SIGNED hash list (SHA256SUMS + .sig), verifies
-- the signature against the embedded release key, and writes lw.pin (version +
-- per-host-binary + bundle hashes) and — unless --pin-only — lw.sh / lw.cmd
-- (boot.launcher), then brings the repository metadata up to date
-- (boot.repo_meta: ignore rule, line-ending attributes, lw.sh exec bit) and
-- prunes old cached binaries. Reports only what changed. The status page runs
-- boot.launcher_check (the checks shared with `lw health`) plus a bounded
-- release probe. Management operations: they run as the invoked host, never
-- redirect, and need no system Lua.

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
    return "refreshed " .. name .. ": replaced the launcher written by lw " .. tostring(info and info.releases or "?")
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

--- Write the pin (+ launchers unless pin_only), update the repository
--- metadata, prune the launcher cache. Returns the change lines (empty when
--- nothing changed) and a state table, or nil, err.
local function apply(root, version, hashes, opts)
  local changes, touched = {}, {}
  local function add(line) if line then changes[#changes + 1] = line end end
  local function touch(f)
    for _, x in ipairs(touched) do if x == f then return end end
    touched[#touched + 1] = f
  end
  local cmd = require("boot.launcher_check").cmd

  local have_pin = read(root .. "/lw.pin")
  local old = have_pin and pin.parse(have_pin) or nil
  local want_pin = pin.serialize(version, hashes)
  local pin_changed = have_pin == nil
    or have_pin:gsub("\r\n", "\n") ~= want_pin
  -- Same content with CR LF endings (a checkout without the eol attribute):
  -- the POSIX launcher would read `version = x\r` — rewrite it with LF.
  local pin_eol = not pin_changed and have_pin ~= want_pin
  if pin_changed or pin_eol then
    local okp, ep = M.write_pin(root, version, hashes)
    if not okp then return nil, ep end
    touch("lw.pin")
  end
  if pin_eol then add("rewrote lw.pin with LF line endings") end

  local created_launcher = false
  if opts.pin_only then
    -- --pin-only never writes, refreshes or deletes a launcher (spec §16.24).
    local present = {}
    for _, kind in ipairs({ "sh", "cmd" }) do
      if uv.fs_stat(root .. "/" .. launcher.KINDS[kind]) then present[#present + 1] = launcher.KINDS[kind] end
    end
    if #present > 0 then
      add("kept " .. table.concat(present, ", ") .. (#present == 1 and " as it is" or " as they are") ..
        " (--pin-only); `" .. cmd(opts.invoked, "bootstrap install") .. "` refreshes " ..
        (#present == 1 and "it" or "them"))
    end
  else
    for _, kind in ipairs({ "sh", "cmd" }) do
      local st, info = M.write_launcher(root, kind, opts.force)
      if st == nil then return nil, info end
      if st == "written" then created_launcher = true end
      if st ~= "same" and st ~= "kept" then touch(launcher.KINDS[kind]) end
      add(launcher_line(kind, st, info))
    end
  end

  local top = repo_meta.toplevel(root)
  if not opts.pin_only then
    local gi, eg = repo_meta.ensure_gitignore(root, top, write_file)
    if not gi then return nil, eg end
    if gi == "added" then add("added " .. launcher.CACHE_DIR .. "/ to .gitignore"); touch(".gitignore") end
  end

  local appended, problem, ea = repo_meta.ensure_gitattributes(root, top, write_file,
    opts.pin_only and { "lw.pin" } or nil)
  if not appended then return nil, ea end
  if #appended > 0 then
    add("added line-ending rules for " .. table.concat(appended, ", ") .. " to .gitattributes")
    touch(".gitattributes")
  end
  add(problem)

  if not opts.pin_only then
    local xb, xproblem = repo_meta.ensure_exec_bit(root, top)
    if xb == "staged" then add("staged lw.sh as executable (git mode 100755)"); touch("lw.sh") end
    if xb == "set" then add("set lw.sh executable in the git index (mode 100755)"); touch("lw.sh") end
    add(xproblem)
  end

  local _, _, pruned = repo_meta.prune_cache(root, version, opts.running_exe)
  for _, f in ipairs(pruned or {}) do
    add(string.format("removed old pinned lw %s (%s, %.1f MB) from %s", f.version, f.name,
      f.size / 1048576, launcher.CACHE_DIR))
  end

  return changes, { old = old, had_pin = have_pin ~= nil, pin_changed = pin_changed,
    created_launcher = created_launcher, top = top, touched = touched }
end

--- The hint when a host older than the target wrote the launchers: it can only
--- write its own generation (spec §16.24 "Upgrading through the launcher").
local function older_host_hint(version, opts, st)
  local self = opts.self_version
  if opts.pin_only then return nil end
  if not (self and st and st.pin_changed and paths.version_gt(version, self)) then return nil end
  return "lw.sh / lw.cmd are the launchers of lw " .. self .. " (the lw that ran this);" ..
    " run `" .. M.launcher_cmd(opts.invoked, "bootstrap install") .. "` once more to take " .. version .. "'s"
end

--- A command that must run through a launcher (the pinned release): the
--- invoked launcher's form, else ./lw.sh.
function M.launcher_cmd(invoked, rest)
  local check = require("boot.launcher_check")
  if invoked == "lw.cmd" or invoked == "lw.sh" then return check.cmd(invoked, rest) end
  return check.cmd("lw.sh", rest)
end

--- The one-line usage error of the removed `lw update`, naming what replaced
--- it in the invoked form (spec §16.24): the pin bump it used to do, and the
--- installation update it is easily mistaken for.
function M.removed_update_line(invoked)
  local cmd = require("boot.launcher_check").cmd
  return "lw: unknown command 'update' - to move lw.pin to the newest release run `" ..
    cmd(invoked, "bootstrap upgrade") .. "`; to update lw itself run `lw self-update`"
end

-- One flat clause, no nested parentheses (spec §16.24 "Reporting").
local SIGNED = "hashes from the signed SHA256SUMS, signature verified"

--- The first release that carries release notes and the release-notes command
--- (spec §16.37). A pin moved up to it or later names the command that shows
--- what changed; an older target release could not run it.
M.RELEASE_NOTES_SINCE = "0.1.41-0"

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

--- The directory pin management works on (spec §16.24 "Which directory"): the
--- pin root found upward from `start`, else `start` itself.
--- @return string dir, boolean has_pin
function M.target(start)
  local found = pin.find_pin_root(start)
  if found then return found, true end
  return (tostring(start):gsub("\\", "/"):gsub("/+$", "")), false
end

--- The newest release on the resolved channel (spec §16.29). `opts.resolve_newest`
--- is a test seam; `opts.fetch` bounds the probe (the status page).
--- @return string|nil version, string|nil err, string|nil channel
function M.newest(opts)
  opts = opts or {}
  local channel, cerr = update.resolve_channel({ channel = opts.channel })
  if not channel then return nil, cerr end
  local resolve = opts.resolve_newest or update.resolve_newest_version
  local v, err = resolve({ channel = channel, fetch = opts.fetch })
  if v and not pin.valid_version(v) then return nil, "unsafe release version '" .. tostring(v) .. "'", channel end
  return v, err, channel
end

--- `lw bootstrap install` — converge the repository to a correct pin (+
--- launchers unless `opts.pin_only`) and metadata (spec §16.24).
--- opts: version?, latest?, channel?, pin_only?, force?, host_version? (the
--- running host's release version: the default for a new pin), self_version?
--- (the release whose launcher templates this host writes), running_exe?,
--- resolve_newest? (test seam).
--- @param start string where to look for the pin (the launcher root / cwd)
--- @return string[]|nil report, string|nil err
function M.install(start, opts)
  opts = opts or {}
  local cmd = require("boot.launcher_check").cmd
  local root, has_pin = M.target(start)
  if opts.version and opts.latest then
    return nil, "--version and --latest cannot be combined"
  end
  local current = has_pin and pin.read(root) or nil
  local version, kept_note, newest_note
  if opts.version then
    version = opts.version
  elseif opts.latest then
    local newest, err, channel = M.newest(opts)
    if not newest then
      return nil, "could not resolve the newest release" ..
        (channel and (" on the " .. channel .. " channel") or "") .. ": " .. tostring(err)
    end
    newest_note = "newest " .. channel .. " release: " .. newest
    if current and paths.version_gt(current.version, newest) then
      version = current.version
      kept_note = "lw.pin " .. current.version .. " is newer than the newest " .. channel ..
        " release " .. newest .. " - kept; pass --version <x.y.z> to pin an older release"
    else
      version = newest
    end
  elseif current then
    version = current.version                -- plain install only repairs
  else
    version = opts.host_version
  end
  if not version or version == "" then
    return nil, "no version to pin -- this lw is a development build with no release version;" ..
      " pass `--version <x.y.z>` or `--latest`"
  end
  if not pin.valid_version(version) then
    return nil, "unsafe release version '" .. tostring(version) .. "'"
  end

  -- Fetching the (signed) hash list both validates the release is fetchable and
  -- provides the pin's hashes; fail cleanly before touching anything.
  local sums, e = M.fetch_hashes(version, opts)
  if not sums then return nil, "release " .. version .. " is not fetchable: " .. e end
  local hashes, e2 = M.pin_hashes(version, sums)
  if not hashes then return nil, e2 end

  local changes, st = apply(root, version, hashes, opts)
  if not changes then return nil, st end

  local out = {}
  if newest_note then out[#out + 1] = newest_note end
  if kept_note then out[#out + 1] = kept_note end
  local old_v = st.old and st.old.version
  if not st.pin_changed and #changes == 0 then
    out[#out + 1] = "lw.pin already at " .. version .. " - no changes; " .. SIGNED
    return out
  end
  if not st.pin_changed then
    -- Kept, but something else changed: distinct from the no-op wording.
    out[#out + 1] = "lw.pin kept at " .. version .. "; " .. SIGNED
  elseif old_v and old_v ~= version then
    out[#out + 1] = "lw.pin: " .. old_v .. " -> " .. version .. "; " .. SIGNED
    -- A pointer, not the notes: the new bundle is not acquired here (§16.24).
    if pin.valid_version(old_v) and paths.version_gt(version, old_v)
        and not paths.version_gt(M.RELEASE_NOTES_SINCE, version) then
      out[#out + 1] = "what's new: " .. cmd(opts.invoked, "release-notes --since " .. old_v)
    end
  elseif old_v then
    out[#out + 1] = "lw.pin: " .. version .. " hashes updated; " .. SIGNED
  else
    out[#out + 1] = "wrote lw.pin: version " .. version .. "; " .. SIGNED
  end
  for _, l in ipairs(changes) do out[#out + 1] = l end
  out[#out + 1] = older_host_hint(version, opts, st)
  local function lc(p) return paths.is_windows and p:lower() or p end
  if not st.had_pin and st.top and lc(st.top) ~= lc(root) then
    out[#out + 1] = "note: " .. root .. " is not the repository root " .. st.top ..
      "; lw finds this pin only from inside that directory"
  end
  if not st.had_pin or st.created_launcher then
    out[#out + 1] = ""
    if opts.pin_only then
      out[#out + 1] = "A globally installed lw runs the pinned release for build, run, test, configure"
      out[#out + 1] = "and clean. Add launchers later with `" .. cmd(opts.invoked, "bootstrap install") .. "`."
    else
      out[#out + 1] = "Run it as:  ./lw.sh <cmd>    (Linux, macOS, Git Bash on Windows)"
      out[#out + 1] = "            .\\lw.cmd <cmd>   (cmd, PowerShell)"
    end
    out[#out + 1] = "Check it any time with `" .. cmd(opts.invoked, "bootstrap") .. "`."
  end
  -- The commit hint: the files this run wrote or changed (lw never commits).
  if #st.touched > 0 then
    if st.top then
      out[#out + 1] = "Commit them: " .. require("boot.launcher_check").commit_cmd(st.touched)
    else
      out[#out + 1] = "Commit them: " .. table.concat(st.touched, ", ")
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Status page
-- ---------------------------------------------------------------------------

M.STATUS_SCHEMA = 1

--- The fetch limits of the status page's release probe: health's (§16.31).
M.STATUS_FETCH = { connect_timeout = 5, max_time = 10, attempts = 1 }

local GEN_WORDS = { current = "current", unknown = "not a launcher lw wrote", absent = "missing" }

--- `lw bootstrap` — the read-only status page (spec §16.24).
--- opts: invoked ("launcher"|"global"), host_version?, self_version?,
--- channel?, check?, resolve_newest? / offline? (test seams), git? (test seam).
--- @param start string
--- @return { lines: string[], doc: table, exit: integer }
function M.status(start, opts)
  opts = opts or {}
  local check = require("boot.launcher_check")
  local json = require("boot.json")
  local invoked = opts.invoked or "global"
  local function cmd(rest) return check.cmd(invoked, rest) end
  local root, has_pin = M.target(start)
  local assets = {}
  for _, a in pairs(pin.HOST_ASSETS) do assets[#assets + 1] = a end
  local git = opts.git or function(cwd, args) return repo_meta._git(cwd, args) end
  local r = check.run_checks(root, {
    git = git,
    sha256 = verify.sha256_hex,
    exists = function(p) return uv.fs_stat(p) ~= nil end,
    stale = function(rt, v) return repo_meta.stale_cache(rt, v, assets, pin.valid_version) end,
    invoked = invoked,
  })
  if not has_pin then r.mode = "none" end
  local top = r.git and r.git.top or (has_pin and nil or check.toplevel(root, git))

  -- ---- release probe (the only network operation) ------------------------------
  local compare = r.version or (r.mode == "none" and opts.host_version) or nil
  local upd = {}
  local newest, nerr, channel
  if opts.offline then
    nerr = "offline"
    channel = update.resolve_channel({ channel = opts.channel })
  else
    newest, nerr, channel = M.newest({ channel = opts.channel, fetch = M.STATUS_FETCH,
      resolve_newest = opts.resolve_newest })
  end
  channel = channel or opts.channel or update.DEFAULT_CHANNEL
  upd.channel = channel
  upd.current = compare
  local newer, ahead = false, false
  local newest_unstable
  if newest then
    upd.newest = newest
    newer = compare ~= nil and paths.version_gt(newest, compare)
    ahead = compare ~= nil and paths.version_gt(compare, newest)
    upd.status = newer and "available" or ahead and "ahead" or "current"
    -- A pin ahead of the channel (a prerelease pinned while following stable):
    -- what the newest unstable release is matters too.
    if ahead and channel ~= "unstable" and not opts.offline then
      local u = M.newest({ channel = "unstable", fetch = M.STATUS_FETCH, resolve_newest = opts.resolve_newest })
      if u then newest_unstable = u; upd.newest_unstable = u end
    end
  else
    upd.status = "unknown"
    local why = tostring(nerr or "no version"):match("^[^\n]*"):gsub("%s+$", "")
    upd.detail = why
  end

  -- ---- state -------------------------------------------------------------------
  local lines = { "lw bootstrap - repo-local launcher and version pin", "" }
  local function row(label, text) lines[#lines + 1] = string.format("  %-11s %s", label, text) end
  local dir = root .. (has_pin and "" or " (no lw.pin)")
  local function lc(p) return paths.is_windows and p:lower() or p end
  if top and lc(top) ~= lc(root) and not has_pin then
    dir = dir .. " - not the repository root " .. top
  end
  row("directory", dir)
  if r.mode == "none" then
    row("pin", "none")
  elseif not r.pin then
    row("pin", "lw.pin cannot be read: " .. tostring(r.pin_error))
  else
    local n = 0
    for _ in pairs(pin.HOST_ASSETS) do n = n + 1 end
    local cover = #r.missing_hashes == 0
      and ("hashes for " .. n .. " platforms + bundle")
      or ("no hash for " .. table.concat(r.missing_hashes, ", "))
    row("pin", "lw.pin -> lw " .. r.version .. "; " .. cover)
  end
  local function is_pre(v) return v and v:find("-", 1, true) ~= nil end
  if newest then
    if newer then
      row("release", newest .. " is available on the " .. channel .. " channel")
    elseif ahead then
      local text = (is_pre(compare) and "pinned prerelease " or "pinned ") .. compare ..
        "; newest " .. channel .. ": " .. newest
      if newest_unstable then
        text = text .. (paths.version_gt(newest_unstable, compare)
          and ("; newest unstable: " .. newest_unstable)
          or "; it is the newest unstable")
      end
      row("release", text)
    else
      row("release", compare and (compare .. " is the newest on the " .. channel .. " channel")
        or (newest .. " is the newest on the " .. channel .. " channel"))
    end
  else
    row("release", "not checked - offline or release server unreachable")
  end
  if r.mode == "none" then
    row("launchers", "none")
  elseif r.mode == "pin-only" then
    row("launchers", "none - pin only (a global lw runs the pinned release for build/run/test/configure/clean)")
  else
    local parts = {}
    for _, name in ipairs({ "lw.sh", "lw.cmd" }) do
      local l = r.launchers[name]
      local w = l.generation == "known" and ("written by lw " .. tostring(l.releases))
        or GEN_WORDS[l.generation] or l.generation
      parts[#parts + 1] = name .. " " .. w
    end
    row("launchers", table.concat(parts, ", "))
  end
  if r.git then
    local g = r.git
    local gitparts = { (g.uncommitted and #g.uncommitted > 0)
      and ("not committed yet: " .. table.concat(g.uncommitted, ", "))
      or (r.mode == "pin-only" and "lw.pin committed" or "lw.sh, lw.cmd, lw.pin committed") }
    if r.mode == "launchers" and g.modes and g.modes["lw.sh"] then
      gitparts[#gitparts + 1] = "lw.sh mode " .. g.modes["lw.sh"]
    end
    if g.eol_committed_bad then
      gitparts[#gitparts + 1] = (#g.eol_committed_bad + #g.eol_checkout_bad == 0) and "line endings ok"
        or "line endings wrong"
    end
    row("git", table.concat(gitparts, "; "))
    if g.attrs_bad then
      row("attributes", #g.attrs_bad > 0 and ("no rule for " .. table.concat(g.attrs_bad, ", "))
        or (g.attrs_uncommitted and #g.attrs_uncommitted > 0) and "rules present but not committed"
        or "ok")
    end
    if g.ignore then
      row("ignore", g.ignore == "repo" and ".nvim/cache/ ignored by a committed .gitignore"
        or g.ignore == "uncommitted" and (".nvim/cache/ ignored only by an uncommitted rule in " .. g.ignore_source)
        or g.ignore == "personal" and ".nvim/cache/ ignored only by an uncommitted or personal rule"
        or ".nvim/cache/ not ignored")
    end
  end

  -- ---- findings -------------------------------------------------------------------
  local actionable = 0
  if r.mode ~= "none" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Findings:"
    for _, f in ipairs(r.findings) do
      local bullet = f.kind == "suggestion" and "*" or "-"
      if f.kind == "suggestion" then actionable = actionable + 1 end
      lines[#lines + 1] = "  " .. bullet .. " " .. f.title
      if f.kind == "suggestion" and f.remedy then lines[#lines + 1] = "    fix: " .. f.remedy end
    end
  end

  -- ---- what you can do ------------------------------------------------------------
  local actions = {}
  local seen = {}
  local function act(c, why)
    if seen[c] then return end
    seen[c] = true
    actions[#actions + 1] = { command = c, why = why }
  end
  local hv = opts.host_version
  if r.mode == "none" then
    if hv then
      act(cmd("bootstrap install"), "pin this repo to lw " .. hv .. " and add lw.sh / lw.cmd")
      if newest and paths.version_gt(newest, hv) then
        act(cmd("bootstrap install --latest"), "pin the newest " .. channel .. " release (" .. newest .. ") instead")
      end
    elseif newest then
      act(cmd("bootstrap install --latest"), "pin the newest " .. channel .. " release (" .. newest ..
        ") and add lw.sh / lw.cmd")
    end
    act(cmd("bootstrap install" .. (hv and "" or " --latest") .. " --pin-only"),
      "pin without launcher scripts (contributors and CI then need a global lw)")
    act(cmd("bootstrap install --version <x.y.z>"), hv and "pin a different release" or "pin a specific release")
  else
    if not r.pin then
      act(cmd("bootstrap install --version <x.y.z>"), "rewrite the unreadable lw.pin")
    end
    -- One action per fix: the repair, restore (--force), renormalize, and a
    -- single commit of every file some finding says is not committed.
    local commit_files, commit_seen = {}, {}
    for _, f in ipairs(r.findings) do
      if f.kind == "suggestion" and r.pin then
        if f.commit_files then
          for _, cf in ipairs(f.commit_files) do
            if not commit_seen[cf] then commit_seen[cf] = true; commit_files[#commit_files + 1] = cf end
          end
        elseif f.command == r.repair then
          act(r.repair, "repair: fix the findings above, keeping lw " .. r.version)
        elseif f.command then
          if f.id == "eol-committed" then
            act(r.repair, "repair: add the missing rules, keeping lw " .. r.version)
          end
          act(f.command, f.why or "fix the finding above")
        end
      end
    end
    if #commit_files > 0 then
      act(check.commit_cmd(commit_files), "commit them - contributors and CI only get what is committed")
    end
    local sv = opts.self_version
    local function upgrade(to, extra)
      local up = "bootstrap upgrade" .. (extra or "") .. (r.mode == "pin-only" and " --pin-only" or "")
      local why = "move the pin to " .. to
      if r.mode == "launchers" and sv and paths.version_gt(to, sv) then
        why = why .. ", then run `" .. M.launcher_cmd(invoked, "bootstrap install") ..
          "` once more to take " .. to .. "'s launchers"
      end
      act(cmd(up), why)
    end
    if newer and r.pin then upgrade(newest) end
    if ahead and r.pin and newest_unstable and paths.version_gt(newest_unstable, compare) then
      upgrade(newest_unstable, " --channel unstable")
    end
    if r.mode == "pin-only" then
      act(cmd("bootstrap install"), "add lw.sh / lw.cmd so contributors and CI need no global lw")
    end
    if r.stale and r.pin then
      act(r.repair, "remove the old cached binaries, keeping lw " .. r.version)
    end
    local unstable_newer = ahead and newest_unstable and paths.version_gt(newest_unstable, compare)
    if actionable == 0 and not newer and not unstable_newer then
      act(cmd("bootstrap install --version <x.y.z>"), "pin a different release")
    end
  end
  act(cmd("help bootstrap"), "what the launcher and pin do")

  lines[#lines + 1] = ""
  lines[#lines + 1] = "What you can do:"
  local w = 0
  for _, a in ipairs(actions) do if #a.command > w then w = #a.command end end
  for _, a in ipairs(actions) do
    lines[#lines + 1] = "  " .. a.command .. string.rep(" ", w - #a.command) .. "   " .. a.why
  end
  if invoked == "launcher" then
    lines[#lines + 1] = "  (.\\lw.cmd instead of ./lw.sh from cmd/PowerShell)"
  end
  if r.mode == "none" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Note: `" .. cmd("bootstrap") .. "` only reports now; `" .. cmd("bootstrap install") ..
      "` writes the files."
  end

  -- ---- exit + json ------------------------------------------------------------------
  local exit = 0
  if opts.check and (r.mode == "none" or actionable > 0) then exit = 1 end
  local findings = json.array()
  for _, f in ipairs(r.findings) do
    findings[#findings + 1] = { kind = f.kind, title = f.title, detail = f.detail, remedy = f.remedy }
  end
  local doc = {
    schema = M.STATUS_SCHEMA,
    root = root,
    repo_top = top,
    mode = r.mode,
    invoked = (invoked == "global") and "global" or "launcher",
    launcher = (invoked == "lw.sh" or invoked == "lw.cmd") and invoked or nil,
    launchers = {},
    update = upd,
    findings = r.mode == "none" and json.array() or findings,
    actions = json.array(actions),
    summary = { actionable = actionable },
  }
  if r.mode ~= "none" then
    doc.pin = r.pin and { version = r.version, file = root .. "/lw.pin",
      missing_hashes = json.array(r.missing_hashes) } or { file = root .. "/lw.pin", error = r.pin_error }
  end
  for _, name in ipairs({ "lw.sh", "lw.cmd" }) do
    local l = r.launchers[name] or { present = uv.fs_stat(root .. "/" .. name) ~= nil, generation = "absent" }
    doc.launchers[name] = { present = l.present and true or false, generation = l.generation,
      releases = l.releases }
  end
  return { lines = lines, doc = doc, exit = exit }
end

return M
