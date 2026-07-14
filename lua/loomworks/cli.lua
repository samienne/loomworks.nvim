--- loomworks/cli.lua — headless entry point for the standalone runner.
---
--- Fulfils specification.md §16. v1 hosted under Neovim
--- (`nvim --headless -u NONE -l lua/loomworks/cli.lua <cmd> [args]`); the
--- luvi + shim host is layered on later without changing this file.
---
--- Commands: (status) | init | project <add|remove|list|show> |
---           configuration <list|add|show|get|set|unset|remove> |
---           configuration-set <list|show|create|map|unmap|remove> | profiles |
---           profile <list|select|create> | tools | build [profile] |
---           publish | test [profile] | config <...> | help

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

--- Forced non-interactive mode. Set by main() from `--no-input` /
--- `--non-interactive`, or the LW_NO_INPUT / CI environment. Belt-and-braces
--- over TTY detection: a CI runner can allocate a pseudo-terminal (docker -t,
--- ssh -t, some runners), which reads as a tty even though no human is there —
--- so prompting would block forever. Forcing this makes prompts error with an
--- explicit-argument hint instead.
local force_noninteractive = false

--- May we prompt the user? False when forced non-interactive, or when stdin
--- isn't a terminal (piped / redirected / closed — the common CI case).
local function interactive()
  if force_noninteractive then return false end
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
  -- No profile given. Non-interactive mode deliberately does NOT fall back to
  -- the active/selected profile (or the single-profile shortcut): the active
  -- profile is mutable shared state in user.json that a parallel run or a
  -- committed dev setting could change under a CI build, so we require it
  -- spelled out for a deterministic, contention-free result.
  if not interactive() then
    local keys = {}
    for _, p in ipairs(profiles) do keys[#keys + 1] = p.key end
    table.sort(keys)
    die("no profile specified — non-interactive mode does not use the active profile.\n" ..
      "  pass one explicitly (a unique substring works): lw build <profile>\n" ..
      "  profiles: " .. (next(keys) and table.concat(keys, ", ") or "(none — `lw profile create`)"))
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
-- Shared lookups + small formatting helpers
-- ---------------------------------------------------------------------------

--- Resolve a project by exact key, or die listing the existing ones.
local function resolve_project(ws, name)
  local names = {}
  for _, p in pairs(ws._projects) do
    if p.key == name then return p end
    names[#names + 1] = p.key
  end
  table.sort(names)
  die("no project named '" .. tostring(name) .. "'. Existing: " ..
    (next(names) and table.concat(names, ", ") or "(none)"))
end

--- Resolve a configuration in a project: exact canonical name, else an
--- unambiguous base name. When `require_user`, refuse non-user configs.
local function resolve_config(proj, name, require_user)
  local exact, base_hits = nil, {}
  for _, c in ipairs(proj:get_configurations()) do
    if c.name == name then exact = c end
    if c.base_name == name and c.name ~= name then base_hits[#base_hits + 1] = c end
  end
  local cfg = exact or base_hits[1]
  if not exact and #base_hits > 1 then
    local ns = {}
    for _, c in ipairs(base_hits) do ns[#ns + 1] = c.name end
    die("'" .. name .. "' is ambiguous in '" .. proj.key .. "': " .. table.concat(ns, ", "))
  end
  if not cfg then
    local ns = {}
    for _, c in ipairs(proj:get_configurations()) do ns[#ns + 1] = c.name end
    table.sort(ns)
    die("no configuration '" .. name .. "' in project '" .. proj.key ..
      "'. Have: " .. (next(ns) and table.concat(ns, ", ") or "(none)"))
  end
  if require_user and not cfg.is_user then
    local kind = cfg:is_auto_gen() and "module-generated" or "from a preset"
    die("'" .. cfg.name .. "' is " .. kind ..
      " and can't be edited — create a user configuration that inherits it:\n" ..
      "  lw configuration add " .. proj.key .. " <name> " ..
      (cfg.module_config and cfg.module_config.variant or "") .. "\n" ..
      "  lw configuration set " .. proj.key .. " <name> inherits " .. cfg.name)
  end
  return cfg
end

--- Print a string→string dict, sorted, one `k = v` per line at `indent`.
local function print_dict(indent, d)
  local keys = {}
  for k in pairs(d or {}) do keys[#keys + 1] = k end
  if #keys == 0 then out(indent .. "(none)"); return end
  table.sort(keys)
  for _, k in ipairs(keys) do out(string.format("%s%s = %s", indent, k, tostring(d[k]))) end
end

--- Split a comma-separated list, trimming whitespace; drops empty entries.
local function split_csv(s)
  local list = {}
  for item in tostring(s):gmatch("[^,]+") do
    local t = item:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then list[#list + 1] = t end
  end
  return list
end

-- ---------------------------------------------------------------------------
-- Projects (add / remove / list / show) — explicit management, user.json (§16.9)
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
  if not interactive() then
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
  if not interactive() then
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

--- Configuration sets that map a configuration for `proj`, as
--- `{ set = <name>, config = <config name> }` rows.
local function config_set_rows(ws, proj)
  local rows = {}
  for _, cs in ipairs(ws._config_sets or {}) do
    local mapped = cs.mappings and cs.mappings[proj]
    if mapped then rows[#rows + 1] = { set = cs.name, config = mapped.name } end
  end
  table.sort(rows, function(a, b) return a.set < b.set end)
  return rows
end

--- `lw project show <name>` — project detail: type, path, configurations, and
--- the configuration sets that map it.
function M.cmd_project_show(root, name)
  if not name then die("usage: lw project show <name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, name)
  local t = proj.type or (proj._module and proj._module.id) or "?"
  out(string.format("%s  (%s)", proj.key, t))
  out("  path            " .. (proj.path or "."))
  if proj._intent then out("  intent          " .. proj._intent) end

  local cfgs = proj:get_configurations()
  table.sort(cfgs, function(a, b) return a.name < b.name end)
  out("")
  out("  Configurations:")
  if #cfgs == 0 then
    out("    (none)")
  else
    for _, c in ipairs(cfgs) do
      local kind = c.is_user and "user" or (c:is_auto_gen() and "auto" or "preset")
      local variant = c.module_config and c.module_config.variant
      out(string.format("    %-22s %-7s%s", c.name, kind,
        variant and ("  variant=" .. variant) or (c:is_abstract() and "  (abstract)" or "")))
    end
  end

  local rows = config_set_rows(ws, proj)
  out("")
  out("  Configuration sets:")
  if #rows == 0 then
    out("    (not mapped in any set — map it to build)")
  else
    for _, r in ipairs(rows) do out(string.format("    %-22s -> %s", r.set, r.config)) end
  end
  return 0
end

--- `lw project <add|remove|list|show>`
function M.cmd_project(sub, root, a3, a4, a5)
  if sub == "add" then return M.cmd_project_add(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_project_remove(root, a3) end
  if sub == "show" then return M.cmd_project_show(root, a3) end
  if sub == nil or sub == "list" then return M.cmd_project_list(root) end
  die("unknown project subcommand '" .. tostring(sub) .. "' — use add|remove|list|show")
end

-- ---------------------------------------------------------------------------
-- Configurations (list / add / show / get / set / unset / remove)
-- ---------------------------------------------------------------------------

--- Reconstruct the user-override data table (save_configuration's input shape)
--- from a live Configuration, so set/unset can read-modify-write.
local function config_to_data(cfg)
  local data = {}
  for k, v in pairs(cfg.module_config or {}) do data[k] = v end
  if cfg.inherits_names and #cfg.inherits_names > 0 then
    data.inherits = (#cfg.inherits_names == 1) and cfg.inherits_names[1]
        or vim.deepcopy(cfg.inherits_names)
  end
  if cfg.options and next(cfg.options) then data.options = vim.deepcopy(cfg.options) end
  if cfg.variables and next(cfg.variables) then data.variables = vim.deepcopy(cfg.variables) end
  if cfg.languages and #cfg.languages > 0 then data.languages = vim.deepcopy(cfg.languages) end
  if cfg.role then data.role = cfg.role end
  return data
end

--- Apply one `param`/`value` to a config data table (value nil clears). Param
--- namespaces: options.<KEY>, variables.<NAME>, inherits, languages (CSV), and
--- any other bare name → module field.
local function apply_param(data, param, value)
  if param == "options" or param == "variables" then
    die("specify a key: " .. param .. ".<KEY>")
  end
  local dictname, key = param:match("^(options)%.(.+)$")
  if not dictname then dictname, key = param:match("^(variables)%.(.+)$") end
  if dictname then
    data[dictname] = data[dictname] or {}
    data[dictname][key] = value
    if not next(data[dictname]) then data[dictname] = nil end
  elseif param == "inherits" then
    if not value or value == "" then
      data.inherits = nil
    else
      local list = split_csv(value)
      data.inherits = (#list == 1) and list[1] or list
    end
  elseif param == "languages" then
    -- empty clears the override → inherit languages from the module
    data.languages = (value and value ~= "") and split_csv(value) or nil
  else
    data[param] = value -- module field (variant, toolchain, generator, ...)
  end
end

--- Read one `param` off a Configuration. Returns a string, a dict, or nil.
local function get_param(cfg, param)
  if param == "inherits" then
    return (cfg.inherits_names and #cfg.inherits_names > 0)
        and table.concat(cfg.inherits_names, ",") or nil
  elseif param == "languages" then
    return (cfg.languages and #cfg.languages > 0) and table.concat(cfg.languages, ",") or nil
  elseif param == "options" or param == "variables" then
    return cfg[param]
  end
  local key = param:match("^options%.(.+)$")
  if key then return cfg.options and cfg.options[key] end
  key = param:match("^variables%.(.+)$")
  if key then return cfg.variables and cfg.variables[key] end
  return cfg.module_config and cfg.module_config[param]
end

--- `lw configuration list [project]` — configs for one project, or all.
function M.cmd_configuration_list(root, proj_name)
  local ws = load_workspace(root, false)
  local projs = {}
  if proj_name then
    projs = { resolve_project(ws, proj_name) }
  else
    for _, p in ipairs(ws._projects or {}) do projs[#projs + 1] = p end
    table.sort(projs, function(a, b) return a.key < b.key end)
  end
  if #projs == 0 then out("(no projects)"); return 0 end
  for _, proj in ipairs(projs) do
    if not proj_name then out(proj.key .. ":") end
    local cfgs = proj:get_configurations()
    table.sort(cfgs, function(a, b) return a.name < b.name end)
    local pad = proj_name and "  " or "    "
    if #cfgs == 0 then
      out(pad .. "(none)")
    else
      for _, c in ipairs(cfgs) do
        local kind = c.is_user and "user" or (c:is_auto_gen() and "auto" or "preset")
        local variant = c.module_config and c.module_config.variant
        out(string.format("%s%-22s %-7s%s", pad, c.name, kind,
          variant and ("  variant=" .. variant) or ""))
      end
    end
  end
  return 0
end

--- `lw configuration add <project> <name> [variant]`
function M.cmd_configuration_add(root, proj_name, name, variant)
  if not proj_name or not name then
    die("usage: lw configuration add <project> <name> [variant]")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local data = {}
  if variant then data.variant = variant end
  local ok, err = proj:save_configuration(name, data)
  if not ok then die("could not add configuration: " .. tostring(err)) end
  out(string.format("added configuration '%s' to project '%s'%s", name, proj.key,
    variant and ("  (variant " .. variant .. ")") or ""))
  if not variant then
    out("  no variant set — it is abstract (a mixin) until you set one:")
    out("    lw configuration set " .. proj.key .. " " .. name .. " variant <name>")
  end
  out("  map it into a configuration set to build it; `lw publish` to share.")
  return 0
end

--- `lw configuration show <project> <name>`
function M.cmd_configuration_show(root, proj_name, cfg_name)
  if not proj_name or not cfg_name then die("usage: lw configuration show <project> <name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, false)
  local kind = cfg.is_user and "user" or (cfg:is_auto_gen() and "module-generated" or "preset")
  out(string.format("%s / %s", proj.key, cfg.name))
  out("  kind            " .. kind .. (cfg._source_missing and "  (source missing)" or ""))
  if cfg._intent then out("  intent          " .. cfg._intent) end
  local variant = cfg.module_config and cfg.module_config.variant
  out("  variant         " .. (variant or (cfg:is_abstract() and "(abstract / mixin)" or "-")))
  if cfg.inherits_names and #cfg.inherits_names > 0 then
    out("  inherits        " .. table.concat(cfg.inherits_names, ", "))
    local unresolved = cfg:unresolved_inherits_names()
    if #unresolved > 0 then out("    unresolved    " .. table.concat(unresolved, ", ")) end
  end
  out("  languages       " .. (function()
    local eff = cfg:effective_languages()
    local base = (#eff > 0) and table.concat(eff, ", ") or "(none)"
    return base .. ((cfg.languages and #cfg.languages > 0) and "" or "  (inherited)")
  end)())
  -- Other module fields beyond variant.
  local extra = {}
  for k, v in pairs(cfg.module_config or {}) do
    if k ~= "variant" then extra[k] = v end
  end
  if next(extra) then out("  module fields:"); print_dict("    ", extra) end
  if cfg.options and next(cfg.options) then out("  options:"); print_dict("    ", cfg.options) end
  if cfg.variables and next(cfg.variables) then out("  variables:"); print_dict("    ", cfg.variables) end
  local ok, reasons = cfg:is_valid()
  if not ok then out("  invalid: " .. table.concat(reasons, "; ")) end
  local rows = config_set_rows(ws, proj)
  local using = {}
  for _, r in ipairs(rows) do if r.config == cfg.name then using[#using + 1] = r.set end end
  if #using > 0 then out("  used by sets    " .. table.concat(using, ", ")) end
  return 0
end

--- `lw configuration get <project> <name> <param>`
function M.cmd_configuration_get(root, proj_name, cfg_name, param)
  if not (proj_name and cfg_name and param) then
    die("usage: lw configuration get <project> <name> <param>")
  end
  local ws = load_workspace(root, false)
  local cfg = resolve_config(resolve_project(ws, proj_name), cfg_name, false)
  local v = get_param(cfg, param)
  if v == nil then
    out("(unset)")
  elseif type(v) == "table" then
    print_dict("  ", v)
  else
    out(tostring(v))
  end
  return 0
end

--- Shared read-modify-write for set/unset.
local function edit_configuration(root, proj_name, cfg_name, param, value, verb)
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, true)
  local data = config_to_data(cfg)
  apply_param(data, param, value)
  local ok, err = proj:save_configuration(cfg.name, data)
  if not ok then die("could not " .. verb .. ": " .. tostring(err)) end
  if verb == "set" then
    out(string.format("%s/%s: set %s = %s", proj.key, cfg.name, param, value))
  else
    out(string.format("%s/%s: unset %s", proj.key, cfg.name, param))
  end
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw configuration set <project> <name> <param> <value>`
function M.cmd_configuration_set(root, proj_name, cfg_name, param, value)
  if not (proj_name and cfg_name and param) or value == nil then
    die("usage: lw configuration set <project> <name> <param> <value>\n" ..
      "  (use `lw configuration unset` to clear a value)")
  end
  return edit_configuration(root, proj_name, cfg_name, param, value, "set")
end

--- `lw configuration unset <project> <name> <param>`
function M.cmd_configuration_unset(root, proj_name, cfg_name, param)
  if not (proj_name and cfg_name and param) then
    die("usage: lw configuration unset <project> <name> <param>")
  end
  return edit_configuration(root, proj_name, cfg_name, param, nil, "unset")
end

--- `lw configuration remove <project> <name>`
function M.cmd_configuration_remove(root, proj_name, cfg_name)
  if not proj_name or not cfg_name then
    die("usage: lw configuration remove <project> <name>")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, true)
  local ok, err = proj:delete_configuration(cfg.name)
  if not ok then die("could not remove configuration: " .. tostring(err)) end
  out(string.format("removed configuration '%s' from project '%s'", cfg.name, proj.key))
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw configuration <list|add|show|get|set|unset|remove>`
function M.cmd_configuration(sub, root, a3, a4, a5, a6)
  if sub == nil or sub == "list" then return M.cmd_configuration_list(root, a3) end
  if sub == "add" then return M.cmd_configuration_add(root, a3, a4, a5) end
  if sub == "show" then return M.cmd_configuration_show(root, a3, a4) end
  if sub == "get" then return M.cmd_configuration_get(root, a3, a4, a5) end
  if sub == "set" then return M.cmd_configuration_set(root, a3, a4, a5, a6) end
  if sub == "unset" then return M.cmd_configuration_unset(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_configuration_remove(root, a3, a4) end
  die("unknown configuration subcommand '" .. tostring(sub) ..
    "' — use list|add|show|get|set|unset|remove")
end

-- ---------------------------------------------------------------------------
-- Configuration sets (list / show / create / map / unmap / remove)
-- ---------------------------------------------------------------------------

--- Resolve a configuration set by name, or die listing the existing ones.
local function resolve_config_set(ws, name)
  local names = {}
  for _, cs in ipairs(ws._config_sets or {}) do
    if cs.name == name then return cs end
    names[#names + 1] = cs.name
  end
  table.sort(names)
  die("no configuration set '" .. tostring(name) .. "'. Existing: " ..
    (next(names) and table.concat(names, ", ") or "(none)"))
end

--- Profiles that reference `cs` by name.
local function profiles_using_set(ws, cs)
  local using = {}
  for _, p in pairs(ws._profiles or {}) do
    if p._configuration_set_name == cs.name then using[#using + 1] = p.key end
  end
  table.sort(using)
  return using
end

--- `lw configuration-set list` — all sets with their mappings.
function M.cmd_cset_list(root)
  local ws = load_workspace(root, false)
  local sets = {}
  for _, cs in ipairs(ws._config_sets or {}) do sets[#sets + 1] = cs end
  if #sets == 0 then out("(no configuration sets)"); return 0 end
  table.sort(sets, function(a, b) return a.name < b.name end)
  for _, cs in ipairs(sets) do
    local rows = {}
    for project, cfg in pairs(cs.mappings or {}) do rows[#rows + 1] = project.key .. "→" .. cfg.name end
    table.sort(rows)
    out(string.format("  %-16s %s", cs.name, next(rows) and table.concat(rows, ", ") or "(empty)"))
  end
  return 0
end

--- `lw configuration-set show <name>`
function M.cmd_cset_show(root, name)
  if not name then die("usage: lw configuration-set show <name>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  out(cs.name)
  if cs._intent then out("  intent          " .. cs._intent) end
  out("  Mappings:")
  local rows = {}
  for project, cfg in pairs(cs.mappings or {}) do
    rows[#rows + 1] = { p = project.key, c = cfg.name, stale = (cfg._source_missing or cfg._removed) }
  end
  table.sort(rows, function(a, b) return a.p < b.p end)
  if #rows == 0 then
    out("    (empty — add with `lw configuration-set map " .. cs.name .. " <project> <config>`)")
  else
    for _, r in ipairs(rows) do
      out(string.format("    %-20s -> %s%s", r.p, r.c, r.stale and "   (stale)" or ""))
    end
  end
  local ok, reasons = cs:is_valid()
  if not ok then out("  invalid: " .. table.concat(reasons, "; ")) end
  local using = profiles_using_set(ws, cs)
  if #using > 0 then out("  used by profiles " .. table.concat(using, ", ")) end
  return 0
end

--- Parse and validate a `project=config` mapping spec against the workspace.
--- @return string project_key, string config_name (canonical)
local function parse_mapping(ws, spec)
  local pk, cfgname = spec:match("^([^=]+)=(.+)$")
  if not pk then die("bad mapping '" .. spec .. "' — use project=config") end
  local project = resolve_project(ws, pk)
  local cfg = resolve_config(project, cfgname, false)
  return project.key, cfg.name
end

--- `lw configuration-set create <name> [project=config ...]`
function M.cmd_cset_create(root, args)
  local name = args[3]
  if not name then die("usage: lw configuration-set create <name> [project=config ...]") end
  local ws = load_workspace(root, false)
  local raw = {}
  for i = 4, #args do
    local pk, cfgname = parse_mapping(ws, args[i])
    raw[pk] = cfgname
  end
  local cs, err = ws:add_configuration_set(name, raw)
  if not cs then die("could not create configuration set: " .. tostring(err)) end
  out("created configuration set '" .. cs.name .. "'" ..
    (next(raw) and "" or " (empty)"))
  if not next(raw) then
    out("  add mappings: lw configuration-set map " .. cs.name .. " <project> <config>")
  end
  out("`lw publish` to share it; `lw profile create " .. cs.name .. " <tool>` to build it.")
  return 0
end

--- `lw configuration-set map <name> <project> <config>`
function M.cmd_cset_map(root, name, pk, cfgname)
  if not (name and pk and cfgname) then
    die("usage: lw configuration-set map <name> <project> <config>")
  end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local project = resolve_project(ws, pk)
  local cfg = resolve_config(project, cfgname, false)
  local ok, err = cs:update_mapping(project, cfg)
  if not ok then die("could not map: " .. tostring(err)) end
  out(string.format("%s: %s -> %s", cs.name, project.key, cfg.name))
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw configuration-set unmap <name> <project>`
function M.cmd_cset_unmap(root, name, pk)
  if not (name and pk) then die("usage: lw configuration-set unmap <name> <project>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local project = resolve_project(ws, pk)
  if not cs.mappings[project] then die("'" .. pk .. "' is not mapped in '" .. cs.name .. "'") end
  local ok, err = cs:update_mapping(project, nil)
  if not ok then die("could not unmap: " .. tostring(err)) end
  out(cs.name .. ": removed mapping for " .. project.key)
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw configuration-set remove <name>`
function M.cmd_cset_remove(root, name)
  if not name then die("usage: lw configuration-set remove <name>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local using = profiles_using_set(ws, cs)
  local ok, err = ws:remove_configuration_set(cs)
  if not ok then die("could not remove configuration set: " .. tostring(err)) end
  out("removed configuration set '" .. cs.name .. "'")
  if #using > 0 then
    out("  note: these profiles now reference a missing set: " .. table.concat(using, ", "))
  end
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw configuration-set <list|show|create|map|unmap|remove>` (alias: cs)
function M.cmd_cset(sub, root, args)
  if sub == nil or sub == "list" then return M.cmd_cset_list(root) end
  if sub == "show" then return M.cmd_cset_show(root, args[3]) end
  if sub == "create" then return M.cmd_cset_create(root, args) end
  if sub == "map" then return M.cmd_cset_map(root, args[3], args[4], args[5]) end
  if sub == "unmap" then return M.cmd_cset_unmap(root, args[3], args[4]) end
  if sub == "remove" or sub == "rm" then return M.cmd_cset_remove(root, args[3]) end
  die("unknown configuration-set subcommand '" .. tostring(sub) ..
    "' — use list|show|create|map|unmap|remove")
end

--- `lw profile select` — interactive picker that sets the active profile.
--- Writes user.json (explicit management, spec §16.9).
function M.select_profile(ws)
  local profiles = ws._profiles or {}
  if #profiles == 0 then die("no profiles to select — run `lw profiles`") end
  if not interactive() then
    local keys = {}
    for _, p in ipairs(profiles) do keys[#keys + 1] = p.key end
    die("`lw profile select` needs an interactive terminal.\n" ..
      "  set the active profile with `lw profile create <set> <tool> --activate`, or\n" ..
      "  build a specific profile with `lw build <profile>`.\n" ..
      "  profiles: " .. table.concat(keys, ", "))
  end
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

--- Resolve a config set by name, or materialize an auto-detected candidate of
--- that name (so `create` works from a fresh init with no set command yet).
local function resolve_or_materialize_set(ws, name)
  for _, cs in ipairs(ws._config_sets or {}) do
    if cs.name == name then return cs, false end
  end
  local auto = ws:generate_default_config_sets()
  if auto and auto[name] then
    local cs, err = ws:add_configuration_set(name, auto[name])
    if not cs then die("could not create configuration set '" .. name .. "': " .. tostring(err)) end
    return cs, true
  end
  local existing, autos = {}, {}
  for _, cs in ipairs(ws._config_sets or {}) do existing[#existing + 1] = cs.name end
  for n in pairs(auto or {}) do autos[#autos + 1] = n end
  table.sort(existing); table.sort(autos)
  die("no configuration set '" .. name .. "'.\n" ..
    "  existing: " .. (next(existing) and table.concat(existing, ", ") or "(none)") .. "\n" ..
    "  auto-detected: " .. (next(autos) and table.concat(autos, ", ") or "(none)"))
end

--- Sorted list of a module's tool keys, for error/pick messages.
local function tool_keys_of(mod)
  local keys = {}
  for _, t in ipairs(mod:tools()) do keys[#keys + 1] = t.key or "(default)" end
  table.sort(keys)
  return keys
end

--- Pick a toolchain for `mod`. `qualify` true prints the module: prefix in the
--- non-interactive hint (multiple keyed modules in the set).
local function pick_tool(mod, qualify)
  local tools = mod:tools()
  table.sort(tools, function(a, b) return (a.key or "") < (b.key or "") end)
  if #tools == 0 then die("no " .. mod.id .. " toolchains detected — install one, then retry") end
  if not interactive() then
    die("no " .. mod.id .. " toolchain specified — pass one:\n  lw profile create <set> " ..
      (qualify and (mod.id .. ":") or "") .. "<tool>   (available: " ..
      table.concat(tool_keys_of(mod), ", ") .. ")")
  end
  out("Select a " .. mod.id .. " toolchain:")
  for i, t in ipairs(tools) do
    out(string.format("  %d) %s%s", i, t.key or "(default)", t.label and ("   " .. t.label) or ""))
  end
  out("")
  local line = prompt_line("Enter number (blank to cancel)")
  if not line or line == "" then out("cancelled"); finish(0) end
  local n = tonumber(line)
  if not n or not tools[n] then die("invalid selection: " .. tostring(line)) end
  return tools[n]
end

--- `lw profile create <config-set> [tool ...] [--activate]` — synthesize a
--- profile (config set + toolchains) in the working copy.
function M.cmd_profile_create(root, args)
  local set_name = args[3]
  if not set_name then
    die("usage: lw profile create <config-set> [tool ...] [--activate]")
  end
  local activate, tool_specs = false, {}
  for i = 4, #args do
    local a = args[i]
    if a == "--activate" or a == "-a" then activate = true
    else tool_specs[#tool_specs + 1] = a end
  end

  local ws = load_workspace(root) -- wait for tool detection (needed to resolve tools)
  local cs, materialized = resolve_or_materialize_set(ws, set_name)
  if materialized then out("materialized auto-detected configuration set '" .. cs.name .. "'") end

  -- Distinct keyed-tool module types the set's projects require.
  local keyed, order = {}, {}
  for project in pairs(cs.mappings or {}) do
    local mod = project._module
    if mod and mod.has_keyed_tools and not keyed[mod.id] then
      keyed[mod.id] = mod
      order[#order + 1] = mod.id
    end
  end
  table.sort(order)

  -- Parse tool specs into module-qualified (module:key) and bare keys.
  local by_mod, bare = {}, {}
  for _, spec in ipairs(tool_specs) do
    local m, k = spec:match("^([^:]+):(.+)$")
    if m then by_mod[m] = k else bare[#bare + 1] = spec end
  end
  if #order > 1 and #bare > 0 then
    die("this set needs multiple toolchains (" .. table.concat(order, ", ") ..
      ") — qualify each: e.g. " .. order[1] .. ":<tool>")
  end
  if #bare > 1 then die("too many toolchains for one module — pass a single tool key") end

  -- Resolve one Tool per required keyed module.
  local resolved = {}
  for _, mtype in ipairs(order) do
    local mod = keyed[mtype]
    local key = by_mod[mtype] or (#order == 1 and bare[1]) or nil
    local tool
    if key then
      tool = mod:find_tool(key)
      if not tool then
        die("no " .. mtype .. " toolchain matching '" .. key .. "'. Available: " ..
          table.concat(tool_keys_of(mod), ", "))
      end
    else
      tool = pick_tool(mod, #order > 1)
    end
    resolved[mtype] = tool
  end

  -- Build the profile: first tool via ensure_profile, the rest via add_tool.
  local first_entry
  if order[1] then
    local t = resolved[order[1]]
    first_entry = { tool_key = t.key, tool_data = t.data, tool_label = t.label, tool_mod_type = order[1] }
  end
  local existed = cs:find_profile(first_entry) ~= nil
  local profile = cs:ensure_profile(first_entry)
  if not profile then die("failed to create profile for set '" .. cs.name .. "'") end
  for i = 2, #order do profile:add_tool(resolved[order[i]].key) end
  profile._intent = "local"
  if activate then profile:activate() else ws:_save_user() end

  out((existed and "profile already exists: " or "created profile: ") .. profile.key ..
    (activate and "  (active)" or ""))
  local ok, reasons = true, nil
  if profile.is_valid then ok, reasons = profile:is_valid() end
  if not ok then out("  not yet buildable: " .. table.concat(reasons or {}, "; ")) end
  out("`lw publish` to share it" .. (activate and "" or "; `lw profile select` or --activate to activate") .. ".")
  return 0
end

--- `lw profile <list|select|create>`
function M.cmd_profile(sub, root, args)
  if sub == "select" then
    return M.select_profile(load_workspace(root, false))
  end
  if sub == "create" then
    return M.cmd_profile_create(root, args)
  end
  if sub == nil or sub == "list" then
    return M.cmd_profiles(load_workspace(root))
  end
  die("unknown profile subcommand '" .. tostring(sub) .. "' — use list|select|create")
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

--- Truncate `s` to about `w` columns with an ellipsis. Byte-approximate —
--- fine for the ASCII-ish content on the status page.
local function trunc(s, w)
  s = tostring(s)
  if #s <= w then return s end
  return s:sub(1, math.max(1, w - 1)) .. "…"
end

--- Print a capped section: a blank line, "Title (N)", up to `max` rows via
--- `row_fn`, then a "+K more · <more_hint>" line when the list was truncated,
--- and always a short `help` line (how to add — doubles as the empty-state
--- hint, like the active-profile line shows with no profiles).
local function status_section(title, items, max, row_fn, more_hint, help)
  out("")
  out(string.format("%s (%d)", title, #items))
  if #items == 0 then out("  " .. help); return end
  local shown = math.min(#items, max)
  for i = 1, shown do out(row_fn(items[i])) end
  if #items > shown then
    out(string.format("  +%d more · %s", #items - shown, more_hint))
  end
  out("  " .. help)
end

--- `lw status` (also bare `lw`) — one-screen workspace overview. Works outside
--- a workspace too. Every section is capped to keep it to a single page.
function M.cmd_status(root)
  if not root then
    out("loomworks — no workspace here (no loomworks.json / .nvim/loomworks.user.json)")
    out("")
    out("Run `lw init` to start one, or `lw help` for commands.")
    return 0
  end
  local ws = load_workspace(root, false) -- pinned info only; skip tool detection
  out(string.format("loomworks — %s  (%s)", ws.name or "?", ws.root))

  local MAX = 6
  local profiles = ws._profiles or {}
  local active_key = ws._active_profile_key
  local ap
  for _, p in ipairs(profiles) do if p.key == active_key then ap = p end end

  out("")
  if ap then
    out("Active profile   " .. trunc(ap.key, 44) ..
      "   (set " .. (ap._configuration_set_name or "?") .. ")")
  elseif #profiles > 0 then
    out("Active profile   (none) — `lw profile select`")
  else
    out("Active profile   (no profiles) — `lw profile create <set> <tool>`")
  end

  -- Profiles: active first (so it's always visible under the cap), then the
  -- rest by key; active marked with `*`.
  local plist = {}
  if ap then plist[#plist + 1] = ap end
  local rest = {}
  for _, p in ipairs(profiles) do if p ~= ap then rest[#rest + 1] = p end end
  table.sort(rest, function(a, b) return a.key < b.key end)
  for _, p in ipairs(rest) do plist[#plist + 1] = p end
  status_section("Profiles", plist, MAX, function(p)
    local mark = (p.key == active_key) and "*" or " "
    return string.format(" %s %-38s set=%s", mark, trunc(p.key, 38),
      trunc(p._configuration_set_name or "?", 22))
  end, "lw profiles", "create a profile · lw profile create <set> <tool>")

  -- Configuration sets: name + compact mappings.
  local sets = {}
  for _, cs in ipairs(ws._config_sets or {}) do sets[#sets + 1] = cs end
  table.sort(sets, function(a, b) return a.name < b.name end)
  status_section("Configuration sets", sets, MAX, function(cs)
    local rows = {}
    for project, cfg in pairs(cs.mappings or {}) do rows[#rows + 1] = project.key .. "→" .. cfg.name end
    table.sort(rows)
    return string.format("  %-14s %s", trunc(cs.name, 14),
      trunc(next(rows) and table.concat(rows, ", ") or "(empty)", 56))
  end, "lw cs list", "create a set · lw configuration-set create <name> [project=config …]")

  -- Projects with their configurations (first few names, then +K).
  local projs = {}
  for _, p in ipairs(ws._projects or {}) do projs[#projs + 1] = p end
  table.sort(projs, function(a, b) return a.key < b.key end)
  status_section("Projects", projs, MAX, function(p)
    local t = p.type or (p._module and p._module.id) or "?"
    local names = {}
    for _, c in ipairs(p:get_configurations()) do names[#names + 1] = c.name end
    table.sort(names)
    local head = {}
    for i = 1, math.min(#names, 3) do head[#head + 1] = names[i] end
    local cfgstr = (#names == 0) and "(no configs)" or table.concat(head, ", ")
    if #names > 3 then cfgstr = cfgstr .. " +" .. (#names - 3) end
    return string.format("  %-14s %-6s %s", trunc(p.key, 14), t, trunc(cfgstr, 50))
  end, "lw project list", "add a project · lw project add <path> [type]")

  out("")
  out("`lw help` for commands · `lw help <command>` for details.")
  return 0
end

--- `lw tools` — list detected toolchains, grouped by module. Tools are scanned
--- per workspace module, so a module only appears once a project uses it.
function M.cmd_tools(root)
  local ws = load_workspace(root) -- wait for tool detection
  local mods = {}
  for _, m in pairs(ws._modules or {}) do mods[#mods + 1] = m end
  table.sort(mods, function(a, b) return a.id < b.id end)
  if #mods == 0 then
    out("(no modules yet — add a project first: lw project add <path> [type])")
    return 0
  end
  for _, mod in ipairs(mods) do
    out(mod.id .. (mod.has_keyed_tools and "" or "   (single default toolchain)"))
    local tools = mod:tools()
    table.sort(tools, function(a, b) return (a.key or "") < (b.key or "") end)
    if #tools == 0 then
      out("  (none detected)")
    else
      for _, t in ipairs(tools) do
        local langs = (t.languages and #t.languages > 0)
            and ("  [" .. table.concat(t.languages, ", ") .. "]") or ""
        local label = t.label and ("   " .. t.label) or ""
        out(string.format("  %-26s%s%s", t.key or "(default)", label, langs))
      end
    end
    out("")
  end
  out("Pin a tool in a profile: lw profile create <set> <tool>  (version prefixes match)")
  return 0
end

-- ---------------------------------------------------------------------------
-- Help
-- ---------------------------------------------------------------------------

local HELP = {
  status = [[lw status   (also: bare `lw`)

One-screen workspace overview: the active profile, then capped lists of
profiles (active marked `*`), configuration sets, and projects with their
configurations. Each section is limited to fit a page — use `lw profiles`,
`lw cs list`, or `lw project list` for the full lists.]],
  profiles = [[lw profiles

List the workspace's profiles, marking the active one with `*` and flagging
any that aren't buildable (an unavailable module or an unresolved tool).]],
  tools = [[lw tools

List the toolchains detected on this machine, grouped by module (cmake,
meson, …). Each row is a tool key, its label, and the languages it provides.
Tools are scanned per workspace module, so a module only appears once a
project uses it. Pin one in a profile with `lw profile create <set> <tool>`;
version prefixes match (ninja-clang-19 -> ninja-clang-19.1.5).]],
  build = [[lw build [profile]

Build a profile's projects. Interactively, with no profile given, it uses the
active profile (user.json), else the only profile, else errors. In
non-interactive mode (--no-input / LW_NO_INPUT / CI, or piped stdin) the active
profile is NOT used — pass the profile explicitly for a deterministic build.

  profile   e.g. Debug:ninja-clang-19  (a unique substring works too; major
            pins resolve to the installed patch version)

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
  project = [[lw project <add|remove|list|show>

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
  list  Show all projects: key, type, path.
  show <name>
        Detail one project: type, path, its configurations, and the
        configuration sets that map it.]],
  configuration = [[lw configuration <list|add|show|get|set|unset|remove>   (alias: cfg)

Manage a project's build configurations in the working copy; `lw publish`
shares the result. Configs are addressed by name (an unambiguous base name
works too). set/unset/remove act on user configs only.

  list [project]                     configs for one project, or all
  add <project> <name> [variant]     create a user configuration
  show <project> <name>              detail: variant, inherits, options, ...
  get <project> <name> <param>       print one value
  set <project> <name> <param> <value>
  unset <project> <name> <param>     clear one value
  remove <project> <name>            delete a user configuration

Params for get/set/unset:
  variant            the module variant (cmake/meson: Debug, Release, ...)
  inherits           comma-separated base configs (a mixin chain)
  languages          comma-separated; empty inherits from the module
  options.<KEY>      a generic build option
  variables.<NAME>   a project variable override
  <other>            any module-specific field (e.g. toolchain, generator)]],
  ["configuration-set"] = [[lw configuration-set <list|show|create|map|unmap|remove>   (alias: cs)

A configuration set maps each project to one of its configurations — the
cross-project selection a profile builds. Managed in the working copy;
`lw publish` shares it.

  list                                all sets and their mappings
  show <name>                         one set: mappings, validity, profiles
  create <name> [project=config ...]  create a set (optionally with mappings)
  map <name> <project> <config>       set/replace one project's mapping
  unmap <name> <project>              drop a project's mapping
  remove <name>                       delete the set

<config> is a configuration name (an unambiguous base name works, so `Debug`
resolves `variant:Debug`). Build a set with `lw profile create <name> <tool>`.]],
  profile = [[lw profile <list|select|create>

  list      same as `lw profiles`
  select    interactive picker; sets the active profile (writes user.json)
  create <config-set> [tool ...] [--activate]
            Create a profile (a config set + toolchains) in the working copy.
            If <config-set> doesn't exist but is auto-detectable, it's
            materialized first. Each [tool] is a tool key (version prefixes
            match, e.g. ninja-clang-19) or module:key when the set spans
            several toolchains (cmake:..., meson:...). A required toolchain
            left unspecified is prompted on a terminal (errors otherwise).
            The profile key is derived from the set + tools. --activate also
            makes it active.

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
  -- Normalize command aliases to their canonical help topic.
  local alias = { cs = "configuration-set", cfg = "configuration" }
  cmd = cmd and (alias[cmd] or cmd) or nil
  if cmd and HELP[cmd] then
    out(HELP[cmd])
    return 0
  end
  if cmd then io.stderr:write("lw: no help topic '" .. cmd .. "'\n") end
  out([[lw — loomworks standalone runner

Usage: lw [command] [args]

  (no command)      workspace status + active profile
  init              initialize the workspace working copy
  project <sub>     add | remove | list | show projects
  configuration     add | set | get | show | ... project configurations
  configuration-set create | map | show | ... sets  (cs)
  profiles          list profiles and their buildability
  profile <sub>     list | select | create profiles
  tools             list detected toolchains by module
  build [profile]   build a profile (configure if needed, then build)
  publish           write loomworks.json from the working copy
  test  [profile]   build and run tests                     (coming)
  config <...>      get/set lw configuration
  help  [command]   this help, or details for a command

Global: --no-input (alias --non-interactive) never prompts — a missing
required value errors instead of waiting. Also enabled by LW_NO_INPUT or CI.
Otherwise prompting is on only when stdin is a terminal. In non-interactive
mode `lw build` also ignores the active profile — pass the profile explicitly.

`lw help <command>` for details.]])
  return cmd and 1 or 0
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

--- True for env values that mean "yes/on" (present + not an explicit false).
local function env_truthy(name)
  local v = os.getenv(name)
  return v ~= nil and v ~= "" and v ~= "0" and v:lower() ~= "false"
end

local function main()
  -- Non-interactive control (CI-safe): strip the global `--no-input` /
  -- `--non-interactive` flags from anywhere in the args, and honor the
  -- LW_NO_INPUT and conventional CI environment variables. Any of these makes
  -- prompts error with an explicit-argument hint instead of blocking.
  local a = {}
  for _, v in ipairs(_G.arg or {}) do
    if v == "--no-input" or v == "--non-interactive" then
      force_noninteractive = true
    else
      a[#a + 1] = v
    end
  end
  if env_truthy("LW_NO_INPUT") or env_truthy("CI") then
    force_noninteractive = true
  end

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

  -- Bare `lw` and `lw status` → status (also fine outside a workspace).
  if not command or command == "status" then
    finish(M.cmd_status(root))
  end

  -- Workspace commands.
  if not root then die("no loomworks.json found (searched up from cwd) — `lw init` to create one") end

  -- `profile` manages its own workspace load (select skips tool detection).
  if command == "profile" then
    finish(M.cmd_profile(a[2], root, a))
  end
  if command == "publish" then
    finish(M.cmd_publish(root))
  end
  -- `project` / `configuration` manage their own workspace load (no tools).
  if command == "project" then
    finish(M.cmd_project(a[2], root, a[3], a[4], a[5]))
  end
  if command == "configuration" or command == "cfg" then
    finish(M.cmd_configuration(a[2], root, a[3], a[4], a[5], a[6]))
  end
  if command == "configuration-set" or command == "cs" then
    finish(M.cmd_cset(a[2], root, a))
  end

  if command == "tools" then
    finish(M.cmd_tools(root))
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
