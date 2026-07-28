--- loomworks/cli.lua — headless entry point for the standalone runner.
---
--- Hosted under Neovim
--- (`nvim --headless -u NONE -l lua/loomworks/cli.lua <cmd> [args]`); the
--- luvi + shim host is layered on later without changing this file.
---
--- Commands: (status) | init | workspace <rename> |
---           project <add|remove|rename|list|show> |
---           configuration <list|add|show|get|set|unset|remove> |
---           configuration-set <list|show|create|map|unmap|remove> | profiles |
---           profile <list|select|create|remove|publish|target|query> |
---           tools | build [profile] |
---           clean [profile] | run <profile> [target] | publish | test [profile] |
---           unlock <profile>|--all | config <...> | completion <shell> | help

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

-- Cleanups run before any os.exit() (both finish() and die()), so a build-dir
-- lock is always released even when a step fails and we bail out.
local _exit_hooks = {}
local function on_exit(fn) _exit_hooks[#_exit_hooks + 1] = fn end
local function run_exit_hooks()
  for i = #_exit_hooks, 1, -1 do pcall(_exit_hooks[i]) end
  _exit_hooks = {}
end

--- Exit, flushing stdout first. Under `nvim -l`, print() is fully buffered on
--- a pipe and os.exit() skips the flush; luvi is fine but this keeps both hosts
--- reliable.
local function finish(code)
  run_exit_hooks()
  io.stdout:flush()
  os.exit(code or 0)
end

--- Write a line to real stdout. `print()` goes to stderr under `nvim -l`, so
--- CLI output (the parseable part) must use io.write on both hosts.
local function out(s) io.write((s or "") .. "\n") end

--- Truncate `s` to width `w`, appending an ellipsis when it overflows.
local function trunc(s, w)
  s = tostring(s)
  if #s <= w then return s end
  return s:sub(1, math.max(1, w - 1)) .. "…"
end

local function die(msg, code)
  run_exit_hooks()
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
    -- — a not-yet-published `lw init` has only the latter.
    if uv.fs_stat(dir .. "/loomworks.json")
        or uv.fs_stat(dir .. "/.nvim/loomworks.user.json") then
      return dir
    end
    -- Stop at a git working-tree boundary — a directory with a `.git` entry
    -- (a dir in a normal checkout, a FILE in a linked worktree). A workspace
    -- must not resolve across a checkout boundary: without this, `lw` in a
    -- fresh `git worktree` (whose `.nvim/` doesn't exist yet, is gitignored,
    -- and isn't created by `git worktree add`) would silently walk past the
    -- worktree and bind to the PARENT checkout's workspace, operating on the
    -- wrong build dir. Returning nil here surfaces the "run `lw init`" hint
    -- instead.
    if uv.fs_stat(dir .. "/.git") then
      return nil
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

--- Like `resolve_abs` but for an OUTPUT path that need not exist yet (e.g. a
--- JUnit file to be written): join against `base`, forward-slash, no realpath.
--- @return string absolute forward-slashed path
local function resolve_abs_out(p, base)
  p = p:gsub("\\", "/")
  local joined = (p:match("^%a:/") or p:sub(1, 1) == "/") and p or (base .. "/" .. p)
  return (joined:gsub("/+$", ""))
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

--- Creation intent for `add`/`create` commands. nil = the per-kind default,
--- `local+shared` for most items (the CLI authors the shared contract).
--- Callers pass `default` to override that — profiles create `local`, since a
--- profile pins toolchains resolved on this machine. Set to `local` by
--- `--local` or to `local+shared` by `--shared` in main().
local create_intent = nil
local function created_intent(default)
  return create_intent or default or "local+shared"
end

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

-- ---------------------------------------------------------------------------
-- Tool cache (machine-level: ~/.cache/loomworks/tools.json, %LOCALAPPDATA% on
-- Windows). Detecting toolchains probes compilers, vswhere, and vcvarsall —
-- seconds of work redone in every fresh process. We persist the last scan so
-- the fast paths (profile create, profiles, later completion) reuse it.
-- `lw tools` always does a real scan and rewrites the cache (deliberate = real
-- result); `lw tools --cached` reads it. Compilers are a machine fact, not a
-- workspace one, so the cache is shared across workspaces, keyed by module type.
-- ---------------------------------------------------------------------------

local TOOL_CACHE_VERSION = 1
-- "auto"   serve the cache when it covers the needed modules, else scan+write
-- "force"  always scan + write (`lw tools`)
-- "cached" never scan; serve whatever is cached (`lw tools --cached`, and any
--          command that doesn't wait for tools — no point probing)
local tool_cache_mode = "auto"

-- Set while serving `lw __complete`: load_workspace returns nil instead of
-- dying on a broken/absent workspace, so shell completion never errors out.
local completion_mode = false

local function tool_cache_dir()
  if is_windows() then
    local lad = os.getenv("LOCALAPPDATA")
    if lad and #lad > 0 then return (lad:gsub("\\", "/")) .. "/loomworks/cache" end
  end
  local xdg = os.getenv("XDG_CACHE_HOME")
  if xdg and #xdg > 0 then return (xdg:gsub("\\", "/")) .. "/loomworks" end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
  return (home:gsub("\\", "/")) .. "/.cache/loomworks"
end

local function tool_cache_path() return tool_cache_dir() .. "/tools.json" end

--- @return table|nil { version, timestamp, scanned_types, tools_by_type }
local function read_tool_cache()
  local f = io.open(tool_cache_path(), "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return nil end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or data.version ~= TOOL_CACHE_VERSION then return nil end
  return data
end

--- Merge a fresh scan of `scanned_types` into the on-disk cache. Per-type merge
--- keeps entries for module types this workspace didn't scan (machine cache),
--- while refreshing the ones it did — including clearing a type that now has no
--- tools (its tools_by_type entry becomes absent but it stays "scanned").
local function write_tool_cache(tools_by_type, scanned_types)
  local existing = read_tool_cache() or {}
  local tbt = existing.tools_by_type or {}
  local scanned = existing.scanned_types or {}
  for mod_type in pairs(scanned_types) do
    scanned[mod_type] = true
    tbt[mod_type] = tools_by_type[mod_type] -- nil clears a now-empty type
  end
  vim.fn.mkdir(tool_cache_dir(), "p")
  local f = io.open(tool_cache_path(), "w")
  if not f then return end
  f:write(vim.json.encode({
    version = TOOL_CACHE_VERSION,
    timestamp = os.time(),
    scanned_types = scanned,
    tools_by_type = tbt,
  }))
  f:close()
end

--- Module types the workspace needs tools for, from the reconstructed config.
local function config_needed_types(config)
  local t = {}
  if config and config.projects then
    for _, p in pairs(config.projects) do
      if p.type then t[p.type] = true end
    end
  end
  return t
end

--- True when the cache has scanned every needed module type (an empty result
--- for a type still counts as covered — scanned_types records it).
local function cache_covers(cache, needed)
  local scanned = cache and cache.scanned_types or {}
  for mod_type in pairs(needed) do
    if not scanned[mod_type] then return false end
  end
  return true
end

--- The real detect_tools_async, captured before we wrap it.
local orig_detect_tools_async = nil

--- Caching wrapper around core's detect_tools_async, honoring tool_cache_mode.
local function cached_detect_tools_async(config, cfg_cache, callback)
  local needed = config_needed_types(config)
  if tool_cache_mode ~= "force" then
    local cache = read_tool_cache()
    if cache and (tool_cache_mode == "cached" or cache_covers(cache, needed)) then
      return callback(cache.tools_by_type or {})
    end
    if tool_cache_mode == "cached" then
      return callback({}) -- told not to scan and nothing cached
    end
  end
  -- Real scan; record which types we scanned so "scanned but empty" is cached.
  orig_detect_tools_async(config, cfg_cache, function(tools_by_type)
    write_tool_cache(tools_by_type, needed)
    callback(tools_by_type)
  end)
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
  -- The CLI never surfaces build targets, so skip target introspection — it can
  -- spawn a per-build-dir meson/python subprocess (~2s) on every load.
  core._deps.scan_targets = false
  -- Serve tools from the machine-level cache. A load that won't wait for tools
  -- never probes — serve cache only (never spend seconds for a command that
  -- doesn't need live tools). Install the wrapper before setup triggers a scan.
  if wait_tools == false and tool_cache_mode == "auto" then
    tool_cache_mode = "cached"
  end
  if core._deps.detect_tools_async ~= cached_detect_tools_async then
    orig_detect_tools_async = core._deps.detect_tools_async
    core._deps.detect_tools_async = cached_detect_tools_async
  end
  core:setup({ root = root })
  local ok = vim.wait(15000, function()
    return core._state == "initialized" or core._state == "uninitialized"
  end, 25)
  if not ok then
    if completion_mode then return nil end
    die("timed out loading workspace at " .. root)
  end
  local ws = lw.get_workspace()
  if not ws then
    if completion_mode then return nil end
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

--- Resolve which profile to operate on: explicit name (exact, then
--- unambiguous substring) → user.json active → single → error.
--- @param ws table
--- @param name string|nil
--- @return table profile
local function resolve_profile(ws, name)
  local profiles = ws._profiles or {}
  if name then
    -- Boundary-anchored selector: exact key, else a segment-aligned
    -- match, so `Debug:ninja-clang-18` deterministically resolves the highest
    -- matching patch and `clang-1` never crosses into `clang-18`.
    local keys, by_key = {}, {}
    for _, p in ipairs(profiles) do keys[#keys + 1] = p.key; by_key[p.key] = p end
    local hit, ambiguous = require("loomworks.merge").match_profile(keys, name)
    if hit then return by_key[hit] end
    if ambiguous then
      die("'" .. name .. "' matches multiple profiles: " .. table.concat(ambiguous, ", "))
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

--- Spawn `step` and wait for it. Default: capture stdout/stderr and print them
--- (build/test steps). `opts.launch`: attach the child to this terminal
--- (inherited stdio, window shown) so a launched program streams output live,
--- reads stdin, and shows its GUI window — like a direct launch, not the
--- hidden/captured spawn used for build tools.
--- @param step table { cmd, cwd, env }
--- @param root string
--- @param opts? { launch?: boolean }
--- @return integer code
local function run_spec(step, root, opts)
  -- An empty env table would wipe PATH; inherit the parent env instead.
  local env = (step.env and next(step.env)) and step.env or nil
  if opts and opts.launch then
    -- Flush our own buffered output first: the child inherits the terminal and
    -- writes directly, so anything we printed must land before its output
    -- (otherwise our block-buffered stdout flushes only at exit, after the
    -- child's live output).
    io.stdout:flush(); io.stderr:flush()
    local res = vim.system(step.cmd, {
      cwd = step.cwd or root,
      env = env,
      stdio = "inherit",
      hide = false,
    }):wait()
    return res.code
  end
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

--- Interactive picker among the workspace's configuration sets.
local function pick_config_set(ws)
  local sets = {}
  for _, s in ipairs(ws._config_sets or {}) do sets[#sets + 1] = s end
  table.sort(sets, function(a, b) return a.name < b.name end)
  if #sets == 1 then return sets[1] end
  out("Select a configuration set to build:")
  for i, s in ipairs(sets) do out(string.format("  %d) %s", i, s.name)) end
  out("")
  local line = prompt_line("Enter number (blank to cancel)")
  if not line or line == "" then out("cancelled"); finish(0) end
  local n = tonumber(line)
  if not n or not sets[n] then die("invalid selection: " .. tostring(line)) end
  return sets[n]
end

--- Resolve the profile to build. When no profile exists yet, onboard one from a
--- configuration set (interactively): pick a set, create+activate a profile
--- (prompting for the tool), then build it. Non-interactive/CI never creates —
--- it defers to resolve_profile's strict, explicit error (builds are read-only
--- there). Returns (profile, ws); ws may be a fresh reload.
local function resolve_build_target(ws, name)
  local profiles = ws._profiles or {}

  -- A concrete profile match (exact key or unambiguous substring) always wins.
  if name then
    for _, p in ipairs(profiles) do if p.key == name then return p, ws end end
    local matches = {}
    for _, p in ipairs(profiles) do if p.key:find(name, 1, true) then matches[#matches + 1] = p end end
    if #matches == 1 then return matches[1], ws end
    if #matches > 1 then
      local keys = {}
      for _, p in ipairs(matches) do keys[#keys + 1] = p.key end
      die("'" .. name .. "' matches multiple profiles: " .. table.concat(keys, ", "))
    end
  else
    if not interactive() then return resolve_profile(ws, nil), ws end
    local active = ws._active_profile_key
    if active then for _, p in ipairs(profiles) do if p.key == active then return p, ws end end end
    if #profiles == 1 then return profiles[1], ws end
    if #profiles > 1 then
      die("no profile specified and no active default — `lw profile select`, or `lw build <profile>`")
    end
  end

  -- No profile matched. Non-interactive → strict error with the exact commands.
  if not interactive() then
    if name then
      for _, s in ipairs(ws._config_sets or {}) do
        if s.name == name then
          die("'" .. name .. "' is a configuration set with no profile yet — " ..
            "create one:\n  lw profile create " .. name .. " <tool> --activate   " ..
            "(tools: `lw tools`)\n  then: lw build")
        end
      end
    end
    return resolve_profile(ws, name), ws
  end

  -- Onboard: build a config set by creating a profile for it.
  local sets = ws._config_sets or {}
  if not next(sets) then
    die("no profiles or configuration sets yet.\n" ..
      "  create a set:  lw configuration-set create <name> <project>=<config>")
  end
  local cs
  if name then
    for _, s in ipairs(sets) do if s.name == name then cs = s; break end end
    if not cs then
      die("no profile or configuration set matching '" .. name .. "'.\n" ..
        "  `lw profiles` / `lw configuration-set list`")
    end
  else
    cs = pick_config_set(ws)
  end

  out("No profile for '" .. cs.name .. "' yet — let's create one.")
  M.cmd_profile_create(ws.root, { "profile", "create", cs.name, "--activate" })
  out("")

  -- Reload to pick up the newly created + activated profile.
  local ws2 = load_workspace(ws.root)
  local active = ws2._active_profile_key
  for _, p in ipairs(ws2._profiles or {}) do
    if p.key == active then return p, ws2 end
  end
  die("profile creation did not yield an active profile")
end

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

--- Persist a headless step's outcome (state + config snapshot for staleness)
--- to the cache via Workspace:record_task_result, so a later invocation skips
--- an already-done, unchanged configure (headless builds may write the cache).
--- build_dir is set on the unit but not passed as result.build_dir
--- (that triggers the post-configure parse_targets scan the CLI opts out of).
local function record_step(ws, step, ok)
  if not step.unit then return end
  if step.build_dir then step.unit.build_dir_value = step.build_dir end
  pcall(function()
    ws:record_task_result({ unit = step.unit, action = step.kind, success = ok })
  end)
end

--- Run a profile's build steps (configure + build), dying on any failure.
--- Returns the number of steps run (0 = nothing buildable).
--- @param opts? table { for_test?: boolean, extra_args?: string[] } for_test
---   skips building units whose native test runner rebuilds itself;
---   extra_args are forwarded to the build tool.
local function run_build_steps(profile, ws, opts)
  opts = opts or {}
  -- Same gate the editor applies in `Profile:build` / `Profile:configure`.
  -- The CLI plans steps directly, so without this an unbuildable profile —
  -- e.g. one mapping an abstract configuration — would build anyway, on
  -- whatever default the module picked.
  if profile.assert_buildable then
    local buildable, why = profile:assert_buildable()
    if not buildable then die(tostring(why)) end
  end
  local overseer = require("loomworks.overseer")
  local steps = overseer.plan_profile_build(profile, opts)
  if not steps or #steps == 0 then return 0 end
  out("building profile: " .. profile.key)
  for _, step in ipairs(steps) do
    -- Caller args (`lw build -- -j 4`) go to the BUILD tool only — a configure
    -- step would choke on them. Appended so they layer on top.
    if opts.extra_args and step.kind == "build" then
      step.cmd = vim.list_extend(vim.list_extend({}, step.cmd), opts.extra_args)
    end
    out(string.format("==> [%s] %s", step.kind, step.name or "?"))
    local code = run_spec(step, ws.root)
    record_step(ws, step, code == 0)
    if code ~= 0 then
      die(string.format("%s failed (exit %d): %s", step.kind, code, step.name or "?"), code)
    end
  end
  return #steps
end

--- The distinct build directories a profile's projects map to.
--- @param profile loomworks.Profile
--- @return string[]
local function profile_build_dirs(profile)
  local dirs, seen = {}, {}
  for _, pp in ipairs(profile:projects()) do
    local bd = pp.build_dir and pp:build_dir()
    if bd and not seen[bd] then seen[bd] = true; dirs[#dirs + 1] = bd end
  end
  return dirs
end

--- Hold a cross-process lock on every build directory of `profile`
--- for the duration of `fn`, then release. Fail-fast: if any dir is in use by
--- another process, dies with a clear message (releasing any already held). A
--- release is also registered as an exit hook so a `die()` inside `fn` frees
--- the locks too.
--- @param profile loomworks.Profile
--- @param action "build"|"clean"
--- @param fn fun()
local function with_build_locks(profile, action, fn)
  local build_lock = require("loomworks.build_lock")
  local held = {}
  local function release_all()
    for _, h in ipairs(held) do build_lock.release(h) end
    held = {}
  end
  on_exit(release_all)
  for _, bd in ipairs(profile_build_dirs(profile)) do
    local h, err = build_lock.acquire(bd, action)
    if not h then
      release_all()
      die("cannot " .. action .. ": " .. tostring(err))
    end
    held[#held + 1] = h
  end
  fn()
  release_all()
end

--- `lw build [profile] [-- <build-tool args>]` — configure if needed, then
--- build. Args after `--` are forwarded to the build tool (e.g. `-- -j 4`).
function M.cmd_build(ws, args)
  -- Split on `--`: everything after goes to the build tool.
  local pre, extra, seen_sep = {}, {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then extra[#extra + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  if pre[2] then
    die("unexpected argument '" .. tostring(pre[2]) ..
      "' — usage: lw build [profile] [-- build-tool-args…]")
  end
  local profile
  profile, ws = resolve_build_target(ws, pre[1])
  local built = 0
  with_build_locks(profile, "build", function()
    built = run_build_steps(profile, ws, { extra_args = (#extra > 0) and extra or nil })
  end)
  if built == 0 then
    die("nothing to build for profile '" .. profile.key ..
      "' — no buildable projects (unavailable module or unresolved tool?)")
  end
  out("BUILD OK: " .. profile.key)
  return 0
end

--- `lw clean [profile]` — run each project's build-system clean (e.g.
--- `meson compile --clean`, `cmake --build --target clean`) on the profile's
--- configured build dirs. Removes build artifacts but keeps the configuration
--- (a later build reconfigures only if stale). Dies on any failure.
function M.cmd_clean(ws, profile_name)
  local overseer = require("loomworks.overseer")
  local profile
  profile, ws = resolve_build_target(ws, profile_name)
  local steps = overseer.plan_profile_clean(profile)
  if not steps or #steps == 0 then
    die("nothing to clean for profile '" .. profile.key ..
      "' — no configured build directories.")
  end
  with_build_locks(profile, "clean", function()
    out("cleaning profile: " .. profile.key)
    for _, step in ipairs(steps) do
      out(string.format("==> [clean] %s", step.name or "?"))
      local code = run_spec(step, ws.root)
      if code ~= 0 then
        die(string.format("clean failed (exit %d): %s", code, step.name or "?"), code)
      end
    end
  end)
  out("CLEAN OK: " .. profile.key)
  return 0
end

--- `lw unlock <profile> | --all` — force-remove build-dir locks,
--- for recovery after a crash left a stale lock. Warns before clearing a lock
--- that still looks active (fresh heartbeat).
function M.cmd_unlock(ws, args)
  local build_lock = require("loomworks.build_lock")
  local all, profile_name = false, nil
  for i = 2, #args do
    if args[i] == "--all" then all = true
    elseif not profile_name then profile_name = args[i] end
  end

  local function unlock_dir(bd)
    local info = build_lock.read(bd)
    if not info then return false end
    if not info.stale then
      io.stderr:write(string.format(
        "lw: forcing an ACTIVE lock (pid %s, %s, %ss ago): %s\n",
        tostring(info.pid), tostring(info.action), tostring(info.age), bd))
    end
    build_lock.force(bd)
    out("unlocked " .. bd)
    return true
  end

  local targets = {}
  if all then
    for _, p in ipairs(ws._profiles or {}) do
      for _, bd in ipairs(profile_build_dirs(p)) do targets[bd] = true end
    end
  else
    if not profile_name then
      die("usage: lw unlock <profile> | --all")
    end
    for _, bd in ipairs(profile_build_dirs(resolve_profile(ws, profile_name))) do
      targets[bd] = true
    end
  end

  local removed = 0
  for bd in pairs(targets) do
    if unlock_dir(bd) then removed = removed + 1 end
  end
  if removed == 0 then out("no build-dir locks to clear") end
  return 0
end

--- Ensure a config unit's build targets are parsed — the headless equivalent
--- of the editor's post-configure scan (workspace.lua). No-op if already
--- parsed or the module exposes no target introspection. Requires a configured
--- build dir, so the caller must build first.
local function ensure_unit_targets(ws, unit)
  if not unit or unit.targets then return end
  local project = unit._project
  local mod = project and project._module and project._module.impl
  local build_dir = unit.build_dir and unit:build_dir()
  if not (mod and mod.parse_targets and build_dir) then return end
  -- config_name is the module build type (e.g. "Debug"); matters for
  -- multi-config generators, ignored by single-config ones.
  local cfg = unit.configuration and unit:configuration()
  local config_name = (cfg and cfg.module_config and cfg.module_config.variant)
    or (unit._cached_module_config and unit._cached_module_config.variant)
    or (unit.variant and unit:variant())
  local ok, targets = pcall(mod.parse_targets, {
    build_dir = build_dir,
    project_path = ws.root .. "/" .. (project.path or project.key),
    config_name = config_name,
  })
  if ok and targets then unit:set_targets(targets) end
end

--- `lw test [profile] [--junit <file>] [-- <args>]` — build a profile, then run
--- its tests via each module's native runner, reporting a real exit code.
--- Args after `--` are forwarded to the native batch runner (e.g.
--- `-- -j 4` / `-- --num-processes 4`). `--junit <file>` writes JUnit XML for CI
--- (one file per unit — a label suffix when a profile runs several).
function M.cmd_test(ws, args)
  local overseer = require("loomworks.overseer")
  -- Split on `--`: everything after is forwarded to the native test runner.
  local pre, extra, seen_sep = {}, {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then extra[#extra + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  -- Pre-`--` tokens: `--junit <file>` and a positional profile.
  local profile_name, junit
  local i = 1
  while pre[i] do
    if pre[i] == "--junit" then
      junit = pre[i + 1]
      if not junit then die("--junit requires a file path") end
      i = i + 2
    elseif not profile_name then
      profile_name = pre[i]; i = i + 1
    else
      die("unexpected argument '" .. tostring(pre[i]) ..
        "' — usage: lw test [profile] [--junit <file>] [-- args…]")
    end
  end
  if junit then junit = resolve_abs_out(junit, user_cwd()) end

  local profile
  profile, ws = resolve_build_target(ws, profile_name)
  -- Hold the build-dir lock across build AND test: a native runner like
  -- `meson test` rebuilds, so the whole run must be exclusive of other
  -- processes touching the same build dir.
  with_build_locks(profile, "build", function()
    -- Ensure configured + built, but skip building units whose native test
    -- runner rebuilds itself — e.g. `meson test`. Dies on build failure.
    run_build_steps(profile, ws, { for_test = true })

    -- Parse build targets before planning: the test step's run environment
    -- (sibling DLL dirs on Windows) is derived from parsed targets, and
    -- ctest, unlike `meson test`, does not set that up itself. Without this a
    -- DLL-dependent test executable fails in the loader (0xc0000135).
    for _, pp in ipairs(profile:projects()) do ensure_unit_targets(ws, pp._config_unit) end

    local test_steps, units = overseer.plan_profile_test(profile,
      { extra_args = (#extra > 0) and extra or nil, junit = junit })
    if not test_steps or #test_steps == 0 then
      out("no tests to run for profile '" .. profile.key .. "'" ..
        ((units and units > 0) and " — its modules expose no test runner" or ""))
      return
    end

    -- ctest's --output-junit and the meson copy target both need the directory
    -- to exist up front.
    if junit then
      local dir = junit:match("^(.*)/[^/]+$")
      if dir then vim.fn.mkdir(dir, "p") end
    end

    local failed, wrote = {}, {}
    for _, step in ipairs(test_steps) do
      out(string.format("==> [test] %s", step.name or "?"))
      local code = run_spec(step, ws.root)
      if code ~= 0 then failed[#failed + 1] = step.name or "?" end
      -- Materialize JUnit at the caller's path. When the runner wrote it to its
      -- own fixed location (meson), copy it over; when it wrote there directly
      -- (ctest), just confirm. Runs even for failed tests — CI wants the report.
      if step.junit_dest and step.junit_out then
        if norm_cmp(step.junit_out) ~= norm_cmp(step.junit_dest) then
          if uv.fs_stat(step.junit_out) then
            uv.fs_copyfile(step.junit_out, step.junit_dest)
            wrote[#wrote + 1] = step.junit_dest
          else
            io.stderr:write("lw: warning: no JUnit output for " .. (step.name or "?") .. "\n")
          end
        elseif uv.fs_stat(step.junit_dest) then
          wrote[#wrote + 1] = step.junit_dest
        else
          io.stderr:write("lw: warning: no JUnit output for " .. (step.name or "?") .. "\n")
        end
      end
    end

    for _, p in ipairs(wrote) do out("JUnit: " .. p) end

    if #failed > 0 then
      die(string.format("%d of %d test run(s) failed: %s",
        #failed, #test_steps, table.concat(failed, ", ")), 1)
    end
    out(string.format("TESTS OK: %s (%d run%s)", profile.key, #test_steps,
      #test_steps == 1 and "" or "s"))
  end)
  return 0
end

--- `lw init` — initialize the working copy (.nvim/loomworks.user.json).
-- ---------------------------------------------------------------------------
-- Launch configurations + run
-- ---------------------------------------------------------------------------

--- Enumerate launchable targets in a profile: command launch configs and
--- executable build targets across the profile's mapped projects. Each entry:
--- `{ kind = "launch"|"target", project = Project, name = string, target_id? = string }`.
--- Parses targets on demand (build first).
local function launchable_targets(ws, profile)
  local list = {}
  for _, pp in ipairs(profile:projects()) do
    local unit = pp._config_unit
    local project = unit and unit._project
    if project then
      if type(project.launch) == "table" then
        local names = {}
        for lname, cfg in pairs(project.launch) do
          if type(cfg) == "table" and (cfg.command or cfg.target) then names[#names + 1] = lname end
        end
        table.sort(names)
        for _, lname in ipairs(names) do
          list[#list + 1] = { kind = "launch", project = project, name = lname }
        end
      end
      ensure_unit_targets(ws, unit)
      if type(unit.targets) == "table" then
        local ids = {}
        for id in pairs(unit.targets) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
          local t = unit.targets[id]
          if t and t.is_executable and t:is_executable() then
            local dname = (t.display_name and t:display_name()) or id
            list[#list + 1] = { kind = "target", project = project, name = dname, target_id = id }
          end
        end
      end
    end
  end
  return list
end

--- Format a candidate for messages: `project:name (kind)`.
local function fmt_cand(c)
  return c.project.key .. ":" .. c.name .. " (" .. c.kind .. ")"
end

--- Build a LaunchTarget object from a resolved candidate.
local function candidate_launch_target(ws, profile, c)
  local descriptor = { project = c.project.key }
  if c.kind == "target" then descriptor.target = c.target_id else descriptor.launch = c.name end
  return require("loomworks.launch_target").new(ws, profile, descriptor)
end

--- `lw run <profile> [target] [-- prog-args…]` — resolve a profile and a
--- launch target (the profile's default when unnamed, else a named build
--- target or command launch config), then build → deploy → execute. Args
--- after `--` are forwarded to the program. Returns its exit code.
--- Routes through the editor's LaunchTarget seams (resolve_launch_spec
--- / deploy_sync) so headless and editor launches stay identical.
function M.cmd_run(ws, args)
  -- Split on `--`: everything after is forwarded verbatim to the program.
  local pre, extra_args, seen_sep = {}, {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then extra_args[#extra_args + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  -- Disambiguation flags (`--project <key>`, `--target`, `--launch`) and a
  -- per-invocation `--cwd <dir>`; remaining pre-`--` tokens are
  -- positional (profile, then optional target).
  local positionals, proj_scope, kind, cwd_override = {}, nil, nil, nil
  local i = 1
  while pre[i] do
    if pre[i] == "--project" then proj_scope = pre[i + 1]; i = i + 2
    elseif pre[i] == "--target" then kind = "target"; i = i + 1
    elseif pre[i] == "--launch" then kind = "launch"; i = i + 1
    elseif pre[i] == "--cwd" or pre[i] == "--working-dir" then cwd_override = pre[i + 1]; i = i + 2
    else positionals[#positionals + 1] = pre[i]; i = i + 1 end
  end
  local profile_name, target_name = positionals[1], positionals[2]

  local profile
  profile, ws = resolve_build_target(ws, profile_name)

  -- Build the profile first (configures + builds); dies on failure. Build
  -- targets and the default target's artifact resolve against the built tree.
  -- The build-dir lock is held only for the build — released before the launch,
  -- which just executes the artifact and may run indefinitely.
  with_build_locks(profile, "build", function()
    run_build_steps(profile, ws)
  end)

  local lt
  if target_name then
    -- Optional `project:name` scoping — split only when the prefix is a known
    -- project in this profile (target ids may themselves contain ':').
    local scope, bare = proj_scope, target_name
    if not scope then
      local pfx, rest = target_name:match("^([^:]+):(.+)$")
      if pfx and profile:project(pfx) then scope, bare = pfx, rest end
    end
    local all = launchable_targets(ws, profile)
    local matches = {}
    for _, c in ipairs(all) do
      if c.name == bare and (not scope or c.project.key == scope)
        and (not kind or c.kind == kind) then matches[#matches + 1] = c end
    end
    if #matches == 0 then
      local labels = {}
      for _, c in ipairs(all) do labels[#labels + 1] = fmt_cand(c) end
      die("no launch target '" .. target_name .. "' in profile '" .. profile.key .. "'.\n" ..
        "  available: " .. (next(labels) and table.concat(labels, ", ") or "(none)"))
    elseif #matches > 1 then
      local labels = {}
      for _, c in ipairs(matches) do labels[#labels + 1] = fmt_cand(c) end
      die("'" .. target_name .. "' is ambiguous: " .. table.concat(labels, ", ") ..
        "\n  qualify with `--target`/`--launch`, `--project <key>`, or `<project>:<name>`.")
    end
    lt = candidate_launch_target(ws, profile, matches[1])
  else
    -- No name → the profile's default target.
    for _, pp in ipairs(profile:projects()) do ensure_unit_targets(ws, pp._config_unit) end
    lt = profile:default_target()
    if not lt then
      local cands = launchable_targets(ws, profile)
      if #cands == 1 then
        lt = candidate_launch_target(ws, profile, cands[1])
      elseif #cands == 0 then
        die("nothing to run in profile '" .. profile.key ..
          "' — no launch configs or executable targets.")
      else
        local labels = {}
        for _, c in ipairs(cands) do labels[#labels + 1] = fmt_cand(c) end
        die("no default target set for profile '" .. profile.key .. "'.\n" ..
          "  set one:      lw profile target " .. profile.key .. " <target>\n" ..
          "  or name one:  lw run " .. profile.key .. " <target>\n" ..
          "  candidates:   " .. table.concat(labels, ", "))
      end
    end
  end

  -- Validity gate (stale descriptor / invalid profile or configuration).
  local ok, reasons = lt:is_valid()
  if not ok then
    die("launch target is not runnable: " ..
      table.concat(type(reasons) == "table" and reasons or { "invalid" }, "; "))
  end

  -- Deploy (both phases), then execute the resolved spec.
  local dok, derr = lt:deploy_sync()
  if not dok then die("deploy failed: " .. tostring(derr)) end

  local spec, serr = lt:resolve_launch_spec({ extra_args = extra_args, working_dir = cwd_override })
  if not spec then die("cannot resolve launch: " .. tostring(serr)) end

  local full = { spec.cmd }
  for _, a in ipairs(spec.args or {}) do full[#full + 1] = a end
  out(string.format("running %s [cwd: %s]: %s", spec.name, spec.cwd or ws.root,
    table.concat(full, " ")))
  return run_spec({ cmd = full, cwd = spec.cwd, env = spec.env }, ws.root, { launch = true })
end

--- `lw launch list [project]` — list command-type launch configs.
function M.cmd_launch_list(ws, proj_name)
  local projs = {}
  for _, p in pairs(ws._projects) do
    if (not proj_name or p.key == proj_name) and type(p.launch) == "table" and next(p.launch) then
      projs[#projs + 1] = p
    end
  end
  table.sort(projs, function(a, b) return a.key < b.key end)

  -- Collect rows as (project, name, runs) so PROJECT and NAME lead, in the same
  -- order you pass them to `lw launch show|set <project> <name>`.
  local rows = {}
  for _, p in ipairs(projs) do
    local names = {}
    for n in pairs(p.launch) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
      local cfg = p.launch[n]
      local runs
      if type(cfg) == "table" and cfg.target then
        runs = "target:" .. cfg.target
      elseif type(cfg) == "table" and cfg.command then
        runs = cfg.command
      else
        runs = "(no command)"
      end
      if type(cfg) == "table" and cfg.args and #cfg.args > 0 then
        runs = runs .. " " .. table.concat(cfg.args, " ")
      end
      rows[#rows + 1] = { project = p.key, name = n, runs = runs }
    end
  end

  if #rows == 0 then
    out("no launch configurations" .. (proj_name and (" for '" .. proj_name .. "'") or "") ..
      ".\n  add one: lw launch add <project> <name> <command|--from-target T> [args…]")
    return 0
  end

  -- Size the PROJECT / NAME columns to their contents (capped).
  local pw, nw = #"PROJECT", #"NAME"
  for _, r in ipairs(rows) do
    pw = math.max(pw, #r.project)
    nw = math.max(nw, #r.name)
  end
  pw = math.min(pw, 20); nw = math.min(nw, 24)
  local fmt = "  %-" .. pw .. "s  %-" .. nw .. "s  %s"

  out("Launch configs — pass PROJECT and NAME to `lw launch show|set`:")
  out("")
  out(string.format(fmt, "PROJECT", "NAME", "RUNS"))
  for _, r in ipairs(rows) do
    out(string.format(fmt, trunc(r.project, pw), trunc(r.name, nw), trunc(r.runs, 46)))
  end
  return 0
end

--- `lw launch add <project> <name> <command> [args…] [--working-dir D] [--env K=V]`
--- or  `lw launch add <project> <name> --from-target <target> [args…] [flags]`
--- (target-backed launch config — runs the target's built artifact with
--- the build-tree run environment; args/env/working_dir layer on top).
function M.cmd_launch_add(root, args)
  local proj_name, name = args[3], args[4]
  local usage = "usage: lw launch add <project> <name> <command> [args…] [--working-dir D] [--env K=V]\n" ..
    "   or: lw launch add <project> <name> --from-target <target> [args…] [--working-dir D] [--env K=V]"
  if not (proj_name and name) then die(usage) end
  local ws = load_workspace(root, false)
  local project = resolve_project(ws, proj_name)

  local positionals, from_target, working_dir, env = {}, nil, nil, nil
  local i = 5
  while args[i] do
    local v = args[i]
    if v == "--working-dir" or v == "--cwd" then working_dir = args[i + 1]; i = i + 2
    elseif v == "--from-target" then from_target = args[i + 1]; i = i + 2
    elseif v == "--env" then
      local k, val = (args[i + 1] or ""):match("^([^=]+)=(.*)$")
      if not k then die("bad --env '" .. tostring(args[i + 1]) .. "' — use KEY=VALUE") end
      env = env or {}; env[k] = val; i = i + 2
    else positionals[#positionals + 1] = v; i = i + 1 end
  end

  local cfg
  if from_target then
    -- Target-backed: no command positional; remaining positionals are args.
    cfg = { target = from_target }
    if #positionals > 0 then cfg.args = positionals end
  else
    if #positionals == 0 then die(usage) end
    cfg = { command = positionals[1] }
    if #positionals > 1 then
      local a = {}
      for k = 2, #positionals do a[#a + 1] = positionals[k] end
      cfg.args = a
    end
  end
  if working_dir then cfg.working_dir = working_dir end
  if env then cfg.env = env end

  local ok, err = project:save_launch_config(name, cfg)
  if not ok then die("could not save launch config: " .. tostring(err)) end
  out(string.format("added launch config '%s' on project '%s'%s", name, project.key,
    from_target and (" (target: " .. from_target .. ")") or ""))
  out("  run it: lw run <profile> " .. name)
  return 0
end

--- `lw launch set <project> <name> [flags]` — modify an existing launch config
--- in place. Reads the config, applies only the given changes, saves it
--- back to the project's working copy.
---   --working-dir D | --clear-working-dir
---   --env K=V (add/update, repeatable) | --unset-env K (remove, repeatable)
---   --command C | --from-target T   (switch kind)
---   trailing positionals replace args | --clear-args
function M.cmd_launch_set(root, args)
  local proj_name, name = args[3], args[4]
  if not (proj_name and name) then
    die("usage: lw launch set <project> <name> [--working-dir D|--clear-working-dir] " ..
      "[--env K=V] [--unset-env K] [--command C|--from-target T] [args…|--clear-args]")
  end
  local ws = load_workspace(root, false)
  local project = resolve_project(ws, proj_name)
  local cur = project.launch and project.launch[name]
  if type(cur) ~= "table" then
    die("no launch config '" .. name .. "' on project '" .. project.key ..
      "' — create it with `lw launch add`")
  end

  -- Copy so a save failure leaves the in-memory config untouched. Preserve
  -- fields we don't edit (e.g. deploy, debug); deep-copy the mutated tables.
  local new = {}
  for k, v in pairs(cur) do new[k] = v end
  if type(new.env) == "table" then
    local e = {}; for k, v in pairs(new.env) do e[k] = v end; new.env = e
  end
  if type(new.args) == "table" then
    local a = {}; for i, v in ipairs(new.args) do a[i] = v end; new.args = a
  end

  local new_args, touched = nil, false
  local i = 5
  while args[i] do
    local v = args[i]
    if v == "--working-dir" or v == "--cwd" then new.working_dir = args[i + 1]; touched = true; i = i + 2
    elseif v == "--clear-working-dir" then new.working_dir = nil; touched = true; i = i + 1
    elseif v == "--env" then
      local k, val = (args[i + 1] or ""):match("^([^=]+)=(.*)$")
      if not k then die("bad --env '" .. tostring(args[i + 1]) .. "' — use KEY=VALUE") end
      new.env = new.env or {}; new.env[k] = val; touched = true; i = i + 2
    elseif v == "--unset-env" then
      local k = args[i + 1]
      if not k then die("--unset-env needs a KEY") end
      if type(new.env) == "table" then
        new.env[k] = nil
        if not next(new.env) then new.env = nil end
      end
      touched = true; i = i + 2
    elseif v == "--clear-args" then new.args = nil; touched = true; i = i + 1
    elseif v == "--command" then new.command = args[i + 1]; new.target = nil; touched = true; i = i + 2
    elseif v == "--from-target" then new.target = args[i + 1]; new.command = nil; touched = true; i = i + 2
    else new_args = new_args or {}; new_args[#new_args + 1] = v; i = i + 1 end
  end
  if new_args then new.args = new_args; touched = true end
  if not touched then
    die("nothing to change — pass e.g. --working-dir D, --env K=V, --unset-env K")
  end

  local ok, err = project:save_launch_config(name, new)
  if not ok then die("could not save launch config: " .. tostring(err)) end
  out(string.format("updated launch config '%s' on project '%s'", name, project.key))
  return M.cmd_launch_show(root, project.key, name)
end

--- `lw launch show <project> <name>`
function M.cmd_launch_show(root, proj_name, name)
  if not (proj_name and name) then die("usage: lw launch show <project> <name>") end
  local ws = load_workspace(root, false)
  local project = resolve_project(ws, proj_name)
  local cfg = project.launch and project.launch[name]
  if not cfg then die("no launch config '" .. name .. "' on project '" .. project.key .. "'") end
  out("launch config '" .. name .. "'  (project " .. project.key .. ")")
  if cfg.target then
    out("  target       " .. tostring(cfg.target) .. "  (runs the built artifact + run env)")
  else
    out("  command      " .. tostring(cfg.command))
  end
  if cfg.args then out("  args         " .. table.concat(cfg.args, " ")) end
  if cfg.working_dir then out("  working_dir  " .. cfg.working_dir) end
  if type(cfg.env) == "table" then
    for k, v in pairs(cfg.env) do out("  env." .. k .. " = " .. tostring(v)) end
  end
  return 0
end

--- `lw launch remove <project> <name>`
function M.cmd_launch_remove(root, proj_name, name)
  if not (proj_name and name) then die("usage: lw launch remove <project> <name>") end
  local ws = load_workspace(root, false)
  local project = resolve_project(ws, proj_name)
  local ok, err = project:delete_launch_config(name)
  if not ok then die(tostring(err)) end
  out("removed launch config '" .. name .. "' from project '" .. project.key .. "'")
  return 0
end

function M.cmd_launch(sub, root, args)
  if sub == nil or sub == "list" then return M.cmd_launch_list(load_workspace(root, false), args[3]) end
  if sub == "add" then return M.cmd_launch_add(root, args) end
  if sub == "set" or sub == "edit" then return M.cmd_launch_set(root, args) end
  if sub == "show" then return M.cmd_launch_show(root, args[3], args[4]) end
  if sub == "remove" or sub == "rm" then return M.cmd_launch_remove(root, args[3], args[4]) end
  die("unknown launch subcommand '" .. tostring(sub) .. "' — use list|add|set|show|remove")
end

--- loomworks.json is written later by `lw publish` (working-copy model).
function M.cmd_init(args)
  local dir = (os.getenv("LW_ROOT") or uv.cwd()):gsub("\\", "/"):gsub("/+$", "")
  -- Optional `--name <name>` overrides the directory-basename default.
  local name
  local i = 2
  while args and args[i] do
    if args[i] == "--name" then
      name = args[i + 1]
      if not name then die("--name requires a value") end
      i = i + 2
    else
      die("unknown init argument '" .. tostring(args[i]) .. "' — usage: lw init [--name <name>]")
    end
  end
  local ok, err = require("loomworks.workspace").init_workspace(dir, name)
  if not ok then die(err or "failed to initialize workspace") end
  out("initialized workspace at " .. dir)
  out("  created .nvim/loomworks.user.json (working copy)")
  if name then out("  name: " .. name) end
  out("")
  out("Add `.nvim/` to the repo's .gitignore — it holds the working copy, the")
  out("cache and build trees, all machine-local. Only loomworks.json is shared.")
  out("")
  out("Add projects/profiles (editor or manual edit), then `lw publish` to")
  out("write the shared loomworks.json.")
  return 0
end

--- `lw workspace <rename <name>>` — manage workspace-level settings.
--- Bare `lw workspace` prints the current name.
function M.cmd_workspace(sub, root, args)
  if sub == nil then
    if not root then die("no loomworks.json found (searched up from cwd) — `lw init` to create one") end
    local ws = load_workspace(root, false)
    out(ws.name or "(unnamed)")
    return 0
  end
  if sub == "rename" or sub == "mv" then
    local new_name = args[3]
    if not new_name then die("usage: lw workspace rename <name>") end
    if not root then die("no loomworks.json found (searched up from cwd) — `lw init` to create one") end
    local ws = load_workspace(root, false)
    local ok, err = ws:rename_workspace(new_name)
    if not ok then die("could not rename workspace: " .. tostring(err)) end
    out("workspace name set to '" .. ws.name .. "'")
    out("`lw publish` to update the shared loomworks.json.")
    return 0
  end
  die("unknown workspace subcommand '" .. tostring(sub) .. "' — use rename")
end

--- True when the published snapshot would carry no shared items.
local function snapshot_empty(ws)
  local snap = ws:_serialize_config_internal()
  local function empty(t) return not t or not next(t) end
  return empty(snap.projects) and empty(snap.configuration_sets) and empty(snap.profiles)
end

--- `lw publish` — regenerate the shared loomworks.json from the working copy.
--- `lw migrate [--check] [-y]` — rewrite the workspace files from a still-valid
--- older shape into the current recommended one. Form changes, meaning does not.
function M.cmd_migrate(root, args)
  local check, yes = false, false
  for _, v in ipairs(args or {}) do
    if v == "--check" then check = true
    elseif v == "-y" or v == "--yes" then yes = true end
  end
  local ws = load_workspace(root, false)
  local migrate = require("loomworks.migrate")
  local plan = migrate.plan(ws)

  for _, skip in ipairs(plan.skipped) do
    out(string.format("skipped  %s/%s", skip.project, skip.item))
    out("         " .. skip.reason)
  end

  if #plan.changes == 0 then
    out(#plan.skipped > 0
      and "nothing to migrate automatically (see skipped above)"
      or "already up to date — nothing to migrate")
    return 0
  end

  -- Always show the rewrites before touching anything.
  out((check and "pending migrations:" or "migrations to apply:"))
  for _, c in ipairs(plan.changes) do
    out(string.format("  %s/%s  [%s]", c.project, c.item, c.rule))
    out("      - " .. c.before)
    out("      + " .. c.after)
  end

  if check then
    -- Signal through the exit status so this works as a CI lint.
    out("")
    out(#plan.changes .. " migration(s) pending; run `lw migrate` to apply")
    return 1
  end

  -- A management write, so it needs explicit consent when it cannot ask.
  if not yes then
    if not interactive() then
      die("refusing to rewrite the workspace files without confirmation.\n"
        .. "  Re-run with -y to apply, or --check to see what is pending.")
    end
    local answer = prompt_line(
      string.format("Rewrite %d configuration(s)? [y/N]", #plan.changes))
    answer = (answer or ""):lower()
    if answer ~= "y" and answer ~= "yes" then
      die("aborted — nothing was written")
    end
  end

  local applied, err = migrate.apply(plan)
  if err then die("migration failed after " .. applied .. " change(s): " .. err) end

  -- The published snapshot is regenerated from the working copy, so a
  -- migration that touches published items rewrites it wholesale.
  local pub_ok, pub_err = ws:publish()
  if not pub_ok then
    die("migrated the working copy, but publishing failed: " .. tostring(pub_err)
      .. "\n  Run `lw publish` once resolved.")
  end
  out("")
  out("migrated " .. applied .. " configuration(s); wrote the working copy and "
    .. "regenerated loomworks.json")
  return 0
end

-- ---------------------------------------------------------------------------
-- Module acquisition
-- ---------------------------------------------------------------------------

--- boot.* is resolvable only on the standalone luvi host (main.lua installs a
--- searcher for it); the nvim-hosted fallback has no bundle. Module management
--- is a standalone-host feature, so fail with that hint rather than a raw
--- require error.
local function require_boot_modules()
  local ok, mods = pcall(require, "boot.modules")
  if not ok then
    die("`lw module` is a feature of the standalone lw binary; it is not "
      .. "available in the nvim-hosted fallback.")
  end
  local host_api = require("loomworks.api_versions").module
  return mods, host_api
end

--- Compact "brings: sdks=a,b progress=c" suffix from an index/meta entry.
local function brings_suffix(brings)
  if type(brings) ~= "table" then return "" end
  local parts = {}
  for _, kind in ipairs({ "sdks", "progress" }) do
    local v = brings[kind]
    if type(v) == "table" and #v > 0 then
      parts[#parts + 1] = kind .. "=" .. table.concat(v, ",")
    end
  end
  return #parts > 0 and ("  (brings " .. table.concat(parts, " ") .. ")") or ""
end

function M.cmd_module_list(args)
  local mods, host_api = require_boot_modules()
  -- The index may be unreachable (offline); still list what is installed.
  local idx = select(1, mods.load_index())
  local rows = mods.status(idx, host_api)
  if not idx then
    out("(module index unavailable — showing installed modules only)")
  end
  if #rows == 0 then
    out(idx and "no modules in the index" or "no modules installed")
    return 0
  end
  for _, r in ipairs(rows) do
    local status
    if r.installed and r.available then
      if r.installed.version == r.available.version then
        status = "installed v" .. r.installed.version
      else
        status = "installed v" .. tostring(r.installed.version)
          .. "  (update: v" .. r.available.version .. ")"
      end
    elseif r.installed then
      status = "installed v" .. tostring(r.installed.version) .. "  (not in index)"
    else
      status = "available v" .. r.available.version
    end
    -- Compatibility is meaningful only against the index's declared api_version.
    local compat = ""
    if r.available and not r.compatible then
      compat = "  [incompatible: needs module api v" .. r.available.api_version .. "]"
    end
    out(string.format("%-16s %s%s", r.name, status, compat))
    if r.description and #r.description > 0 then
      out("                 " .. trunc(r.description, 70))
    end
  end
  return 0
end

function M.cmd_module_install(args)
  local name = args[3]
  if not name then die("usage: lw module install <name>") end
  local force = false
  for i = 4, #args do if args[i] == "--force" then force = true end end

  local mods, host_api = require_boot_modules()
  local idx, ierr = mods.load_index()
  if not idx then die(ierr) end
  local entry, eerr = mods.entry(idx, name)
  if not entry then
    local names = {}
    for n in pairs(idx.modules) do names[#names + 1] = n end
    table.sort(names)
    die(eerr .. (#names > 0 and ("\n  available: " .. table.concat(names, ", ")) or ""))
  end

  -- Interface-version gate, before any download.
  if not mods.compatible(entry, host_api) then
    die(mods.incompatible_reason(entry, host_api))
  end

  -- Already at this exact version? Skip unless forced.
  local installed
  for _, m in ipairs(require("boot.paths").installed_modules()) do
    if m.name == name then installed = m.meta end
  end
  if installed and installed.version == entry.version
      and (installed.sha256 or ""):lower() == entry.sha256:lower() and not force then
    out(name .. " is already installed at v" .. entry.version
      .. " (use --force to reinstall)")
    return 0
  end

  out((installed and "updating " or "installing ") .. name .. " v" .. entry.version .. "…")
  local res, err = mods.install(entry)
  if not res then die("install " .. name .. " failed: " .. err) end
  out("installed " .. res.name .. " v" .. res.version .. brings_suffix(entry.brings))
  return 0
end

function M.cmd_module_update(args)
  local mods, host_api = require_boot_modules()
  local paths = require("boot.paths")

  -- Build the target list: an explicit name, or every installed module for --all.
  local targets = {}
  local all = false
  for i = 3, #args do if args[i] == "--all" then all = true end end
  if all then
    for _, m in ipairs(paths.installed_modules()) do targets[#targets + 1] = m.name end
  elseif args[3] and args[3]:sub(1, 2) ~= "--" then
    targets = { args[3] }
  else
    die("usage: lw module update <name> | --all")
  end
  if #targets == 0 then out("no modules installed"); return 0 end

  local idx, ierr = mods.load_index()
  if not idx then die(ierr) end

  local failed = 0
  for _, name in ipairs(targets) do
    local entry = select(1, mods.entry(idx, name))
    if not entry then
      out("skip  " .. name .. " — no longer in the index")
    elseif not mods.compatible(entry, host_api) then
      -- Skip-and-warn: one stale module must not block the rest.
      out("skip  " .. mods.incompatible_reason(entry, host_api))
    else
      local cur
      for _, m in ipairs(paths.installed_modules()) do
        if m.name == name then cur = m.meta end
      end
      if cur and cur.version == entry.version
          and (cur.sha256 or ""):lower() == entry.sha256:lower() then
        out("ok    " .. name .. " already up to date (v" .. entry.version .. ")")
      else
        local res, err = mods.install(entry)
        if not res then
          out("FAIL  " .. name .. ": " .. err); failed = failed + 1
        else
          out("done  " .. name .. " -> v" .. res.version)
        end
      end
    end
  end
  return failed > 0 and 1 or 0
end

function M.cmd_module_remove(args)
  local name = args[3]
  if not name then die("usage: lw module remove <name>") end
  local mods = require_boot_modules()
  local paths = require("boot.paths")
  local present = false
  for _, m in ipairs(paths.installed_modules()) do
    if m.name == name then present = true end
  end
  if not present then out(name .. " is not installed"); return 0 end
  local ok, err = mods.remove(name)
  if not ok then die("remove " .. name .. " failed: " .. err) end
  out("removed " .. name)
  return 0
end

function M.cmd_module(sub, args)
  if sub == nil or sub == "list" or sub == "ls" then return M.cmd_module_list(args) end
  if sub == "install" or sub == "add" then return M.cmd_module_install(args) end
  if sub == "update" or sub == "upgrade" then return M.cmd_module_update(args) end
  if sub == "remove" or sub == "rm" then return M.cmd_module_remove(args) end
  die("unknown module subcommand '" .. tostring(sub) .. "' — "
    .. "expected list | install | update | remove")
end

function M.cmd_publish(root)
  local ws = load_workspace(root, false)
  local empty = snapshot_empty(ws)
  local ok, err = ws:publish()
  if not ok then die("publish failed: " .. tostring(err)) end
  out("published " .. ws.root .. "/loomworks.json")
  if empty then
    out("")
    io.stderr:write("lw: note: loomworks.json is empty — nothing is marked shared.\n")
    io.stderr:write("    Share items with `lw <project|profile|configuration-set> publish <name>`,\n")
    io.stderr:write("    or create them with --shared (the CLI default). See `lw help publish`.\n")
  end
  return 0
end

--- Mark `item` shared (local+shared) and regenerate loomworks.json. The
--- publishability closure pulls transitive dependencies (a profile's set +
--- projects), so publishing a profile writes everything it needs.
local function publish_item(ws, item, label)
  item._intent = "local+shared"
  local ok, err = ws:publish()
  if not ok then die("publish failed: " .. tostring(err)) end
  out("published " .. label .. " → " .. ws.root .. "/loomworks.json")
  return 0
end

-- ---------------------------------------------------------------------------
-- Shared lookups + small formatting helpers
-- ---------------------------------------------------------------------------

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
-- Projects (add / remove / list / show) — explicit management, user.json
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
  project._intent = created_intent()
  ws:_save_user()
  out(string.format("added project '%s' (%s) at %s  [%s]", key, mtype, store_path or key, project._intent))
  out("")
  if project._intent == "local" then
    out("Working copy only (--local). `lw project publish " .. key .. "` shares it later.")
  else
    out("Map it into a configuration set to build it, then `lw publish` writes it")
    out("to the shared loomworks.json.")
  end
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

--- `lw project rename <old> <new>` — rename a project key in the working copy.
--- Delegates to the same atomic mutation the editor uses (Workspace:rename_project),
--- which propagates the new key to profile mappings and config units and rolls
--- back on save failure. Config-set mappings are object-keyed, so they follow
--- automatically.
function M.cmd_project_rename(root, old_name, new_name)
  if not old_name or not new_name then die("usage: lw project rename <old-name> <new-name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, old_name)
  local ok, err = ws:rename_project(proj, new_name)
  if not ok then die("could not rename project: " .. tostring(err)) end
  out(string.format("renamed project '%s' -> '%s'", old_name, new_name))
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
--- `lw project publish <name>` — mark a project shared and write loomworks.json.
function M.cmd_project_publish(root, name)
  if not name then die("usage: lw project publish <name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, name)
  return publish_item(ws, proj, "project '" .. proj.key .. "'")
end

function M.cmd_project(sub, root, a3, a4, a5)
  if sub == "add" then return M.cmd_project_add(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_project_remove(root, a3) end
  if sub == "rename" or sub == "mv" then return M.cmd_project_rename(root, a3, a4) end
  if sub == "show" then return M.cmd_project_show(root, a3) end
  if sub == "publish" then return M.cmd_project_publish(root, a3) end
  if sub == nil or sub == "list" then return M.cmd_project_list(root) end
  die("unknown project subcommand '" .. tostring(sub) .. "' — use add|remove|rename|list|show|publish")
end

-- ---------------------------------------------------------------------------
-- Configurations (list / add / show / get / set / unset / remove)
-- ---------------------------------------------------------------------------

--- Reconstruct the user-override data table (save_configuration's input shape)
--- from a live Configuration, so set/unset can read-modify-write.
local function config_to_data(cfg)
  local data = {}
  for k, v in pairs(cfg.module_config or {}) do
    -- Values the module propagated from a base are not this config's to
    -- restate: copying them into the edit round-trip would re-declare them
    -- (freezing the base's value), which is exactly what `_derived` prevents
    -- at serialization. The module re-derives them on the next refresh.
    if not (cfg._derived and cfg._derived[k]) then data[k] = v end
  end
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

--- Reject `variant` as a settable field. A configuration becomes concrete by
--- inheriting a base that provides a variant (`inherits: variant:Release`),
--- not by naming one itself: the built-in `variant:*` configurations are the
--- declared source of build types, and a hand-written copy duplicates one with
--- nothing to check it against. Reading a declared `variant` still works, so
--- existing hand-written files keep resolving.
--- @param proj loomworks.Project
--- @param value string|nil the variant the caller tried to set
local function reject_variant_param(proj, value)
  local base = nil
  if type(value) == "string" and value ~= "" then
    -- Point at the base that provides this variant, if one exists.
    for _, c in ipairs(proj:get_configurations()) do
      local mc = c.module_config
      if c:is_auto_gen() and ((mc and mc.variant == value) or c.name == value) then
        base = c.name
        break
      end
    end
  end
  die(table.concat({
    "`variant` is not settable - inherit it instead.",
    "  A configuration becomes concrete by inheriting a base that provides a",
    "  variant, so the build type has a single declared source:",
    "    lw configuration set " .. proj.key .. " <name> inherits "
      .. (base or "variant:<Name>"),
    "  `lw configuration list " .. proj.key .. "` shows the available bases.",
  }, "\n"))
end

--- `lw configuration add <project> <name> [base...]`
--- Trailing arguments are BASES to inherit (e.g. `variant:Release asan`),
--- which is how a configuration becomes concrete — see `reject_variant_param`.
--- Several bases form a mixin chain, merged left to right (later wins), the
--- same order `set … inherits a,b` produces. Each argument may itself be a
--- comma-separated list, so both spellings work.
--- @param bases string[]|string|nil
function M.cmd_configuration_add(root, proj_name, name, bases)
  if not proj_name or not name then
    die("usage: lw configuration add <project> <name> [base...]")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local data = {}

  -- Accept `a b`, `a,b`, and `a, b` alike.
  local wanted = {}
  for _, arg in ipairs(type(bases) == "table" and bases or { bases }) do
    if type(arg) == "string" and arg ~= "" then
      for _, part in ipairs(split_csv(arg)) do wanted[#wanted + 1] = part end
    end
  end

  local resolved = {}
  for _, base in ipairs(wanted) do
    -- Resolve each base up front: an unresolvable `inherits` would otherwise
    -- produce a config that looks created but can never build.
    local target = proj:get_configuration(base)
    if not target then
      -- A bare build type (`Release`) is the likely mistake now that the
      -- variant is inherited rather than named; point at the base providing it.
      local suggestion
      for _, c in ipairs(proj:get_configurations()) do
        local mc = c.module_config
        if c:is_auto_gen() and mc and mc.variant == base then
          suggestion = c.name
          break
        end
      end
      die("no configuration '" .. base .. "' in project '" .. proj.key .. "'"
        .. (suggestion and (" — did you mean '" .. suggestion .. "'?") or ".")
        .. "\n  `lw configuration list " .. proj.key .. "` shows the bases "
        .. "available to inherit.")
    end
    resolved[#resolved + 1] = target.name
  end
  if #resolved == 1 then
    data.inherits = resolved[1]
  elseif #resolved > 1 then
    data.inherits = resolved
  end
  local ok, err = proj:save_configuration(name, data)
  if not ok then die("could not add configuration: " .. tostring(err)) end
  out(string.format("added configuration '%s' to project '%s'%s", name, proj.key,
    #resolved > 0 and ("  (inherits " .. table.concat(resolved, ", ") .. ")") or ""))
  if not data.inherits then
    out("  no base — it is abstract (a mixin) and cannot be built until it")
    out("  inherits one that provides a variant:")
    out("    lw configuration set " .. proj.key .. " " .. name .. " inherits <base>")
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
  if param == "variant" then reject_variant_param(proj, value) end
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
--- `lw configuration publish <project> <name>` — mark a configuration (and its
--- project) shared and write loomworks.json.
function M.cmd_configuration_publish(root, proj_name, cfg_name)
  if not (proj_name and cfg_name) then die("usage: lw configuration publish <project> <name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, false)
  -- A configuration can't be published without its project.
  if proj._intent == "local" or proj._intent == nil then proj._intent = "local+shared" end
  return publish_item(ws, cfg, "configuration '" .. proj.key .. ":" .. cfg.name .. "'")
end

function M.cmd_configuration(sub, root, a3, a4, a5, a6, argv)
  if sub == nil or sub == "list" then return M.cmd_configuration_list(root, a3) end
  if sub == "add" then
    -- Bases are variadic: everything after <project> <name>. argv is
    -- { "configuration", sub, project, name, base... }.
    local bases = {}
    for i = 5, #(argv or {}) do bases[#bases + 1] = argv[i] end
    if #bases == 0 and a5 then bases[1] = a5 end
    return M.cmd_configuration_add(root, a3, a4, bases)
  end
  if sub == "show" then return M.cmd_configuration_show(root, a3, a4) end
  if sub == "get" then return M.cmd_configuration_get(root, a3, a4, a5) end
  if sub == "set" then return M.cmd_configuration_set(root, a3, a4, a5, a6) end
  if sub == "unset" then return M.cmd_configuration_unset(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_configuration_remove(root, a3, a4) end
  if sub == "publish" then return M.cmd_configuration_publish(root, a3, a4) end
  die("unknown configuration subcommand '" .. tostring(sub) ..
    "' — use list|add|show|get|set|unset|remove|publish")
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
  cs._intent = created_intent()
  ws:_save_user()
  out("created configuration set '" .. cs.name .. "'  [" .. cs._intent .. "]" ..
    (next(raw) and "" or " (empty)"))
  if not next(raw) then
    out("  add mappings: lw configuration-set map " .. cs.name .. " <project> <config>")
  end
  if cs._intent == "local" then
    out("`lw configuration-set publish " .. cs.name .. "` shares it. ")
  end
  out("`lw profile create " .. cs.name .. " <tool>` to build it.")
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
--- `lw configuration-set publish <name>` — mark a set shared and write
--- loomworks.json (pulls its mapped projects + configs via the closure).
function M.cmd_cset_publish(root, name)
  if not name then die("usage: lw configuration-set publish <name>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  return publish_item(ws, cs, "configuration set '" .. cs.name .. "'")
end

function M.cmd_cset(sub, root, args)
  if sub == nil or sub == "list" then return M.cmd_cset_list(root) end
  if sub == "show" then return M.cmd_cset_show(root, args[3]) end
  if sub == "create" then return M.cmd_cset_create(root, args) end
  if sub == "map" then return M.cmd_cset_map(root, args[3], args[4], args[5]) end
  if sub == "unmap" then return M.cmd_cset_unmap(root, args[3], args[4]) end
  if sub == "remove" or sub == "rm" then return M.cmd_cset_remove(root, args[3]) end
  if sub == "publish" then return M.cmd_cset_publish(root, args[3]) end
  die("unknown configuration-set subcommand '" .. tostring(sub) ..
    "' — use list|show|create|map|unmap|remove|publish")
end

--- `lw profile select` — interactive picker that sets the active profile.
--- Writes user.json (explicit management).
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
  -- Profiles default to `local`: the toolchains they pin were resolved on
  -- this machine, so publishing one by default would push a build environment
  -- into the shared contract that other machines may not have.
  profile._intent = created_intent("local")
  if activate then profile:activate() else ws:_save_user() end

  out((existed and "profile already exists: " or "created profile: ") .. profile.key ..
    "  [" .. profile._intent .. "]" .. (activate and "  (active)" or ""))
  local ok, reasons = true, nil
  if profile.is_valid then ok, reasons = profile:is_valid() end
  if not ok then out("  not yet buildable: " .. table.concat(reasons or {}, "; ")) end
  if profile._intent == "local" then
    out("`lw profile publish " .. profile.key .. "` shares it (pulls its set + projects).")
  else
    out("`lw publish` writes it to loomworks.json (with its set + projects)" ..
      (activate and "" or "; `lw profile select` or --activate to activate") .. ".")
  end
  return 0
end

--- `lw profile publish <key>` — mark a profile shared and write loomworks.json
--- (pulls its configuration set + projects via the closure).
function M.cmd_profile_publish(root, name)
  if not name then die("usage: lw profile publish <key>") end
  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, name)
  return publish_item(ws, profile, "profile '" .. profile.key .. "'")
end

--- `lw profile <list|select|create|publish|target>`
--- `lw profile target <profile> [<target>|--clear]` — show, set, or clear a
--- profile's default launch target. With no target name,
--- prints the current default. Resolves a build target or command launch
--- config the same way `lw run` does (parsing targets on demand — build the
--- profile first so its build targets are known).
function M.cmd_profile_target(root, args)
  -- args: { "profile", "target", <profile>, <target?>, flags… }
  local pos, scope, clear, kind, working_dir = {}, nil, false, nil, nil
  local i = 3
  while args[i] do
    if args[i] == "--clear" then clear = true; i = i + 1
    elseif args[i] == "--project" then scope = args[i + 1]; i = i + 2
    elseif args[i] == "--target" then kind = "target"; i = i + 1
    elseif args[i] == "--launch" then kind = "launch"; i = i + 1
    elseif args[i] == "--cwd" or args[i] == "--working-dir" then working_dir = args[i + 1]; i = i + 2
    else pos[#pos + 1] = args[i]; i = i + 1 end
  end
  local profile_name, target_name = pos[1], pos[2]
  if not profile_name then
    die("usage: lw profile target <profile> [<target>|--clear]")
  end

  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, profile_name)

  if clear then
    profile:clear_default_target()
    out("cleared default target for profile '" .. profile.key .. "'")
    return 0
  end

  if not target_name then
    if not profile:has_default_target_override() then
      out("profile '" .. profile.key .. "' has no default target set.")
      return 0
    end
    local lt = profile:default_target()
    if not lt then
      out("default target for '" .. profile.key .. "': (set but unresolved — build the profile?)")
      return 0
    end
    out("default target for '" .. profile.key .. "': " .. tostring(lt))
    if lt:is_module_target() then
      out("  working dir: " .. (lt:working_directory() or "?") ..
        (lt:has_working_dir_override() and "" or "  (default: project dir)"))
    end
    return 0
  end

  -- Resolve <target> to a candidate (same rules as `lw run`).
  local bare = target_name
  if not scope then
    local pfx, rest = target_name:match("^([^:]+):(.+)$")
    if pfx and profile:project(pfx) then scope, bare = pfx, rest end
  end
  local all = launchable_targets(ws, profile)
  local matches = {}
  for _, c in ipairs(all) do
    if c.name == bare and (not scope or c.project.key == scope)
      and (not kind or c.kind == kind) then matches[#matches + 1] = c end
  end
  if #matches == 0 then
    local labels = {}
    for _, c in ipairs(all) do labels[#labels + 1] = fmt_cand(c) end
    die("no launch target '" .. target_name .. "' in profile '" .. profile.key .. "'.\n" ..
      "  available: " .. (next(labels) and table.concat(labels, ", ")
        or "(none — build the profile so its targets are known)"))
  elseif #matches > 1 then
    local labels = {}
    for _, c in ipairs(matches) do labels[#labels + 1] = fmt_cand(c) end
    die("'" .. target_name .. "' is ambiguous: " .. table.concat(labels, ", ") ..
      "\n  qualify with `--target`/`--launch`, `--project <key>`, or `<project>:<name>`.")
  end

  local c = matches[1]
  if c.kind == "target" then
    profile:set_default_target(c.project, c.target_id, nil, working_dir)
  else
    if working_dir then
      out("note: --cwd is ignored for a command launch config — set its " ..
        "working_dir on the launch config itself (`lw launch add … --working-dir`).")
    end
    profile:set_default_target(c.project, nil, c.name)
  end
  out("default target for '" .. profile.key .. "' set to " .. fmt_cand(c))
  local lt = profile:default_target()
  if lt and lt:is_module_target() then
    out("  working dir: " .. (lt:working_directory() or "?") ..
      (lt:has_working_dir_override() and "" or "  (default: project dir)"))
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- SDKs (user-declared toolchain installations)
-- ---------------------------------------------------------------------------

--- SDK providers shipped with core. The registry discovers providers by
--- scanning runtimepath, which only exists under the editor host — the
--- standalone runner has no runtimepath (and no plugin ecosystem), so these are
--- probed directly as a fallback.
local CORE_SDK_PROVIDERS = { "cpp_compiler" }

--- Provider ids available on this host (core + any plugin-supplied).
local function sdk_provider_ids()
  local ok, registry = pcall(require, "loomworks.sdks")
  if not ok then return {} end
  local ids, seen = {}, {}
  -- Editor host: runtimepath discovery finds core + plugin providers.
  local ok_list, listed = pcall(registry.list)
  if ok_list and type(listed) == "table" then
    for _, id in ipairs(listed) do
      if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
  end
  for _, id in ipairs(CORE_SDK_PROVIDERS) do
    if not seen[id] and registry.get(id) then seen[id] = true; ids[#ids + 1] = id end
  end
  table.sort(ids)
  return ids
end

--- `lw sdk <types|list|add|remove>` — declare toolchain installations that
--- auto-detection cannot find (a compiler at an arbitrary path, a
--- cross-compiler). A declared SDK produces a kit, so it shows up in
--- `lw tools` and can be pinned by `lw profile create`.
function M.cmd_sdk(sub, root, args)
  local ids = sdk_provider_ids()

  if sub == "types" then
    if #ids == 0 then out("(no SDK providers available)"); return 0 end
    for _, id in ipairs(ids) do out("  " .. id) end
    return 0
  end

  if sub == nil or sub == "list" then
    local ws = load_workspace(root, false)
    local sdks = ws._sdks or {}
    if #sdks == 0 then
      out("(no SDKs declared — `lw sdk add <type> <path>`)")
      return 0
    end
    for _, sdk in ipairs(sdks) do
      out(string.format("  %-42s %s", sdk.key, sdk._path or "?"))
    end
    return 0
  end

  if sub == "add" then
    -- args: { "sdk", "add", <type>, <path>, flags… }
    local pos, force, family, version = {}, false, nil, nil
    local i = 3
    while args[i] do
      if args[i] == "--force" then force = true; i = i + 1
      elseif args[i] == "--family" then family = args[i + 1]; i = i + 2
      elseif args[i] == "--version" then version = args[i + 1]; i = i + 2
      else pos[#pos + 1] = args[i]; i = i + 1 end
    end
    local sdk_type, path = pos[1], pos[2]
    if not (sdk_type and path) then
      die("usage: lw sdk add <type> <path> [--force [--family <f>] [--version <v>]]\n" ..
        "  types: " .. (next(ids) and table.concat(ids, ", ") or "(none)"))
    end
    local abs = resolve_abs(path, user_cwd()) or resolve_abs_out(path, user_cwd())
    local ws = load_workspace(root, false)
    local sdk, err = ws:add_sdk(sdk_type, abs,
      { force = force, family = family, version = version })
    if not sdk then die("could not add SDK: " .. tostring(err)) end
    out("declared SDK: " .. sdk.key)
    out("  path: " .. (sdk._path or abs))
    if force then
      out("  (registered with --force — it did not identify itself; version-based")
      out("   selection is unavailable, pin it by its full key)")
    end
    out("")
    out("It provides a toolchain — `lw tools` lists it, then:")
    out("  lw profile create <config-set> " .. sdk.key)
    return 0
  end

  if sub == "remove" or sub == "rm" then
    local key = args[3]
    if not key then die("usage: lw sdk remove <key>  (`lw sdk list` shows keys)") end
    local ws = load_workspace(root, false)
    if not ws:remove_sdk(key) then
      die("no SDK with key '" .. key .. "'. Run `lw sdk list`.")
    end
    out("removed SDK '" .. key .. "'")
    return 0
  end

  die("unknown sdk subcommand '" .. tostring(sub) .. "' — use types|list|add|remove")
end

--- `lw profile remove <profile>` — drop a profile from the working copy.
--- Removes user intent only; build directories are left alone (`lw clean` /
--- the editor's delete plan handle artifacts).
function M.cmd_profile_remove(root, args)
  local name = args[3]
  if not name then die("usage: lw profile remove <profile>") end
  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, name)
  local key = profile.key
  local ok, err = ws:remove_profile(profile)
  if not ok then die("could not remove profile: " .. tostring(err)) end
  out("removed profile '" .. key .. "'")
  out("  build directories were left in place (`lw clean` removes artifacts).")
  out("`lw publish` to update the shared loomworks.json.")
  return 0
end

--- `lw profile query <profile> <project> <field>` — print a single machine-
--- readable fact about a project within a resolved profile. Read-only
--- introspection for scripting (e.g. locating CI artifacts). Fields:
--- build-dir | config | state | tool.
function M.cmd_profile_query(root, args)
  -- args: { "profile", "query", <profile>, <project>, <field> }
  local profile_name, project_key, field = args[3], args[4], args[5]
  if not (profile_name and project_key and field) then
    die("usage: lw profile query <profile> <project> <field>\n" ..
      "  fields: build-dir | config | state | tool")
  end
  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, profile_name)

  local pp, projects = nil, {}
  for _, p in ipairs(profile:projects()) do
    projects[#projects + 1] = p:project_key()
    if p:project_key() == project_key then pp = p end
  end
  if not pp then
    table.sort(projects)
    die("project '" .. project_key .. "' is not mapped in profile '" .. profile.key ..
      "'. Projects: " .. (next(projects) and table.concat(projects, ", ") or "(none)"))
  end

  local value
  if field == "build-dir" then
    value = pp:build_dir()
    if not value or value == "" then
      die("build dir not resolved for '" .. project_key .. "' in '" .. profile.key ..
        "' — the profile is incomplete or unbuildable (`lw profiles`).")
    end
    value = value:gsub("\\", "/")
  elseif field == "config" then
    value = pp:variant_name()
  elseif field == "state" then
    value = pp:status()
  elseif field == "tool" then
    local t = pp:tool_object()
    value = t and t.key or ""
  else
    die("unknown field '" .. field .. "' — use build-dir | config | state | tool")
  end
  out(value or "")
  return 0
end

function M.cmd_profile(sub, root, args)
  if sub == "select" then
    return M.select_profile(load_workspace(root, false))
  end
  if sub == "create" then
    return M.cmd_profile_create(root, args)
  end
  if sub == "query" then
    return M.cmd_profile_query(root, args)
  end
  if sub == "remove" or sub == "rm" then
    return M.cmd_profile_remove(root, args)
  end
  if sub == "publish" then
    return M.cmd_profile_publish(root, args[3])
  end
  if sub == "target" then
    return M.cmd_profile_target(root, args)
  end
  if sub == nil or sub == "list" then
    return M.cmd_profiles(load_workspace(root))
  end
  die("unknown profile subcommand '" .. tostring(sub) ..
    "' — use list|select|create|remove|publish|target|query")
end

--- The value a config key falls back to when unset, so `lw config get` can
--- report it. Only keys with a discoverable built-in default are listed.
--- @param key string
--- @return string|nil
local function effective_config_default(key)
  if key == "release-url" then
    local ok, update = pcall(require, "boot.update")
    if ok and update.DEFAULT_RELEASE_URL then
      return os.getenv("LOOMWORKS_RELEASE_URL") or update.DEFAULT_RELEASE_URL
    end
    return os.getenv("LOOMWORKS_RELEASE_URL")
  end
  return nil
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
    if cfg[key] ~= nil then out(tostring(cfg[key])); return 0 end
    -- Unset keys still have an effective value; print it so a setting like the
    -- release URL is discoverable from the CLI instead of reading the source.
    local eff = effective_config_default(key)
    out(eff and ("(unset — using default: " .. eff .. ")") or "(unset)")
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
    -- The active profile's default launch target (what `lw run <profile>` runs
    -- with no target named). Descriptor-based, so it shows without a build.
    local ok_lt, lt = pcall(function() return ap:default_target() end)
    if ok_lt and lt then
      local line = "Default target   " .. lt:describe()
      if lt:is_module_target() then
        local cwd = lt:working_directory()
        if cwd then line = line .. "   cwd: " .. trunc(cwd, 34) end
      end
      out(line)
    else
      out("Default target   (none) — `lw profile target " .. trunc(ap.key, 26) .. " <target>`")
    end
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

--- Human-readable age, e.g. "45s", "12m", "3h", "2d".
local function human_age(secs)
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then return math.floor(secs / 60) .. "m" end
  if secs < 86400 then return math.floor(secs / 3600) .. "h" end
  return math.floor(secs / 86400) .. "d"
end

--- `lw tools [--cached]` — list detected toolchains, grouped by module.
--- Default: a full scan (and it refreshes the machine-level cache). --cached:
--- read the cached result instantly (with its age) instead of probing.
function M.cmd_tools(root, args)
  local cached = false
  for _, v in ipairs(args or {}) do if v == "--cached" then cached = true end end
  tool_cache_mode = cached and "cached" or "force"

  if cached then
    local c = read_tool_cache()
    if not c then
      out("(no cached tools — run `lw tools` to scan)")
      return 0
    end
    out(string.format("(cached %s ago — `lw tools` to rescan)",
      human_age(os.time() - (c.timestamp or os.time()))))
  end

  local ws = load_workspace(root) -- served from cache or scanned per the mode
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
-- Shell completion
-- ---------------------------------------------------------------------------

--- Load a workspace for completion — tolerant (nil on any problem) and quiet.
local function comp_ws(root)
  if not root then return nil end
  return load_workspace(root, false)
end

--- Sorted, de-duplicated list.
local function sorted_unique(t)
  local seen, out_list = {}, {}
  for _, v in ipairs(t) do
    if v and v ~= "" and not seen[v] then seen[v] = true; out_list[#out_list + 1] = v end
  end
  table.sort(out_list)
  return out_list
end

local function comp_project_names(ws)
  local t = {}
  if ws then for _, p in pairs(ws._projects or {}) do t[#t + 1] = p.key end end
  return sorted_unique(t)
end

local function comp_set_names(ws)
  local t = {}
  if ws then for _, cs in ipairs(ws._config_sets or {}) do t[#t + 1] = cs.name end end
  return sorted_unique(t)
end

local function comp_profile_names(ws)
  local t = {}
  if ws then for _, p in ipairs(ws._profiles or {}) do t[#t + 1] = p.key end end
  return sorted_unique(t)
end

--- Launch config names across all projects (optionally one project).
local function comp_launch_names(ws, project_key)
  local t = {}
  if ws then
    for _, p in pairs(ws._projects or {}) do
      if (not project_key or p.key == project_key) and type(p.launch) == "table" then
        for n in pairs(p.launch) do t[#t + 1] = n end
      end
    end
  end
  return sorted_unique(t)
end

--- Configuration names for a project (canonical + base names, incl. auto-gens).
local function comp_config_names(ws, project_key)
  local t = {}
  if ws and project_key then
    for _, p in pairs(ws._projects or {}) do
      if p.key == project_key then
        for _, c in ipairs(p:get_configurations()) do
          t[#t + 1] = c.name
          if c.base_name and c.base_name ~= c.name then t[#t + 1] = c.base_name end
        end
        break
      end
    end
  end
  return sorted_unique(t)
end

--- Tool keys straight from the machine cache (no scan — instant).
local function comp_tool_keys()
  local c = read_tool_cache()
  local t = {}
  if c and c.tools_by_type then
    for _, list in pairs(c.tools_by_type) do
      for _, e in ipairs(list) do if e.tool_key then t[#t + 1] = e.tool_key end end
    end
  end
  return sorted_unique(t)
end

local COMP_COMMANDS = {
  "status", "init", "project", "configuration", "configuration-set", "cfg", "cs",
  "profiles", "profile", "tools", "build", "clean", "test", "run", "launch", "publish",
  "unlock", "config", "completion", "version", "install", "self-update", "help", "sdk",
  "migrate", "module", "--no-input",
}

--- `lw __complete <cword> <word0..N>` — emit newline-separated candidates for
--- the token at `cword` (0-based into the COMP_WORDS passed after it). A lone
--- `__dirs__` / `__files__` line tells the shell to do path completion.
--- Never blocks (non-interactive) and never errors out (tolerant loads).
function M.cmd_complete(cword, words)
  force_noninteractive = true
  completion_mode = true
  cword = tonumber(cword) or 0
  -- Completed tokens before the cursor, excluding the "lw" at words[1].
  local a = {}
  for i = 2, cword do a[#a + 1] = words[i] or "" end
  local n = #a
  local function emit(list) for _, c in ipairs(list) do out(c) end end
  local function has(set, v) for _, x in ipairs(set) do if x == v then return true end end end

  if n == 0 then emit(COMP_COMMANDS); return 0 end

  local cmd, sub = a[1], a[2]
  local root = find_root(os.getenv("LW_ROOT"))

  if cmd == "help" then
    if n == 1 then
      local topics = {}
      for _, v in ipairs(COMP_COMMANDS) do topics[#topics + 1] = v end
      topics[#topics + 1] = "agent" -- help-only topics (no command)
      topics[#topics + 1] = "ci"
      emit(topics)
    end
    return 0
  elseif cmd == "tools" then
    if n == 1 then emit({ "--cached" }) end
    return 0
  elseif cmd == "config" then
    if n == 1 then emit({ "list", "get", "set", "unset" }) end
    if n == 2 and has({ "get", "set", "unset" }, sub) then
      emit({ "dev-lua", "default-source", "release-url", "module-index" })
    end
    return 0
  elseif cmd == "build" or cmd == "test" or cmd == "clean" then
    if n == 1 then
      local ws = comp_ws(root)
      local names = comp_profile_names(ws)
      for _, s in ipairs(comp_set_names(ws)) do names[#names + 1] = s end -- onboarding form
      emit(sorted_unique(names))
    end
    return 0
  elseif cmd == "unlock" then
    if n == 1 then
      local names = comp_profile_names(comp_ws(root)); names[#names + 1] = "--all"
      emit(sorted_unique(names))
    end
    return 0
  elseif cmd == "run" then
    if n == 1 then
      emit(comp_profile_names(comp_ws(root)))                    -- <profile>
    elseif n == 2 then
      emit(sorted_unique(comp_launch_names(comp_ws(root))))      -- [target] (launch configs;
                                                                 -- build targets need a build)
    end
    return 0
  elseif cmd == "launch" then
    if n == 1 then emit({ "list", "add", "set", "show", "remove" }); return 0 end
    if n == 2 and has({ "add", "set", "show", "remove", "rm", "list" }, sub) then
      emit(comp_project_names(comp_ws(root))); return 0                     -- <project>
    end
    if n == 3 and has({ "set", "show", "remove", "rm" }, sub) then
      emit(comp_launch_names(comp_ws(root), a[3]))                         -- <name>
    end
    return 0
  elseif cmd == "project" then
    if n == 1 then emit({ "add", "remove", "rm", "list", "show", "publish" }); return 0 end
    if sub == "add" then
      if n == 2 then out("__dirs__") -- <path>
      elseif n == 3 then emit(require("loomworks.modules").list()) end -- [type]
    elseif (sub == "remove" or sub == "rm" or sub == "show" or sub == "publish") and n == 2 then
      emit(comp_project_names(comp_ws(root)))
    end
    return 0
  elseif cmd == "profile" then
    if n == 1 then emit({ "list", "select", "create", "publish", "target" }); return 0 end
    if sub == "create" then
      if n == 2 then emit(comp_set_names(comp_ws(root)))       -- <config-set>
      elseif n >= 3 then                                       -- [tool ...] / --activate
        local list = comp_tool_keys(); list[#list + 1] = "--activate"; emit(list)
      end
    elseif sub == "publish" and n == 2 then
      emit(comp_profile_names(comp_ws(root)))                  -- <key>
    elseif sub == "target" then
      if n == 2 then emit(comp_profile_names(comp_ws(root)))   -- <profile>
      elseif n == 3 then emit(sorted_unique(comp_launch_names(comp_ws(root)))) -- [target]
      end
    end
    return 0
  elseif cmd == "configuration" or cmd == "cfg" then
    if n == 1 then emit({ "list", "add", "show", "get", "set", "unset", "remove", "publish" }); return 0 end
    if n == 2 then emit(comp_project_names(comp_ws(root))); return 0 end -- <project>
    if n == 3 and has({ "show", "get", "set", "unset", "remove", "publish" }, sub) then
      emit(comp_config_names(comp_ws(root), a[3])); return 0            -- <config>
    end
    if n == 4 and has({ "get", "set", "unset" }, sub) then
      emit({ "variant", "inherits", "languages", "toolchain", "generator",
        "options.", "variables." })                                     -- <param>
    end
    return 0
  elseif cmd == "configuration-set" or cmd == "cs" then
    if n == 1 then emit({ "list", "show", "create", "map", "unmap", "remove", "publish" }); return 0 end
    if n == 2 and has({ "show", "map", "unmap", "remove", "publish" }, sub) then
      emit(comp_set_names(comp_ws(root))); return 0                      -- <name>
    end
    if n == 3 and (sub == "map" or sub == "unmap") then
      emit(comp_project_names(comp_ws(root))); return 0                  -- <project>
    end
    if n == 4 and sub == "map" then
      emit(comp_config_names(comp_ws(root), a[4]))                       -- <config>
    end
    return 0
  elseif cmd == "module" or cmd == "mod" then
    if n == 1 then emit({ "list", "install", "update", "remove" }); return 0 end
    -- update/remove operate on what is installed — complete from disk (offline,
    -- fast). install takes an index name; that needs a network fetch, so leave
    -- it to the user rather than stall the shell.
    if n == 2 and has({ "update", "remove", "rm", "upgrade" }, sub) then
      local ok, paths = pcall(require, "boot.paths")
      if ok then
        local names = {}
        for _, m in ipairs(paths.installed_modules()) do names[#names + 1] = m.name end
        if sub == "update" or sub == "upgrade" then names[#names + 1] = "--all" end
        emit(sorted_unique(names))
      end
    end
    return 0
  end
  return 0
end

--- `lw completion <bash|zsh>` — print a completion script to source/eval. It
--- writes nothing itself; enable with `eval "$(lw completion bash)"`.
function M.cmd_completion(shell)
  shell = shell or "bash"
  if shell == "bash" or shell == "zsh" then
    if shell == "zsh" then
      out("autoload -U +X bashcompinit && bashcompinit")
    end
    out([[# loomworks (lw) completion. Enable with:  eval "$(lw completion ]] .. shell .. [[)"
_lw_complete() {
  local reply
  reply=$(LW_NO_INPUT=1 lw __complete "$COMP_CWORD" "${COMP_WORDS[@]}" 2>/dev/null)
  reply=${reply//$'\r'/}   # strip CR: lw's stdout is CRLF on Windows
  case "$reply" in
    __dirs__)  COMPREPLY=( $(compgen -d -- "${COMP_WORDS[COMP_CWORD]}") ); return ;;
    __files__) COMPREPLY=( $(compgen -f -- "${COMP_WORDS[COMP_CWORD]}") ); return ;;
  esac
  local IFS=$'\n'
  COMPREPLY=( $(compgen -W "$reply" -- "${COMP_WORDS[COMP_CWORD]}") )
}
complete -F _lw_complete lw]])
    return 0
  end
  die("unknown shell '" .. tostring(shell) .. "' — use bash or zsh")
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
  tools = [[lw tools [--cached]

List the toolchains detected on this machine, grouped by module (cmake,
meson, …). Each row is a tool key, its label, and the languages it provides.
Tools are scanned per workspace module, so a module only appears once a
project uses it. Pin one in a profile with `lw profile create <set> <tool>`;
version prefixes match (ninja-clang-19 -> ninja-clang-19.1.5).

Probing compilers/vcvarsall is slow, so the result is cached
(~/.cache/loomworks/tools.json). `lw tools` always does a real scan and
refreshes that cache; other commands (profile create, profiles) read it.
  --cached   print the cached result instantly (with its age); don't scan.
Installed a new compiler? run `lw tools` to refresh.]],
  build = [[lw build [profile | config-set] [-- <build-tool args>]

Args after `--` are forwarded to the BUILD tool (not to configure), e.g.
`lw build Debug:ninja-gcc-14 -- -j 4` to cap parallelism in CI.

Build a profile's projects. Interactively, with no profile given, it uses the
active profile (user.json), else the only profile. With NO profile yet, it
onboards one: pick a configuration set, choose a tool, and it creates +
activates the profile, then builds — so a freshly-cloned project goes from
`lw build` to building. `lw build <config-set>` does the same for a named set.

In non-interactive mode (--no-input / LW_NO_INPUT / CI, or piped stdin) the
active profile is NOT used and nothing is created — pass a profile explicitly
for a deterministic build (§16.9). The CI pattern is:
  lw profile create <set> <tool> --activate  &&  lw build

  profile     e.g. Debug:ninja-clang-19  (a unique substring works too; major
              pins resolve to the installed patch version)
  config-set  a set name; onboards a profile for it (interactive)

Configures first if the build dir isn't configured, then builds. Non-zero
exit on any failure. Artifacts land under
.nvim/build/<project>/<tool>/<config>/ — a separate build dir per toolchain.]],
  clean = [[lw clean [profile | config-set]

Run each project's build-system clean on the profile's build directories
(cmake -> `cmake --build <dir> --target clean`; meson -> `meson compile
--clean`). Removes build artifacts but KEEPS the configuration — a later
`lw build` reconfigures only if something changed. Build dirs that were never
created are skipped. Non-zero exit on any failure.

Profile resolution matches `lw build` (a unique substring works; --no-input
requires an explicit profile). To remove a build directory entirely rather than
just its artifacts, delete `.nvim/build/<project>/<tool>/<config>/`.]],
  unlock = [[lw unlock <profile> | --all

Force-remove build-directory locks. loomworks serializes configure/build/clean
on a build dir across processes (editor + CLI) with an advisory lockfile
(spec §16.6); a crashed process's lock is normally reclaimed automatically once
its heartbeat goes stale (~20s). Use `unlock` to clear one immediately.

  <profile>   clear locks on that profile's build dirs
  --all       clear locks on every profile's build dirs

Warns (on stderr) before clearing a lock that still looks active — meaning a
build may really be running elsewhere.]],
  run = [[lw run <profile> [target] [-- prog-args…]

Resolve a profile and a launch target, then build -> deploy -> execute (spec
§16.17). The target is EITHER a build target (its executable) OR a command
launch configuration declared with `lw launch add`; variables are expanded in
the profile's context. The launched process's exit code becomes lw's exit
code; output streams through.

  profile      required (a unique substring works), like `lw build`.
  target       which target to launch. Omit to use the profile's DEFAULT
               target (`lw profile target`); if none is set and exactly one
               target is in scope, that one runs, else it errors.
  --cwd <dir>  working directory for this run (absolute or workspace-root-
               relative, variable-expanded). Overrides the target's stored /
               default working dir just for this invocation. Default: the
               owning project's directory.
  -- args…     everything after `--` is forwarded verbatim to the program
               (a command config's own declared args come first). Required to
               pass args, so a target name is never mistaken for one.

Disambiguating a name present more than once:
  <project>:<target>     scope to a project
  --project <key>        same, as a flag
  --target | --launch    force the kind when a build target and a launch
                         config share a name in one project

Deploy steps declared on the target run before launch. Debug (DAP) and device
launches are editor-only.]],
  launch = [[lw launch <list|add|show|remove>

Define and manage a project's launch configurations (the runners `lw run`
executes). A launch config is either **command-type** (a command, args, working
dir, env — all variable-expanded: ${build_dir}, ${variant}, project variables…)
or **target-backed** (`--from-target`): it runs a build target's executable
with the build-tree run environment (DLL paths) set up automatically, and your
args/env/working-dir layered on top — no hand-written path.

  list [project]
        List launch configs (all projects, or one).
  add <project> <name> <command> [args…] [--working-dir D] [--env K=V]
        Declare a command-type launch config. Repeat --env for more variables.
        e.g. lw launch add app serve node server.js --env PORT=8080
  add <project> <name> --from-target <target> [args…] [--working-dir D] [--env K=V]
        Declare a target-backed launch config from a build target (by name).
        e.g. lw launch add app run --from-target app --working-dir . --env FOO=bar
  set <project> <name> [flags]   Modify an existing config in place (only the
        given fields change). Flags:
          --working-dir D | --clear-working-dir
          --env K=V (add/update, repeat) | --unset-env K (remove, repeat)
          --command C | --from-target T   (switch kind)
          trailing args replace the arg list | --clear-args
        e.g. lw launch set app run --env PORT=9090 --unset-env FOO --working-dir .
  show <project> <name>       Detail one config.
  remove <project> <name>     Delete one config.

Configs live in the project's working copy; they reach loomworks.json when the
project is published (`lw project publish <project>`).]],
  test = [[lw test [profile | config-set] [--junit <file>] [-- runner-args…]

Build a profile, then run its tests through each module's NATIVE runner (cmake
-> ctest, meson -> `meson test`), streaming output and reporting a REAL exit
code: 0 iff the build succeeded and every runner passed, non-zero otherwise
(spec §16.16). A profile whose modules expose no test runner reports "no tests"
and exits 0 — not a failure.

Profile resolution and onboarding match `lw build`: interactively it can create
a profile from a configuration set; in --no-input / CI it needs an explicit
profile (`lw profile create <set> <tool> --activate && lw test`).

  profile        e.g. Debug:ninja-clang-19  (unique substring works)
  config-set     a set name (interactive: onboards a profile, then tests)
  --junit <file> Write JUnit XML for CI reporters. ctest maps to
                 --output-junit; meson's fixed testlog is copied here. One file
                 per invocation; when a profile runs several test units a label
                 suffix is inserted (report.xml -> report.app-Debug.xml).
  -- args…       Everything after `--` is forwarded to the native batch runner,
                 e.g. `-- -j 4` (ctest) or `-- --num-processes 4` (meson).

CI example (JUnit + 4-way parallel ctest):
  lw --no-input test Debug:ninja-gcc-12 --junit results.xml -- -j 4]],
  init = [[lw init [--name <name>]

Initialize the workspace working copy (.nvim/loomworks.user.json). The shared
loomworks.json is written later by `lw publish` (working-copy model). Fails if
the workspace already exists.

  --name <name>   Set the workspace display name. Defaults to the directory
                  basename — set this when the directory name isn't the name
                  you want published (e.g. a git worktree). Change it later
                  with `lw workspace rename <name>`.

Add `.nvim/` to the repo's .gitignore: it holds the working copy, the cache and
the build trees — all machine-local. Only loomworks.json is committed. (A
personal global gitignore can hide this from whoever sets the project up, while
every teammate and CI runner still sees it untracked.)]],
  workspace = [[lw workspace [rename <name>]   (alias: ws)

Workspace-level settings, stored in the working copy.

  (no args)        Print the current workspace name.
  rename <name>    Set the workspace display name. `lw publish` then writes it
                   to the shared loomworks.json. The name defaults to the
                   directory basename when never set.]],
  migrate = [[lw migrate [--check] [-y]

Rewrite the workspace files from a still-valid older shape into the current
recommended one. Form changes, meaning does not: a migrated workspace resolves
to the same projects, configurations, options and build types as before. Safe
to re-run — an already-migrated workspace reports nothing pending.

Every rewrite is printed as its before/after before anything is written, and
applying asks for confirmation (-y to skip; required when not on a terminal).
Because loomworks.json is regenerated from the working copy, a migration that
touches published items rewrites that file wholesale rather than patching it.

  --check    report what is pending and exit non-zero if anything is —
             use it as a CI lint so files don't drift back
  -y         apply without asking

Cases a rule cannot rewrite without risking a behaviour change are reported
and left alone, never guessed at.

Rules:
  variant-inherits   A configuration declares its build type by INHERITING a
                     base that provides it (`inherits: variant:Release`), not
                     by naming it (`variant: Release`), so the build type has
                     one declared source. Rewrites the old shape onto the
                     matching `variant:*` base. Skips a variant no
                     configuration provides, and a chain where adding the base
                     could change which option wins.]],
  module = [[lw module <sub>   (alias: mod)

Acquire third-party modules for the standalone lw host. Modules ship as
separate plugins; this installs them so `lw` can build their project types
(e.g. harmony / OpenHarmony). Standalone-host only — under the nvim-hosted
fallback, install the module through your plugin manager instead.

  list                 Available (from the index) and installed modules, with
  (or no subcommand)   their versions and whether each is compatible with this
                       lw. Works offline, showing installed modules only.
  install <name>       Download, verify, and install a module.
     --force             reinstall even if already at the index version
  update <name>        Update one module to the version the index records.
  update --all         Update every installed module; a module the index lists
                       as incompatible with this lw is skipped with a note
                       rather than failing the run.
  remove <name>        Uninstall a module.

Trust: the index lists, for each module, where to fetch it and the SHA-256 of
that artifact. The download is verified against that hash before anything is
installed; a mismatch installs nothing. The index is trusted because it comes
from the loomworks repository over HTTPS — override it (offline mirror / a fork)
with `lw config set module-index <url-or-path>` or LOOMWORKS_MODULE_INDEX.

Modules install under the lw data dir, separate from the release bundle, so
`lw self-update` never disturbs them and removing one never touches the core.
An incompatible module is refused at install time (strict interface-version
match), with a message saying whether to update lw or wait for a module
release.]],
  publish = [[lw publish

Regenerate the shared loomworks.json from the working copy — the same snapshot
the editor produces on :w. This is the file you commit and that CI reads.

Only items whose INTENT includes `shared` are written. Every item (project,
configuration set, profile, configuration) carries an intent:
  local          working copy only (.nvim/loomworks.user.json) — private
  local+shared   both files — the CLI default (`lw` authors the shared config)
  shared         loomworks.json only (rare; reference-only)
In the CLI, `add`/`create` default to local+shared, so `lw publish` writes them.
PROFILES are the exception: they default to local, because they pin toolchains
resolved on THIS machine. Share the configuration set instead — each machine
pairs it with a locally created profile.
Use --local at creation to keep something private, or --shared to be explicit.

To share an item created --local (or made in the editor), publish it by name:
  lw project publish <name>
  lw configuration-set publish <name> (also writes its mapped projects/configs)
  lw configuration publish <project> <name>
  lw profile publish <key>            (also writes its set + projects)
Each marks the item local+shared and regenerates loomworks.json.

Configuration sets are the portable unit teams share: a profile pins a
machine-specific tool, so publishing config sets (+ projects) lets everyone —
and each CI runner — pick a local tool and create their own profile
(`lw profile create <set> <tool>`). You CAN publish a profile too; it just
resolves as incomplete for anyone without that tool.

Bare `lw publish` warns if the result is empty (nothing is shared yet).]],
  project = [[lw project <add|remove|rename|list|show|publish>

Manage the workspace's projects in the working copy (.nvim/loomworks.user.json);
`lw publish` writes the shared ones to loomworks.json.

  add <path> [type] [name] [--shared|--local]
        Register an existing directory as a project. The path is inspected to
        detect the type (CMakeLists.txt -> cmake, meson.build -> meson, ...);
        pass <type> to override or when nothing is detected. <name> defaults to
        the directory basename; on a clash you're prompted (or, non-interactive,
        it errors). Missing-and-required args are prompted only on a terminal.
        New projects default to local+shared (--local keeps them private).
        A cmake/meson project comes with auto configurations (Debug, Release, …)
        ready to map — see `lw configuration list <name>`.
  remove <name>
        Drop a project. <name> is the unique project key (`lw project list`).
  rename <old-name> <new-name>       (alias: mv)
        Rename a project's key. Updates every profile mapping and configuration
        set that references it; `lw publish` then rewrites loomworks.json.
  list  Show all projects: key, type, path.
  show <name>
        Detail one project: type, path, its configurations, the sets that map
        it, and its intent.
  publish <name>
        Mark the project shared (local+shared) and regenerate loomworks.json.]],
  configuration = [[lw configuration <list|add|show|get|set|unset|remove>   (alias: cfg)

Manage a project's build configurations in the working copy; `lw publish`
shares the result. Configs are addressed by name (an unambiguous base name
works too). set/unset/remove act on user configs only.

cmake/meson projects already expose auto configurations (variant:Debug,
variant:Release, …) that you can map into a set directly — `add` is only for
custom variants.

  list [project]                     configs for one project, or all
  add <project> <name> [base...]     create a user configuration, inheriting
                                     the given bases (e.g. variant:Release
                                     asan). Several bases form a mixin chain
                                     merged left to right; a comma-separated
                                     list works too.
  show <project> <name>              detail: variant, inherits, options, ...
  get <project> <name> <param>       print one value
  set <project> <name> <param> <value>
  unset <project> <name> <param>     clear one value
  remove <project> <name>            delete a user configuration

A config becomes concrete by INHERITING a base that provides a variant; the
variant is not settable directly, so the build type has one declared source
(the built-in `variant:*` configs). Without a base a config is an abstract
mixin — usable as a base, never built.

Params for get/set/unset:
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
  profile = [[lw profile <list|select|create|remove|publish|target|query>

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
            makes it active. A toolchain may be pinned coarsely — by major
            version (ninja-clang-19) or without an edition (msvc-17); it
            resolves to the best installed match (see the note below).
            Created `local` — a profile pins toolchains resolved here, so it
            stays out of loomworks.json unless you pass --shared or run
            `lw profile publish`.
  remove <profile>                   (alias: rm)
            Drop a profile from the working copy. Removes the profile only —
            its build directories are left in place (`lw clean` removes
            artifacts). Clears the active selection if it pointed here.
  publish <profile>
            Mark the profile shared (local+shared) and regenerate
            loomworks.json, including the set and projects it needs.
  target <profile> [<target>|--clear] [--cwd <dir>]
            Show, set, or clear a profile's DEFAULT launch target — what
            `lw run <profile>` runs with no target named. With no target, prints
            the current default and its working directory; `--clear` unsets it.
            Resolves a build target or command launch config like `lw run`
            (build the profile first so its build targets are known);
            `--target`/`--launch`/`--project` disambiguate. `--cwd <dir>` stores
            a persistent working directory for a build-target default (absolute
            or workspace-root-relative); default is the project directory.
  query <profile> <project> <field>
            Print one machine-readable fact for scripting (e.g. CI artifact
            collection). Read-only; no build. Fields:
              build-dir  absolute build directory (known before building)
              config     the pinned configuration name
              state      last known build state (unconfigured/configured/built…)
              tool       the resolved toolchain key
            e.g. BD=$(lw profile query Debug:ninja-clang-18 app build-dir)

The active profile is the default for `lw build`. Profiles and toolchains
resolve by a TRUNCATED selector, matched at segment boundaries: `ninja-clang-18`
picks the highest `18.x`, and `msvc-17` picks an installed VS 17 without naming
the edition. A truncated selector never crosses a boundary (`…-1` never matches
`…-18`), and a substring like `lw build clang-19` works when unambiguous.]],
  config = [[lw config <list|get|set|unset> [key] [value]

Read or write lw's user configuration (]] .. config_path() .. [[).

  list                 show all settings and the file path
  get <key>            print one setting
  set <key> <value>    set a setting
  unset <key>          remove a setting

Keys:
  dev-lua         a checked-out loomworks `lua/` directory to run from
                  (the development source, spec §16.11).
  default-source  `dev` or `release`. `dev` makes `lw` use dev-lua without
                  needing `--dev` each time; `release` (default) uses the
                  verified release bundle.

Source precedence (resolved by the host before commands run):
  LOOMWORKS_LUA env > `--dev[=PATH]` > default-source=dev > release bundle.
Dev sources are your own checkout and are not signature-verified.]],
  completion = [[lw completion <bash|zsh>

Print a shell completion script to stdout. It writes nothing to your shell
config — you choose how to enable it, so nothing is installed behind your back:

  eval "$(lw completion bash)"      # this session only
  echo 'eval "$(lw completion bash)"' >> ~/.bashrc   # persist it yourself

Completes commands, subcommands, project / configuration-set / profile names,
toolchains (from the cache — no scan), configuration names, module types, and
paths. `lw` must be on PATH so the completion can call it back. Completion is
non-interactive and never blocks; names come from a fast (~250ms) load.]],
  version = [[lw version

Print the host version and which system-Lua source is active — one of:
  dev      a checked-out tree (--dev / default-source=dev / LOOMWORKS_LUA)
  release  a verified release bundle (lua-<ver>/ under the data dir)
  fused    the copy bundled into the lw binary (a full-fused/dev build)

A host command, handled by the lw binary itself (spec §16.11).]],
  install = [[lw install [-y] [--no-modify-path] [--no-bundle] [--dry-run]

Install the running lw binary for the current user and make it usable
(spec §16.15). It copies itself to a per-user location, ensures that location
is on PATH, and fetches the first release bundle. No admin required.

  location   Windows: %LOCALAPPDATA%\Microsoft\WindowsApps\lw.exe (on PATH)
             Unix:    ~/.local/bin/lw

  -y                 apply PATH changes without prompting (needed with --no-input)
  --no-modify-path   install the binary but never touch PATH / shell rc
  --no-bundle        skip fetching the release bundle (do `lw self-update` later)
  --dry-run          print what would happen, change nothing

Typical bootstrap (download, verify by hash, then let the verified binary
install itself) — from the release page for your platform, e.g.:

  curl -fsSL <url>/lw-linux-x86_64 -o /tmp/lw \
    && echo "<sha256>  /tmp/lw" | sha256sum -c \
    && chmod +x /tmp/lw && /tmp/lw install

A host command (handled by lw itself).]],
  ["self-update"] = [[lw self-update [--force]

Download the current release, verify its signature and hashes, and activate
it (spec §16.12–16.13). Fetches manifest.json + manifest.json.sig, checks the
signature against the key built into lw, downloads the bundle, verifies its
SHA-256 against the (trusted) manifest, then extracts it into a new
lua-<version>/ under the data dir — never overwriting a running copy. Integrity
rests on the signature, not the transport, so it is safe behind a proxy;
set LOOMWORKS_INSECURE_TLS=1 for TLS-intercepting proxies.

  --force   reinstall even if that version is already present

Source of releases: LOOMWORKS_RELEASE_URL, else the `release-url` config key,
else the built-in default. A local directory works as an offline mirror.
Not applicable to a development source. A host command (handled by lw itself).]],
  agent = [[lw help agent — driving lw from an automation agent

Run EVERY command with --no-input (or export LW_NO_INPUT=1). In this mode lw
never prompts and never falls back to the user's active profile, so it cannot
block and will not change the user's interactive state. A missing required
value errors with the exact command to run, instead of waiting.

Contract: stdout is the parseable result; warnings/errors go to stderr; exit
code is 0 on success, non-zero on failure. Prefer exact names/keys over
substrings for determinism.

Read-only — safe any time (no writes to user.json / loomworks.json):
  lw                              status + active profile
  lw workspace                    print the workspace name
  lw project list | show <name>   lw profiles       lw tools [--cached]
  lw configuration list|show|get  lw configuration-set list|show
  lw profile query <profile> <project> <field>   (build-dir | config | state | tool)
  lw build <profile> [-- args]    builds; read-only toward config (writes only
                                  the build dir + cache)
  lw version

Mutating — only when the task asks (these write the working copy / shared file):
  init · workspace rename · project add|remove|rename ·
  configuration add|set|unset|remove ·
  configuration-set create|map|unmap|remove · profile create|remove ·
  sdk add|remove ·
  <kind> publish · publish · config set

Do NOT change the user's active profile:
  - Build by explicit key:  lw --no-input build Debug:ninja-clang-19
  - Avoid `lw profile select` and `profile create --activate` (both set the
    active profile). Create without --activate, then build by key.
  - With --no-input, `lw build` (no profile) errors instead of onboarding — you
    stay in control; create/choose the profile explicitly.

Intent: items you create default to local+shared and reach the committed
loomworks.json on publish — except profiles, which default to local because
they pin machine-resolved toolchains. Pass --local to keep something out of the
shared file, and don't `publish` unless the task is to change the shared
contract. See `lw help publish`.]],
  sdk = [[lw sdk <types|list|add|remove>

Declare a toolchain installation that auto-detection cannot find — a compiler
at an arbitrary path, a custom build, or a cross-compiler. A declared SDK
produces a toolchain, so it appears in `lw tools` and can be pinned by
`lw profile create`. Declarations live in the working copy (machine-local).

  types                 SDK provider ids available on this host. Plugins add
                        more by shipping a provider (e.g. a platform SDK).
  list                  declared SDKs and their paths
  add <type> <path>     Probe the path, derive a key, and declare it.
        [--force]       Register even when the path fails to identify itself
                        (an exotic driver or a wrapper script). The path must
                        still exist. Such an SDK has no discovered version, so
                        version-based selection is unavailable — pin it by its
                        full key.
        [--family <f>] [--version <v>]
                        With --force, supply what probing could not discover,
                        so the key stays meaningful.
  remove <key>          Drop a declaration (`lw sdk list` shows keys).

The key is DERIVED, not chosen: <type>-<family>-<version>-<path token>, e.g.
cpp_compiler-clang-19.1.0-vendor-clang. Two builds of the same version at
different paths therefore stay distinct, and the version stays selectable
(`cpp_compiler-clang-19` resolves it). `add` prints the key it produced.

  lw sdk add cpp_compiler /opt/compilers/clang-19/bin/clang++
  lw profile create Debug cpp_compiler-clang-19]],
  ci = [[lw help ci — driving CI jobs with lw

Model: commit the CONFIGURATION SETS (the portable unit) and the projects.
Each matrix cell then picks a local toolchain by major version and creates its
own profile — profiles are per-machine and need not be committed. Run every
command with --no-input (or LW_NO_INPUT=1 / the conventional CI env var); see
`lw help agent` for the non-interactive contract.

1. Bootstrap lw on the runner
   Download a PINNED binary for the platform, verify it by hash, then let the
   verified binary install itself (details + one-liner in `lw help install`):
     curl -fsSL <url>/lw-linux-x86_64 -o /tmp/lw \
       && echo "<sha256>  /tmp/lw" | sha256sum -c \
       && chmod +x /tmp/lw && /tmp/lw install -y
   Pin the version by using a specific release URL + sha256 and NOT running
   `lw self-update`. Air-gapped runner: point LOOMWORKS_RELEASE_URL (or the
   `release-url` config key) at a local mirror directory.

2. Pick a toolchain deterministically (per matrix cell)
   Pin a toolchain COARSELY — by major version, or without an edition — and it
   resolves to the best installed match, so the job never names the exact patch
   or the runner image's VS edition:
     lw --no-input profile create Debug ninja-clang-18 --activate
   Key shapes differ per MODULE, so run `lw tools` on the runner to see the
   real keys before writing the matrix:
     cmake   generator + compiler:  ninja-clang-18 · ninja-gcc-12 ·
             msvc-17 (any edition) · ninja-msvc-17
     meson   compiler only (no generator):  clang-18 · gcc-12
   A truncated pin never crosses a boundary, so `clang-1` matches nothing.

3. Build and test with machine-readable output
     lw --no-input build Debug:ninja-clang-18
     lw --no-input test  Debug:ninja-clang-18 --junit results.xml -- -j 4
   `--junit <file>` writes JUnit XML for your reporter (one file per test unit);
   everything after `--` forwards to the native runner (ctest `-j N`, meson
   `--num-processes N`). The exit code is real: 0 iff build + every test passed.
   The profile selector (`ninja-clang-18`) resolves the same here as on create.

4. Collect build artifacts
     BD=$(lw --no-input profile query Debug:ninja-clang-18 app build-dir)
     cp "$BD/app" out/
   The build directory is deterministic and known BEFORE building. Fields:
   build-dir | config | state | tool (see `lw help profile`).

Gitignore `.nvim/`: it holds the working copy (loomworks.user.json), the cache,
and the build trees — all machine-local. If it isn't in the repo's .gitignore,
every teammate and CI runner sees it as untracked (a personal GLOBAL gitignore
hides this from whoever set the project up). Only loomworks.json is committed.

Dependency fetching / offline: lw is non-invasive — `lw build` runs your build
system's own configure/build, so third-party fetching (cmake FetchContent,
meson subprojects/wrap) is done by cmake/meson, NOT by lw. A first configure
that pulls deps needs network; lw adds no separate download step, dependency
cache, or offline mode of its own. Fetched deps land inside the build dir
(e.g. cmake's _deps/), so caching .nvim/build/<project>/ between runs reuses
both fetched sources and compiled objects.]],
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
  workspace <sub>   show / rename the workspace  (ws)
  project <sub>     add | remove | rename | list | show projects
  configuration     add | set | get | show | ... project configurations
  configuration-set create | map | show | ... sets  (cs)
  profiles          list profiles and their buildability
  profile <sub>     list | select | create | remove | publish | target | query
  tools [--cached]  list detected toolchains (scans; --cached reads the cache)
  sdk <sub>         declare toolchains detection can't find (types|list|add|remove)
  build [profile]   build a profile (configure if needed, then build)
  test  [profile]   build a profile, then run its tests (real exit code)
  run <profile> [target]  build, then execute a launch target
  launch <sub>      list | add | show | remove launch configurations
  publish           write loomworks.json from the working copy
  migrate [--check] bring the workspace files up to current conventions
  module <sub>      install | update | remove | list acquirable modules (mod)
  config <...>      get/set lw configuration
  completion <shell> print a shell completion script (bash|zsh)
  version           host version + which system-Lua source is in use
  install           install the lw binary on PATH + fetch the first bundle
  self-update       download + verify the latest release bundle
  help  [command]   this help, or details for a command

Quickstart (empty dir -> first build -> shared config):
  lw init                                  initialize the workspace
  lw project add <path>                    register a project (type auto-detected)
  lw cs create <name> <project>=<config>   map a config set (e.g. app=Debug)
  lw profile create <name> <tool>          make a buildable profile (`lw tools`)
  lw build <profile>                       build it
  lw publish                               write the shared loomworks.json

Items you add/create default to local+shared, so `lw publish` writes them to the
committed loomworks.json — profiles excepted, as they pin toolchains found on
this machine. Use --local to keep something private, --shared to share a
profile; or share later with `lw <project|profile|configuration-set> publish
<name>`. See `lw help publish` for the intent model.

New cmake/meson projects already expose configurations (Debug, Release, …) to
map — `lw configuration list <project>` shows them; you only add configurations
for custom variants.

Global: --no-input (alias --non-interactive) never prompts — a missing
required value errors instead of waiting. Also enabled by LW_NO_INPUT or CI.
Otherwise prompting is on only when stdin is a terminal. In non-interactive
mode `lw build` also ignores the active profile — pass the profile explicitly.

Automation agent? See `lw help agent` — run with --no-input so you never block
or change the user's settings. Driving CI? See `lw help ci`.

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
  local raw = _G.arg or {}
  -- Shell completion runs before flag-stripping so the passed COMP_WORDS reach
  -- the completer verbatim (a word being completed may itself be `--no-input`).
  if raw[1] == "__complete" then
    local words = {}
    for i = 3, #raw do words[#words + 1] = raw[i] end
    finish(M.cmd_complete(raw[2], words))
  end

  -- Non-interactive control (CI-safe): strip the global `--no-input` /
  -- `--non-interactive` flags from anywhere in the args, and honor the
  -- LW_NO_INPUT and conventional CI environment variables. Any of these makes
  -- prompts error with an explicit-argument hint instead of blocking.
  local a = {}
  for _, v in ipairs(raw) do
    if v == "--no-input" or v == "--non-interactive" then
      force_noninteractive = true
    elseif v == "--shared" then
      create_intent = "local+shared"
    elseif v == "--local" then
      create_intent = "local"
    elseif v == "--dev" or v:sub(1, 6) == "--dev=" then
      -- Source selection is resolved by the host bootstrap (main.lua) before
      -- we run; ignore it here so the nvim-hosted path doesn't choke on it.
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
    finish(M.cmd_init(a))
  end
  if command == "completion" then
    finish(M.cmd_completion(a[2]))
  end
  -- `module` acquires third-party modules — no workspace needed.
  if command == "module" or command == "mod" then
    finish(M.cmd_module(a[2], a))
  end
  -- `version` / `self-update` are host commands: on the luvi host the bootstrap
  -- (main.lua) intercepts them before we run. Reaching here means the
  -- nvim-hosted fallback, where they don't apply.
  if command == "version" or command == "--version" or command == "-v"
      or command == "self-update" or command == "install" then
    io.stderr:write("lw: `" .. command .. "` is provided by the standalone lw " ..
      "binary; it is not available in the nvim-hosted fallback.\n")
    finish(1)
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
  if command == "migrate" then
    finish(M.cmd_migrate(root, a))
  end
  -- `project` / `configuration` manage their own workspace load (no tools).
  if command == "project" then
    finish(M.cmd_project(a[2], root, a[3], a[4], a[5]))
  end
  if command == "configuration" or command == "cfg" then
    finish(M.cmd_configuration(a[2], root, a[3], a[4], a[5], a[6], a))
  end
  if command == "configuration-set" or command == "cs" then
    finish(M.cmd_cset(a[2], root, a))
  end
  -- `workspace` manages workspace-level settings (name) in the working copy.
  if command == "workspace" or command == "ws" then
    finish(M.cmd_workspace(a[2], root, a))
  end
  -- `sdk` declares toolchain installations detection can't find.
  if command == "sdk" then
    finish(M.cmd_sdk(a[2], root, a))
  end

  if command == "tools" then
    finish(M.cmd_tools(root, a))
  end
  -- `launch` manages launch configs in the working copy (no tools needed).
  if command == "launch" then
    finish(M.cmd_launch(a[2], root, a))
  end

  local ws = load_workspace(root)
  if command == "profiles" then
    finish(M.cmd_profiles(ws))
  elseif command == "build" then
    finish(M.cmd_build(ws, a))
  elseif command == "clean" then
    finish(M.cmd_clean(ws, a[2]))
  elseif command == "unlock" then
    finish(M.cmd_unlock(ws, a))
  elseif command == "test" then
    finish(M.cmd_test(ws, a))
  elseif command == "run" then
    finish(M.cmd_run(ws, a))
  else
    die("unknown command '" .. command .. "' — run `lw help`")
  end
end

main()
