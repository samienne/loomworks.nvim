-- Universal luvi entry point — the host **bootstrap** (spec §16.11).
--
-- This is the only Lua fused into the host binary. It carries no behavioral
-- logic; it resolves the *system Lua* (the loomworks implementation) from one
-- of two kinds of source and then runs the CLI:
--
--   1. a development source — a working tree on disk, opted into explicitly
--      (LOOMWORKS_LUA env, a `--dev` flag, or config `default-source=dev`);
--      verification is skipped (it is the caller's own checkout).
--   2. the release source — the highest-versioned bundle under the data dir
--      (`<data>/loomworks/lua-<ver>/`). In a later slice these arrive verified
--      via `lw self-update`; here they are simply resolved if present.
--
-- If neither resolves, the fused luvi bundle (the embedded zip, or the source
-- dir on disk when run as `luvi . --`) is the last-resort fallback, so a
-- dev/full-fused exe and the nvim-hosted path keep working unchanged.
--
-- The resolved on-disk root (dev or release) is published as
-- `_G.__loomworks_luaroot` so the shim's `nvim_get_runtime_file` can discover
-- `<root>/loomworks/<kind>/*.lua` off disk.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local is_windows = package.config:sub(1, 1) == "\\"
local loaders = package.loaders or package.searchers

-- ---- args: peel off the bootstrap-level `--dev[=PATH]` flag -----------------
-- Everything else is forwarded verbatim to the CLI.
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

-- ---- host configuration -----------------------------------------------------
-- Read with a plain pattern (not the JSON lib): this runs before any Lua loads.
local function config_file()
  if is_windows then
    local ad = os.getenv("APPDATA")
    if ad and #ad > 0 then return (ad:gsub("\\", "/")) .. "/loomworks/config.json" end
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local base = (xdg and #xdg > 0) and xdg
    or ((os.getenv("HOME") or os.getenv("USERPROFILE") or ".") .. "/.config")
  return (base:gsub("\\", "/")) .. "/loomworks/config.json"
end

local function read_config()
  local f = io.open(config_file(), "r")
  if not f then return {} end
  local content = f:read("*a"); f:close()
  content = content or ""
  return {
    dev_lua = content:match('"dev%-lua"%s*:%s*"([^"]*)"'),
    default_source = content:match('"default%-source"%s*:%s*"([^"]*)"'),
  }
end

local cfg = read_config()

local function norm(p)
  if not p or #p == 0 then return nil end
  return (p:gsub("\\", "/"):gsub("/+$", ""))
end

-- ---- data dir (where release bundles live) ----------------------------------
local function data_dir()
  if is_windows then
    local lad = os.getenv("LOCALAPPDATA")
    if lad and #lad > 0 then return (lad:gsub("\\", "/")) .. "/loomworks" end
  end
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and #xdg > 0 then return (xdg:gsub("\\", "/")) .. "/loomworks" end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return (home:gsub("\\", "/")) .. "/.local/share/loomworks"
end

-- Compare dotted-numeric versions ("1.10.0" > "1.9.0"); non-numeric parts sort
-- as 0. Returns true when `a` is strictly newer than `b`.
local function version_gt(a, b)
  local ai, bi = {}, {}
  for n in a:gmatch("%d+") do ai[#ai + 1] = tonumber(n) end
  for n in b:gmatch("%d+") do bi[#bi + 1] = tonumber(n) end
  for i = 1, math.max(#ai, #bi) do
    local x, y = ai[i] or 0, bi[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

-- Highest-versioned `<data>/loomworks/lua-<ver>/` directory, or nil.
local function newest_release_root()
  local base = data_dir()
  local scan = uv.fs_scandir(base)
  if not scan then return nil end
  local best_ver, best_dir
  while true do
    local name, typ = uv.fs_scandir_next(scan)
    if not name then break end
    local ver = name:match("^lua%-(.+)$")
    -- fs_scandir_next may not report the type on every platform; stat to be sure.
    local is_dir = typ == "directory"
      or (uv.fs_stat(base .. "/" .. name) or {}).type == "directory"
    if ver and is_dir then
      if not best_ver or version_gt(ver, best_ver) then
        best_ver, best_dir = ver, base .. "/" .. name
      end
    end
  end
  return best_dir
end

-- ---- resolve the system-Lua source (spec §16.11) ----------------------------
-- Dev is used only on explicit opt-in; the default is the release source.
local env_lua = norm(os.getenv("LOOMWORKS_LUA"))
local dev_opt_in = env_lua ~= nil or dev_flag or cfg.default_source == "dev"

local luaroot, source_kind
if dev_opt_in then
  luaroot = env_lua or norm(dev_flag_path) or norm(cfg.dev_lua)
  source_kind = "dev"
  if not luaroot then
    io.stderr:write(
      "lw: development source requested but no directory is configured.\n" ..
      "    Set one with `lw config set dev-lua <path>`, pass `--dev=<path>`,\n" ..
      "    or export LOOMWORKS_LUA=<path>.\n")
    os.exit(1)
  end
  -- A dev root is authoritative (no bundle fallback), so validate it up front
  -- rather than surfacing a bare `require` traceback later.
  if not uv.fs_stat(luaroot .. "/loomworks") then
    io.stderr:write(
      "lw: development source '" .. luaroot .. "' is not a loomworks `lua/` " ..
      "directory\n    (no `loomworks/` subdir found there).\n")
    os.exit(1)
  end
else
  luaroot = newest_release_root()
  source_kind = luaroot and "release" or nil
end

-- ---- install searchers ------------------------------------------------------
-- On-disk root (dev or release) is authoritative; the fused bundle is only a
-- fallback. A disk searcher rooted at `<luaroot>/loomworks/...`:
if luaroot then
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
end

-- luvi bundle searcher — the last-resort fallback, used only when no on-disk
-- root resolved (a full-fused dev exe, or the `luvi . --` source-dir run).
-- When a dev or release root IS resolved it is authoritative and complete, so
-- we do not also consult the bundle: a partial on-disk tree fails loudly rather
-- than silently mixing in bundled code. Standard `require` can't read a luvi
-- bundle, so back the searcher with the bundle API.
if not luaroot then
  local bundle = require("luvi").bundle
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

-- ---- run --------------------------------------------------------------------
if not _G.vim then
  _G.vim = require("loomworks.shim")
end

_G.arg = forwarded
require("loomworks.cli")
