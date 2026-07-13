--- loomworks/cli.lua — headless entry point for the standalone runner.
---
--- Fulfils specification.md §16. v1 hosted under Neovim
--- (`nvim --headless -u NONE -l lua/loomworks/cli.lua <cmd> [args]`); the
--- luvi + shim host is layered on later without changing this file.
---
--- Commands: (status) | init | project <add|remove|list> | profiles |
---           profile <list|select> | build [profile] | publish |
---           test [profile] | config <...> | help

-- Make loomworks requireable regardless of runtimepath (nvim host, -u NONE).
-- Under the luvi host the source is a "bundle:" path and require resolves via
-- luvi's bundle loader, so skip the package.path dance there.
local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
if not src:match("^bundle:") then
  local lua_dir = src:gsub("loomworks/cli%.lua$", "")
  package.path = lua_dir .. "?.lua;" .. lua_dir .. "?/init.lua;" .. package.path
end

local uv = vim.uv or vim.loop

-- Windows: render UTF-8 diagnostics (em dashes, arrows — shared with the editor
-- UI) correctly in any console, in-process. Both the nvim and luvi hosts run
-- this, so no per-shell chcp is needed.
if package.config:sub(1, 1) == "\\" then
  local ok_ffi, ffi = pcall(require, "ffi")
  if ok_ffi then
    pcall(function()
      ffi.cdef([[ int SetConsoleOutputCP(unsigned int wCodePageID); ]])
      ffi.C.SetConsoleOutputCP(65001)
    end)
  end
end

local M = {}

--- Exit, flushing stdout first. Under `nvim -l`, print() is fully buffered on
--- a pipe and os.exit() skips the flush; luvi is fine but this keeps both hosts
--- reliable.
local function finish(code)
  io.stdout:flush()
  os.exit(code or 0)
end

--- Write a line to real stdout. `print()` goes to stderr under `nvim -l`, so
--- CLI output (the parseable part) must use io.write on both hosts.
local function out(s) io.write((s or "") .. "\n") end

local function die(msg, code)
  io.stdout:flush()
  io.stderr:write("lw: " .. tostring(msg) .. "\n")
  os.exit(code or 1)
end

--- Walk up from `start` for the nearest directory containing loomworks.json.
--- @param start? string
--- @return string|nil root
local function find_root(start)
  local dir = (start or uv.cwd()):gsub("\\", "/"):gsub("/+$", "")
  while dir ~= "" do
    -- A workspace is recognized by the published snapshot OR the working copy
    -- (spec §2.2/§2.4) — a not-yet-published `lw init` has only the latter.
    if uv.fs_stat(dir .. "/loomworks.json")
        or uv.fs_stat(dir .. "/.nvim/loomworks.user.json") then
      return dir
    end
    local parent = dir:gsub("/[^/]*$", "")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

local function is_windows() return package.config:sub(1, 1) == "\\" end

-- ---------------------------------------------------------------------------
-- Path helpers + interactive prompts
-- ---------------------------------------------------------------------------

--- The directory the user typed paths relative to. Under the luvi host the
--- process runs from the bundle dir, so the launcher passes the real cwd in
--- LW_ROOT; under `nvim -l` the process already runs in the user's cwd.
local function user_cwd()
  local d = os.getenv("LW_ROOT")
  if d and #d > 0 then return (d:gsub("\\", "/"):gsub("/+$", "")) end
  return (uv.cwd():gsub("\\", "/"):gsub("/+$", ""))
end

local function basename(p)
  return (p:gsub("/+$", ""):match("[^/]+$")) or p
end

--- Normalize for prefix comparison: forward slashes, no trailing slash,
--- lowercased on Windows (matches deps.normalize's case folding).
local function norm_cmp(p)
  p = p:gsub("\\", "/"):gsub("/+$", "")
  if is_windows() then p = p:lower() end
  return p
end

--- Resolve `p` (relative to `base`, or absolute) to a real absolute path.
--- @return string|nil abs forward-slashed real path, or nil if it doesn't exist
local function resolve_abs(p, base)
  p = p:gsub("\\", "/")
  local joined = (p:match("^%a:/") or p:sub(1, 1) == "/") and p or (base .. "/" .. p)
  local real = uv.fs_realpath(joined)
  return real and (real:gsub("\\", "/")) or nil
end

--- Return `abs` made relative to workspace `root` ("." if equal), or nil if
--- `abs` is not inside `root`. `root`/`abs` are real, same-cased forward paths.
local function rel_to_root(root, abs)
  local nr, na = norm_cmp(root), norm_cmp(abs)
  if na == nr then return "." end
  if na:sub(1, #nr + 1) == nr .. "/" then return abs:sub(#root + 2) end
  return nil
end

--- Mirror workspace_view.derive_key_and_path (kept inline to avoid pulling
--- editor-only requires into the standalone host).
local function derive_key_and_path(root, abs, name)
  local rel = abs:sub(#root + 2)
  if rel == "" then return name, "."
  elseif rel == name then return name, nil
  else return (rel:gsub("/", "_")), rel end
end

--- Is stdin an interactive terminal? Gates prompting: interactive → ask;
--- non-interactive (CI, pipe) → the caller errors instead of blocking.
local function is_tty()
  local ok, h = pcall(uv.guess_handle, 0)
  return ok and h == "tty"
end

--- Prompt for a line. Blank input returns `default` (nil if none). Returns nil
--- only on EOF. Trims surrounding whitespace.
local function prompt_line(question, default)
  io.write(question)
  if default and default ~= "" then io.write(" [" .. default .. "]") end
  io.write(": ")
  io.stdout:flush()
  local line = io.read("*l")
  if line == nil then return nil end
  if line:match("^%s*$") then return default end
  return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- User config (~/.config/loomworks/config.json, %APPDATA%\loomworks on Windows)
-- ---------------------------------------------------------------------------

local function config_dir()
  if is_windows() then
    local appdata = os.getenv("APPDATA")
    if appdata and #appdata > 0 then return (appdata:gsub("\\", "/")) .. "/loomworks" end
  end
  local xdg = os.getenv("XDG_CONFIG_HOME")
  if xdg and #xdg > 0 then return (xdg:gsub("\\", "/")) .. "/loomworks" end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return (home:gsub("\\", "/")) .. "/.config/loomworks"
end

local function config_path() return config_dir() .. "/config.json" end

local function read_config()
  local f = io.open(config_path(), "r")
  if not f then return {} end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return {} end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function write_config(cfg)
  vim.fn.mkdir(config_dir(), "p")
  local encoded = (next(cfg) == nil) and "{}" or vim.json.encode(cfg)
  local f, err = io.open(config_path(), "w")
  if not f then return false, err end
  f:write(encoded); f:write("\n"); f:close()
  return true
end

--- Bootstrap a live, remerged Workspace headlessly. Waits for tool detection
--- unless `wait_tools` is false (status only needs pinned info, not live tools).
--- @param root string
--- @param wait_tools? boolean default true
--- @return table workspace, table core
local function load_workspace(root, wait_tools)
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
  if wait_tools ~= false then
    vim.wait(45000, function() return ws._tool_state == "scanned" end, 25)
  end
  return ws, core
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

function M.cmd_profiles(ws)
  local profiles = ws._profiles or {}
  if #profiles == 0 then
    out("(no profiles defined)")
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
    out(string.format("%s%s", mark, p.key))
    out(string.format("      set=%s  tools=[%s]%s", set, tools, status))
  end
  return 0
end

--- Resolve which profile to operate on (spec §16.3): explicit name (exact,
--- then unambiguous substring) → user.json active → single → error.
--- @param ws table
--- @param name string|nil
--- @return table profile
local function resolve_profile(ws, name)
  local profiles = ws._profiles or {}
  if name then
    for _, p in ipairs(profiles) do
      if p.key == name then return p end
    end
    -- Substring match — profile keys are long, so `lw build clang-19` works.
    local matches = {}
    for _, p in ipairs(profiles) do
      if p.key:find(name, 1, true) then matches[#matches + 1] = p end
    end
    if #matches == 1 then return matches[1] end
    if #matches > 1 then
      local keys = {}
      for _, p in ipairs(matches) do keys[#keys + 1] = p.key end
      die("'" .. name .. "' matches multiple profiles: " .. table.concat(keys, ", "))
    end
    die("no profile matching '" .. name .. "'. Run `lw profiles` to list.")
  end
  local active = ws._active_profile_key
  if active then
    for _, p in ipairs(profiles) do
      if p.key == active then return p end
    end
  end
  if #profiles == 1 then return profiles[1] end
  die("no profile specified and no unambiguous default — run `lw profile select`")
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
  out("building profile: " .. profile.key)
  for _, step in ipairs(steps) do
    out(string.format("==> [%s] %s", step.kind, step.name or "?"))
    local code = run_spec(step, ws.root)
    if code ~= 0 then
      die(string.format("%s failed (exit %d): %s", step.kind, code, step.name or "?"), code)
    end
  end
  out("BUILD OK: " .. profile.key)
  return 0
end

--- `lw init` — initialize the working copy (.nvim/loomworks.user.json).
--- loomworks.json is written later by `lw publish` (working-copy model, §2.4).
function M.cmd_init()
  local dir = (os.getenv("LW_ROOT") or uv.cwd()):gsub("\\", "/"):gsub("/+$", "")
  local ok, err = require("loomworks.workspace").init_workspace(dir)
  if not ok then die(err or "failed to initialize workspace") end
  out("initialized workspace at " .. dir)
  out("  created .nvim/loomworks.user.json (working copy)")
  out("")
  out("Add projects/profiles (editor or manual edit), then `lw publish` to")
  out("write the shared loomworks.json.")
  return 0
end

--- `lw publish` — write the shared loomworks.json from the working copy.
function M.cmd_publish(root)
  local ws = load_workspace(root, false)
  local ok, err = ws:publish()
  if not ok then die("publish failed: " .. tostring(err)) end
  out("published " .. ws.root .. "/loomworks.json")
  return 0
end

-- ---------------------------------------------------------------------------
-- Projects (add / remove / list) — explicit management, writes user.json (§16.9)
-- ---------------------------------------------------------------------------

--- Pick a module type interactively. `detected` is the detect_all_types result
--- (nil → offer all installed modules). Non-interactive callers can't pick, so
--- this errors with the explicit-argument hint instead of blocking.
--- @param detected { type: string, marker: string }[]|nil
--- @return string type
local function pick_type(detected)
  local modules = require("loomworks.modules")
  local options = {}
  if detected then
    for _, d in ipairs(detected) do options[#options + 1] = d.type end
  else
    options = modules.list()
  end
  if #options == 0 then die("no modules available to add a project as") end
  if not is_tty() then
    die("could not determine the project type — pass it explicitly:\n" ..
      "  lw project add <path> <type>   (types: " .. table.concat(options, ", ") .. ")")
  end
  out(detected and "Multiple project types detected:" or
    "No type detected — select one:")
  for i, t in ipairs(options) do
    local marker = detected and ("   (" .. detected[i].marker .. ")") or ""
    out(string.format("  %d) %s%s", i, t, marker))
  end
  out("")
  local line = prompt_line("Enter number (blank to cancel)")
  if not line or line == "" then out("cancelled"); finish(0) end
  local n = tonumber(line)
  if not n or not options[n] then die("invalid selection: " .. tostring(line)) end
  return options[n]
end

--- Find a free project key. On collision: prompt for a new one (interactive) or
--- error (non-interactive). Suggests `<key>-<type>` since a same-folder second
--- project of another type is the common cause.
local function resolve_free_key(ws, key, mtype)
  local function taken(k)
    for _, p in pairs(ws._projects) do if p.key == k then return true end end
    return false
  end
  if not taken(key) then return key end
  if not is_tty() then
    die("project '" .. key .. "' already exists — pass a distinct name:\n" ..
      "  lw project add <path> <type> <name>")
  end
  local suggestion = key .. "-" .. mtype
  while true do
    local ans = prompt_line("project '" .. key .. "' exists; new name", suggestion)
    if not ans or ans == "" then out("cancelled"); finish(0) end
    if not taken(ans) then return ans end
    io.stderr:write("lw: '" .. ans .. "' also exists\n")
    suggestion = ans .. "-2"
  end
end

--- `lw project add <path> [type] [name]` — register an existing directory as a
--- project in the working copy. Path is inspected to detect/validate the type.
function M.cmd_project_add(root, path_arg, type_arg, name_arg)
  if not path_arg then die("usage: lw project add <path> [type] [name]") end
  local abs = resolve_abs(path_arg, user_cwd())
  local st = abs and uv.fs_stat(abs)
  if not st or st.type ~= "directory" then die("not a directory: " .. path_arg) end
  local root_real = (uv.fs_realpath(root) or root):gsub("\\", "/")
  local rel = rel_to_root(root_real, abs)
  if not rel then die("project path must be inside the workspace (" .. root .. ")") end

  local modules = require("loomworks.modules")
  local detected = modules.detect_all_types(abs)

  -- Resolve type: explicit (validated) or detected/prompted.
  local mtype = type_arg
  if mtype then
    local mod = modules.get(mtype)
    if not mod then die("unknown module type '" .. mtype .. "'") end
    if mod.detect and not mod.detect(abs) then
      io.stderr:write("lw: warning: no " .. mtype .. " marker found in " .. rel .. "\n")
    end
  elseif #detected == 1 then
    mtype = detected[1].type
    out(string.format("detected %s (%s)", mtype, detected[1].marker))
  else
    mtype = pick_type(#detected > 1 and detected or nil)
  end

  -- Resolve key + stored path. Explicit name wins; else derive like the editor.
  local key, store_path
  if name_arg then
    key, store_path = name_arg, rel
  else
    key, store_path = derive_key_and_path(root_real, abs, basename(abs))
  end

  local ws = load_workspace(root, false) -- no tools needed to author user.json
  key = resolve_free_key(ws, key, mtype)

  local project, err = ws:add_project(key, mtype, store_path)
  if not project then die("could not add project: " .. tostring(err)) end
  out(string.format("added project '%s' (%s) at %s", key, mtype, store_path or key))
  out("")
  out("Working copy updated (.nvim/loomworks.user.json). Map it into a")
  out("configuration set to build it, then `lw publish` to share it.")
  return 0
end

--- `lw project remove <name>` — drop a project from the working copy.
function M.cmd_project_remove(root, name_arg)
  if not name_arg then die("usage: lw project remove <name>") end
  local ws = load_workspace(root, false)
  local proj, names = nil, {}
  for _, p in pairs(ws._projects) do
    names[#names + 1] = p.key
    if p.key == name_arg then proj = p end
  end
  if not proj then
    table.sort(names)
    die("no project named '" .. name_arg .. "'. Existing: " ..
      (next(names) and table.concat(names, ", ") or "(none)"))
  end
  local ok, err = ws:remove_project(proj)
  if not ok then die("could not remove project: " .. tostring(err)) end
  out("removed project '" .. proj.key .. "'")
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw project [list]` — list the workspace's projects.
function M.cmd_project_list(root)
  local ws = load_workspace(root, false)
  local sorted = {}
  for _, p in ipairs(ws._projects or {}) do sorted[#sorted + 1] = p end
  if #sorted == 0 then out("(no projects)"); return 0 end
  table.sort(sorted, function(a, b) return a.key < b.key end)
  for _, p in ipairs(sorted) do
    local t = p.type or (p._module and p._module.id) or "?"
    out(string.format("  %-20s %-10s %s", p.key, t, p.path or "."))
  end
  return 0
end

--- `lw project <add|remove|list>`
function M.cmd_project(sub, root, a3, a4, a5)
  if sub == "add" then return M.cmd_project_add(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_project_remove(root, a3) end
  if sub == nil or sub == "list" then return M.cmd_project_list(root) end
  die("unknown project subcommand '" .. tostring(sub) .. "' — use add|remove|list")
end

--- `lw profile select` — interactive picker that sets the active profile.
--- Writes user.json (explicit management, spec §16.9).
function M.select_profile(ws)
  local profiles = ws._profiles or {}
  if #profiles == 0 then die("no profiles to select — run `lw profiles`") end
  local active = ws._active_profile_key
  out("Select a profile:")
  out("")
  for i, p in ipairs(profiles) do
    out(string.format("  %d) %s%s", i, p.key, (p.key == active) and "   (current)" or ""))
  end
  out("")
  io.write("Enter number (blank to cancel): ")
  io.stdout:flush()
  local line = io.read("*l")
  if not line or line:match("^%s*$") then out("cancelled"); return 0 end
  local n = tonumber(line)
  if not n or not profiles[n] then die("invalid selection: " .. tostring(line)) end
  profiles[n]:activate()
  out("active profile: " .. profiles[n].key)
  return 0
end

--- `lw profile <list|select>`
function M.cmd_profile(sub, root)
  if sub == "select" then
    return M.select_profile(load_workspace(root, false))
  end
  if sub == nil or sub == "list" then
    return M.cmd_profiles(load_workspace(root))
  end
  die("unknown profile subcommand '" .. tostring(sub) .. "' — use list|select")
end

--- `lw config <list|get|set|unset> [key] [value]`
function M.cmd_config(sub, key, value)
  local cfg = read_config()
  if sub == nil or sub == "list" then
    out("config file: " .. config_path())
    local keys = {}
    for k in pairs(cfg) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then
      out("  (empty)")
    else
      for _, k in ipairs(keys) do out(string.format("  %s = %s", k, tostring(cfg[k]))) end
    end
    return 0
  elseif sub == "get" then
    if not key then die("usage: lw config get <key>") end
    out(cfg[key] == nil and "(unset)" or tostring(cfg[key]))
    return 0
  elseif sub == "set" then
    if not key or value == nil then die("usage: lw config set <key> <value>") end
    -- Path-like values use forward slashes so the bootstrap can read them raw.
    cfg[key] = (key == "dev-lua") and value:gsub("\\", "/") or value
    local ok, err = write_config(cfg)
    if not ok then die("failed to write config: " .. tostring(err)) end
    out(string.format("set %s = %s", key, tostring(cfg[key])))
    return 0
  elseif sub == "unset" then
    if not key then die("usage: lw config unset <key>") end
    cfg[key] = nil
    local ok, err = write_config(cfg)
    if not ok then die("failed to write config: " .. tostring(err)) end
    out("unset " .. key)
    return 0
  end
  die("unknown config subcommand '" .. tostring(sub) .. "' — use list|get|set|unset")
end

--- Bare `lw` — workspace status. Works outside a workspace too.
function M.cmd_status(root)
  if not root then
    out("loomworks — no workspace here (no loomworks.json found)")
    out("")
    out("Run `lw help` for commands.")
    return 0
  end
  local ws = load_workspace(root, false) -- pinned info only; skip detection
  out(string.format("loomworks — %s  (%s)", ws.name or "?", ws.root))
  out("")
  local profiles = ws._profiles or {}
  local active = ws._active_profile_key
  local ap
  for _, p in ipairs(profiles) do if p.key == active then ap = p end end
  if ap then
    out("  Active profile   " .. ap.key)
    out("    set            " .. (ap._configuration_set_name or "?"))
    out("    tools          " .. table.concat(ap._tool_keys or {}, ", "))
    local builds = {}
    for _, pp in ipairs(ap:projects()) do
      local proj = pp._project
      if proj then
        local t = proj.type or (proj._module and proj._module.id) or "?"
        builds[#builds + 1] = proj.key .. " (" .. t .. ")"
      end
    end
    if #builds > 0 then out("    builds         " .. table.concat(builds, ", ")) end
  elseif #profiles > 0 then
    out("  No active profile — run `lw profile select` to pick one")
  else
    out("  No profiles defined")
  end
  out("")
  if #profiles > 0 then
    out(string.format("  %d profile%s defined · `lw profiles` to list",
      #profiles, #profiles == 1 and "" or "s"))
    out("")
  end
  out("Run `lw help` for commands · `lw help <command>` for details.")
  return 0
end

-- ---------------------------------------------------------------------------
-- Help
-- ---------------------------------------------------------------------------

local HELP = {
  status = [[lw   (no command)

Show workspace status: the active profile, its configuration set, tools,
and the projects it builds.]],
  profiles = [[lw profiles

List the workspace's profiles, marking the active one with `*` and flagging
any that aren't buildable (an unavailable module or an unresolved tool).]],
  build = [[lw build [profile]

Build a profile's projects. With no profile: the active profile (user.json),
else the only profile, else an error listing candidates.

  profile   e.g. Debug:ninja-clang-19  (major pins resolve to the installed
            patch version)

Configures first if the build dir isn't configured, then builds. Non-zero
exit on any failure.]],
  test = [[lw test [profile]   (coming soon)

Build the profile's test target and run it, reporting a real exit code.]],
  init = [[lw init

Initialize the workspace working copy (.nvim/loomworks.user.json). The shared
loomworks.json is written later by `lw publish` (working-copy model). Fails if
the workspace already exists.]],
  publish = [[lw publish

Write the shared loomworks.json from the working copy — the same snapshot the
editor produces on :w. This is the file you commit and that CI reads.]],
  project = [[lw project <add|remove|list>

Manage the workspace's projects in the working copy (.nvim/loomworks.user.json);
`lw publish` shares the result.

  add <path> [type] [name]
        Register an existing directory as a project. The path is inspected to
        detect the type (CMakeLists.txt -> cmake, meson.build -> meson, ...);
        pass <type> to override or when nothing is detected. <name> defaults to
        the directory basename; on a clash you're prompted (or, non-interactive,
        it errors). Missing-and-required args are prompted only on a terminal.
  remove <name>
        Drop a project. <name> is the unique project key (`lw project list`).
  list  Show all projects: key, type, path.]],
  profile = [[lw profile <list|select>

  list      same as `lw profiles`
  select    interactive picker; sets the active profile (writes user.json)

The active profile is the default for `lw build`. `lw build` also accepts a
substring, so `lw build clang-19` works when it's unambiguous.]],
  config = [[lw config <list|get|set|unset> [key] [value]

Read or write lw's user configuration (]] .. config_path() .. [[).

  list                 show all settings and the file path
  get <key>            print one setting
  set <key> <value>    set a setting
  unset <key>          remove a setting

Keys:
  dev-lua   directory to load loomworks Lua from (development override).
            Precedence: LOOMWORKS_LUA env > dev-lua > cache > bundled.]],
}

function M.cmd_help(cmd)
  if cmd and HELP[cmd] then
    out(HELP[cmd])
    return 0
  end
  if cmd then io.stderr:write("lw: no help topic '" .. cmd .. "'\n") end
  out([[lw — loomworks standalone runner

Usage: lw [command] [args]

  (no command)      workspace status + active profile
  init              initialize the workspace working copy
  project <sub>     add | remove | list projects
  profiles          list profiles and their buildability
  profile <sub>     list | select (set the active profile)
  build [profile]   build a profile (configure if needed, then build)
  publish           write loomworks.json from the working copy
  test  [profile]   build and run tests                     (coming)
  config <...>      get/set lw configuration
  help  [command]   this help, or details for a command

`lw help <command>` for details.]])
  return cmd and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function main()
  local a = _G.arg or {}
  local command = a[1]

  -- Global commands — no workspace required.
  if command == "help" or command == "-h" or command == "--help" then
    finish(M.cmd_help(a[2]))
  end
  if command == "config" then
    finish(M.cmd_config(a[2], a[3], a[4]))
  end
  if command == "init" then
    finish(M.cmd_init())
  end

  -- LW_ROOT lets a launcher pass the user's directory when the process itself
  -- runs from elsewhere (the luvi host runs from the bundle dir).
  local root = find_root(os.getenv("LW_ROOT"))

  -- Bare `lw` → status (also fine outside a workspace).
  if not command then
    finish(M.cmd_status(root))
  end

  -- Workspace commands.
  if not root then die("no loomworks.json found (searched up from cwd) — `lw init` to create one") end

  -- `profile` manages its own workspace load (select skips tool detection).
  if command == "profile" then
    finish(M.cmd_profile(a[2], root))
  end
  if command == "publish" then
    finish(M.cmd_publish(root))
  end
  -- `project` manages its own workspace load (no tool detection needed).
  if command == "project" then
    finish(M.cmd_project(a[2], root, a[3], a[4], a[5]))
  end

  local ws = load_workspace(root)
  if command == "profiles" then
    finish(M.cmd_profiles(ws))
  elseif command == "build" then
    finish(M.cmd_build(ws, a[2]))
  else
    die("unknown command '" .. command .. "' — run `lw help`")
  end
end

main()
