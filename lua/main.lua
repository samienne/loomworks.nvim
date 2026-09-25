-- Universal luvi entry point — the host bootstrap.
--
-- The only Lua fused into the host binary. It carries no behavioral logic; it
-- (1) resolves where *system Lua* (the loomworks implementation) comes from,
-- (2) handles the host-level commands `version` and `self-update` (which must
-- work even with no bundle installed), and (3) runs the CLI from the resolved
-- source.
--
-- System-Lua source precedence:
--   LOOMWORKS_LUA env > `--dev[=PATH]` > settings `default-source=dev`
--     > newest verified release bundle (<data>/loomworks/lua-<ver>/)
--     > fused luvi bundle (a full-fused dev exe / `luvi . --` source run).
-- A resolved on-disk root is authoritative — no silent bundle fallback.
--
-- Bootstrap-only modules live under `lua/boot/` (verify, download, update,
-- host_update, json, paths, pin, ...); they load from the fused host regardless
-- of the chosen source, via the boot searcher below. They are NOT part of the
-- release bundle they verify.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local loaders = package.loaders or package.searchers
local bundle = require("luvi").bundle

-- ---- boot searcher: always resolve boot.* from the fused/source bundle ------
-- Inserted right after the preload searcher (position 2), AHEAD of the path
-- searchers: LuaJIT's Windows default package.path includes `!\lua\?.lua`
-- (the executable's own directory), so an appended searcher would let a `lua/`
-- directory beside lw.exe shadow the fused boot modules — including
-- boot.verify, which carries the release public key.
table.insert(loaders, 2, function(modname)
  if modname ~= "boot" and modname:sub(1, 5) ~= "boot." then return nil end
  local base = modname:gsub("%.", "/")
  for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
    local src = bundle.readfile(cand)
    if src then
      local chunk, err = loadstring(src, "bundle:" .. cand)
      return chunk or ("\n\t" .. tostring(err))
    end
  end
  return "\n\tno bundle file for '" .. modname .. "'"
end)

local paths = require("boot.paths")
local pin = require("boot.pin")

-- A Windows host self-update (spec §16.32) — or `lw install` / `make install`
-- over a running lw (boot.install.copy_binary) — renames the running exe aside
-- to `<exe>.old`; the next invocation removes it. Best-effort and silent — the
-- file may still be in use by another lw process that started before the swap.
if paths.is_windows then require("boot.host_update").cleanup_old() end

--- Exit, flushing stdout first (host-level bootstrap path; the CLI has its own).
local function exit(code)
  io.stdout:flush()
  os.exit(code)
end

--- Env read via libuv's view (sees in-process uv.os_setenv; used for tests).
local function getenv(name) return paths.getenv(name) end

--- First non-flag token — the subcommand — ignoring leading global flags.
local function subcommand(args)
  for _, v in ipairs(args) do
    if type(v) == "string" and v:sub(1, 1) ~= "-" then return v end
  end
  return nil
end

-- ---- args: peel off the bootstrap-level `--dev[=PATH]` / `--no-pin` flags ---
local forwarded = {}
local dev_flag, dev_flag_path, no_pin = false, nil, false
for _, v in ipairs({ ... }) do
  if v == "--dev" then
    dev_flag = true
  elseif type(v) == "string" and v:sub(1, 6) == "--dev=" then
    dev_flag, dev_flag_path = true, v:sub(7)
  elseif v == "--no-pin" then
    no_pin = true
  else
    forwarded[#forwarded + 1] = v
  end
end

-- ---- resolve the system-Lua source -----------------------------------------
local cfg = paths.read_config()
local env_lua = paths.norm(os.getenv("LOOMWORKS_LUA"))
local dev_opt_in = env_lua ~= nil or dev_flag or cfg["default-source"] == "dev"

local luaroot, source_kind
if dev_opt_in then
  luaroot = env_lua or paths.norm(dev_flag_path) or paths.norm(cfg["dev-lua"])
  source_kind = "dev"
  if not luaroot then
    io.stderr:write(
      "lw: development source requested but no directory is configured.\n" ..
      "    Set one with `lw settings set dev-lua <path>`, pass `--dev=<path>`,\n" ..
      "    or export LOOMWORKS_LUA=<path>.\n")
    os.exit(1)
  end
  if not uv.fs_stat(luaroot .. "/loomworks") then
    io.stderr:write(
      "lw: development source '" .. luaroot .. "' is not a loomworks `lua/` " ..
      "directory\n    (no `loomworks/` subdir found there).\n")
    os.exit(1)
  end
else
  luaroot = paths.newest_release_root()
  source_kind = luaroot and "release" or nil
end

-- ---- pin: sentinel, override, and workspace root ----------------------------
local pinned_sentinel = getenv("LOOMWORKS_PINNED")
local lw_override = getenv("LOOMWORKS_LW") ~= nil
-- The workspace root the pin (and the repo-local cache) live at — the same
-- upward walk the CLI uses to bind a workspace, seeded from LW_ROOT when a
-- launcher passes the user's cwd.
local pin_root = pin.find_pin_root(paths.norm(getenv("LW_ROOT")) or uv.cwd())

-- ---- pinned context: provision the pinned bundle repo-local -----------------
-- Set by the launcher script or the redirect below. We are the pinned host;
-- load system Lua from the repo-local bundle rather than any machine-global
-- install, and never redirect again (the sentinel is our guard).
if pinned_sentinel and not dev_opt_in then
  local p = pin_root and pin.read(pin_root)
  if p and p.version == pinned_sentinel then
    local dir, err = require("boot.update").ensure_version(p.version, {
      root = pin_root,
      bundle_sha256 = p.hashes[pin.bundle_asset(p.version)],
    })
    if not dir then
      io.stderr:write("lw: could not provision pinned bundle " .. p.version ..
        ": " .. tostring(err) .. "\n")
      exit(1)
    end
    luaroot, source_kind = dir, "release"
  end
end

-- ---- host commands: version / self-update (work without a bundle) -----------
-- Detect the subcommand tolerant of a leading global flag (e.g.
-- `lw --no-input update`), the same way the redirect classifies it — otherwise a
-- flag-prefixed host command would fall through to the nvim-hosted CLI.
local command = subcommand(forwarded)
-- `--version` / `-v` are the conventional spellings; accept them as aliases so
-- they don't fall through to workspace resolution and error about a missing
-- loomworks.json.
if not command then
  for _, v in ipairs(forwarded) do
    if v == "--version" or v == "-v" then command = "version"; break end
  end
end
--- Is system Lua fused into this host? A dev build (`make install` /
--- `luvi lua --`) fuses it; a release host carries only the bootstrap.
local function fused_system_lua() return bundle.readfile("loomworks/cli.lua") ~= nil end

-- `lw <host-command> --help` / `-h` must show help, never perform the operation
-- (a `self-update --help` that replaced the binary was a real bug). Leave such
-- invocations to the CLI's central help dispatcher below.
local help_requested = false
for _, v in ipairs(forwarded) do
  if v == "--help" or v == "-h" then help_requested = true; break end
end

local host_command = (not help_requested) and command or nil

if host_command == "version" then
  local upd = require("boot.update")
  -- Same dev-build predicate self-update uses (§16.32), so the label never
  -- calls a host a dev build that self-update would replace, or vice versa.
  local hu = require("boot.host_update")
  local dev_build = hu.dev_build({ exe = hu.exe_path(), fused_system_lua = fused_system_lua() }) ~= nil
  local info = upd.version_info(luaroot, source_kind, { dev_build = dev_build })
  -- The update channel is a self-update preference; show it so `lw version` is
  -- the one place a user confirms whether they follow stable or unstable.
  local channel = upd.resolve_channel({}) or upd.DEFAULT_CHANNEL
  io.write(upd.version_line(info, channel) .. "\n")
  exit(0)
elseif host_command == "self-update" then
  if source_kind == "dev" then
    io.stderr:write("lw: self-update does not apply to a development source " ..
      "(--dev / default-source=dev).\n")
    exit(1)
  end
  local force, channel, no_host = false, nil, false
  for _, v in ipairs(forwarded) do
    if v == "--force" then force = true
    elseif v == "--no-host" then no_host = true
    elseif v == "--channel" then channel = "" -- flag seen; value is the next token
    elseif type(v) == "string" and v:sub(1, 10) == "--channel=" then channel = v:sub(11)
    elseif channel == "" then channel = v end  -- `--channel <value>` form
  end
  -- Host-step options (spec §16.32): who may self-replace.
  local function host_opts(target)
    return {
      target_version = target,
      no_host = no_host,
      pinned = pinned_sentinel ~= nil,
      dev = source_kind == "dev",
      fused_system_lua = fused_system_lua(),
    }
  end
  io.write("lw: checking for updates…\n")
  local res, err, info = require("boot.update").self_update({ force = force, channel = channel ~= "" and channel or nil })
  if not res and info and info.host_incompatible then
    -- The (verified) release needs a newer host than this one. Replace the
    -- host first — otherwise the first release raising min_host_version would
    -- strand every installed host — then ask for a re-run to fetch the bundle
    -- with the new host. Non-zero exit either way: the bundle is NOT updated.
    local h = require("boot.host_update").update_host(host_opts(info.version))
    if h.status == "replaced" then
      io.write("lw: " .. tostring(err) .. "\n")
      io.write("lw: lw binary updated to " .. info.version ..
        "; re-run `lw self-update` to update the bundle\n")
      exit(1)
    end
    io.stderr:write("lw: self-update failed: " .. tostring(err) .. "\n")
    io.stderr:write("    The lw binary was not updated: " .. tostring(h.message) .. "\n")
    if h.manual then
      io.stderr:write("    To update it manually, " .. h.manual .. ".\n")
    else
      io.stderr:write("    Install the lw binary of release " .. tostring(info.version) ..
        " or later as in the README's \"Installing lw\"" ..
        (no_host and " (or re-run without --no-host)" or "") .. ", then re-run " ..
        "`lw self-update`.\n")
    end
    exit(1)
  end
  if not res then
    io.stderr:write("lw: self-update failed: " .. tostring(err) .. "\n")
    -- A 404 here usually means this build points at a release feed that has no
    -- releases yet, so say where it looked and how to redirect it rather than
    -- leaving a bare curl error.
    if tostring(err):find("404", 1, true) then
      io.stderr:write("    Releases are fetched from: " ..
        require("boot.update").DEFAULT_RELEASE_URL .. "\n" ..
        "    Point it elsewhere with `lw settings set release-url <url>` or\n" ..
        "    LOOMWORKS_RELEASE_URL (a local directory works as an offline mirror).\n")
    end
    exit(1)
  end
  if res.channel_overridden then
    io.stderr:write("lw: --channel " .. res.channel_overridden ..
      " is ignored — a release-url override is in effect (LOOMWORKS_RELEASE_URL / " ..
      "the `release-url` setting). The channel governs only the default origin; " ..
      "unset the override to use channels.\n")
  end
  io.write(res.updated
    and ("lw: installed loomworks " .. res.version .. "\n")
    or ("lw: already up to date (" .. res.version .. ")\n"))
  -- Then the host binary itself (spec §16.32): host-side fixes never ship in the
  -- bundle, so a bundle-only update would leave them stranded. Same release as
  -- the bundle just resolved; verified against the signed SHA256SUMS before any
  -- swap. Refuses for pinned / dev / source-run hosts (a note, not a failure).
  local h = require("boot.host_update").update_host(host_opts(res.version))
  if h.status == "replaced" then
    io.write("lw: updated host binary " .. (h.from or "(unknown version)") .. " -> " ..
      h.to .. " (" .. h.exe .. ")\n")
  elseif h.status == "current" then
    io.write("lw: host binary already current (" .. res.version .. ")\n")
  elseif h.status == "skipped" then
    if not no_host then io.write("lw: host binary not replaced: " .. h.message .. "\n") end
  else
    local label = h.status == "error" and "error" or "warning"
    io.stderr:write("lw: " .. label .. ": host binary not updated: " .. h.message .. "\n")
    if h.manual then io.stderr:write("    To update it manually, " .. h.manual .. ".\n") end
    io.stderr:write("    The bundle update above still stands.\n")
    if h.status == "error" then exit(1) end
  end
  exit(0)
elseif host_command == "install" then
  local opts = { dry_run = false, no_modify_path = false, no_bundle = false }
  for _, v in ipairs(forwarded) do
    if v == "-y" or v == "--yes" then opts.assume_yes = true
    elseif v == "--no-modify-path" then opts.no_modify_path = true
    elseif v == "--no-bundle" then opts.no_bundle = true
    elseif v == "--dry-run" then opts.dry_run = true end
  end
  -- install may report progress AND fail: the binary can be placed while the
  -- bundle fetch dies. Print whatever it got done, then honour the error —
  -- exiting 0 on a partial install is what leaves a job to fail later with a
  -- confusing "no loomworks release is installed".
  local report, err = require("boot.install").install(opts)
  if report then
    for _, line in ipairs(report) do io.write(line .. "\n") end
  end
  if err then
    io.stderr:write("lw: install failed: " .. tostring(err) .. "\n")
    exit(1)
  end
  exit(0)
elseif host_command == "bootstrap" or host_command == "update" then
  -- Pin management (spec §16.24): runs as the global host, never redirected.
  local bootstrap = require("boot.bootstrap")
  local ver_opt
  for i, v in ipairs(forwarded) do if v == "--version" then ver_opt = forwarded[i + 1] end end
  local self_version = (source_kind == "release" and luaroot)
    and luaroot:match("lua%-(.+)$") or nil
  local root = paths.norm(getenv("LW_ROOT")) or (uv.cwd():gsub("\\", "/"):gsub("/+$", ""))
  local report, err
  if command == "update" then
    -- Update rewrites an existing pin; it must already be bootstrapped.
    local existing = pin.find_pin_root(root)
    if not existing then
      io.stderr:write("lw: no lw.pin found (run `lw bootstrap` first)\n")
      exit(1)
    end
    report, err = bootstrap.update(existing, { version = ver_opt })
  else
    report, err = bootstrap.bootstrap(root, self_version, { version = ver_opt })
  end
  if report then for _, line in ipairs(report) do io.write(line .. "\n") end end
  if err then
    io.stderr:write("lw: " .. command .. " failed: " .. tostring(err) .. "\n")
    exit(1)
  end
  exit(0)
end

-- ---- pin: redirect a workspace operation to the pinned release --------------
-- A global host in a pinned repo runs the pinned release. Fast path: the pin
-- matches self, run in-process (no download). Otherwise fetch+verify the pinned
-- host binary, set the sentinel, and re-exec it — that host then provisions the
-- pinned bundle (above) and never redirects again.
do
  local self_version = (source_kind == "release" and luaroot)
    and luaroot:match("lua%-(.+)$") or nil
  local p = pin_root and pin.read(pin_root)
  local action = pin.decide({
    command = command,
    pin = p,
    self_version = self_version,
    pinned_sentinel = pinned_sentinel,
    no_pin = no_pin,
    lw_override = lw_override,
    dev = dev_opt_in,
  })
  if action == "redirect" then
    local asset, aerr = pin.detect_asset()
    if not asset then
      io.stderr:write("lw: cannot honor lw.pin: " .. tostring(aerr) .. "\n")
      exit(1)
    end
    local bin = pin.binary_path(pin_root, p.version, asset)
    io.write("lw: this repo pins lw " .. p.version .. "; fetching and running it…\n")
    io.stdout:flush()
    local ok, err = require("boot.update").ensure_host_binary(
      p.version, asset, p.hashes[asset], bin)
    if not ok then
      io.stderr:write("lw: could not fetch pinned lw " .. p.version .. ": " ..
        tostring(err) .. "\n")
      exit(1)
    end
    -- Carry the sentinel + workspace root across the exec; the child inherits
    -- our environment (uv.os_setenv is visible to spawned children).
    uv.os_setenv("LOOMWORKS_PINNED", p.version)
    uv.os_setenv("LW_ROOT", getenv("LW_ROOT") or uv.cwd())
    local code
    local handle = uv.spawn(bin, { args = forwarded, stdio = { 0, 1, 2 } },
      function(c) code = c end)
    if not handle then
      io.stderr:write("lw: cannot exec pinned lw at " .. bin .. "\n")
      exit(1)
    end
    uv.run()
    handle:close()
    exit(code or 0)
  end
end

-- ---- install the loomworks searcher + run -----------------------------------
if luaroot then
  -- On-disk root (dev or release) is authoritative; no bundle fallback, so a
  -- partial tree fails loudly instead of silently mixing in bundled code.
  _G.__loomworks_luaroot = luaroot
  table.insert(loaders, 1, function(modname)
    local base = luaroot .. "/" .. modname:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
      local fh = io.open(cand, "r")
      if fh then
        local s = fh:read("*a"); fh:close()
        local chunk, err = loadstring(s, "@" .. cand)
        return chunk or ("\n\t" .. tostring(err))
      end
    end
    return "\n\tno " .. source_kind .. " file for '" .. modname .. "'"
  end)
else
  -- No on-disk root. Fall back to a full-fused bundle (dev exe / source run);
  -- if there is no fused loomworks either, this is a bootstrap-only host with
  -- nothing installed yet — guide the user to fetch a release.
  if not bundle.readfile("loomworks/cli.lua") then
    io.stderr:write(
      "lw: no loomworks release is installed.\n" ..
      "    Run `lw self-update` to download and verify the current release.\n")
    exit(1)
  end
  table.insert(loaders, function(modname)
    local base = modname:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
      local src = bundle.readfile(cand)
      if src then
        local chunk, err = loadstring(src, "bundle:" .. cand)
        return chunk or ("\n\t" .. tostring(err))
      end
    end
    return "\n\tno bundle file for '" .. modname .. "'"
  end)
end

-- ---- acquired modules: resolve alongside system Lua ------------------------
-- Modules installed by `lw module install` live under <data>/loomworks/modules/
-- <name>/lua, separate from the release source so a self-update never disturbs
-- them. Expose their roots to both resolvers — the require searcher below and
-- the vim shim's `nvim_get_runtime_file` glob (module/SDK discovery) — via a
-- global, so the two stay in lockstep. Appended (not inserted at 1) so core
-- always wins a name; module packages only ever add new namespaces
-- (loomworks.modules.<id>, loomworks.sdks.<id>, loomworks.progress.<id>).
_G.__loomworks_module_roots = paths.module_lua_roots()
if #_G.__loomworks_module_roots > 0 then
  table.insert(loaders, function(modname)
    local rel = modname:gsub("%.", "/")
    for _, root in ipairs(_G.__loomworks_module_roots) do
      for _, cand in ipairs({ root .. "/" .. rel .. ".lua", root .. "/" .. rel .. "/init.lua" }) do
        local fh = io.open(cand, "r")
        if fh then
          local s = fh:read("*a"); fh:close()
          local chunk, err = loadstring(s, "@" .. cand)
          return chunk or ("\n\t" .. tostring(err))
        end
      end
    end
    return "\n\tno acquired-module file for '" .. modname .. "'"
  end)
end

if not _G.vim then
  _G.vim = require("loomworks.shim")
end

_G.arg = forwarded
require("loomworks.cli")
