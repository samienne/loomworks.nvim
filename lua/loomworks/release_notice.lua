--- loomworks/release_notice.lua — where the release notes are, which version
--- is running, the last-seen record and the one-line upgrade notice
--- (spec §16.37). Rendering lives in loomworks/release_notes.lua (pure).
---
--- Uses NO boot module: the bundle runs under hosts back to v0.1.2
--- (tests/old_host_compat_spec.lua), so the data directory is derived from the
--- running bundle's own location (`<data>/lua-<ver>`), never from boot.paths.

local M = {}

--- File in the per-user data directory holding the last-seen version.
M.SEEN_FILE = "release-notes-seen"

local function uv() return vim.uv or vim.loop end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- This file's directory (forward slashes), or nil when loaded from a fused
--- bundle (chunk names `bundle:…`).
function M.source_dir()
  local src = debug.getinfo(1, "S").source or ""
  if src:sub(1, 1) ~= "@" then return nil end
  return (src:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$"))
end

--- The notes text: `CHANGELOG.md` beside this file (a release bundle carries
--- it as `loomworks/CHANGELOG.md`), else at the source tree's root
--- (`<root>/lua/loomworks/` -> `<root>/CHANGELOG.md`), else inside a fused
--- bundle. nil when this build carries none.
--- @param dir string|nil override of source_dir() (tests)
--- @return string|nil text, string|nil path
function M.read_text(dir)
  dir = dir or M.source_dir()
  if dir then
    for _, p in ipairs({ dir .. "/CHANGELOG.md", dir .. "/../../CHANGELOG.md" }) do
      local s = read_file(p)
      if s then return s, p end
    end
    return nil
  end
  local ok, luvi = pcall(require, "luvi")
  if ok and type(luvi) == "table" and luvi.bundle and luvi.bundle.readfile then
    local okr, s = pcall(luvi.bundle.readfile, "loomworks/CHANGELOG.md")
    if okr and type(s) == "string" then return s, "bundle:loomworks/CHANGELOG.md" end
  end
  return nil
end

--- The running release version: the `lua-<ver>` basename of the system-Lua
--- root the host resolved. nil for a development source, a fused build and
--- the editor.
--- @param luaroot string|nil default `_G.__loomworks_luaroot`
--- @return string|nil
function M.running_version(luaroot)
  luaroot = luaroot or rawget(_G, "__loomworks_luaroot")
  if type(luaroot) ~= "string" then return nil end
  local v = luaroot:gsub("\\", "/"):gsub("/+$", ""):match("/lua%-([^/]+)$")
  return require("loomworks.release_notes").normalize(v)
end

--- The per-user data directory of a globally installed release — the parent
--- of `<data>/lua-<ver>` — or nil (a development source, or a pinned release:
--- `<data>/pinned/<sha256>/lua-<ver>`, or the pinned sentinel set).
--- @param luaroot string|nil
--- @param getenv fun(name: string): string|nil
--- @return string|nil
function M.release_data_dir(luaroot, getenv)
  luaroot = luaroot or rawget(_G, "__loomworks_luaroot")
  getenv = getenv or os.getenv
  if not M.running_version(luaroot) then return nil end
  local p = luaroot:gsub("\\", "/"):gsub("/+$", "")
  local parent = p:match("^(.*)/[^/]+$")
  if not parent then return nil end
  if parent:match("/pinned/[^/]+$") then return nil end
  local pinned = getenv("LOOMWORKS_PINNED")
  if pinned and pinned ~= "" then return nil end
  return parent
end

--- @param dir string data dir
--- @return string|nil
function M.read_seen(dir)
  local s = read_file(dir .. "/" .. M.SEEN_FILE)
  if not s then return nil end
  return require("loomworks.release_notes").normalize((s:gsub("%s+", "")))
end

--- Record `version` as seen — only when it is newer than the recorded one.
--- Atomic (temp file + rename); every failure is silent.
--- @return boolean written
function M.write_seen(dir, version)
  local rn = require("loomworks.release_notes")
  if not dir or not rn.normalize(version) then return false end
  local cur = M.read_seen(dir)
  if cur and rn.compare(version, cur) <= 0 then return false end
  local path = dir .. "/" .. M.SEEN_FILE
  local tmp = path .. ".tmp" .. tostring(math.random(100000, 999999))
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(version .. "\n")
  f:close()
  local ok = pcall(function()
    local u = uv()
    local r = u.fs_rename(tmp, path)
    if not r then
      -- Windows refuses to rename over an existing file with some libuv builds.
      os.remove(path)
      assert(u.fs_rename(tmp, path))
    end
  end)
  if not ok then os.remove(tmp) end
  return ok
end

--- The newest installed release in `dir` older than `running` (the baseline
--- when no last-seen version was ever recorded), or nil.
function M.previous_installed(dir, running)
  local rn = require("loomworks.release_notes")
  local u = uv()
  local h = u.fs_scandir(dir)
  if not h then return nil end
  local best
  while true do
    local name = u.fs_scandir_next(h)
    if not name then break end
    local v = rn.normalize(name:match("^lua%-(.+)$"))
    if v and rn.compare(v, running) < 0 and (not best or rn.compare(v, best) > 0) then best = v end
  end
  return best
end

--- Whether release-notes output is silenced (setting `release-notes = off` or
--- `LOOMWORKS_RELEASE_NOTES` = off/0/false; the environment wins).
--- @param getenv fun(name: string): string|nil
--- @param cfg table|nil lw settings
function M.silenced(getenv, cfg)
  local e = (getenv or os.getenv)("LOOMWORKS_RELEASE_NOTES")
  if e and e ~= "" then
    e = e:lower()
    return e == "off" or e == "0" or e == "false" or e == "no"
  end
  return type(cfg) == "table" and cfg["release-notes"] == "off"
end

--- Pure decision. o: running, seen, previous (the baseline when seen is nil),
--- interactive. Returns { action = "notice", from, to } | { action = "record",
--- to } | nil.
function M.decide(o)
  local rn = require("loomworks.release_notes")
  if not o.running then return nil end
  local base = o.seen or o.previous
  if not base then
    -- A first installation: nothing to announce; start tracking.
    return { action = "record", to = o.running }
  end
  if rn.compare(o.running, base) <= 0 then return nil end
  if not o.interactive then return nil end
  return { action = "notice", from = base, to = o.running }
end

--- The notice line.
function M.notice_line(from, to)
  return "lw: updated " .. from .. " -> " .. to .. " - see what's new: lw release-notes --since " .. from
end

--- Decide, record and return the line to print (or nil). Never errors.
--- o: interactive, cfg (lw settings), luaroot?, getenv?
--- @return string|nil
function M.maybe_notice(o)
  local ok, line = pcall(function()
    local getenv = o.getenv or os.getenv
    if M.silenced(getenv, o.cfg) then return nil end
    local dir = M.release_data_dir(o.luaroot, getenv)
    if not dir then return nil end
    local running = M.running_version(o.luaroot)
    local seen = M.read_seen(dir)
    local d = M.decide({
      running = running,
      seen = seen,
      previous = (not seen) and M.previous_installed(dir, running) or nil,
      interactive = o.interactive,
    })
    if not d then return nil end
    M.write_seen(dir, d.to)
    if d.action == "notice" then return M.notice_line(d.from, d.to) end
    return nil
  end)
  return ok and line or nil
end

--- Record the running version as seen (after `lw release-notes` printed notes).
function M.mark_seen(o)
  o = o or {}
  pcall(function()
    local dir = M.release_data_dir(o.luaroot, o.getenv)
    local running = M.running_version(o.luaroot)
    if dir and running then M.write_seen(dir, running) end
  end)
end

return M
