-- Self-update's "what's new" lines (spec §16.32, §16.37).
--
-- The host knows nothing about the notes format: after `lw self-update`
-- installed a newer bundle, it loads THAT bundle's pure renderer
-- (loomworks/release_notes.lua, already signature-verified with the rest of the
-- bundle) into a sandbox of plain builtins, hands it the bundle's
-- loomworks/CHANGELOG.md, and prints what comes back folded to ASCII (§16.7).
-- Any failure reduces the output to the pointer line; nothing here can change
-- self-update's exit status (main.lua also pcall's it).

local uv_ok, uv = pcall(require, "uv")
if not uv_ok then uv = require("luv") end
local paths = require("boot.paths")

local M = {}

M.SEEN_FILE = "release-notes-seen"
M.MAX_WIDTH = 100
M.MAX_RELEASES = 5

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- Fold a line to printable ASCII: every control or non-ASCII byte -> `?`.
--- @param s string
--- @return string
function M.sanitize(s)
  return (tostring(s):gsub("[%z\1-\31\127-\255]", "?"))
end

--- Whether release-notes output is silenced: LOOMWORKS_RELEASE_NOTES
--- off/0/false/no (wins), else the `release-notes` setting `off`.
--- @param getenv fun(name: string): string|nil
--- @param cfg table|nil host settings (paths.read_config())
function M.silenced(getenv, cfg)
  local e = getenv("LOOMWORKS_RELEASE_NOTES")
  if e and e ~= "" then
    e = e:lower()
    return e == "off" or e == "0" or e == "false" or e == "no"
  end
  return type(cfg) == "table" and cfg["release-notes"] == "off"
end

--- Load a bundle's renderer into a sandbox with only pure builtins.
--- @param bundle_dir string `<data>/lua-<ver>`
--- @return table|nil renderer, string|nil err
function M.load_renderer(bundle_dir)
  local src = read_file(bundle_dir .. "/loomworks/release_notes.lua")
  if not src then return nil, "the bundle carries no release notes renderer" end
  local chunk, err = loadstring(src, "=release_notes")
  if not chunk then return nil, err end
  local env = {
    string = string, table = table, math = math,
    ipairs = ipairs, pairs = pairs, next = next, type = type, select = select,
    tostring = tostring, tonumber = tonumber, error = error, pcall = pcall,
    setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget,
  }
  setfenv(chunk, env)
  local ok, mod = pcall(chunk)
  if not ok then return nil, tostring(mod) end
  if type(mod) ~= "table" or type(mod.whats_new) ~= "function" then
    return nil, "the bundle's release notes renderer has no whats_new"
  end
  return mod
end

--- The block (without the pointer line) for `from` -> `to`, or nil + err.
--- @return string[]|nil lines, string|nil err
function M.block(bundle_dir, from, to, width)
  local text = read_file(bundle_dir .. "/loomworks/CHANGELOG.md")
  if not text then return nil, "the bundle carries no release notes" end
  local mod, err = M.load_renderer(bundle_dir)
  if not mod then return nil, err end
  local ok, lines = pcall(mod.whats_new, text, from, to, { width = width, max = M.MAX_RELEASES })
  if not ok then return nil, tostring(lines) end
  if type(lines) ~= "table" then return nil, "no lines" end
  local out = {}
  for i = 1, #lines do out[i] = M.sanitize(lines[i]) end
  return out
end

--- The lines self-update prints after installing `to` over `from`.
--- o: bundle_dir, from (nil: first installation), to, interactive, width,
---    silenced.
--- @return string[] lines (possibly empty)
function M.report(o)
  if o.silenced or not o.from or not o.to or not paths.version_gt(o.to, o.from) then return {} end
  local from = M.sanitize(o.from)
  local pointer = "Full notes: lw release-notes --since " .. from
  if not o.interactive then
    return { "lw: what's new since " .. from .. ": lw release-notes --since " .. from }
  end
  local width = o.width and math.min(o.width, M.MAX_WIDTH) or nil
  local block = M.block(o.bundle_dir, o.from, o.to, width)
  if not block or #block == 0 then
    return { "lw: what's new since " .. from .. ": lw release-notes --since " .. from }
  end
  local out = { "" }
  for _, l in ipairs(block) do out[#out + 1] = l end
  out[#out + 1] = pointer
  return out
end

--- Record `version` as the last-seen release-notes version in `data_dir`,
--- only when newer than the recorded one. Best-effort and silent.
function M.record_seen(data_dir, version)
  pcall(function()
    local path = data_dir .. "/" .. M.SEEN_FILE
    local cur = read_file(path)
    cur = cur and cur:gsub("%s+", "") or nil
    if cur and cur ~= "" and not paths.version_gt(version, cur) then return end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(version .. "\n")
    f:close()
    if not uv.fs_rename(tmp, path) then
      os.remove(path)
      if not uv.fs_rename(tmp, path) then os.remove(tmp) end
    end
  end)
end

--- The width of the terminal on stdout, or nil when it is not one.
function M.stdout_width()
  local ok, kind = pcall(uv.guess_handle, 1)
  if not ok or kind ~= "tty" then return nil end
  local w
  pcall(function()
    local tty = uv.new_tty(1, false)
    if tty then
      w = tty:get_winsize()
      pcall(function() tty:close() end)
    end
  end)
  if type(w) == "number" and w > 0 then return math.floor(w) end
  return 80
end

return M
