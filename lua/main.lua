-- Universal luvi entry point (a bundled `lw` executable or a disk run).
--
-- Resolves loomworks Lua through a searcher chain and runs the CLI:
--   1. dev override  — a working tree (LOOMWORKS_LUA env, else config dev-lua)
--   2. luvi bundle   — the embedded zip (shipped exe) or the source dir on disk
-- so a developer can point at their checkout without rebuilding the binary,
-- and everyone else runs the bundled/downloaded Lua.

local loaders = package.loaders or package.searchers

-- ---- dev override -----------------------------------------------------------
-- Precedence: LOOMWORKS_LUA env > config "dev-lua". The config is read with a
-- plain pattern (not the JSON lib) since this runs before any Lua is loaded.
local function config_file()
  if package.config:sub(1, 1) == "\\" then
    local ad = os.getenv("APPDATA")
    if ad and #ad > 0 then return (ad:gsub("\\", "/")) .. "/loomworks/config.json" end
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  local base = (xdg and #xdg > 0) and xdg or ((os.getenv("HOME") or os.getenv("USERPROFILE") or ".") .. "/.config")
  return (base:gsub("\\", "/")) .. "/loomworks/config.json"
end

local function dev_lua_dir()
  local env = os.getenv("LOOMWORKS_LUA")
  if env and #env > 0 then return env end
  local f = io.open(config_file(), "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  return content and content:match('"dev%-lua"%s*:%s*"([^"]*)"')
end

local devdir = dev_lua_dir()
if devdir then
  devdir = devdir:gsub("\\", "/"):gsub("/+$", "")
  -- Expose the dev root to the shim so nvim_get_runtime_file (module/SDK
  -- discovery) can list `<devdir>/loomworks/<kind>/*.lua` off disk.
  _G.__loomworks_devdir = devdir
  table.insert(loaders, 1, function(modname)
    local base = devdir .. "/" .. modname:gsub("%.", "/")
    for _, cand in ipairs({ base .. ".lua", base .. "/init.lua" }) do
      local fh = io.open(cand, "r")
      if fh then
        local s = fh:read("*a"); fh:close()
        local chunk, err = loadstring(s, "@" .. cand)
        return chunk or ("\n\t" .. tostring(err))
      end
    end
    return "\n\tno dev file for '" .. modname .. "'"
  end)
end

-- ---- luvi bundle searcher ---------------------------------------------------
-- Standard `require` doesn't read from a luvi bundle, so back a searcher with
-- the bundle API (works for both the embedded zip and a source dir on disk).
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

if not _G.vim then
  _G.vim = require("loomworks.shim")
end

_G.arg = { ... }
require("loomworks.cli")
