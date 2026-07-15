-- Shared path/config/version helpers for the host bootstrap (spec §16.11–16.13).
-- Used by main.lua (source resolution) and boot.update (acquisition). Depends
-- only on luv + boot.json; never on the vim shim.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local json = require("boot.json")

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

--- Read an environment variable. Uses libuv's view (`uv.os_getenv`) which sees
--- the real inherited environment AND in-process `uv.os_setenv` changes — the
--- latter is how the tests sandbox the data/config dirs. Empty is treated as
--- unset. Falls back to os.getenv if libuv lacks the call.
function M.getenv(name)
  -- Prefer libuv's view (sees in-process uv.os_setenv, used for test sandboxing)
  -- but only when it actually has a value: on Windows luvi returns empty for
  -- some inherited vars (notably PATH), so fall back to os.getenv, which reads
  -- the real inherited environment.
  if uv.os_getenv then
    local ok, v = pcall(uv.os_getenv, name)
    if ok and v ~= nil and v ~= "" then return v end
  end
  local v = os.getenv(name)
  return (v ~= nil and v ~= "") and v or nil
end
local getenv = M.getenv

--- Forward-slash a path and strip trailing slashes; nil/empty -> nil.
function M.norm(p)
  if not p or #p == 0 then return nil end
  return (p:gsub("\\", "/"):gsub("/+$", ""))
end

--- Per-user data dir that holds release bundles + the host binary.
--- %LOCALAPPDATA%\loomworks (win) | $XDG_DATA_HOME/loomworks | ~/.local/share/loomworks
function M.data_dir()
  local override = getenv("LOOMWORKS_DATA_DIR")
  if override then return (override:gsub("\\", "/"):gsub("/+$", "")) end
  if M.is_windows then
    local lad = getenv("LOCALAPPDATA")
    if lad then return (lad:gsub("\\", "/")) .. "/loomworks" end
  end
  local xdg = getenv("XDG_DATA_HOME")
  if xdg then return (xdg:gsub("\\", "/")) .. "/loomworks" end
  local home = getenv("HOME") or getenv("USERPROFILE") or "."
  return (home:gsub("\\", "/")) .. "/.local/share/loomworks"
end

--- Host config file (%APPDATA%\loomworks | $XDG_CONFIG_HOME | ~/.config).
function M.config_file()
  if M.is_windows then
    local ad = getenv("APPDATA")
    if ad then return (ad:gsub("\\", "/")) .. "/loomworks/config.json" end
  end
  local xdg = getenv("XDG_CONFIG_HOME")
  local base = xdg or ((getenv("HOME") or getenv("USERPROFILE") or ".") .. "/.config")
  return (base:gsub("\\", "/")) .. "/loomworks/config.json"
end

--- Read host config as a table (or {} if absent/unreadable).
function M.read_config()
  local f = io.open(M.config_file(), "r")
  if not f then return {} end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return {} end
  local decoded = json.decode(content)
  if type(decoded) ~= "table" or decoded == json.null then return {} end
  return decoded
end

--- Compare dotted-numeric versions ("1.10.0" > "1.9.0"); non-numeric parts
--- sort as 0. True when `a` is strictly newer than `b`.
function M.version_gt(a, b)
  local ai, bi = {}, {}
  for n in a:gmatch("%d+") do ai[#ai + 1] = tonumber(n) end
  for n in b:gmatch("%d+") do bi[#bi + 1] = tonumber(n) end
  for i = 1, math.max(#ai, #bi) do
    local x, y = ai[i] or 0, bi[i] or 0
    if x ~= y then return x > y end
  end
  return false
end

--- List installed release versions as { {ver=, dir=}, ... }, newest first.
function M.installed_releases()
  local base = M.data_dir()
  local scan = uv.fs_scandir(base)
  local out = {}
  if scan then
    while true do
      local name, typ = uv.fs_scandir_next(scan)
      if not name then break end
      local ver = name:match("^lua%-(.+)$")
      local is_dir = typ == "directory"
        or (uv.fs_stat(base .. "/" .. name) or {}).type == "directory"
      if ver and is_dir then out[#out + 1] = { ver = ver, dir = base .. "/" .. name } end
    end
  end
  table.sort(out, function(x, y) return M.version_gt(x.ver, y.ver) end)
  return out
end

--- Highest-versioned release root dir, or nil.
function M.newest_release_root()
  local rels = M.installed_releases()
  return rels[1] and rels[1].dir or nil
end

--- Recursively create a directory (mkdir -p). Returns true or nil, err.
function M.mkdirp(path)
  path = path:gsub("\\", "/")
  local acc = ""
  -- Preserve a leading "/" (posix) or drive prefix (C:/).
  local start = 1
  if path:sub(1, 1) == "/" then acc = "/"; start = 2 end
  local drive = path:match("^(%a:)/")
  if drive then acc = drive .. "/"; start = #drive + 2 end
  for seg in path:sub(start):gmatch("[^/]+") do
    acc = (acc == "" or acc:sub(-1) == "/") and (acc .. seg) or (acc .. "/" .. seg)
    if not uv.fs_stat(acc) then
      local ok, err = uv.fs_mkdir(acc, tonumber("777", 8))
      if not ok and not uv.fs_stat(acc) then return nil, err end
    end
  end
  return true
end

--- Remove a file or directory tree. Best-effort; returns true or nil, err.
function M.rm_rf(path)
  local st = uv.fs_lstat(path)
  if not st then return true end
  if st.type == "directory" then
    local scan = uv.fs_scandir(path)
    if scan then
      while true do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        M.rm_rf(path .. "/" .. name)
      end
    end
    return uv.fs_rmdir(path)
  end
  return uv.fs_unlink(path)
end

return M
