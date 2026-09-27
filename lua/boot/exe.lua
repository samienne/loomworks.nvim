-- Resolve a program name to an absolute path for the host bootstrap.
--
-- Same rule as loomworks/exe.lua (which the bootstrap cannot depend on — boot
-- modules never load from the bundle): a bare name is looked up in ABSOLUTE
-- PATH entries only — never the current directory, never an empty or relative
-- PATH entry — with PATHEXT on Windows. Spawning the bare name instead would
-- let libuv (and cmd.exe) pick a same-named file from the current directory on
-- Windows. Depends only on luv.

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end

local M = {}

M.is_windows = package.config:sub(1, 1) == "\\"

local function getenv(name)
  if uv.os_getenv then
    local ok, v = pcall(uv.os_getenv, name)
    if ok and v ~= nil and v ~= "" then return v end
  end
  local v = os.getenv(name)
  return (v ~= nil and v ~= "") and v or nil
end

--- Is `p` absolute? (Windows: drive-rooted or UNC; POSIX: leading `/`.)
function M.is_absolute(p)
  if type(p) ~= "string" or p == "" then return false end
  if M.is_windows then
    return p:match("^%a:[/\\]") ~= nil or p:match("^[/\\][/\\][^/\\]") ~= nil
  end
  return p:sub(1, 1) == "/"
end

local function is_executable(p)
  local st = uv.fs_stat(p)
  if not st or st.type ~= "file" then return false end
  if M.is_windows or not uv.fs_access then return true end
  local ok, res = pcall(uv.fs_access, p, "X")
  return not ok or res == true
end

--- Resolve `name` (a bare program name) to an absolute path, or nil + err.
--- An absolute `name` is returned when it exists; a relative path is refused.
--- @param name string
--- @return string|nil path, string|nil err
function M.resolve(name)
  if type(name) ~= "string" or name == "" then return nil, "empty command" end
  local exts = { "" }
  if M.is_windows then
    exts = {}
    if name:match("%.[^./\\]+$") then exts[1] = "" end
    for e in (getenv("PATHEXT") or ".COM;.EXE;.BAT;.CMD"):gmatch("[^;]+") do
      exts[#exts + 1] = e:lower()
    end
  end
  if name:find("[/\\]") then
    if not M.is_absolute(name) then
      return nil, "relative program path '" .. name .. "' is not allowed"
    end
    for _, ext in ipairs(exts) do
      if is_executable(name .. ext) then return name .. ext end
    end
    return nil, name .. " does not exist"
  end
  local sep = M.is_windows and ";" or ":"
  for entry in ((getenv("PATH") or "") .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    entry = entry:gsub('^"(.*)"$', "%1")
    if M.is_absolute(entry) then
      local base = entry:gsub("[/\\]+$", "")
      for _, ext in ipairs(exts) do
        local p = base .. "/" .. name .. ext
        if is_executable(p) then
          return M.is_windows and (p:gsub("/", "\\")) or p
        end
      end
    end
  end
  return nil, name .. " not found on PATH"
end

return M
