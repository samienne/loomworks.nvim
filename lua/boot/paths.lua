-- Shared path/config/version helpers for the host bootstrap.
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

--- Split a version into its numeric release core and its pre-release identifier
--- list. Build metadata (`+…`) is ignored for precedence (semver §10). A version
--- with no `-<pre>` suffix returns nil for the identifier list.
---   "0.2.0"        -> {0,2,0}, nil
---   "0.2.0-beta.1" -> {0,2,0}, {"beta","1"}
local function split_version(v)
  v = (v:gsub("%+.*$", ""))                  -- drop build metadata
  local core, pre = v:match("^(.-)%-(.+)$")  -- first '-' splits core / pre
  core = core or v
  local nums = {}
  for n in core:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
  local ids
  if pre and pre ~= "" then
    ids = {}
    for id in pre:gmatch("[^%.]+") do ids[#ids + 1] = id end
  end
  return nums, ids
end

--- Compare two pre-release identifiers per semver §11.4: numeric identifiers
--- compare numerically, numeric ranks below alphanumeric, alphanumerics compare
--- lexically. Returns -1 / 0 / 1.
local function cmp_ident(x, y)
  local nx, ny = tonumber(x), tonumber(y)
  if nx and ny then return nx < ny and -1 or (nx > ny and 1 or 0) end
  if nx and not ny then return -1 end        -- numeric < alphanumeric
  if ny and not nx then return 1 end
  if x == y then return 0 end
  return x < y and -1 or 1
end

--- Semver-aware comparison of two versions: -1 if a<b, 0 if equal, 1 if a>b.
--- The numeric release core compares field-by-field; on an equal core a
--- pre-release orders BELOW the full release (§16.29), and two pre-releases
--- compare identifier-by-identifier (a shorter identifier list ranks lower).
local function compare_versions(a, b)
  local acore, apre = split_version(a)
  local bcore, bpre = split_version(b)
  for i = 1, math.max(#acore, #bcore) do
    local x, y = acore[i] or 0, bcore[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  if not apre and not bpre then return 0 end
  if not apre then return 1 end              -- a is the full release -> newer
  if not bpre then return -1 end
  for i = 1, math.max(#apre, #bpre) do
    if apre[i] == nil then return -1 end     -- fewer identifiers -> lower
    if bpre[i] == nil then return 1 end
    local r = cmp_ident(apre[i], bpre[i])
    if r ~= 0 then return r end
  end
  return 0
end
M.compare_versions = compare_versions

--- Compare versions (semver-aware, §16.29). True when `a` is strictly newer than
--- `b`. A pre-release (`0.2.0-beta.1`) is older than its release (`0.2.0`); the
--- numeric core still orders "1.10.0" > "1.9.0".
function M.version_gt(a, b)
  return compare_versions(a, b) > 0
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

--- Directory holding acquired modules. A sibling of the
--- `lua-<ver>/` release roots, so a self-update never disturbs it and
--- `installed_releases` (which matches only `lua-*`) never lists it.
function M.modules_dir()
  return M.data_dir() .. "/modules"
end

--- Read an acquired module's install record (`.module.json`), or {} if absent
--- or unreadable. Records what `lw module install` wrote: version, api_version,
--- the source url + verified sha256, and the providers the package brings.
function M.read_module_meta(dir)
  local f = io.open(dir .. "/.module.json", "r")
  if not f then return {} end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return {} end
  local decoded = json.decode(content)
  if type(decoded) ~= "table" or decoded == json.null then return {} end
  return decoded
end

--- List acquired modules as { {name=, dir=, lua_root=, meta=}, ... }, sorted by
--- name. An entry is a subdirectory of `modules_dir()` that carries a `lua/`
--- tree; staging/download scratch dirs (dot-prefixed) are skipped.
function M.installed_modules()
  local base = M.modules_dir()
  local scan = uv.fs_scandir(base)
  local out = {}
  if scan then
    while true do
      local name, typ = uv.fs_scandir_next(scan)
      if not name then break end
      local dir = base .. "/" .. name
      local is_dir = typ == "directory"
        or (uv.fs_stat(dir) or {}).type == "directory"
      if is_dir and name:sub(1, 1) ~= "." and uv.fs_stat(dir .. "/lua") then
        out[#out + 1] = {
          name = name,
          dir = dir,
          lua_root = dir .. "/lua",
          meta = M.read_module_meta(dir),
        }
      end
    end
  end
  table.sort(out, function(x, y) return x.name < y.name end)
  return out
end

--- The `lua/` roots of all acquired modules, for the host's require/runtime
--- searchers. Cheap list used at startup by main.lua and the vim shim.
function M.module_lua_roots()
  local roots = {}
  for _, m in ipairs(M.installed_modules()) do roots[#roots + 1] = m.lua_root end
  return roots
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
