-- Universal luvi entry point — the host **bootstrap** (spec §16.11–16.14).
--
-- The only Lua fused into the host binary. It carries no behavioral logic; it
-- (1) resolves where *system Lua* (the loomworks implementation) comes from,
-- (2) handles the host-level commands `version` and `self-update` (which must
-- work even with no bundle installed), and (3) runs the CLI from the resolved
-- source.
--
-- System-Lua source precedence (spec §16.11):
--   LOOMWORKS_LUA env > `--dev[=PATH]` > config `default-source=dev`
--     > newest verified release bundle (<data>/loomworks/lua-<ver>/)
--     > fused luvi bundle (a full-fused dev exe / `luvi . --` source run).
-- A resolved on-disk root is authoritative — no silent bundle fallback.
--
-- Bootstrap-only modules live under `lua/boot/` (verify, download, update,
-- json, paths); they load from the fused host regardless of the chosen source,
-- via the boot searcher below. They are NOT part of the release bundle they
-- verify (spec §16.12).

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local loaders = package.loaders or package.searchers
local bundle = require("luvi").bundle

-- ---- boot searcher: always resolve boot.* from the fused/source bundle ------
table.insert(loaders, function(modname)
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

-- ---- args: peel off the bootstrap-level `--dev[=PATH]` flag -----------------
local forwarded = {}
local dev_flag, dev_flag_path = false, nil
for _, v in ipairs({ ... }) do
  if v == "--dev" then
    dev_flag = true
  elseif type(v) == "string" and v:sub(1, 6) == "--dev=" then
    dev_flag, dev_flag_path = true, v:sub(7)
  else
    forwarded[#forwarded + 1] = v
  end
end

-- ---- resolve the system-Lua source (spec §16.11) ----------------------------
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
      "    Set one with `lw config set dev-lua <path>`, pass `--dev=<path>`,\n" ..
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

-- ---- host commands: version / self-update (work without a bundle) -----------
local function exit(code)
  io.stdout:flush()
  os.exit(code)
end

local command = forwarded[1]
-- `--version` / `-v` are the conventional spellings; accept them as aliases so
-- they don't fall through to workspace resolution and error about a missing
-- loomworks.json.
if command == "--version" or command == "-v" then command = "version" end
if command == "version" then
  local info = require("boot.update").version_info(luaroot, source_kind)
  io.write(string.format("lw — host v%d · source: %s · bundle: %s\n",
    info.host_version, info.source, info.bundle))
  exit(0)
elseif command == "self-update" then
  if source_kind == "dev" then
    io.stderr:write("lw: self-update does not apply to a development source " ..
      "(--dev / default-source=dev).\n")
    exit(1)
  end
  local force = false
  for _, v in ipairs(forwarded) do if v == "--force" then force = true end end
  io.write("lw: checking for updates…\n")
  local res, err = require("boot.update").self_update({ force = force })
  if not res then
    io.stderr:write("lw: self-update failed: " .. tostring(err) .. "\n")
    -- A 404 here usually means this build points at a release feed that has no
    -- releases yet, so say where it looked and how to redirect it rather than
    -- leaving a bare curl error.
    if tostring(err):find("404", 1, true) then
      io.stderr:write("    Releases are fetched from: " ..
        require("boot.update").DEFAULT_RELEASE_URL .. "\n" ..
        "    Point it elsewhere with `lw config set release-url <url>` or\n" ..
        "    LOOMWORKS_RELEASE_URL (a local directory works as an offline mirror).\n")
    end
    exit(1)
  end
  io.write(res.updated
    and ("lw: installed loomworks " .. res.version .. "\n")
    or ("lw: already up to date (" .. res.version .. ")\n"))
  exit(0)
elseif command == "install" then
  local opts = { dry_run = false, no_modify_path = false, no_bundle = false }
  for _, v in ipairs(forwarded) do
    if v == "-y" or v == "--yes" then opts.assume_yes = true
    elseif v == "--no-modify-path" then opts.no_modify_path = true
    elseif v == "--no-bundle" then opts.no_bundle = true
    elseif v == "--dry-run" then opts.dry_run = true end
  end
  local report, err = require("boot.install").install(opts)
  if not report then
    io.stderr:write("lw: install failed: " .. tostring(err) .. "\n")
    exit(1)
  end
  for _, line in ipairs(report) do io.write(line .. "\n") end
  exit(0)
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

if not _G.vim then
  _G.vim = require("loomworks.shim")
end

_G.arg = forwarded
require("loomworks.cli")
