--- loomworks/cli.lua — headless entry point for the standalone runner.
---
--- Fulfils specification.md §16. v1 hosted under Neovim
--- (`nvim --headless -u NONE -l lua/loomworks/cli.lua <cmd> [args]`); the
--- luvi + shim host is layered on later without changing this file.
---
--- Commands: profiles | build [profile] | test [profile]

-- Make loomworks requireable regardless of runtimepath (we run under -u NONE).
local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local lua_dir = src:gsub("loomworks/cli%.lua$", "")
package.path = lua_dir .. "?.lua;" .. lua_dir .. "?/init.lua;" .. package.path

local uv = vim.uv or vim.loop

local M = {}

local function die(msg, code)
  io.stderr:write("lw: " .. tostring(msg) .. "\n")
  os.exit(code or 1)
end

--- Walk up from `start` for the nearest directory containing loomworks.json.
--- @param start? string
--- @return string|nil root
local function find_root(start)
  local dir = (start or uv.cwd()):gsub("\\", "/"):gsub("/+$", "")
  while dir ~= "" do
    if uv.fs_stat(dir .. "/loomworks.json") then return dir end
    local parent = dir:gsub("/[^/]*$", "")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

--- Bootstrap a live, remerged Workspace headlessly and wait for tool detection.
--- @param root string
--- @return table workspace, table core
local function load_workspace(root)
  local lw = require("loomworks")
  local core = lw._core()
  -- Route notifications to stderr (warnings/errors only); the editor's
  -- info chatter is noise on a CLI.
  core._deps.notify = function(msg, level)
    if not level or level >= vim.log.levels.WARN then
      io.stderr:write(tostring(msg) .. "\n")
    end
  end
  core:setup({ root = root })
  local ok = vim.wait(15000, function()
    return core._state == "initialized" or core._state == "uninitialized"
  end, 25)
  if not ok then die("timed out loading workspace at " .. root) end
  local ws = lw.get_workspace()
  if not ws then
    local e = core.get_setup_error and core:get_setup_error()
    die("failed to load workspace" .. (e and e.message and (": " .. e.message) or ""))
  end
  -- Await tool detection (needed for cold builds + accurate buildability).
  vim.wait(45000, function() return ws._tool_state == "scanned" end, 25)
  return ws, core
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

function M.cmd_profiles(ws)
  local profiles = ws._profiles or {}
  if #profiles == 0 then
    print("(no profiles defined)")
    return 0
  end
  local active = ws._active_profile_key
  for _, p in ipairs(profiles) do
    local tools = table.concat(p._tool_keys or {}, ", ")
    local set = p._configuration_set_name or "?"
    local mark = (p.key == active) and "* " or "  "
    local valid, reasons = true, nil
    if p.is_valid then valid, reasons = p:is_valid() end
    local status = valid and "" or ("  [unbuildable: " .. table.concat(reasons or {}, "; ") .. "]")
    print(string.format("%s%s", mark, p.key))
    print(string.format("      set=%s  tools=[%s]%s", set, tools, status))
  end
  return 0
end

--- Resolve which profile to operate on (spec §16.3):
--- explicit name → user.json active → single published → error.
--- @param ws table
--- @param name string|nil
--- @return table profile
local function resolve_profile(ws, name)
  local profiles = ws._profiles or {}
  if name then
    for _, p in ipairs(profiles) do
      if p.key == name then return p end
    end
    die("no profile named '" .. name .. "'. Run `lw profiles` to list.")
  end
  local active = ws._active_profile_key
  if active then
    for _, p in ipairs(profiles) do
      if p.key == active then return p end
    end
  end
  if #profiles == 1 then return profiles[1] end
  die("no profile specified and no unambiguous default — run `lw profiles`, then `lw build <profile>`")
end

--- Spawn one step's command, streaming output; return its exit code.
--- @param step table { cmd, cwd, env }
--- @param root string
--- @return integer code
local function run_spec(step, root)
  -- An empty env table would wipe PATH; inherit the parent env instead.
  local env = (step.env and next(step.env)) and step.env or nil
  local res = vim.system(step.cmd, {
    cwd = step.cwd or root,
    env = env,
    text = true,
  }):wait()
  io.write(res.stdout or "")
  local err = res.stderr or ""
  if err ~= "" then io.stderr:write(err) end
  return res.code
end

function M.cmd_build(ws, profile_name)
  local overseer = require("loomworks.overseer")
  local profile = resolve_profile(ws, profile_name)
  local steps = overseer.plan_profile_build(profile)
  if not steps or #steps == 0 then
    die("nothing to build for profile '" .. profile.key ..
      "' — no buildable projects (unavailable module or unresolved tool?)")
  end
  print("building profile: " .. profile.key)
  for _, step in ipairs(steps) do
    print(string.format("==> [%s] %s", step.kind, step.name or "?"))
    local code = run_spec(step, ws.root)
    if code ~= 0 then
      die(string.format("%s failed (exit %d): %s", step.kind, code, step.name or "?"), code)
    end
  end
  print("BUILD OK: " .. profile.key)
  return 0
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function main()
  local a = _G.arg or {}
  local command = a[1]
  if not command or command == "-h" or command == "--help" then
    die("usage: lw <profiles|build|test> [profile]", command and 0 or 1)
  end

  local root = find_root()
  if not root then die("no loomworks.json found (searched up from cwd)") end

  local ws = load_workspace(root)

  if command == "profiles" then
    os.exit(M.cmd_profiles(ws))
  elseif command == "build" then
    os.exit(M.cmd_build(ws, a[2]))
  else
    die("command not yet implemented: " .. command)
  end
end

main()
