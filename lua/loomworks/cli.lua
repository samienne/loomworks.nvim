--- loomworks/cli.lua — headless entry point for the standalone runner.
---
--- Hosted under Neovim
--- (`nvim --headless -u NONE -l lua/loomworks/cli.lua <cmd> [args]`); the
--- luvi + shim host is layered on later without changing this file.
---
--- Commands: (status) | init | workspace <rename> |
---           project <add|remove|rename|list|show> |
---           config <list|add|show|get|set|unset|rename|remove> |
---           configset <list|show|create|map|unmap|rename|remove> |
---           profile <list|show|select|create|remove|publish|query|set|unset> |
---           tools | build [profile] |
---           clean [profile] | run [target] | run <profile> <target> |
---           target <list|set|clear> [profile] | launch <sub> | publish | test [profile] |
---           unlock <profile>|<dir>|--all [--force]|--device <serial> | device <list|select|clean> |
--           settings <...> | completion <shell> | help

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

-- Terminal-safe rendering of everything the CLI prints (control characters in
-- data escaped; only our own palette markers become escape sequences).
local term = require("loomworks.term")

-- Cleanups run before any os.exit() (both finish() and die()), so a build-dir
-- lock is always released even when a step fails and we bail out.
-- An interrupt passes its context (`interrupt_context`) to every hook; a
-- normal exit passes nothing.
local _exit_hooks = {}
local function on_exit(fn) _exit_hooks[#_exit_hooks + 1] = fn end
local function run_exit_hooks(ctx)
  for i = #_exit_hooks, 1, -1 do pcall(_exit_hooks[i], ctx) end
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
--- Every line goes through `term.render`: control characters in DATA (names,
--- paths, values read from workspace/cache/health files) are escaped; only the
--- palette's own SGR markers become escape sequences (loomworks.term).
-- While true, `out` folds report glyphs (bullets, marks, dashes) to ASCII —
-- set by `lw health` (spec §16.31), whose report must read in any console
-- code page. The strings stay Unicode for the editor, which renders its own.
-- (A field, not a local: this chunk is at Lua's 200-local limit.)
M._ascii_out = false

local function out(s)
  local r = term.render(s or "")
  if M._ascii_out then r = term.ascii(r) end
  io.write(r .. "\n")
end

--- Write an informational line to stderr. Used when stdout must stay clean for a
--- machine consumer — e.g. `lw run --print` streams its build/status chatter here
--- so `valgrind $(lw run --print)` captures only the resolved command line.
--- stdout is flushed first: it is buffered (stderr is not), so a stdout line
--- written earlier (e.g. a `==> [step]` header) would otherwise surface after
--- this one on a shared terminal.
local function note(s) io.stdout:flush(); io.stderr:write(term.render(s or "") .. "\n") end

--- stderr counterpart of `out` for text that is not a whole line (same
--- rendering; stdout flushed first, as `note`). Raw tool output relayed from a
--- child process does not use it.
local function errw(s) io.stdout:flush(); io.stderr:write(term.render(s or "")) end

-- ---------------------------------------------------------------------------
-- Shell-word splitting and POSIX-sh quoting (for `lw run --prefix` / `--print`)
-- ---------------------------------------------------------------------------

--- Split a shell-style word string into tokens, honoring single quotes
--- (literal), double quotes (with backslash escaping of `"` `\` `$` `` ` ``),
--- and backslash escaping outside quotes. Used for
--- `--prefix "valgrind --leak-check=full"`. A quoted empty string (`''`) yields
--- one empty token; unterminated quotes are tolerated (the run to end-of-string
--- is the token). Pure — no shell is invoked.
--- @param s string
--- @return string[]
local function shell_split(s)
  local tokens, buf, has = {}, {}, false
  local i, n = 1, #s
  local function push()
    if has then tokens[#tokens + 1] = table.concat(buf); buf, has = {}, false end
  end
  while i <= n do
    local c = s:sub(i, i)
    if c == "'" then
      has = true; i = i + 1
      while i <= n and s:sub(i, i) ~= "'" do buf[#buf + 1] = s:sub(i, i); i = i + 1 end
      i = i + 1
    elseif c == '"' then
      has = true; i = i + 1
      while i <= n and s:sub(i, i) ~= '"' do
        local d = s:sub(i, i)
        if d == "\\" and i < n then
          local e = s:sub(i + 1, i + 1)
          if e == '"' or e == "\\" or e == "$" or e == "`" then
            buf[#buf + 1] = e; i = i + 2
          else
            buf[#buf + 1] = d; i = i + 1
          end
        else
          buf[#buf + 1] = d; i = i + 1
        end
      end
      i = i + 1
    elseif c == "\\" and i < n then
      has = true; buf[#buf + 1] = s:sub(i + 1, i + 1); i = i + 2
    elseif c:match("%s") then
      push(); i = i + 1
    else
      has = true; buf[#buf + 1] = c; i = i + 1
    end
  end
  push()
  return tokens
end
M._shell_split = shell_split

--- POSIX-sh single-quote a token so it survives shell word-splitting and
--- expansion unchanged: an empty string becomes `''`, a token of only shell-safe
--- characters is left bare, and anything else is single-quote wrapped with each
--- embedded `'` rendered as `'\''`. NOTE: this targets POSIX shells; the JSON
--- form (`--print=json`) is the portable representation (e.g. on Windows).
--- @param s string
--- @return string
local function posix_sh_quote(s)
  s = tostring(s)
  if s == "" then return "''" end
  if s:match("^[%w_%-%./:=@,+]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
M._posix_sh_quote = posix_sh_quote

--- The launch-contributed environment OVERRIDES: entries of the resolved run
--- environment whose value differs from the inherited process environment. A
--- command launch config's env is already just its declared vars; a build-target
--- / target-backed launch resolves a FULL env (inherited + a PATH prepend), so
--- diffing against the inherited env reduces it to exactly the launch's
--- contribution — never the whole inherited environment (spec §16.17 "Command
--- inspection"). Returns a plain table (possibly empty). loomworks.run_prep
--- (shared with the workspace daemon's `prepare_run`, §19.15).
--- @param env table<string,string>|nil
--- @return table<string,string>
local function launch_env_overrides(env)
  return require("loomworks.run_prep").env_overrides(env)
end
M._launch_env_overrides = launch_env_overrides

--- Render a resolved launch spec as a read-only report (spec §16.17 "Command
--- inspection") and return exit 0. `mode` is `"sh"` (a single POSIX-sh-quoted
--- `<cmd> <args…>` line, suitable for `valgrind $(lw run --print)`) or `"json"`
--- (`{ "cmd": [argv…], "cwd": …, "env": { overrides-only } }`). Never executes.
--- @param spec { cmd: string, args: string[], cwd: string, env: table|nil }
--- @param mode "sh"|"json"
--- @param root string workspace root (cwd fallback)
--- @return integer
local function emit_run_print(spec, mode, root)
  if mode == "json" then
    local argv = { spec.cmd }
    for _, a in ipairs(spec.args or {}) do argv[#argv + 1] = a end
    local ov = launch_env_overrides(spec.env)
    out(vim.json.encode({
      cmd = argv,
      cwd = spec.cwd or root,
      env = next(ov) and ov or vim.empty_dict(),
    }))
  else
    local parts = { posix_sh_quote(spec.cmd) }
    for _, a in ipairs(spec.args or {}) do parts[#parts + 1] = posix_sh_quote(a) end
    out(table.concat(parts, " "))
  end
  return 0
end
M._emit_run_print = emit_run_print

--- Assemble the launched argv for a run: the prefix tokens, then the resolved
--- command, then its arguments (`<prefix…> <cmd> <args…>`, spec §16.17 "Launch
--- prefix"). Pure.
--- @param prefix_tokens string[]|nil
--- @param spec { cmd: string, args: string[]|nil }
--- @return string[]
local function build_run_argv(prefix_tokens, spec)
  local full = {}
  for _, t in ipairs(prefix_tokens or {}) do full[#full + 1] = t end
  full[#full + 1] = spec.cmd
  for _, a in ipairs(spec.args or {}) do full[#full + 1] = a end
  return full
end
M._build_run_argv = build_run_argv

--- Truncate `s` to width `w`, appending an ellipsis when it overflows.
local function trunc(s, w)
  s = tostring(s)
  if #s <= w then return s end
  return s:sub(1, math.max(1, w - 1)) .. "…"
end

local function die(msg, code)
  run_exit_hooks()
  io.stdout:flush()
  io.stderr:write(term.render("lw: " .. tostring(msg)) .. "\n")
  os.exit(code or 1)
end

-- Interrupt handling. In a terminal, Ctrl-C sends SIGINT to the WHOLE
-- foreground process group — the build tool AND this `lw` process. lw's default
-- SIGINT action terminates it before run_exit_hooks() runs, so every held
-- build-dir lock leaks until the ~STALE_SECONDS mtime reclaim, and a remote
-- run (spec §18.8) leaves its device program running. Installing a handler
-- routes an interrupt through the SAME run_exit_hooks() cleanup path (so the
-- release_all registered by with_build_locks fires, and a remote run stops its
-- device program) and then exits 130, the conventional code for a
-- SIGINT-terminated process.
--
-- Every way a user or the system interrupts lw takes that path, not only
-- Ctrl-C: libuv reports CTRL_BREAK_EVENT as sigbreak and a closed console
-- window (CTRL_CLOSE_EVENT) as sighup on Windows; on POSIX a terminal hangup
-- is sighup and a termination request sigterm. Unhandled, each of them ends
-- the process at once (0xC000013A on Windows) with nothing cleaned up.
--
-- Handles are kept in this module-level table so they are not garbage-collected
-- while started; each is :unref()'d so it never keeps the event loop alive on
-- its own.
local _signal_handles = {}

--- Signals routed through the interrupt cleanup. A name the platform does not
--- support (sigbreak on POSIX) simply fails to install.
M.INTERRUPT_SIGNALS = { "sigint", "sigbreak", "sighup", "sigterm" }

--- Seconds a device stop may take while a Windows console is closing: the
--- system ends the process about 5 s after CTRL_CLOSE_EVENT, so the stop is
--- bounded below that and the device lock is still released in time.
M.CLOSE_STOP_TIMEOUT = 3

--- The context an interrupt passes to the exit hooks: the signal name and,
--- for a Windows console close (sighup), the bounded device-stop time. Pure.
--- @param signal string|nil
--- @param windows boolean
--- @return { signal: string|nil, stop_timeout: number|nil }
local function interrupt_context(signal, windows)
  local ctx = { signal = signal }
  if windows and signal == "sighup" then ctx.stop_timeout = M.CLOSE_STOP_TIMEOUT end
  return ctx
end
M._interrupt_context = interrupt_context

--- Build the guarded interrupt-cleanup callback (the body a signal handler
--- runs, called with the signal name): run the exit hooks with the interrupt
--- context (releasing held build/device locks and stopping a remote run's
--- device program), flush the output streams, then exit with `code`. The
--- returned closure fires the cleanup at most once — a repeated Ctrl-C or a
--- second signal is ignored. `exit_fn` defaults to os.exit and is injectable
--- so tests can drive the callback without terminating the process.
--- @param code integer
--- @param exit_fn? fun(code: integer)
--- @return fun(signal?: string) callback
local function make_interrupt_cleanup(code, exit_fn)
  local fired = false
  return function(signal)
    if fired then return end
    fired = true
    run_exit_hooks(interrupt_context(type(signal) == "string" and signal or nil,
      package.config:sub(1, 1) == "\\"))
    pcall(function() io.stdout:flush() end)
    pcall(function() io.stderr:flush() end)
    ;(exit_fn or os.exit)(code)
  end
end

--- Whether SIGHUP was ignored when lw started (POSIX: `nohup lw …`). A handler
--- would override that inherited disposition, so it is not installed then.
--- Linux reports the ignored-signal mask in /proc/self/status (`SigIgn`, a hex
--- mask; SIGHUP is bit 0). Elsewhere, where the mask is unknown, a hangup only
--- concerns a terminal, so SIGHUP counts as ignored unless standard error is a
--- terminal (nohup redirects it away from one). Both sources are injectable.
--- @param status_text? string|false contents of /proc/self/status (false = unavailable)
--- @param stderr_tty? boolean
--- @return boolean
local function posix_sighup_ignored(status_text, stderr_tty)
  if status_text == nil then
    local f = io.open("/proc/self/status", "r")
    status_text = f and f:read("*a") or false
    if f then f:close() end
  end
  local mask = status_text and status_text:match("\nSigIgn:%s*(%x+)")
  if mask then
    local last = tonumber(mask:sub(-1), 16)
    return last ~= nil and last % 2 == 1
  end
  if stderr_tty == nil then
    local ok, kind = pcall(uv.guess_handle, 2)
    stderr_tty = ok and kind == "tty"
  end
  return not stderr_tty
end
M._posix_sighup_ignored = posix_sighup_ignored

--- Install a best-effort handler for every M.INTERRUPT_SIGNALS entry that runs
--- the interrupt cleanup and exits 130. A host/platform that cannot install
--- one simply leaves the CLI running normally (each install is pcall-guarded —
--- a handler-install failure must never break `lw`). On POSIX, SIGHUP is left
--- alone when it was inherited as ignored (`posix_sighup_ignored`). `exit_fn`,
--- the signal source `new_signal` (default uv.new_signal) and
--- `opts.sighup_ignored` are injectable for tests.
--- @param exit_fn? fun(code: integer)
--- @param new_signal? fun(): table
--- @param opts? { sighup_ignored?: fun(): boolean }
--- @return fun(signal?: string) cleanup the shared guarded callback the handlers invoke
local function install_interrupt_handler(exit_fn, new_signal, opts)
  new_signal = new_signal or uv.new_signal
  local sighup_ignored = (opts and opts.sighup_ignored) or function()
    return package.config:sub(1, 1) ~= "\\" and posix_sighup_ignored()
  end
  local cleanup = make_interrupt_cleanup(130, exit_fn)
  for _, sig in ipairs(M.INTERRUPT_SIGNALS) do
    pcall(function()
      if sig == "sighup" and sighup_ignored() then return end
      local h = new_signal()
      if not h then return end
      h:start(sig, cleanup)
      h:unref()
      _signal_handles[#_signal_handles + 1] = h
    end)
  end
  return cleanup
end

-- Test seams: `_on_exit` registers a cleanup hook the way with_build_locks does
-- (so a test can exercise the real run_exit_hooks release chain);
-- `_make_interrupt_cleanup` / `_install_interrupt_handler` expose the guarded
-- interrupt callback with an injectable exit.
M._on_exit = on_exit
M._make_interrupt_cleanup = make_interrupt_cleanup
M._install_interrupt_handler = install_interrupt_handler

--- Walk up from `start` for the workspace root (spec §1.1). The search itself
--- — including why a linked worktree is a hard boundary while a submodule is
--- walked through to its superproject — lives in root_finder, shared with the
--- editor's auto-load so both resolve the same workspace. Returns
--- `(root, info)`; `info.submodule` names the submodule crossed, if any.
--- @param start? string
--- @return string|nil root, { submodule: string|nil }|nil info
local function find_root(start)
  return require("loomworks.root_finder").find(start)
end
M._find_root = find_root

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
--- Test seam: set (or clear, nil) the `--local` / `--shared` creation intent.
function M._set_create_intent(v) create_intent = v end

--- May we prompt the user? False when forced non-interactive, or when stdin
--- isn't a terminal (piped / redirected / closed — the common CI case).
local function interactive()
  if force_noninteractive then return false end
  if M._test_interactive ~= nil then return M._test_interactive end
  -- (Tests of a spawned `lw` without a terminal: the interactive defaults.)
  if os.getenv("LW_TEST_INTERACTIVE") == "1" then return true end
  local ok, h = pcall(uv.guess_handle, 0)
  return ok and h == "tty"
end

--- Prompt for a line. Blank input returns `default` (nil if none). Returns nil
--- only on EOF. Trims surrounding whitespace.
local function prompt_line(question, default)
  io.write(term.render(question))
  if default and default ~= "" then io.write(term.render(" [" .. default .. "]")) end
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
  assert(require("loomworks.io").mkdir_p(config_dir()))
  local encoded = (next(cfg) == nil) and "{}" or vim.json.encode(cfg)
  local f, err = io.open(config_path(), "w")
  if not f then return false, err end
  f:write(encoded); f:write("\n"); f:close()
  return true
end

-- ---------------------------------------------------------------------------
-- Tool cache (machine-level tools.json: %LOCALAPPDATA%/loomworks/cache on
-- Windows, else $XDG_CACHE_HOME/loomworks or ~/.cache/loomworks). Detecting toolchains probes compilers, vswhere, and vcvarsall —
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

--- Test seam: reset the process-global mode flags that some commands latch for
--- the lifetime of a single CLI process (`lw __complete` sets completion_mode +
--- force_noninteractive; `--no-input` sets force_noninteractive; `lw tools`
--- sets tool_cache_mode). Real invocations exit right after, so the latch never
--- matters; in-process tests call this to keep one case from leaking into the next.
function M._reset_modes()
  force_noninteractive = false
  completion_mode = false
  tool_cache_mode = "auto"
end

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
  assert(require("loomworks.io").mkdir_p(tool_cache_dir()))
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
--- `opts.soft_trust` returns `nil, core, trust` for a refused working copy
--- instead of exiting with the trust instructions (`lw health`, §16.36).
--- @param root string
--- @param wait_tools? boolean default true
--- `opts.replace_untrusted_user` loads past a refused working copy as if it
--- were absent (`lw import`, §16.39; the workspace's `_user_unread` says why).
--- @param opts? { soft_trust?: boolean, replace_untrusted_user?: boolean }
--- @return table|nil workspace, table core, table|nil trust refusal
local function load_workspace(root, wait_tools, opts)
  local ws, core, fail = M._load_workspace_soft(root, wait_tools, opts)
  if ws then return ws, core end
  if completion_mode then return nil end
  -- `lw health` reports a refused working copy as an item instead (§16.36).
  if fail.trust and opts and opts.soft_trust then return nil, core, fail.trust end
  die(fail.message)
end

--- Bootstrap a live, remerged Workspace headlessly without exiting: the load
--- behind `load_workspace`, also used by the workspace daemon (spec §19.15),
--- which reports a refusal to its client instead of exiting. Returns
--- `ws, core`, or `nil, core, { message, trust? }` — `message` is exactly
--- what `lw` prints for that refusal. `opts.handlers` (the daemon) replaces
--- the exiting hooks: `notify(msg, level)` and `refused(msg)` (a refused
--- save or workspace operation lock); it also makes the file tracker manual.
--- @param root string
--- @param wait_tools? boolean
--- @param opts? { soft_trust?: boolean, replace_untrusted_user?: boolean, handlers?: table }
--- @return table|nil ws, table core, table|nil failure
function M._load_workspace_soft(root, wait_tools, opts)
  local lw = require("loomworks")
  local core = lw._core()
  local handlers = opts and opts.handlers
  -- Route notifications to stderr (warnings/errors only); the editor's
  -- info chatter is noise on a CLI.
  core._deps.notify = handlers and handlers.notify or function(msg, level)
    if not level or level >= vim.log.levels.WARN then
      errw(tostring(msg) .. "\n")
    end
  end
  -- A refused `.nvim` file (spec §17.4) is reported by the CLI itself, with
  -- its own commands (spec §17.10).
  core._deps.quiet_trust_errors = true
  core._deps.trust_actions = { trust = "lw trust", discard = "lw trust --discard", nuke = "lw nuke" }
  -- Only `lw import` loads past a refused working copy (it replaces it unread,
  -- spec §16.39); every other command keeps the refusal.
  core._deps.replace_untrusted_user = opts and opts.replace_untrusted_user or nil
  -- A refused save (spec §2.7: the working copy changed on disk since this
  -- command read it, or a state file has a newer schema) ends the command:
  -- `lw: <message>`, exit 1. Nothing was written.
  core._deps.on_save_refused = handlers and handlers.refused or function(msg) die(msg) end
  -- A refused workspace operation lock (spec §19.3: another process runs a
  -- multi-file operation) ends the command too, before anything was changed.
  core._deps.on_lock_refused = handlers and handlers.refused or function(msg) die(msg) end
  -- The daemon broadcasts each committed state-file write (spec §19.12).
  core._deps.on_written = handlers and handlers.written or nil
  -- The daemon applies external file changes itself, before each operation
  -- (spec §19.15): its tracker never polls.
  core._deps.manual_file_tracking = handlers and true or nil
  -- Skip the automatic background target scan — it can spawn a per-build-dir
  -- meson/python subprocess (~2s) on every load. Commands that need targets
  -- (`lw run`, `lw target`, the status Targets section) parse them on demand for
  -- just the resolved profile via ensure_unit_targets, which is independent of
  -- this flag and only reads an already-configured build tree.
  core._deps.scan_targets = false
  -- Serve tools from the machine-level cache. A load that won't wait for tools
  -- never probes — serve cache only (never spend seconds for a command that
  -- doesn't need live tools). Install the wrapper before setup triggers a scan.
  -- Not in the daemon (`handlers`): the latch would outlive this load and
  -- keep every later request from probing (a snapshot's load does not wait
  -- for tools, spec §19.13; its detection still runs in the background).
  if wait_tools == false and tool_cache_mode == "auto" and not handlers then
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
    return nil, core, { message = "timed out loading workspace at " .. root }
  end
  local ws = lw.get_workspace()
  if not ws then
    return nil, core, M._setup_failure(core)
  end
  -- Await tool detection (needed for cold builds + accurate buildability).
  if wait_tools ~= false then
    vim.wait(45000, function() return ws._tool_state == "scanned" end, 25)
  end
  return ws, core
end

--- The refusal of a workspace core that has no workspace (its setup error),
--- as `lw` prints it: `{ message, trust? }`.
--- @param core table
--- @return table
function M._setup_failure(core)
  local e = core.get_setup_error and core:get_setup_error()
  if e and e.trust then return { message = M._trust_refusal_message(e.trust), trust = e.trust } end
  if e and (e.newer or e.journal) then return { message = e.message } end
  return { message = "failed to load workspace" .. (e and e.message and (": " .. e.message) or "") }
end
-- Test seam: load a real workspace the way dispatch does (build/clean/reset).
M._load_workspace = load_workspace

--- The workspace a read-only command reads (spec §19.1, §19.13): in
--- `runtime-mode daemon`, the read-only projection of a live, compatible
--- shared daemon's model (`M._read_projection`); otherwise — `in-process`
--- mode, an attached selection, no such daemon, or one that cannot serve it
--- in time — the in-process load, exactly as before. A projection
--- never saves (`_no_write`): only commands that write nothing read through
--- this.
--- @param root string
--- @param wait_tools? boolean as for load_workspace (the in-process load only)
--- @param opts? loomworks.cli.ReadOpts
--- @return table workspace
local function read_workspace(root, wait_tools, opts)
  local ws = M._read_projection(root, opts)
  if ws then return ws end
  return load_workspace(root, wait_tools)
end
M._read_workspace = read_workspace

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--- Build the `lw profiles` / `lw profile list` output lines. Pure and
--- color-aware so it is testable without a tty: the active profile's two lines
--- are painted with the status palette's `active` (green on a terminal, plain
--- on a pipe/redirect), matching the `lw status` active-profile highlight.
--- After the list a dim command-hint footer (same "<prose> · <command>" style
--- the status sections use) points at the neighbouring profile commands; the
--- `switch` hint appears only when more than one profile exists.
--- `color` defaults to the stdout-tty probe. Reads the palette/color helpers
--- off `M` (assigned later in the file) at call time.
--- @param ws table workspace
--- @param color boolean|nil force color on/off (nil = auto-detect stdout)
--- @return string[] lines
--- Stable positional numbering of profiles: the profiles sorted by `.key`
--- ascending, assigned 1..N. Recomputed each run (never persisted), so a
--- profile's number is identical in every listing and as a CLI argument, and
--- only shifts when profiles are added/removed. Single source of truth — every
--- listing and the numeric-argument resolver go through this. Returns:
---   list   — array of profile objects in sorted-by-key order (index = number)
---   number — map profile.key → its 1-based number
--- @param ws table
--- @return { list: table[], number: table<string, integer> }
local function profile_numbering(ws)
  local list = {}
  for _, p in ipairs(ws._profiles or {}) do list[#list + 1] = p end
  table.sort(list, function(a, b) return a.key < b.key end)
  local number = {}
  for i, p in ipairs(list) do number[p.key] = i end
  return { list = list, number = number }
end
M._profile_numbering = profile_numbering

--- Hint lines for mapping project `pkey` (configuration `cfg`, a literal name
--- or the `<config>` placeholder) into a configuration set (spec §16.38): `map`
--- into an existing set, else `create` one — and, for the placeholder, where
--- the configurations come from. `indent` prefixes every line.
function M._map_hint_lines(ws, pkey, cfg, indent)
  local lines = {}
  local function row(cmd, desc) lines[#lines + 1] = string.format("%s%-41s %s", indent, cmd, desc) end
  if cfg == "<config>" then row("lw config list " .. pkey, "its configurations") end
  if #(ws._config_sets or {}) > 0 then
    row("lw configset map <set> " .. pkey .. " " .. cfg, "into a set (`lw configset list`)")
  else
    row("lw configset create <name> " .. pkey .. "=" .. cfg, "a set to build")
  end
  return lines
end

--- The "create a profile" hint line shared by `lw status`, `lw profile list`
--- (spec §16.38: an operand chosen from a listing names the listing command).
M.PROFILE_CREATE_HELP = "create a profile · lw profile create <set> <tool>  (tools: lw tools)"

local function profile_list_rows(ws, color)
  local profiles = ws._profiles or {}
  if color == nil then color = M._stdout_supports_color() end
  local pal = M._status_palette(color)
  if #profiles == 0 then
    -- Empty state names the command that fills it, and the listings its
    -- operands come from (§16.38).
    return {
      "(no profiles defined)",
      "",
      "  " .. M._paint_help(pal, "create a profile · lw profile create <set> <tool>"),
      "  " .. M._paint_help(pal, "list sets and tools · lw configset list · lw tools"),
    }
  end
  local active = ws._active_profile_key
  -- List in the stable sorted-by-key order so the numbers read 1,2,3 down the
  -- page; the number is the same one every other listing and CLI argument uses.
  local order = profile_numbering(ws)
  local num_w = #tostring(#order.list)
  local lines = {}
  for _, p in ipairs(order.list) do
    local n = order.number[p.key]
    local tools = table.concat(p._tool_keys or {}, ", ")
    local set = p._configuration_set_name or "?"
    local is_active = (p.key == active)
    local mark = is_active and "* " or "  "
    local valid, reasons = true, nil
    if p.is_valid then valid, reasons = p:is_valid() end
    local status = valid and "" or ("  [unbuildable: " .. table.concat(reasons or {}, "; ") .. "]")
    -- "<mark> <n>  <key>" → `* 2  Release:ninja-clang-18` / `  1  Debug:...`.
    -- The detail line indents past the mark + number column so keys align.
    local indent = 2 + num_w + 2
    local l1 = string.format("%s%" .. num_w .. "d  %s", mark, n, p.key)
    local l2 = string.rep(" ", indent) .. string.format("set=%s  tools=[%s]%s", set, tools, status)
    local l1_w = require("loomworks.description").width(l1)
    if is_active then l1, l2 = pal.active(l1), pal.active(l2) end
    l1 = l1 .. M._summary_suffix(l1_w, p.description, nil, pal)
    lines[#lines + 1] = l1
    lines[#lines + 1] = l2
  end
  -- Help footer — dim command hints, styled exactly like the `lw status`
  -- sections (a blank separator, then indented `paint_help` lines; plain on a
  -- pipe/redirect). `switch` only makes sense with more than one profile.
  local help = { "show a profile · lw profile show <profile>" }
  if #profiles > 1 then
    help[#help + 1] = "switch the profile · lw profile select"
  end
  help[#help + 1] = M.PROFILE_CREATE_HELP
  help[#help + 1] = "use a number from this list in place of a name"
  lines[#lines + 1] = ""
  for _, h in ipairs(help) do lines[#lines + 1] = "  " .. M._paint_help(pal, h) end
  return lines
end
M._profile_list_rows = profile_list_rows

function M.cmd_profiles(ws)
  for _, line in ipairs(profile_list_rows(ws)) do out(line) end
  return 0
end

--- The single NAMED-profile matcher shared by every verb that takes a profile
--- argument (`build`/`clean`/`run` via resolve_build_target, `select`/`remove`/
--- `set`/`unset`/`target` via resolve_profile, `show` via
--- resolve_profile_for_show). One consistent order:
---   1. bare integer → the stable positional index from `lw profiles`
---      (`profile_by_number`; out-of-range dies). Disabled by `opts.no_number`
---      for `lw profile query`, the deterministic machine path — a number there
---      falls through to name matching.
---   2. exact key.
---   3. unique boundary-anchored substring (`merge.match_profile`), so
---      `Debug:ninja-clang-18` resolves the highest matching patch and `clang-1`
---      never crosses into `clang-18`.
--- Returns the profile, `nil` when nothing matched (the caller decides what a
--- miss means — a hard error, or an onboarding branch), and dies with a clear
--- message on an ambiguous substring. Each verb keeps its own distinct
--- NO-argument fallback (§16.9/§16.18); only this named logic converges.
--- @param ws table
--- @param name string
--- @param opts { no_number: boolean }|nil
--- @return table|nil profile
local function match_profile_arg(ws, name, opts)
  -- loomworks.build_run.match_profile (host-neutral, shared with the daemon).
  local hit, err = require("loomworks.build_run").match_profile(ws, name, opts)
  if err then die(err) end
  return hit
end
M._match_profile_arg = match_profile_arg

--- Resolve which profile to operate on: explicit number/name (a bare integer
--- is the stable positional index; otherwise exact, then unambiguous substring)
--- → user.json active → single → error.
--- `opts.no_number` disables the numeric-index path (keys only) — used by
--- `lw profile query`, the deterministic machine path.
--- `opts.usage` is the invoked command's explicit form (e.g. `lw test <profile>`)
--- quoted in the non-interactive "no profile specified" refusal, so the hint
--- names the command the user actually ran rather than always `lw build`.
--- @param ws table
--- @param name string|nil
--- @param opts { no_number: boolean, usage: string }|nil
--- @return table profile
local function resolve_profile(ws, name, opts)
  -- loomworks.build_run.resolve_profile; the refusals are its messages.
  local o = { no_number = opts and opts.no_number, usage = opts and opts.usage, interactive = interactive() }
  local p, err = require("loomworks.build_run").resolve_profile(ws, name, o)
  if not p then die(err) end
  return p
end
M._resolve_profile = resolve_profile

--- Spawn `step` and wait for it, returning its exit code. Output handling
--- depends on the host: the standalone shim streams (the child inherits this
--- terminal, so progress-aware tools like ninja see a real terminal); real
--- Neovim's `vim.system` has no `stdio` option, so there we capture and write
--- the tool output ourselves (buffered, dumped once the step exits).
--- @param step table { cmd, cwd, env }
--- @param root string
--- @param to_stderr? boolean route the child's stdout to OUR stderr (keeps our
---   stdout clean for a machine consumer — used by `lw run --print`'s build).
--- @return integer code, integer|nil signal the signal that ended the step
---   (code is then 128 + signal: a failure, never a success — §16.7)
local function run_spec(step, root, to_stderr)
  -- Resolve the program to an absolute path (never the cwd / a relative PATH
  -- entry) and, on Windows, add NoDefaultCurrentDirectoryInExePath=1 to the
  -- child env. An unresolvable program is reported, never spawned by name.
  -- loomworks.build_run.spawn_spec (the shared headless build path); an
  -- empty env is dropped there (the child inherits ours, never a wiped PATH).
  local build_run = require("loomworks.build_run")
  local spec, herr = build_run.spawn_spec(step, root)
  if not spec then
    errw("lw: " .. tostring(herr) .. "\n")
    return 127
  end
  step = { cmd = spec.cmd, cwd = spec.cwd, env = spec.env }
  local env = step.env
  if vim._loomworks_shim then
    -- Flush our own buffered output first: the child inherits the terminal and
    -- writes directly, so anything we printed must land before its output
    -- (otherwise our block-buffered stdout flushes only at exit, after the
    -- child's live output).
    io.stdout:flush(); io.stderr:flush()
    local res = vim.system(step.cmd, {
      cwd = step.cwd or root,
      env = env,
      -- "inherit_err" maps the child's stdout onto fd 2 so it streams live but
      -- never lands on our stdout (see the shim's vim.system).
      stdio = to_stderr and "inherit_err" or "inherit",
      hide = false,
    }):wait()
    -- (Inherited output is never captured: only a failed spawn reports here.)
    if res.spawn_error then errw(build_run.spawn_failure_line(step.cmd[1], res.spawn_error) .. "\n") end
    return build_run.exit_status(res.code, res.signal)
  end
  local okc, obj = pcall(vim.system, step.cmd, {
    cwd = step.cwd or root,
    env = env,
    text = true,
  })
  if not okc then
    -- Neovim's vim.system raises when the program cannot be started.
    errw(build_run.spawn_failure_line(step.cmd[1], obj) .. "\n")
    return 127
  end
  local res = obj:wait()
  if to_stderr then
    io.stderr:write(res.stdout or "")
  else
    io.write(res.stdout or "")
  end
  local err = res.stderr or ""
  if err ~= "" then io.stderr:write(err) end
  -- Neovim's vim.system reports a signal-ended process as code 0 + signal.
  return build_run.exit_status(res.code, res.signal)
end
M._run_spec = run_spec

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
--- `usage` is the invoked command's explicit form for the refusal hints
--- (default `lw build <profile>`; test/clean/reset/run pass their own).
--- @param usage? string
local function resolve_build_target(ws, name, usage)
  usage = usage or "lw build <profile>"
  -- The match / refusal rules are loomworks.build_run.resolve_target's (shared
  -- with the workspace daemon, spec §19.15); only onboarding is this host's.
  local p, err = require("loomworks.build_run").resolve_target(ws, name,
    { usage = usage, interactive = interactive() })
  if p then return p, ws end
  if err then die(err) end

  -- Onboard: build a config set by creating a profile for it.
  local sets = ws._config_sets or {}
  if not next(sets) then
    die("no profiles or configuration sets yet.\n" ..
      "  create a set:  lw configset create <name> <project>=<config>")
  end
  local cs
  if name then
    for _, s in ipairs(sets) do if s.name == name then cs = s; break end end
    if not cs then
      die("no profile or configuration set matching '" .. name .. "'.\n" ..
        "  `lw profile list` / `lw configset list`")
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
M._resolve_build_target = resolve_build_target

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

-- The headless build-step logic (plan/gates/record) lives in
-- loomworks.build_run, host-neutral so any runner can share it.
M._record_step = function(ws, step, ok) return require("loomworks.build_run").record(ws, step, ok) end
M._runs_batch_file = function(cmd) return require("loomworks.build_run").runs_batch_file(cmd) end

--- Up to three of `candidates` close to `name` (loomworks.build_run).
local function close_matches(name, candidates)
  return require("loomworks.build_run").close_matches(name, candidates)
end
M._close_matches = close_matches

-- Defined with the test runner below.
local ensure_unit_targets

--- After a failed `--target` build: the build tool's unknown targets, named
--- with close matches (loomworks.build_run.unknown_target_hint, §16.4).
--- @return string|nil
local function unknown_target_hint(ws, step, targets)
  return require("loomworks.build_run").unknown_target_hint(ws, step, targets)
end

M._unknown_target_hint = unknown_target_hint

--- Run a profile's build steps (configure + build), dying on any failure.
--- Returns the number of steps run (0 = nothing buildable).
--- @param opts? table { for_test?: boolean, extra_args?: string[], build_targets?: string[], force?: boolean, reconfigure?: boolean, quiet?: boolean, verbose?: boolean }
---   for_test skips building units whose native test runner rebuilds itself;
---   extra_args are forwarded to the build tool and build_targets select what
---   it builds — both handed to the module's build task (core §8.1), which
---   puts them on its native build command before any wrapping (§16.4);
---   force overrides the output-artifact conflict gate (§5.9); reconfigure
---   forces a FULL reconfigure of every unit before building (§16.4);
---   verbose prints each step's command line + cwd (always logged, §16.4).
local function run_build_steps(profile, ws, opts)
  opts = opts or {}
  -- The plan/gate/record sequence lives in loomworks.build_run (host-neutral);
  -- only the spawn (blocking here) and the reporting (die) are this host's.
  local build_run = require("loomworks.build_run")
  local steps, plan_err = build_run.plan(profile, {
    for_test = opts.for_test,
    reconfigure = opts.reconfigure,
    extra_args = opts.extra_args,
    build_targets = opts.build_targets,
  })
  if not steps then die(plan_err) end
  if #steps == 0 then return 0 end
  -- `quiet` keeps our stdout clean (status lines + build-tool output → stderr)
  -- so a machine consumer like `lw run --print` captures only its report.
  local quiet = opts.quiet or false
  local log = quiet and note or out
  log("building profile: " .. profile.key)
  -- Ignored loomworks.json program settings (spec §17.10): one line, stderr.
  local tn = build_run.trust_notice(ws, profile)
  if tn then note(tn) end
  for _, step in ipairs(steps) do
    -- Conflict gate + full-reconfigure reset. `--force` and `--no-input`
    -- alike just refuse with exit 1; force is the only bypass, never a prompt.
    local ok_g, g_err = build_run.before_step(ws, step, { force = opts.force })
    if not ok_g then die(g_err, 1) end
    for _, line in ipairs(build_run.step_lines(ws, step, { verbose = opts.verbose })) do log(line) end
    -- Through the module table so tests can stub the spawn.
    -- (A step a signal ended comes back as 128 + signal, with the signal.)
    local code, sig = M._run_spec(step, ws.root, quiet)
    build_run.after_step(ws, step, code)
    if code ~= 0 then
      -- A `--target` the unit's parsed targets do not list (likely a typo).
      local th = step.kind == "build" and unknown_target_hint(ws, step, opts.build_targets) or nil
      die(build_run.failure_message(step, code, th, sig), code)
    end
  end
  return #steps
end
M._run_build_steps = run_build_steps  -- exported for tests

--- The distinct build directories a profile's projects map to.
local function profile_build_dirs(profile)
  return require("loomworks.build_run").profile_build_dirs(profile)
end

--- Hold a cross-process lock on every build directory of `profile`
--- for the duration of `fn`, then release. Fail-fast: if any dir is in use by
--- another process, dies with a clear message (releasing any already held). A
--- release is also registered as an exit hook so a `die()` inside `fn` frees
--- the locks too. Directories are locked in canonical order (normalized path,
--- spec §19.3). A dead holder's lock is reclaimed and the interrupted step's
--- state recovered (§19.5 step 5); a hung or live holder is broken first under
--- `--break-locks` (M._lock_holder_or_die).
--- @param dirs string[] distinct build directories to lock
--- @param action string "build"|"clean"|"reset"
--- @param fn fun()
--- @param ws? loomworks.Workspace for messages and state recovery
local function with_build_dir_locks(dirs, action, fn, ws)
  local build_lock = require("loomworks.build_lock")
  local held = {}
  local function release_all()
    for _, h in ipairs(held) do build_lock.release(h) end
    held = {}
  end
  on_exit(release_all)
  local ordered = M._lock_order(dirs)
  for _, bd in ipairs(ordered) do
    local shown = ws and ws:_display_build_dir(bd) or bd
    local ctx = { what = shown, command = require("loomworks.lock_break").command, unlock = shown }
    local h = M._lock_holder_or_die(function()
      local hh, _, info = build_lock.acquire(bd, action, ctx)
      return hh, info
    end, ctx, release_all)
    held[#held + 1] = h
    if h.reclaimed and ws then
      local line = ws:_recover_interrupted_build_dir(bd, h.reclaimed)
      if line then errw("lw: " .. line .. "\n") end
    end
  end
  fn()
  release_all()
end
M._with_build_dir_locks = with_build_dir_locks -- exported for tests

--- Build directories in the canonical lock order of spec §19.3: by
--- normalized identity (§4.6, §2.3), duplicates dropped.
--- @param dirs string[]
--- @return string[]
function M._lock_order(dirs)
  return require("loomworks.build_run").lock_order(dirs)
end

--- Acquire one lock through `try()` (→ handle | nil, classified info), dying
--- with the holder's message on refusal (after `cleanup`). Under
--- `--break-locks` (loomworks.lock_break.requested) a hung or live holder on
--- this host is stopped first and the acquisition retried once (§19.5).
--- @param try fun(): table|nil, table|nil
--- @param ctx table busy-message context
--- @param cleanup? fun()
--- @return table handle
function M._lock_holder_or_die(try, ctx, cleanup)
  local h, msg = require("loomworks.lock_break").acquire(try, ctx)
  if h then return h end
  if cleanup then cleanup() end
  die(msg)
end

--- @param profile loomworks.Profile
--- @param action "build"|"clean"
--- @param fn fun()
local function with_build_locks(profile, action, fn)
  with_build_dir_locks(profile_build_dirs(profile), action, fn, profile._workspace)
end

--- `lw build [profile] [--target <name>]... [-- <build-tool args>]` — configure
--- if needed, then build. `--target` (repeatable) selects what the build tool
--- builds; args after `--` are forwarded to the build tool (e.g. `-- -j 4`).
--- Both reach the module's native build command, never the configure (§16.4).
function M.cmd_build(ws, args)
  -- Split on `--`: everything after goes to the build tool.
  local pre, extra, seen_sep = {}, {}, false
  local force, reconfigure, verbose, targets = false, false, false, {}
  local usage = "usage: lw build [profile] [--target <name>]... [--force] [--reconfigure] "
    .. "[-v|--verbose] [-- build-tool-args…]"
  local i = 2
  while i <= #args do
    local a = args[i]
    if not seen_sep and a == "--" then seen_sep = true
    elseif seen_sep then extra[#extra + 1] = a
    elseif a == "--force" then force = true
    elseif a == "--reconfigure" then reconfigure = true
    elseif a == "--verbose" or a == "-v" then verbose = true
    elseif a == "--target" or a:match("^%-%-target=") then
      local name = a:match("^%-%-target=(.*)$")
      if not name then i = i + 1; name = args[i] end
      if not name or name == "" or name == "--" or name:sub(1, 1) == "-" then
        die("--target needs a target name — " .. usage)
      end
      targets[#targets + 1] = name
    else pre[#pre + 1] = a end
    i = i + 1
  end
  if pre[2] then
    die("unexpected argument '" .. tostring(pre[2]) .. "' — " .. usage)
  end
  local profile
  profile, ws = resolve_build_target(ws, pre[1])
  local built = 0
  with_build_locks(profile, "build", function()
    built = run_build_steps(profile, ws, {
      extra_args = (#extra > 0) and extra or nil,
      build_targets = (#targets > 0) and targets or nil,
      force = force,
      reconfigure = reconfigure,
      verbose = verbose,
    })
  end)
  if built == 0 then
    die("nothing to build for profile '" .. profile.key ..
      "' — no buildable projects (unavailable module or unresolved tool?)")
  end
  out("BUILD OK: " .. profile.key)
  return 0
end

-- A deletion spawns rm-rf subprocesses; give the whole reset / clean wipe a generous budget
-- (large trees / slow disks) before declaring it stuck.
local RESET_TIMEOUT_MS = 120000
-- After the deletion subprocess exits, the directory can briefly linger on
-- Windows (delete-pending: an antivirus/indexer handle keeps the entry in the
-- namespace until it closes). Poll for genuine on-disk absence up to this long
-- before declaring the removal failed. Instant on a healthy filesystem.
local RESET_VERIFY_MS = 30000

--- `lw clean [profile]` — run each project's build-system clean (e.g.
--- `meson compile --clean`, `cmake --build --target clean`) on the profile's
--- configured build dirs. Removes build artifacts but keeps the configuration
--- (a later build reconfigures only if stale). Dies on any failure. The plan,
--- lines and the core-performed wipe are loomworks.build_run's, shared with
--- the workspace daemon (spec §19.15 "Clean").
function M.cmd_clean(ws, profile_name)
  local build_run = require("loomworks.build_run")
  local profile
  profile, ws = resolve_build_target(ws, profile_name, "lw clean <profile>")
  local steps = build_run.plan_clean(profile)
  if not steps then die(build_run.nothing_to_clean_message(profile)) end
  -- A core-performed wipe is a deletion, which takes the workspace operation
  -- lock; lock order (spec §19.3) puts it before the build-directory locks
  -- (the deletion's own acquisition then re-enters both).
  local op_tok
  if build_run.has_wipe(steps) then
    op_tok = ws:_op_lock("clean")
    on_exit(function() require("loomworks.op_lock").release(op_tok) end)
  end
  local groups = build_run.wipe_groups(ws, steps)
  with_build_locks(profile, "clean", function()
    out("cleaning profile: " .. profile.key)
    for _, step in ipairs(steps) do
      out(build_run.clean_step_line(step))
      if step.wipe_build_dir then
        -- Core-performed wipe (spec §8.1) = a build-directory deletion
        -- (§4.6, §4.7), the daemon's same path (build_run.wipe_step).
        local done, res = false, nil
        build_run.wipe_step(ws, step, groups,
          { verify_ms = M._reset_verify_ms or RESET_VERIFY_MS },
          function(code, msg, _, note) done, res = true, { code = code, msg = msg, note = note } end)
        if not vim.wait(RESET_TIMEOUT_MS + (M._reset_verify_ms or RESET_VERIFY_MS),
            function() return done end, 20) then
          die("clean timed out — the build-directory deletion did not complete: "
            .. (step.name or "?"))
        end
        if res.code ~= 0 then die(res.msg, res.code) end
        if res.note then out(res.note) end
      else
        local code, sig = M._run_spec(step, ws.root)
        build_run.after_clean_step(ws, step, code)
        if code ~= 0 then die(build_run.failure_message(step, code, nil, sig), code) end
      end
    end
  end)
  if op_tok then require("loomworks.op_lock").release(op_tok) end
  out("CLEAN OK: " .. profile.key)
  return 0
end

--- `lw reset [profile] [--all] [-y]` — HARD reset build state (spec §16.30):
--- remove the build directories (rm -rf, not the build system's own artifact
--- clean) and drop the config units back to `unconfigured`, so the next build
--- reconfigures from scratch. The profile itself is KEPT (unlike the editor's
--- delete). `--all` resets every build dir in the workspace — across all
--- profiles, including orphaned dirs. Destructive, so it confirms first: `-y` /
--- `--yes` skips the prompt; a non-interactive host without `-y` refuses rather
--- than deleting unprompted.
--- `opts.plan`: the token of a plan the user already confirmed from the
--- workspace daemon's listing (§19.15 "Reset": the second request could not
--- be routed) — nothing is listed or asked again, and a plan whose token
--- differs is refused (`reset_plan.CHANGED`) before anything is removed.
--- @param ws loomworks.Workspace
--- @param args string[]
--- @param opts? { plan?: string }
--- @return integer
function M.cmd_reset(ws, args, opts)
  opts = opts or {}
  local all, yes, profile_name = false, false, nil
  for i = 2, #args do
    local a = args[i]
    if a == "--all" then all = true
    elseif a == "-y" or a == "--yes" then yes = true
    elseif a:sub(1, 1) == "-" then
      die("unknown flag '" .. a .. "' — usage: lw reset [profile] [--all] [-y]")
    elseif not profile_name then profile_name = a
    else
      die("unexpected argument '" .. a .. "' — usage: lw reset [profile] [--all] [-y]")
    end
  end
  if all and profile_name then
    die("`lw reset --all` resets every profile — drop the profile argument")
  end

  -- The plan (spec §16.30) is loomworks.reset_plan's, shared with the
  -- workspace daemon (§19.15 "Reset"): the lock set (every computed build
  -- dir), the removal set (dirs on disk to remove), the listing, the token.
  local reset_plan = require("loomworks.reset_plan")
  local plan
  if all then
    plan = reset_plan.plan(ws, { all = true })
  else
    local profile
    profile, ws = resolve_build_target(ws, profile_name, "lw reset <profile>")
    plan = reset_plan.plan(ws, { profile = profile })
  end

  -- Confirmed against the daemon's listing: never remove a directory the
  -- user was not shown (§19.15 "Reset").
  if opts.plan and opts.plan ~= plan.token then die(reset_plan.CHANGED) end

  if reset_plan.is_empty(plan) then
    out(reset_plan.nothing_message(plan))
    return 0
  end

  if not opts.plan then
    for _, line in ipairs(reset_plan.listing(plan)) do out(line) end
  end

  -- Destructive → confirm. `-y` skips; a non-interactive host without it refuses
  -- rather than deleting unprompted (spec §16.30).
  if not yes and not opts.plan then
    if not interactive() then die(reset_plan.unconfirmed_message(plan)) end
    local answer = prompt_line(reset_plan.prompt(plan))
    answer = (answer or ""):lower()
    if answer ~= "y" and answer ~= "yes" then
      die(reset_plan.ABORTED)
    end
  end

  -- Exclusive like clean/delete: hold every target dir's lock across the async
  -- deletion (spec §16.6, §16.30). reset_plan.execute runs the deletion and
  -- then VERIFIES genuine on-disk absence (polling out delete-pending without
  -- blocking) — reset must not report success while a build tree survives.
  -- This host waits on it; the daemon keeps serving instead.
  local verify_ms = M._reset_verify_ms or reset_plan.VERIFY_MS
  local settled, res = false, nil
  -- Lock order (spec §19.3): the workspace operation lock first, then every
  -- build directory's lock; the workspace's own deletion re-enters both.
  local op_tok = ws:_op_lock("reset")
  on_exit(function() require("loomworks.op_lock").release(op_tok) end)
  with_build_dir_locks(plan.lock_dirs, "reset", function()
    -- Under the locks, before anything is removed: the plan must still be the
    -- one listed (a dir another process created meanwhile is refused, never
    -- removed unseen; spec §16.30).
    local vok, vmsg = reset_plan.verify(ws, plan)
    if not vok then
      settled, res = true, { code = 1, msg = vmsg }
      return
    end
    reset_plan.execute(ws, plan, { verify_ms = verify_ms }, function(code, msg)
      settled, res = true, { code = code, msg = msg }
    end)
    -- Backstop only: execute's own timers settle it (timeout / verify bound).
    vim.wait(reset_plan.TIMEOUT_MS + verify_ms + 5000, function() return settled end, 20)
  end, ws)
  require("loomworks.op_lock").release(op_tok)
  if not settled then die(reset_plan.TIMED_OUT) end
  if res.code ~= 0 then die(res.msg, res.code) end

  out(reset_plan.ok_line(plan))
  return 0
end

-- ---------------------------------------------------------------------------
-- Workspace trust (spec §17)
-- ---------------------------------------------------------------------------

--- The message for a refused `.nvim` file (spec §17.10). `t` is the setup
--- error's `trust` table `{ kind = "user"|"cache", status }`.
--- @param t table
--- @return string
function M._trust_refusal_message(t)
  if t.kind == "cache" then
    return ".nvim/loomworks.cache.json was not written on this machine (its signature does not match).\n"
      .. "  It is not used. Reset the build cache (deletes .nvim/build and the cache): lw nuke"
  end
  local why = (t.status == "unsigned")
    and "is not signed by this machine (written by hand, or by an earlier lw)"
    or "was modified outside loomworks (its signature does not match this machine)"
  return ".nvim/loomworks.user.json " .. why .. ".\n"
    .. "  It is not used until you review it.\n"
    .. "  Review and trust it:  lw trust\n"
    .. "  Or discard it:        lw trust --discard\n"
    .. "  (`lw help trust` explains why.)"
end

--- `lw trust [--yes] [--discard]` — review the working copy and re-sign it
--- for this machine, or discard it (spec §17.4, §17.10). Works on a refused
--- workspace: it never loads the workspace.
--- @param root string
--- @param args string[]
--- @return integer
function M.cmd_trust(root, args)
  local yes, discard = false, false
  for i = 2, #args do
    local v = args[i]
    if v == "-y" or v == "--yes" then yes = true
    elseif v == "--discard" then discard = true
    else die("unknown argument '" .. v .. "' — usage: lw trust [--yes] [--discard]") end
  end
  local trust = require("loomworks.trust")
  local io_mod = require("loomworks.io")
  local user = require("loomworks.user")
  local path = user.filepath(root)

  -- The build cache's state, reported alongside (its only remedy is a reset).
  local function cache_note()
    local ctext = io_mod.read_file(require("loomworks.cache").filepath(root))
    if ctext and trust.verify("cache", ctext) == "invalid" then
      out("note: .nvim/loomworks.cache.json was not written on this machine — reset it with `lw nuke`.")
    end
  end

  local text = io_mod.read_file(path)
  if not text then
    out("no working copy (.nvim/loomworks.user.json) — nothing to trust.")
    cache_note()
    return 0
  end
  local status, content = trust.verify("user", text)

  if discard then
    -- Removes the working copy and its backup: the workspace operation lock
    -- (spec §19.3) keeps a concurrent publish / import out of the middle. It
    -- is taken before the notice and any prompt, so a refusal prints alone:
    -- held from here with --yes; with a prompt only checked (a lock held
    -- across a blocking prompt stops heartbeating) and taken after the answer.
    local op_lock = require("loomworks.op_lock")
    local tok, lmsg = op_lock.acquire(root, "trust --discard")
    if not tok then die(lmsg) end
    if not yes then op_lock.release(tok) end
    out("Will delete " .. path .. " (the working copy: profiles, local configuration, settings).")
    if not yes then
      if not interactive() then
        die("refusing to discard the working copy without confirmation.\n  Re-run with --yes.")
      end
      local answer = (prompt_line("Discard it? [y/N]") or ""):lower()
      if answer ~= "y" and answer ~= "yes" then die("aborted — nothing was deleted") end
      tok, lmsg = op_lock.acquire(root, "trust --discard")
      if not tok then die(lmsg) end
    end
    if tok.recovered then errw("lw: " .. tok.recovered .. "\n") end
    on_exit(function() op_lock.release(tok) end)
    for _, p in ipairs({ path, path .. ".bak" }) do
      local ok, err = io_mod.rm_rf(p)
      if not ok then die("could not delete " .. p .. ": " .. tostring(err)) end
    end
    op_lock.release(tok)
    out("DISCARDED: " .. path)
    return 0
  end

  if status == "valid" then
    out(".nvim/loomworks.user.json is trusted (signed by this machine) — nothing to do.")
    cache_note()
    return 0
  end

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    die(path .. " is not valid JSON — fix it, or discard it with `lw trust --discard`")
  end
  out(path)
  out(status == "unsigned"
    and "  is not signed by this machine (written by hand, or by an earlier lw)."
    or "  was modified outside loomworks, or copied from another machine.")
  out("")
  local prog, other = require("loomworks.program_fields").review(decoded, require("loomworks.modules"))
  out("Program settings — what loomworks may run on this file's word:")
  if #prog == 0 then out("  (none)") end
  for _, l in ipairs(prog) do out("  " .. l) end
  out("Other contents:")
  for _, l in ipairs(other) do out("  " .. l) end
  out("")
  if not yes then
    if not interactive() then
      die("refusing to trust without confirmation.\n"
        .. "  Review the summary above, then re-run with --yes.")
    end
    local answer = (prompt_line("Trust this working copy? [y/N]") or ""):lower()
    if answer ~= "y" and answer ~= "yes" then die("aborted — the working copy stays untrusted") end
  end
  local sok, serr = trust.sign_file(path, "user", content)
  if not sok then die("could not sign " .. path .. ": " .. tostring(serr)) end
  out("TRUSTED: .nvim/loomworks.user.json (signed for this machine)")
  cache_note()
  return 0
end

--- `lw nuke [-y]` — reset the build cache: delete `.nvim/build/`, the cache
--- and the health cache (spec §17.4). The remedy for a cache this machine did
--- not write; destructive, so it confirms (and `-y` is mandatory when
--- non-interactive, like `lw reset`).
--- @param root string
--- @param args string[]
--- @return integer
function M.cmd_nuke(root, args)
  local yes = false
  for i = 2, #args do
    local v = args[i]
    if v == "-y" or v == "--yes" then yes = true
    else die("unknown argument '" .. v .. "' — usage: lw nuke [-y]") end
  end
  local core = require("loomworks")._core()
  -- The locks first (spec §19.3), BEFORE the list of what would go and any
  -- prompt: a refused nuke prints only its refusal. With -y they are held
  -- from here to the deletion. Otherwise they are only checked here (taken
  -- and released: a lock held across a blocking prompt stops heartbeating)
  -- and taken again once confirmed; the check never breaks a holder —
  -- `--break-locks` acts only on the confirmed nuke.
  local st, why
  if yes then
    st, why = core:_nuke_begin(root)
    if not st then die(M._nuke_message(why)) end
  else
    local lock_break = require("loomworks.lock_break")
    local requested = lock_break.requested
    lock_break.requested = nil
    local ok, cwhy = core:nuke_check(root)
    lock_break.requested = requested
    if not ok and not requested then die(M._nuke_message(cwhy)) end
  end
  local targets = {
    root .. "/.nvim/build/",
    require("loomworks.cache").filepath(root),
    root .. "/.nvim/loomworks.health.json",
  }
  out("Will delete (build state only; your configuration is kept):")
  for _, p in ipairs(targets) do out("  " .. p) end
  if not yes then
    if not interactive() then
      die("refusing to delete build state without confirmation.\n  Re-run with -y.")
    end
    local answer = (prompt_line("Reset the build cache? [y/N]") or ""):lower()
    if answer ~= "y" and answer ~= "yes" then die("aborted — nothing was deleted") end
    st, why = core:_nuke_begin(root)
    if not st then die(M._nuke_message(why)) end
  end
  local errors = {}
  local saved_notify = core._deps.notify
  core._deps.notify = function(msg, level)
    if level and level >= vim.log.levels.ERROR then errors[#errors + 1] = M._nuke_message(msg) end
  end
  local done = core:_nuke_run(st)
  core._deps.notify = saved_notify
  if not done or #errors > 0 then die(M._nuke_failure(errors)) end
  out("NUKED: build state removed — the next build reconfigures from scratch.")
  return 0
end

--- A core nuke message as the CLI prints it: core's own `loomworks: `
--- prefix dropped (`die` adds `lw: `).
--- @param msg any
--- @return string
function M._nuke_message(msg)
  return (tostring(msg or "nuke failed"):gsub("^loomworks: ", ""))
end

--- The message for the errors a running nuke reported: one refusal stands
--- alone (`cannot nuke: …`), one failure reads `nuke failed: …`, several go
--- on their own lines under `nuke failed:`.
--- @param errors string[] already stripped (`_nuke_message`)
--- @return string
function M._nuke_failure(errors)
  if #errors == 0 then return "nuke failed" end
  if #errors == 1 then
    return errors[1]:find("^cannot nuke: ") and errors[1] or ("nuke failed: " .. errors[1])
  end
  return "nuke failed:\n  " .. table.concat(errors, "\n  ")
end

--- `lw unlock <profile|dir> | --all [--force]` — clear build-dir locks
--- (spec §16.6, §19.5). Without `--force` only a lock whose holder is gone (dead,
--- or stale where it cannot be checked) is removed — its interrupted step's
--- state recovered as on any reclaim; a live or hung holder's lock is refused,
--- naming the holder. `--force` removes the record whatever the holder's state,
--- WITHOUT stopping it, after warning that it may still be running and writing.
--- `--device <serial>` clears a device lock (§18.7; always forced).
function M.cmd_unlock(ws, args, root)
  local all, profile_name, device_serial, force, workspace = false, nil, nil, false, false
  local i = 2
  while args[i] do
    if args[i] == "--all" then all = true; i = i + 1
    elseif args[i] == "--force" then force = true; i = i + 1
    elseif args[i] == "--journal" then return M._unlock_journal(root or (ws and ws.root))
    elseif args[i] == "--workspace" then workspace = true; i = i + 1
    elseif args[i] == "--device" then
      device_serial = args[i + 1]
      if not device_serial then die("--device requires a serial") end
      i = i + 2
    elseif not profile_name then profile_name = args[i]; i = i + 1
    else i = i + 1 end
  end

  -- `lw unlock --device <serial>` clears a device lock (spec §18.7).
  if device_serial then
    local device_lock = require("loomworks.remote.device_lock")
    -- A recorded program (in the lock or the leftover file) is only
    -- reported, never reaped: the holder may be alive and still running it
    -- (spec §18.7). The leftover file stays for the next acquisition.
    local function report(left, where)
      errw("lw: " .. where .. " recorded " .. (left.program:match("([^/]+)$") or left.program)
        .. " (pid " .. left.pid .. ") on " .. device_serial .. " (" .. left.program .. ")"
        .. "; it was not stopped and may still be running there\n")
    end
    local file_left = device_lock.load_leftover(device_serial)
    local info = device_lock.read(device_serial)
    if not info then
      out("no device lock for " .. device_serial)
      if file_left then report(file_left, "an earlier run that lost its connection") end
      return 0
    end
    if not info.stale then
      errw("lw: forcing an ACTIVE device lock (" .. device_lock.holder(info, device_serial) .. " ago)\n")
      M._record_recovery(root or (ws and ws.root), "lw unlock --device: forced the active device lock of "
        .. device_serial .. " held by pid " .. tostring(info.pid))
    end
    device_lock.force(device_serial)
    out("unlocked device " .. device_serial)
    local left = device_lock.leftover_of(info)
    if left then report(left, "the lock") end
    if file_left and not (left and left.nonce == file_left.nonce) then
      report(file_left, "an earlier run that lost its connection")
    end
    return 0
  end

  -- `lw unlock --workspace` clears the workspace operation lock (spec §19.3);
  -- `--all` includes it.
  if workspace and not all and not profile_name then
    return M._unlock_workspace(root or (ws and ws.root), force)
  end
  if all then
    local code = M._unlock_workspace(ws.root, force, true)
    if code ~= 0 then return code end
  end
  return M._unlock_build_dirs(ws, all, profile_name, force)
end

--- Discard a stuck commit journal (`lw unlock --journal`, spec §19.4): under
--- the workspace operation lock (taken WITHOUT completing the journal), remove
--- exactly `.nvim/loomworks.txn.json` and the stray staged copies of the three
--- workspace files (`<file>.txn-<hex>`, regular files). The files stay as
--- they are — possibly a mix of the interrupted operation's old and new state.
--- @param root string
--- @return integer exit code
function M._unlock_journal(root)
  local txn = require("loomworks.txn")
  local op_lock = require("loomworks.op_lock")
  local j, why = txn.read_journal(root)
  if j == nil and #txn.strays(root) == 0 then
    out("no commit journal")
    return 0
  end
  local tok, lmsg = op_lock.acquire(root, "unlock --journal", { no_recover = true })
  if not tok then die(lmsg) end
  on_exit(function() op_lock.release(tok) end)
  local removed = txn.discard_locked(root)
  op_lock.release(tok)
  for _, p in ipairs(removed) do out("removed " .. p) end
  if j ~= nil then
    errw("lw: WARNING: discarded the journal of an interrupted "
      .. (j and tostring(j.operation or "operation") or ("operation (the journal " .. tostring(why) .. ")"))
      .. " — the workspace files may now mix its old and new state; check them (`lw status`), or "
      .. "reset the build state (`lw nuke`)\n")
  end
  return 0
end

--- Clear the workspace operation lock (`lw unlock --workspace`, `--all`):
--- a gone holder's lock is removed (nonce-checked); a running or hung one only
--- with `force`, loudly, without stopping it. `quiet` = say nothing when free.
--- @param root string
--- @param force boolean
--- @param quiet? boolean
--- @return integer exit code
function M._unlock_workspace(root, force, quiet)
  local op_lock = require("loomworks.op_lock")
  local build_lock = require("loomworks.build_lock")
  local lock_record = require("loomworks.lock_record")
  local path = op_lock.path(root)
  local info = build_lock.read_path(path)
  if not info then
    if not quiet then out("no workspace operation lock") end
    return 0
  end
  info.state = lock_record.classify(info)
  if lock_record.RECLAIMABLE[info.state] then
    if build_lock.reclaim_path(path) then out("unlocked the workspace operation lock") end
    return 0
  end
  if not force then
    errw("lw: " .. lock_record.busy_message(info, op_lock.ctx()) .. "\n")
    die("the workspace operation lock was left in place — its holder is running (use --force "
      .. "to remove the record anyway, or the command's --break-locks to stop the holder)")
  end
  errw(string.format("lw: WARNING: removing the workspace operation lock held by %s (pid %s%s, %s) "
    .. "without stopping it — it may still be running and writing\n", lock_record.holder_text(info),
    tostring(info.pid or "?"), lock_record.same_host(info) and "" or (" on " .. tostring(info.host)),
    info.state))
  M._record_recovery(root, "lw unlock --force: removed the workspace operation lock held by pid "
    .. tostring(info.pid) .. " (" .. tostring(info.state) .. ")")
  build_lock.force_path(path)
  out("unlocked the workspace operation lock")
  return 0
end

--- The build-directory part of `lw unlock` (see M.cmd_unlock). `name` is a
--- profile, or a build directory (relative to the workspace root, or
--- absolute) that must lie under the root (separator-bounded), both as
--- spelled and by identity (loomworks.dir_identity: its real path must lie
--- under the root's real path, so a junction / symlink to a folder outside
--- the workspace is refused): only `<dir>.loomworks-lock` beside that
--- identity — exactly that regular file — is ever removed.
--- @param ws loomworks.Workspace
--- @param all boolean
--- @param name string|nil
--- @param force boolean
--- @return integer exit code
function M._unlock_build_dirs(ws, all, name, force)
  local build_lock = require("loomworks.build_lock")
  local lock_record = require("loomworks.lock_record")
  local targets = {}
  if all then
    for _, p in ipairs(ws._profiles or {}) do
      for _, bd in ipairs(profile_build_dirs(p)) do targets[#targets + 1] = bd end
    end
  else
    if not name then
      die("usage: lw unlock <profile> | <build dir> | --all [--force] | --device <serial>")
    end
    -- A name with a path separator is a build directory; else a profile.
    local is_path = name:find("[/\\]") ~= nil
    local hit = not is_path and match_profile_arg(ws, name) or nil
    if not is_path and not hit then
      die("no profile matching '" .. name .. "' (a build directory is named by its path, e.g. "
        .. ".nvim/build/App/Debug). Run `lw profile list` to list.")
    end
    if hit then
      for _, bd in ipairs(profile_build_dirs(hit)) do targets[#targets + 1] = bd end
    else
      local p = name:gsub("\\", "/"):gsub("/+$", "")
      -- No `.` / `..` segments: the prefix check below compares spellings,
      -- so `../x` must never pass for a path under the root.
      for seg in p:gmatch("[^/]+") do
        if seg == "." or seg == ".." then
          die("a build directory is named by a plain path under the workspace root "
            .. "(no '.' or '..' segments): " .. name)
        end
      end
      if not (p:match("^%a:/") or p:sub(1, 1) == "/") then p = ws.root .. "/" .. p end
      local nr, np = norm_cmp(ws.root), norm_cmp(p)
      if np:sub(1, #nr + 1) ~= nr .. "/" then
        die("no profile matching '" .. name .. "', and it is not a directory under the workspace root")
      end
      -- The lockfile sits beside the directory's IDENTITY (build_lock.lock_path),
      -- so the spelled check above is not enough: a junction / symlink under
      -- the root can point outside it. Require the identity under the
      -- root's identity too (separator-bounded), else refuse.
      local identity = require("loomworks.dir_identity")
      local rr, ri = norm_cmp(identity.resolve(ws.root)), norm_cmp(identity.resolve(p))
      if ri:sub(1, #rr + 1) ~= rr .. "/" then
        die("'" .. name .. "' resolves to " .. identity.resolve(p) .. ", outside the workspace root; "
          .. "lw unlock does not remove its lockfile " .. build_lock.lock_path(p)
          .. " — remove it by hand if its holder is gone")
      end
      targets[1] = p
    end
  end

  local removed, refused = 0, 0
  for _, bd in ipairs(M._lock_order(targets)) do
    local path = build_lock.lock_path(bd)
    local shown = ws:_display_build_dir(bd)
    local info = build_lock.read_path(path)
    if info then
      info.state = lock_record.classify(info)
      local gone
      if lock_record.RECLAIMABLE[info.state] then
        gone = build_lock.reclaim_path(path) ~= nil
      elseif force then
        errw(string.format("lw: WARNING: removing the lock of %s held by %s (pid %s%s, %s) without "
          .. "stopping it — it may still be running and writing there\n", shown,
          lock_record.holder_text(info), tostring(info.pid or "?"),
          lock_record.same_host(info) and "" or (" on " .. tostring(info.host)), info.state))
        M._record_recovery(ws.root, "lw unlock --force: removed the lock of " .. shown .. " held by pid "
          .. tostring(info.pid) .. " (" .. tostring(info.state) .. ")")
        gone = build_lock.force_path(path)
      else
        refused = refused + 1
        errw("lw: " .. lock_record.busy_message(info, { what = shown, command = "lw build",
          unlock = shown }) .. "\n")
      end
      if gone then
        removed = removed + 1
        out("unlocked " .. shown)
        local line = ws:_recover_interrupted_build_dir(bd, info)
        if line then errw("lw: " .. line .. "\n") end
      end
    end
  end
  if refused > 0 then
    die(string.format("%d lock%s left in place — its holder is running (use --force to remove the "
      .. "record anyway, or the command's --break-locks to stop the holder)", refused,
      refused == 1 and " was" or "s were"))
  end
  if removed == 0 then out("no build-dir locks to clear") end
  return 0
end

-- ---------------------------------------------------------------------------
-- Devices (spec §16.34, §18.3)
-- ---------------------------------------------------------------------------

-- Device-command helpers live in one table: the CLI chunk is close to Lua's
-- 200-locals-per-function limit.
local DEV = {}

--- The profile a device command is scoped to without dying: a named one
--- (dies when unknown), else — interactive only — the active / sole profile;
--- nil means "no profile" (every declared SDK's runner is in scope, §16.34).
function DEV.soft_profile(ws, name)
  if name then return resolve_profile(ws, name) end
  if not interactive() then return nil end
  local profiles = ws._profiles or {}
  local active = ws._active_profile_key
  for _, p in ipairs(profiles) do if p.key == active then return p end end
  if #profiles == 1 then return profiles[1] end
  return nil
end

--- Parse a positive number option value (`--timeout 30`).
function DEV.parse_seconds(flag, v)
  local n = tonumber(v)
  if not n or n <= 0 then die(flag .. " requires a positive number of seconds (got '" .. tostring(v) .. "')") end
  return n
end
M._parse_seconds = DEV.parse_seconds

--- Serial → profile keys that persist it (§1.8).
function DEV.persisted_serials(ws)
  local map = {}
  for _, p in ipairs(ws._profiles or {}) do
    if p._device_serial then
      map[p._device_serial] = map[p._device_serial] or {}
      table.insert(map[p._device_serial], p.key)
    end
  end
  for _, keys in pairs(map) do table.sort(keys) end
  return map
end

--- Fresh per-invocation device options for `run` / `test` (spec §16.34).
function DEV.new_device_opts()
  return { timeouts = {}, log_options = nil }
end

--- Consume one device option at `argv[i]` into `o` (setting `o._next`).
--- Returns false when `argv[i]` is not a device option. Options: `--device
--- <serial>`, `--fresh`, `--timeout <s>`, `--query-timeout <s>`,
--- `--transfer-timeout <s>`, `--log <key>=<value>` (repeatable; CLI wins per
--- key), `--no-wait`.
--- @return boolean
function DEV.parse_device_opt(argv, i, o)
  local v = argv[i]
  if v == "--device" then
    o.device = argv[i + 1]
    if not o.device or o.device == "" then die("--device requires a serial") end
    o._next = i + 2
  elseif v == "--fresh" then o.fresh = true; o._next = i + 1
  elseif v == "--no-wait" then o.no_wait = true; o._next = i + 1
  elseif v == "--timeout" then o.timeout = DEV.parse_seconds(v, argv[i + 1]); o._next = i + 2
  elseif v == "--query-timeout" then o.timeouts.query = DEV.parse_seconds(v, argv[i + 1]); o._next = i + 2
  elseif v == "--transfer-timeout" then o.timeouts.transfer = DEV.parse_seconds(v, argv[i + 1]); o._next = i + 2
  elseif v == "--log" then
    local k, val = require("loomworks.remote.run").parse_log_arg(argv[i + 1] or "")
    if not k then die(val) end
    o.log_options = o.log_options or {}
    o.log_options[k] = val
    o._next = i + 2
  else
    return false
  end
  return true
end
M._parse_device_opt = DEV.parse_device_opt
M._new_device_opts = DEV.new_device_opts

--- `lw device list [--json]` body (spec §16.34): the attached devices each
--- runner in scope reports. Read-only. `deps.backend` (tests) is the process
--- backend. Returns the exit code.
--- @param ws loomworks.Workspace
--- @param opts { json?: boolean, profile?: string, timeouts?: table }
--- @param deps? { backend?: table }
--- @return integer
function M._device_list(ws, opts, deps)
  deps = deps or {}
  local runners = require("loomworks.remote.runners")
  local devices = require("loomworks.remote.devices")
  local profile = DEV.soft_profile(ws, opts.profile)
  local scope = runners.in_scope(ws, profile)
  if #scope == 0 then
    die("no device runner available — none of the SDKs in scope" ..
      (profile and (" (profile '" .. profile.key .. "')") or "") ..
      " supplies one (declare the SDK with `lw sdk add`, and install a plugin whose SDK provider ships a device runner)")
  end
  local persisted = DEV.persisted_serials(ws)
  local rows, failed = {}, 0
  for _, e in ipairs(scope) do
    local list, err = devices.list(e.runner, { backend = deps.backend, timeouts = opts.timeouts,
      describe = true })
    if not list then
      failed = failed + 1
      errw("lw: " .. tostring(err) .. "\n")
    else
      devices.merge(ws, e.runner.id, list)
      for _, d in ipairs(list) do
        rows[#rows + 1] = { serial = d.serial, state = d.state, runner = e.runner.id,
          name = d.display_name, profiles = persisted[d.serial] or {} }
      end
    end
  end
  if opts.json then
    local list = {}
    for _, r in ipairs(rows) do
      -- `profiles` (the profiles persisting this serial) is omitted when none.
      list[#list + 1] = { serial = r.serial, state = r.state, runner = r.runner, name = r.name,
        profiles = #r.profiles > 0 and r.profiles or nil }
    end
    out(vim.json.encode({ devices = list }))
  else
    local w = { 6, 5, 6 }
    for _, r in ipairs(rows) do
      w[1] = math.max(w[1], #r.serial); w[2] = math.max(w[2], #r.state); w[3] = math.max(w[3], #r.runner)
    end
    local fmt = "%-" .. w[1] .. "s  %-" .. w[2] .. "s  %-" .. w[3] .. "s  %s"
    if #rows == 0 then
      out("no devices attached")
    else
      out(string.format(fmt, "SERIAL", "STATE", "RUNNER", "NAME"))
      for _, r in ipairs(rows) do
        local tail = #r.profiles > 0 and ("   (device for " .. table.concat(r.profiles, ", ") .. ")") or ""
        out(string.format(fmt, r.serial, r.state, r.runner, r.name) .. tail)
      end
    end
  end
  return failed > 0 and 1 or 0
end

--- `lw device select <serial> [profile]` / `lw device select --clear [profile]`
--- body: persist (or clear) the profile's device serial in the working copy
--- (§1.8, §16.9). Never requires the device to be attached.
--- @return integer
function M._device_select(ws, args)
  local clear, positionals = false, {}
  for _, v in ipairs(args) do
    if v == "--clear" then clear = true else positionals[#positionals + 1] = v end
  end
  local serial, profile_name
  if clear then
    profile_name = positionals[1]
    if #positionals > 1 then die("usage: lw device select --clear [profile]") end
  else
    serial, profile_name = positionals[1], positionals[2]
    if not serial or #positionals > 2 then
      die("usage: lw device select <serial> [profile] | lw device select --clear [profile]")
    end
    if serial:find("[%c]") then die("invalid device serial") end
  end
  local profile = resolve_profile(ws, profile_name, { usage = "lw device select <serial> <profile>" })
  if clear then
    if not profile._device_serial then
      out("profile '" .. profile.key .. "' has no device selected")
      return 0
    end
    profile:clear_device()
    out("cleared the device of profile '" .. profile.key .. "'")
    return 0
  end
  profile:set_device(serial)
  out("device for profile '" .. profile.key .. "': " .. serial)
  return 0
end

--- Resolve (runner, serial) for a device operation from the runners in scope:
--- the device is chosen per §18.3 (explicit > the profile's persisted serial >
--- the sole online device) across every runner's listing. Dies on ambiguity.
--- @return loomworks.Runner runner, string serial
function DEV.pick_device(ws, profile, explicit, opts, deps)
  local runners = require("loomworks.remote.runners")
  local devices = require("loomworks.remote.devices")
  local scope = runners.in_scope(ws, profile)
  if #scope == 0 then die("no device runner available for this workspace") end
  local all, owner = {}, {}
  for _, e in ipairs(scope) do
    local list, err = devices.list(e.runner, { backend = deps and deps.backend, timeouts = opts.timeouts })
    if not list then die(err) end
    devices.merge(ws, e.runner.id, list)
    for _, d in ipairs(list) do
      if not owner[d.serial] then owner[d.serial] = e.runner; all[#all + 1] = d end
    end
  end
  local serial, err = devices.select(all, {
    explicit = explicit, persisted = profile and profile._device_serial or nil,
    runner_id = #scope == 1 and scope[1].runner.id or "*", profile_key = profile and profile.key,
  })
  if not serial then die(err) end
  return owner[serial], serial
end
M._pick_device = DEV.pick_device

DEV.BLOCK_USAGE = "usage: lw project set <project> device.stage|device.archive <glob>...\n"
  .. "       lw project set <project> device.working_dir <dir>\n"
  .. "       lw project set <project> device.env.<NAME> <value>\n"
  .. "       lw project unset <project> device[.stage|.archive|.working_dir|.env[.<NAME>]]"

--- `lw project set <project> device.<field> <value>...` (spec §18.9, §16.9):
--- edit the project's device block in the working copy. `stage` / `archive`
--- take one or more globs and replace the list; `working_dir` one path;
--- `env.<NAME>` one value (upsert).
--- @param root string
--- @param pos string[] positionals: project, field, values...
--- @return integer
function DEV.project_device_set(root, pos)
  local proj_name, field = pos[1], pos[2]
  local values = {}
  for i = 3, #pos do values[#values + 1] = pos[i] end
  local sub, name = field:match("^device%.([%w_]+)%.?(.*)$")
  if not sub or #values == 0 then die(DEV.BLOCK_USAGE) end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local block = vim.deepcopy(proj.device or {})
  if (sub == "stage" or sub == "archive") and name == "" then
    block[sub] = values
  elseif sub == "working_dir" and name == "" and #values == 1 then
    block.working_dir = values[1]
  elseif sub == "env" and name ~= "" and #values == 1 then
    block.env = type(block.env) == "table" and block.env or {}
    block.env[name] = values[1]
  else
    die("cannot set '" .. field .. "'\n" .. DEV.BLOCK_USAGE)
  end
  local ok, err = proj:save_device(block)
  if not ok then die(err or "failed to update the device block") end
  out(string.format("%s: %s = %s  (working copy: projects.%s.%s.device)", proj.key, field,
    table.concat(values, " "), proj.key, proj.type or "?"))
  return 0
end

--- `lw project unset <project> device[.<field>[.<NAME>]]`.
--- @return integer
function DEV.project_device_unset(root, proj_name, field)
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local block = vim.deepcopy(proj.device or {})
  local sub, name = field:match("^device%.([%w_]+)%.?(.*)$")
  if field == "device" then
    block = nil
  elseif sub == "env" and name ~= "" then
    if not (type(block.env) == "table" and block.env[name] ~= nil) then
      die("project '" .. proj.key .. "' sets no device.env." .. name)
    end
    block.env[name] = nil
    if next(block.env) == nil then block.env = nil end
  elseif (sub == "stage" or sub == "archive" or sub == "working_dir" or sub == "env") and name == "" then
    if block[sub] == nil then die("project '" .. proj.key .. "' sets no device." .. sub) end
    block[sub] = nil
  else
    die("cannot unset '" .. field .. "'\n" .. DEV.BLOCK_USAGE)
  end
  local ok, err = proj:save_device(block)
  if not ok then die(err or "failed to update the device block") end
  out(string.format("%s: removed %s", proj.key, field))
  return 0
end

--- `lw device clean [--device <serial>] [--no-wait] [profile]` body: remove
--- this workspace's staging root from the device (§18.12) and its sync record.
--- @return integer
function M._device_clean(ws, args, deps)
  local explicit, no_wait, profile_name = nil, false, nil
  local opts = { timeouts = {} }
  local i = 1
  while args[i] do
    local v = args[i]
    if v == "--device" then explicit = args[i + 1]; i = i + 2
    elseif v == "--no-wait" then no_wait = true; i = i + 1
    elseif v == "--query-timeout" then opts.timeouts.query = DEV.parse_seconds(v, args[i + 1]); i = i + 2
    elseif not profile_name and not v:match("^%-") then profile_name = v; i = i + 1
    else die("usage: lw device clean [--device <serial>] [--no-wait] [profile]") end
  end
  local profile = DEV.soft_profile(ws, profile_name)
  local runner, serial = DEV.pick_device(ws, profile, explicit, opts, deps)
  local man = require("loomworks.remote.manifest")
  local ws_prefix = man.device_roots(runner.staging_base, ws.name or "workspace", "_")
  local device_lock = require("loomworks.remote.device_lock")
  local h, lerr = device_lock.acquire(serial, {
    wait = not no_wait, action = "clean", workspace = ws.name,
    on_wait = function(msg) errw("lw: " .. msg .. "\n") end,
  })
  if not h then die(lerr) end
  on_exit(function() device_lock.release(h) end)
  local transport = require("loomworks.remote.transport").new({
    runner = runner, serial = serial, backend = deps and deps.backend, timeouts = opts.timeouts })
  -- A reclaimed stale lock or the leftover file may name a program an
  -- interrupted run left running from the staging root about to be removed
  -- (spec §18.7).
  require("loomworks.remote.run").reap_on_acquire(runner, serial, h, {
    backend = deps and deps.backend, timeout = transport.timeouts.query,
    note = function(s) errw("lw: " .. s .. "\n") end })
  local ok, err, base_removed = require("loomworks.remote.staging").clean(transport, ws_prefix, runner.staging_base)
  device_lock.release(h)
  if not ok then die(err) end
  -- Drop the sync records of every staging root under this workspace prefix.
  local recs = ws._device_sync and ws._device_sync[serial]
  if recs then
    for root in pairs(recs) do
      if man.device_path_under(root, ws_prefix) then recs[root] = nil end
    end
    if next(recs) == nil then ws._device_sync[serial] = nil end
    if ws._save_cache then ws:_save_cache() end
  end
  out("removed " .. ws_prefix .. " from " .. serial)
  if base_removed then out("removed empty " .. runner.staging_base:gsub("/+$", "") .. " from " .. serial) end
  out("cleared host sync record")
  return 0
end

--- `lw device <list|select|clean>` (spec §16.34).
function M.cmd_device(sub, root, args)
  local rest = {}
  for i = 3, #args do rest[#rest + 1] = args[i] end
  if sub == "list" or sub == "ls" then
    local opts = { timeouts = {} }
    local i = 1
    while rest[i] do
      local v = rest[i]
      if v == "--json" then opts.json = true; i = i + 1
      elseif v == "--query-timeout" then opts.timeouts.query = DEV.parse_seconds(v, rest[i + 1]); i = i + 2
      elseif not opts.profile and not v:match("^%-") then opts.profile = v; i = i + 1
      else die("unexpected argument '" .. v .. "' — usage: lw device list [--json] [profile]") end
    end
    local ws = load_workspace(root, false)
    return M._device_list(ws, opts)
  elseif sub == "select" then
    local ws = load_workspace(root, false)
    return M._device_select(ws, rest)
  elseif sub == "clean" then
    local ws = load_workspace(root, false)
    return M._device_clean(ws, rest)
  end
  die("usage: lw device list [--json] | lw device select <serial> [profile] [--clear] | " ..
    "lw device clean [--device <serial>]")
end

--- Ensure a config unit's build targets are parsed (loomworks.build_run).
--- Requires a configured build dir, so the caller must build first.
ensure_unit_targets = function(ws, unit)
  return require("loomworks.build_run").ensure_unit_targets(ws, unit)
end

--- `lw test [profile] [--junit <file>] [-- <args>]` — build a profile, then run
--- its tests via each module's native runner, reporting a real exit code.
--- Args after `--` are forwarded to the native batch runner (e.g.
--- `-- -j 4` / `-- --num-processes 4`). `--junit <file>` writes JUnit XML for CI
--- (one file per unit — a label suffix when a profile runs several).
function M.cmd_test(ws, args)
  local overseer = require("loomworks.overseer")
  local build_run = require("loomworks.build_run")
  -- Split on `--`: everything after is forwarded to the native test runner.
  local pre, extra, seen_sep = {}, {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then extra[#extra + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  -- Pre-`--` tokens: `--junit <file>`, `--target <exe>` (repeatable), device
  -- options (§16.34) and a positional profile.
  local profile_name, junit
  local names, dev_opts = {}, DEV.new_device_opts()
  local i = 1
  while pre[i] do
    if pre[i] == "--junit" then
      junit = pre[i + 1]
      if not junit then die("--junit requires a file path") end
      i = i + 2
    elseif pre[i] == "--target" then
      if not pre[i + 1] then die("--target requires a test executable name") end
      names[#names + 1] = pre[i + 1]
      i = i + 2
    elseif DEV.parse_device_opt(pre, i, dev_opts) then i = dev_opts._next
    elseif not profile_name then
      profile_name = pre[i]; i = i + 1
    else
      die("unexpected argument '" .. tostring(pre[i]) ..
        "' — usage: lw test [profile] [--target <exe>…] [--junit <file>] [-- args…]")
    end
  end
  if junit then junit = resolve_abs_out(junit, user_cwd()) end

  local profile
  profile, ws = resolve_build_target(ws, profile_name, "lw test <profile>")

  -- Named test executables run directly — locally or on a device (§16.16).
  if #names > 0 then
    return M._test_targets(ws, profile, names, { junit = junit, extra = extra, dev = dev_opts })
  end
  if dev_opts.device or dev_opts.fresh or dev_opts.timeout or dev_opts.no_wait or dev_opts.log_options then
    die("device options apply to named test executables: lw test <profile> --target <exe> …")
  end
  M._refuse_foreign_batch(profile)
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
      out(build_run.no_tests_line(profile, units))
      return
    end

    local okj, jerr = build_run.prepare_junit(junit)
    if not okj then die(jerr) end

    local failed, wrote = {}, {}
    for _, step in ipairs(test_steps) do
      out(string.format("==> [test] %s", step.name or "?"))
      local code = run_spec(step, ws.root)
      if code ~= 0 then failed[#failed + 1] = step.name or "?" end
      -- JUnit at the caller's path, also for a failed run (CI wants it).
      local path, warning = build_run.junit_result(step)
      if path then wrote[#wrote + 1] = path elseif warning then errw(warning) end
    end

    for _, p in ipairs(wrote) do out("JUnit: " .. p) end

    local ok_line, failure = build_run.test_summary(profile, failed, #test_steps)
    if failure then die(failure, 1) end
    out(ok_line)
  end)
  return 0
end

--- `lw init` — initialize the working copy (.nvim/loomworks.user.json).
-- ---------------------------------------------------------------------------
-- Launch configurations + run
-- ---------------------------------------------------------------------------

--- The launch-target enumeration, formatting and matching of `lw run` /
--- `lw target` / `lw test --target` live in loomworks.run_prep (shared with
--- the workspace daemon's `prepare_run`, §19.15); these are its local names.
--- `launchable_targets(ws, profile)` → candidates
--- `{ kind = "launch"|"target", project, name, target_id? }` (parses targets
--- on demand: build first).
local function launchable_targets(ws, profile)
  return require("loomworks.run_prep").launchable_targets(ws, profile)
end

--- Format a candidate for messages: `project:name (kind)`.
local function fmt_cand(c)
  return require("loomworks.run_prep").fmt_cand(c)
end

--- Build a LaunchTarget object from a resolved candidate.
local function candidate_launch_target(ws, profile, c)
  return require("loomworks.run_prep").candidate_launch_target(ws, profile, c)
end

--- Match a run operand `name` against a profile's launchable targets
--- (loomworks.run_prep.match_targets; `all` is injectable for testing).
--- @return table matches, table all
local function match_targets(ws, profile, name, proj_scope, kind, all)
  return require("loomworks.run_prep").match_targets(ws, profile, name, proj_scope, kind, all)
end
M._match_targets = match_targets

--- Resolve the (profile, target_name) for a `lw run` invocation from its parsed
--- operands, implementing the positional grammar of spec §16.17:
---   0 operands → resolved profile (§16.3) + its default target (target = nil);
---   1 operand  → the SAME resolved profile (§16.3) + the operand as a target
---                on it — a single operand is always a target, never a profile
---                selector;
---   2 operands → the named target on the named profile.
--- The named target is matched by the caller AFTER the build, so build targets
--- are visible. `resolve_build_target` is injectable via `deps.resolve` for
--- testing; production uses the module local. May die() when the profile can't
--- be resolved (§16.3). Returns (profile, target_name, ws) — ws may be a fresh
--- reload from resolve_build_target's onboarding path.
--- @param deps? { resolve?: function }
--- @return table profile, string|nil target_name, table ws
function M._run_selection(ws, positionals, deps)
  deps = deps or {}
  local resolve = deps.resolve or resolve_build_target
  -- A named profile needs the two-operand form (one operand is a target).
  local usage = "lw run <profile> <target>"
  local profile
  if #positionals >= 2 then
    profile, ws = resolve(ws, positionals[1], usage)
    return profile, positionals[2], ws
  elseif #positionals == 1 then
    -- One operand is always a target on the resolved profile (the same profile
    -- a bare `lw run` would pick), never a profile selector.
    profile, ws = resolve(ws, nil, usage)
    return profile, positionals[1], ws
  end
  profile, ws = resolve(ws, nil, usage)
  return profile, nil, ws
end

--- The device options of `lw run` / `lw test` (spec §18.3), each mapped to
--- whether it takes a value — what `_run_request` recognizes without parsing
--- them (a run with any of them is not routed, §19.15).
M.RUN_DEVICE_OPTIONS = { ["--device"] = true, ["--timeout"] = true, ["--query-timeout"] = true,
  ["--transfer-timeout"] = true, ["--log"] = true, ["--fresh"] = false, ["--no-wait"] = false }

--- @class loomworks.cli.RunArgs
--- @field positionals string[] the pre-`--` operands (§16.17 grammar: 0, 1 or 2)
--- @field proj_scope string|nil `--project`
--- @field kind "target"|"launch"|nil `--target` / `--launch`
--- @field cwd_override string|nil `--cwd` / `--working-dir`, verbatim
--- @field prefix_tokens string[] `--prefix`, shell-word split
--- @field print_mode "sh"|"json"|nil `--print` / `--dry-run` report format
--- @field dry_run boolean
--- @field no_build boolean `--no-build` (also set by `--dry-run`)
--- @field extra_args string[] the arguments after `--`
--- @field dev table device options (DEV.new_device_opts)
--- @field device_option boolean a device option was given

--- Parse a `lw run` argv (args[1] == "run"). `fail(msg)` reports a refusal
--- (cmd_run: die); `device(argv, i, o)` consumes a device option at
--- `argv[i]` into `o` (cmd_run: DEV.parse_device_opt), returning false when
--- it is none.
--- @param args string[]
--- @param fail fun(msg: string)
--- @param device fun(argv: string[], i: integer, o: table): boolean
--- @return loomworks.cli.RunArgs
function M._parse_run_args(args, fail, device)
  -- Split on `--`: everything after is forwarded verbatim to the program.
  local pre, extra_args, seen_sep = {}, {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then extra_args[#extra_args + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  -- Disambiguation flags (`--project <key>`, `--target`, `--launch`), a
  -- per-invocation `--cwd <dir>`, the launch `--prefix`, `--print`/`--dry-run`,
  -- and `--no-build`; remaining pre-`--` tokens are positional and follow the
  -- §16.17 operand grammar (0/1/2). None of the options consume the operands or
  -- the forwarded (post-`--`) args.
  local r = { positionals = {}, prefix_tokens = {}, no_build = false, dry_run = false,
    extra_args = extra_args, dev = DEV.new_device_opts(), device_option = false }
  local i = 1
  while pre[i] do
    if pre[i] == "--project" then r.proj_scope = pre[i + 1]; i = i + 2
    elseif pre[i] == "--target" then r.kind = "target"; i = i + 1
    elseif pre[i] == "--launch" then r.kind = "launch"; i = i + 1
    elseif pre[i] == "--cwd" or pre[i] == "--working-dir" then r.cwd_override = pre[i + 1]; i = i + 2
    elseif pre[i] == "--prefix" then
      local val = pre[i + 1]
      if val == nil then
        return fail("--prefix requires a wrapper command (e.g. `--prefix valgrind` or " ..
          "`--prefix 'valgrind --leak-check=full'`)")
      end
      for _, tok in ipairs(shell_split(val)) do r.prefix_tokens[#r.prefix_tokens + 1] = tok end
      i = i + 2
    elseif pre[i] == "--print" or pre[i] == "--dry-run" then
      r.print_mode, r.dry_run = "sh", r.dry_run or pre[i] == "--dry-run"; i = i + 1
    elseif pre[i]:match("^%-%-print=") or pre[i]:match("^%-%-dry%-run=") then
      r.dry_run = r.dry_run or pre[i]:match("^%-%-dry%-run=") ~= nil
      local fmt = pre[i]:gsub("^%-%-[%w%-]+=", "")
      if fmt ~= "sh" and fmt ~= "json" then
        return fail("--print format must be 'sh' or 'json' (got '" .. fmt .. "')")
      end
      r.print_mode = fmt; i = i + 1
    elseif pre[i] == "--no-build" then r.no_build = true; i = i + 1
    elseif device(pre, i, r.dev) then r.device_option = true; i = r.dev._next
    else r.positionals[#r.positionals + 1] = pre[i]; i = i + 1 end
  end
  -- --dry-run is the pure read-only report: it never builds or deploys.
  if r.dry_run then r.no_build = true end

  if r.print_mode and #r.prefix_tokens > 0 then
    -- --print reports the bare resolved command; a wrapper is a run-execution
    -- concern. Combining them is contradictory — reject rather than guess.
    return fail("--print and --prefix are mutually exclusive: --print reports the " ..
      "resolved command (compose your own wrapper), --prefix runs under one.")
  end
  return r
end

--- The options of `_run_launch_target` for a parsed run.
--- @param r loomworks.cli.RunArgs
--- @return table
function M._run_target_opts(r)
  local d = r.dev
  return {
    prefix_tokens = r.prefix_tokens,
    print_mode = r.print_mode,
    no_build = r.no_build,
    dry_run = r.dry_run,
    extra_args = r.extra_args,
    cwd_override = r.cwd_override,
    device = d.device, fresh = d.fresh, timeout = d.timeout,
    timeouts = d.timeouts, log_options = d.log_options, no_wait = d.no_wait,
  }
end

--- `lw run [<target>] [-- prog-args…]` / `lw run <profile> <target>` — resolve a
--- profile and a launch target, then build → deploy → execute. The pre-`--`
--- operands follow the §16.17 grammar: none → the resolved profile's default
--- target; one → that target on the resolved profile (never a profile selector);
--- two → the named target on the named profile. Args after `--` are forwarded to
--- the program. Returns its exit code. Routes through the editor's LaunchTarget
--- seams (resolve_launch_spec / deploy_sync, via loomworks.run_prep — shared
--- with the workspace daemon's `prepare_run`, §19.15) so headless and editor
--- launches stay identical.
---
--- Options (spec §16.17):
---   --prefix <cmd>   interpose a wrapper before the resolved command — the
---                    process becomes `<prefix> <cmd> <args>` in the launch's
---                    resolved cwd/env, on the real terminal (so interactive
---                    gdb/valgrind work). Repeatable and shell-word split, so
---                    `--prefix 'valgrind --leak-check=full'` and
---                    `--prefix gdb --prefix --args` both give multiple tokens.
---   --print[=sh|json] build (quietly), then resolve the launch but do NOT
---                     execute; report it and exit 0. `sh` (default) is a single
---                     POSIX-sh-quoted line; `json` is `{cmd:[argv], cwd, env:{overrides}}`.
---   --dry-run[=sh|json] like --print, but never builds or deploys (implies
---                     --no-build): a pure read-only report. A program that is
---                     not built yet is still reported, with a note on stderr.
---   --no-build        skip the build+deploy (inspect / run what is already built).
function M.cmd_run(ws, args)
  local r = M._parse_run_args(args, die, DEV.parse_device_opt)

  -- Determine (profile, target) from the operand count (§16.17). The profile is
  -- resolved here; a named target is matched AFTER the build below, so build
  -- targets are enumerated.
  local profile, target_name
  profile, target_name, ws = M._run_selection(ws, r.positionals)

  -- Build the profile first (configures + builds); dies on failure. Build
  -- targets and the default target's artifact resolve against the built tree.
  -- `--no-build` (and `--dry-run`, which implies it) skips build+deploy
  -- (inspect/run what is already built). Under `--print` the build streams to
  -- stderr (quiet) so our stdout carries only the report line. The build-dir
  -- lock is held only for the build — released before the launch, which just
  -- executes the artifact and may run indefinitely.
  if not r.no_build then
    with_build_locks(profile, "build", function()
      M._run_build_steps(profile, ws, { quiet = r.print_mode ~= nil })
    end)
  end

  local lt, serr = require("loomworks.run_prep").select(ws, profile, target_name, r.proj_scope, r.kind)
  if not lt then die(serr) end
  return M._run_launch_target(lt, ws, M._run_target_opts(r))
end

--- The editor-shared deploy → resolve → (report | prefix-exec) tail of a run,
--- given an already-resolved launch target `lt`. Extracted so cmd_run and tests
--- drive the identical dispatch. Returns the launched process's exit code, or 0
--- for a --print report. `opts`:
---   prefix_tokens string[]  wrapper tokens prepended to the argv (§16.17)
---   print_mode    "sh"|"json"|nil  report-and-exit instead of executing
---   no_build      boolean   skip deploy (paired with the skipped build)
---   dry_run       boolean   --dry-run: note (stderr) when the reported program
---                           does not exist yet (never built)
---   extra_args    string[]  post-`--` args forwarded to the program
---   cwd_override  string|nil per-invocation working dir
--- `deps.run_spec` is injectable for tests.
--- @param lt loomworks.LaunchTarget
--- @param ws loomworks.Workspace
--- @param opts table
--- @param deps? { run_spec?: function }
--- @return integer
function M._run_launch_target(lt, ws, opts, deps)
  if not M._foreign_of(lt) then
    if opts.log_options and next(opts.log_options) then opts.log = true end
    for _, k in ipairs({ "device", "fresh", "timeout", "no_wait", "log" }) do
      if opts[k] then
        die("--" .. k:gsub("_", "-") .. " applies only to a build target that runs on a device "
          .. "(one built by a cross-compiling kit)")
      end
    end
  end
  return M._run_launch_target_impl(lt, ws, opts, deps)
end

--- The foreign-artifact classification of a launch target's build-target
--- artifact (spec §18.1), or nil: a module target or a target-backed launch
--- configuration whose artifact is foreign. Command launches are never probed.
--- @param lt loomworks.LaunchTarget
--- @return loomworks.ForeignArtifact|nil
function M._foreign_of(lt)
  return require("loomworks.run_prep").foreign_of(lt)
end

--- Run a foreign build target on a device (spec §16.17, §18.5): deploy on the
--- host → stage → execute remotely. Returns the invocation's exit status (the
--- device program's; a lost status is a transport failure, EXIT_TRANSPORT).
--- `deps.backend` / `deps.liveness_ms` are test seams.
--- @return integer
function M._run_foreign(lt, ws, f, opts, deps)
  deps = deps or {}
  local foreign = require("loomworks.remote.foreign")
  local runners = require("loomworks.remote.runners")
  local manifest = require("loomworks.remote.manifest")
  local remote_run = require("loomworks.remote.run")
  if #(opts.prefix_tokens or {}) > 0 then
    die("--prefix cannot wrap '" .. f.name .. "': it runs on a device (built for "
      .. tostring(f.platform or f.what) .. "), where a local wrapper does not apply.")
  end
  if opts.cwd_override then
    die("--cwd does not apply to a device run — set the project's device.working_dir instead")
  end
  local runner = f.platform and runners.for_foreign(f) or nil
  if not runner then die(foreign.refusal(f)) end

  -- Deploy steps run on the host before staging, unchanged (§18.4).
  if not opts.no_build then
    local dok, derr = lt:deploy_sync()
    if not dok then die("deploy failed: " .. tostring(derr)) end
  end

  local project = lt._project
  local cfg = lt._launch_config
  local block = manifest.effective_block(project and project.device, cfg and cfg.device)
  for _, b in ipairs({ { project and project.device, "project device" }, { cfg and cfg.device, "launch device" } }) do
    local vok, verr = manifest.validate_block(b[1], b[2])
    if not vok then die(verr) end
  end
  local unit = f.target._config_unit or lt._config_unit
  local man, merr = manifest.build({
    build_dir = unit:build_dir(), artifact = f.artifact, unit = unit, target = f.target,
    runner = runner, tool = f.tool, device = block,
  })
  if not man then die(merr) end

  -- Program arguments: a target-backed launch configuration's declared args
  -- (expanded), then the forwarded ones.
  local args = {}
  if cfg and cfg.args then
    local expand = require("loomworks.expand")
    local ctx = expand.launch_context(ws, lt._profile, project)
    for _, a in ipairs(expand.expand_array(cfg.args, ctx) or {}) do args[#args + 1] = a end
  end
  for _, a in ipairs(opts.extra_args or {}) do args[#args + 1] = a end

  local profile = lt._profile
  if opts.print_mode then
    local plan, perr = remote_run.plan({ runner = runner, ws_name = ws.name or "workspace", unit = unit,
      manifest = man, device = block, args = args })
    if not plan then die(perr) end
    local dinfo = { runner = runner.id }
    local list, lerr = require("loomworks.remote.devices").list(runner,
      { backend = deps.backend, timeouts = opts.timeouts })
    if list then
      dinfo.serial, dinfo.error = require("loomworks.remote.devices").select(list, {
        explicit = opts.device, persisted = profile and profile._device_serial,
        runner_id = runner.id, profile_key = profile and profile.key })
    else
      dinfo.error = lerr
    end
    for _, line in ipairs(remote_run.render_print(plan, man, dinfo, opts.print_mode)) do out(line) end
    return 0
  end

  local result, err = remote_run.execute({
    ws = ws, runner = runner, unit = unit, manifest = man, device = block, args = args,
    serial = opts.device, persisted = profile and profile._device_serial,
    profile_key = profile and profile.key,
    fresh = opts.fresh, no_wait = opts.no_wait, timeout = opts.timeout, timeouts = opts.timeouts,
    log_options = remote_run.merge_log_options(cfg and cfg.device_log, opts.log_options),
    results = opts.results, extra_args_fn = opts.extra_args_fn, before_exec = opts.before_exec,
    fail_on_missing_results = opts.fail_on_missing_results,
    backend = deps.backend, liveness_ms = deps.liveness_ms,
    write_out = deps.write_out, write_err = deps.write_err,
    note = function(s) errw("lw: " .. s .. "\n") end,
    on_cleanup = on_exit,
  })
  if not result then die(err) end
  if opts.on_result then return opts.on_result(result) end
  remote_run.report(result, function(s) errw(s .. "\n") end)
  return result.exit_code
end

--- (implementation of `_run_launch_target`, after the device-option check)
function M._run_launch_target_impl(lt, ws, opts, deps)
  deps = deps or {}
  local rp = require("loomworks.run_prep")
  local prefix_tokens = opts.prefix_tokens or {}

  -- Validity gate (stale descriptor / invalid profile or configuration).
  local verr = rp.validity_error(lt)
  if verr then die(verr) end

  -- A prefix wraps LOCAL execution; a device target runs on the device, where a
  -- host-side wrapper does not apply (device launch is deferred anyway, §16.17).
  if #prefix_tokens > 0 and lt:requires_device() then
    die("--prefix cannot wrap a device target ('" .. lt:display_name() ..
      "') — a local wrapper does not apply to on-device execution.")
  end

  -- A foreign build target (spec §18.1) never runs here: it is routed to a
  -- device through its SDK's runner, or refused.
  local foreign = M._foreign_of(lt)
  if foreign then
    return M._run_foreign(lt, ws, foreign, opts, deps)
  end

  -- Deploy (both phases). Skipped with --no-build (paired with the build).
  if not opts.no_build then
    local dok, derr = lt:deploy_sync()
    if not dok then die("deploy failed: " .. tostring(derr)) end
  end

  local spec, serr = rp.resolve_spec(lt, opts)
  if not spec then die(serr) end
  return M._run_resolved(spec, opts, ws.root, deps)
end

--- Finish a run whose launch spec is resolved — in-process, or as returned by
--- the workspace daemon's `prepare_run` (§19.15 "Run"): `--print` /
--- `--dry-run` report it (§16.17 "Command inspection"); otherwise print
--- `running <name> [cwd: <cwd>]: <argv>` and execute `<prefix> <cmd> <args>`
--- in this process, on its terminal. Returns the exit code.
--- @param spec { name: string, cmd: string, args: string[]|nil, cwd: string|nil, env: table|nil }
--- @param opts { prefix_tokens?: string[], print_mode?: "sh"|"json", dry_run?: boolean }
--- @param root string the workspace root (the cwd when the spec has none)
--- @param deps? { run_spec?: function }
--- @return integer
function M._run_resolved(spec, opts, root, deps)
  local run = deps and deps.run_spec or run_spec
  -- --print / --dry-run: report the resolved invocation, never execute (§16.17
  -- "Command inspection").
  if opts.print_mode then
    -- A dry run never built: a program that does not exist yet is still
    -- reported (its path is known), with a note on stderr — never a failure.
    -- Only an absolute path is checked; a bare command resolves via PATH.
    local cmd = spec.cmd
    if opts.dry_run and type(cmd) == "string" and (cmd:match("^[/\\]") or cmd:match("^%a:[/\\]"))
      and not uv.fs_stat(cmd) then
      errw("note: " .. cmd .. " is not built yet\n")
    end
    return emit_run_print(spec, opts.print_mode, root)
  end

  -- Build the launched argv (prefix, then cmd, then args) and execute it in the
  -- launch's resolved cwd/env on the real terminal, so an interactive wrapper
  -- (gdb, valgrind) drives the tty. The wrapper process's exit status becomes
  -- the invocation's (§16.17 "Launch prefix").
  local full = build_run_argv(opts.prefix_tokens, spec)
  out(string.format("running %s [cwd: %s]: %s", spec.name, spec.cwd or root,
    table.concat(full, " ")))
  -- (Only the status: a program a signal ended exits 128 + signal.)
  return (run({ cmd = full, cwd = spec.cwd, env = spec.env }, root))
end

--- The batch runner is a host program that would execute the profile's test
--- binaries here: never for a cross kit (spec §15 invariant 19, §18.6). Dies
--- naming the kit and platform, pointing at `lw test --target`.
--- @param profile loomworks.Profile
function M._refuse_foreign_batch(profile)
  local msg = require("loomworks.build_run").foreign_batch_refusal(profile)
  if msg then die(msg) end
end

--- Run named test executables (spec §16.16, §18.6): build the profile, then
--- run each named executable directly with its framework's results option —
--- on a device when foreign (§18.5), locally otherwise — and judge each
--- outcome from exit status + parsed results (+ crashes / missing results on a
--- device). `opts = { junit?, extra = string[], dev = device options }`.
--- `deps` (tests): build(profile, ws), resolve_target(ws, profile, name) → lt,
--- run_spec, backend, liveness_ms, write_out, write_err.
--- @return integer exit code
function M._test_targets(ws, profile, names, opts, deps)
  deps = deps or {}
  local test_run = require("loomworks.remote.test_run")
  local gtest = require("loomworks.gtest")
  local remote_run = require("loomworks.remote.run")
  if deps.build then
    deps.build(profile, ws)
  else
    with_build_locks(profile, "build", function() run_build_steps(profile, ws, {}) end)
  end
  local function resolve(name)
    if deps.resolve_target then return deps.resolve_target(ws, profile, name) end
    for _, pp in ipairs(profile:projects()) do ensure_unit_targets(ws, pp._config_unit) end
    local matches, all = match_targets(ws, profile, name, nil, "target")
    if #matches == 0 then
      local labels = {}
      for _, c in ipairs(all) do if c.kind == "target" then labels[#labels + 1] = c.project.key .. ":" .. c.name end end
      die("no executable target '" .. name .. "' in profile '" .. profile.key .. "'.\n  executables: " ..
        (next(labels) and table.concat(labels, ", ") or "(none)"))
    elseif #matches > 1 then
      local labels = {}
      for _, c in ipairs(matches) do labels[#labels + 1] = fmt_cand(c) end
      die("'" .. name .. "' is ambiguous: " .. table.concat(labels, ", ") .. "\n  qualify with <project>:<name>.")
    end
    return candidate_launch_target(ws, profile, matches[1])
  end

  local several = #names > 1
  local failed_names, wrote = {}, {}
  for _, name in ipairs(names) do
    local lt = resolve(name)
    local f = M._foreign_of(lt)
    local results, results_requested, results_missing, failed, reasons
    if f then
      out(string.format("==> [test] %s (on a device)", name))
      local hook, st = test_run.device_hook(f.name)
      local outcome
      M._run_foreign(lt, ws, f, {
        extra_args = opts.extra, device = opts.dev.device, fresh = opts.dev.fresh,
        timeout = opts.dev.timeout, timeouts = opts.dev.timeouts, log_options = opts.dev.log_options,
        no_wait = opts.dev.no_wait, before_exec = hook,
        on_result = function(r) outcome = r; return r.exit_code end,
      }, deps)
      results_requested = st.framework == "gtest"
      local path = st.results_name and outcome.results[st.results_name]
      results = path and gtest.parse_xml_results(path) or nil
      if path and not results then results = {} end
      results_missing = results_requested and not path
      failed, reasons = test_run.judge({ status = outcome.status, results_requested = results_requested,
        results = results, results_missing = results_missing, crashes = #outcome.crashes,
        transport_error = outcome.transport_error or (outcome.timed_out and "timeout" or nil) })
      remote_run.report(outcome, function(s2) errw(s2 .. "\n") end, failed)
    else
      out(string.format("==> [test] %s", name))
      local spec, serr = lt:resolve_launch_spec({ extra_args = opts.extra })
      if not spec then die("cannot resolve test executable: " .. tostring(serr)) end
      local fw = gtest.probe_sync(spec.cmd, name, { env = spec.env, cwd = spec.cwd })
      local xml
      if fw == "gtest" then
        results_requested = true
        -- In the workspace's .nvim/tmp, not the system temp dir (§16.40).
        xml = require("loomworks.housekeeping").tmp_path(ws.root, "lw-test-", ".xml")
        spec.args[#spec.args + 1] = "--gtest_output=xml:" .. xml
      end
      local argv = { spec.cmd }
      for _, a in ipairs(spec.args) do argv[#argv + 1] = a end
      local code = (deps.run_spec or run_spec)({ cmd = argv, cwd = spec.cwd, env = spec.env }, ws.root)
      if xml then
        if uv.fs_stat(xml) then
          results = gtest.parse_xml_results(xml) or {}
          os.remove(xml)
        else
          results_missing = true
        end
      end
      failed, reasons = test_run.judge({ status = code, results_requested = results_requested,
        results = results, results_missing = results_missing })
    end
    local c = test_run.count(results)
    if failed then
      failed_names[#failed_names + 1] = name
      out(string.format("%s: FAILED (%s)%s", name, table.concat(reasons, ", "),
        #c.failed_ids > 0 and (": " .. table.concat(c.failed_ids, ", ")) or ""))
    else
      out(string.format("%s: %d test%s passed%s", name, c.total - c.skipped, (c.total - c.skipped) == 1 and "" or "s",
        c.skipped > 0 and (", " .. c.skipped .. " skipped") or ""))
    end
    if opts.junit then
      if results then
        local p = test_run.junit_path(opts.junit, name, several)
        local ok, werr = test_run.write_file(p, test_run.junit_xml(name, results))
        if ok then wrote[#wrote + 1] = p else errw("lw: warning: cannot write JUnit " .. p .. ": " .. tostring(werr) .. "\n") end
      else
        errw("lw: warning: no JUnit output for " .. name .. " (no results file)\n")
      end
    end
  end
  for _, p in ipairs(wrote) do out("JUnit: " .. p) end
  if #failed_names > 0 then
    die(string.format("%d of %d test executable%s failed: %s", #failed_names, #names,
      #names == 1 and "" or "s", table.concat(failed_names, ", ")), 1)
  end
  out(string.format("TESTS OK: %s (%d executable%s)", profile.key, #names, #names == 1 and "" or "s"))
  return 0
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
      rows[#rows + 1] = { project = p.key, name = n, runs = runs,
        description = type(cfg) == "table" and cfg.description or nil }
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
  -- One layout rule (spec §16.35): PROJECT and NAME, then the DESCRIPTION
  -- summary column, then RUNS — the open-ended tail, cut to the terminal
  -- (both printed in full when piped).
  local d = require("loomworks.description")
  local descs = {}
  for i, r in ipairs(rows) do descs[i] = r.description end
  local prefix_w = 2 + pw + 1
  local tw = M._term_width()
  local sum_w = M._summary_column(descs, tw, prefix_w + 1 + nw, true)
  local tail_w
  if M._stdout_tty() then
    local used = prefix_w + 1 + nw + 1 + (sum_w > 0 and (sum_w + 3) or 0)
    tail_w = math.max(16, tw - used)
  end
  local function prefix(pv, nv)
    return "  " .. pv .. string.rep(" ", pw - d.width(pv)) .. "  " .. nv .. string.rep(" ", nw - d.width(nv))
  end

  out("Launch configs — pass PROJECT and NAME to `lw launch show|set`:")
  out("")
  local head_sum = sum_w > 0 and ("DESCRIPTION" .. string.rep(" ", math.max(0, sum_w - 11))) or nil
  out(head_sum and (prefix("PROJECT", "NAME") .. "  " .. head_sum .. "  RUNS")
    or (prefix("PROJECT", "NAME") .. " RUNS"))
  for _, r in ipairs(rows) do
    out(M._row_with_summary(prefix(d.fit(r.project, pw), d.fit(r.name, nw)), r.description,
      sum_w, r.runs, tail_w))
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

  -- A new launch name must be valid (spec §8.7).
  local vok, verr = require("loomworks.project").validate_launch_name(name)
  if not vok then die("invalid launch name '" .. name .. "': " .. verr) end

  -- `--description <para>` (repeatable) — not `-m`: everything after the
  -- command is the program's own args, where `-m` is common (§16.35).
  local positionals, from_target, working_dir, env = {}, nil, nil, nil
  local paras = {}
  local i = 5
  while args[i] do
    local v = args[i]
    if v == "--description" then
      if args[i + 1] == nil then die("--description needs a paragraph") end
      paras[#paras + 1] = args[i + 1]; i = i + 2
    elseif v:sub(1, 14) == "--description=" then
      paras[#paras + 1] = v:sub(15); i = i + 1
    elseif v == "--working-dir" or v == "--cwd" then working_dir = args[i + 1]; i = i + 2
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
  if #paras > 0 then
    local dok, desc, derr = require("loomworks.description").prepare(table.concat(paras, "\n\n"))
    if not dok then die("invalid --description: " .. tostring(derr)) end
    cfg.description = desc
  end

  local ok, err = project:save_launch_config(name, cfg)
  if not ok then die("could not save launch config: " .. tostring(err)) end
  out(string.format("added launch config '%s' on project '%s'%s", name, project.key,
    from_target and (" (target: " .. from_target .. ")") or ""))
  out("  run it: lw run <profile> " .. name)
  return 0
end

--- Parse the `(project, name)` address for `launch show/remove/set`, accepting
--- BOTH the legacy two-positional `<project> <name>` form and the `run`/`target`
--- addressing style — a single `[<project>:]<name>` operand and/or
--- `--project <p>` / `--launch <n>` flags. Scans `tokens` from `start`, pulling
--- out the `--project`/`--launch` flags and the leading bare positionals that
--- make up the address; it stops at the first OTHER `--flag` (an edit flag for
--- `launch set`) or once the address is satisfied, so trailing edit flags/args
--- are left for the caller. A single `project:name` operand splits on the first
--- `:` only when the prefix is a known project (launch names may contain ':').
--- @param ws table
--- @param tokens string[]
--- @param start integer index of the first address token (3 for `launch <sub>`)
--- @return string|nil project_name, string|nil launch_name, integer next_index
local function consume_launch_address(ws, tokens, start)
  local proj_flag, launch_flag, pos = nil, nil, {}
  local i = start
  while tokens[i] do
    local t = tokens[i]
    if t == "--project" then proj_flag = tokens[i + 1]; i = i + 2
    elseif t == "--launch" then launch_flag = tokens[i + 1]; i = i + 2
    elseif t:sub(1, 2) == "--" then break -- an edit flag: the address ends here
    else
      local need = (proj_flag and 0 or 1) + (launch_flag and 0 or 1)
      if #pos >= need then break end -- address already satisfied by flags/positionals
      pos[#pos + 1] = t; i = i + 1
    end
  end
  local proj, name = proj_flag, launch_flag
  if not proj and not name then
    if #pos >= 2 then
      proj, name = pos[1], pos[2]
    elseif #pos == 1 then
      local pfx, rest = pos[1]:match("^([^:]+):(.+)$")
      local known = false
      if pfx then
        for _, p in pairs(ws._projects or {}) do if p.key == pfx then known = true break end end
      end
      if known then proj, name = pfx, rest else name = pos[1] end
    end
  elseif not name then
    name = pos[1]
  elseif not proj then
    proj = pos[1]
  end
  return proj, name, i
end
M._consume_launch_address = consume_launch_address

-- Forward declaration: defined just after cmd_launch_set, used by it.
local launch_show_resolved

--- `lw launch set <project> <name> [flags]` (also `[<project>:]<name>` /
--- `--project`/`--launch`) — modify an existing launch config
--- in place. Reads the config, applies only the given changes, saves it
--- back to the project's working copy.
---   --working-dir D | --clear-working-dir
---   --env K=V (add/update, repeatable) | --unset-env K (remove, repeatable)
---   --command C | --from-target T   (switch kind)
---   trailing positionals replace args | --clear-args
function M.cmd_launch_set(root, args)
  local ws = load_workspace(root, false)
  local proj_name, name, next_i = consume_launch_address(ws, args, 3)
  if not (proj_name and name) then
    die("usage: lw launch set [<project>] <name> [--project P] [--launch N] " ..
      "[--working-dir D|--clear-working-dir] " ..
      "[--env K=V] [--unset-env K] [--command C|--from-target T] [args…|--clear-args]")
  end
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
  local i = next_i
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
  return launch_show_resolved(project, name)
end

--- Print one launch config, given a resolved project + name. Shared by
--- `launch show` and the confirmation `launch set` prints after a save.
function launch_show_resolved(project, name)
  local cfg = project.launch and project.launch[name]
  if not cfg then die("no launch config '" .. name .. "' on project '" .. project.key .. "'") end
  out("launch config '" .. name .. "'  (project " .. project.key .. ")")
  if type(cfg.description) == "string" then
    local d = require("loomworks.description")
    local first = true
    for line in (d.inert(cfg.description) .. "\n"):gmatch("([^\n]*)\n") do
      if first then out("  description  " .. line); first = false
      else out(line == "" and "" or ("               " .. line)) end
    end
  end
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
  -- Fields `show` did not print before (spec §16.35).
  if type(cfg.deploy) == "table" and next(cfg.deploy) then
    local dests = {}
    for dest in pairs(cfg.deploy) do dests[#dests + 1] = dest end
    table.sort(dests)
    for _, dest in ipairs(dests) do out("  deploy       " .. dest) end
  end
  if type(cfg.device) == "table" and next(cfg.device) then
    local keys = {}
    for k in pairs(cfg.device) do keys[#keys + 1] = k end
    table.sort(keys)
    out("  device       " .. table.concat(keys, ", "))
  end
  if type(cfg.debug) == "table" and #cfg.debug > 0 then
    out("  debug        " .. table.concat(cfg.debug, ", "))
  end
  return 0
end

--- `lw launch show … --json` (spec §16.35): the whole launch as one object —
--- values as declared (not expanded), args as an array.
--- @param project table
--- @param name string
--- @return integer
function M._launch_show_json(project, name)
  local cfg = project.launch and project.launch[name]
  if type(cfg) ~= "table" then die("no launch config '" .. name .. "' on project '" .. project.key .. "'") end
  local d = require("loomworks.description")
  local desc = type(cfg.description) == "string" and cfg.description or nil
  local obj = {
    project = project.key,
    name = name,
    kind = cfg.target and "target" or "command",
    target = cfg.target,
    command = cfg.command,
    args = (type(cfg.args) == "table" and #cfg.args > 0) and cfg.args or nil,
    working_dir = cfg.working_dir,
    env = (type(cfg.env) == "table" and next(cfg.env)) and cfg.env or nil,
    deploy = (type(cfg.deploy) == "table" and next(cfg.deploy)) and cfg.deploy or nil,
    device = (type(cfg.device) == "table" and next(cfg.device)) and cfg.device or nil,
    device_log = cfg.device_log,
    debug = (type(cfg.debug) == "table" and #cfg.debug > 0) and cfg.debug or nil,
    description = desc or vim.NIL,
    summary = d.summary(desc) or vim.NIL,
  }
  out(vim.json.encode(obj))
  return 0
end

--- `lw launch show <project> <name>` (also `[<project>:]<name>` /
--- `--project`/`--launch`).
function M.cmd_launch_show(root, args)
  local ws = read_workspace(root, false)
  local proj_name, name = consume_launch_address(ws, args, 3)
  if not (proj_name and name) then
    die("usage: lw launch show [<project>] <name>  (also <project>:<name> / --project P --launch N)")
  end
  local project = resolve_project(ws, proj_name)
  for _, a in ipairs(args) do
    if a == "--json" then return M._launch_show_json(project, name) end
  end
  return launch_show_resolved(project, name)
end

--- `lw launch remove <project> <name>` (also `[<project>:]<name>` /
--- `--project`/`--launch`).
function M.cmd_launch_remove(root, args)
  local ws = load_workspace(root, false)
  local proj_name, name = consume_launch_address(ws, args, 3)
  if not (proj_name and name) then
    die("usage: lw launch remove [<project>] <name>  (also <project>:<name> / --project P --launch N)")
  end
  local project = resolve_project(ws, proj_name)
  local ok, err = project:delete_launch_config(name)
  if not ok then die(tostring(err)) end
  out("removed launch config '" .. name .. "' from project '" .. project.key .. "'")
  return 0
end

function M.cmd_launch(sub, root, args)
  if sub == nil or sub == "list" then return M.cmd_launch_list(read_workspace(root, false), args[3]) end
  if sub == "add" or sub == "create" then return M.cmd_launch_add(root, args) end
  if sub == "set" or sub == "edit" then return M.cmd_launch_set(root, args) end
  if sub == "show" then return M.cmd_launch_show(root, args) end
  if sub == "remove" or sub == "rm" then return M.cmd_launch_remove(root, args) end
  if sub == "rename" or sub == "mv" then return M.cmd_launch_rename(root, args) end
  if sub == "describe" then return M.cmd_launch_describe(root, args) end
  die("unknown launch subcommand '" .. tostring(sub) .. "' — use list|add|set|show|remove|rename|describe")
end

--- The build-target names of `project` (ids and display names), for the
--- launch-name clash warning (spec §8.7). Targets come from the project's
--- configured units, scanned on demand like `lw target` does (a fresh `lw`
--- process has not parsed them yet). Returns the name set, plus `true` when the
--- project's module has build targets but no unit could be scanned (no
--- configured build yet), so the check could not be made.
--- @return table<string, boolean> names, boolean unscanned
function M._project_build_target_names(ws, project)
  local names, scanned = {}, false
  for _, unit in pairs(ws._config_units or {}) do
    if unit._project == project then
      ensure_unit_targets(ws, unit)
      if type(unit.targets) == "table" then
        scanned = true
        for id, t in pairs(unit.targets) do
          if not id:match("^launch:") then
            names[id] = true
            local dn = t.display_name and t:display_name()
            if dn then names[dn] = true end
          end
        end
      end
    end
  end
  local mod = project._module and project._module.impl
  return names, (not scanned) and mod ~= nil and mod.parse_targets ~= nil
end

--- Rename a launch configuration (spec §8.7) and report it: the whole table
--- moves and every profile's default target follows. Warns (never refuses)
--- when the new name is also a build target of the project, since `lw run
--- <name>` then needs `--launch` / `--target`; says so when the targets are
--- not scanned yet. `opts.target_names` is a test seam; by default the
--- project's build targets are scanned (`M._project_build_target_names`).
--- @param ws table
--- @param project table
--- @param old string
--- @param new string
--- @param opts? { target_names?: table<string, boolean> }
--- @return integer
function M._launch_rename(ws, project, old, new, opts)
  opts = opts or {}
  local changed, err, moved = project:rename_launch_config(old, new)
  if changed == nil then die("could not rename launch config: " .. tostring(err)) end
  if changed == false then
    out("launch configuration '" .. project.key .. ":" .. old .. "' (unchanged)")
    return 0
  end
  out(string.format("renamed launch configuration '%s:%s' -> '%s:%s'", project.key, old, project.key, new))
  if moved and #moved > 0 then
    out("  default target updated in profiles: " .. table.concat(moved, ", "))
  end
  local names, unscanned = opts.target_names, false
  if not names then
    names, unscanned = M._project_build_target_names(ws, project)
  end
  if names[new] then
    errw("lw: warning: '" .. new .. "' is also the name of a build target in '" .. project.key
      .. "' - `lw run " .. new .. "` needs --launch or --target to choose\n")
  elseif unscanned then
    errw("lw: note: the build targets of '" .. project.key .. "' are not scanned yet (no configured "
      .. "build) - could not check that '" .. new .. "' is not also a build target name; if it is, "
      .. "`lw run " .. new .. "` needs --launch or --target to choose\n")
  end
  M._publish_hint(M._item_reaches_shared(ws, "projects", project, nil))
  return 0
end

--- `lw launch rename <project> <old> <new>` (alias `mv`).
function M.cmd_launch_rename(root, args)
  local proj_name, old, new = args[3], args[4], args[5]
  if not (proj_name and old and new) then
    die("usage: lw launch rename <project> <old> <new>")
  end
  local ws = load_workspace(root, false)
  return M._launch_rename(ws, resolve_project(ws, proj_name), old, new)
end

--- `lw launch describe <project> <name> [text | flags]` (also `--project P
--- --launch N`): the §16.35 describe forms for a launch configuration. The
--- single `[<project>:]<name>` operand is not accepted (a following <text>
--- would be ambiguous with it).
function M.cmd_launch_describe(root, args)
  local usage = "usage: lw launch describe <project> <name> [<text> | -m <para>... | -F <file|-> | - | -e | --clear | --json]\n"
    .. "   or: lw launch describe --project <p> --launch <n> [...]"
  local proj_name, name, rest = nil, nil, {}
  local i = 3
  local pos = {}
  while args[i] do
    local v = args[i]
    if v == "--project" then proj_name = args[i + 1]; i = i + 2
    elseif v == "--launch" then name = args[i + 1]; i = i + 2
    else
      local need = (proj_name and 0 or 1) + (name and 0 or 1)
      if #pos < need and not (v:sub(1, 1) == "-" and v ~= "-") then
        pos[#pos + 1] = v
      else
        rest[#rest + 1] = v
      end
      i = i + 1
    end
  end
  if not proj_name then proj_name = table.remove(pos, 1) end
  if not name then name = table.remove(pos, 1) end
  if not (proj_name and name) then die(usage) end
  local o = M._describe_parse(rest, usage)
  local ws = load_workspace(root, false)
  local project = resolve_project(ws, proj_name)
  local cfg = project.launch and project.launch[name]
  if type(cfg) ~= "table" then
    die("no launch config '" .. name .. "' on project '" .. project.key .. "'")
  end
  local handle = {
    description = type(cfg.description) == "string"
      and require("loomworks.description").normalize(cfg.description) or nil,
    _json_extra = { project = project.key, name = name },
    _shared_item = project,
  }
  function handle:set_description(text)
    local changed, err = project:set_launch_description(name, text)
    local c = project.launch and project.launch[name]
    self.description = c and c.description or nil
    return changed, err
  end
  return M._describe_item(ws, handle, "launch configuration", project.key .. ":" .. name,
    "projects", nil, o)
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
  -- Next step (spec §16.38): the first command on the path to a build.
  out("Next: `lw project add <path>` registers a project (type auto-detected);")
  out("`lw help` has the quickstart from here to a first build.")
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
    if M._has_shared_file(ws) then out("`lw publish` to update the shared loomworks.json.") end
    return 0
  end
  die("unknown workspace subcommand '" .. tostring(sub) .. "' — use rename")
end

--- True when the published snapshot would carry no shared items — judged on
--- exactly what `lw publish` writes (the effective-intent closure, §2.4).
local function snapshot_empty(ws)
  local snap = ws:shared_snapshot()
  local function empty(t) return not t or not next(t) end
  return empty(snap.projects) and empty(snap.configuration_sets) and empty(snap.profiles)
end

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

  -- Rewrites the working copy and the published snapshot: one operation
  -- under the workspace operation lock (spec §19.3).
  local op_tok = ws:_op_lock("migrate")
  on_exit(function() require("loomworks.op_lock").release(op_tok) end)
  -- The plan was made (and confirmed) before the lock: refuse if another
  -- process changed the working copy since, before writing anything.
  if not ws:_working_copy_fresh() then
    die(require("loomworks.workspace").STALE_USER_MESSAGE .. " — re-run `lw migrate`")
  end
  local mtxn = ws:_txn_begin("migrate")
  local applied, err = migrate.apply(plan)
  if err then die("migration failed after " .. applied .. " change(s): " .. err) end

  -- The published snapshot is regenerated from the working copy, so a
  -- migration that touches published items rewrites it wholesale.
  local pub_ok, pub_err = ws:publish()
  if not pub_ok then
    die("migrated the working copy, but publishing failed: " .. tostring(pub_err)
      .. "\n  Run `lw publish` once resolved.")
  end
  local c_ok, c_err = ws:_txn_finish(mtxn)
  require("loomworks.op_lock").release(op_tok)
  if not c_ok then die("migration failed: " .. tostring(c_err)) end
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
  local okp, paths = pcall(require, "boot.paths")
  if not ok or not okp or type(paths.installed_modules) ~= "function" then
    -- boot.modules / paths.installed_modules first ship in the v0.1.4 host.
    die("`lw module` is a feature of the standalone lw binary (v0.1.4 or later); "
      .. "it is not available in the nvim-hosted fallback or an older lw binary. "
      .. "Install the current lw binary as in the README's \"Installing lw\".")
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

--- `lw publish` — regenerate the shared loomworks.json from the working copy.
function M.cmd_publish(root)
  local ws = load_workspace(root, false)
  local empty = snapshot_empty(ws)
  local ok, err = ws:publish()
  if not ok then die("publish failed: " .. tostring(err)) end
  out("published " .. ws.root .. "/loomworks.json")
  if empty then
    out("")
    errw("lw: note: loomworks.json is empty — nothing is marked shared.\n")
    errw("    Share items with `lw <project|profile|configset> publish <name>`,\n")
    errw("    or create them with --shared (the CLI default). See `lw help publish`.\n")
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- `lw export` / `lw import` (spec §16.39)
-- ---------------------------------------------------------------------------

--- Write `s` to standard output as raw bytes: no control-character rendering,
--- no ASCII folding (the JSON is data a reader parses), and no text-mode LF ->
--- CRLF translation on Windows (the export must match the file a publish
--- writes). Test seam: replace `M._raw_stdout`.
--- @param s string
function M._raw_stdout(s)
  M._raw_write(1, s)
end

--- Write `s` raw to file descriptor `fd` (1 or 2), after flushing both
--- buffered streams (so the order with our own lines holds).
--- @param fd integer
--- @param s string
function M._raw_write(fd, s)
  io.stdout:flush()
  io.stderr:flush()
  local pos = 1
  while pos <= #s do
    local ok, n = pcall(uv.fs_write, fd, s:sub(pos))
    if not ok or type(n) ~= "number" or n <= 0 then
      local f = fd == 2 and io.stderr or io.stdout
      f:write(s:sub(pos))
      f:flush()
      return
    end
    pos = pos + n
  end
end

--- Resolve and check `lw export -o <p>`: the parent directory must exist, the
--- target must not be a directory, and it must be neither this workspace's
--- loomworks.json (that is publish) nor anything under its .nvim/
--- (machine-signed state). Compared on resolved paths with a separator
--- boundary. Returns the absolute path, or nil and the message.
--- @param root string
--- @param p string
--- @return string|nil dest, string|nil err
function M._export_destination(root, p)
  local dest = resolve_abs_out(p, user_cwd())
  local parent, name = dest:match("^(.*)/([^/]+)$")
  if not parent or not name then return nil, "cannot write " .. p .. ": not a file path" end
  if parent == "" or parent:match("^%a:$") then parent = parent .. "/" end
  local preal = uv.fs_realpath(parent)
  if not preal then
    return nil, "cannot write " .. dest .. ": directory " .. parent .. " does not exist"
  end
  local full = (preal:gsub("\\", "/"):gsub("/+$", "")) .. "/" .. name
  local st = uv.fs_stat(full)
  if st and st.type == "directory" then return nil, "cannot write " .. full .. ": it is a directory" end
  local real_full = uv.fs_realpath(full)
  real_full = real_full and real_full:gsub("\\", "/") or full
  local nr = norm_cmp((uv.fs_realpath(root) or root):gsub("\\", "/"))
  local nf = norm_cmp(real_full)
  if nf == nr .. "/loomworks.json" then
    return nil, "refusing to write this workspace's loomworks.json — that is what `lw publish` does"
  end
  local nvim = nr .. "/.nvim"
  if nf == nvim or nf:sub(1, #nvim + 1) == nvim .. "/" then
    return nil, "refusing to write inside this workspace's .nvim/ — it holds machine-signed state"
  end
  return full
end

local EXPORT_USAGE = "usage: lw export [--published] [--no-profiles] [-o <file>]  (see `lw help export`)"

--- `lw export` — print the configuration as a loomworks.json (spec §16.39).
function M.cmd_export(root, args)
  local published, no_profiles, out_path = false, false, nil
  local i = 2
  while args[i] ~= nil do
    local v = args[i]
    if v == "--published" then published = true
    elseif v == "--no-profiles" then no_profiles = true
    elseif v == "-o" or v == "--output" then
      out_path = args[i + 1]
      if out_path == nil then die("`" .. v .. "` needs a file (or `-` for stdout) — " .. EXPORT_USAGE, 2) end
      i = i + 1
    elseif v:sub(1, 9) == "--output=" then
      out_path = v:sub(10)
    else
      die("unexpected argument '" .. v .. "' — " .. EXPORT_USAGE, 2)
    end
    i = i + 1
  end
  local transfer = require("loomworks.config_transfer")
  local dest
  if out_path and out_path ~= "-" then
    local derr
    dest, derr = M._export_destination(root, out_path)
    if not dest then die(derr) end
  end
  local ws = load_workspace(root, false)
  local raw = ws:shared_snapshot({ all = not published, no_profiles = no_profiles })
  local text, err = transfer.export_text(raw)
  if not text then die("export failed: " .. tostring(err)) end

  local counts = transfer.counts(transfer.inventory(raw))
  local summary
  if counts.projects + counts.configuration_sets + counts.profiles == 0 then
    summary = published and "nothing is published — `lw publish` would write no items"
      or "nothing to export — the workspace has no projects, configuration sets or profiles"
  else
    summary = (published and "what `lw publish` would write now: " or "exported ")
      .. transfer.counts_text(counts)
    local prog = require("loomworks.program_fields").review(raw, require("loomworks.modules"))
    if #prog > 0 then
      summary = summary .. string.format(", %d program setting%s", #prog, #prog == 1 and "" or "s")
      if not published then
        summary = summary .. string.format(" (`lw import` on the other machine puts %s into effect)",
          #prog == 1 and "it" or "them")
      end
    end
  end
  if published then
    summary = summary .. (dest and " — loomworks.json untouched" or " — nothing was written")
  end
  if dest then
    local ok, werr = require("loomworks.io").write_file_atomic(dest, text, { backup = false })
    if not ok then die("cannot write " .. dest .. ": " .. tostring(werr)) end
    out(summary .. " → " .. dest)
  else
    M._raw_stdout(text)
    note(summary)
  end
  return 0
end

--- Up to `max` names, then "…(+N)".
local function name_list(names, max)
  max = max or 5
  if #names <= max then return table.concat(names, ", ") end
  local head = {}
  for k = 1, max do head[k] = names[k] end
  return table.concat(head, ", ") .. string.format(", … (+%d)", #names - max)
end

--- The import summary and review (spec §16.39 "Trust"), printed before asking.
--- @param plan table from Workspace:prepare_import
--- @param label string where the import comes from
function M._print_import_plan(plan, label)
  local transfer = require("loomworks.config_transfer")
  out("Import " .. label .. " into .nvim/loomworks.user.json — replaces the working configuration.")
  out("loomworks.json and build state are not touched.")
  out("")
  out(string.format("  %-20s  %s", "", "now → after"))
  local labels = { projects = "projects", configurations = "configurations",
    configuration_sets = "configuration sets", profiles = "profiles" }
  for _, kind in ipairs(transfer.KINDS) do
    local d = plan.diff[kind]
    local parts = {}
    if #d.added > 0 then parts[#parts + 1] = "+ " .. name_list(d.added) end
    if #d.removed > 0 then parts[#parts + 1] = "- " .. name_list(d.removed) end
    if #d.changed > 0 then parts[#parts + 1] = "~ " .. name_list(d.changed) end
    out(string.format("  %-20s  %3d → %-3d  %s", labels[kind], d.before, d.after,
      table.concat(parts, "   ")):gsub("%s+$", ""))
  end
  if plan.name_before ~= plan.name_after then
    out(string.format("  %-20s  %s → %s", "name", tostring(plan.name_before), tostring(plan.name_after)))
  elseif plan.name_exported and plan.name_exported ~= plan.name_after then
    out(string.format("  %-20s  %s (kept; export says %s — --take-name to use it)", "name",
      tostring(plan.name_after), plan.name_exported))
  else
    out(string.format("  %-20s  %s (unchanged)", "name", tostring(plan.name_after)))
  end
  for _, c in ipairs(plan.intent_changes or {}) do
    out(string.format("  intent: %s %s %s -> %s", c.kind, c.name, c.from, c.to))
  end
  if plan.unread then
    out("Current working copy is " .. (plan.unread == "invalid"
        and "modified outside loomworks or from another machine (its signature does not match)"
        or "not signed by this machine")
      .. " — replaced unread (backup kept).")
    out("Its machine-local settings are not carried over (active profile, device selections,")
    out("fill values, SDKs, LSP and debug-adapter settings).")
  elseif plan.active_before and plan.active_before == plan.active_after then
    out("active profile: " .. plan.active_before .. " (kept)")
  elseif plan.active_before then
    out("Active profile " .. plan.active_before .. " is not in the import — no profile will be active.")
  elseif not plan.active_after then
    out("active profile: none (unchanged)")
  end
  for _, d in ipairs(plan.dropped or {}) do
    if d.what == "device" then
      out(string.format("device selection of %s (%s) is dropped — the import removes the profile.",
        d.profile, tostring(d.value)))
    else
      out(string.format("fill values of %s (%d) are dropped — the import removes the profile.",
        d.profile, d.value))
    end
  end
  if #plan.shared_only > 0 then
    out("Still in loomworks.json, not in the import (stay visible as shared): "
      .. name_list(plan.shared_only, 8) .. ".")
  end
  if plan.orphaned_build_dirs > 0 then
    out(string.format("%d build director%s will belong to no profile (kept on disk).",
      plan.orphaned_build_dirs, plan.orphaned_build_dirs == 1 and "y" or "ies"))
  end
  local removals = plan.publish_removals or {}
  if #removals > 0 then
    out(string.format("the next `lw publish` would remove %d item%s from loomworks.json: %s.",
      #removals, #removals == 1 and "" or "s", name_list(removals, 8)))
  end
  out("")
  out("Program settings — what loomworks may run on this file's word:")
  if #plan.program_lines == 0 then out("  (none)") end
  for _, l in ipairs(plan.program_lines) do out("  " .. l) end
  out("Other contents:")
  for _, l in ipairs(plan.other_lines) do out("  " .. l) end
  out("")
end

local IMPORT_USAGE = "usage: lw import <file>|- [--dry-run] [-y] [--take-name]  (see `lw help import`)"

--- `lw import` — replace the working configuration with an export (spec §16.39).
function M.cmd_import(root, args)
  local yes, dry, take_name, src = false, false, false, nil
  for i = 2, #args do
    local v = args[i]
    if v == "-y" or v == "--yes" then yes = true
    elseif v == "-n" or v == "--dry-run" then dry = true
    elseif v == "--take-name" then take_name = true
    elseif v == "-" or v:sub(1, 1) ~= "-" then
      if src then die("import takes one file — " .. IMPORT_USAGE, 2) end
      src = v
    else
      die("unknown option '" .. v .. "' — " .. IMPORT_USAGE, 2)
    end
  end
  if not src then die(IMPORT_USAGE, 2) end
  local from_stdin = src == "-"
  local content, label
  if from_stdin then
    content = io.stdin:read("*a")
    label = "standard input"
  else
    local path = resolve_abs_out(src, user_cwd())
    content = require("loomworks.io").read_file(path)
    if not content then die("cannot read " .. path) end
    label = src
  end
  -- A working copy not signed by this machine is replaced unread (spec
  -- §16.39): load as if it were absent; the plan says so.
  local ws = load_workspace(root, false, { replace_untrusted_user = true })
  local plan, err, kind = ws:prepare_import(content, { intent = create_intent, take_name = take_name })
  if not plan then
    if kind == "working_copy" then
      die(label .. " is a working copy (.nvim/loomworks.user.json), not an export — on this machine "
        .. "use `lw pull <checkout>`; from another machine run `lw export` there")
    end
    if kind == "json" then die(label .. " is not valid JSON — nothing was changed") end
    die(label .. ": " .. tostring(err) .. " — nothing was changed")
  end
  M._print_import_plan(plan, label)
  if dry then
    out("dry run — nothing was written.")
    return 0
  end
  if not yes then
    if from_stdin or not interactive() then
      die("refusing to import without confirmation — review with --dry-run, then re-run with --yes")
    end
    local answer = (prompt_line("Replace the working configuration? [y/N]") or ""):lower()
    if answer ~= "y" and answer ~= "yes" then die("aborted — nothing was changed") end
  end
  local ok, cerr, backup = ws:commit_import(plan)
  if not ok then
    die(tostring(cerr) .. (backup and "" or " — nothing was changed"))
  end
  local transfer = require("loomworks.config_transfer")
  out("imported " .. transfer.counts_text(plan.counts))
  if backup then
    local rel = backup
    local r = ws.root:gsub("\\", "/")
    if rel:sub(1, #r + 1) == r .. "/" then rel = rel:sub(#r + 2) end
    out("  previous working copy: " .. rel .. " (copy it back over .nvim/loomworks.user.json to undo)")
  else
    out("  created .nvim/loomworks.user.json (there was no working copy)")
  end
  if plan.active_after then
    out("  active profile: " .. plan.active_after)
  elseif plan.counts.profiles > 0 and not plan.active_before and not plan.unread then
    -- There was none before: say so, so the hint does not read as a loss.
    out("  no profile is active (none was before) — `lw profile select <profile>` to choose one "
      .. "(`lw profile list`)")
  elseif plan.counts.profiles > 0 then
    out("  no active profile — `lw profile select <profile>` (`lw profile list`)")
  end
  if plan.orphaned_build_dirs > 0 then
    out("  build directories no profile uses were left in place. `lw reset --all` deletes them")
    out("  along with every other profile's builds.")
  end
  if plan.publish_changes and M._has_shared_file(ws) then
    out("`lw publish` to update the shared loomworks.json.")
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

--- Does the workspace have a published loomworks.json? The publish reminder
--- ("`lw publish` to update the shared loomworks.json.") is shown only when it
--- does: a local-only workspace (spec §2.4, no loomworks.json yet) has no
--- shared file to update, so every edit there stays quiet.
--- @param ws table
--- @return boolean
function M._has_shared_file(ws)
  local r = ws and ws.root
  return type(r) == "string" and uv.fs_stat(r .. "/loomworks.json") ~= nil
end

--- Whether `item` — a project (`kind` "projects"), configuration ("configs",
--- with its `proj`), configuration set ("config_sets") or profile ("profiles")
--- — reaches the shared loomworks.json: it is in the effective-intent closure
--- (§2.4: its own intent, or a published set/profile pulls it in), or a
--- published copy of it already exists (so editing/removing it changes
--- loomworks.json). Gates the "`lw publish` …" hint after a remove / rename /
--- (un)map: a never-published LOCAL item has nothing to publish, and nothing
--- reaches a loomworks.json that does not exist (`M._has_shared_file`). Evaluate it
--- BEFORE a remove (the item leaves the closure once gone). Errs on the side of
--- the hint when the closure cannot be computed.
--- @param ws table
--- @param kind "projects"|"configs"|"config_sets"|"profiles"
--- @param item table
--- @param proj? loomworks.Project the configuration's project (kind "configs")
--- @return boolean
local function item_reaches_shared(ws, kind, item, proj)
  if not M._has_shared_file(ws) then return false end
  local ok_p, pub = pcall(function() return ws:_publishable_to_shared() end)
  if not (ok_p and type(pub) == "table" and type(pub[kind]) == "table") then return true end
  if pub[kind][item] then return true end
  local base = ws._shared_baseline
  if type(base) ~= "table" then return false end
  local function has(t, k) return type(t) == "table" and k ~= nil and t[k] ~= nil end
  if kind == "projects" then return has(base.projects, item.key) end
  if kind == "config_sets" then return has(base.configuration_sets, item.name) end
  if kind == "profiles" then return has(base.profiles, item.key) end
  if kind == "configs" and proj then
    local ok_b, in_base = pcall(function() return ws:is_config_in_baseline(proj, item) end)
    return not ok_b or in_base == true
  end
  return false
end

--- Print the `lw publish` hint when `shared` (see `item_reaches_shared`).
local function publish_hint(shared)
  if shared then out("`lw publish` to update the shared loomworks.json.") end
end
-- (Fields for callers defined above these locals; the chunk is at the 200-local limit.)
M._publish_hint = publish_hint
M._item_reaches_shared = item_reaches_shared

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
      "  lw config add " .. proj.key .. " <name> " ..
      (cfg.module_config and cfg.module_config.variant or "") .. "\n" ..
      "  lw config set " .. proj.key .. " <name> inherits " .. cfg.name)
  end
  return cfg
end

--- Print a string→string dict, sorted, one `k = v` per line at `indent`.
local function print_dict(indent, d)
  local keys = {}
  for k in pairs(d or {}) do keys[#keys + 1] = k end
  if #keys == 0 then out(indent .. "(none)"); return end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = d[k]
    if type(v) == "table" then
      -- Nested dict (e.g. overrides: family → { name → value }).
      out(string.format("%s%s:", indent, k))
      print_dict(indent .. "  ", v)
    else
      out(string.format("%s%s = %s", indent, k, tostring(v)))
    end
  end
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
    errw("lw: '" .. ans .. "' also exists\n")
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
      errw("lw: warning: no " .. mtype .. " marker found in " .. rel .. "\n")
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
  M._apply_create_description(project, "project '" .. key .. "'")
  out(string.format("added project '%s' (%s) at %s  [%s]", key, mtype, store_path or key, project._intent))
  out("")
  -- Next step (spec §16.38): how to map it, and where the configurations to
  -- map come from. `map` into an existing set, else `create` one.
  out("Map it into a configuration set to build it:")
  for _, l in ipairs(M._map_hint_lines(ws, key, "<config>", "  ")) do out(l) end
  if project._intent == "local" then
    out("Working copy only (--local). `lw project publish " .. key .. "` shares it later.")
  else
    out("Then `lw publish` writes it to the shared loomworks.json.")
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
  local shared = item_reaches_shared(ws, "projects", proj)
  local ok, err = ws:remove_project(proj)
  if not ok then die("could not remove project: " .. tostring(err)) end
  out("removed project '" .. proj.key .. "'")
  publish_hint(shared)
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
  local shared = item_reaches_shared(ws, "projects", proj)
  local ok, err = ws:rename_project(proj, new_name)
  if not ok then die("could not rename project: " .. tostring(err)) end
  out(string.format("renamed project '%s' -> '%s'", old_name, new_name))
  publish_hint(shared)
  return 0
end

--- `lw project [list]` — list the workspace's projects.
function M.cmd_project_list(root)
  local ws = read_workspace(root, false)
  local sorted = {}
  for _, p in ipairs(ws._projects or {}) do sorted[#sorted + 1] = p end
  if #sorted == 0 then out("(no projects)"); return 0 end
  table.sort(sorted, function(a, b) return a.key < b.key end)
  for _, p in ipairs(sorted) do
    local t = p.type or (p._module and p._module.id) or "?"
    local row = string.format("  %-20s %-10s %s", p.key, t, p.path or ".")
    out(row .. M._summary_suffix(require("loomworks.description").width(row), p.description))
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
  local ws = read_workspace(root, false)
  local proj = resolve_project(ws, name)
  local t = proj.type or (proj._module and proj._module.id) or "?"
  out(string.format("%s  (%s)", proj.key, t))
  M._describe_block(proj.description)
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

  local vars = require("loomworks.workspace_view").get_variables(proj)
  out("")
  out("  Variables:")
  if #vars == 0 then
    out("    (none)")
  else
    for _, v in ipairs(vars) do
      out(string.format("    %-22s %-7s%s", v.name, v.type,
        v.default ~= nil and ("  default=" .. v.default) or "  (blank)"))
    end
  end

  -- The device block (spec §18.9), when set.
  if type(proj.device) == "table" and next(proj.device) then
    out("")
    out("  Device:")
    for _, k in ipairs({ "stage", "archive", "working_dir" }) do
      local v = proj.device[k]
      if v ~= nil then
        out(string.format("    %-22s %s", k, type(v) == "table" and table.concat(v, " ") or tostring(v)))
      end
    end
    local names = {}
    for n in pairs(type(proj.device.env) == "table" and proj.device.env or {}) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do out(string.format("    %-22s %s", "env." .. n, tostring(proj.device.env[n]))) end
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

--- Parse `lw project set`'s args: the operands after `set` are the positionals
--- `<project> <variable> [<default>]` with an optional `--type <string|path>`
--- flag that may appear before or after the optional `<default>` (or as
--- `--type=<value>`). `argv` is the full command array
--- (`{ "project", "set", ... }`); operands start at index 3.
--- @param argv string[]
--- @return string[] positionals, string|nil var_type
local function parse_project_set_args(argv)
  local pos, var_type = {}, nil
  local i = 3
  while i <= #argv do
    local w = argv[i]
    local inline = w:match("^%-%-type=(.*)$")
    if w == "--type" then
      var_type = argv[i + 1]
      if not var_type then die("--type needs a value — use 'string' or 'path'") end
      i = i + 2
    elseif inline then
      var_type = inline
      i = i + 1
    else
      pos[#pos + 1] = w
      i = i + 1
    end
  end
  return pos, var_type
end
M._parse_project_set_args = parse_project_set_args

local PROJECT_SET_USAGE =
  "usage: lw project set <project> <variable> [<default>] [--type string|path]\n" ..
  "  declares (create-or-update) a project variable; omit <default> to declare\n" ..
  "  it BLANK — the active profile must fill it before a build that uses it\n" ..
  "  (see `lw config set variables.<name>` and `lw profile set`)"

--- `lw project set <project> <variable> [<default>] [--type string|path]` —
--- declare (create or update) a project variable. `--type` defaults to
--- `string`. Omitting `<default>` declares a BLANK variable (§1.3.1). Upserts
--- via Project:save_variable; persisted to user.json only.
function M.cmd_project_set(root, argv)
  local pos, var_type = parse_project_set_args(argv)
  local proj_name, var_name, default_val = pos[1], pos[2], pos[3]
  if not proj_name or not var_name then die(PROJECT_SET_USAGE) end
  -- `device.<field>`: the project's device block (spec §18.9).
  if var_name == "device" or var_name:match("^device%.") then
    if var_type then die("--type does not apply to the device block\n" .. DEV.BLOCK_USAGE) end
    return DEV.project_device_set(root, pos)
  end
  if #pos > 3 then die("too many arguments\n" .. PROJECT_SET_USAGE) end
  var_type = var_type or "string"
  if var_type ~= "string" and var_type ~= "path" then
    die("invalid --type '" .. tostring(var_type) .. "' — use 'string' or 'path'")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local decl = { type = var_type }
  if default_val ~= nil then decl.default = default_val end
  local ok, err = proj:save_variable(var_name, decl)
  if not ok then die(err or "failed to declare variable '" .. var_name .. "'") end
  out(string.format("%s: declared %s (type=%s, %s)", proj.key, var_name, var_type,
    default_val ~= nil and ("default=" .. default_val) or "blank"))
  return 0
end

--- `lw project unset <project> <variable>` — remove a project variable
--- declaration via Project:delete_variable. Persisted to user.json only.
function M.cmd_project_unset(root, proj_name, var_name)
  if not proj_name or not var_name then
    die("usage: lw project unset <project> <variable>\n" ..
      "  removes a project variable declaration")
  end
  if var_name == "device" or var_name:match("^device%.") then
    return DEV.project_device_unset(root, proj_name, var_name)
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  if not (proj.variables and proj.variables[var_name]) then
    local declared = {}
    for n in pairs(proj.variables or {}) do declared[#declared + 1] = n end
    table.sort(declared)
    die("project '" .. proj.key .. "' declares no variable '" .. var_name ..
      "'. Declared: " .. (next(declared) and table.concat(declared, ", ") or "(none)"))
  end
  local ok, err = proj:delete_variable(var_name)
  if not ok then die(err or "failed to remove variable '" .. var_name .. "'") end
  out(string.format("%s: removed variable %s", proj.key, var_name))
  return 0
end

function M.cmd_project(sub, root, a3, a4, a5, argv)
  if sub == "add" or sub == "create" then return M.cmd_project_add(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_project_remove(root, a3) end
  if sub == "rename" or sub == "mv" then return M.cmd_project_rename(root, a3, a4) end
  if sub == "show" then return M.cmd_project_show(root, a3) end
  if sub == "set" then return M.cmd_project_set(root, argv) end
  if sub == "unset" then return M.cmd_project_unset(root, a3, a4) end
  if sub == "publish" then return M.cmd_project_publish(root, a3) end
  if sub == "describe" then return M.cmd_describe("project", root, argv) end
  if sub == nil or sub == "list" then return M.cmd_project_list(root) end
  die("unknown project subcommand '" .. tostring(sub) ..
    "' — use add|remove|rename|list|show|set|unset|describe|publish")
end

-- ---------------------------------------------------------------------------
-- Configurations (list / add / show / get / set / unset / remove)
-- ---------------------------------------------------------------------------

--- Reconstruct the user-override data table (save_configuration's input shape)
--- from a live Configuration, so set/unset can read-modify-write.
local function config_to_data(cfg)
  -- Every declared field, deep-copied; derived module values are left out
  -- (Configuration:declared_data). The description is kept through the edit
  -- round-trip (spec §1.10); it is changed only by `describe`.
  return cfg:declared_data()
end

--- The accepted `lw config get/set/unset` param forms (§16.9), for errors.
local CONFIG_PARAM_FORMS = "inherits | languages | <module field> | options.<KEY> "
  .. "| variables.<NAME> | env.<NAME> | overrides.<family>.<NAME> "
  .. "| overrides.<family>.env.<NAME>  (family ∈ clang|gcc|msvc)"

--- Set (value) or clear (nil / "") `t[key]`, returning the table or nil when
--- it became empty (so emptied maps are pruned).
local function set_or_clear(t, key, value)
  t = t or {}
  t[key] = (value ~= nil and value ~= "") and value or nil
  return next(t) and t or nil
end

--- Set (value) or clear (nil / "") environment variable `name` in `t`,
--- treating names CASE-INSENSITIVELY for duplicates on every host (Windows
--- environment names are case-insensitive and a configuration file is shared
--- across hosts — the same rule as the reserved names): an existing entry
--- spelled differently (`PATH` vs `Path`) is REPLACED — the new spelling is
--- kept — and a clear removes every case variant. Returns the table (nil when
--- emptied) and the differently-spelled names that were dropped.
--- @param t table|nil
--- @param name string
--- @param value string|nil
--- @return table|nil t, string[] replaced
local function set_env_ci(t, name, value)
  local replaced = {}
  if type(t) == "table" then
    local lname = name:lower()
    for k in pairs(t) do
      if k ~= name and type(k) == "string" and k:lower() == lname then
        replaced[#replaced + 1] = k
      end
    end
    table.sort(replaced)
    for _, k in ipairs(replaced) do t[k] = nil end
  end
  return set_or_clear(t, name, value), replaced
end

--- Apply one `param`/`value` to a config data table (value nil clears). Param
--- namespaces (§16.9): options.<KEY>, variables.<NAME>, env.<NAME> (the
--- configuration environment, §1.3.3), overrides.<family>.<name> (a
--- compiler-family variable override) and overrides.<family>.env.<NAME> (a
--- compiler-family environment variable), family ∈ clang|gcc|msvc; the bare
--- fields inherits and languages (CSV); and any other BARE name → module
--- field. Any other dotted param is rejected rather than stored as a literal
--- dotted module-field name. Returns the case-variant env names a set/unset
--- replaced (`set_env_ci`) — empty for every other param.
--- @return string[] replaced
local function apply_param(data, param, value)
  if param == "options" or param == "variables" or param == "env" then
    die("specify a key: " .. param .. ".<KEY>")
  end
  -- Compiler-family override: overrides.<family>.<name> (three segments,
  -- mirroring the nested shape) or overrides.<family>.env.<NAME> (the
  -- family's environment sub-block). A nil/empty value CLEARS it and empty
  -- sub-tables / family tables / an empty `overrides` are pruned. Malformed
  -- shapes (bare `overrides`, `overrides.<family>` with no name,
  -- `overrides.<family>.env` with no NAME) are rejected here so the error
  -- names the expected form; declared-name validation is left to
  -- save_configuration.
  if param == "overrides" then
    die("specify a family and name: overrides.<family>.<name> or "
      .. "overrides.<family>.env.<NAME> (family ∈ clang|gcc|msvc)")
  end
  local ov_family, ov_name = param:match("^overrides%.([^.]+)%.(.+)$")
  if not ov_family and param:match("^overrides%.") then
    die("malformed override param '" .. param .. "' — expected "
      .. "overrides.<family>.<name> or overrides.<family>.env.<NAME> "
      .. "(family ∈ clang|gcc|msvc)")
  end
  if ov_family then
    if ov_family ~= "clang" and ov_family ~= "gcc" and ov_family ~= "msvc" then
      die("unknown compiler family '" .. ov_family
        .. "' — expected clang, gcc, or msvc")
    end
    data.overrides = data.overrides or {}
    local fam = data.overrides[ov_family] or {}
    if ov_name == "env" then
      die("specify a variable: overrides." .. ov_family .. ".env.<NAME>")
    end
    local env_name = ov_name:match("^env%.(.+)$")
    local replaced = {}
    if env_name then
      local env = type(fam.env) == "table" and fam.env or nil
      fam.env, replaced = set_env_ci(env, env_name, value)
    elseif ov_name:find(".", 1, true) then
      die("unknown parameter '" .. param .. "' — expected one of: " .. CONFIG_PARAM_FORMS)
    else
      -- A nil (unset) or empty value clears the entry.
      fam[ov_name] = (value ~= nil and value ~= "") and value or nil
    end
    data.overrides[ov_family] = next(fam) and fam or nil
    if not next(data.overrides) then data.overrides = nil end
    return replaced
  end
  local dictname, key = param:match("^(options)%.(.+)$")
  if not dictname then dictname, key = param:match("^(variables)%.(.+)$") end
  if dictname then
    data[dictname] = data[dictname] or {}
    data[dictname][key] = value
    if not next(data[dictname]) then data[dictname] = nil end
    return {}
  end
  local env_name = param:match("^env%.(.+)$")
  if env_name then
    -- Configuration environment (§1.3.3). An empty value clears, like unset.
    local replaced
    data.env, replaced = set_env_ci(data.env, env_name, value)
    return replaced
  end
  if param == "inherits" then
    if not value or value == "" then
      data.inherits = nil
    else
      local list = split_csv(value)
      data.inherits = (#list == 1) and list[1] or list
    end
  elseif param == "languages" then
    -- empty clears the override → inherit languages from the module
    data.languages = (value and value ~= "") and split_csv(value) or nil
  elseif param:find(".", 1, true) then
    -- Unknown dotted param: never store a literal dotted module-field name.
    die("unknown parameter '" .. param .. "' — expected one of: " .. CONFIG_PARAM_FORMS)
  else
    data[param] = value -- module field (variant, toolchain, generator, ...)
  end
  return {}
end

--- Read one `param` off a Configuration. Returns a string, a dict, or nil.
local function get_param(cfg, param)
  if param == "inherits" then
    return (cfg.inherits_names and #cfg.inherits_names > 0)
        and table.concat(cfg.inherits_names, ",") or nil
  elseif param == "languages" then
    return (cfg.languages and #cfg.languages > 0) and table.concat(cfg.languages, ",") or nil
  elseif param == "options" or param == "variables" or param == "env" then
    return cfg[param]
  elseif param == "overrides" then
    return cfg._overrides
  end
  local key = param:match("^options%.(.+)$")
  if key then return cfg.options and cfg.options[key] end
  key = param:match("^variables%.(.+)$")
  if key then return cfg.variables and cfg.variables[key] end
  key = param:match("^env%.(.+)$")
  if key then return cfg.env and cfg.env[key] end
  -- overrides.<family>.env.<NAME> → the string; overrides.<family>.env → the
  -- family's env dict; overrides.<family>.<name> → the string;
  -- overrides.<family> → that dict.
  local ov_family, ov_name = param:match("^overrides%.([^.]+)%.(.+)$")
  if ov_family then
    local fam = cfg._overrides and cfg._overrides[ov_family]
    if not fam then return nil end
    local env_name = ov_name:match("^env%.(.+)$")
    if env_name then return type(fam.env) == "table" and fam.env[env_name] or nil end
    return fam[ov_name]
  end
  ov_family = param:match("^overrides%.([^.]+)$")
  if ov_family then return cfg._overrides and cfg._overrides[ov_family] end
  if param:find(".", 1, true) then
    die("unknown parameter '" .. param .. "' — expected one of: " .. CONFIG_PARAM_FORMS)
  end
  return cfg.module_config and cfg.module_config[param]
end
-- Exported for tests: the pure param-grammar seams behind
-- `lw config get/set/unset`.
M._config_to_data = config_to_data
M._apply_param = apply_param
M._get_param = get_param

--- `lw config list [project]` — configs for one project, or all.
function M.cmd_configuration_list(root, proj_name)
  local ws = read_workspace(root, false)
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
        local row = string.format("%s%-22s %-7s%s", pad, c.name, kind,
          variant and ("  variant=" .. variant) or "")
        out(row .. M._summary_suffix(require("loomworks.description").width(row), c.description))
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
    "    lw config set " .. proj.key .. " <name> inherits "
      .. (base or "variant:<Name>"),
    "  `lw config list " .. proj.key .. "` shows the available bases.",
  }, "\n"))
end

--- Whether configuration `name` of `proj` would reach the shared
--- loomworks.json on the next publish — its own intent is shared /
--- local+shared, or a published configuration set pulls it in (§2.4 effective
--- intent). Gates the "`lw publish` …" hints: a local-only configuration has
--- nothing to publish. Errs on the side of the hint when the closure cannot be
--- computed.
--- @param ws table
--- @param proj loomworks.Project
--- @param name string
--- @return boolean
local function config_reaches_shared(ws, proj, name)
  if not M._has_shared_file(ws) then return false end
  local ok_p, pub = pcall(function() return ws:_publishable_to_shared() end)
  if not (ok_p and type(pub) == "table" and type(pub.configs) == "table") then return true end
  for _, c in ipairs(proj._configurations or {}) do
    if c.name == name and pub.configs[c] then return true end
  end
  return false
end

--- `lw config add <project> <name> [base...]`
--- Trailing arguments are BASES to inherit (e.g. `variant:Release asan`),
--- which is how a configuration becomes concrete — see `reject_variant_param`.
--- Several bases form a mixin chain, merged left to right (later wins), the
--- same order `set … inherits a,b` produces. Each argument may itself be a
--- comma-separated list, so both spellings work.
--- @param bases string[]|string|nil
function M.cmd_configuration_add(root, proj_name, name, bases)
  if not proj_name or not name then
    die("usage: lw config add <project> <name> [base...]")
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
        .. "\n  `lw config list " .. proj.key .. "` shows the bases "
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
  M._apply_create_description(proj:get_configuration(name), "configuration '" .. proj.key .. "/" .. name .. "'")
  out(string.format("added configuration '%s' to project '%s'%s", name, proj.key,
    #resolved > 0 and ("  (inherits " .. table.concat(resolved, ", ") .. ")") or ""))
  if not data.inherits then
    out("  no base — it is abstract (a mixin) and cannot be built until it")
    out("  inherits one that provides a variant:")
    out("    lw config set " .. proj.key .. " " .. name .. " inherits <base>")
  end
  -- Suggest publishing only when the new configuration would actually reach
  -- the shared file (same effective-intent check as config set/unset).
  out("  map it into a configuration set to build it:")
  for _, l in ipairs(M._map_hint_lines(ws, proj.key, name, "    ")) do out(l) end
  if config_reaches_shared(ws, proj, name) then
    out("  `lw publish` to share.")
  end
  return 0
end

--- `lw config show <project> <name>`
function M.cmd_configuration_show(root, proj_name, cfg_name)
  if not proj_name or not cfg_name then die("usage: lw config show <project> <name>") end
  local ws = read_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, false)
  local kind = cfg.is_user and "user" or (cfg:is_auto_gen() and "module-generated" or "preset")
  out(string.format("%s / %s", proj.key, cfg.name))
  M._describe_block(cfg.description, cfg._description_from_module)
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
  if cfg.env and next(cfg.env) then out("  env:"); print_dict("    ", cfg.env) end
  if cfg._overrides and next(cfg._overrides) then
    out("  overrides (compiler-family):"); print_dict("    ", cfg._overrides)
  end
  local ok, reasons = cfg:is_valid()
  if not ok then out("  invalid: " .. table.concat(reasons, "; ")) end
  local rows = config_set_rows(ws, proj)
  local using = {}
  for _, r in ipairs(rows) do if r.config == cfg.name then using[#using + 1] = r.set end end
  if #using > 0 then out("  used by sets    " .. table.concat(using, ", ")) end
  return 0
end

--- `lw config get <project> <name> <param>`
function M.cmd_configuration_get(root, proj_name, cfg_name, param)
  if not (proj_name and cfg_name and param) then
    die("usage: lw config get <project> <name> <param>\n" ..
      "  param: inherits | languages | options.<KEY> | variables.<NAME> | env[.<NAME>]\n" ..
      "         | overrides[.<family>[.<NAME> | .env[.<NAME>]]] | <module field>")
  end
  local ws = read_workspace(root, false)
  local cfg = resolve_config(resolve_project(ws, proj_name), cfg_name, false)
  if param == "description" then
    if cfg.description then M._describe_print(cfg.description) else out("(unset)") end
    return 0
  end
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
  -- A `cache` policy (variables.cache / overrides.<family>.cache) is stored in
  -- its canonical spelling (`SCCACHE` → `sccache`, `none` → `off`); an invalid
  -- one passes through unchanged for save_configuration to reject.
  local cc = require("loomworks.compiler_cache")
  local is_cache_param = param == "variables.cache"
    or param:match("^overrides%.[^.]+%.cache$") ~= nil
  if is_cache_param then value = cc.canonical_policy(value) end
  local data = config_to_data(cfg)
  local before = vim.deepcopy(data)
  local replaced = apply_param(data, param, value) or {}
  -- Nothing changed (an unset of a param that was never set, or a set to the
  -- value it already has — for a cache policy, the same canonical policy):
  -- say so, write nothing, and suggest no publish.
  -- Exit 0 — an idempotent edit is not an error (a script may re-run it).
  local unchanged = vim.deep_equal(before, data)
  if not unchanged and is_cache_param and value ~= nil and value ~= "" then
    unchanged = cc.canonical_policy(get_param(cfg, param)) == value
  end
  if unchanged then
    if verb == "set" then
      out(string.format("%s/%s: %s = %s (unchanged)", proj.key, cfg.name, param, value))
    else
      out(string.format("%s/%s: %s is not set (nothing to unset)", proj.key, cfg.name, param))
    end
    return 0
  end
  local ok, err = proj:save_configuration(cfg.name, data)
  if not ok then die("could not " .. verb .. ": " .. tostring(err)) end
  if verb == "set" then
    out(string.format("%s/%s: set %s = %s", proj.key, cfg.name, param, value))
    local prefix = param:match("^(.*%.)[^.]+$") or ""
    for _, old in ipairs(replaced) do
      out(string.format("  (replaces %s%s — environment names are case-insensitive)", prefix, old))
    end
    -- `PATH` (any case) is allowed but replaces the tool's PATH wholesale
    -- (§1.3.3) — say so now, not only when a build later cannot find cl.exe.
    local env_name = param:match("^env%.(.+)$") or param:match("^overrides%.[^.]+%.env%.(.+)$")
    if env_name and require("loomworks.reserved_compiler").is_path_env(env_name) then
      note("warning: " .. param .. " replaces the PATH the tool sets up for every "
        .. "configure/build/test task of " .. proj.key .. "/" .. cfg.name
        .. " (e.g. the MSVC developer environment — cl.exe / link.exe may then not be "
        .. "found). ${PATH} in the value expands to lw's own PATH, not the tool's.")
    end
  else
    out(string.format("%s/%s: unset %s", proj.key, cfg.name, param))
  end
  -- Point at `lw publish` only when something changed (above) and this
  -- configuration actually reaches the shared loomworks.json.
  if config_reaches_shared(ws, proj, cfg.name) then
    out("`lw publish` to update the shared loomworks.json.")
  end
  return 0
end

--- `lw config set <project> <name> <param> <value>`
function M.cmd_configuration_set(root, proj_name, cfg_name, param, value)
  if not (proj_name and cfg_name and param) or value == nil then
    die("usage: lw config set <project> <name> <param> <value>\n" ..
      "  param: inherits | languages | options.<KEY> | variables.<NAME> | env.<NAME>\n" ..
      "         | overrides.<family>.<NAME> | overrides.<family>.env.<NAME>\n" ..
      "         (family ∈ clang|gcc|msvc) | <module field>\n" ..
      "  (use `lw config unset` to clear a value)")
  end
  -- `description` is a generic field (spec §1.10): same rules as `describe`.
  if param == "description" then
    return M.cmd_describe("config", root, { "config", "describe", proj_name, cfg_name, value })
  end
  return edit_configuration(root, proj_name, cfg_name, param, value, "set")
end

--- `lw config unset <project> <name> <param>`
function M.cmd_configuration_unset(root, proj_name, cfg_name, param)
  if not (proj_name and cfg_name and param) then
    die("usage: lw config unset <project> <name> <param>\n" ..
      "  param: inherits | languages | options.<KEY> | variables.<NAME> | env.<NAME>\n" ..
      "         | overrides.<family>.<NAME> | overrides.<family>.env.<NAME>\n" ..
      "         (family ∈ clang|gcc|msvc) | <module field>")
  end
  if param == "description" then
    return M.cmd_describe("config", root, { "config", "describe", proj_name, cfg_name, "--clear" })
  end
  return edit_configuration(root, proj_name, cfg_name, param, nil, "unset")
end

--- `lw config remove <project> <name>`
function M.cmd_configuration_remove(root, proj_name, cfg_name)
  if not proj_name or not cfg_name then
    die("usage: lw config remove <project> <name>")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, true)
  local shared = item_reaches_shared(ws, "configs", cfg, proj)
  local ok, err = proj:delete_configuration(cfg.name)
  if not ok then die("could not remove configuration: " .. tostring(err)) end
  out(string.format("removed configuration '%s' from project '%s'", cfg.name, proj.key))
  publish_hint(shared)
  return 0
end

--- `lw config rename <project> <old> <new>` (alias `mv`) — rename a
--- user-declared configuration in place. Delegates to the same atomic mutation
--- the editor uses (Project:rename_configuration), which updates the config-set
--- mappings, ConfigUnits, and profiles that reference it and orphans the old
--- build dir. For a pure rename we hand it the EXISTING config's user-override
--- data (via config_to_data) so nothing but the name changes. Only works on a
--- user configuration; module-generated/preset configs (e.g. variant:Debug)
--- surface rename_configuration's "not found" error via die.
function M.cmd_configuration_rename(root, proj_name, old_name, new_name)
  if not (proj_name and old_name and new_name) then
    die("usage: lw config rename <project> <old> <new>")
  end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, old_name, false)
  -- rename_configuration mutates cfg.name in place, so snapshot it for the
  -- confirmation line before the call.
  local from = cfg.name
  -- Guard an exact-name collision here: rename_configuration only validates the
  -- name shape (validate_path_name), whose collision check skips exact matches,
  -- so renaming onto an existing user config would silently merge the two. The
  -- configset path rejects this in its own mutation; mirror that at the CLI.
  if new_name ~= from then
    for _, other in ipairs(proj:get_configurations()) do
      if other ~= cfg and other.is_user and other.name == new_name then
        die("could not rename configuration: configuration '" .. new_name ..
          "' already exists in project '" .. proj.key .. "'")
      end
    end
  end
  local config_data = config_to_data(cfg)
  local shared = item_reaches_shared(ws, "configs", cfg, proj)
  local ok, err = proj:rename_configuration(from, new_name, config_data)
  if not ok then die("could not rename configuration: " .. tostring(err)) end
  out(string.format("renamed configuration '%s/%s' -> '%s/%s'",
    proj.key, from, proj.key, new_name))
  publish_hint(shared)
  return 0
end

--- `lw config<list|add|show|get|set|unset|rename|remove>`
--- `lw config publish <project> <name>` — mark a configuration (and its
--- project) shared and write loomworks.json.
function M.cmd_configuration_publish(root, proj_name, cfg_name)
  if not (proj_name and cfg_name) then die("usage: lw config publish <project> <name>") end
  local ws = load_workspace(root, false)
  local proj = resolve_project(ws, proj_name)
  local cfg = resolve_config(proj, cfg_name, false)
  -- A configuration can't be published without its project.
  if proj._intent == "local" or proj._intent == nil then proj._intent = "local+shared" end
  return publish_item(ws, cfg, "configuration '" .. proj.key .. ":" .. cfg.name .. "'")
end

function M.cmd_configuration(sub, root, a3, a4, a5, a6, argv)
  if sub == nil or sub == "list" then return M.cmd_configuration_list(root, a3) end
  if sub == "add" or sub == "create" then
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
  if sub == "rename" or sub == "mv" then return M.cmd_configuration_rename(root, a3, a4, a5) end
  if sub == "remove" or sub == "rm" then return M.cmd_configuration_remove(root, a3, a4) end
  if sub == "publish" then return M.cmd_configuration_publish(root, a3, a4) end
  if sub == "describe" then return M.cmd_describe("config", root, argv) end
  die("unknown config subcommand '" .. tostring(sub) ..
    "' — use list|add|show|get|set|unset|rename|describe|remove|publish")
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

--- `lw configset list` — all sets with their mappings.
function M.cmd_cset_list(root)
  local ws = read_workspace(root, false)
  local sets = {}
  for _, cs in ipairs(ws._config_sets or {}) do sets[#sets + 1] = cs end
  if #sets == 0 then out("(no configuration sets)"); return 0 end
  table.sort(sets, function(a, b) return a.name < b.name end)
  -- One layout rule (spec §16.35): name, then the summary column, then the
  -- open-ended mapping list, which takes the truncation on a terminal.
  local d = require("loomworks.description")
  local name_w, descs = 16, {}
  for i, cs in ipairs(sets) do
    name_w = math.max(name_w, d.width(cs.name))
    descs[i] = cs.description
  end
  local prefix_w = 2 + name_w
  local tw = M._term_width()
  local sum_w = M._summary_column(descs, tw, prefix_w, true)
  local tail_w = nil
  if M._stdout_tty() then
    local used = prefix_w + 1 + (sum_w > 0 and (sum_w + 3) or 0)
    tail_w = math.max(16, tw - used)
  end
  for _, cs in ipairs(sets) do
    local rows = {}
    for project, cfg in pairs(cs.mappings or {}) do rows[#rows + 1] = project.key .. "→" .. cfg.name end
    table.sort(rows)
    local prefix = "  " .. cs.name .. string.rep(" ", name_w - d.width(cs.name))
    out(M._row_with_summary(prefix, cs.description, sum_w,
      next(rows) and rows or "(empty)", tail_w))
  end
  return 0
end

--- `lw configset show <name>`
function M.cmd_cset_show(root, name)
  if not name then die("usage: lw configset show <name>") end
  local ws = read_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  out(cs.name)
  M._describe_block(cs.description)
  if cs._intent then out("  intent          " .. cs._intent) end
  out("  Mappings:")
  local rows = {}
  for project, cfg in pairs(cs.mappings or {}) do
    rows[#rows + 1] = { p = project.key, c = cfg.name, stale = (cfg._source_missing or cfg._removed) }
  end
  table.sort(rows, function(a, b) return a.p < b.p end)
  if #rows == 0 then
    out("    (empty — add with `lw configset map " .. cs.name .. " <project> <config>`)")
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

--- `lw configset create <name> [project=config ...]`
--- Also accepts positional `<project> <config>` pairs (the same grammar as
--- `configset map`), e.g. `lw configset create dev app Debug renderer Release`.
--- The form is chosen by whether the first mapping token contains `=`.
function M.cmd_cset_create(root, args)
  local name = args[3]
  if not name then
    die("usage: lw configset create <name> [project=config ...]\n" ..
      "   or: lw configset create <name> [<project> <config> ...]")
  end
  local ws = load_workspace(root, false)
  local raw = {}
  local rest = {}
  for i = 4, #args do rest[#rest + 1] = args[i] end
  if rest[1] and not rest[1]:find("=", 1, true) then
    -- Positional `<project> <config>` pairs (matching `configset map`).
    if #rest % 2 ~= 0 then
      die("positional mappings must come in <project> <config> pairs: " ..
        table.concat(rest, " "))
    end
    for i = 1, #rest, 2 do
      local project = resolve_project(ws, rest[i])
      local cfg = resolve_config(project, rest[i + 1], false)
      raw[project.key] = cfg.name
    end
  else
    for _, spec in ipairs(rest) do
      local pk, cfgname = parse_mapping(ws, spec)
      raw[pk] = cfgname
    end
  end
  local cs, err = ws:add_configuration_set(name, raw)
  if not cs then die("could not create configuration set: " .. tostring(err)) end
  cs._intent = created_intent()
  ws:_save_user()
  M._apply_create_description(cs, "configuration set '" .. cs.name .. "'")
  out("created configuration set '" .. cs.name .. "'  [" .. cs._intent .. "]" ..
    (next(raw) and "" or " (empty)"))
  if not next(raw) then
    out("  add mappings: lw configset map " .. cs.name .. " <project> <config>")
  end
  if cs._intent == "local" then
    out("`lw configset publish " .. cs.name .. "` shares it. ")
  end
  out("`lw profile create " .. cs.name .. " <tool>` to build it (`lw tools` lists tools).")
  return 0
end

--- `lw configset map <name> <project> <config>`
function M.cmd_cset_map(root, name, pk, cfgname)
  if not (name and pk and cfgname) then
    die("usage: lw configset map <name> <project> <config>")
  end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local project = resolve_project(ws, pk)
  local cfg = resolve_config(project, cfgname, false)
  local ok, err = cs:update_mapping(project, cfg)
  if not ok then die("could not map: " .. tostring(err)) end
  out(string.format("%s: %s -> %s", cs.name, project.key, cfg.name))
  publish_hint(item_reaches_shared(ws, "config_sets", cs))
  return 0
end

--- `lw configset unmap <name> <project>`
function M.cmd_cset_unmap(root, name, pk)
  if not (name and pk) then die("usage: lw configset unmap <name> <project>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local project = resolve_project(ws, pk)
  if not cs.mappings[project] then die("'" .. pk .. "' is not mapped in '" .. cs.name .. "'") end
  local ok, err = cs:update_mapping(project, nil)
  if not ok then die("could not unmap: " .. tostring(err)) end
  out(cs.name .. ": removed mapping for " .. project.key)
  publish_hint(item_reaches_shared(ws, "config_sets", cs))
  return 0
end

--- `lw configset remove <name>`
function M.cmd_cset_remove(root, name)
  if not name then die("usage: lw configset remove <name>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  local using = profiles_using_set(ws, cs)
  local shared = item_reaches_shared(ws, "config_sets", cs)
  local ok, err = ws:remove_configuration_set(cs)
  if not ok then die("could not remove configuration set: " .. tostring(err)) end
  out("removed configuration set '" .. cs.name .. "'")
  if #using > 0 then
    out("  note: these profiles now reference a missing set: " .. table.concat(using, ", "))
  end
  publish_hint(shared)
  return 0
end

--- `lw configset rename <old> <new>` (alias `mv`) — rename a configuration set
--- in place. Delegates to the same atomic mutation the editor uses
--- (Workspace:rename_configuration_set): validates the name, rejects a
--- collision, and re-derives the keys of profiles that reference the set. Its
--- error (invalid/colliding name) surfaces via die.
function M.cmd_cset_rename(root, old_name, new_name)
  if not (old_name and new_name) then
    die("usage: lw configset rename <old> <new>")
  end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, old_name)
  local shared = item_reaches_shared(ws, "config_sets", cs)
  local ok, err = ws:rename_configuration_set(cs, new_name)
  if not ok then die("could not rename configuration set: " .. tostring(err)) end
  out(string.format("renamed configuration set '%s' -> '%s'", old_name, new_name))
  publish_hint(shared)
  return 0
end

--- `lw configset <list|show|create|map|unmap|rename|remove>` (alias: cs)
--- `lw configset publish <name>` — mark a set shared and write
--- loomworks.json (pulls its mapped projects + configs via the closure).
function M.cmd_cset_publish(root, name)
  if not name then die("usage: lw configset publish <name>") end
  local ws = load_workspace(root, false)
  local cs = resolve_config_set(ws, name)
  return publish_item(ws, cs, "configuration set '" .. cs.name .. "'")
end

function M.cmd_cset(sub, root, args)
  if sub == nil or sub == "list" then return M.cmd_cset_list(root) end
  if sub == "show" then return M.cmd_cset_show(root, args[3]) end
  if sub == "create" or sub == "add" then return M.cmd_cset_create(root, args) end
  if sub == "map" then return M.cmd_cset_map(root, args[3], args[4], args[5]) end
  if sub == "unmap" then return M.cmd_cset_unmap(root, args[3], args[4]) end
  if sub == "rename" or sub == "mv" then return M.cmd_cset_rename(root, args[3], args[4]) end
  if sub == "remove" or sub == "rm" then return M.cmd_cset_remove(root, args[3]) end
  if sub == "publish" then return M.cmd_cset_publish(root, args[3]) end
  if sub == "describe" then return M.cmd_describe("configset", root, args) end
  die("unknown configset subcommand '" .. tostring(sub) ..
    "' — use list|show|create|map|unmap|rename|describe|remove|publish")
end

-- ---------------------------------------------------------------------------
-- Descriptions: `lw <project|config|configset|profile> describe` (spec §16.35)
-- (Helpers are M. fields: this chunk is at Lua's 200-local limit.)
-- ---------------------------------------------------------------------------

--- Parse a `describe` argument tail (everything after the item operands).
--- Exactly one text source: `<text>`, `-m <para>` (repeatable), `-F <file>`,
--- `-F -` / a lone `-` (stdin), `--clear`; `-e`/`--edit` opens an editor and
--- may be combined with a text source (pre-fill). `--json` selects the JSON
--- read form. Usage errors die.
--- @param rest string[]
--- @param usage string
--- @return table opts { paras?, text?, file?, stdin?, edit?, clear?, json? }
function M._describe_parse(rest, usage)
  local o = {}
  local sources = 0
  local i = 1
  while i <= #rest do
    local v = rest[i]
    if v == "-m" or v == "--message" then
      local p = rest[i + 1]
      if p == nil then die("-m needs a paragraph\n" .. usage) end
      if not o.paras then o.paras = {}; sources = sources + 1 end
      o.paras[#o.paras + 1] = p
      i = i + 2
    elseif v:sub(1, 3) == "-m=" or v:sub(1, 10) == "--message=" then
      if not o.paras then o.paras = {}; sources = sources + 1 end
      o.paras[#o.paras + 1] = v:match("^[^=]+=(.*)$")
      i = i + 1
    elseif v == "-F" or v == "--file" then
      local f = rest[i + 1]
      if f == nil then die("-F needs a file (or - for stdin)\n" .. usage) end
      if f == "-" then o.stdin = true else o.file = f end
      sources = sources + 1
      i = i + 2
    elseif v == "-" then
      o.stdin = true; sources = sources + 1; i = i + 1
    elseif v == "-e" or v == "--edit" then
      o.edit = true; i = i + 1
    elseif v == "--clear" then
      o.clear = true; i = i + 1
    elseif v == "--json" then
      o.json = true; i = i + 1
    elseif v:sub(1, 1) == "-" and v ~= "" then
      die("unknown option '" .. v .. "'\n" .. usage)
    else
      if o.text ~= nil then die("give the description as one quoted argument\n" .. usage) end
      o.text = v; sources = sources + 1; i = i + 1
    end
  end
  if sources > 1 then die("give the description one way only (<text>, -m, -F or -)\n" .. usage) end
  if o.clear and (sources > 0 or o.edit) then die("--clear takes no description\n" .. usage) end
  if o.json and (sources > 0 or o.edit or o.clear) then
    die("--json prints the description; it does not set one\n" .. usage)
  end
  return o
end

--- The text a write form supplies (before normalisation), or nil for the read
--- form. `-m` paragraphs join with a blank line (git).
--- @param o table parsed options
--- @return string|nil
function M._describe_source_text(o)
  if o.paras then return table.concat(o.paras, "\n\n") end
  if o.text ~= nil then return o.text end
  if o.stdin then return (M._describe_read_stdin or function() return io.read("*a") end)() or "" end
  if o.file then
    local f, ferr = io.open(o.file, "rb")
    if not f then die("cannot read " .. o.file .. ": " .. tostring(ferr)) end
    local s = f:read("*a") or ""
    f:close()
    return s
  end
  return nil
end

--- Open $VISUAL / $EDITOR on a temporary file pre-filled with `prefill` plus
--- `#` help lines; return the saved text with the `#` lines removed, or nil
--- when the editor failed (aborted: nothing is written).
--- @param prefill string
--- @param what string e.g. "profile 'Debug:gcc'"
--- @param root string
--- @return string|nil
function M._describe_edit(prefill, what, root)
  if not interactive() then
    die("--edit needs an interactive terminal; give the description with -m, "
      .. "-F <file>, -F - (stdin) or as an argument")
  end
  local editor = os.getenv("VISUAL")
  if not editor or editor == "" then editor = os.getenv("EDITOR") end
  if not editor or editor == "" then
    die("no editor: set $VISUAL or $EDITOR, or give the description with -m, "
      .. "-F <file>, -F - or as an argument")
  end
  -- In the workspace's .nvim/tmp, not the system temp dir (§16.40).
  local path = require("loomworks.housekeeping").tmp_path(root, "lw-describe-", ".txt")
  local f = io.open(path, "wb")
  if not f then die("cannot create a temporary file for the editor") end
  f:write((prefill or "") .. "\n\n"
    .. "# Describe " .. what .. ".\n"
    .. "# The first line is the summary shown in lists; add a blank line, then details.\n"
    .. "# Lines starting with '#' are ignored. Save an empty description to remove it.\n")
  f:close()
  local argv = shell_split(editor)
  argv[#argv + 1] = path
  local code = (M._describe_run_editor or run_spec)({ cmd = argv }, root)
  local text
  if code == 0 then
    local rf = io.open(path, "rb")
    if rf then
      local lines = {}
      for line in ((rf:read("*a") or "") .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
      end
      rf:close()
      text = require("loomworks.description").strip_comments(lines)
    end
  end
  os.remove(path)
  if code ~= 0 then
    note("lw: the editor exited with status " .. tostring(code) .. " - description unchanged")
    return nil
  end
  return text or ""
end

--- Print a description in full, one output line per description line,
--- optionally indented (§16.7 / §17.11 rendering).
--- @param desc string
--- @param indent? string
function M._describe_print(desc, indent)
  local d = require("loomworks.description")
  for line in (d.inert(desc) .. "\n"):gmatch("([^\n]*)\n") do
    out(line == "" and "" or ((indent or "") .. line))
  end
end

--- Run `describe` on a resolved item.
--- @param ws table
--- @param item table Project|Configuration|ConfigurationSet|Profile
--- @param kind string "project"|"configuration"|"configuration set"|"profile"
--- @param name string display name
--- @param shared_kind string item_reaches_shared kind
--- @param proj table|nil owning project (configurations)
--- @param o table parsed options
--- @return integer
function M._describe_item(ws, item, kind, name, shared_kind, proj, o)
  local d = require("loomworks.description")
  local current = item.description
  local generated = item._description_from_module == true
  local text = M._describe_source_text(o)
  if text == nil and not o.edit and not o.clear then
    -- Read form.
    if o.json then
      local json_kind = ({ ["configuration set"] = "configset", configuration = "config",
        ["launch configuration"] = "launch" })[kind] or kind
      local obj = {
        kind = json_kind,
        name = name,
        description = current or vim.NIL,
        summary = d.summary(current) or vim.NIL,
        source = generated and "project-files" or "workspace",
      }
      for k, v in pairs(item._json_extra or {}) do obj[k] = v end
      out(vim.json.encode(obj))
      return 0
    end
    if not current then
      note(kind .. " '" .. name .. "' has no description")
      return 0
    end
    if generated then note("(from the project files; read-only)") end
    M._describe_print(current)
    return 0
  end
  if o.edit then
    text = M._describe_edit(text or current or "", kind .. " '" .. name .. "'", ws.root)
    if text == nil then return 0 end
  end
  if o.clear then text = nil end
  local was = current
  local changed, err = item:set_description(text)
  if changed == nil then die("cannot describe " .. kind .. " '" .. name .. "': " .. tostring(err)) end
  if changed == false then
    if was == nil then
      out(kind .. " '" .. name .. "' has no description")
    else
      out(kind .. " '" .. name .. "': description (unchanged)")
    end
    return 0
  end
  if item.description == nil then
    out(kind .. " '" .. name .. "': description removed")
  else
    out(kind .. " '" .. name .. "' described")
  end
  publish_hint(item_reaches_shared(ws, shared_kind, item._shared_item or item, proj))
  return 0
end

--- Is stdout a terminal? (Test seam: `M._test_stdout_tty`.)
--- @return boolean
function M._stdout_tty()
  if M._test_stdout_tty ~= nil then return M._test_stdout_tty end
  local ok, h = pcall(uv.guess_handle, 1)
  return ok and h == "tty"
end

--- The summary placed after a one-line row (spec §16.35): "  <summary>"
--- fitted to what the terminal leaves (at most 60 columns; 60 when stdout is
--- not a terminal), or a continuation line "\n      <summary>" when fewer than
--- 16 columns remain or `force_cont`. "" when there is no description.
--- @param plain_w integer display width of the row's visible text
--- @param desc string|nil
--- @param tw integer|nil terminal width (default: term_width())
--- @param pal table|nil status palette (summary is dimmed)
--- @param force_cont boolean|nil always use the continuation line
--- @return string
function M._summary_suffix(plain_w, desc, tw, pal, force_cont)
  local d = require("loomworks.description")
  local sum = d.summary(desc)
  if not sum then return "" end
  sum = d.inert_line(sum)
  local dim = (pal and pal.dim) or function(x) return x end
  local indent = "      "
  if not M._stdout_tty() then
    if force_cont then return "\n" .. indent .. dim(d.fit(sum, 60)) end
    return "  " .. dim(d.fit(sum, 60))
  end
  tw = tw or M._term_width()
  local avail = tw - plain_w - 2
  if not force_cont and avail >= 16 then
    return "  " .. dim(d.fit(sum, math.min(60, avail)))
  end
  return "\n" .. indent .. dim(d.fit(sum, math.min(60, math.max(1, tw - #indent))))
end

--- Widest summary column in a row with an open-ended tail (spec §16.35).
M._SUMMARY_TAIL_CAP = 36

--- Width of the summary column for a listing whose rows end in an
--- open-ended list (spec §16.35): as wide as the longest summary shown, at
--- most 36 columns; 0 when no row has a description; -1 when fewer than 16
--- columns would remain for it on this terminal (continuation lines instead).
--- `full_when_piped`: a listing that prints its open-ended list in full when
--- stdout is not a terminal (`lw launch list`, `lw configset list`) prints the
--- summaries in full too — the column is then as wide as the longest summary,
--- uncapped. The status overview keeps the cap (its lists stay cut).
--- @param descs (string|nil)[] the rows' descriptions
--- @param tw integer terminal width
--- @param prefix_w integer display width of the widest identity/fixed prefix
--- @param full_when_piped boolean|nil
--- @return integer
function M._summary_column(descs, tw, prefix_w, full_when_piped)
  local d = require("loomworks.description")
  local longest = 0
  for i = 1, #descs do
    local sum = d.summary(descs[i])
    if sum then longest = math.max(longest, d.width(d.inert_line(sum))) end
  end
  if longest == 0 then return 0 end
  if not M._stdout_tty() then
    return full_when_piped and longest or math.min(longest, M._SUMMARY_TAIL_CAP)
  end
  local w = math.min(longest, M._SUMMARY_TAIL_CAP)
  -- Room left after the prefix, two gaps and a 16-column minimum for the list.
  local avail = tw - prefix_w - 2 - 2 - 16
  if avail < 16 then return -1 end
  return math.min(w, avail)
end

--- Fit an open-ended list to `width` display columns (spec §16.35) without
--- cutting an entry mid-way: the entries joined with ", " (then " +more" for
--- entries the caller already left out) when that fits; otherwise the most
--- leading whole entries that fit, then " …+N" for every entry not shown. Only
--- when not even the first entry fits whole is the list cut in display columns
--- with `…`. `width == nil` prints the list in full.
--- @param items string[]
--- @param more integer|nil entries already left out by the caller (counted in +N)
--- @param width integer|nil
--- @return string
function M._fit_list(items, more, width)
  local d = require("loomworks.description")
  more = more or 0
  local full = table.concat(items, ", ") .. (more > 0 and (" +" .. more) or "")
  if not width or d.width(full) <= width then return full end
  local total = #items + more
  for k = #items - 1, 1, -1 do
    local s = table.concat(items, ", ", 1, k) .. " …+" .. (total - k)
    if d.width(s) <= width then return s end
  end
  return d.fit(full, math.max(1, width))
end

--- Build a one-line row with an open-ended tail (spec §16.35): `prefix`, then
--- the summary column (`sum_w` from `_summary_column`), then `tail` cut to
--- `tail_w` display columns (nil = in full). A `tail` given as a list of
--- entries (optional `more` field: entries already left out) is fitted at
--- whole-entry boundaries by `_fit_list`. With `sum_w == 0` the row is
--- `prefix .. " " .. tail`; with `sum_w == -1` the summary goes on an indented
--- continuation line.
--- @param prefix string identity + fixed columns (already padded)
--- @param desc string|nil
--- @param sum_w integer
--- @param tail string|string[]
--- @param tail_w integer|nil
--- @param pal table|nil status palette (summary dimmed)
--- @return string
function M._row_with_summary(prefix, desc, sum_w, tail, tail_w, pal)
  local d = require("loomworks.description")
  local dim = (pal and pal.dim) or function(x) return x end
  local t
  if type(tail) == "table" then
    t = M._fit_list(tail, tail.more, tail_w and math.max(1, tail_w))
  else
    t = tail_w and d.fit(tail, math.max(1, tail_w)) or tail
  end
  local sum = d.summary(desc)
  sum = sum and d.inert_line(sum) or nil
  if sum_w == 0 then return prefix .. " " .. t end
  if sum_w < 0 then
    local row = prefix .. " " .. t
    if not sum then return row end
    local tw = M._stdout_tty() and M._term_width() or 66
    return row .. "\n      " .. dim(d.fit(sum, math.min(60, math.max(1, tw - 6))))
  end
  local text = sum and d.fit(sum, sum_w) or ""
  local padded = text .. string.rep(" ", math.max(0, sum_w - d.width(text)))
  return prefix .. "  " .. (text ~= "" and dim(padded) or padded) .. "  " .. t
end

--- Print an item's full description in a detail view, under a `description`
--- label aligned with the other `  label           value` rows (spec §16.35).
--- @param desc string|nil
--- @param generated boolean|nil module default (read-only)
function M._describe_block(desc, generated)
  if not desc then return end
  local d = require("loomworks.description")
  local first = true
  for line in (d.inert(desc) .. "\n"):gmatch("([^\n]*)\n") do
    if first then
      out("  description     " .. line .. (generated and "   (from the project files)" or ""))
      first = false
    else
      out(line == "" and "" or ("                  " .. line))
    end
  end
end

M._DESCRIBE_USAGE = {
  project = "usage: lw project describe <project> [<text> | -m <para>... | -F <file|-> | - | -e | --clear | --json]",
  config = "usage: lw config describe <project> <config> [<text> | -m <para>... | -F <file|-> | - | -e | --clear | --json]",
  configset = "usage: lw configset describe <set> [<text> | -m <para>... | -F <file|-> | - | -e | --clear | --json]",
  profile = "usage: lw profile describe <profile> [<text> | -m <para>... | -F <file|-> | - | -e | --clear | --json]",
}

--- `lw <kind> describe ...` - resolve the item from `args` (the full argv,
--- where args[1] is the command and args[2] is `describe`) and run it.
--- @param kind "project"|"config"|"configset"|"profile"
--- @param root string
--- @param args string[]
--- @return integer
function M.cmd_describe(kind, root, args)
  local usage = M._DESCRIBE_USAGE[kind]
  local n_ops = (kind == "config") and 2 or 1
  local ops, rest = {}, {}
  for i = 3, #args do
    if #ops < n_ops then
      if args[i]:sub(1, 1) == "-" and args[i] ~= "-" then die(usage) end
      ops[#ops + 1] = args[i]
    else
      rest[#rest + 1] = args[i]
    end
  end
  if #ops < n_ops then die(usage) end
  local o = M._describe_parse(rest, usage)
  -- The read form reads the runtime's projection in daemon mode (§19.13);
  -- a form that writes loads the workspace in-process.
  local reading = not (o.paras or o.text ~= nil or o.stdin or o.file or o.edit or o.clear)
  local ws = reading and read_workspace(root, false) or load_workspace(root, false)
  if kind == "project" then
    local proj = resolve_project(ws, ops[1])
    return M._describe_item(ws, proj, "project", proj.key, "projects", nil, o)
  elseif kind == "config" then
    local proj = resolve_project(ws, ops[1])
    local cfg = resolve_config(proj, ops[2], false)
    return M._describe_item(ws, cfg, "configuration", proj.key .. "/" .. cfg.name, "configs", proj, o)
  elseif kind == "configset" then
    local cs = resolve_config_set(ws, ops[1])
    return M._describe_item(ws, cs, "configuration set", cs.name, "config_sets", nil, o)
  end
  local profile = resolve_profile(ws, ops[1])
  return M._describe_item(ws, profile, "profile", profile.key, "profiles", nil, o)
end

--- `-m <para>` on an item-creating verb (spec §16.35): main() strips the
--- pairs from argv into `M._create_paras`; the create command calls this on
--- the new item after saving it.
--- @param item table
--- @param what string display label
function M._apply_create_description(item, what)
  local paras = M._create_paras
  if not paras or not item or not item.set_description then return end
  M._create_paras = nil
  local changed, err = item:set_description(table.concat(paras, "\n\n"))
  if changed == nil then
    errw("lw: warning: " .. what .. " created, but its description was refused: " .. tostring(err) .. "\n")
  end
end

--- Strip `-m <para>` / `-m=<para>` pairs from a create command's argv (in
--- place) into `M._create_paras`.
--- @param a string[]
function M._extract_create_paras(a)
  local kept, paras = {}, {}
  local i = 1
  while i <= #a do
    local v = a[i]
    if (v == "-m" or v == "--message") and a[i + 1] ~= nil then
      paras[#paras + 1] = a[i + 1]; i = i + 2
    elseif v:sub(1, 3) == "-m=" or v:sub(1, 10) == "--message=" then
      paras[#paras + 1] = v:match("^[^=]+=(.*)$"); i = i + 1
    else
      kept[#kept + 1] = v; i = i + 1
    end
  end
  for k = #a, 1, -1 do a[k] = nil end
  for k, v in ipairs(kept) do a[k] = v end
  M._create_paras = #paras > 0 and paras or nil
end

--- Clear the active profile (`lw profile select --none`). Idempotent: with no
--- active profile it says so and writes nothing. A stale active key (naming a
--- profile that no longer exists) is cleared too.
--- @param ws table
--- @return integer exit code
local function clear_active_profile(ws)
  local active = ws._active_profile_key
  if not active then
    out("no active profile (unchanged)")
    return 0
  end
  local hit
  for _, p in ipairs(ws._profiles or {}) do
    if p.key == active then hit = p; break end
  end
  if hit then
    hit:deactivate()
  else
    ws._active_profile = nil
    ws._active_profile_key = nil
    ws:_save_user()
  end
  out("active profile cleared (was " .. active .. ")")
  return 0
end

--- `lw profile select [<profile> | --none]` — set (or clear) the active profile
--- in the working copy (user.json). A named profile is resolved like every other
--- profile operand (number, exact key, unique boundary substring) and needs no
--- terminal, so scripts can drive it; `--none` clears the selection. Only the
--- no-argument picker is interactive. Selecting the profile that is already
--- active reports `(unchanged)` and writes nothing.
--- @param ws table
--- @param args string[]|nil full argv ({ "profile", "select", … })
function M.select_profile(ws, args)
  local name, none
  for i = 3, #(args or {}) do
    local a = args[i]
    if a == "--none" then
      none = true
    elseif a:sub(1, 1) == "-" then
      die("unknown option '" .. a .. "' — usage: lw profile select [<profile> | --none]")
    elseif name then
      die("unexpected argument '" .. a .. "' — usage: lw profile select [<profile> | --none]")
    else
      name = a
    end
  end
  if none and name then
    die("`--none` clears the active profile; it takes no profile name")
  end
  if none then return clear_active_profile(ws) end
  local profiles = ws._profiles or {}
  if name then
    local p = resolve_profile(ws, name)
    if ws._active_profile_key == p.key then
      out("active profile: " .. p.key .. " (unchanged)")
      return 0
    end
    p:activate()
    out("active profile: " .. p.key)
    return 0
  end
  if #profiles == 0 then die("no profiles to select — run `lw profile list`") end
  if not interactive() then
    local keys = {}
    for _, p in ipairs(profiles) do keys[#keys + 1] = p.key end
    table.sort(keys)
    die("`lw profile select` without a profile is an interactive picker.\n" ..
      "  name the profile (a unique substring works): lw profile select <profile>\n" ..
      "  or clear the selection: lw profile select --none\n" ..
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
  M._apply_create_description(profile, "profile '" .. profile.key .. "'")

  out((existed and "profile already exists: " or "created profile: ") .. profile.key ..
    "  [" .. profile._intent .. "]" .. (activate and "  (active)" or ""))
  local ok, reasons = true, nil
  if profile.is_valid then ok, reasons = profile:is_valid() end
  if not ok then out("  not yet buildable: " .. table.concat(reasons or {}, "; ")) end
  -- Next step (spec §16.38): build it — by name unless it is now the active
  -- profile — and how to make it the default. Omitted while unbuildable.
  if ok then
    if activate then
      out("  build it:          lw build")
    else
      out("  build it:          lw build " .. profile.key)
      out("  make it default:   lw profile select " .. profile.key)
    end
  end
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

-- A launchable-target candidate's short kind label for display.
local function target_kind_label(kind) return kind == "target" and "exe" or "launch" end

--- Does a launchable-target candidate `c` match a profile's stored default-target
--- descriptor? Matches by (project, target-id) for build targets and
--- (project, name) for command launch configs.
local function candidate_is_default(desc, c)
  if not desc or desc.project ~= c.project.key then return false end
  if desc.target then return c.kind == "target" and c.target_id == desc.target end
  if desc.launch then return c.kind == "launch" and c.name == desc.launch end
  return false
end

--- Gather a profile's launchable targets for display (read-only; never builds).
--- Returns `rows` (each { label, kind_label, is_default, cand?, suffix? }, the
--- default first if it isn't otherwise enumerable), `unconfigured` (project keys
--- that could contribute build targets once configured), and `incomplete`.
--- @return { rows: table[], unconfigured: string[], incomplete: boolean }
local function collect_targets(ws, profile)
  local cands = launchable_targets(ws, profile)
  local desc = profile._default_target_descriptor
  local rows, seen_default = {}, false
  for _, c in ipairs(cands) do
    local is_default = candidate_is_default(desc, c)
    if is_default then seen_default = true end
    local lcfg = c.kind == "launch" and c.project.launch and c.project.launch[c.name]
    rows[#rows + 1] = {
      label = c.project.key .. ":" .. c.name,
      kind_label = target_kind_label(c.kind),
      is_default = is_default,
      cand = c,
      -- A launch's description summary ends its row (spec §16.35).
      description = type(lcfg) == "table" and type(lcfg.description) == "string"
        and lcfg.description or nil,
    }
  end
  -- The default points at a target we couldn't enumerate (e.g. an unconfigured
  -- build target). Show it anyway from the descriptor so it is never hidden.
  if desc and desc.project and not seen_default and (desc.target or desc.launch) then
    table.insert(rows, 1, {
      label = desc.project .. ":" .. (desc.target or desc.launch),
      kind_label = desc.target and "exe" or "launch",
      is_default = true,
      suffix = "  (unresolved — build to confirm)",
    })
  end
  -- Projects that could contribute build targets but aren't configured yet, so
  -- the caller can say the list is incomplete (spec §16.18).
  local unconfigured = {}
  for _, pp in ipairs(profile:projects()) do
    local unit = pp._config_unit
    local project = unit and unit._project
    local mod = project and project._module and project._module.impl
    if mod and mod.parse_targets then
      local st = unit:local_state()
      if st ~= "configured" and st ~= "built" then unconfigured[#unconfigured + 1] = project.key end
    end
  end
  table.sort(unconfigured)
  return { rows = rows, unconfigured = unconfigured, incomplete = #unconfigured > 0 }
end

--- Resolve a profile for the READ-ONLY target listing. Unlike resolve_profile,
--- it may fall back to the active profile even in a non-interactive host (the
--- listing neither builds nor writes, so the CI-determinism guard does not
--- apply — spec §16.18). Named → that profile; else active; else the sole one.
local function resolve_profile_for_listing(ws, name)
  if name then return resolve_profile(ws, name) end
  local profiles = ws._profiles or {}
  if #profiles == 0 then die("no profiles yet — `lw profile create <set> <tool>`") end
  local active = ws._active_profile_key
  if active then
    for _, p in ipairs(profiles) do if p.key == active then return p end end
  end
  if #profiles == 1 then return profiles[1] end
  die("no active profile — name one (`lw target <profile>`) or `lw profile select`")
end

--- `lw target [list] [profile]` — print a profile's launchable targets, default
--- marked `*`, with a note when the list is incomplete (a project not yet
--- configured). Read-only.
local function print_target_list(ws, profile)
  local info = collect_targets(ws, profile)
  out("targets — profile '" .. profile.key .. "':")
  if #info.rows == 0 then
    out("  (none" .. (info.incomplete and " yet)" or ")"))
  else
    local lw_ = 0
    for _, r in ipairs(info.rows) do
      lw_ = math.max(lw_, require("loomworks.description").width(r.label .. " (" .. r.kind_label .. ")"))
    end
    for _, r in ipairs(info.rows) do
      local cell = r.label .. " (" .. r.kind_label .. ")"
      local line = string.format("  %s %s", r.is_default and "*" or " ", cell)
      if r.description then
        line = line .. string.rep(" ", lw_ - require("loomworks.description").width(cell))
      end
      out(line .. (r.suffix or "")
        .. M._summary_suffix(require("loomworks.description").width(line), r.description))
    end
  end
  if info.incomplete then
    out("  build targets for " .. table.concat(info.unconfigured, ", ") ..
      " appear after `lw build`.")
  end
  return 0
end

--- `lw target set [<profile>] <target>` — set a profile's default launch target
--- (what a bare `lw run` executes). One operand is the target on the active
--- profile (non-interactive requires the explicit <profile>, spec §16.9); two
--- operands name the profile. Resolves the target the same way `lw run` does.
local function target_set(root, args)
  -- args: { "target", "set", <positionals & flags…> }
  local pos, scope, kind, working_dir = {}, nil, nil, nil
  local i = 3
  while args[i] do
    if args[i] == "--project" then scope = args[i + 1]; i = i + 2
    elseif args[i] == "--target" then kind = "target"; i = i + 1
    elseif args[i] == "--launch" then kind = "launch"; i = i + 1
    elseif args[i] == "--cwd" or args[i] == "--working-dir" then working_dir = args[i + 1]; i = i + 2
    else pos[#pos + 1] = args[i]; i = i + 1 end
  end
  local profile_name, target_name
  if #pos >= 2 then profile_name, target_name = pos[1], pos[2]
  elseif #pos == 1 then target_name = pos[1]
  else die("usage: lw target set [<profile>] <target>") end

  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, profile_name, -- nil → active (interactive) / dies in CI
    { usage = "lw target set <profile> <target>" })

  -- Resolve <target> to a candidate (the same matcher as `lw run`).
  local matches, all = match_targets(ws, profile, target_name, scope, kind)
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

--- `lw target clear [profile]` — clear a profile's default target.
local function target_clear(root, args)
  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, args[3], -- nil → active (interactive) / dies in CI
    { usage = "lw target clear <profile>" })
  profile:clear_default_target()
  out("cleared default target for profile '" .. profile.key .. "'")
  return 0
end

--- `lw target [list] [profile]` | `lw target set [<profile>] <target>` |
--- `lw target clear [profile]` — list a profile's launchable targets (default
--- marked `*`), or set/clear its default target. Bare `lw target` lists the
--- active profile's targets. `set`/`clear` are reserved sub-keywords; list a
--- profile literally named `set`/`clear`/`unset` with `lw target list <name>`.
--- `unset` is an alias of `clear`.
function M.cmd_target(root, args)
  local sub = args[2]
  if sub == "set" then return target_set(root, args) end
  if sub == "clear" or sub == "unset" then return target_clear(root, args) end
  local name = (sub == "list") and args[3] or sub
  local ws = load_workspace(root, false)
  local profile = resolve_profile_for_listing(ws, name)
  return print_target_list(ws, profile)
end

M._collect_targets = collect_targets
M._resolve_profile_for_listing = resolve_profile_for_listing

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

--- The installations provider `id` detects on this host — its `detect_all()`,
--- the same enumeration the editor's SDKs section offers. Entries without a
--- usable path are dropped; a raising provider yields none plus the error.
--- @param id string provider id
--- @return { path: string, version?: string }[]|nil installs, string|nil err
local function detect_sdk_installations(id)
  local registry = require("loomworks.sdks")
  local p = registry.get(id)
  if not p then return nil, "unknown SDK type" end
  if type(p.detect_all) ~= "function" then return {} end
  local ok, res = pcall(p.detect_all)
  if not ok then return {}, tostring(res) end
  local list = {}
  for _, inst in ipairs(type(res) == "table" and res or {}) do
    if type(inst) == "table" and type(inst.path) == "string" and inst.path ~= "" then
      list[#list + 1] = inst
    end
  end
  return list
end

--- A provider's display name (falls back to its id).
local function sdk_display_name(id)
  local p = require("loomworks.sdks").get(id)
  return (p and type(p.display_name) == "string" and p.display_name) or id
end

--- `lw sdk detect [<type>]` — list the installations every provider (or one)
--- detects on this host. Read-only: no workspace needed, nothing declared.
local function cmd_sdk_detect(ids, sdk_type)
  if sdk_type then
    if not require("loomworks.sdks").get(sdk_type) then
      die("unknown SDK type '" .. sdk_type .. "' — types: " ..
        (next(ids) and table.concat(ids, ", ") or "(none)"))
    end
    ids = { sdk_type }
  end
  if #ids == 0 then out("(no SDK providers available)"); return 0 end
  for _, id in ipairs(ids) do
    local installs, err = detect_sdk_installations(id)
    if err then
      out(string.format("  %-14s (detection failed: %s)", id, err))
    elseif #installs == 0 then
      out(string.format("  %-14s (none detected)", id))
    else
      for _, inst in ipairs(installs) do
        out(string.format("  %-14s %-12s %s", id, tostring(inst.version or "?"), inst.path))
      end
    end
  end
  return 0
end

--- Choose the installation `lw sdk add <type>` (no path) declares: the
--- provider's detected installations minus those already declared. None →
--- error naming the explicit form; one → it; several → a picker, or (non-
--- interactive) an error listing each candidate as the explicit command.
--- @return string path
local function pick_detected_sdk(ws, sdk_type)
  local installs, err = detect_sdk_installations(sdk_type)
  local explicit = "lw sdk add " .. sdk_type .. " <path>"
  if not installs then
    die("unknown SDK type '" .. sdk_type .. "' — `lw sdk types` lists them")
  end
  if #installs == 0 then
    die("no " .. sdk_type .. " installation detected" ..
      (err and (" (detection failed: " .. err .. ")") or "") ..
      " — pass a path: " .. explicit)
  end
  local declared = {}
  for _, s in ipairs(ws._sdks or {}) do
    local sp = s.sdk_path and s:sdk_path() or s._path
    if sp then declared[norm_cmp(sp)] = s.key end
  end
  local fresh, taken = {}, {}
  for _, inst in ipairs(installs) do
    local key = declared[norm_cmp(inst.path)]
    if key then taken[#taken + 1] = key .. " (" .. inst.path .. ")"
    else fresh[#fresh + 1] = inst end
  end
  if #fresh == 0 then
    die("every detected " .. sdk_type .. " installation is already declared: " ..
      table.concat(taken, ", ") .. " — `lw sdk list` shows them; declare another with " .. explicit)
  end
  if #fresh == 1 then
    out("detected " .. fresh[1].path)
    return fresh[1].path
  end
  if not interactive() then
    local lines = {}
    for _, inst in ipairs(fresh) do
      lines[#lines + 1] = "  lw sdk add " .. sdk_type .. " " .. inst.path ..
        (inst.version and ("   (" .. tostring(inst.version) .. ")") or "")
    end
    die(#fresh .. " " .. sdk_type .. " installations detected — pass one explicitly:\n" ..
      table.concat(lines, "\n"))
  end
  local display = sdk_display_name(sdk_type)
  out("Several " .. sdk_type .. " installations detected — select one:")
  for i, inst in ipairs(fresh) do
    out(string.format("  %d) %s%s  %s", i, display,
      inst.version and (" " .. tostring(inst.version)) or "", inst.path))
  end
  out("")
  local line = prompt_line("Enter number (blank to cancel)")
  if not line or line == "" then out("cancelled"); finish(0) end
  local n = tonumber(line)
  if not n or not fresh[n] then die("invalid selection: " .. tostring(line)) end
  return fresh[n].path
end

--- `lw sdk <types|detect|list|add|remove>` — declare toolchain installations
--- that auto-detection cannot find (a compiler at an arbitrary path, a
--- cross-compiler), or that a provider detects but nothing declares yet (a
--- platform SDK). A declared SDK produces a kit, so it shows up in `lw tools`
--- and can be pinned by `lw profile create`.
function M.cmd_sdk(sub, root, args)
  local ids = sdk_provider_ids()

  if sub == "detect" then
    return cmd_sdk_detect(ids, args[3])
  end

  if sub == "types" then
    if #ids == 0 then out("(no SDK providers available)"); return 0 end
    for _, id in ipairs(ids) do out("  " .. id) end
    return 0
  end

  if sub == nil or sub == "list" then
    local ws = load_workspace(root, false)
    local sdks = ws._sdks or {}
    if #sdks == 0 then
      out("(no SDKs declared — `lw sdk detect`, then `lw sdk add <type> [<path>]`)")
      return 0
    end
    for _, sdk in ipairs(sdks) do
      out(string.format("  %-42s %s", sdk.key, sdk._path or "?"))
    end
    return 0
  end

  if sub == "add" or sub == "create" then
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
    if not sdk_type or (force and not path) then
      die("usage: lw sdk add <type> [<path>] [--force [--family <f>] [--version <v>]]\n" ..
        "  (--force needs a <path>; without a <path> the type's detected installation is used)\n" ..
        "  types: " .. (next(ids) and table.concat(ids, ", ") or "(none)"))
    end
    local ws = load_workspace(root, false)
    -- No path: declare the installation the provider detects (§10.1).
    if not path then path = pick_detected_sdk(ws, sdk_type) end
    local abs = resolve_abs(path, user_cwd()) or resolve_abs_out(path, user_cwd())
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

  die("unknown sdk subcommand '" .. tostring(sub) .. "' — use types|detect|list|add|remove")
end

--- `lw profile remove <profile>` — drop a profile from the working copy.
--- Removes user intent only; build directories are left alone (`lw reset
--- --all` / the editor's delete plan handle them).
function M.cmd_profile_remove(root, args)
  local name = args[3]
  if not name then die("usage: lw profile remove <profile>") end
  local ws = load_workspace(root, false)
  local profile = resolve_profile(ws, name)
  local key = profile.key
  local shared = item_reaches_shared(ws, "profiles", profile)
  local ok, err = ws:remove_profile(profile)
  if not ok then die("could not remove profile: " .. tostring(err)) end
  out("removed profile '" .. key .. "'")
  -- `lw clean` cannot name a removed profile; `reset --all` also covers build
  -- dirs no profile references any more (spec §16.30, §16.38).
  out("  build directories were left in place. `lw reset --all` deletes them along")
  out("  with every other profile's builds (`lw reset <profile>` first is narrower).")
  publish_hint(shared)
  return 0
end

--- The `cache` field of `lw profile query`: the resolved compiler cache for
--- this (profile, project) (§16.18) — the same value as the `Cache` row, e.g.
--- `sccache`, `off`, `auto (none found)`, `auto (off for MSVC-style)`,
--- `ccache (not found)`, `not applied (preset)`. Empty for a project whose
--- module does not cache C/C++ (like `tool` with no toolchain). Never spawns
--- the cache tool.
--- @param profile loomworks.Profile
--- @param pp loomworks.ProfileProject
--- @return string
function M._profile_query_cache(profile, pp)
  local status = profile:compiler_cache_status(pp)
  return status and (status.text:gsub("^Cache: ", "")) or ""
end

--- `lw profile query <profile> <project> <field>` — print a single machine-
--- readable fact about a project within a resolved profile. Read-only
--- introspection for scripting (e.g. locating CI artifacts). Fields:
--- build-dir | config | state | tool | cache | variables | variables.<name>.
function M.cmd_profile_query(root, args)
  -- args: { "profile", "query", <profile>, <project>, <field> }
  local profile_name, project_key, field = args[3], args[4], args[5]
  if not (profile_name and project_key and field) then
    die("usage: lw profile query <profile> <project> <field>\n" ..
      "  fields: build-dir | config | state | tool | cache | variables | variables.<name>")
  end
  -- `cache` probes the host: asked of the runtime (§19.14) on a session kept open.
  local ws = read_workspace(root, false, { keep = field == "cache" })
  -- Deterministic machine path: resolve by key only, never a positional number
  -- (numbers are an interactive convenience that shifts on profile add/remove).
  local profile = resolve_profile(ws, profile_name, { no_number = true })

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

  -- Resolve the project's user-declared variables for this profile, with the
  -- active tool's compiler-family overrides applied (core §1.3.1). Shared by
  -- the `variables` (all) and `variables.<name>` (single) fields.
  local function resolved_variables()
    local project = pp._project
    if not project or not project.variables or not next(project.variables) then
      return {}
    end
    local tool = pp:tool_object()
    local family = require("loomworks.cpp_compilers")
      .family_from_tool_data(tool and tool.data or nil)
    -- Thread the queried profile so blank variables (§1.3.1) resolve to their
    -- fill value; still-blank ones report as empty via `entry.value or ""`.
    return require("loomworks.variables").resolve(project, pp:configuration(), family, profile)
  end

  local value
  if field == "build-dir" then
    value = pp:build_dir()
    if not value or value == "" then
      die("build dir not resolved for '" .. project_key .. "' in '" .. profile.key ..
        "' — the profile is incomplete or unbuildable (`lw profile list`).")
    end
    value = value:gsub("\\", "/")
  elseif field == "config" then
    value = pp:variant_name()
  elseif field == "state" then
    value = pp:status()
  elseif field == "tool" then
    local t = pp:tool_object()
    value = t and t.key or ""
  elseif field == "cache" then
    local q = ws._projection and M._read_query("profile_cache", { profile = profile.key, project = project_key })
    if q then
      value = type(q.cache) == "table"
        and (require("loomworks.profile").compiler_cache_text(q.cache):gsub("^Cache: ", "")) or ""
    else
      value = M._profile_query_cache(profile, pp)
    end
  elseif field == "variables" then
    -- Deterministic, machine-parseable: sorted `name=value` lines.
    local resolved = resolved_variables()
    local names = {}
    for name in pairs(resolved) do names[#names + 1] = name end
    table.sort(names)
    local lines = {}
    for _, name in ipairs(names) do
      lines[#lines + 1] = name .. "=" .. (resolved[name].value or "")
    end
    out(table.concat(lines, "\n"))
    return 0
  else
    local var_name = field:match("^variables%.(.+)$")
    if var_name then
      local resolved = resolved_variables()
      local entry = resolved[var_name]
      if not entry then
        die("project '" .. project_key .. "' declares no variable '" .. var_name .. "'")
      end
      value = entry.value or ""
    else
      die("unknown field '" .. field
        .. "' — use build-dir | config | state | tool | cache | variables | variables.<name>")
    end
  end
  out(value or "")
  return 0
end

--- Resolve the profile for a `lw profile set/unset`: a named profile is matched
--- with the same boundary-anchored selector as builds; an omitted name falls
--- back to the active profile (a management write, so the active-profile
--- default is allowed even in a non-interactive host, §16.9/§16.18).
--- @param ws table
--- @param name string|nil
--- @return table profile
local function resolve_profile_for_set(ws, name)
  if name then return resolve_profile(ws, name) end
  local active = ws._active_profile_key
  if active then
    for _, p in ipairs(ws._profiles or {}) do
      if p.key == active then return p end
    end
  end
  die("no profile specified and no active profile — name one " ..
    "(`lw profile set <profile> <project> <variable> <value>`) " ..
    "or select one with `lw profile select`.")
end
M._resolve_profile_for_set = resolve_profile_for_set

--- Whether `name` is a variable a profile may fill for `proj`: a declared
--- project variable, or a core pre-declared policy name (`cache`, core §1.3.2)
--- which is profile-fillable without any declaration.
--- @param proj loomworks.Project
--- @param name string
--- @return boolean
local function profile_fillable(proj, name)
  if proj.variables and proj.variables[name] then return true end
  return require("loomworks.variables").PREDECLARED_NAMES[name] == true
end

--- `lw profile set [<profile>] <project> <variable> <value>` — set this
--- profile's machine-local fill value for a blank project variable (§1.3.1).
--- Profile defaults to the active one. Written to user.json only; never
--- published to loomworks.json.
function M.cmd_profile_set(root, args)
  -- args: { "profile", "set", [profile], project, variable, value }
  local rest = {}
  for i = 3, #args do rest[#rest + 1] = args[i] end
  local profile_name, project_key, var_name, value
  if #rest == 4 then
    profile_name, project_key, var_name, value = rest[1], rest[2], rest[3], rest[4]
  elseif #rest == 3 then
    project_key, var_name, value = rest[1], rest[2], rest[3]
  else
    die("usage: lw profile set [<profile>] <project> <variable> <value>\n" ..
      "  sets this profile's machine-local value for a blank project variable\n" ..
      "  (or the pre-declared `cache` policy, e.g. `lw profile set App cache sccache`)\n" ..
      "  (profile defaults to the active one; written to user.json only)")
  end
  local ws = load_workspace(root, false)
  local profile = resolve_profile_for_set(ws, profile_name)
  local proj = resolve_project(ws, project_key)
  if not profile_fillable(proj, var_name) then
    local declared = {}
    for n in pairs(proj.variables or {}) do declared[#declared + 1] = n end
    table.sort(declared)
    die("project '" .. proj.key .. "' declares no variable '" .. var_name ..
      "'. Declared: " .. (next(declared) and table.concat(declared, ", ") or "(none)"))
  end
  local current = profile:variable_value(proj.key, var_name)
  if var_name == "cache" then
    local cc = require("loomworks.compiler_cache")
    local ok, err = cc.validate_policy(value)
    if not ok then die(err) end
    -- Stored (and compared) canonically: `SCCACHE` → `sccache`, `none` → `off`.
    value = cc.canonical_policy(value)
    current = cc.canonical_policy(current)
  end
  -- Same idempotence as `lw config set`: a value already set changes nothing,
  -- so say so and leave user.json untouched.
  if value ~= "" and current == value then
    out(string.format("%s: %s/%s = %s (unchanged)", profile.key, proj.key, var_name, value))
    return 0
  end
  profile:set_variable_value(proj.key, var_name, value)
  out(string.format("%s: set %s/%s = %s", profile.key, proj.key, var_name, value))
  return 0
end

--- `lw profile unset [<profile>] <project> <variable>` — clear a profile's
--- fill value for a project variable. Mirrors `lw profile set`.
function M.cmd_profile_unset(root, args)
  -- args: { "profile", "unset", [profile], project, variable }
  local rest = {}
  for i = 3, #args do rest[#rest + 1] = args[i] end
  local profile_name, project_key, var_name
  if #rest == 3 then
    profile_name, project_key, var_name = rest[1], rest[2], rest[3]
  elseif #rest == 2 then
    project_key, var_name = rest[1], rest[2]
  else
    die("usage: lw profile unset [<profile>] <project> <variable>\n" ..
      "  clears this profile's machine-local value for a project variable\n" ..
      "  (profile defaults to the active one)")
  end
  local ws = load_workspace(root, false)
  local profile = resolve_profile_for_set(ws, profile_name)
  local proj = resolve_project(ws, project_key)
  if not profile_fillable(proj, var_name) then
    die("project '" .. proj.key .. "' declares no variable '" .. var_name .. "'")
  end
  if profile:variable_value(proj.key, var_name) == nil then
    -- Idempotent (exit 0), like `lw config unset` of a never-set param.
    out(string.format("%s: %s/%s is not set (nothing to unset)", profile.key, proj.key, var_name))
    return 0
  end
  profile:clear_variable_value(proj.key, var_name)
  out(string.format("%s: unset %s/%s", profile.key, proj.key, var_name))
  return 0
end

function M.cmd_profile(sub, root, args)
  if sub == "select" then
    return M.select_profile(load_workspace(root, false), args)
  end
  if sub == "set" then
    return M.cmd_profile_set(root, args)
  end
  if sub == "unset" then
    return M.cmd_profile_unset(root, args)
  end
  if sub == "create" or sub == "add" then
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
  if sub == "describe" then
    return M.cmd_describe("profile", root, args)
  end
  if sub == "show" then
    return M.cmd_profile_show(root, args[3])
  end
  if sub == nil or sub == "list" then
    return M.cmd_profiles(load_workspace(root))
  end
  die("unknown profile subcommand '" .. tostring(sub) ..
    "' — use list|show|select|create|remove|publish|query|set|unset|describe (target moved to `lw target`)")
end

--- The value a settings key falls back to when unset, so `lw settings get` can
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
  if key == "channel" then
    -- Precedence mirrors boot.update.resolve_channel (env > config > default).
    return os.getenv("LOOMWORKS_CHANNEL") or "stable"
  end
  if key == "runtime-mode" then
    -- Precedence mirrors loomworks.daemon.runtime.resolve (env > config > default).
    local rt = require("loomworks.daemon.runtime")
    local v = os.getenv(rt.ENV)
    return (rt.is_valid(v) and v) or rt.DEFAULT
  end
  if key == "daemon-idle-timeout" then return "1h" end
  if key == "runtime-busy-wait" then return "5s" end
  return nil
end

--- `lw settings <list|get|set|unset> [key] [value]` — lw's OWN user settings.
function M.cmd_settings(sub, key, value)
  local cfg = read_config()
  if sub == nil or sub == "list" then
    out("settings file: " .. config_path())
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
    if not key then die("usage: lw settings get <key>") end
    if cfg[key] ~= nil then out(tostring(cfg[key])); return 0 end
    -- Unset keys still have an effective value; print it so a setting like the
    -- release URL is discoverable from the CLI instead of reading the source.
    local eff = effective_config_default(key)
    out(eff and ("(unset — using default: " .. eff .. ")") or "(unset)")
    return 0
  elseif sub == "set" then
    if not key or value == nil then die("usage: lw settings set <key> <value>") end
    -- Validate constrained keys up front so a typo is caught here, not silently
    -- at the next self-update (the channel is re-validated by the host too).
    if key == "channel" and value ~= "stable" and value ~= "unstable" then
      die("invalid channel '" .. value .. "' — use 'stable' or 'unstable'")
    end
    if key == "release-notes" and value ~= "on" and value ~= "off" then
      die("invalid value '" .. value .. "' for release-notes — use 'on' or 'off'")
    end
    if key == "runtime-mode" and not require("loomworks.daemon.runtime").is_valid(value) then
      die("invalid runtime-mode '" .. value .. "' — use 'in-process' or 'daemon'")
    end
    if key == "daemon-idle-timeout" and not require("loomworks.daemon.runtime").parse_duration(value) then
      die("invalid daemon-idle-timeout '" .. value .. "' — use seconds, or a number with s, m or h (30m, 1h)")
    end
    if key == "runtime-busy-wait" and not require("loomworks.daemon.runtime").parse_busy_wait(value) then
      die("invalid runtime-busy-wait '" .. value .. "' — use 0, seconds, or a number with ms, s or m (500ms, 5s)")
    end
    -- Path-like values use forward slashes so the bootstrap can read them raw.
    cfg[key] = (key == "dev-lua") and value:gsub("\\", "/") or value
    local ok, err = write_config(cfg)
    if not ok then die("failed to write config: " .. tostring(err)) end
    out(string.format("set %s = %s", key, tostring(cfg[key])))
    return 0
  elseif sub == "unset" then
    if not key then die("usage: lw settings unset <key>") end
    cfg[key] = nil
    local ok, err = write_config(cfg)
    if not ok then die("failed to write config: " .. tostring(err)) end
    out("unset " .. key)
    return 0
  end
  die("unknown settings subcommand '" .. tostring(sub) .. "' — use list|get|set|unset")
end

-- Command tokens are cyan on a real terminal; the rest of the status palette is
-- bold titles, dim secondary prose (counts, help, "+N more"), green for the
-- active profile. ANSI would corrupt captured / piped / redirected output, so
-- it is emitted only to a stdout tty (see status_palette / stdout_supports_color).
-- The palette emits `term.sgr` MARKERS, not raw escapes: out/note render them
-- into real SGR sequences while escaping any control characters that arrive
-- with data (loomworks.term).
local ANSI_CMD, ANSI_RESET = term.sgr("36"), term.sgr("0")
local ANSI_TITLE, ANSI_DIM, ANSI_ACTIVE = term.sgr("1"), term.sgr("2"), term.sgr("32")
-- Diagnostic severities: red for errors, yellow for warnings. Same tty-only
-- gating as the rest of the palette — plain on a pipe/redirect.
local ANSI_ERR, ANSI_WARN = term.sgr("31"), term.sgr("33")
-- The editor highlight groups the CLI mirrors (a profile's build state,
-- `Profile:status()` / STATUS_HL, spec §16.18), mapped to the terminal colors
-- with the same meaning — the one place a highlight group becomes ANSI. Info is
-- blue, not cyan: cyan is the CLI's command-token color.
local ANSI_BY_HL = {
  Comment = ANSI_DIM,
  DiagnosticInfo = term.sgr("34"),
  DiagnosticOk = ANSI_ACTIVE,
  DiagnosticWarn = ANSI_WARN,
  DiagnosticError = ANSI_ERR,
}

--- A named set of painters for `lw status`. When `color` is false every field
--- is the identity function, so the exact same rendering code produces plain
--- text on a pipe/redirect (every test) and colored text on a real terminal.
--- `.cmd` matches the hint block's cyan so command tokens read the same across
--- the whole CLI.
local function status_palette(color)
  local function mk(seq)
    if not color then return function(s) return s end end
    return function(s) return seq .. s .. ANSI_RESET end
  end
  return {
    title = mk(ANSI_TITLE),
    dim = mk(ANSI_DIM),
    active = mk(ANSI_ACTIVE),
    cmd = mk(ANSI_CMD),
    -- A command mentioned inline in prose: dim on a terminal (it is secondary
    -- guidance, not data), backticked on a pipe/redirect so it stays visually
    -- delimited without color (matching the footer's `lw help` style).
    inline = color and mk(ANSI_DIM) or function(s) return "`" .. s .. "`" end,
    err = mk(ANSI_ERR),
    warn = mk(ANSI_WARN),
    -- Paint `s` in the color of editor highlight group `group` (ANSI_BY_HL);
    -- plain for an unmapped group or with color off.
    hl = function(group, s)
      local seq = color and ANSI_BY_HL[group]
      if not seq then return s end
      return seq .. s .. ANSI_RESET
    end,
  }
end

--- Paint a status help line — secondary guidance ("<prose> · <lw command>" or a
--- bare command hint). Dimmed whole on a terminal so it recedes behind the data;
--- plain on a pipe/redirect. `pal` is a status_palette().
local function paint_help(pal, help)
  return pal.dim(help)
end

M._status_palette = status_palette
M._paint_help = paint_help

--- Print a capped section: a blank line, "Title (N)" (title bold, count dim),
--- up to `max` rows via `row_fn`, then a "+K more · <more_hint>" line when the
--- list was truncated, a blank separator, and one or more short `help` lines
--- (how to act — doubles as the empty-state hint, like the active-profile line
--- shows with no profiles). `help` is a single string or a list of them, each on
--- its own line. The blank line before them keeps them from blending into the
--- entries. `pal` is a status_palette(); with color off it renders plain.
local function status_section(pal, title, items, max, row_fn, more_hint, help)
  local help_lines = type(help) == "table" and help or { help }
  out("")
  out(pal.title(title) .. " " .. pal.dim("(" .. #items .. ")"))
  if #items == 0 then
    for _, h in ipairs(help_lines) do out("  " .. paint_help(pal, h)) end
    return
  end
  local shown = math.min(#items, max)
  for i = 1, shown do out(row_fn(items[i])) end
  if #items > shown then
    out("  " .. pal.dim("+" .. (#items - shown) .. " more · " .. more_hint))
  end
  out("")
  for _, h in ipairs(help_lines) do out("  " .. paint_help(pal, h)) end
end

M._status_section = status_section

--- Group workspace diagnostics (from `Workspace:diagnostics()`) for inline
--- rendering. Returns `{ by_key = <target_fold_key → {diag,…}>, by_project =
--- <project key → {diag,…}> }`. Entries with a nil `target_fold_key` are
--- workspace-level and skipped (they show only in the top section). `by_project`
--- is filled from `config:<proj>:<name>` keys so a configuration's diagnostic
--- attaches to its project's row; the leading project segment can't contain a
--- `:` (config names can, so match only up to the FIRST one after the key).
--- A `profile_proj:<profile>:<project>` key (a per-project tool-compatibility
--- error) is routed into the SAME `profile:<profile>` bucket the Profiles row
--- reads, so it renders inline under its profile alongside that profile's own
--- diagnostics — the profile key can't contain a `:`, so match up to the first.
local function group_diagnostics(diags)
  local by_key, by_project = {}, {}
  local function bucket(key, d)
    local g = by_key[key]; if not g then g = {}; by_key[key] = g end
    g[#g + 1] = d
  end
  for _, d in ipairs(diags) do
    local k = d.target_fold_key
    if k then
      bucket(k, d)
      local proj = k:match("^config:([^:]+):")
      if proj then
        local p = by_project[proj]; if not p then p = {}; by_project[proj] = p end
        p[#p + 1] = d
      end
      local prof = k:match("^profile_proj:([^:]+):")
      if prof then bucket("profile:" .. prof, d) end
    end
  end
  return { by_key = by_key, by_project = by_project }
end
M._group_diagnostics = group_diagnostics

--- An inline marker block for a list of diagnostics, appended to a section row:
--- a newline-prefixed, indented "✗ "/"⚠ " + message line per entry (message
--- only — the row already names the item, and the source is redundant inline).
--- "" when the list is nil/empty. `out()` writes the embedded newlines as
--- separate lines. `pal` is a status_palette(); plain when color is off.
local function inline_markers(pal, list)
  if not list or #list == 0 then return "" end
  local parts = {}
  for _, d in ipairs(list) do
    local marker = d.severity == "error" and pal.err("✗ ") or pal.warn("⚠ ")
    parts[#parts + 1] = "\n    " .. marker .. (d.message or "")
  end
  return table.concat(parts)
end
M._inline_markers = inline_markers

--- The top "Diagnostics" section for `lw status`. Emits NOTHING when the list
--- is empty (no all-clear line). Otherwise: a leading blank line, a bold
--- "Diagnostics (N)" header followed by a dim "X error(s), Y warning(s)"
--- breakdown (a zero count is omitted), a blank line, then one indented line per
--- diagnostic ("✗ "/"⚠ " + dim "[source] " + message). Draws from the same
--- `Workspace:diagnostics()` the editor's Diagnostics section uses. `pal` is a
--- status_palette(); plain on a pipe/redirect.
local function render_diagnostics(pal, diags)
  if #diags == 0 then return end
  local errs, warns = 0, 0
  for _, d in ipairs(diags) do
    if d.severity == "error" then errs = errs + 1 else warns = warns + 1 end
  end
  local parts = {}
  if errs > 0 then parts[#parts + 1] = errs .. (errs == 1 and " error" or " errors") end
  if warns > 0 then parts[#parts + 1] = warns .. (warns == 1 and " warning" or " warnings") end
  out("")
  out(pal.title("Diagnostics") .. " " .. pal.dim("(" .. #diags .. ")")
    .. "  " .. pal.dim(table.concat(parts, ", ")))
  out("")
  for _, d in ipairs(diags) do
    local marker = d.severity == "error" and pal.err("✗ ") or pal.warn("⚠ ")
    out("  " .. marker .. pal.dim("[" .. (d.source or "?") .. "] ") .. (d.message or ""))
  end
end
M._render_diagnostics = render_diagnostics

--- The exit code for `lw status`: 1 when `--check` was passed AND at least one
--- diagnostic is present (for CI), else 0. Without `--check`, always 0 — the
--- overview neither builds nor manages state (§16.9).
local function check_exit_code(check, diags)
  if check and #diags > 0 then return 1 end
  return 0
end
M._check_exit_code = check_exit_code

--- The git argv prefix every lw git call uses (spec §17.8): repository-local
--- configuration must not be able to run commands on lw's behalf, so the
--- file-system monitor hook and the hooks directory are disabled on every
--- invocation (`git` itself is resolved to an absolute path by exe.system).
--- @return string[]
local function git_base_cmd()
  return { "git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=" }
end
M._git_base_cmd = git_base_cmd

--- Best-effort, time-bounded git query for the no-workspace status hint. Never
--- throws and never hangs status: a missing binary, non-zero exit, or a git
--- that runs long past the timeout all return nil. Returns trimmed stdout only
--- on a clean (code 0) run. A timeout additionally returns `"timeout"` as the
--- second value, so callers can tell a SLOW git from an absent one (a missing
--- binary or a failed run returns a bare nil). `cwd` nil runs git unanchored
--- (for `--version`).
local GIT_HINT_TIMEOUT_MS = 1500
local function git_query(cwd, args, timeout_ms)
  local cmd = git_base_cmd()
  if cwd then cmd[#cmd + 1] = "-C"; cmd[#cmd + 1] = cwd end
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local done, res = false, nil
  local ok, proc = pcall(require("loomworks.exe").system, cmd, { text = true }, function(r)
    res = r; done = true
  end)
  if not ok or not proc then return nil end
  vim.wait(timeout_ms or GIT_HINT_TIMEOUT_MS, function() return done end, 20)
  if not done then
    pcall(function() proc:kill(9) end)
    if proc.pid then pcall(uv.kill, proc.pid, 9) end
    return nil, "timeout"
  end
  if not res or res.code ~= 0 then return nil end
  return ((res.stdout or ""):gsub("%s+$", ""))
end

-- Budget for the read-only probes of the git-REQUIRED commands (`lw worktree`,
-- `lw worktree add`, `lw pull`). Those commands cannot degrade: a probe that
-- times out is reported as "git is not available" / "not in a git repository",
-- or silently resolves the wrong checkout. The status hint's 1.5 s budget is
-- right for a convenience line but routinely too short for a real answer on a
-- loaded machine, so these use a generous one (30 s) — still bounded, never a
-- hang. git_query with that budget; same `(cwd, args) -> stdout|nil[, "timeout"]`
-- contract, so it is interchangeable with an injected test runner. (Module
-- fields, not locals: this chunk is at Lua's 200-local limit.)
M.GIT_REQUIRED_TIMEOUT_MS = 30000
function M._git_query_required(cwd, args)
  return git_query(cwd, args, M.GIT_REQUIRED_TIMEOUT_MS)
end

--- The one-line note for a best-effort probe that ran past the status hint's
--- budget: a slow git is not an absent git, so say it timed out (and which
--- command does the full, longer-budget check) instead of "git unavailable".
--- @param what string what could not be checked
--- @param cmd string the git-required command that checks with the longer budget
function M._git_timeout_note(what, cmd)
  return string.format("(git timed out after %g s — couldn't check %s; `%s` waits longer)",
    GIT_HINT_TIMEOUT_MS / 1000, what, cmd)
end

-- Timeout for the one MUTATING git call the CLI makes (`git worktree add`, via
-- `lw worktree add`). It checks out a tree, so it is slower than git_query's
-- read-only probes and needs a longer budget.
local GIT_MUTATE_TIMEOUT_MS = 60000

--- Like git_query but for a MUTATING git command whose stderr the user must see
--- on failure. Returns the raw vim.system result `{ code, stdout, stderr }`, or
--- nil when the process could not be spawned or timed out. (git_query collapses
--- failure to nil and discards stderr — fine for read-only probes, but a create
--- must surface git's own message.)
--- @param cwd string|nil
--- @param args string[]
--- @param timeout_ms? number
--- @return table|nil result
local function git_exec(cwd, args, timeout_ms)
  local cmd = git_base_cmd()
  if cwd then cmd[#cmd + 1] = "-C"; cmd[#cmd + 1] = cwd end
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local done, res = false, nil
  local ok, proc = pcall(require("loomworks.exe").system, cmd, { text = true }, function(r)
    res = r; done = true
  end)
  if not ok or not proc then return nil end
  vim.wait(timeout_ms or GIT_MUTATE_TIMEOUT_MS, function() return done end, 20)
  if not done then
    pcall(function() proc:kill(9) end)
    if proc.pid then pcall(uv.kill, proc.pid, 9) end
    return nil
  end
  return res
end

--- Parse `git worktree list --porcelain` into a record per worktree, in order
--- (the first is the main worktree). Each record has `path`, and optionally
--- `head`, `branch` (short — `refs/heads/` stripped), `detached`, `bare`,
--- `locked`, `prunable`. Records are separated by blank lines.
local function parse_worktrees(text)
  local records, cur = {}, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      if cur then records[#records + 1] = cur; cur = nil end
    else
      local key, rest = line:match("^(%S+)%s*(.*)$")
      cur = cur or {}
      if key == "worktree" then cur.path = rest
      elseif key == "HEAD" then cur.head = rest
      elseif key == "branch" then cur.branch = (rest:gsub("^refs/heads/", ""))
      elseif key == "detached" then cur.detached = true
      elseif key == "bare" then cur.bare = true
      elseif key == "locked" then cur.locked = true
      elseif key == "prunable" then cur.prunable = true
      end
    end
  end
  if cur then records[#records + 1] = cur end
  return records
end

--- Whether checkout `root` carries a workspace — the published snapshot OR the
--- working copy. The same presence test the status hint and `lw worktree` use.
local function stat_has_workspace(stat, root)
  return stat(root .. "/loomworks.json")
      or stat(root .. "/.nvim/loomworks.user.json")
end

--- All worktrees of the git worktree containing `opts.dir`, from
--- `git worktree list --porcelain`. Read-only, time-bounded, never throws.
--- Returns `(records, top, reason)`: `records` is the ordered list (first =
--- main), `top` the current worktree's toplevel; both nil when there is no
--- answer, with `reason` one of "git-missing" | "git-timeout" | "not-git" |
--- "no-list" | "no-main" for the caller to phrase. "git-timeout" means ANY
--- probe ran past the runner's budget — a slow git, never read as absent git or
--- as "not a repo". `opts.git`/`opts.dir` inject for tests.
function M._worktree_list(opts)
  opts = opts or {}
  local git = opts.git or git_query
  local dir = opts.dir or user_cwd()
  -- Probe git itself first: its absence and "not a repo" both fail the queries
  -- below, but only the former is distinguishable as a real "no git" note.
  local ver, verr = git(nil, { "--version" })
  if verr == "timeout" then return nil, nil, "git-timeout" end
  if not ver then return nil, nil, "git-missing" end
  local top, terr = git(dir, { "rev-parse", "--show-toplevel" })
  if terr == "timeout" then return nil, nil, "git-timeout" end
  if not top or top == "" then return nil, nil, "not-git" end
  local list, lerr = git(dir, { "worktree", "list", "--porcelain" })
  if lerr == "timeout" then return nil, nil, "git-timeout" end
  if not list then return nil, nil, "no-list" end
  local records = parse_worktrees(list)
  if #records == 0 or not records[1].path then return nil, nil, "no-main" end
  return records, top, nil
end

--- The **main worktree** of the git worktree containing `opts.dir` (the first
--- `git worktree list --porcelain` entry). Read-only, time-bounded, never
--- throws. Returns `(main, top, reason)`: `main` is the main worktree's path
--- and `top` the current worktree's toplevel; both nil when there is no answer,
--- with `reason` as for `_worktree_list`. When `main == top` the caller is
--- already in the main worktree. `opts.git`/`opts.dir` are injectable for tests.
function M._main_worktree(opts)
  local records, top, reason = M._worktree_list(opts)
  if not records then return nil, nil, reason end
  return records[1].path, top, nil
end

-- On Windows a console only renders ANSI once virtual-terminal processing is
-- on. Enable it once via LuaJIT FFI (kernel32) — available on both hosts (nvim
-- and the luvi luajit shim). Memoized, Windows-only, and every step is
-- pcall-guarded: no ffi, a redirected stdout, or a denied syscall all yield
-- false and we stay plain. Never touches kernel32 off Windows.
local _win_vt_memo -- nil = undecided, then true/false
local function windows_vt_enabled()
  if _win_vt_memo ~= nil then return _win_vt_memo end
  local enabled = false
  pcall(function()
    local ffi = require("ffi")
    if ffi.os ~= "Windows" then return end
    ffi.cdef([[
      void* GetStdHandle(unsigned long nStdHandle);
      int GetConsoleMode(void* hConsoleHandle, unsigned long* lpMode);
      int SetConsoleMode(void* hConsoleHandle, unsigned long dwMode);
    ]])
    local STD_OUTPUT_HANDLE = 0xFFFFFFF5 -- (DWORD)-11
    local ENABLE_VT = 0x0004 -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
    local h = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
    local mode = ffi.new("unsigned long[1]")
    if ffi.C.GetConsoleMode(h, mode) == 0 then return end -- redirected / not a console
    if ffi.C.SetConsoleMode(h, bit.bor(tonumber(mode[0]), ENABLE_VT)) == 0 then return end
    enabled = true
  end)
  _win_vt_memo = enabled
  return _win_vt_memo
end

--- Whether to color stdout: NO_COLOR (the convention) unset AND stdout is a
--- real terminal AND, on Windows, VT processing could be turned on. The tty
--- gate runs before the Windows probe, so a piped / redirected / captured run
--- (every test) returns false without ever touching the FFI path.
local function stdout_supports_color()
  if os.getenv("NO_COLOR") then return false end
  local ok, h = pcall(uv.guess_handle, 1)
  if not ok or h ~= "tty" then return false end
  if is_windows() then return windows_vt_enabled() end
  return true
end
M._stdout_supports_color = stdout_supports_color

--- The stderr counterpart of `stdout_supports_color` (same NO_COLOR / tty /
--- Windows-VT gates, probed on fd 2) — for the dim one-line notes `lw` writes
--- to stderr, e.g. the daemon-delegation line (spec §19.15).
--- @return boolean
function M._stderr_supports_color()
  if os.getenv("NO_COLOR") then return false end
  local ok, h = pcall(uv.guess_handle, 2)
  if not ok or h ~= "tty" then return false end
  if not is_windows() then return true end
  windows_vt_enabled() -- declares the console functions (and enables stdout)
  local enabled = false
  pcall(function()
    local ffi = require("ffi")
    local hh = ffi.C.GetStdHandle(0xFFFFFFF4) -- (DWORD)-12, STD_ERROR_HANDLE
    local mode = ffi.new("unsigned long[1]")
    if ffi.C.GetConsoleMode(hh, mode) == 0 then return end
    if ffi.C.SetConsoleMode(hh, bit.bor(tonumber(mode[0]), 0x0004)) == 0 then return end
    enabled = true
  end)
  return enabled
end

--- Best-effort width of the output terminal, in columns. A real stdout tty is
--- measured via libuv (`new_tty` + `get_winsize`); a redirected / piped /
--- captured run (every test) falls back to `$COLUMNS`, then a sensible default
--- of 100. Never errors; always returns a positive integer. `opts.guess` /
--- `opts.new_tty` are injectable seams so tests can exercise the tty path (and
--- the non-tty fallback) without a real terminal.
local function term_width(opts)
  opts = opts or {}
  local guess = opts.guess or uv.guess_handle
  local new_tty = opts.new_tty or uv.new_tty
  local ok, kind = pcall(guess, 1)
  if ok and kind == "tty" then
    local w
    pcall(function()
      local tty = new_tty(1, false)
      if tty then
        w = tty:get_winsize() -- returns width, height
        pcall(function() tty:close() end)
      end
    end)
    if type(w) == "number" and w > 0 then return math.floor(w) end
  end
  local env = tonumber(os.getenv("COLUMNS"))
  if env and env > 0 then return math.floor(env) end
  return 100
end
M._term_width = term_width

--- Fit a content-sized column to the terminal: the field is never wider than its
--- longest entry (`longest`), never wider than what the terminal leaves after the
--- row's fixed parts (`tw - reserved`), and never narrower than `min`. Returns the
--- width to use in a paired `%-<w>s` field / `trunc(value, w)`. Pure; exported for
--- tests. When `longest <= (tw - reserved)` the entry fits and is shown in full
--- (no over-padding to a hardcoded width); otherwise the column is capped so the
--- row stays on one line and `trunc` adds the ellipsis.
local function fit_column(longest, tw, reserved, min)
  local budget = math.max(min, tw - reserved)
  return math.max(min, math.min(longest, budget))
end
M._fit_column = fit_column

-- Fixed, non-name characters on a Profiles row: "* " (mark + space) plus a few
-- columns of slack for the inline diagnostic markers (those actually render on
-- their own lines, so the slack is just breathing room). The number and state
-- columns are added per call; the name column gets whatever the terminal leaves.
local PROFILE_RESERVED = 2 + 4

--- Build the formatted rows for the Profiles section, sizing the profile-name
--- column to its content and capping it to `tw` columns. Raw text is formatted
--- first, then painted (ANSI escapes never enter a width measurement). Exported
--- for tests; `cmd_status` renders exactly these rows. Returns the row-string
--- array and the name column width it chose.
--- @param pal table status_palette()
--- @param plist table Profile-like objects ({ key, status? })
--- @param active_key string|nil
--- @param grouped table group_diagnostics() result
--- @param tw integer terminal width in columns
--- @param numbers table<string, integer> profile.key → stable number (profile_numbering)
local function status_profile_rows(pal, plist, active_key, grouped, tw, numbers)
  numbers = numbers or {}
  local longest, num_w, state_w = 0, 1, 0
  -- Build state (§16.18): the editor's aggregate `Profile:status()` label and
  -- highlight group, shown verbatim in parentheses after the name. No set
  -- column: a profile key is always `<set>[:<tools>]` (Profile:_derive_key), so
  -- the name already shows the set.
  local states = {}
  local dwidth = require("loomworks.description").width
  for _, p in ipairs(plist) do
    longest = math.max(longest, #tostring(p.key))
    num_w = math.max(num_w, #tostring(numbers[p.key] or ""))
    local ok, label, hl = pcall(function()
      if p.status then return p:status() end
    end)
    if ok and type(label) == "string" and label ~= "" then
      states[p] = { text = "(" .. label .. ")", hl = hl }
      state_w = math.max(state_w, 1 + dwidth(states[p].text))
    end
  end
  -- The number and state columns widen the fixed overhead; take them off the
  -- name budget.
  local name_w = fit_column(longest, tw, PROFILE_RESERVED + num_w + state_w, 8)
  -- "<mark><n> <name> (<state>)" — the stable number is a label here, so it
  -- keeps its value even though the section lists the active profile first.
  -- The name is padded only when a state follows it.
  local rows = {}
  for _, p in ipairs(plist) do
    local is_active = (p.key == active_key)
    local st = states[p]
    local name = trunc(p.key, name_w)
    if st then name = name .. string.rep(" ", name_w - dwidth(name)) end
    local head = string.format("%s%" .. num_w .. "s %s", is_active and "*" or " ",
      tostring(numbers[p.key] or ""), name)
    local plain = st and (head .. " " .. st.text) or head
    local row = (is_active and pal.active(head) or head)
      .. (st and (" " .. pal.hl(st.hl, st.text)) or "")
    rows[#rows + 1] = row
      .. M._summary_suffix(dwidth(plain), p.description, tw, pal)
      .. inline_markers(pal, grouped.by_key["profile:" .. p.key])
  end
  return rows, name_w
end
M._status_profile_rows = status_profile_rows

--- Return a token painter: wraps a command in cyan when `color`, else identity.
local function painter(color)
  if not color then return function(s) return s end end
  return function(s) return ANSI_CMD .. s .. ANSI_RESET end
end

-- Visible width of the command field so descriptions line up in a column.
local HINT_CMD_FIELD = 13
local function hint_cmd_line(paint, cmd, desc)
  local pad = string.rep(" ", math.max(2, HINT_CMD_FIELD - #cmd))
  return "  " .. paint(cmd) .. pad .. desc
end

--- The no-workspace status block. When we sit in a linked git worktree whose
--- main checkout holds a workspace, it offers `lw pull` (fold that config in)
--- alongside `lw init`; otherwise only `lw init`. Read-only and non-fatal —
--- git is best-effort. Command tokens are colored only on a real terminal.
--- `opts.git`/`opts.stat`/`opts.dir` are injectable for tests; `opts.color`
--- overrides tty detection.
function M._worktree_hint(opts)
  opts = opts or {}
  local stat = opts.stat or uv.fs_stat
  local color = opts.color
  if color == nil then color = stdout_supports_color() end
  local paint = painter(color)
  local main, top, reason = M._main_worktree(opts)

  -- A linked worktree: main resolved cleanly and distinct from this checkout.
  if main and reason == nil and norm_cmp(main) ~= norm_cmp(top) then
    local has_ws = stat_has_workspace(stat, main)
    if has_ws then
      return {
        "loomworks — no workspace here (git worktree).",
        "main checkout " .. main .. " has a workspace:",
        "",
        hint_cmd_line(paint, "lw pull", "copy its config into this worktree"),
        hint_cmd_line(paint, "lw init", "start a fresh workspace here instead"),
      }
    end
    return {
      "loomworks — no workspace here (git worktree).",
      "",
      hint_cmd_line(paint, "lw init", "start a workspace here"),
    }
  end

  -- Not a linked worktree: a plain repo, the main checkout, or not a repo.
  local lines = {
    "loomworks — no workspace here.",
    "",
    hint_cmd_line(paint, "lw init", "start a workspace here"),
  }
  if reason == "git-missing" then
    lines[#lines + 1] = "(git unavailable — couldn't check for a parent worktree)"
  elseif reason == "git-timeout" then
    lines[#lines + 1] = M._git_timeout_note("for a parent worktree", "lw worktree")
  end
  return lines
end

--- Can `lw pull` fill this workspace's empty profile list (headless §16.18)?
--- True when we sit in a linked git worktree whose main checkout holds a
--- working copy (`.nvim/loomworks.user.json`). Presence only — the main
--- checkout's files are never read here (pull verifies them). Best-effort and
--- time-bounded like the no-workspace hint; never throws. Returns
--- `(bool, reason)`: `reason` is "git-timeout" when the probe ran past its
--- budget (the answer is unknown, not "no"), else nil. `opts.git` /
--- `opts.stat` / `opts.dir` are injectable for tests.
function M._main_has_working_copy(opts)
  opts = opts or {}
  local stat = opts.stat or uv.fs_stat
  local ok, res, why = pcall(function()
    local main, top, reason = M._main_worktree(opts)
    if reason == "git-timeout" then return false, reason end
    if not main or reason ~= nil or norm_cmp(main) == norm_cmp(top) then return false end
    return stat(main .. "/.nvim/loomworks.user.json") and true or false
  end)
  return ok and res == true, ok and why or nil
end

--- The fixed command footer of the status overview (headless §16.18, §16.38):
--- the everyday commands, then the pointer to the full index. ≤ 80 columns.
--- Command names stay at normal brightness on a terminal; the rest is dim.
--- No backticks on a pipe — the line must fit 80 columns plain.
M.STATUS_COMMON = { "build", "run", "test", "clean", "reset", "health", "pull",
  "worktree add", "publish" }
function M._status_footer(pal)
  local names = {}
  for i, n in ipairs(M.STATUS_COMMON) do names[i] = n end
  return {
    pal.dim("Common: ") .. table.concat(names, pal.dim(", ")),
    pal.inline("lw help") .. pal.dim(" for every command · ") ..
      pal.inline("lw help <command>") .. pal.dim(" for details."),
  }
end

--- Query a compiler cache tool's own usage statistics (headless §16.18,
--- `--cache-stats`). This spawns the tool, so it is only called under the
--- explicit flag. `run` is injectable for tests. Returns the (trimmed,
--- non-empty) output lines, or a one-line diagnostic note.
--- @param tool string launcher name ("ccache" | "sccache")
--- @param path string resolved executable path
--- @param run? fun(cmd: string[]): string runner (default vim.fn.system)
--- @return string[]
function M._cache_stats(tool, path, run)
  run = run or function(cmd) return vim.fn.system(cmd) end
  local args = (tool == "sccache") and { path, "--show-stats" } or { path, "-s" }
  local ok, outp = pcall(run, args)
  if not ok or type(outp) ~= "string" or outp == "" then
    return { "(could not read " .. tool .. " statistics)" }
  end
  local lines = {}
  for line in (outp .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then lines[#lines + 1] = (line:gsub("%s+$", "")) end
  end
  if #lines == 0 then return { "(no statistics reported)" } end
  return lines
end

--- Render the active profile's compiler-cache line (headless §16.18) — the
--- resolved launcher, or that caching is off/unavailable, mirroring the
--- editor's `Cache:` row. Under `--cache-stats` it also folds in the tool's own
--- usage statistics (spawning the tool). `auto (off for MSVC-style)` points at
--- `lw help cache` (how to opt in). Never lets a broken query break status.
--- @param pal table status_palette()
--- @param profile loomworks.Profile active profile
--- @param cache_stats boolean whether to fold in usage statistics
local function render_cache_line(pal, profile, cache_stats)
  local ok_c, cache = pcall(function() return profile:compiler_cache_status() end)
  if not ok_c or not cache then
    -- Asked for statistics but this profile has no C/C++ project: say so
    -- rather than printing nothing.
    if cache_stats then
      out(pal.title("Cache") .. string.rep(" ", 12)
        .. pal.dim("(no C/C++ project in the active profile — no compiler cache)"))
    end
    return
  end
  local value = (cache.text:gsub("^Cache: ", ""))
  local line = pal.title("Cache") .. string.rep(" ", 12) .. value
  if cache.msvc_auto_off and cache.policy == "auto" and cache.applicable ~= false then
    line = line .. pal.dim(" — lw help cache")
  end
  if cache.stale then line = line .. pal.warn(" [stale — reconfigure]") end
  out(line)
  if cache_stats then
    if cache.present and cache.path then
      for _, l in ipairs(M._cache_stats(cache.tool, cache.path)) do
        out("  " .. pal.dim(l))
      end
    else
      out("  " .. pal.dim("(no cache resolved — nothing to query)"))
    end
  end
end

--- `lw status` (also bare `lw`) — one-screen workspace overview. Works outside
--- a workspace too. Every section is capped to keep it to a single page.
--- `opts.check` (from `lw status --check`) makes the invocation exit non-zero
--- when any diagnostic is present, or when no workspace resolves here, for CI;
--- it never changes the rendering.
--- `opts.submodule` (the submodule dir the root search crossed, spec §1.1)
--- adds a one-line note that the workspace came from the superproject.
--- The `Trust` row of `lw status` (spec §17.10): whether the working copy is
--- present (a refused one never reaches the page) and how many program
--- settings in loomworks.json are ignored. A workspace's NAME can read
--- "untrusted" (it is its directory's); this row is the trust state.
--- @param ws table workspace
--- @param root string
--- @return string
function M._trust_row(ws, root)
  local present = uv.fs_stat(require("loomworks.user").filepath(root)) ~= nil
  local row = present and "local config signed on this machine (its program settings are used)"
    or "no local config (only a local config may name programs)"
  local ok, ignored = pcall(function() return ws:ignored_program_settings() end)
  local n = ok and type(ignored) == "table" and #ignored or 0
  if n > 0 then
    row = row .. string.format(" · %d program setting%s in loomworks.json ignored", n, n == 1 and "" or "s")
  end
  return row .. " — lw help trust"
end

--- The `Runtime` row of `lw status` (spec §19.6), computed from the runtime
--- lock and handle files only (nil only if that fails).
--- @param root string
--- @return string|nil
function M._runtime_row(root)
  local ok, row = pcall(function()
    local rt = require("loomworks.daemon.runtime")
    local mode = rt.resolve(read_config()[rt.SETTING])
    local inspect = require("loomworks.daemon.inspect")
    return inspect.row(inspect.state(root), mode, require("loomworks.daemon.version").identity())
  end)
  return ok and row or nil
end

--- Workspace commands that never start or contact the daemon (besides the
--- ones dispatched before the workspace guard: status, health, pull, worktree,
--- settings, help, daemon …).
M.NO_DAEMON_COMMANDS = { trust = true, nuke = true, unlock = true }

--- The read-only sub-commands of each command (spec §19.1, §19.14; `lw
--- status` is dispatched before the guard): they read a live compatible
--- daemon's projection or in-process (`read_workspace`), so their ensure step
--- never launches a daemon. `false` = the bare command (its list form).
M.READ_ONLY_SUBS = {
  project = { [false] = true, list = true, show = true },
  config = { [false] = true, list = true, show = true, get = true },
  configset = { [false] = true, list = true, show = true },
  profile = { show = true, query = true },
  launch = { [false] = true, list = true, show = true },
}
M.READ_ONLY_ALIAS = {
  configuration = "config", cfg = "config", ["configuration-set"] = "configset", cs = "configset",
}
--- The commands with a `describe` sub-command read by `cmd_describe`, and its
--- item operand count.
M.DESCRIBE_OPS = { project = 1, config = 2, configset = 1, profile = 1 }

--- Is argv `args` a read-only command (spec §19.1, §19.14): `lw tools`,
--- `profile show` / `query`, `project` / `config` / `configset` / `launch`
--- list and show, `config get`, and the read form of `describe` (no
--- description source, `--clear` or `--edit`; only `--json`)? Like the
--- NO_DAEMON_COMMANDS its ensure step is skipped: it never launches, stops or
--- restarts a daemon. Commands that write keep the ensure step.
--- @param args string[]
--- @return boolean
function M._read_only_command(args)
  local command = args[1]
  if command == "tools" then return true end
  command = M.READ_ONLY_ALIAS[command] or command
  local subs = M.READ_ONLY_SUBS[command]
  if not subs then return false end
  local sub = args[2]
  if sub == nil then return subs[false] == true end
  if subs[sub] then return true end
  if sub == "describe" and M.DESCRIBE_OPS[command] then
    for i = 3 + M.DESCRIBE_OPS[command], #args do
      if args[i] ~= "--json" then return false end
    end
    return #args >= 2 + M.DESCRIBE_OPS[command]
  end
  return false
end

--- Workspace commands routed to the workspace daemon (spec §19.15): their
--- ensure step waits longer for a slow daemon (§19.10) before they run
--- in-process. `test`: its batch form (§19.19 step 5); `run`: its preparation
--- (§19.15 "Run"; the program runs here); `clean` (§19.15 "Clean", step 5c);
--- `reset` (§19.15 "Reset", step 5d).
M.ROUTED_COMMANDS = { build = true, test = true, run = true, clean = true, reset = true }

--- Would argv `args` be routed to the daemon, for the ensure step's bound
--- (§19.10)? A routed command, except `lw test --target` and a `lw run` with a
--- device option (they stay in-process, §19.15), which get the plain
--- non-routed ensure.
--- @param args string[]
--- @return boolean
function M._routed_command(args)
  local command = args[1]
  if not M.ROUTED_COMMANDS[command] then return false end
  if command == "test" and M._test_request(args) == "target" then return false end
  if command == "run" and M._run_request(args) == "device" then return false end
  return true
end

--- Keep the workspace daemon running before a workspace command (spec §19.1,
--- §19.10; loomworks.daemon.ensure). Never fails the command. Returns what
--- happened (loomworks.daemon.ensure.ensure's outcome; nil on an error).
--- `routed`: the command would be routed to the daemon (`lw build`), which
--- gives a live-but-slow daemon the longer bound (ensure.ROUTED_STEP_MS).
--- @param root string
--- @param routed? boolean
--- @return string|nil
function M._ensure_daemon(root, routed)
  local ok, outcome = pcall(function()
    return require("loomworks.daemon.ensure").ensure(root, {
      config = read_config(), flag = M._no_daemon, note = note, routed = routed == true,
      log = require("loomworks.daemon.rlog").writer(root),
      -- A repo that pins another lw: its daemon is the pinned lw's (§16.23).
      foreign_pin = rawget(_G, "__loomworks_foreign_pin"),
    })
  end)
  if not ok then
    -- Never silent (§19.15): the command runs without the daemon, and says so.
    note("lw: could not use the workspace daemon (" .. (tostring(outcome):match("[^\n]*")) .. "); running without it")
    return nil
  end
  return outcome
end

--- The one stderr line of a `lw build` / `lw test` the daemon does not run
--- although this command has one (spec §19.15): `lw: <what> (<reason>);
--- running without it`.
--- @param what string
--- @param reason string
--- @return string
function M._not_routed_line(what, reason)
  return "lw: " .. what .. " (" .. tostring(reason) .. "); running without it"
end

--- Why the workspace runtime `st` (loomworks.daemon.inspect) is not a daemon
--- this command can use, for `_not_routed_line`.
--- @param st table
--- @return string
function M._runtime_reason(st)
  local lk = st.lock or {}
  local pid = tostring(lk.pid or (st.handle or {}).pid or "?")
  if st.kind == "foreign" then return "it runs on " .. tostring(lk.host or "?") .. ", pid " .. pid end
  if st.kind == "attached" then
    return "the workspace runtime is held by " .. require("loomworks.daemon.rlock").holder_text(lk) .. ", pid " .. pid
  end
  if st.kind == "starting" then return "it is still starting, pid " .. pid end
  return "the workspace runtime: " .. require("loomworks.daemon.inspect").row(st, "daemon")
end

--- The one stderr line an operation routed to the daemon prints before its
--- output while the daemon is opt-in (spec §19.15): `lw: building through the
--- workspace daemon (pid <n>)` (`testing …` for `lw test`, `preparing the
--- run …` for `lw run`). Dim on a color-capable stderr.
--- @param pid integer|nil the daemon's pid
--- @param color? boolean override the stderr color probe (tests)
--- @param op? "build"|"test"|"run"|"clean"|"reset" (default "build")
--- @return string
function M._delegation_line(pid, color, op)
  local what = ({ test = "testing", run = "preparing the run", clean = "cleaning", reset = "resetting" })[op]
    or "building"
  local line = "lw: " .. what .. " through the workspace daemon"
  if type(pid) == "number" and pid > 0 then line = line .. " (pid " .. math.floor(pid) .. ")" end
  if color == nil then color = M._stderr_supports_color() end
  if color then return term.sgr("2") .. line .. term.sgr("0") end
  return line
end

--- The request a `lw build` argv routes as (spec §19.15): the same parse as
--- `cmd_build` — `{ profile?, targets, extra, force, reconfigure, verbose }` —
--- or nil when `cmd_build` would refuse the arguments (it then reports them).
--- @param args string[] argv, args[1] == "build"
--- @return table|nil
function M._build_request(args)
  local req = { targets = {}, extra = {}, force = false, reconfigure = false, verbose = false }
  local pre, seen_sep, i = {}, false, 2
  while i <= #args do
    local a = args[i]
    if not seen_sep and a == "--" then seen_sep = true
    elseif seen_sep then req.extra[#req.extra + 1] = a
    elseif a == "--force" then req.force = true
    elseif a == "--reconfigure" then req.reconfigure = true
    elseif a == "--verbose" or a == "-v" then req.verbose = true
    elseif a == "--target" or a:match("^%-%-target=") then
      local name = a:match("^%-%-target=(.*)$")
      if not name then i = i + 1; name = args[i] end
      if not name or name == "" or name == "--" or name:sub(1, 1) == "-" then return nil end
      req.targets[#req.targets + 1] = name
    else pre[#pre + 1] = a end
    i = i + 1
  end
  if pre[2] then return nil end
  req.profile = pre[1]
  return req
end

--- The request a `lw clean` argv routes as (spec §19.15 "Clean"): the same
--- parse as `cmd_clean` — `{ profile? }`, the first operand (`cmd_clean`
--- refuses no argument form; the profile resolution refuses, as in-process).
--- @param args string[] argv, args[1] == "clean"
--- @return table
function M._clean_request(args)
  return { profile = args[2] }
end

--- The request a `lw reset` argv routes as (spec §19.15 "Reset"): the same
--- parse as `cmd_reset` — `{ profile?, all, yes }` — or nil when `cmd_reset`
--- would refuse the arguments (an unknown flag, a second operand, `--all`
--- with a profile; it then reports them).
--- @param args string[] argv, args[1] == "reset"
--- @return table|nil
function M._reset_request(args)
  local req = { all = false, yes = false }
  for i = 2, #args do
    local a = args[i]
    if a == "--all" then req.all = true
    elseif a == "-y" or a == "--yes" then req.yes = true
    elseif a:sub(1, 1) == "-" then return nil
    elseif not req.profile then req.profile = a
    else return nil end
  end
  if req.all and req.profile then return nil end
  return req
end

--- A routed `lw reset` the workspace daemon asked to confirm (spec §19.15
--- "Reset", Confirmation): print its listing, ask as in-process, then send
--- the reset again with `yes` and the listed plan's token. When that second
--- request is not routed (the daemon stopped or was retired meanwhile), the
--- reset runs in-process with the user's answer, never asking again, and
--- refuses when its plan differs from the one shown — except after an
--- attached runtime lost its lock (`opts.lost()`, §19.2): nothing is reset,
--- exit 1.
--- @param root string
--- @param args string[]
--- @param req table the first request (`_reset_request`)
--- @param reply table the `confirm` reply { lines, plan, profile_key? }
--- @param ensured string|nil
--- @param opts table `_delegate`'s
--- @return integer exit code
function M._reset_confirm(root, args, req, reply, ensured, opts)
  local reset_plan = require("loomworks.reset_plan")
  local shown = { label = reset_plan.label_for((not req.all and type(reply.profile_key) == "string")
    and reply.profile_key or nil) }
  for _, line in ipairs(type(reply.lines) == "table" and reply.lines or {}) do out(tostring(line)) end
  if not interactive() then die(reset_plan.unconfirmed_message(shown)) end
  local answer = prompt_line(reset_plan.prompt(shown))
  answer = (answer or ""):lower()
  if answer ~= "y" and answer ~= "yes" then die(reset_plan.ABORTED) end
  -- An attached runtime whose lock was lost while the prompt waited (§19.2)
  -- has no authority left: nothing is reset, here or in-process.
  local function lost_exit()
    local why = opts and opts.lost and opts.lost()
    if why then return M._lost_runtime_exit("reset", why) end
  end
  local gone = lost_exit()
  if gone then return gone end
  local token = tostring(reply.plan or "")
  local second = vim.deepcopy(req)
  second.yes, second.plan = true, token
  local routed = M._delegate("reset", root, args, ensured, vim.tbl_extend("force", opts or {}, { req = second }))
  if routed then return routed end
  gone = lost_exit()
  if gone then return gone end
  -- An attached runtime ends before the in-process reset loads the workspace.
  if opts and opts.release then opts.release() end
  return M.cmd_reset(load_workspace(root), args, { plan = token })
end

--- The request a `lw test` argv routes as (spec §19.15): the same parse as
--- `cmd_test` — `{ profile?, junit?, extra }`, `junit` made absolute against
--- this process's working directory as `cmd_test` does. Returns "target" for
--- the named-executable form (`--target`, not carried in this step), or nil
--- when `cmd_test` would refuse the arguments or they carry a form the daemon
--- does not (device options without `--target`; `cmd_test` reports them).
--- @param args string[] argv, args[1] == "test"
--- @return table|"target"|nil
function M._test_request(args)
  local req = { extra = {} }
  local pre, seen_sep = {}, false
  for i = 2, #args do
    if not seen_sep and args[i] == "--" then seen_sep = true
    elseif seen_sep then req.extra[#req.extra + 1] = args[i]
    else pre[#pre + 1] = args[i] end
  end
  for _, a in ipairs(pre) do
    if a == "--target" then return "target" end
  end
  local i = 1
  while pre[i] do
    local a = pre[i]
    if a == "--junit" then
      if not pre[i + 1] then return nil end
      req.junit = resolve_abs_out(pre[i + 1], user_cwd())
      i = i + 2
    elseif a:sub(1, 1) == "-" or req.profile then
      return nil
    else
      req.profile = a
      i = i + 1
    end
  end
  return req
end

--- The request a `lw run` argv routes as (spec §19.15 "Run"): the same parse
--- as `cmd_run` (`_parse_run_args`) — `{ profile?, target?, project?, kind?,
--- cwd?, extra, no_build, quiet }` — and, second, what stays with this client
--- (the parsed run: wrapper, report format). "device" when a device option is
--- given (a device run stays in-process); nil when `cmd_run` would refuse the
--- arguments (it then reports them). `cwd` is sent as given: the launch
--- resolves it as in-process (variables expanded, relative to the workspace
--- root).
--- @param args string[] argv, args[1] == "run"
--- @return table|"device"|nil req, loomworks.cli.RunArgs|nil run
function M._run_request(args)
  local seen_sep = false
  for i = 2, #args do
    if args[i] == "--" then seen_sep = true end
    if not seen_sep and M.RUN_DEVICE_OPTIONS[args[i]] ~= nil then return "device" end
  end
  local ok, r = pcall(M._parse_run_args, args, function() error("refused", 0) end,
    function() return false end)
  if not ok or type(r) ~= "table" then return nil end
  local pos = r.positionals
  local req = {
    extra = r.extra_args, no_build = r.no_build, quiet = r.print_mode ~= nil,
    project = r.proj_scope, kind = r.kind, cwd = r.cwd_override,
    -- (Only whether a wrapper is given: it refuses a device target before
    -- any deploy, as in-process; the wrapper itself stays here.)
    prefix = (r.prefix_tokens and #r.prefix_tokens > 0) or nil,
  }
  -- The §16.17 operand grammar (`_run_selection`): one operand is a target.
  if #pos >= 2 then req.profile, req.target = pos[1], pos[2] else req.target = pos[1] end
  return req, r
end

--- Finish a `lw run` whose preparation the workspace daemon did (spec §19.15
--- "Run"): its `done` carries the resolved `launch`, executed (or reported)
--- here; or `device = true` — the target runs on a device, which stays in this
--- process: say so, then continue in-process from the deploy without building
--- again. Returns the exit code.
--- @param root string
--- @param req table the request sent (`_run_request`)
--- @param r loomworks.cli.RunArgs
--- @param done table { code, launch?, device?, profile_key? } (`profile_key`: the
--- `accepted` reply's)
--- @param attached? boolean an attached run (§19.1): no daemon line
--- @return integer
function M._finish_routed_run(root, req, r, done, attached)
  if done.device then
    local ws = load_workspace(root)
    -- The profile the daemon built (its `accepted` reply), never re-resolved:
    -- the active profile may have changed since.
    local profile
    for _, p in ipairs(ws._profiles or {}) do
      if p.key == done.profile_key then profile = p; break end
    end
    if not profile then
      die("profile '" .. tostring(done.profile_key) .. "' the workspace daemon built is gone — it was not run here")
    end
    local lt, serr = require("loomworks.run_prep").select(ws, profile, req.target, r.proj_scope, r.kind)
    if not lt then die(serr) end
    local f = M._foreign_of(lt)
    if not attached then
      note("lw: the workspace daemon could not take the run (" .. tostring(f and f.name or lt:display_name())
        .. " runs on a device in this process); continuing without it")
    end
    return M._run_launch_target(lt, ws, M._run_target_opts(r))
  end
  local l = done.launch
  if type(l) ~= "table" or type(l.cmd) ~= "string" then
    die("the workspace daemon returned no launch for the run — it was not run here")
  end
  local spec = { name = tostring(l.name or l.cmd), cmd = l.cmd, cwd = type(l.cwd) == "string" and l.cwd or nil,
    args = {}, env = nil }
  for _, a in ipairs(type(l.args) == "table" and l.args or {}) do spec.args[#spec.args + 1] = tostring(a) end
  if type(l.env) == "table" and next(l.env) then
    spec.env = {}
    for k, v in pairs(l.env) do spec.env[tostring(k)] = tostring(v) end
  end
  return M._run_resolved(spec, M._run_target_opts(r), spec.cwd or root)
end

--- Would this machine refuse the workspace's working copy or cache (§17.4)?
--- Such a workspace is never routed (§19.15): the in-process path reports the
--- refusal with its remedies.
--- @param root string
--- @return boolean
function M._daemon_workspace_trusted(root)
  local trust = require("loomworks.trust")
  local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
  end
  local utext = read(require("loomworks.user").filepath(root))
  if utext and trust.verify("user", utext) ~= "valid" then return false end
  local ctext = read(require("loomworks.cache").filepath(root))
  if ctext and trust.verify("cache", ctext) == "invalid" then return false end
  return true
end

--- Windows: make this process receive the console's Ctrl-C again. A process
--- started with Ctrl-C disabled — `start /b`, a new process group (as Git
--- Bash runs a native program it signals with `kill -INT`), or inherited from
--- a parent that ignores it — never sees the interrupt; in-process that did
--- not matter (the build's own processes in the console still get it and the
--- build stops), but a routed build's processes are the daemon's, so only
--- this client can cancel it. `SetConsoleCtrlHandler(NULL, FALSE)`; a no-op
--- elsewhere, without the FFI, or when Ctrl-C was not disabled. Returns
--- whether it changed the state — only then `_restore_console_ctrl_c` puts it
--- back, before a routed run's program starts (it inherits this process's
--- state, as in-process). The prior state is the process parameters'
--- `CONSOLE_IGNORE_CTRL_C` flag (bit 0 of `ConsoleFlags`, which
--- `SetConsoleCtrlHandler(NULL, …)` maintains); when it cannot be read,
--- nothing is changed.
--- @return boolean
function M._enable_console_ctrl_c()
  if package.config:sub(1, 1) ~= "\\" then return false end
  local ok, res = pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "int SetConsoleCtrlHandler(void *handler, int add);")
    pcall(ffi.cdef, "void *RtlGetCurrentPeb(void);")
    local peb = ffi.cast("uint8_t *", ffi.load("ntdll").RtlGetCurrentPeb())
    local x64 = ffi.abi("64bit")
    local params = ffi.cast("uint8_t **", peb + (x64 and 0x20 or 0x10))[0]
    if params == nil then return false end
    local flags = ffi.cast("uint32_t *", params + (x64 and 0x18 or 0x14))[0]
    if require("bit").band(flags, 1) == 0 then return false end
    return ffi.C.SetConsoleCtrlHandler(nil, 0) ~= 0
  end)
  return ok and res == true
end

--- Undo `_enable_console_ctrl_c` (it returned true): Ctrl-C disabled again,
--- as this process was started.
function M._restore_console_ctrl_c()
  pcall(function()
    local ffi = require("ffi")
    pcall(ffi.cdef, "int SetConsoleCtrlHandler(void *handler, int add);")
    ffi.C.SetConsoleCtrlHandler(nil, 1)
  end)
end

--- Route `lw build` to the workspace daemon (spec §19.15, §19.19 step 3):
--- `_delegate("build", …)`.
--- @param root string
--- @param args string[]
--- @param ensured string|nil
--- @param opts? table
--- @return integer|nil exit code
function M._delegate_build(root, args, ensured, opts)
  return M._delegate("build", root, args, ensured, opts)
end

--- Route `lw build`, the batch `lw test`, the preparation of `lw run` or `lw
--- clean` to the workspace daemon (spec §19.15, §19.19 steps 3, 5 and 5c). A routed run's
--- program then runs here, after the connection was closed
--- (`_finish_routed_run`).
--- Only when this command has a daemon (`ensured` is "used", "launched" or
--- "restarted" — runtime-mode daemon, not `--no-daemon` / CI, versions
--- matched) or runs attached (`opts.attached`, below), the arguments parse, `--break-locks` is not given (it stays
--- in-process), and the workspace is trusted. Returns nil to run in-process
--- (nothing was done), or the exit code once the daemon refused or ran the
--- build — an accepted build is NEVER re-run in-process. The daemon runs the
--- build in this process's environment (sent with the request).
--- `lw test --target` (the named-executable form) and a `lw run` with a
--- device option stay in-process with one line (§19.15).
--- `lw reset` (§19.15 "Reset") is asked in two requests: a `confirm` reply
--- is answered here (`_reset_confirm`), which sends the second one
--- (`opts.req`: the request to send instead of the one argv parses as).
--- @param op "build"|"test"|"run"|"clean"|"reset"
--- @param root string
--- @param args string[]
--- @param ensured string|nil
--- An attached run (`opts.attached`, spec §19.1 "Loopback", from
--- `_delegate_attached`) sends the same request to the server it started in
--- this process (`opts.session`): no daemon state, endpoint or
--- `--break-locks` checks, and none of the daemon's lines — a case it does
--- not take runs in-process silently, as before step 5e. `opts.release`
--- releases its runtime lock (a run's, before the program starts);
--- `opts.lost()` says why the runtime stopped by itself meanwhile (its lock
--- taken over, the root removed; false while it runs): from then on no path
--- falls back to in-process (§19.2).
--- @param opts? { session?: function, keepalive_ms?: integer, connect_ms?: integer, req?: table, attached?: boolean, release?: function, lost?: function }
--- @return integer|nil exit code
function M._delegate(op, root, args, ensured, opts)
  opts = opts or {}
  local attached = opts.attached == true
  local inspect = require("loomworks.daemon.inspect")
  local function could_not(reason)
    if not attached then note(M._not_routed_line("the workspace daemon could not take the " .. op, reason)) end
    return nil
  end
  -- An attached runtime that stopped by itself (its lock taken over, the
  -- root removed; §19.2, §19.11) ends the command.
  local function lost_lock()
    return M._lost_runtime_exit(op, opts.lost and opts.lost() or nil)
  end
  local function lost() return attached and opts.lost ~= nil and opts.lost() and true or false end
  -- Every outcome that does not route in daemon mode prints one line saying
  -- why (§19.15): ensure() printed it for a bypass, a newer daemon, a hung,
  -- starting or unstartable one; "off" is in-process mode or an explicit
  -- `--no-daemon` / LOOMWORKS_NO_DAEMON / CI.
  local have = ensured == "used" or ensured == "launched" or ensured == "restarted"
  if not attached and not have and ensured ~= "elsewhere" then return nil end
  -- An argument cmd_build / cmd_test refuses, and a workspace the machine
  -- refuses: the in-process path reports them (that is the line).
  local req, run_args
  if opts.req then req = opts.req
  else req, run_args = M._routed_request(op, args) end
  -- `--target` / a device option always says why in its own words, whatever
  -- the runtime is.
  if req == "target" then
    return could_not("--target runs test executables in this process")
  end
  if req == "device" then
    return could_not("device options run the program on a device in this process")
  end
  -- `lw run --print` / `--dry-run`: the whole task stream on stderr, so
  -- stdout carries only the report (§19.15 "Run").
  local quiet = op == "run" and req and req.quiet
  if not attached and ensured == "elsewhere" then return could_not(M._runtime_reason(inspect.state(root))) end
  -- (Attached, `--break-locks` runs here: its recovery is this process's.)
  if not attached and require("loomworks.lock_break").requested then
    return could_not("--break-locks runs the " .. op .. " in this process")
  end
  if not req or not M._daemon_workspace_trusted(root) then return nil end
  local client = require("loomworks.daemon.client")
  local endpoint
  if not attached then
    local st = inspect.state(root)
    if st.kind ~= "live" then return could_not(M._runtime_reason(st)) end
    local eok, ewhy = require("loomworks.daemon.endpoint").check(root, st.handle.endpoint)
    if not eok then return could_not(ewhy) end
    endpoint = st.handle.endpoint
  end
  local task_id, done, accepted, profile_key = nil, nil, false, nil
  local function on_message(m)
    if m.kind ~= "task" or m.task_id == nil or m.task_id ~= task_id then return end
    if m.phase == "line" then
      local text = tostring(m.text or "")
      if m.stream == "out" and not quiet then out(text); io.stdout:flush()
      elseif m.stream == "out" or m.stream == "note" then note(text)
      else errw(text) end
    elseif m.phase == "output" then
      -- A step's raw bytes, as the in-process child writes them to the
      -- inherited terminal: written to the file descriptor directly, never
      -- through the C runtime's text mode (which would turn the tool's CRLF
      -- into CR CR LF on Windows).
      M._raw_write((m.stream == "stderr" or quiet) and 2 or 1, tostring(m.text or ""))
    elseif m.phase == "done" then
      -- An interface method's task carries its task result (§19.20); a
      -- protocol-10 task the same fields on the frame itself.
      local res = type(m.result) == "table" and m.result or m
      done = { code = tonumber(res.exit_code) or 1, error = res.error, launch = res.launch,
        device = res.device == true, profile_key = profile_key }
    end
  end
  local session = opts.session or client.session
  local conn, cerr = session(endpoint, { timeout_ms = opts.connect_ms or 5000, on_message = on_message })
  if not conn then
    -- Never an in-process fallback once an attached runtime lost its lock.
    if lost() then return lost_lock() end
    if not attached then
      note("lw: could not reach the workspace daemon (" .. tostring(cerr) .. "); running without it")
    end
    return nil
  end
  -- Ctrl-C cancels the routed operation (§19.15): the interrupt handler runs the
  -- exit hooks — this one drops the connection first, which the daemon takes
  -- as the cancellation — and exits 130. The build's own processes are the
  -- daemon's, not in this console, so the interrupt must reach THIS process:
  -- on Windows it may have been started with Ctrl-C disabled.
  on_exit(function() pcall(conn.close, conn) end)
  local ctrl_c_enabled = M._enable_console_ctrl_c()
  local reply, rerr
  -- Over transport 11 the interface method (Build/1, Tests/1.run,
  -- Launch/1.prepare_run), else the protocol-10 request (daemon/calls.lua).
  local msg = { kind = op == "run" and "prepare_run" or op, args = req, interactive = interactive(),
    command = "lw " .. op, env = require("loomworks.daemon.envscope").capture() }
  require("loomworks.daemon.calls").request(conn, msg, function(r, e)
    reply, rerr = r, e
    if not r then return end
    -- Printed here, before any task event of it is dispatched (they can
    -- arrive in the same read).
    for _, n in ipairs(type(r.notes) == "table" and r.notes or {}) do errw(tostring(n) .. "\n") end
    if r.outcome == "accepted" then
      task_id, accepted = r.task_id, true
      profile_key = type(r.profile_key) == "string" and r.profile_key or nil
      -- No daemon is involved in an attached run (§19.1 rule c).
      if not attached then note(M._delegation_line(r.pid, nil, op)) end
    end
  end)
  -- No timeout: loading the workspace or a build takes as long as it takes
  -- (as in-process). The connection is kept alive with pings; Ctrl-C ends
  -- this process and the daemon cancels the build (§19.15).
  local keepalive = opts.keepalive_ms or tonumber(os.getenv("LW_TEST_DAEMON_KEEPALIVE_MS") or "")
    or require("loomworks.daemon.server").KEEPALIVE_MS
  local last_ping = uv.now()
  local function waiting(cond)
    while not cond() and not conn.closed do
      vim.wait(keepalive, function() return cond() or conn.closed end, 10)
      if not cond() and not conn.closed and uv.now() - last_ping >= keepalive then
        last_ping = uv.now()
        conn:request({ kind = "ping" }, function() end)
      end
    end
  end
  waiting(function() return reply ~= nil or rerr ~= nil end)
  if not reply then
    conn:close()
    if lost() then return lost_lock() end
    -- Nothing was accepted: run without it, as for a daemon that cannot be
    -- started (§19.10).
    return could_not(rerr or "connection lost")
  end
  if reply.outcome == "declined" then
    conn:close()
    -- (A stopping attached runtime declines: never in-process then.)
    if lost() then return lost_lock() end
    if not attached then
      note(M._not_routed_line("the workspace daemon declined the " .. op, reply.reason or "no reason given"))
    end
    return nil
  end
  if reply.outcome == "refused" then
    conn:close()
    -- (A reset with nothing to reset: the in-process stdout line, exit 0.)
    if reply.stream == "out" then
      if ctrl_c_enabled then M._restore_console_ctrl_c() end
      out(tostring(reply.message))
      return tonumber(reply.exit_code) or 0
    end
    die(tostring(reply.message), tonumber(reply.exit_code) or 1)
  end
  if reply.outcome == "confirm" and op == "reset" and not opts.req then
    conn:close()
    if ctrl_c_enabled then M._restore_console_ctrl_c() end
    return M._reset_confirm(root, args, req, reply, ensured, opts)
  end
  if not accepted then
    conn:close()
    if lost() then return lost_lock() end
    return could_not("unexpected reply")
  end
  waiting(function() return done ~= nil end)
  conn:close()
  -- Its runtime lock taken over mid-operation: the running task was
  -- cancelled (its steps killed) as on Ctrl-C (§19.2); the command ends.
  if lost() then
    if ctrl_c_enabled then M._restore_console_ctrl_c() end
    return lost_lock()
  end
  -- The routed operation ended: this process's Ctrl-C state as it started,
  -- before a run's program (or the in-process device run) inherits it.
  if ctrl_c_enabled then M._restore_console_ctrl_c() end
  if not done then
    if attached then return lost_lock() end
    errw("lw: lost the connection to the workspace daemon during the " .. op .. " — it was not re-run here\n")
    return 1
  end
  if done.error then die(tostring(done.error), done.code) end
  -- A run: the task (and every lock) ended; the program runs here, never the
  -- daemon's (§19.15 "Run").
  -- An attached run releases the runtime lock when its preparation ends,
  -- before the program runs (§19.1 rule a): the program is not the runtime's.
  if op == "run" and opts.release then opts.release() end
  if op == "run" and done.code == 0 then return M._finish_routed_run(root, req, run_args, done, attached) end
  return done.code
end

--- The exit of an attached run whose runtime stopped by itself (spec §19.2,
--- §19.11): one stderr line saying why, exit status 1. `why` is what
--- `_delegate_attached`'s `lost()` returns (the attached server's
--- `stop_reason`): loomworks.daemon.server LOST_LOCK, ROOT_REMOVED, or another
--- reason.
--- @param op string
--- @param why string|boolean|nil
--- @return integer
function M._lost_runtime_exit(op, why)
  local server_mod = require("loomworks.daemon.server")
  if why == server_mod.ROOT_REMOVED then
    errw("lw: the workspace root was removed during the " .. op .. " — stopped\n")
  elseif why == server_mod.LOST_LOCK or type(why) ~= "string" then
    errw("lw: the workspace runtime lock was taken over during the " .. op .. " — stopped\n")
  else
    errw("lw: the workspace runtime stopped during the " .. op .. " (" .. why .. ")\n")
  end
  return 1
end

--- The request argv routes as for `op` (`_build_request`, `_test_request`,
--- `_run_request`, `_clean_request`, `_reset_request`): the request (or
--- "target" / "device" for a form that stays in-process, nil for arguments
--- the in-process path refuses), and a run's parsed arguments.
--- @param op "build"|"test"|"run"|"clean"|"reset"
--- @param args string[]
--- @return table|string|nil req, loomworks.cli.RunArgs|nil run_args
function M._routed_request(op, args)
  if op == "test" then return M._test_request(args) end
  if op == "run" then return M._run_request(args) end
  if op == "clean" then return M._clean_request(args) end
  if op == "reset" then return M._reset_request(args) end
  return M._build_request(args)
end

--- Is this command's selection attached in `runtime-mode daemon` (spec §19.1
--- "Loopback during the transition")? `--no-daemon`, LOOMWORKS_NO_DAEMON=1,
--- CI, or a daemon that could not be started (`ensured == "failed"`, or nil:
--- the ensure step itself failed with an error — never in-process without the
--- runtime lock). Never in `in-process` mode (the default).
--- @param ensured string|nil `_ensure_daemon`'s outcome
--- @return boolean
function M._attached_selected(ensured)
  if ensured == "failed" then return true end
  if ensured ~= "off" and ensured ~= nil then return false end
  local rt = require("loomworks.daemon.runtime")
  local sel = rt.select(read_config()[rt.SETTING], { flag = M._no_daemon })
  if ensured == nil then return sel.mode == rt.DAEMON end
  return sel.mode == rt.DAEMON and not sel.daemon
end

--- The "workspace busy" refusal of an attached run (spec §19.2): `lk` is the
--- runtime lock's record (loomworks.daemon.inspect `state().lock`).
--- @param lk table|nil
--- @return string
function M._busy_message(lk)
  lk = lk or {}
  local rlock = require("loomworks.daemon.rlock")
  local who = string.format("%s (pid %s on %s)", rlock.holder_text(lk), tostring(lk.pid or "?"),
    tostring(lk.host or "?"))
  if lk.mode == "attached" then
    return "workspace busy: " .. who .. " is running here without a daemon — retry when it finishes"
  end
  return "workspace busy: " .. who .. " holds this workspace — retry when it finishes"
end

--- An attached selection meets the live daemon `st` holding the runtime lock
--- (spec §19.2, §19.9): loomworks.daemon.ensure.meet — the endpoint check,
--- handshake and version reconcile of the normal daemon-mode path — except
--- that an idle daemon of another version is only stopped (`no_launch`): the
--- command then runs attached. `opts.meet` (tests) replaces it.
--- @param root string
--- @param st table loomworks.daemon.inspect `state()`, kind "live"
--- @param opts table `_delegate_attached`'s
--- @return string "used" | "stopped" | "bypass" | "newer" | "failed"
function M._meet_live(root, st, opts)
  if opts.meet then return opts.meet(root, st) end
  local ensure = require("loomworks.daemon.ensure")
  local ok, outcome = pcall(ensure.meet, root, st, {
    note = note, log = require("loomworks.daemon.rlog").writer(root), no_launch = true,
    step_ms = ensure.step_ms(true),
  })
  if not ok then
    note("lw: could not use the workspace daemon (" .. (tostring(outcome):match("[^\n]*")) .. "); running without it")
    return "failed"
  end
  return outcome
end

--- A shared selection (daemon mode, `ensured == "elsewhere"`) whose runtime
--- lock an attached run holds (spec §19.2): wait `runtime-busy-wait` for it,
--- then fail "workspace busy", exit 1 (`die`). When it ends in time, the
--- ensure step runs again (the daemon is launched or used as usual) and its
--- outcome is returned. Any other holder (another host, a daemon still
--- starting): "elsewhere", unchanged.
--- @param root string
--- @return string|nil `_ensure_daemon`'s outcome
function M._await_attached_runtime(root)
  local inspect = require("loomworks.daemon.inspect")
  local st = inspect.state(root)
  if st.kind ~= "attached" then return "elsewhere" end
  local wait = require("loomworks.daemon.runtime").busy_wait_ms(read_config())
  vim.wait(math.max(1, wait), function()
    st = inspect.state(root)
    return st.kind ~= "attached"
  end, 25)
  if st.kind == "attached" then die(M._busy_message(st.lock), 1) end
  return M._ensure_daemon(root, true)
end

--- Run a routed operation attached (spec §19.1 "Loopback during the
--- transition", §19.19 step 5e): start the daemon's server and build service
--- in this process, holding the runtime lock in `attached` mode for the
--- command, and send the same request over the loopback transport
--- (`_delegate` with `attached`). A live daemon holding the lock is used as a
--- shared client instead; another attached run (or a daemon still starting)
--- is waited for `runtime-busy-wait`, then the command fails "workspace
--- busy", exit 1 (§19.2). The lock is released on every path — return,
--- error, `die`/`finish` and Ctrl-C (an exit hook, which also cancels the
--- running task). Returns nil to run in-process (a form the service does not
--- take), or the exit code.
--- @param op "build"|"test"|"run"|"clean"|"reset"
--- @param root string
--- @param args string[]
--- @param opts? table as for `_delegate`; `start` (tests) replaces
--- loomworks.daemon.command.start_attached
--- @return integer|nil exit code
function M._delegate_attached(op, root, args, opts)
  opts = opts or {}
  -- The forms that stay in-process (`lw test --target`, device options),
  -- arguments the in-process path refuses, and a workspace this machine
  -- refuses never take the runtime lock: in-process, silently.
  local req = M._routed_request(op, args)
  if type(req) ~= "table" or not M._daemon_workspace_trusted(root) then return nil end
  local server_mod = require("loomworks.daemon.server")
  local inspect = require("loomworks.daemon.inspect")
  local host = M._daemon_host()
  local start = opts.start or require("loomworks.daemon.command").start_attached
  local deadline = uv.now() + require("loomworks.daemon.runtime").busy_wait_ms(host.config)
  local srv, code, st
  while true do
    local _
    srv, _, code = start(root, host, op)
    if srv or code ~= server_mod.EXIT_HELD then break end
    st = inspect.state(root)
    local met
    if st.kind == "live" then
      -- A live daemon: connect to it as a shared client (§19.2) after the
      -- same version handshake as the normal path (§19.9, `_meet_live`).
      met = M._meet_live(root, st, opts)
      if met == "used" then return M._delegate(op, root, args, "used", opts) end
      -- A version bypass, a newer daemon, one that cannot be reached: its
      -- line is printed, and the command runs without it, as for a shared
      -- selection.
      if met ~= "stopped" then return nil end
      -- An idle daemon of another version was stopped (nothing launched):
      -- the lock is free, start attached at once (still within the wait).
    end
    if uv.now() >= deadline then break end
    if met ~= "stopped" then
      vim.wait(math.max(1, math.min(100, deadline - uv.now())), function() return false end, 10)
    end
  end
  if not srv then
    if code == server_mod.EXIT_HELD then
      st = st or inspect.state(root)
      if st.kind == "hung" then
        die("the workspace runtime is not responding (" .. M._runtime_reason(st) .. ") — see `lw daemon status`")
      end
      die(M._busy_message(st.lock), 1)
    end
    -- Not startable here (e.g. the root is gone): the in-process path reports it.
    return nil
  end
  local released = false
  local function release()
    if released then return end
    released = true
    pcall(srv.stop, srv, "the command ended", 0)
    -- The service loaded the workspace into this process's core with its own
    -- hooks: unload it, so an in-process load after it (a fallback, a device
    -- run) starts clean.
    if srv.service and srv.service._unload then pcall(srv.service._unload, srv.service) end
  end
  -- `die` / `finish` / Ctrl-C: stopping cancels the running task (its steps
  -- killed, its build locks released) and releases the runtime lock.
  on_exit(function()
    if not released then released = true; pcall(srv.stop, srv, "interrupted", 130) end
  end)
  local o = vim.tbl_extend("force", opts, {
    attached = true,
    session = require("loomworks.daemon.client").loopback_sessioner(srv),
    release = release,
    -- Stopped by itself (its lock taken over, or the root removed): why
    -- (the server's `stop_reason`), else false.
    lost = function()
      if released then return false end
      -- Checked now, not only on the next heartbeat: a prompt blocked the
      -- loop (the root and the lock record, as the heartbeat does).
      if srv.stopped ~= true then pcall(srv._tick, srv) end
      if srv.stopped ~= true then return false end
      return srv.stop_reason or server_mod.LOST_LOCK
    end,
  })
  o.start = nil
  local ok, res = xpcall(M._delegate, debug.traceback, op, root, args, "attached", o)
  -- A runtime that stopped by itself never lets the caller run the command
  -- in-process (nil) without the lock (§19.2).
  local why = o.lost()
  release()
  if not ok then error(res, 0) end
  if res == nil and why then return M._lost_runtime_exit(op, why) end
  return res
end

--- @class loomworks.cli.ReadOpts
--- Options of `read_workspace` / `M._read_projection`.
--- @field tools? "query"|table "query": build the projection from the
--- runtime's `tools` query (a fresh detection in this process's environment,
--- `lw tools`, §19.14); a table: this detection (tools_by_type, `lw tools
--- --cached`); absent: the detection the runtime's model holds
--- @field keep? boolean keep the session open until the command ends, for
--- `M._read_query` (`lw profile query … cache`)

--- How long a read waits for the daemon's answer to one request (spec
--- §19.1): a snapshot, and a host-probing query (a fresh tool detection takes
--- longer). Past it, or after `READ_MISSED_PINGS` keepalive pings in a row went
--- unanswered (one each `READ_PING_MS`), the command reads in-process with a
--- one-line note. `LW_TEST_READ_DEADLINE_MS` (tests) replaces both deadlines.
M.READ_DEADLINE_MS = 15000
M.READ_QUERY_DEADLINE_MS = 60000
M.READ_PING_MS = 1000
M.READ_MISSED_PINGS = 3

--- The open session a `keep` read leaves for `M._read_query` (nil otherwise).
--- @type { ask: fun(msg: table): table|nil, string|nil }|nil
M._read_session = nil

--- The read-only projection of the workspace daemon's model for a read-only
--- command (spec §19.1, §19.13), or nil to load the workspace in-process.
--- Only in `runtime-mode daemon` with a shared selection, and only from a
--- daemon that is already live, authenticates as this machine's and runs this
--- lw's version: a read never launches, stops or restarts a daemon, never
--- starts an attached (loopback) runtime and never takes the runtime lock.
--- Anything else — no daemon, another version, an attached selection
--- (`--no-daemon`, CI, the setting), a workspace this machine refuses, a
--- connection that fails, a declined request or no answer in time
--- (`READ_DEADLINE_MS`, missed pings: a one-line note) — is nil: the
--- in-process path, which reports a refusal itself. A refused snapshot ends
--- the command with the daemon's message — the same line the in-process load
--- prints.
--- @param root string
--- @param opts? loomworks.cli.ReadOpts
--- @return table|nil ws the projection (`_projection`, `_no_write`)
function M._read_projection(root, opts)
  opts = opts or {}
  if completion_mode or not root then return nil end
  local rt = require("loomworks.daemon.runtime")
  local sel = rt.select(read_config()[rt.SETTING], { flag = M._no_daemon })
  if sel.mode ~= rt.DAEMON or not sel.daemon or not M._daemon_workspace_trusted(root) then return nil end
  local st = require("loomworks.daemon.inspect").state(root)
  if st.kind ~= "live" or not require("loomworks.daemon.endpoint").check(root, st.handle.endpoint) then
    return nil
  end
  local client = require("loomworks.daemon.client")
  local conn = client.session(st.handle.endpoint, { timeout_ms = 5000 })
  if not conn then return nil end
  -- Another version is never reconciled here (no stop, no restart).
  if not require("loomworks.daemon.version").matches(conn.challenge or {}) then
    pcall(conn.close, conn)
    return nil
  end
  local function release() pcall(conn.close, conn) end
  on_exit(release)
  local test_deadline = tonumber(os.getenv("LW_TEST_READ_DEADLINE_MS") or "")
  local timed_out = false
  -- One request, bounded (see READ_DEADLINE_MS): nil, err on no answer.
  local function ask(msg, deadline_ms)
    if timed_out or conn.closed then return nil, "the connection closed" end
    local res
    -- (Over transport 11: lw.internal.Snapshot/1.get, Toolchains/1.list,
    -- Profiles/1.compiler_cache; daemon/calls.lua.)
    require("loomworks.daemon.calls").request(conn, msg, function(r, e) res = { r, e } end)
    local deadline = uv.now() + (test_deadline or deadline_ms or M.READ_DEADLINE_MS)
    local pong, missed, last = true, 0, uv.now()
    while not res and not conn.closed do
      vim.wait(math.max(1, math.min(M.READ_PING_MS, deadline - uv.now())),
        function() return res ~= nil or conn.closed end, 10)
      if res or conn.closed then break end
      if uv.now() >= deadline then timed_out = true; break end
      if uv.now() - last >= M.READ_PING_MS then
        missed = pong and 0 or (missed + 1)
        if missed >= M.READ_MISSED_PINGS then timed_out = true; break end
        pong, last = false, uv.now()
        conn:request({ kind = "ping" }, function() pong = true end)
      end
    end
    if timed_out then
      note("lw: the workspace daemon did not answer in time; reading without it")
      release()
      return nil, "timed out"
    end
    if not res then return nil, "the connection closed" end
    return res[1], res[2]
  end
  local env = require("loomworks.daemon.envscope").capture()
  local KIND = require("loomworks.daemon.protocol").KIND
  local snapshot = require("loomworks.daemon.snapshot")
  -- The reply, or nil (the in-process path); a refusal ends the command.
  local function answered(r)
    if not r or r.kind == "error" or r.outcome == "declined" then return nil end
    if r.outcome == "refused" then
      for _, n in ipairs(type(r.notes) == "table" and r.notes or {}) do errw(tostring(n) .. "\n") end
      die(r.message or "the workspace runtime refused the request")
    end
    if r.outcome ~= "ok" then return nil end
    return r
  end
  local snap = answered((ask({ kind = KIND.snapshot, scope = "all", env = env })))
  if not snap then release(); return nil end
  local tools = type(opts.tools) == "table" and opts.tools or nil
  if opts.tools == "query" then
    local q = answered((ask({ kind = KIND.query, name = "tools", args = {}, env = env }, M.READ_QUERY_DEADLINE_MS)))
    if not (q and type(q.result) == "table") then release(); return nil end
    tools = snapshot.tools_from_rows(q.result.tools)
  end
  local ws = snapshot.project(root, snap, {
    tools = tools,
    -- As the in-process load: warnings and errors on stderr.
    notify = function(msg, level)
      if not level or level >= vim.log.levels.WARN then errw(tostring(msg) .. "\n") end
    end,
  })
  if not ws then release(); return nil end
  -- Tests: a marker that this command read the daemon's projection.
  local trace = os.getenv("LW_TEST_READ_TRACE")
  if trace and trace ~= "" then
    local f = io.open(trace, "a")
    if f then f:write("projection " .. root .. "\n"); f:close() end
  end
  if opts.keep then
    M._read_session = { ask = function(msg)
      msg.env = msg.env or env
      return ask(msg, M.READ_QUERY_DEADLINE_MS)
    end }
  else
    release()
  end
  return ws
end

--- Run a host-probing query (spec §19.14) on the session a `keep` read left
--- open: its `result`, or nil when there is none (the caller computes the
--- value in-process). A refusal ends the command with its message.
--- @param name string
--- @param args? table
--- @return table|nil result
function M._read_query(name, args)
  local s = M._read_session
  if not s then return nil end
  local r = s.ask({ kind = require("loomworks.daemon.protocol").KIND.query, name = name, args = args or {} })
  if not r or r.kind == "error" or r.outcome == "declined" then return nil end
  if r.outcome == "refused" then die(r.message or ("query " .. name .. " failed")) end
  return type(r.result) == "table" and r.result or nil
end

--- Record a kill or forced unlock in the runtime log (spec §19.5, §19.10).
--- @param root string|nil
--- @param line string
function M._record_recovery(root, line)
  if root then require("loomworks.daemon.rlog").write(root, line) end
end

--- The output helpers loomworks.daemon.command uses.
--- @return table
function M._daemon_host()
  return { out = out, note = note, errw = errw, die = die, config = read_config(), finish = finish,
    on_exit = on_exit, build = M._daemon_build_host() }
end

--- What the workspace daemon's build service (loomworks.daemon.service,
--- spec §19.15) needs from this host: the workspace load of the in-process
--- path — never exiting, refusals returned as the text `lw` prints — and the
--- `--target` failure hint.
--- @return table
function M._daemon_build_host()
  local function core() return require("loomworks")._core() end
  return {
    -- `opts.wait_tools = false`: a snapshot's or query's load (§19.13), which
    -- does not wait for tool detection.
    load = function(root, handlers, opts)
      local wait = not (opts and opts.wait_tools == false)
      local ws, _, fail = M._load_workspace_soft(root, wait, { handlers = handlers })
      if ws then return ws end
      return nil, fail and fail.message
    end,
    unload = function() core():shutdown() end,
    -- nil while the core (re)loads: a refused file put it back through
    -- setup (§17.4), and its old workspace must not be used meanwhile.
    current = function()
      local c = core()
      return c._state == "initialized" and c:get_workspace() or nil
    end,
    settle = function(ms)
      vim.wait(ms, function()
        local c = core()
        return c._state == "initialized" or c._state == "uninitialized"
      end, 25)
      local ws = core():get_workspace()
      if ws then vim.wait(ms, function() return ws._tool_state == "scanned" end, 25) end
    end,
    setup_error = function() return M._setup_failure(core()).message end,
    -- The failed load the welcome header reports (spec §19.13), nil when
    -- none: `refused` for a trust, newer-schema or journal refusal.
    error_state = function()
      local c = core()
      local e = c.get_setup_error and c:get_setup_error()
      if not e then return nil end
      return { message = M._setup_failure(c).message,
        refused = (e.trust or e.newer or e.journal) and true or nil }
    end,
    unknown_target_hint = function(ws, step, targets) return M._unknown_target_hint(ws, step, targets) end,
  }
end

--- `lw daemon <sub>` (spec §19.11) — loomworks.daemon.command.
--- @param root string|nil
--- @param args string[]
--- @return integer
--- `lw cleanup [--dry-run | --yes] [--all] [--pinned-older-than <dur>]`
--- (spec §16.40).
function M.cmd_cleanup(root, args)
  return require("loomworks.housekeeping").cmd(root, args, { out = out, die = die })
end

function M.cmd_daemon(root, args)
  return require("loomworks.daemon.command").run(args[2], root, args, M._daemon_host())
end

function M.cmd_status(root, opts)
  opts = opts or {}
  if not root then
    for _, line in ipairs(M._worktree_hint()) do out(line) end
    -- The command index pointer lives here, not in _worktree_hint, so the
    -- health report (which reuses the hint) does not repeat it (§16.18).
    local pal0 = status_palette(stdout_supports_color())
    out("")
    out(pal0.inline("lw help") .. pal0.dim(" for every command."))
    -- A `--check` gate with no workspace is a misconfigured CI job: fail it.
    -- The page is unchanged — `--check` only sets the exit status (§16.18).
    return opts.check and 1 or 0
  end
  local ws = read_workspace(root, false) -- pinned info only; skip tool detection
  local pal = status_palette(stdout_supports_color())
  out(pal.title("loomworks — " .. (ws.name or "?")) .. "  " .. pal.dim("(" .. ws.root .. ")"))
  -- Reached by walking out of a submodule (spec §1.1): say so, so acting on the
  -- superproject's build from inside a submodule is not a surprise (§16 status).
  if opts.submodule then
    local rel = opts.submodule:sub(#root + 2)
    out(pal.dim("(workspace of the superproject — you are in submodule " ..
      (rel ~= "" and rel or opts.submodule) .. ")"))
  end

  -- Workspace diagnostics — the SAME source the editor's Diagnostics section
  -- uses. Rendered as a top section (when non-empty) and, per item, inline
  -- under the relevant profile/config-set/project row. Never let it break
  -- status: a broken diagnostics pass collapses to "no diagnostics".
  local ok_d, diags = pcall(function() return ws:diagnostics() end)
  if not ok_d or type(diags) ~= "table" then diags = {} end
  local grouped = group_diagnostics(diags)

  local MAX = 6
  -- Size every name column to the terminal so wide terminals show full names
  -- instead of truncating at a hardcoded width. Measured once per render.
  local tw = term_width()
  local profiles = ws._profiles or {}
  local active_key = ws._active_profile_key
  local ap
  for _, p in ipairs(profiles) do if p.key == active_key then ap = p end end
  -- No profiles in a linked worktree whose main checkout has a working copy:
  -- offer `lw pull` first (§16.18). The git probe runs only in this case.
  local can_pull, pull_probe = false, nil
  if #profiles == 0 then
    -- Probe from the workspace root (not the cwd): it is that checkout's
    -- worktree whose main we ask about.
    if opts.can_pull ~= nil then
      can_pull = opts.can_pull
    else
      can_pull, pull_probe = M._main_has_working_copy({ dir = root })
    end
  end

  out("")
  if ap then
    -- Fixed parts of this line: the "Active profile" title + 3 spaces (prefix),
    -- then 3 spaces + "(set <name>)" (suffix). The name gets the rest.
    local set_name = ap._configuration_set_name or "?"
    local overhead = #"Active profile" + 3 + 3 + #("(set " .. set_name .. ")")
    local aw = math.max(20, tw - overhead)
    out(pal.title("Active profile") .. "   " .. pal.active(trunc(ap.key, aw)) ..
      "   " .. pal.dim("(set " .. set_name .. ")"))
  elseif #profiles > 0 then
    out(pal.title("Active profile") .. "   " .. pal.dim("(none) — ") .. pal.inline("lw profile select"))
  elseif can_pull then
    out(pal.title("Active profile") .. "   " .. pal.dim("(no profiles) — ") ..
      pal.inline("lw pull") .. pal.dim(" copies them from the main checkout"))
  else
    out(pal.title("Active profile") .. "   " .. pal.dim("(no profiles) — ") ..
      pal.inline("lw profile create <set> <tool>"))
    -- A slow git leaves the pull offer unknown, not "no": say so (§16.18).
    if pull_probe == "git-timeout" then
      out(string.rep(" ", 17) .. pal.dim(M._git_timeout_note("the main checkout", "lw pull")))
    end
  end

  -- Compiler cache line for the active profile (headless §16.18), sibling to
  -- the toolchain info, mirroring the editor's Cache: row. Shown only for a
  -- profile with a C/C++-caching module; --cache-stats folds in usage stats.
  if ap then
    render_cache_line(pal, ap, opts.cache_stats)
  elseif opts.cache_stats then
    -- --cache-stats needs a profile to resolve the cache tool from.
    out(pal.title("Cache") .. string.rep(" ", 12)
      .. pal.dim("(no active profile — activate one with `lw profile select` for --cache-stats)"))
  end

  -- Runtime row (spec §19.6): from the runtime lock and handle files only —
  -- never launches or connects. Under it, a busy daemon's running tasks: asked
  -- with a bounded `status` request, never launching one; a failed query is
  -- one line and changes nothing else.
  do
    local row = M._runtime_row(root)
    if row then out(pal.title("Runtime") .. string.rep(" ", 10) .. pal.dim(row)) end
    local ok, lines, reply = pcall(function() return require("loomworks.daemon.running").lines(root) end)
    if ok then
      for _, l in ipairs(lines) do out(pal.dim(l)) end
    end
    -- The same reply's tasks put their running state on this process's
    -- profiles and units, exactly as the editor shows an observed task
    -- (§19.16), so the Profiles rows' state shows them running (§16.18).
    -- Display only, never persisted; a bad entry is skipped.
    if ok and type(reply) == "table" and type(reply.tasks) == "table" then
      local rt = require("loomworks.daemon.remote_task")
      local clock = uv.hrtime() / 1e9
      for _, entry in ipairs(reply.tasks) do
        pcall(function()
          local task = rt.adopt(ws, entry, clock)
          if task then task:attach_units() end
        end)
      end
    end
  end

  -- Trust row (spec §17.10): what loomworks may run on whose word. A refused
  -- working copy never gets here (the load exits with the refusal), so a
  -- present one is signed on this machine.
  out(pal.title("Trust") .. string.rep(" ", 12) .. pal.dim(M._trust_row(ws, root)))

  -- Diagnostics section — right after the active-profile block, before Targets.
  -- Renders nothing when there are none.
  render_diagnostics(pal, diags)

  -- Suggestions count line (spec/ui.md §1.1, headless §16.18): a one-line
  -- advisory pointing at `lw health`, shown only when the framework has
  -- findings. Advisory — it never affects the --check exit status.
  do
    -- Count only ACTIONABLE items — an affirmative "using <cache>" info item
    -- lives in `lw health`, never inflates this nag count (headless §16.31).
    local ok_s, n = pcall(function()
      return require("loomworks.suggestions").count_actionable(ws)
    end)
    if ok_s and type(n) == "number" and n > 0 then
      out("")
      out(pal.warn(n .. (n == 1 and " suggestion" or " suggestions"))
        .. " — run " .. pal.inline("lw health"))
    end
  end

  if ap then
    -- Targets: the active profile's launchable targets (the same list
    -- `lw target` shows), default marked `*`+green. Build-free — a build target
    -- is listed only once its project is configured, so the list may be
    -- incomplete; a hint says how to complete it. Never let it break status.
    local ok_t, tinfo = pcall(collect_targets, ws, ap)
    if not ok_t or not tinfo then tinfo = { rows = {}, unconfigured = {}, incomplete = false } end
    -- cwd for the default module target (descriptor-based; no build needed).
    local default_cwd
    local ok_lt, lt = pcall(function() return ap:default_target() end)
    if ok_lt and lt and lt:is_module_target() then default_cwd = lt:working_directory() end

    local target_help = {
      "run a target · lw run <target>",
      "set this profile's default · lw target set <target>",
    }
    if tinfo.incomplete then
      table.insert(target_help, 1, "configure to list build targets · lw build")
    end
    status_section(pal, "Targets", tinfo.rows, MAX, function(r)
      local base = string.format("%s %-30s (%s)", r.is_default and "*" or " ",
        trunc(r.label, 30), r.kind_label)
      local sum = M._summary_suffix(require("loomworks.description").width(base), r.description, nil, pal)
      if r.is_default then
        local line = pal.active(base) .. sum
        if default_cwd then line = line .. "   " .. pal.dim("cwd: " .. trunc(default_cwd, 30)) end
        if r.suffix then line = line .. pal.dim(r.suffix) end
        return line
      end
      return base .. sum .. (r.suffix and pal.dim(r.suffix) or "")
    end, "lw target", target_help)
  end

  -- Profiles: active first (so it's always visible under the cap), then the
  -- rest by key; active marked with `*`.
  local plist = {}
  if ap then plist[#plist + 1] = ap end
  local rest = {}
  for _, p in ipairs(profiles) do if p ~= ap then rest[#rest + 1] = p end end
  table.sort(rest, function(a, b) return a.key < b.key end)
  for _, p in ipairs(rest) do plist[#plist + 1] = p end
  -- Switching only makes sense with more than one profile; offer it above the
  -- create hint in that case.
  local profile_help = { M.PROFILE_CREATE_HELP }
  if can_pull then
    table.insert(profile_help, 1, "copy the main checkout's profiles · lw pull")
  end
  if #profiles > 1 then
    table.insert(profile_help, 1, "switch the profile · lw profile select")
  end
  -- Content-sized, terminal-capped name column (row formatting lives in the
  -- exposed status_profile_rows seam so it can be tested without a real tty).
  local prof_rows = status_profile_rows(pal, plist, active_key, grouped, tw,
    profile_numbering(ws).number)
  local prof_i = 0
  status_section(pal, "Profiles", plist, MAX, function()
    prof_i = prof_i + 1
    return prof_rows[prof_i]
  end, "lw profile list", profile_help)

  -- Configuration sets: name + compact mappings.
  local sets = {}
  for _, cs in ipairs(ws._config_sets or {}) do sets[#sets + 1] = cs end
  table.sort(sets, function(a, b) return a.name < b.name end)
  -- Name column sized to content and capped to the terminal; the mapping list
  -- takes the width that remains (never below 16), so the row fits.
  local cs_longest = 0
  for _, cs in ipairs(sets) do cs_longest = math.max(cs_longest, #tostring(cs.name)) end
  local cs_name_w = fit_column(cs_longest, tw, 2 + 1 + 56 + 4, 8)
  local cs_map_w = math.max(16, tw - 2 - cs_name_w - 1 - 4)
  -- Summary column before the open-ended mappings, which take the truncation
  -- (spec §16.35).
  local cs_descs = {}
  for i, cs in ipairs(sets) do cs_descs[i] = cs.description end
  local cs_sum_w = M._summary_column(cs_descs, tw, 2 + cs_name_w)
  if cs_sum_w > 0 then cs_map_w = math.max(16, tw - 2 - cs_name_w - 1 - cs_sum_w - 3 - 4) end
  status_section(pal, "Configuration sets", sets, MAX, function(cs)
    local rows = {}
    for project, cfg in pairs(cs.mappings or {}) do rows[#rows + 1] = project.key .. "→" .. cfg.name end
    table.sort(rows)
    local prefix = string.format("  %-" .. cs_name_w .. "s", trunc(cs.name, cs_name_w))
    return M._row_with_summary(prefix, cs.description, cs_sum_w,
      next(rows) and rows or "(empty)", cs_map_w, pal)
      .. inline_markers(pal, grouped.by_key["set:" .. cs.name])
  end, "lw configset list", "create a set · lw configset create <name> [project=config …]")

  -- Projects with their configurations (first few names, then +K).
  local projs = {}
  for _, p in ipairs(ws._projects or {}) do projs[#projs + 1] = p end
  table.sort(projs, function(a, b) return a.key < b.key end)
  -- Name column sized to content and capped to the terminal; the type column
  -- is as wide as the longest type shown; the config list takes the width
  -- that remains (never below 16), so the row fits.
  -- Row layout: "  " + name + " " + type + " " + cfgstr.
  local function ptype(p) return tostring(p.type or (p._module and p._module.id) or "?") end
  local pj_longest, pj_type_w = 0, 1
  for _, p in ipairs(projs) do
    pj_longest = math.max(pj_longest, #tostring(p.key))
    pj_type_w = math.max(pj_type_w, #ptype(p))
  end
  local pj_name_w = fit_column(pj_longest, tw, 2 + 1 + pj_type_w + 1 + 50 + 4, 8)
  local pj_cfg_w = math.max(16, tw - 2 - pj_name_w - 1 - pj_type_w - 1 - 4)
  -- Summary column before the open-ended configuration list (spec §16.35).
  local pj_descs = {}
  for i, p in ipairs(projs) do pj_descs[i] = p.description end
  local pj_sum_w = M._summary_column(pj_descs, tw, 2 + pj_name_w + 1 + pj_type_w)
  if pj_sum_w > 0 then
    pj_cfg_w = math.max(16, tw - 2 - pj_name_w - 1 - pj_type_w - 1 - pj_sum_w - 3 - 4)
  end
  status_section(pal, "Projects", projs, MAX, function(p)
    local t = ptype(p)
    local names = {}
    for _, c in ipairs(p:get_configurations()) do names[#names + 1] = c.name end
    table.sort(names)
    -- First three names, then +K; the row cuts at whole names (§16.35).
    local head = { more = math.max(0, #names - 3) }
    for i = 1, math.min(#names, 3) do head[#head + 1] = names[i] end
    local cfgstr = (#names == 0) and "(no configs)" or head
    local prefix = string.format("  %-" .. pj_name_w .. "s %-" .. pj_type_w .. "s", trunc(p.key, pj_name_w), t)
    return M._row_with_summary(prefix, p.description, pj_sum_w, cfgstr, pj_cfg_w, pal)
      .. inline_markers(pal, grouped.by_project[p.key])
  end, "lw project list", "add a project · lw project add <path> [type]")

  out("")
  for _, l in ipairs(M._status_footer(pal)) do out(l) end

  -- `--check` (CI): exit non-zero when ANY diagnostic is present. The rendering
  -- above is unchanged; only the exit code differs. Without it, status is 0.
  return check_exit_code(opts.check, diags)
end

-- ---------------------------------------------------------------------------
-- health — advisory suggestions + environment inventory (§16.31, §16.33)
-- ---------------------------------------------------------------------------

--- Probe the environment inventory now (an explicit health run). A seam tests
--- replace so they never depend on the host's tools.
--- `opts` carries the run's scope and area selection (§16.36).
--- @param ws loomworks.Workspace|nil
--- @param opts? { scope?: "relevant"|"all", areas?: table<string, true> }
--- @return table tier `inventory.probe_tier` result
function M._probe_inventory(ws, opts)
  return require("loomworks.inventory").probe_tier(ws, opts)
end

--- Status mark for an inventory entry: + found, x missing+required, - missing,
--- ? unknown.
--- @param e table classified entry
--- @return string
local function inv_mark(e)
  if e.status == "found" then return "+" end
  if e.status == "unknown" then return "?" end
  return e.required and "x" or "-"
end

--- Paint an entry's mark: found green, missing-required warn, others dim.
--- @param pal table status_palette()
--- @param e table
--- @return string
local function inv_paint_mark(pal, e)
  local m = inv_mark(e)
  if e.status == "found" then return pal.active(m) end
  if e.required and e.status == "missing" then return pal.warn(m) end
  return pal.dim(m)
end

--- The trailing text of one full inventory line: the location (and detail) for
--- a found entry; "not found" / detail plus the hint otherwise.
--- @param pal table
--- @param e table
--- @return string
local function inv_tail(pal, e)
  if e.status == "found" then
    local parts = {}
    if e.path then parts[#parts + 1] = pal.dim(e.path) end
    if e.detail then parts[#parts + 1] = pal.dim("(" .. e.detail .. ")") end
    return table.concat(parts, " ")
  end
  local what = e.detail or (e.status == "unknown" and "unknown" or "not found")
  if e.hint then what = what .. " (" .. e.hint .. ")" end
  return pal.dim(what)
end

--- Display width of a UTF-8 string (code points).
--- @param s string
--- @return integer
local function uwidth(s)
  local _, n = tostring(s):gsub("[^\128-\191]", "")
  return n
end

--- Right-pad `s` to display width `w`.
local function upad(s, w)
  return s .. string.rep(" ", math.max(0, w - uwidth(s)))
end

-- Columns the name column always leaves for the tail (location / hint) and the
-- floor it never shrinks below, whatever the terminal width.
local INV_TAIL_RESERVE = 30
local INV_NAME_MIN = 40

--- Width of the inventory "label version" column: sized to the longest row, but
--- capped so the tail keeps `INV_TAIL_RESERVE` columns on a `tw`-wide terminal
--- (never below `INV_NAME_MIN`, so a narrow terminal still lines up the common
--- rows). `lead` is the visible width before the column (indent + category
--- column); the 4 accounts for the status mark, its space, and the two-space
--- gap. A row longer than the cap overflows (its name is never truncated —
--- a clipped version would mislead). Pure; exported for tests.
--- @param longest integer widest "label version" among the rows
--- @param lead integer visible columns before the mark
--- @param tw integer terminal width
--- @return integer
local function inventory_name_width(longest, lead, tw)
  return math.min(longest, math.max(INV_NAME_MIN, tw - lead - 4 - INV_TAIL_RESERVE))
end
M._inventory_name_width = inventory_name_width

--- Who needs an entry, for the end of its line: its active-scope `required_by`,
--- or — relevant only through non-active profiles — "other profiles: …"
--- (§16.36). Compacted (`names_phrase`); every name with `full`.
--- @param e table scoped entry
--- @param full? boolean
--- @return string|nil
function M._inv_needed(e, full)
  local inv = require("loomworks.inventory")
  if #(e.required_by or {}) > 0 then
    return inv.names_phrase(e.required_by, { full = full })
  end
  if e.used_by and #e.used_by > 0 then
    return "other profiles: " .. inv.names_phrase(e.used_by, { full = full })
  end
  return nil
end

--- Render `entries` one line per item under a left category column that names
--- each category once; a line ends with who needs it (`inv_needed`).
--- @param pal table
--- @param entries table[] entries (category order)
--- @param indent string
--- @param full_names? boolean every profile/project name (`--verbose`)
local function render_inventory_lines(pal, entries, indent, full_names)
  local cat_w, longest = 0, 0
  for _, e in ipairs(entries) do
    cat_w = math.max(cat_w, uwidth(e.category))
    local name = e.label .. (e.version and (" " .. e.version) or "")
    longest = math.max(longest, uwidth(name))
  end
  local name_w = inventory_name_width(longest, uwidth(indent) + cat_w + 2, term_width())
  local last_cat
  for _, e in ipairs(entries) do
    local cat = (e.category ~= last_cat) and e.category or ""
    last_cat = e.category
    local name = e.label .. (e.version and (" " .. e.version) or "")
    local line = indent .. pal.title(upad(cat, cat_w)) .. "  "
      .. inv_paint_mark(pal, e) .. " " .. upad(name, name_w) .. "  " .. inv_tail(pal, e)
    local who = M._inv_needed(e, full_names)
    if who then line = line .. pal.dim("  - " .. who) end
    out((line:gsub("%s+$", "")))
  end
end

--- Render entries compacted to one line per category (the full scope's "not
--- used here" block, §16.36). Found plugins are counted, not listed.
--- @param pal table
--- @param entries table[] (category order)
--- @param indent string
local function render_inventory_compact(pal, entries, indent)
  local cats, by_cat = {}, {}
  for _, e in ipairs(entries) do
    if not by_cat[e.category] then
      by_cat[e.category] = {}
      cats[#cats + 1] = e.category
    end
    table.insert(by_cat[e.category], e)
  end
  local cat_w = 0
  for _, c in ipairs(cats) do cat_w = math.max(cat_w, uwidth(c)) end
  for _, c in ipairs(cats) do
    local items = {}
    local loaded = 0
    for _, e in ipairs(by_cat[c]) do
      if c == "plugins" and e.status == "found" then
        loaded = loaded + 1
      else
        local txt = e.label .. ((e.status == "found" and e.version) and (" " .. e.version) or "")
        if e.detail and e.detail:match("^rejected") then txt = txt .. " (rejected)" end
        items[#items + 1] = inv_paint_mark(pal, e) .. " " .. txt
      end
    end
    if loaded > 0 then table.insert(items, 1, pal.active("+") .. " " .. loaded .. " loaded") end
    out(indent .. pal.title(upad(c, cat_w)) .. "  " .. table.concat(items, pal.dim(" - ")))
  end
end

--- The `lw health --json` document (§16.33, §16.36): `{ schema, scope,
--- areas?, workspace?, suggestions[], inventory[], summary, hidden?, update?,
--- submodules? }`. `entries` are the SHOWN inventory entries (the run's scope
--- and area selection); `summary` counts what the document holds. Each
--- suggestion carries its `area`; each entry its `area`, `relevant` and —
--- relevant only through non-active profiles — `used_by`. An inventory entry
--- carries `hint` only when it is not found. `cmd_health` encodes it with
--- sorted object keys.
--- @param ws loomworks.Workspace|nil
--- @param suggestions loomworks.Suggestion[]
--- @param entries table[]
--- @param meta? { scope?: string, areas?: string[], hidden?: table<string, integer>, root?: string, trust?: table }
--- @return table
local function health_json(ws, suggestions, entries, meta)
  meta = meta or {}
  local inv = require("loomworks.inventory")
  local sugg = {}
  for _, s in ipairs(suggestions) do
    sugg[#sugg + 1] = { kind = s.kind or "suggestion", title = s.title, detail = s.detail,
      remedy = s.remedy, area = s.area or "other" }
  end
  -- The submodule report (§16.31 provider #3), absent when it did not apply.
  local ok_sm, submodules = pcall(function()
    local sm = require("loomworks.submodules")
    return sm.json(sm.last_report())
  end)
  local summary = { actionable = 0, found = 0, missing = 0, unknown = 0, required_missing = 0 }
  for _, s in ipairs(suggestions) do
    if (s.kind or "suggestion") ~= "info" then summary.actionable = summary.actionable + 1 end
  end
  local items = {}
  for _, e in ipairs(entries) do
    if summary[e.status] then summary[e.status] = summary[e.status] + 1 end
    if e.required and e.status == "missing" then summary.required_missing = summary.required_missing + 1 end
    items[#items + 1] = {
      id = e.id, label = e.label, category = e.category, status = e.status,
      version = e.version, path = e.path, detail = e.detail,
      -- The install remedy only where it is actionable: a found entry's hint
      -- is noise to a reader or a diff.
      hint = e.status ~= "found" and e.hint or nil,
      required = e.required and true or false,
      required_by = e.required_by or {},
      area = e.area or inv.area_of(e.category),
      relevant = e.relevant and true or false,
      used_by = (e.used_by and #e.used_by > 0) and e.used_by or nil,
    }
  end
  local workspace
  if ws then
    workspace = { name = ws.name, root = ws.root }
  elseif meta.trust then
    workspace = { root = meta.root, trust = "refused" }
  end
  return {
    schema = inv.JSON_SCHEMA,
    scope = meta.scope or "all",
    areas = meta.areas,
    workspace = workspace,
    suggestions = sugg,
    inventory = items,
    summary = summary,
    hidden = (meta.hidden and next(meta.hidden)) and meta.hidden or nil,
    -- The update check's outcome (§16.31); absent when it does not apply.
    update = require("loomworks.suggestions").last_update_check(),
    submodules = ok_sm and submodules or nil,
  }
end
M._health_json = health_json

--- Validate `lw health` area arguments (§16.36): the known ones, deduplicated,
--- in the order given. Returns nil and the offending name for an unknown one.
--- @param names string[]
--- @return string[]|nil areas, string|nil unknown
function M._health_areas(names)
  local inv = require("loomworks.inventory")
  local known, seen, list = {}, {}, {}
  for _, a in ipairs(inv.AREAS) do known[a] = true end
  for _, n in ipairs(names or {}) do
    if not known[n] then return nil, n end
    if not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  return list
end

--- The actionable item for a refused working copy (§16.36).
--- @param t table the setup error's trust table `{ kind, status }`
--- @return loomworks.Suggestion
function M._health_trust_item(t)
  local why = (t and t.status == "unsigned") and "not signed by this machine" or "modified outside loomworks"
  return {
    kind = "suggestion", area = "workspace",
    title = "working copy not trusted (.nvim/loomworks.user.json " .. why .. ")",
    remedy = "review and trust it: lw trust   (or discard it: lw trust --discard; lw help trust)",
  }
end

--- `lw health` — the workspace's advisory suggestions and the environment
--- inventory (headless §16.31, §16.33), scoped to what the workspace makes
--- relevant, or everything with `opts.all`, optionally narrowed to areas
--- (§16.36). Read-only and advisory: it performs no build, authors nothing
--- (the health cache is an internal file), and ALWAYS exits 0 (suggestions
--- never gate; an unknown area is rejected by the dispatcher before this
--- runs). Never spawns a cache tool; the inventory probes spawn version
--- queries and the installation locator, which is why they run only here —
--- and in the relevant scope only for what the workspace uses.
---
--- Outside a workspace (or with a refused working copy, reported as an
--- item) nothing but lw itself is relevant: plain health reports the lw and
--- launcher areas and probes no toolchain, SDK or editor declaration; `--all`
--- is the full machine inventory. Nothing is cached there.
--- `opts.json` prints the machine-readable document instead.
--- @param root string|nil workspace root
--- @param opts? { json?: boolean, verbose?: boolean, all?: boolean, areas?: string[] }
--- @return integer exit code (always 0)
function M.cmd_health(root, opts)
  opts = opts or {}
  -- The text report is ASCII (§16.31); --json keeps the data verbatim.
  local prev = M._ascii_out
  M._ascii_out = not opts.json
  local ok, res = pcall(M._cmd_health, root, opts)
  M._ascii_out = prev
  if not ok then error(res, 0) end
  return res
end

--- `cmd_health`'s body (see there).
--- @param root string|nil
--- @param opts table
--- @return integer
function M._cmd_health(root, opts)
  local pal = status_palette((not opts.json) and stdout_supports_color())
  local inv = require("loomworks.inventory")
  local scope = opts.all and "all" or "relevant"
  local area_list = (opts.areas and #opts.areas > 0) and opts.areas or nil
  local areas
  if area_list then
    areas = {}
    for _, a in ipairs(area_list) do areas[a] = true end
  end
  local function selected(a) return areas == nil or areas[a] == true end

  local ws, trust
  if root then
    local _
    ws, _, trust = load_workspace(root, false, { soft_trust = true })
  end

  -- Probe first (the one expensive step) — only what the scope and selection
  -- need (§16.36); a failure leaves an empty inventory.
  local ok_t, tier = pcall(M._probe_inventory, ws, { scope = scope, areas = areas })
  if not ok_t or type(tier) ~= "table" then tier = nil end

  -- `collect_health` (not the passive `collect`) so the report includes the
  -- network-backed providers — the update-availability check (§16.31) — that are
  -- deliberately kept out of the frequently-rendered `N suggestions` count. Pass
  -- whatever workspace we have (possibly nil); the workspace-independent
  -- providers run regardless, the workspace-scoped ones guard nil themselves.
  -- Only the selected areas' providers run, and only completed tiers are cached.
  local ok_s, suggestions = pcall(function()
    local sug = require("loomworks.suggestions")
    sug._update_check = nil -- only this run's outcome reaches --json
    require("loomworks.submodules")._last = nil
    return sug.collect_health(ws, { inventory = tier, areas = areas })
  end)
  if not ok_s or type(suggestions) ~= "table" then suggestions = {} end
  if trust and selected("workspace") then table.insert(suggestions, 1, M._health_trust_item(trust)) end

  -- Entries: classified over every profile (relevance) with the active
  -- profile's required split; then the scope decides what is shown.
  local shown, hidden = {}, {}
  if tier then
    for a, n in pairs(tier.skipped or {}) do hidden[a] = (hidden[a] or 0) + n end
    local ok_c, entries = pcall(inv.scoped_entries, tier, ws)
    for _, e in ipairs(ok_c and entries or {}) do
      if not selected(e.area) then
        -- Outside the selection: neither shown nor counted.
      elseif scope == "relevant" and not e.relevant then
        hidden[e.area] = (hidden[e.area] or 0) + 1
      else
        shown[#shown + 1] = e
      end
    end
  end

  if opts.json then
    -- Sorted object keys at every depth (arrays keep their defined order), so
    -- the document is byte-stable for agents and CI diffs.
    out(require("loomworks.io").encode_sorted(health_json(ws, suggestions, shown, {
      scope = scope, areas = area_list, hidden = scope == "relevant" and hidden or nil,
      root = root, trust = trust,
    })))
    return 0
  end

  if ws then
    out(pal.title("loomworks health — " .. (ws.name or "?")) .. "  "
      .. pal.dim("(" .. ws.root .. ")"))
  elseif not trust then
    -- No workspace here: lead with the worktree hint so the user knows why no
    -- project-scoped items appear, then still run the workspace-independent
    -- health providers below (they ignore the nil workspace).
    for _, line in ipairs(M._worktree_hint()) do out(line) end
  else
    out(pal.title("loomworks health") .. "  " .. pal.dim("(" .. tostring(root) .. ")"))
  end

  -- Actionable items first ("*", the ones `lw status`'s N suggestions
  -- counts) with their area, then one section per area holding its
  -- informational notes ("-") and inventory lines (§16.36) — so the "*"
  -- bullets a reader counts match that number, with or without color.
  local actionable, notes = {}, {}
  for _, s in ipairs(suggestions) do
    if s.kind == "info" then notes[#notes + 1] = s else actionable[#actionable + 1] = s end
  end
  -- A `detail_verbose` item's detail (e.g. the per-submodule lines) is shown
  -- only with --verbose; --json always carries it.
  local function show_detail(s) return s.detail and (not s.detail_verbose or opts.verbose) end
  if #actionable == 0 and ws and not areas then
    out("")
    out(pal.dim("No suggestions — nothing to flag."))
  end
  for _, s in ipairs(actionable) do
    out("")
    out(pal.warn("* " .. s.title) .. "  " .. pal.dim("[" .. (s.area or "other") .. "]"))
    if show_detail(s) then out("  " .. s.detail) end
    if s.remedy then out("  " .. pal.dim(s.remedy)) end
  end

  local order = {}
  for _, a in ipairs(inv.AREAS) do order[#order + 1] = a end
  order[#order + 1] = "other"
  for _, area in ipairs(order) do
    local area_notes, lw_entry, plugins, relevant, other = {}, nil, {}, {}, {}
    for _, s in ipairs(notes) do
      if (s.area or "other") == area then area_notes[#area_notes + 1] = s end
    end
    for _, e in ipairs(shown) do
      if e.area == area then
        if e.id == "lw" and e.category == "lw" then
          lw_entry = e
        elseif not e.relevant then
          other[#other + 1] = e
        elseif e.category == "plugins" and e.status == "found" and not e.required then
          plugins[#plugins + 1] = e
        else
          relevant[#relevant + 1] = e
        end
      end
    end
    local empty = not lw_entry and #area_notes == 0 and #plugins == 0 and #relevant == 0 and #other == 0
    if not empty or (areas and areas[area]) then
      out("")
      out(pal.title(area))
      if lw_entry then
        out("  " .. "lw  " .. (lw_entry.version or "")
          .. (lw_entry.detail and pal.dim((lw_entry.version and " (" or "(") .. lw_entry.detail .. ")") or "")
          .. (lw_entry.path and ("  " .. pal.dim(lw_entry.path)) or ""))
      end
      for _, s in ipairs(area_notes) do
        -- Informational items (affirmative status) read as positive, not a warning.
        out("  " .. pal.active("- " .. s.title))
        if show_detail(s) then out("    " .. s.detail) end
        if s.remedy then out("    " .. pal.dim(s.remedy)) end
      end
      -- Required entries first (the active profile's), then the other relevant ones.
      local req_first = {}
      for _, e in ipairs(relevant) do if e.required then req_first[#req_first + 1] = e end end
      for _, e in ipairs(relevant) do if not e.required then req_first[#req_first + 1] = e end end
      relevant = req_first
      if #relevant > 0 then render_inventory_lines(pal, relevant, "  ", opts.verbose) end
      if #plugins > 0 then
        local names = {}
        for _, e in ipairs(plugins) do names[#names + 1] = e.label end
        out("  " .. pal.title("plugins") .. "  " .. pal.active("+") .. " " .. #plugins .. " loaded"
          .. pal.dim(" (" .. table.concat(names, ", ") .. ")"))
      end
      if #other > 0 then
        if not ws then
          -- Outside a workspace --all is the machine inventory, one line each.
          render_inventory_lines(pal, other, "  ", true)
        else
          out("  " .. pal.dim("not used here:"))
          if opts.verbose then
            render_inventory_lines(pal, other, "  ", true)
          else
            render_inventory_compact(pal, other, "  ")
          end
        end
      end
      if empty then out("  " .. pal.dim("nothing to report")) end
    end
  end

  if scope == "relevant" then
    if not ws then
      if selected("toolchains") or selected("cache") or selected("sdks") or selected("editor") then
        out("")
        out(pal.dim("Machine inventory not checked outside a workspace — lw health --all lists"))
        out(pal.dim("toolchains, compiler caches, SDKs and editor tools."))
      end
    else
      local total, parts = 0, {}
      for _, a in ipairs(order) do
        local n = hidden[a]
        if n and n > 0 then
          total = total + n
          parts[#parts + 1] = a .. " " .. n
        end
      end
      if total > 0 then
        out("")
        out(pal.dim(total .. " other check" .. (total == 1 and "" or "s") .. " not relevant here ("
          .. table.concat(parts, ", ") .. ") — lw health "
          .. (area_list and (table.concat(area_list, " ") .. " ") or "") .. "--all"))
      end
    end
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- profile show — a `lw status` page narrowed to a single profile (§16.18)
-- ---------------------------------------------------------------------------

--- Keep only the diagnostics that concern one profile: its own bucket (the
--- `profile:<key>` diagnostic plus any `profile_proj:<key>:<project>` folded
--- into it by group_diagnostics), its configuration set (`set:<name>`), and the
--- configurations of the projects that set maps (`config:<proj>:…` for a mapped
--- project). Workspace-level entries (nil fold key) and everything about other
--- profiles/sets/projects are dropped, so the page never dumps the whole
--- workspace's diagnostics.
--- @param diags table[] Workspace:diagnostics() output
--- @param profile table the profile in view
--- @param ref_projects table<string, boolean> mapped project keys
--- @return table[] scoped diagnostics (same shape, a filtered subset)
local function scope_profile_diagnostics(diags, profile, ref_projects)
  local set_name = profile._configuration_set_name
  local scoped = {}
  for _, d in ipairs(diags) do
    local k = d.target_fold_key
    local keep = false
    if k then
      if k == "profile:" .. profile.key then
        keep = true
      elseif k:match("^profile_proj:([^:]+):") == profile.key then
        keep = true
      elseif set_name and k == "set:" .. set_name then
        keep = true
      else
        local proj = k:match("^config:([^:]+):")
        if proj and ref_projects[proj] then keep = true end
      end
    end
    if keep then scoped[#scoped + 1] = d end
  end
  return scoped
end
M._scope_profile_diagnostics = scope_profile_diagnostics

--- Build the `lw profile show` page body for one resolved profile — a `lw
--- status` page narrowed to this profile and only what it references. Pure and
--- color-injectable (same split as `profile_list_rows` / `status_profile_rows`)
--- so it is testable without a tty: it reuses the status-page machinery
--- (`status_palette`, `status_section`, `render_diagnostics`, `collect_targets`,
--- terminal-width-aware columns) by capturing their `out()` writes into a line
--- buffer, then returns the lines for the caller to print.
--- @param ws table workspace
--- @param profile table resolved profile
--- @param color boolean|nil force color on/off (nil = auto-detect stdout)
--- @return string[] lines
local function profile_show_rows(ws, profile, color)
  if color == nil then color = stdout_supports_color() end
  local pal = status_palette(color)
  local tw = term_width()
  local MAX = 6

  -- Diagnostics for the whole workspace, then narrowed to this profile. A
  -- broken diagnostics pass collapses to "none" and never breaks the page.
  local ok_d, diags = pcall(function() return ws:diagnostics() end)
  if not ok_d or type(diags) ~= "table" then diags = {} end
  local pps = profile:projects()
  local ref_projects = {}
  for _, pp in ipairs(pps) do ref_projects[pp:project_key()] = true end
  local scoped = scope_profile_diagnostics(diags, profile, ref_projects)
  local grouped = group_diagnostics(scoped)

  local set_name = profile._configuration_set_name
  local ok_cs, cs = pcall(function() return profile:config_set() end)
  if not ok_cs then cs = nil end
  local active = (profile.key == ws._active_profile_key)

  -- Reuse the status renderers, which write via out(); capture those writes and
  -- split them back into lines. Nesting-safe (restores the previous io.write,
  -- which under test is the spec's own capture).
  local buf = {}
  local real_write = io.write
  io.write = function(s) buf[#buf + 1] = s end
  local ok, err = pcall(function()
    -- 1. Header — Profile <name> (+ `*`/green when active) + (set <name>) + a
    --    buildable/unbuildable note. Name column takes the width left over.
    local valid, reasons = true, nil
    if profile.is_valid then valid, reasons = profile:is_valid() end
    local note = valid and pal.dim("· buildable")
      or pal.warn("· unbuildable" .. (reasons and #reasons > 0
        and (" — " .. reasons[1] .. (#reasons > 1 and " (+" .. (#reasons - 1) .. " more)" or "")) or ""))
    local suffix = "   " .. pal.dim("(set " .. (set_name or "none") .. ")") .. "   " .. note
    -- Stable positional number (same one `lw profiles` / `lw status` show).
    local num = tostring(profile_numbering(ws).number[profile.key] or "?")
    local overhead = #"Profile" + 1 + #num + 2 + 2 + 3 + #("(set " .. (set_name or "none") .. ")") + 3 + 14
    local nw = math.max(12, tw - overhead)
    local name = trunc(profile.key, nw)
    local painted_name = active and pal.active("* " .. name) or ("  " .. name)
    out(pal.title("Profile") .. " " .. num .. "  " .. painted_name .. suffix)
    M._describe_block(profile.description)
    -- The profile's resolved compiler cache (§16.18) — the same `Cache` line
    -- `lw status` renders under the active profile; nothing for a profile with
    -- no C/C++-caching project.
    render_cache_line(pal, profile, false)

    -- 2. Diagnostics — scoped to this profile (top section; nothing when empty).
    render_diagnostics(pal, scoped)

    -- 3. Configuration set — the set name and its project→configuration mappings.
    out("")
    out(pal.title("Configuration set") .. " " .. pal.dim("(" .. (set_name or "none") .. ")")
      .. M._summary_suffix(#"Configuration set" + 3 + require("loomworks.description").width(set_name or "none"),
        cs and cs.description, tw, pal)
      .. inline_markers(pal, set_name and grouped.by_key["set:" .. set_name] or nil))
    if cs and cs.mappings and next(cs.mappings) then
      local map_rows = {}
      for project, cfg in pairs(cs.mappings) do
        map_rows[#map_rows + 1] = "  " .. project.key .. " → " .. (cfg.name or "?")
      end
      table.sort(map_rows)
      for _, r in ipairs(map_rows) do out(r) end
    elseif cs then
      out("  " .. pal.dim("(no mappings)"))
    else
      out("  " .. pal.dim("(profile pins no configuration set)"))
    end

    -- 4. Projects — only the projects this set maps: key, type, the specific
    --    configuration, the resolved tool, and build state / build dir. The name
    --    column is content-sized and capped to the terminal.
    local pj_longest = 0
    for _, pp in ipairs(pps) do pj_longest = math.max(pj_longest, #tostring(pp:project_key())) end
    local pj_name_w = fit_column(pj_longest, tw, 2 + 1 + 8 + 1 + 44 + 4, 8)
    status_section(pal, "Projects", pps, MAX, function(pp)
      local proj = pp._project
      local t = (proj and (proj.type or (proj._module and proj._module.id))) or "?"
      local cfg = pp:variant_name() or "?"
      local tool = pp.tool_object and pp:tool_object() or nil
      local tool_s = (tool and tool.key) or "(none)"
      local state = pp.status and pp:status() or "?"
      local head = string.format("  %-" .. pj_name_w .. "s %-8s cfg=%s  tool=%s  ",
        trunc(pp:project_key(), pj_name_w), trunc(t, 8), cfg, tool_s)
        .. pal.dim("[" .. state .. "]")
      local bd = pp.build_dir and pp:build_dir() or nil
      if bd then
        head = head .. "\n      " .. pal.dim(trunc(bd:gsub("\\", "/"), math.max(20, tw - 6)))
      end
      return head .. inline_markers(pal, grouped.by_project[pp:project_key()])
    end, "lw project list", "project details · lw project show <project>")

    -- 5. Tools — the profile's resolved toolchain per module type it spans.
    local seen, tool_items = {}, {}
    for _, pp in ipairs(pps) do
      local proj = pp._project
      local mid = proj and ((proj._module and proj._module.id) or proj.type)
      if mid and not seen[mid] then
        seen[mid] = true
        tool_items[#tool_items + 1] = { mod = mid, tool = profile.tool_for and profile:tool_for(mid) or nil }
      end
    end
    table.sort(tool_items, function(a, b) return a.mod < b.mod end)
    status_section(pal, "Tools", tool_items, MAX, function(it)
      local t = it.tool
      local key = (t and t.key) or "(none)"
      local label = t and t.label
      return string.format("  %-8s %s", it.mod, key) .. (label and ("   " .. pal.dim(label)) or "")
    end, "lw tools", "detected toolchains · lw tools")

    -- 6. Targets — the profile's launchable targets, default marked `*`+green,
    --    exactly as the status Targets section renders them.
    local ok_t, tinfo = pcall(collect_targets, ws, profile)
    if not ok_t or not tinfo then tinfo = { rows = {}, unconfigured = {}, incomplete = false } end
    local default_cwd
    local ok_lt, lt = pcall(function() return profile:default_target() end)
    if ok_lt and lt and lt:is_module_target() then default_cwd = lt:working_directory() end
    -- A non-active profile is named: the one-operand forms act on the active
    -- profile (spec §16.38).
    local pk = active and "" or (profile.key .. " ")
    local target_help = {
      "run a target · lw run " .. pk .. "<target>",
      "set this profile's default · lw target set " .. pk .. "<target>",
    }
    if tinfo.incomplete then
      table.insert(target_help, 1, "configure to list build targets · lw build"
        .. (active and "" or (" " .. profile.key)))
    end
    status_section(pal, "Targets", tinfo.rows, MAX, function(r)
      local base = string.format("%s %-30s (%s)", r.is_default and "*" or " ",
        trunc(r.label, 30), r.kind_label)
      local sum = M._summary_suffix(require("loomworks.description").width(base), r.description, nil, pal)
      if r.is_default then
        local line = pal.active(base) .. sum
        if default_cwd then line = line .. "   " .. pal.dim("cwd: " .. trunc(default_cwd, 30)) end
        if r.suffix then line = line .. pal.dim(r.suffix) end
        return line
      end
      return base .. sum .. (r.suffix and pal.dim(r.suffix) or "")
    end, "lw target", target_help)

    -- 7. Footer help — profile-level actions not already surfaced by the
    --    Targets section (which carries the run / set-default hints). A
    --    non-active profile is named explicitly: the operand-less forms act on
    --    the ACTIVE profile (spec §16.38, no dead ends).
    out("")
    local arg = active and "" or (" " .. profile.key)
    local footer = {
      "build / test · lw build" .. arg .. " · lw test" .. arg,
      "start over (delete its build dirs) · lw reset" .. arg,
      active and "switch the profile · lw profile select"
        or ("make it the default · lw profile select " .. profile.key),
    }
    -- Descriptions are offered once, here, when none is set (§16.38).
    local desc = profile.description
    if type(desc) ~= "string" or not desc:match("%S") then
      footer[#footer + 1] = "describe it · lw profile describe " .. profile.key .. ' -m "<text>"'
    end
    for _, h in ipairs(footer) do out("  " .. paint_help(pal, h)) end
  end)
  io.write = real_write
  if not ok then error(err) end

  local text = table.concat(buf)
  local lines = {}
  for line in text:gmatch("(.-)\n") do lines[#lines + 1] = line end
  return lines
end
M._profile_show_rows = profile_show_rows

--- Resolve which profile `lw profile show` displays. A named profile resolves
--- through the shared matcher (number index → exact key → unique boundary
--- substring); an unknown name is an error that names it and points at `lw
--- profiles`. With no name it defaults to the ACTIVE profile (like `lw build` /
--- `lw run`); omitting it with no active profile is an error. Read-only, so —
--- unlike the build/manage resolver — it may use the active profile even in a
--- non-interactive host (§16.18).
--- @param ws table
--- @param name string|nil
--- @return table profile
local function resolve_profile_for_show(ws, name)
  local profiles = ws._profiles or {}
  if name then
    -- Same named matcher as build/run: number index → exact key → unique
    -- boundary substring (so `profile show clang-18` resolves a full key).
    local hit = match_profile_arg(ws, name)
    if hit then return hit end
    die("no profile named '" .. name .. "' — run `lw profile list` to list.")
  end
  local active = ws._active_profile_key
  if active then
    for _, p in ipairs(profiles) do if p.key == active then return p end end
  end
  die("no profile specified and no active profile — name one (`lw profile show <profile>`) " ..
    "or set one with `lw profile select`.")
end
M._resolve_profile_for_show = resolve_profile_for_show

--- `lw profile show [<profile>]` — a `lw status` page narrowed to one profile.
--- Loads the workspace (waits for tool detection, for accurate tool resolution
--- and buildability), resolves the profile (default = active), and prints it.
--- @param root string workspace root
--- @param profile_name string|nil
--- @return integer exit code
function M.cmd_profile_show(root, profile_name)
  local ws = read_workspace(root)
  local profile = resolve_profile_for_show(ws, profile_name)
  for _, line in ipairs(profile_show_rows(ws, profile)) do out(line) end
  return 0
end

-- ---------------------------------------------------------------------------
-- pull — fold another checkout's working copy into this one (SOURCE wins)
-- ---------------------------------------------------------------------------

-- user.json top-level keys carrying a map of independent items keyed by the
-- item's own identity (project key, set name, profile key, …). Pull unions
-- these per item-key with the SOURCE winning on collision, target-only kept.
local PULL_ITEM_MAPS = {
  "projects", "configuration_sets", "profiles", "sdks", "default_target",
}
-- Nested settings maps (debug: adapters -> language -> adapter; lsp: server ->
-- option -> value). Unioned per key at EVERY level so a source's entry for one
-- key never drops the target's siblings — pulling a `c++` debug adapter keeps
-- the target's `typescript` one. NOT wholesale-replaced.
local PULL_DEEP_MAPS = { "debug", "lsp" }
-- The sub-maps of `intent`, unioned one level deeper (per item key).
local PULL_INTENT_SUBS = { "projects", "configurations", "configuration_sets", "profiles" }
-- Which item maps a human summary reports on, and how each is labelled.
local PULL_SUMMARY = {
  { key = "projects", label = "Projects" },
  { key = "configuration_sets", label = "Configuration sets" },
  { key = "profiles", label = "Profiles" },
  { key = "sdks", label = "SDKs" },
}
-- Non-itemized keys whose changes the summary reports as one grouped line, so a
-- write (or --dry-run) that only touches settings is never blank about it.
local PULL_SETTINGS_REPORT = {
  { key = "default_target", label = "default targets" },
  { key = "debug", label = "debug adapters" },
  { key = "lsp", label = "lsp options" },
  { key = "intent", label = "publish intent" },
}

-- A non-empty sequence is a list (replaced wholesale on collision); dict-like
-- tables (including empty ones) are unioned key by key.
local function pull_is_list(t) return type(t) == "table" and #t > 0 end

-- Recursive per-key union: target-only keys survive, the source wins at leaves
-- and for lists, and two colliding dict values recurse so nested siblings are
-- preserved. Used for the nested settings maps (debug adapters, lsp options).
local function pull_deep_union(target, source)
  local r = {}
  if type(target) == "table" then for k, v in pairs(target) do r[k] = v end end
  for k, sv in pairs(source) do
    local tv = r[k]
    if type(tv) == "table" and type(sv) == "table"
        and not pull_is_list(tv) and not pull_is_list(sv) then
      r[k] = pull_deep_union(tv, sv)
    else
      r[k] = sv
    end
  end
  return r
end

--- Item-level union of two user.json tables with the SOURCE winning on a key
--- collision, non-destructive toward target-only items. Deliberately the
--- OPPOSITE winner from workspace.merge_configs (target/user-wins) — pull's
--- caller is explicitly asking for the source's config. The target keeps its
--- own workspace identity and per-machine selections — the active profile, the
--- workspace `name`, and the `device` map are never pulled (they are carried
--- over from the target and never overwritten). Returns the merged table
--- (sharing sub-table references with the inputs — safe, since callers write it
--- out and discard the inputs).
--- @param target table|nil target (current) working copy
--- @param source table|nil source working copy
--- @return table merged
function M._pull_merge(target, source)
  target = target or {}
  source = source or {}
  local merged = {}
  for k, v in pairs(target) do merged[k] = v end
  merged._meta = nil -- re-stamped by user.save; irrelevant to the merge

  -- active_profile, name, and device are carried over from the target above and
  -- never overwritten — each checkout keeps its own identity and per-machine
  -- selections.

  for _, map in ipairs(PULL_ITEM_MAPS) do
    local s = source[map]
    if type(s) == "table" then
      local dst = {}
      if type(merged[map]) == "table" then
        for k, v in pairs(merged[map]) do dst[k] = v end -- target-only kept
      end
      for k, v in pairs(s) do dst[k] = v end             -- SOURCE wins
      merged[map] = dst
    end
  end

  -- Configuration-set descriptions (spec §1.10) live in a sidecar but belong
  -- to their set: a pulled set brings its source entry, or its absence;
  -- target-only sets keep theirs.
  if type(source.configuration_sets) == "table" then
    local dst = {}
    if type(merged.configuration_set_descriptions) == "table" then
      for k, v in pairs(merged.configuration_set_descriptions) do dst[k] = v end
    end
    local sd = type(source.configuration_set_descriptions) == "table"
      and source.configuration_set_descriptions or {}
    for name in pairs(source.configuration_sets) do dst[name] = sd[name] end
    merged.configuration_set_descriptions = next(dst) and dst or nil
  end

  if type(source.intent) == "table" then
    local dst = {}
    if type(merged.intent) == "table" then
      for k, v in pairs(merged.intent) do dst[k] = v end
    end
    for _, sub in ipairs(PULL_INTENT_SUBS) do
      local sv = source.intent[sub]
      if type(sv) == "table" then
        local sd = {}
        if type(dst[sub]) == "table" then for k, v in pairs(dst[sub]) do sd[k] = v end end
        for k, v in pairs(sv) do sd[k] = v end
        dst[sub] = sd
      end
    end
    merged.intent = dst
  end

  for _, key in ipairs(PULL_DEEP_MAPS) do
    if type(source[key]) == "table" then
      merged[key] = pull_deep_union(merged[key], source[key])
    end
  end

  return merged
end

--- Classify one item map into added / updated / unchanged / target-only (kept)
--- name lists, comparing the source against the target working copy.
local function pull_classify(target, source, map)
  local s = (type(source[map]) == "table") and source[map] or {}
  local t = (type(target[map]) == "table") and target[map] or {}
  local added, updated, unchanged, kept = {}, {}, {}, {}
  -- A set's sidecar description is part of the set (spec §1.10).
  local function same_sidecar(k)
    if map ~= "configuration_sets" then return true end
    local sd = type(source.configuration_set_descriptions) == "table" and source.configuration_set_descriptions or {}
    local td = type(target.configuration_set_descriptions) == "table" and target.configuration_set_descriptions or {}
    return vim.deep_equal(sd[k], td[k])
  end
  for k, sv in pairs(s) do
    if t[k] == nil then added[#added + 1] = k
    elseif vim.deep_equal(sv, t[k]) and same_sidecar(k) then unchanged[#unchanged + 1] = k
    else updated[#updated + 1] = k end
  end
  for k in pairs(t) do if s[k] == nil then kept[#kept + 1] = k end end
  table.sort(added); table.sort(updated); table.sort(unchanged); table.sort(kept)
  return { added = added, updated = updated, unchanged = unchanged, kept = kept }
end

--- Resolve the source and target checkouts, load both working copies, and
--- compute the source-wins merge — all without writing or exiting. Returns
--- `(plan, err)`; on success `plan` carries source_root, target_root, the
--- target user.json path, the merged table, a `changed` flag, and per-category
--- summaries. `opts.git` is injectable for tests (same contract as git_query).
--- @param opts { cwd?: string, source?: string, git?: function }
--- @return table|nil plan, string|nil err
function M._plan_pull(opts)
  opts = opts or {}
  local cwd = opts.cwd or user_cwd()
  local git = opts.git or M._git_query_required
  local user = require("loomworks.user")

  -- TARGET = the current checkout's root. Prefer the git worktree top (it
  -- resolves in a fresh worktree that has no workspace files yet); fall back to
  -- an already-initialized workspace root when not in a git repo.
  local target_root, terr = git(cwd, { "rev-parse", "--show-toplevel" })
  -- A slow git is not "not a repo": never fall back to the enclosing workspace.
  if terr == "timeout" then
    return nil, string.format("git did not answer within %g s — could not determine the current checkout",
      M.GIT_REQUIRED_TIMEOUT_MS / 1000)
  end
  target_root = (target_root and target_root ~= "")
      and (target_root:gsub("\\", "/"):gsub("/+$", "")) or find_root(cwd)
  if not target_root then
    return nil, "cannot determine the current checkout — run `lw pull` inside a " ..
      "git worktree or an initialized workspace"
  end

  -- SOURCE: an explicit directory, else the auto-detected main worktree.
  local source_root
  if opts.source and opts.source ~= "" then
    local abs = resolve_abs(opts.source, cwd)
    if not abs then return nil, "source directory does not exist: " .. opts.source end
    local st = uv.fs_stat(abs)
    if not (st and st.type == "directory") then
      return nil, "source is not a directory: " .. opts.source
    end
    source_root = abs
  else
    local main, _, reason = M._main_worktree({ dir = cwd, git = git })
    if reason == "git-timeout" then
      return nil, string.format("git did not answer within %g s — could not resolve the main worktree " ..
        "to pull from.\n  retry, or pass the checkout to pull from:  lw pull <path>",
        M.GIT_REQUIRED_TIMEOUT_MS / 1000)
    end
    if not main then
      return nil, "no source given and this is not a linked git worktree.\n" ..
        "  pass the checkout to pull from:  lw pull <path>"
    end
    source_root = (main:gsub("\\", "/"):gsub("/+$", ""))
  end

  -- Same-checkout guard. The two roots reach here canonicalized INCONSISTENTLY:
  -- target_root is the git top-level (forward-slashed only), while an explicit
  -- source_root comes through resolve_abs -> uv.fs_realpath (and the auto-
  -- detected main worktree is likewise not realpath'd). On some checkouts the
  -- git top-level and the realpath'd source spell the SAME directory
  -- differently — short (8.3) names, junctions, or symlinks — which norm_cmp
  -- (slashes/case only) cannot reconcile. CI Windows under D:\a\... exposes
  -- this. Realpath BOTH sides (falling back to the raw string, preserving the
  -- normal case) before comparing.
  local function canon_root(r)
    return norm_cmp(uv.fs_realpath(r) or r)
  end
  if canon_root(source_root) == canon_root(target_root) then
    return nil, "source and target are the same checkout (" .. source_root ..
      ") — nothing to pull"
  end

  -- The source must carry a working copy. user.load returns defaults for a
  -- missing file, so test the file itself for a precise error.
  local src_user_path = user.filepath(source_root)
  if not uv.fs_stat(src_user_path) then
    return nil, "nothing to pull from " .. source_root ..
      " (no .nvim/loomworks.user.json)"
  end
  -- Only a working copy signed by this machine is read, on either side
  -- (spec §16.25, §17.5): a pull must never turn an untrusted file into a
  -- signed one.
  local function untrusted(root_dir, status, detail)
    -- A newer-schema working copy (spec §2.7) is not untrusted: say so.
    if status == "newer" then return detail end
    return "the working copy in " .. root_dir .. " is " ..
      (status == "unsigned" and "not signed by this machine" or "modified outside loomworks") ..
      " — review it there first:  lw trust   (run in " .. root_dir .. ")"
  end
  local src_data, src_status, src_detail = user.load(source_root)
  if not src_data then
    -- A source signed elsewhere usually came from another machine (§16.39).
    local msg = untrusted(source_root, src_status, src_detail)
    if src_status ~= "newer" then
      msg = msg .. "\n  copied from another machine? run `lw export` there and `lw import` here"
    end
    return nil, msg
  end

  local tgt_user_path = user.filepath(target_root)
  local tgt_data = {}
  if uv.fs_stat(tgt_user_path) then
    local d, st, detail = user.load(target_root)
    if not d then return nil, untrusted(target_root, st, detail) end
    tgt_data = d
  end

  local merged = M._pull_merge(tgt_data, src_data)

  -- "Changed?" is a whole-file comparison so every pulled key (items, intent,
  -- settings) counts; nothing is written when the merge is a no-op.
  local tgt_cmp = {}
  for k, v in pairs(tgt_data) do tgt_cmp[k] = v end
  tgt_cmp._meta = nil
  local changed = not vim.deep_equal(merged, tgt_cmp)

  local summary = {}
  for _, cat in ipairs(PULL_SUMMARY) do
    summary[cat.key] = pull_classify(tgt_data, src_data, cat.key)
  end

  -- Non-itemized keys (default targets, debug adapters, lsp options, publish
  -- intent) — reported as a grouped line so a settings-only pull is never blank.
  local settings = {}
  for _, s in ipairs(PULL_SETTINGS_REPORT) do
    if not vim.deep_equal(merged[s.key], tgt_data[s.key]) then
      settings[#settings + 1] = s.label
    end
  end

  return {
    source_root = source_root,
    target_root = target_root,
    target_user_path = tgt_user_path,
    src_user_path = src_user_path,
    merged = merged,
    changed = changed,
    summary = summary,
    settings = settings,
  }
end

--- The head of `list`, capped at `cap` items, with a `, +N more` tail when the
--- list is longer. Shared by the pull summary renderers.
local function pull_names(list, cap)
  local head = {}
  for i = 1, math.min(#list, cap) do head[#head + 1] = list[i] end
  local s = table.concat(head, ", ")
  if #list > cap then s = s .. ", +" .. (#list - cap) .. " more" end
  return s
end

--- Print the per-category (Projects / sets / profiles / SDKs) and settings
--- change lines of a pull `plan`, each indented two spaces. Shared by `lw pull`
--- and `lw worktree add`'s auto-pull so both report identically.
local function print_pull_changes(plan)
  for _, cat in ipairs(PULL_SUMMARY) do
    local c = plan.summary[cat.key]
    if #c.added + #c.updated + #c.unchanged + #c.kept > 0 then
      local parts = {}
      if #c.added > 0 then parts[#parts + 1] = #c.added .. " added (" .. pull_names(c.added, 6) .. ")" end
      if #c.updated > 0 then parts[#parts + 1] = #c.updated .. " updated (" .. pull_names(c.updated, 6) .. ")" end
      if #c.unchanged > 0 then parts[#parts + 1] = #c.unchanged .. " unchanged" end
      if #c.kept > 0 then parts[#parts + 1] = #c.kept .. " kept local-only (" .. pull_names(c.kept, 6) .. ")" end
      out(string.format("  %-19s %s", cat.label .. ":", table.concat(parts, ", ")))
    end
  end
  if #plan.settings > 0 then
    out(string.format("  %-19s %s updated", "Settings:", table.concat(plan.settings, ", ")))
  end
end

--- `lw pull [<source>] [--dry-run]` — fold another checkout's working config
--- into this one so a fresh worktree inherits its profiles / sets / projects.
--- Source-wins, non-destructive, item-level; never publishes, never touches the
--- cache, never pulls the active profile. `--dry-run` reports the plan only.
--- @param args string[]
--- @param opts? table injectable `{ cwd, git }` for tests (nil in production).
function M.cmd_pull(args, opts)
  opts = opts or {}
  local dry_run, source = false, nil
  for i = 2, #args do
    local v = args[i]
    if v == "--dry-run" or v == "-n" then
      dry_run = true
    elseif v:sub(1, 1) == "-" then
      die("unknown pull option '" .. v .. "' — usage: lw pull [<source>] [--dry-run]")
    elseif not source then
      source = v
    else
      die("unexpected argument '" .. v .. "' — usage: lw pull [<source>] [--dry-run]")
    end
  end

  local plan, err = M._plan_pull({ source = source, cwd = opts.cwd, git = opts.git })
  if not plan then die(err) end

  out((dry_run and "pull (dry run) from " or "pull from ") .. plan.source_root)
  out("  into " .. plan.target_root)
  out("")
  print_pull_changes(plan)

  if not plan.changed then
    out("")
    out("already up to date — nothing to pull.")
    return 0
  end
  if dry_run then
    out("")
    out("(dry run — nothing written; re-run without --dry-run to apply)")
    return 0
  end

  -- Write under the target's workspace operation lock (spec §19.3), planned
  -- again under it so a concurrent multi-file operation is not overwritten.
  local op_lock = require("loomworks.op_lock")
  local tok, lmsg = op_lock.acquire(plan.target_root, "pull")
  if not tok then die(lmsg) end
  if tok.recovered then errw("lw: " .. tok.recovered .. "\n") end
  on_exit(function() op_lock.release(tok) end)
  plan, err = M._plan_pull({ source = source, cwd = opts.cwd, git = opts.git })
  if not plan then die(err) end
  local ok, serr = require("loomworks.user").save(plan.target_root, plan.merged)
  op_lock.release(tok)
  if not ok then die("could not write working copy: " .. tostring(serr)) end
  out("")
  out("wrote " .. plan.target_user_path)
  out("Active profile is unchanged (not pulled). " ..
    "`lw profile list` to list, `lw build <profile>` to build.")
  return 0
end

--- The bracketed branch label for a worktree record: `[branch]`, `(bare)` for a
--- bare entry, or `[detached <sha>]` when a detached HEAD; a locked worktree
--- gets a trailing `(locked)`.
local function worktree_branch_label(r)
  local label
  if r.bare then
    label = "(bare)"
  elseif r.branch then
    label = "[" .. r.branch .. "]"
  elseif r.detached then
    label = r.head and ("[detached " .. r.head:sub(1, 7) .. "]") or "[detached]"
  else
    label = "[unknown]"
  end
  if r.locked then label = label .. " (locked)" end
  return label
end

--- `lw worktree [list]` — list every git worktree of the current repo, its
--- branch, whether it is the main / current worktree, and whether loomworks is
--- initialised there (a workspace file present). Read-only; runs before the
--- workspace guard so it works from a worktree with no workspace of its own.
--- Requires git — unlike the status hint it errors (non-zero) when git is
--- unavailable or the cwd is not a git repo, rather than degrading silently.
--- `opts.{dir,git,stat,color}` are injectable for tests.
--- @param args string[]
--- @param opts? table
function M.cmd_worktree(args, opts)
  opts = opts or {}
  local sub = args and args[2]
  if sub == "add" then
    return M.cmd_worktree_add(args, opts)
  end
  if sub and sub ~= "list" then
    die("unknown worktree subcommand '" .. tostring(sub) ..
      "' — usage: lw worktree [list|add]")
  end
  local git = opts.git or M._git_query_required
  local stat = opts.stat or uv.fs_stat
  local dir = opts.dir or user_cwd()
  local color = opts.color
  if color == nil then color = stdout_supports_color() end
  local paint = painter(color)

  local records, top, reason = M._worktree_list({ dir = dir, git = git })
  if not records then
    if reason == "git-missing" then
      die("git is not available — `lw worktree` needs git to list worktrees")
    elseif reason == "git-timeout" then
      die(string.format("git did not answer within %g s — `lw worktree` could not list worktrees",
        M.GIT_REQUIRED_TIMEOUT_MS / 1000))
    end
    die("not in a git repository — run `lw worktree` inside a git worktree")
  end

  -- Build plain rows first so the column widths are computed from visible text,
  -- never from color escapes.
  local rows = {}
  for i, r in ipairs(records) do
    rows[#rows + 1] = {
      current = norm_cmp(r.path) == norm_cmp(top),
      path = r.path,
      main = (i == 1) and "main" or "",
      branch = worktree_branch_label(r),
      inited = stat_has_workspace(stat, r.path) and true or false,
    }
  end

  local pathw, branchw = 0, 0
  for _, row in ipairs(rows) do
    if #row.path > pathw then pathw = #row.path end
    if #row.branch > branchw then branchw = #row.branch end
  end
  local function padr(s, w) return s .. string.rep(" ", math.max(0, w - #s)) end

  out(string.format("%d worktree%s", #rows, #rows == 1 and "" or "s"))
  for _, row in ipairs(rows) do
    -- Color-safe: the current marker is a fixed-width 1 char and the status is
    -- the last column, so wrapping either in escapes never shifts a column.
    local cur = row.current and paint("*") or " "
    local status = row.inited and paint("workspace") or "no workspace"
    out("  " .. cur .. " " .. padr(row.path, pathw) ..
      "  " .. padr(row.main, 4) ..
      "  " .. padr(row.branch, branchw) ..
      "  " .. status)
  end
  -- `worktree add` is everyday (spec §16.38): name it under the listing.
  out("")
  out("  " .. paint_help(status_palette(color), "new worktree with this config · lw worktree add <branch>"))
  return 0
end

--- `lw worktree add <branch> [<start-point>] [--no-pull]` — create a git
--- worktree and, unless `--no-pull`, fold the MAIN checkout's working config
--- into it (§16.25/§16.27) so the new tree is ready to build.
---
--- Path: `<main>/.worktrees/<branch>` with the FULL branch path mirrored as
--- directories (git creates the nested dirs), so `feature/x` lands at
--- `.worktrees/feature/x`. `<main>` is resolved via `_main_worktree`, so `add`
--- works from ANY worktree and the new tree always registers under the main
--- repo. A NEW branch is created with an explicit `-b <branch>` (never git's
--- basename default, which would mis-name a slashed branch); an EXISTING branch
--- is checked out.
---
--- Git-required and NON-DESTRUCTIVE: it never deletes or overwrites; a
--- pre-existing target path is refused, and if the auto-pull fails AFTER the
--- worktree is created the worktree is KEPT (the user runs `lw pull` by hand),
--- with a non-zero exit so the partial state is visible.
--- @param args string[] full argv (args[1]=="worktree", args[2]=="add", ...)
--- @param opts? table injectable `{ dir, git, git_exec, color }` for tests
function M.cmd_worktree_add(args, opts)
  opts = opts or {}
  local git = opts.git or M._git_query_required
  local git_run = opts.git_exec or git_exec
  local dir = opts.dir or user_cwd()
  local color = opts.color
  if color == nil then color = stdout_supports_color() end
  local paint = painter(color)
  local usage = "usage: lw worktree add <branch> [<start-point>] [--no-pull]"

  -- Parse `<branch> [<start-point>]` with a `--no-pull` flag anywhere.
  local no_pull, branch, start_point = false, nil, nil
  for i = 3, #args do
    local v = args[i]
    if v == "--no-pull" then
      no_pull = true
    elseif v == "--pull" then
      no_pull = false
    elseif v:sub(1, 1) == "-" then
      die("unknown option '" .. v .. "' — " .. usage)
    elseif not branch then
      branch = v
    elseif not start_point then
      start_point = v
    else
      die("unexpected argument '" .. v .. "' — " .. usage)
    end
  end
  if not branch or branch == "" then
    die("missing <branch> — " .. usage)
  end

  -- Resolve the MAIN worktree (works from any linked worktree). Git-required:
  -- unlike the status hint, an absent git or non-repo cwd is an explicit error.
  local main, _, reason = M._main_worktree({ dir = dir, git = git })
  if not main then
    if reason == "git-missing" then
      die("git is not available — `lw worktree add` needs git")
    elseif reason == "git-timeout" then
      die(string.format("git did not answer within %g s — `lw worktree add` could not resolve the main worktree",
        M.GIT_REQUIRED_TIMEOUT_MS / 1000))
    end
    die("not in a git repository — run `lw worktree add` inside a git worktree")
  end
  main = (main:gsub("\\", "/"):gsub("/+$", ""))

  -- Target: `<main>/.worktrees/<branch>`, the full branch path mirrored as
  -- directories. Normalize any backslashes a user typed in the branch to '/'.
  local rel = branch:gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
  local path = main .. "/.worktrees/" .. rel

  -- Never clobber: refuse a pre-existing target (git also refuses, but a
  -- pre-check yields a clean message and never risks touching existing content).
  if uv.fs_stat(path) then
    die("target path already exists: " .. path .. " — refusing to clobber it")
  end

  -- Does the branch already exist? rev-parse returns the sha (truthy) or nil.
  local exists = git(main, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }) ~= nil

  -- NEW branch: create it explicitly with `-b` so a slashed name stays whole
  -- (git's basename default would name `feature/x` just `x`). EXISTING branch:
  -- check it out (git errors if it is already checked out elsewhere).
  local gargs
  if exists then
    gargs = { "worktree", "add", path, branch }
  else
    gargs = { "worktree", "add", "-b", branch, path }
    if start_point and start_point ~= "" then gargs[#gargs + 1] = start_point end
  end

  local res = git_run(main, gargs)
  if not res then
    die("`git worktree add` did not complete (git missing or timed out)")
  end
  if res.code ~= 0 then
    local msg = (res.stderr or ""):gsub("%s+$", "")
    if msg == "" then msg = "git exited " .. tostring(res.code) end
    die("git worktree add failed:\n" .. msg)
  end

  out("created worktree " .. paint(path))
  out("  branch " .. branch .. (exists and " (existing)" or " (new)"))

  if no_pull then
    out("  pull skipped (--no-pull) — run `lw pull` here to fold in main's config")
    return 0
  end

  -- Auto-pull: fold MAIN's working config into the fresh worktree (source =
  -- main, target = the new path). A main with NO working copy is "nothing to
  -- pull" — not a failure; the worktree stays and we succeed.
  local user = require("loomworks.user")
  if not uv.fs_stat(user.filepath(main)) then
    out("  pull skipped — " .. main .. " has no working config to pull")
    return 0
  end

  local plan, perr = M._plan_pull({ cwd = path, source = main, git = git })
  if not plan then
    -- The worktree exists; a pull failure must NOT remove it (non-destructive).
    out("  worktree kept — auto-pull could not run")
    die("auto-pull failed: " .. tostring(perr) ..
      "\n  the worktree was created at " .. path ..
      "\n  run `lw pull` inside it to fold in main's config")
  end

  out("")
  out("pulled config from " .. main .. ":")
  if not plan.changed then
    out("  nothing to pull (main's config is empty)")
    return 0
  end
  print_pull_changes(plan)
  local ok, serr = user.save(plan.target_root, plan.merged)
  if not ok then
    out("  worktree kept — auto-pull could not write the working copy")
    die("auto-pull failed: could not write working copy: " .. tostring(serr) ..
      "\n  the worktree was created at " .. path ..
      "\n  run `lw pull` inside it to retry")
  end
  out("wrote " .. plan.target_user_path)
  return 0
end

--- Human-readable age, e.g. "45s", "12m", "3h", "2d".
local function human_age(secs)
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then return math.floor(secs / 60) .. "m" end
  if secs < 86400 then return math.floor(secs / 3600) .. "h" end
  return math.floor(secs / 86400) .. "d"
end

--- One `lw tools` line per tool: "  <key>   <label>  [langs]". The key column is
--- sized to the longest key in the list (floor 26, so short lists keep their
--- familiar layout); the label follows after a three-space gap, so a long key
--- (e.g. ninja-clang-cl-17-enterprise) never runs into it. Pure; exported for tests.
--- @param tools table[] Tool-like objects ({ key?, label?, languages? })
--- @return string[]
local function tool_rows(tools)
  local key_w = 26
  for _, t in ipairs(tools) do key_w = math.max(key_w, #(t.key or "(default)")) end
  local rows = {}
  for _, t in ipairs(tools) do
    local langs = (t.languages and #t.languages > 0)
        and ("  [" .. table.concat(t.languages, ", ") .. "]") or ""
    local label = t.label and ("   " .. t.label) or ""
    rows[#rows + 1] = string.format("  %-" .. key_w .. "s%s%s", t.key or "(default)", label, langs)
  end
  return rows
end
M._tool_rows = tool_rows

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

  -- daemon mode (§19.14): the projection, its tools a fresh `tools` query (or
  -- the cached detection with --cached); a scan refreshes the machine-level
  -- cache as the in-process scan does.
  local ws = M._read_projection(root, { tools = cached and ((read_tool_cache() or {}).tools_by_type or {}) or "query" })
  if ws and not cached then
    local needed = {}
    for _, p in ipairs(ws._projects or {}) do
      local t = p.type or (p._module and p._module.id)
      if t then needed[t] = true end
    end
    write_tool_cache(ws._tools_by_type or {}, needed)
  end
  ws = ws or load_workspace(root) -- served from cache or scanned per the mode
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
      for _, row in ipairs(tool_rows(tools)) do out(row) end
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

-- Canonical command names only — aliases (configuration, configuration-set, cs,
-- cfg, profiles, rm) dispatch but are deliberately kept out of completion.
local COMP_COMMANDS = {
  "status", "init", "project", "config", "configset",
  "profile", "tools", "build", "clean", "reset", "test", "run", "target", "launch", "publish",
  "export", "import", "pull", "worktree", "unlock", "settings", "completion", "version", "install", "self-update", "help",
  "sdk", "migrate", "health", "module", "bootstrap", "trust", "nuke", "device", "release-notes", "daemon",
  "cleanup", "release",
  "--no-input",
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
      topics[#topics + 1] = "cache"
      topics[#topics + 1] = "submodules"
      topics[#topics + 1] = "launcher"
      emit(topics)
    end
    return 0
  elseif cmd == "status" then
    if n == 1 then emit({ "--check", "--cache-stats" }) end
    return 0
  elseif cmd == "health" then
    -- The areas not yet given, then the flags (§16.36).
    local given, c = {}, {}
    for i = 2, n do given[a[i]] = true end
    for _, v in ipairs(require("loomworks.inventory").AREAS) do
      if not given[v] then c[#c + 1] = v end
    end
    for _, v in ipairs({ "--all", "--verbose", "--json" }) do
      if not given[v] then c[#c + 1] = v end
    end
    emit(c)
    return 0
  elseif cmd == "tools" then
    if n == 1 then emit({ "--cached" }) end
    return 0
  elseif cmd == "release-notes" then
    emit(M._release_notes_completions(a, n))
    return 0
  elseif cmd == "release" then
    if n == 1 then emit({ "query" }); return 0 end
    if a[n] == "--channel" then emit({ "stable", "unstable" }); return 0 end
    emit({ "--channel", "--json", "--timeout" })
    return 0
  elseif cmd == "bootstrap" then
    if n == 1 then emit({ "install", "upgrade", "--json", "--check" }); return 0 end
    if sub == "install" then
      if a[n] == "--channel" then emit({ "stable", "unstable" }); return 0 end
      emit({ "--version", "--latest", "--channel", "--pin-only", "--force" })
    elseif sub == "upgrade" then
      if a[n] == "--channel" then emit({ "stable", "unstable" }); return 0 end
      emit({ "--channel", "--pin-only", "--force" })
    end
    return 0
  elseif cmd == "daemon" then
    if n == 1 then emit(require("loomworks.daemon.command").SUBS) end
    return 0
  elseif cmd == "cleanup" then
    if a[n] == "--pinned-older-than" then emit({ "30d", "90d" }); return 0 end
    local c = {}
    for _, v in ipairs({ "--dry-run", "--yes", "--all", "--pinned-older-than" }) do
      if not has(a, v) then c[#c + 1] = v end
    end
    emit(c)
    return 0
  elseif cmd == "settings" then
    if n == 1 then emit({ "list", "get", "set", "unset" }) end
    if n == 2 and has({ "get", "set", "unset" }, sub) then
      emit({ "dev-lua", "default-source", "release-url", "module-index", "channel", "release-notes",
        "runtime-mode", "daemon-idle-timeout", "runtime-busy-wait" })
    end
    if n == 3 and sub == "set" and a[3] == "release-notes" then emit({ "on", "off" }) end
    if n == 3 and sub == "set" and a[3] == "runtime-mode" then emit({ "in-process", "daemon" }) end
    return 0
  elseif cmd == "build" and n >= 2 and a[n] == "--target" then
    -- `lw build <profile> --target <TAB>`: the named profile's parsed build
    -- targets (read from its configured build dirs; none before a configure),
    -- bare and in the project-qualified form `lw target` lists (§16.4).
    local ws_c = comp_ws(root)
    local names = {}
    for _, p in ipairs(ws_c and ws_c._profiles or {}) do
      if p.key == a[2] then
        for _, pp in ipairs(p:projects()) do
          local unit = pp._config_unit
          pcall(ensure_unit_targets, ws_c, unit)
          for id in pairs(unit and type(unit.targets) == "table" and unit.targets or {}) do
            names[#names + 1] = id
            if pp._project then names[#names + 1] = pp._project.key .. ":" .. id end
          end
        end
      end
    end
    emit(sorted_unique(names))
    return 0
  elseif cmd == "build" and n >= 2 and not has(a, "--") then
    emit({ "--target", "--force", "--reconfigure", "--verbose" })
    return 0
  elseif cmd == "build" or cmd == "test" or cmd == "clean" then
    if n == 1 then
      local ws = comp_ws(root)
      local names = comp_profile_names(ws)
      for _, s in ipairs(comp_set_names(ws)) do names[#names + 1] = s end -- onboarding form
      emit(sorted_unique(names))
    end
    return 0
  elseif cmd == "reset" then
    if n == 1 then
      local names = comp_profile_names(comp_ws(root))
      names[#names + 1] = "--all"
      emit(sorted_unique(names))
    end
    return 0
  elseif cmd == "trust" then
    emit({ "--discard", "--yes" })
    return 0
  elseif cmd == "nuke" then
    emit({ "-y" })
    return 0
  elseif cmd == "unlock" then
    if n == 1 then
      local names = comp_profile_names(comp_ws(root)); names[#names + 1] = "--all"
      emit(sorted_unique(names))
    end
    return 0
  elseif cmd == "pull" then
    -- The source is a checkout directory; let the shell complete paths.
    if n == 1 then out("__dirs__") end
    return 0
  elseif cmd == "export" then
    if n >= 2 and (a[n] == "-o" or a[n] == "--output") then out("__files__"); return 0 end
    emit({ "--published", "--no-profiles", "-o" })
    return 0
  elseif cmd == "import" then
    if n == 1 then out("__files__") end
    if n >= 2 then emit({ "--dry-run", "--yes", "--take-name" }) end
    return 0
  elseif cmd == "worktree" then
    if n == 1 then emit({ "list", "add" }) end
    -- `add <branch> [<start-point>] [--no-pull]`: the branch/start-point are free
    -- values (a new branch has no ref to complete); only offer the flag.
    if sub == "add" and n >= 2 then emit({ "--no-pull" }) end
    return 0
  elseif cmd == "run" then
    if n == 1 then
      -- First operand is a target (1-operand form) or a profile (2-operand
      -- form); offer both. Build targets need a build, so only launch configs.
      local ws_c = comp_ws(root)
      emit(sorted_unique(vim.list_extend(comp_launch_names(ws_c), comp_profile_names(ws_c))))
    elseif n == 2 then
      emit(sorted_unique(comp_launch_names(comp_ws(root))))      -- <target> on the named profile
    end
    return 0
  elseif cmd == "launch" then
    if n == 1 then emit({ "list", "add", "set", "show", "remove", "rename", "describe" }); return 0 end
    if n == 2 and has({ "add", "create", "set", "edit", "show", "remove", "rm", "list",
        "rename", "mv", "describe" }, sub) then
      emit(comp_project_names(comp_ws(root))); return 0                     -- <project>
    end
    if n == 3 and has({ "set", "edit", "show", "remove", "rm", "rename", "mv", "describe" }, sub) then
      emit(comp_launch_names(comp_ws(root), a[3]))                         -- <name>
    end
    if n >= 4 and sub == "describe" then emit({ "-m", "-F", "-e", "--clear", "--json" }) end
    return 0
  elseif cmd == "project" then
    if n == 1 then emit({ "add", "remove", "list", "show", "set", "unset", "describe", "publish" }); return 0 end
    if sub == "describe" then
      if n == 2 then emit(comp_project_names(comp_ws(root))) else emit({ "-m", "-F", "-e", "--clear", "--json" }) end
      return 0
    end
    if sub == "add" or sub == "create" then
      if n == 2 then out("__dirs__") -- <path>
      elseif n == 3 then emit(require("loomworks.modules").list()) end -- [type]
    elseif (sub == "remove" or sub == "rm" or sub == "show" or sub == "publish"
        or sub == "set" or sub == "unset") and n == 2 then
      emit(comp_project_names(comp_ws(root)))                    -- <project>
    elseif sub == "set" then
      -- <project> <variable> [<default>] [--type string|path]; offer --type
      -- once past the variable name (position 3+), plus its values after it.
      if n >= 4 then
        if a[n - 1] == "--type" then emit({ "string", "path" })
        else emit({ "--type" }) end
      end
    end
    return 0
  elseif cmd == "profile" then
    if n == 1 then emit({ "list", "show", "select", "create", "publish", "query", "remove", "set", "unset", "describe" }); return 0 end
    if sub == "describe" then
      if n == 2 then emit(comp_profile_names(comp_ws(root))) else emit({ "-m", "-F", "-e", "--clear", "--json" }) end
      return 0
    end
    if sub == "create" then
      if n == 2 then emit(comp_set_names(comp_ws(root)))       -- <config-set>
      elseif n >= 3 then                                       -- [tool ...] / --activate
        local list = comp_tool_keys(); list[#list + 1] = "--activate"; emit(list)
      end
    elseif (sub == "publish" or sub == "show") and n == 2 then
      emit(comp_profile_names(comp_ws(root)))                  -- <key>
    elseif sub == "select" and n == 2 then
      local list = comp_profile_names(comp_ws(root)); list[#list + 1] = "--none"
      emit(list)                                               -- <profile> | --none
    elseif (sub == "set" or sub == "unset") then
      -- Grammar: [<profile>] <project> <variable> [<value>]. Position 2 may be
      -- either the optional profile or the project; offer both. Position 3
      -- offers project names (when a profile led) plus profile names.
      if n == 2 or n == 3 then
        local ws = comp_ws(root)
        local list = comp_profile_names(ws)
        for _, p in ipairs(comp_project_names(ws)) do list[#list + 1] = p end
        emit(list)
      end
    end
    return 0
  elseif cmd == "target" then
    -- `target [list] [profile]` | `target set [<profile>] <target>` |
    -- `target clear [profile]`.
    if n == 1 then
      local ws_c = comp_ws(root)
      emit(sorted_unique(vim.list_extend({ "list", "set", "clear" },
        comp_profile_names(ws_c))))                            -- sub-keyword or profile
      return 0
    end
    if sub == "set" and n == 2 then
      -- <profile> (2-operand form) or <target> (1-operand); offer both.
      local ws_c = comp_ws(root)
      emit(sorted_unique(vim.list_extend(comp_launch_names(ws_c), comp_profile_names(ws_c))))
    elseif sub == "set" and n == 3 then
      emit(sorted_unique(comp_launch_names(comp_ws(root))))    -- <target> on named profile
    elseif (sub == "list" or sub == "clear" or sub == "unset") and n == 2 then
      emit(comp_profile_names(comp_ws(root)))                  -- [profile]
    end
    return 0
  elseif cmd == "config" or cmd == "configuration" or cmd == "cfg" then
    if n == 1 then emit({ "list", "add", "show", "get", "set", "unset", "rename", "describe", "remove", "publish" }); return 0 end
    if n == 2 then emit(comp_project_names(comp_ws(root))); return 0 end -- <project>
    if n >= 4 and sub == "describe" then emit({ "-m", "-F", "-e", "--clear", "--json" }); return 0 end
    if n == 3 and has({ "show", "get", "set", "unset", "rename", "mv", "remove", "publish", "describe" }, sub) then
      emit(comp_config_names(comp_ws(root), a[3])); return 0            -- <config>
    end
    if n == 4 and has({ "get", "set", "unset" }, sub) then
      emit({ "variant", "inherits", "languages", "toolchain", "generator", "description",
        "options.", "variables.", "overrides." })                       -- <param>
    end
    return 0
  elseif cmd == "configset" or cmd == "configuration-set" or cmd == "cs" then
    if n == 1 then emit({ "list", "show", "create", "map", "unmap", "rename", "describe", "remove", "publish" }); return 0 end
    if n >= 3 and sub == "describe" then emit({ "-m", "-F", "-e", "--clear", "--json" }); return 0 end
    if n == 2 and has({ "show", "map", "unmap", "rename", "mv", "remove", "publish", "describe" }, sub) then
      emit(comp_set_names(comp_ws(root))); return 0                      -- <name>
    end
    if n == 3 and (sub == "map" or sub == "unmap") then
      emit(comp_project_names(comp_ws(root))); return 0                  -- <project>
    end
    if n == 4 and sub == "map" then
      emit(comp_config_names(comp_ws(root), a[4]))                       -- <config>
    end
    if sub == "create" or sub == "add" then
      -- create <name> [<project> <config> …] — after the name, positions
      -- alternate project / config (the `project=config` form is free text).
      if n >= 3 and (n % 2 == 1) then emit(comp_project_names(comp_ws(root)))
      elseif n >= 4 and (n % 2 == 0) then emit(comp_config_names(comp_ws(root), a[n])) end
    end
    return 0
  elseif cmd == "module" or cmd == "mod" then
    if n == 1 then emit({ "list", "install", "update", "remove" }); return 0 end
    -- update/remove operate on what is installed — complete from disk (offline,
    -- fast). install takes an index name; that needs a network fetch, so leave
    -- it to the user rather than stall the shell.
    if n == 2 and has({ "update", "remove", "rm", "upgrade" }, sub) then
      local ok, paths = pcall(require, "boot.paths")
      if ok and type(paths) == "table" and type(paths.installed_modules) == "function" then
        local names = {}
        for _, m in ipairs(paths.installed_modules()) do names[#names + 1] = m.name end
        if sub == "update" or sub == "upgrade" then names[#names + 1] = "--all" end
        emit(sorted_unique(names))
      end
    end
    return 0
  elseif cmd == "sdk" then
    if n == 1 then emit({ "types", "detect", "list", "add", "remove" }); return 0 end
    -- The provider ids come from the installed providers (no probing).
    if n == 2 and has({ "add", "create", "detect" }, sub) then emit(sdk_provider_ids()) end
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
-- Release notes (spec §16.37)
-- ---------------------------------------------------------------------------

--- Parse `lw release-notes` arguments (a[1] is the command). Returns the
--- selection and whether `--json` was given, or nil + a usage message.
--- @param a string[]
--- @return table|nil sel, boolean|string json_or_err
function M._release_notes_args(a)
  local rn = require("loomworks.release_notes")
  local sel, json, i = nil, false, 2
  local function set(s)
    if sel then return false end
    sel = s
    return true
  end
  local function need_version(v, what)
    local nv = rn.normalize(v)
    if not nv then return nil, "invalid version '" .. tostring(v) .. "'" .. (what or "") .. " (want x.y.z)" end
    return nv
  end
  local conflict = "give only one of <version>, --since, --all, -n"
  while a[i] ~= nil do
    local v = a[i]
    if v == "--json" then
      json = true
    elseif v == "--all" then
      if not set({ kind = "all" }) then return nil, conflict end
    elseif v == "--since" or v:sub(1, 8) == "--since=" then
      local val = v == "--since" and a[i + 1] or v:sub(9)
      if v == "--since" then i = i + 1 end
      if val == nil then return nil, "--since needs a version" end
      local nv, e = need_version(val, " for --since")
      if not nv then return nil, e end
      if not set({ kind = "since", version = nv }) then return nil, conflict end
    elseif v == "-n" or v:sub(1, 3) == "-n=" then
      local val = v == "-n" and a[i + 1] or v:sub(4)
      if v == "-n" then i = i + 1 end
      local n = tonumber(val)
      if not n or n < 1 or n ~= math.floor(n) then return nil, "-n needs a count of 1 or more" end
      if not set({ kind = "count", n = n }) then return nil, conflict end
    else
      local nv, e = need_version(v)
      if not nv then return nil, e end
      if not set({ kind = "version", version = nv }) then return nil, conflict end
    end
    i = i + 1
  end
  return sel or { kind = "default" }, json
end

--- `lw release-notes [<version> | --since <v> | --all | -n <N>] [--json]`.
function M.cmd_release_notes(a)
  local rn = require("loomworks.release_notes")
  local notice = require("loomworks.release_notice")
  local sel, json = M._release_notes_args(a)
  if not sel then die(json .. " — see `lw help release-notes`", 2) end
  local text
  if M._test_release_notes_text ~= nil then text = M._test_release_notes_text else text = notice.read_text() end
  if not text then
    errw("lw: release notes are not available in this build (no CHANGELOG.md)\n")
    return 1
  end
  local running = notice.running_version()
  local res, err = rn.select(rn.parse(text), running, sel)
  if not res then
    errw("lw: " .. err .. "\n")
    return 1
  end
  if json then
    out(vim.json.encode(rn.to_json(res, vim.NIL)))
    return 0
  end
  local tty = M._stdout_tty()
  local pal = status_palette(tty and stdout_supports_color())
  -- One column short of the terminal: a line of exactly its width makes some
  -- consoles wrap an empty line after it.
  local width = tty and math.max(40, term_width() - 1) or nil
  for _, l in ipairs(rn.render(res, { width = width, paint = pal })) do out(l) end
  notice.mark_seen()
  return 0
end

--- Completion candidates after `lw release-notes ...`: the known versions after
--- `--since` / as the operand, then the options not yet given.
function M._release_notes_completions(a, n)
  local versions = {}
  pcall(function()
    local rn = require("loomworks.release_notes")
    local text = require("loomworks.release_notice").read_text()
    for _, e in ipairs(text and rn.parse(text).entries or {}) do
      if e.version then versions[#versions + 1] = e.version end
    end
  end)
  if a[n] == "--since" then return versions end
  if a[n] == "-n" then return {} end
  local given, c = {}, {}
  for i = 2, n do given[a[i]] = true end
  for _, v in ipairs({ "--since", "--all", "-n", "--json" }) do
    if not given[v] then c[#c + 1] = v end
  end
  if n == 1 then for _, v in ipairs(versions) do c[#c + 1] = v end end
  return c
end

--- The one-line upgrade notice (§16.37), before a command runs: only on a
--- terminal stderr in an interactive run, never for `--json` output.
function M._release_notice(a, noninteractive)
  for _, v in ipairs(a) do if v == "--json" then return end end
  local interactive = M._test_notice_interactive
  if interactive == nil then
    local ok, h = pcall(uv.guess_handle, 2)
    interactive = (not noninteractive) and ok and h == "tty"
  end
  local line = require("loomworks.release_notice").maybe_notice({
    interactive = interactive, cfg = read_config() })
  if line then note(line) end
end

-- ---------------------------------------------------------------------------
-- Help
-- ---------------------------------------------------------------------------

local HELP = {
  status = [[lw status [--check] [--cache-stats]   (also: bare `lw`)

One-screen workspace overview: the active profile and its launchable targets
(default marked `*`), a Diagnostics section (shown only when non-empty), then
capped lists of profiles (active marked `*`), configuration sets, and projects
with their configurations. Each section is limited to fit a page — use
`lw target`, `lw profile list`, `lw configset list`, or `lw project list` for the full
lists. Build targets appear only once a project is configured; a hint shows
when the target list is incomplete.

Each profile row shows its build state in parentheses after the profile
name: the editor's status label, `(built)`, `(configured)`, `(unconfigured)`,
`(unknown)`, or counts when its projects differ (`(1 built, 1 unconfigured)`).
A task the workspace daemon runs shows as running (`(1 building)`). On a
terminal the state is colored as in the editor (built green, configured blue,
unconfigured dim, running yellow, failed red). The row has no set column: a
profile's name starts with its configuration set. Read fresh from the cache on
every run.

For a profile with a C/C++ project the overview shows a `Cache` line — the
resolved compiler-cache launcher (ccache/sccache), or that caching is `off` /
`auto (none found)` / `auto (off for MSVC-style)` (auto never enables a cache
for MSVC or clang-cl; `lw help cache` shows how to opt in) / `<tool> (not found)` (an
explicit `cache=<tool>` whose launcher is not installed — builds run uncached) /
`not applied (<reason>)` (the configuration cannot take a launcher, e.g. a
preset or a Visual Studio / Xcode generator). A `[stale — reconfigure]` marker
means the next build reconfigures to apply a launcher change. `lw profile show`
shows the same line for any profile.

Diagnostics come from the same source the editor's Diagnostics page uses:
per-item warnings/errors also appear inline under the relevant profile,
configuration set, or project.

  --check         exit non-zero if any diagnostic is present, or if there is
                  no workspace here (for CI); without it, `lw status` always
                  exits 0.
  --cache-stats   also run the resolved cache tool's own stats query
                  (`ccache -s` / `sccache --show-stats`) and fold it in. Off by
                  default because it spawns the tool.]],
  ["release-notes"] = [[lw release-notes [<version> | --since <version> | --all | -n <N>] [--json]

What changed in each release, from the notes the running release carries (no
network needed).

  (no argument)        the three newest releases up to the one you run
  <version>            exactly that release's notes (e.g. 0.1.40)
  --since <version>    every release newer than <version> (not <version>
                       itself): what changed since then
  --all                every release
  -n <N>               the N newest releases
  --json               one JSON document (schema 1) instead of text; the
                       not-yet-released entry has "summary": null

Each release lists a short summary, then its changes under Breaking, Upgrade
notes, Added, Changed, Fixed, Security and Removed. On a terminal the text is
wrapped to its width; piped or redirected, every change is one full line.
A prerelease shows the changes it carries that are not released yet.

After `lw self-update` installs a newer release it lists what changed since
your previous one; the first interactive run after an update that did not
(an update made by an older lw binary) prints one line pointing here. Turn
both off with `lw settings set release-notes off` or LOOMWORKS_RELEASE_NOTES=off;
this command always works.]],
  tools = [[lw tools [--cached]

List the toolchains detected on this machine, grouped by module (cmake,
meson, …). Each row is a tool key, its label, and the languages it provides.
Tools are scanned per workspace module, so a module only appears once a
project uses it. Pin one in a profile with `lw profile create <set> <tool>`;
version prefixes match (ninja-clang-19 -> ninja-clang-19.1.5).

Probing compilers/vcvarsall is slow, so the result is cached in tools.json
under the per-user cache dir: %LOCALAPPDATA%\loomworks\cache on Windows,
$XDG_CACHE_HOME/loomworks (default ~/.cache/loomworks) elsewhere.
`lw tools` always does a real scan and refreshes that cache; other commands
(profile create, profiles) read it.
  --cached   print the cached result instantly (with its age); don't scan.
Installed a new compiler? run `lw tools` to refresh.]],
  build = [[lw build [profile | config-set] [--target <name>]... [--force] [--reconfigure] [-v] [--break-locks] [-- <build-tool args>]

Args after `--` are forwarded to the BUILD tool (not to configure), e.g.
`lw build Debug:ninja-gcc-14 -- -j 4` to cap parallelism in CI. They go on
the build command itself (cmake `--build <dir> …`, meson `compile -C <dir> …`),
also for MSVC kits that build inside vcvarsall — `lw build <p> -- --target X`
works there too. An argument the vcvarsall batch file cannot carry (a `"` or a
line break) is refused, never dropped.

Build a profile's projects. Interactively, with no profile given, it uses the
active profile (user.json), else the only profile. With NO profile yet, it
onboards one: pick a configuration set, choose a tool, and it creates +
activates the profile, then builds — so a freshly-cloned project goes from
`lw build` to building. `lw build <config-set>` does the same for a named set.

In non-interactive mode (--no-input / LW_NO_INPUT / CI, or piped stdin) the
active profile is NOT used and nothing is created — pass a profile explicitly
for a deterministic build. The CI pattern is:
  lw profile create <set> <tool>  &&  lw build <set>:<tool>
(the profile key is `<set>:<tool>`, as `lw profile create` prints it).

  profile     e.g. Debug:ninja-clang-19  (a unique substring works too; major
              pins resolve to the installed patch version)
  config-set  a set name; onboards a profile for it (interactive)

  --target <name>  build just this target instead of the default set;
                repeatable (cmake `--build --target <name>…`, meson `compile
                <name>…`; e.g. an EXCLUDE_FROM_ALL target). Name it as
                `lw target` lists it (<project>:<target>) or bare when only one
                project lists it; only the projects named are built. A bare
                name several projects list is refused, naming the choices; one
                no project lists (e.g. `install`, a custom target) goes to
                every project's build tool, and a failure suggests close
                matches. Not supported for shell / typescript projects.
                Tab-completes.
  --force        build even if it overwrites an artifact another built profile
                owns (that profile is marked stale).
  --reconfigure  force a FULL reconfigure of every project before building
                (cmake `--fresh`, below CMake 3.24 a reset of CMakeCache.txt +
                CMakeFiles; meson `setup --wipe`) — for a build tree whose
                configure state you no longer trust.
  -v, --verbose  print each configure / build step's full command line and
                the directory it runs in (for an MSVC kit, the cmake command
                run inside vcvarsall). Always written to .nvim/loomworks.log.
  --break-locks[=now]  recover a build-directory lock whose holder hangs (or,
                on this host, is still running): ask it to stop (POSIX), wait
                ~5s (`=now` skips the wait), kill its process tree, recover the
                interrupted step's state, then run. Never another host's holder
                or the editor's (see `lw help unlock`).

Configures first if the build dir isn't configured — or when a configure input
changed since the last configure (options, env, toolchain, compiler cache), or
the build dir was configured by an older lw — then builds. Each configure
prints why it runs, e.g. `full reconfigure (--fresh): options changed (FOO
removed)`. Non-zero exit on any failure. Artifacts land under
.nvim/build/<project>/<tool>/<config>/ — a separate build dir per toolchain.]],
  clean = [[lw clean [profile | config-set] [--break-locks]

Run each project's build-system clean on the profile's build directories
(cmake -> `cmake --build <dir> --target clean`; meson -> `meson compile
--clean`). Removes build artifacts but KEEPS the configuration — a later
`lw build` reconfigures only if something changed. Build dirs that were never
created are skipped. Non-zero exit on any failure.

Profile resolution matches `lw build` (a unique substring works; --no-input
requires an explicit profile). To remove a build directory entirely rather than
just its artifacts — a hard reset to unconfigured — use `lw reset`.
`--break-locks[=now]` recovers a hung build-directory lock (see `lw help build`).]],
  reset = [[lw reset [profile | --all] [-y] [--break-locks]

HARD-reset build state: remove the build directories (rm -rf, NOT the build
system's artifact clean of `lw clean`) and drop the affected configurations back
to `unconfigured`, so the next `lw build` reconfigures from scratch.
The profile, its configuration set, and its toolchain pins are KEPT —
this is the CLI equivalent of the status page's delete, minus removing the
profile. Contrast `lw clean`, which keeps the configuration and only removes
artifacts.

  profile   e.g. Debug:ninja-clang-19  (a unique substring works). Resolution
            matches `lw build`; --no-input requires an explicit profile.
  --all     reset EVERY build directory in the workspace — across all profiles
            and including orphaned ones (cached build state no profile still
            references). Takes no profile argument.
  -y | --yes  skip the confirmation prompt (required in --no-input / CI).
  --break-locks[=now]  recover a hung build-directory lock (`lw help build`).

Destructive, so it confirms first: the build directories to remove are printed
and confirmation is requested. In non-interactive mode (--no-input / LW_NO_INPUT
/ CI, or piped stdin) `-y` is MANDATORY — without it reset refuses rather than
deleting unprompted. A profile with no build directories resets nothing and
exits 0.

Reset is exclusive (like clean/delete): it holds each build directory's lock
so it cannot race a concurrent build. A build directory still
referenced by another profile not being reset is kept on disk (its state cleared
only for the reset). Non-zero exit on any failure.]],
  trust = [[lw trust [--yes | -y] [--discard]

Workspace trust. A repository can come from anywhere, so loomworks decides what
it may run by where a setting comes from:

  loomworks.json (committed, shared)   never names programs. Environment
      variables, launch commands/arguments/working directories, deploy
      destinations outside the workspace, and module program settings (e.g. a
      clangd/qmlls binary) found there are IGNORED, with a diagnostic in
      `lw status`. They stay in the file (publishing keeps them); to use one,
      copy it into your working copy.
  .nvim/loomworks.user.json (yours)    honored — when it is signed by this
      machine. Every lw/editor write signs it with a per-machine key
      (<data dir>/trust.key, never in a repository). A file written by hand,
      by an earlier lw, or copied from another machine is REFUSED until you
      review it. The signature does not bind the directory: a working copy
      this machine signed stays trusted when moved or copied to another
      workspace here (or seeded into a git worktree) — its profiles, tools
      and launch commands are then used as they are.
  .nvim/loomworks.cache.json            build state; used only when signed here.
      An unsigned one (earlier lw) is ignored unread and replaced by the next
      command that writes the cache (read-only commands leave it); one
      signed elsewhere refuses the load until `lw nuke`.
  Tool paths                            always from detection on this machine,
      never from the cache. A profile only selects a detected toolchain by
      its key; what that runs (compiler, developer-environment script such as
      vcvarsall) is what detection found here.

`lw status` shows the state in its Trust row: whether your local config is
present (a refused one stops every command with the instructions below
instead) and how many loomworks.json program settings are ignored. A build
whose profile is affected prints one line saying so. (The status title is the
workspace's name — a directory named "untrusted" shows as
"loomworks — untrusted"; that is not a trust state.)

Opening a workspace (`lw status`, the editor) never runs anything the shared or
an unsigned file names. `lw build` / `lw test` / `lw run` still run the
project's own build system (cmake/meson/npm and the build files they read) —
that is what you asked for.

  lw trust            show what the working copy would let loomworks run
                      (program settings first), then ask to trust (re-sign) it
  lw trust --yes      trust without asking (non-interactive: required)
  lw trust --discard  delete the working copy instead (asks; --yes skips)

Editing .nvim/loomworks.user.json by hand is fine: run `lw trust` afterwards.
Environment variables that hijack loaders or interpreters (LD_PRELOAD,
DYLD_*, NODE_OPTIONS, PYTHONPATH, ComSpec, PATHEXT, GIT_SSH_COMMAND, …) are
refused from every configuration, even a trusted one.

`--discard` holds the workspace operation lock while it removes the working
copy and its backup; `--break-locks[=now]` recovers it from a hung holder.]],
  nuke = [[lw nuke [-y | --yes]

Delete the workspace's build state: .nvim/build/, .nvim/loomworks.cache.json
and .nvim/loomworks.health.json. Your configuration (loomworks.json and the
working copy) is kept; the next `lw build` reconfigures from scratch.

This is the remedy when the build cache was not written on this machine (it is
refused — see `lw help trust`). Confirms first; -y skips the prompt and is
required in non-interactive mode. Prefer `lw reset` to reset one profile.

Nuke holds the workspace operation lock and the build lock of every build
directory it removes, so it refuses while a build runs ("cannot nuke: a
build is running in ...") instead of deleting under it. `--break-locks[=now]`
stops a hung (or, on this host, running) holder first (see `lw help unlock`).]],
  cleanup = [[lw cleanup [--dry-run | --yes] [--all] [--pinned-older-than <duration>]

List, and with --yes remove, what lw left behind outside the workspace:
downloads and staging directories of an interrupted self-update, pinned
provisioning or module install, temporary files, the MSVC environment probe's
batch file, a self-update's lw.new / lw.old, a device lock or daemon socket
whose owner is gone, and files earlier versions kept outside the workspace
(runtime logs, test results, description buffers). Only exact lw names in
lw's own directories are touched, never through a link, never while in use.

  --dry-run   list only (the default): kind, path, size, age, and the total
  --yes, -y   remove them; exit 1 if one could not be removed (in use, ...)
  --all       also prune pinned releases (<data dir>/pinned) not used for 30
              days (that is all it adds); never the release this
              repository's lw.pin pins, nor the running lw
  --pinned-older-than <duration>
              the pinned-release threshold, e.g. 90d, 12h (implies the pinned
              part of --all)

lw also does this by itself: once a day, at the start of a command, it
silently removes the same leftovers (pinned releases excepted, and old runtime
logs only once unmodified for 30 days), and notes it in the workspace's
.nvim/loomworks.daemon.log.

What lw keeps outside the workspace on purpose: its settings (config.json),
the machine key (trust.key), the tool scan cache (tools.json), the newest three
releases, installed modules, pinned releases in use, and the empty daemon
working directory. <data dir> is %LOCALAPPDATA%\loomworks,
$XDG_DATA_HOME/loomworks or ~/.local/share/loomworks (LOOMWORKS_DATA_DIR).]],
  daemon = [[lw daemon [status] | list [--json] | stop [--force] | kill | restart [--force] | run [--root <dir>] [--stdio]
       lw daemon stop --all [--force] | kill --all [--strays]   [--under <dir>]

EXPERIMENTAL, opt-in. The workspace daemon is one long-lived `lw` process per
workspace that will, step by step, run the workspace's operations for every
client (the editor and each `lw` command). So far `lw build` runs through it
(in `daemon` mode); with the default runtime mode, `in-process`, lw behaves
exactly as before.

  status    (also bare `lw daemon`) the runtime mode and the workspace's
            daemon: pid, host, version, endpoint, heartbeat, and what a live
            daemon on this host answers. Never starts a daemon.
  list      every workspace daemon of yours on this machine, in any
            workspace (works anywhere): pid, uptime, state (idle, busy,
            active, starting, not responding, stray), clients, version and
            root. Found by scanning processes for `lw ... daemon run`; never
            starts, contacts or stops one, and writes nothing. A "stray" is
            not its workspace's runtime (it lost its lock, its workspace is
            gone, or it has no --root). --json for scripts; --under <dir>
            keeps the workspaces under <dir>.
  stop      ask the daemon to exit and wait for it (about 10 s). Never kills:
            a daemon that does not stop is reported as not responding. With
            no daemon running there is nothing to do; the files of one that
            is gone are cleared.
            --force: if it does not stop within about 5 s, kill its process
            tree, then reclaim its lock and complete an interrupted commit
  kill      the same without asking first
  restart   stop (with --force if given), then start a daemon in the
            background
  run       serve this workspace in the foreground (what a started daemon
            runs; --root names the workspace). --stdio: speak the protocol
            on standard input and output instead (one client, no endpoint;
            ends when the client closes standard input)

  --all     with stop / kill: do it for every daemon `lw daemon list` shows
            (--under <dir>: only those workspaces), one line each, through
            each workspace's runtime lock with the rules above. Strays are
            skipped unless `lw daemon kill --all --strays`, which kills them
            after checking each is still that daemon. A daemon of another
            loomworks data dir (another LOOMWORKS_DATA_DIR, a test run's;
            `list` marks it "other data dir") is not this lw's and is
            skipped. Exit 1 when one of this lw's is left running.

A daemon on another host (a shared drive) is never stopped or killed from
here: run the command there. Kills are printed on stderr.

The endpoint (a named pipe on Windows, a socket in a private per-user
directory elsewhere) is restricted to your user, and every connection proves
knowledge of this machine's key (the trust key, `lw help trust`) before
anything else is exchanged.

Runtime mode: `lw settings set runtime-mode in-process|daemon`, or the
LOOMWORKS_RUNTIME environment variable (wins). `lw status` shows it on its
`Runtime` row, read from the files below only.

In `daemon` mode every workspace command (not `lw status`, `health`, `help`,
`settings`, `pull`, `worktree`, `trust`, `nuke`, `unlock`, `daemon …`) first
makes sure the daemon runs: it connects (and pings it, waiting about a second
at most; `lw build`, which the daemon runs, waits up to about 5 seconds for a
slow one) or starts one in the background, then runs exactly as before, except
`lw build`, which runs in the daemon: one dim line says so
(`lw: building through the workspace daemon (pid N)`), then the build's output
and result are the same as without it. Ctrl-C (or the end of `lw`) stops the
build in the daemon. `lw build --break-locks` and creating a missing profile
interactively still run without it. Whenever a build does not run in the
daemon, one line says why (only the opt-outs below are silent). A daemon of another lw version is
replaced when idle; a busy one is asked to exit when idle and the command runs
without it (one line says so). If it cannot start, does not answer, or is
still starting, one line says so and the command runs without it. A daemon
that stopped responding is named with the recovery command; a command given
`--break-locks` recovers it (asks it to stop, kills it, starts a fresh one).
These never start it: `--no-daemon`, LOOMWORKS_NO_DAEMON=1, and
CI=true (LOOMWORKS_NO_DAEMON=0 overrides CI). CI is detected by the `CI`
variable only: Jenkins and Azure Pipelines do not set it — set
LOOMWORKS_NO_DAEMON=1 there. In daemon mode these (and a daemon that could
not be started) run `lw build`, `lw test`, `lw run`'s preparation, `lw clean`
and `lw reset` with the daemon's own code inside the lw process, holding the
workspace for the command, with no "through the workspace daemon" line; a
running daemon is still used. When another such command holds the workspace,
lw waits `runtime-busy-wait` (default 5s; 0, or a number with ms, s or m) and
then fails "workspace busy" (exit 1).

A routed build runs in the environment of the `lw build` that asked for it
(its PATH, compiler and SDK variables, …): lw sends its environment to the
daemon over the private endpoint below; it is never written anywhere. Other
work of a started daemon keeps the environment of the command that started
it. Builds from two terminals (tabs, panes, SSH sessions) share the daemon's
loaded workspace: variables that only name the terminal or session
(WT_SESSION, TMUX_PANE, SSH_TTY, VSCODE_*, cmd.exe's hidden =C: entries,
...) do not count as a different
environment; any other difference (PATH, a compiler variable) reloads it.

A routed build's tools write into a pipe, not your terminal (as with
`lw build | tee`): ninja prints every [n/N] line instead of one status line,
and tools that colour only on a terminal do not. lw adds no colour variable
(it would reach every process of the build); set one yourself, e.g.
CLICOLOR_FORCE=1, and the build gets it. When the reader of lw's output
stops reading (`lw build | less`, paused), the daemon keeps up to about
4 MiB of the build's output for it, then pauses the build tool until it reads
again (as without the daemon); no output is lost or reordered.

Lifetime: the daemon runs while a client is connected (a connection silent for
three 30 s keepalive intervals is dropped) and exits after
`daemon-idle-timeout` without any (setting: seconds, or a number with s, m or h
such as 90s, 2m, 30m, 1h; default 1h),
when the workspace directory is removed, or when its lock is taken over.

Files: .nvim/loomworks.daemon.lock (the runtime lock: one runtime per
workspace), .nvim/loomworks.daemon.json (the handle a client finds the daemon
by), and the runtime log .nvim/loomworks.daemon.log (2 MB + one rotated .1):
the daemon's starts, stops and refusals, every launch, and every kill and
forced unlock (`lw daemon kill`, `--break-locks`, `lw unlock --force`).
`lw daemon status` names the log.]],
  unlock = [[lw unlock <profile> | <build dir> | --workspace | --journal | --all [--force] | --device <serial>

Clear build-directory locks. loomworks serializes configure/build/clean on a
build dir across processes (editor + CLI) with an advisory lockfile that names
its holder (process id, host, start time). A holder that crashed or was killed
is reclaimed automatically by the next command; one that hangs (alive, no
heartbeat) is reported with the recovery command, `<command> --break-locks`.

  <profile>    the locks of that profile's build dirs
  <build dir>  one build dir, by path (relative to the workspace root, or
               absolute; it must lie under the root), e.g. .nvim/build/App/Debug
  --all        the locks of every profile's build dirs, and the workspace
               operation lock
  --workspace  the workspace operation lock (.nvim/loomworks.op.lock), held
               by publish / import / pull / rename / remove / reset / nuke
  --journal    discard a stuck commit journal (.nvim/loomworks.txn.json) and
               its staged copies. A multi-file operation that crashed is
               normally completed by the next command; when it cannot be
               (a file changed since, a staged copy is missing) the workspace
               is refused until you discard the journal (the files then stay
               as they are — possibly mixed). `lw nuke` cannot help: it takes
               the same lock, and only resets build state.
  --force      also remove the lock of a holder that is running (or hung, or on
               another host) — WITHOUT stopping it: it may still be running and
               writing there. Printed loudly, recorded in the runtime log
               (`lw help daemon`).
  --device <serial>
               clear the per-user DEVICE lock of that serial (remote runs hold
               it for their whole duration; see `lw help device`)

Without --force a lock whose holder is still running is left in place and
named (exit 1). A removed lock of a killed configure leaves its units
unconfigured, of a killed build step not built (configured).]],
  run = [[lw run [<target>] [-- prog-args…]   |   lw run <profile> <target> [-- …]

Resolve a profile and a launch target, then build -> deploy -> execute.
The target is EITHER a build target (its executable) OR a command
launch configuration declared with `lw launch add`; variables are expanded in
the profile's context. The launched process's exit code becomes lw's exit
code; output streams through.

Operands (before `--`) — the count picks the form:
  (none)               the resolved profile's DEFAULT target. The profile is
                       the active one (interactive) or the sole one, else error.
  <target>             that target on the resolved profile. A single operand is
                       ALWAYS a target, never a profile — to run another
                       profile use the two-operand form or `lw profile select`.
  <profile> <target>   the named target on the named profile.
  --cwd <dir>  working directory for this run (absolute or workspace-root-
               relative, variable-expanded; alias --working-dir). Overrides the target's stored /
               default working dir just for this invocation. Default: the
               owning project's directory.
  -- args…     everything after `--` is forwarded verbatim to the program
               (a command config's own declared args come first). Required to
               pass args, so the operands are never mistaken for one.

Wrapping and inspecting the launch:
  --prefix <cmd>        run the program under a wrapper — the process becomes
                        `<prefix> <cmd> <args>` in the launch's resolved cwd/env,
                        on the real terminal (interactive gdb/valgrind work).
                        Repeatable and shell-word split, so
                        `--prefix 'valgrind --leak-check=full'` and
                        `--prefix gdb --prefix --args` both give many tokens.
                        This is the faithful way to run under a wrapper —
                        `valgrind $(lw run --print)` cannot carry the cwd/env.
  --print[=sh|json]     build (+deploy) first, then resolve the launch but DO
                        NOT run it; report it, exit 0. `sh` (default) is one
                        POSIX-sh-quoted `<cmd> <args>` line
                        (for `$(lw run --print)`); `json` is
                        `{"cmd":[argv],"cwd":…,"env":{overrides-only}}` — the
                        portable form (e.g. on Windows). An unresolved build-
                        target artifact is reported as such (non-zero), never
                        guessed.
  --dry-run[=sh|json]   like --print but NEVER builds, deploys or runs
                        (implies --no-build). A program that is not built yet
                        is still reported, with a note on stderr.
  --no-build            skip the build+deploy — run / inspect what is already
                        built.

Disambiguating a name present more than once:
  <project>:<target>     scope to a project
  --project <key>        same, as a flag
  --target | --launch    force the kind when a build target and a launch
                         config share a name in one project

Deploy steps declared on the target run before launch. Debug (DAP) and module
device-package launches are editor-only; a cross-built build target runs on a
device (below).

Foreign targets (built by a cross-compiling kit): never run on this host. They
run on an attached DEVICE through the device runner of the kit's SDK — build ->
deploy -> stage -> execute; the exit code is the device program's (255 when the
device/transport lost it, 124 on --timeout). See `lw help device`.
  --device <serial>     the device for this run (else the profile's persisted
                        device, else the only one online)
  --fresh               re-stage every file (ignore the sync record)
  --timeout <s>         stop the device program after <s> seconds
  --query-timeout <s> / --transfer-timeout <s>
                        transport timeouts (defaults 120 s / 600 s)
  --log <key>=<value>   device-log option for the runner (repeatable)
  --no-wait             fail instead of waiting when the device is busy
  --break-locks[=now]   recover a hung build-directory or device lock first
                        (stop its holder's process tree; see `lw help build`)
`--prefix` and `--cwd` are errors on a foreign target; `--print` reports the
device-side invocation and the staging manifest. The run announces
"running <program> on <serial> (pid N)"; Ctrl-C stops the device program and
says so, with the run folder.

Output: build output goes to stdout like `lw build`, but to stderr under
--print / --print=json so stdout carries only the report (--dry-run never
builds).]],
  device = [[lw device <list|select|clean>

Devices for running cross-built programs. An SDK plugin whose kits
build for another platform may ship a DEVICE RUNNER; loomworks uses it to copy
("stage") a program onto an attached device and run it there.

  list [--json] [--query-timeout <s>] [profile]
                                  the devices each runner in scope reports:
                                  serial, state, runner, name, and the profiles
                                  that persist the serial. Exit 0 when none are
                                  attached; non-zero when no runner is available.
  select <serial> [profile]       persist the profile's device (working copy)
  select --clear [profile]        forget it
  clean [--device <serial>] [--query-timeout <s>] [--no-wait] [--break-locks]
                                  remove this workspace's staging tree from
                                  the device (and the staging base if that
                                  leaves it empty) and clear the host's sync
                                  record. --query-timeout bounds each device
                                  query (default 120 s); --no-wait fails
                                  instead of waiting for a busy device

Device choice for `lw run` / `lw test --target`: --device, else the profile's
persisted serial, else the only online device — never guessed otherwise.

What is staged: the program, the project shared libraries it links, the
platform runtime the runner names, plus the project's `device` block, kept in
the project's module section (e.g. projects.App.cmake.device):
  "device": { "stage": ["bin/*.so"], "archive": ["assets/**"],
              "env": { "K": "V" }, "working_dir": "bin" }
(An older project-level "device" block is still read and moves into the module
section on the next save.) Edit it without hand-editing JSON:
  lw project set <project> device.stage 'bin/*.so' 'lib/*.so'
  lw project set <project> device.env.LOG debug
  lw project unset <project> device.stage
`stage`/`archive` are globs relative to the build directory (layout kept);
`archive` sets travel as one tar. Only changed files are re-sent. Runs save
output.log (and device.log, pulled results, crash reports) under
<build>/.device-runs/ (10 newest kept).

Device logs: a launch config's `device_log` table and `--log key=value` are
passed to the runner as-is; the option names belong to the SDK plugin.

Trust: stage/archive and device_log are honored from loomworks.json; device
`env` and `working_dir` only from your local config (`lw help trust`).
One remote operation per device at a time: runs wait for the device lock
(`--no-wait` fails fast; `lw unlock --device <serial>`;
LOOMWORKS_DEVICE_LOCK_DIR relocates the lock directory). A holder that hangs is
reported instead of waited for; `--break-locks[=now]` on run / test / device
clean stops it (never another host's process or the editor's).]],
  target = [[lw target [list] [profile]
lw target set [<profile>] <target>   |   lw target clear [profile]

List a profile's LAUNCHABLE TARGETS, or set/clear which one a bare `lw run`
defaults to. A target is either a build target (its executable) or a command
launch configuration (`lw launch add`). Bare `lw target` lists the active
profile. The default is marked `*`.

Listing is READ-ONLY and performs no build. A command launch config always
lists; a build target lists only once its project is configured (its targets
are read from the build tree). When a project isn't configured yet the list
says so and names it — `lw build` to complete it.

  list [profile]        List targets (default: the active/sole profile). Listing
                        uses the active profile even in --no-input (read-only).
  set [<profile>] <target>
                        Set the default target. One operand is a target on the
                        active profile (--no-input requires the explicit
                        <profile>); two operands name the profile.
  clear [profile]       Clear the default target.

Disambiguating a name present more than once (on `set`):
  <project>:<target>    scope to a project
  --project <key>       same, as a flag
  --target | --launch   force the kind when a build target and a launch config
                        share a name
  --cwd <dir>           persistent working-dir override for a build-target
                        default (variable-expanded; alias --working-dir)

`lw launch` manages the launch-config declarations; `lw target` is the resolved
runnable view over both kinds. `lw run` runs one.]],
  launch = [[lw launch <list|add|set|show|remove|rename|describe>

Define and manage a project's launch configurations (the runners `lw run`
executes). A launch config is either **command-type** (a command, args, working
dir, env — all variable-expanded: ${build_dir}, ${variant}, project variables…)
or **target-backed** (`--from-target`): it runs a build target's executable
with the build-tree run environment (DLL paths) set up automatically, and your
args/env/working-dir layered on top — no hand-written path.

  list [project]
        List launch configs (all projects, or one): PROJECT, NAME, the
        description summary (when any launch has one) and RUNS (the command
        line, cut to the terminal; in full when piped).
  add <project> <name> <command> [args…] [--working-dir D] [--env K=V] [--description <para>]
        Declare a command-type launch config. Repeat --env for more variables.
        --cwd is an alias of --working-dir (here and on `set`).
        --description (repeatable, one paragraph each; the first is the
        summary) describes it. There is no -m here: everything after the
        command is the program's own args (python -m http.server).
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
  show <project> <name> [--json]
        Detail one config: description, target/command, args, working dir,
        env, deploy, device, debug. --json prints the whole config as one
        object (args as an array, values as declared).
  remove <project> <name>     Delete one config.
  rename <project> <old> <new>   (alias: mv)
        Rename a config in place. Everything moves with it (args, env,
        deploy, device, description, …), and every profile's default target
        that named it follows. Warns when <new> is also a build target name.
  describe <project> <name> [<text> | -m <para>… | -F <file|-> | - | -e | --clear | --json]
        Print or set the config's description (see `lw help describe`).
        Also `--project P --launch N` instead of <project> <name>.

Configs live in the project's working copy; they reach loomworks.json when the
project is published (`lw project publish <project>`).]],
  test = [[lw test [profile | config-set] [--junit <file>] [-- runner-args…]
lw test [profile] --target <exe> [--target <exe>…] [--junit <file>] [-- exe-args…]

Build a profile, then run its tests through each module's NATIVE runner (cmake
-> ctest, meson -> `meson test`), streaming output and reporting a REAL exit
code: 0 iff the build succeeded and every runner passed, non-zero otherwise.
A profile whose modules expose no test runner reports "no tests"
and exits 0 — not a failure.

Profile resolution and onboarding match `lw build`: interactively it can create
a profile from a configuration set; in --no-input / CI it needs an explicit
profile (`lw profile create <set> <tool> && lw test <set>:<tool>`).

  profile        e.g. Debug:ninja-clang-19  (unique substring works)
  config-set     a set name (interactive: onboards a profile, then tests)
  --break-locks[=now]  recover a hung build-directory or device lock first
                 (stop its holder's process tree; see `lw help build`)
  --junit <file> Write JUnit XML for CI reporters. ctest maps to
                 --output-junit; meson's fixed testlog is copied here. One file
                 per invocation; when a profile runs several test units a label
                 suffix is inserted (report.xml -> report.app-Debug.xml).
  -- args…       Everything after `--` is forwarded to the native batch runner,
                 e.g. `-- -j 4` (ctest) or `-- --num-processes 4` (meson).

CI example (JUnit + 4-way parallel ctest):
  lw --no-input test Debug:ninja-gcc-12 --junit results.xml -- -j 4

Named test executables (--target, repeatable): each is built and run DIRECTLY
(not through the batch runner) with gtest's XML results option; the outcome
fails on a non-zero exit, a failed test in the XML, a missing XML, or (on a
device) a crash report. Args after `--` go to each executable. A cross-built
executable runs on a device (`lw help device`; --device, --fresh, --timeout,
--query-timeout, --transfer-timeout, --log, --no-wait apply). A profile whose kit cross-compiles refuses the plain
batch-runner form — its registered tests cannot run on this host:
  lw test Debug:ohos-kit --target MyTests -- --gtest_filter=Scene.*]],
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
  migrate = [[lw migrate [--check] [-y | --yes]

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
                     could change which option wins.

It changes several workspace files as one operation, holding the workspace
operation lock (.nvim/loomworks.op.lock): a second such operation fails
fast with "workspace busy". `--break-locks[=now]` recovers the lock from a
hung holder (see `lw help unlock`).]],
  cache = [[lw help cache — compiler caching (ccache / sccache)   (also: sccache, ccache)

loomworks can wrap C/C++ compiles with a compiler cache so clean and
switch-branch rebuilds reuse prior objects. It resolves the launcher, the build
system applies it (cmake: CMAKE_<LANG>_COMPILER_LAUNCHER; meson: a generated
native file). `lw status` / `lw profile show` show the result on the `Cache`
row; `lw health` gives a one-line verdict; `lw status --cache-stats` adds the
tool's own hit statistics.

POLICY — the reserved `cache` variable (per configuration, compiler family or
profile):
  auto      the default. gcc/clang: ccache, else sccache, when on PATH.
            MSVC-style compilers (msvc, clang-cl): OFF — see below.
  off       never use a compiler cache.
  sccache | ccache   use exactly that tool (not found → builds run uncached,
            and `lw health` says so).
  Values are case-insensitive (`false` = off). Anything else is refused when
  set; one found in a hand-edited file is flagged in `lw status`.
Set it:
  lw config set <project> <configuration> variables.cache sccache
  lw config set <project> <configuration> overrides.msvc.cache sccache
            (clang-cl: overrides.clang.cache) — only for that compiler family
  lw profile set [<profile>] <project> cache sccache   (this machine's profile)
  lw config unset <project> <configuration> variables.cache   (back to auto)

WHY `auto` IS OFF FOR MSVC-STYLE COMPILERS — sccache FAILS a compile that
writes a shared .pdb (/Zi, /ZI; MSVC errors C1041 / C1090), and ccache won't
cache it.
Such flags often come from code loomworks does not control (a dependency, the
project's own CMakeLists). So caching there is an explicit opt-in: set
`cache=sccache` (or ccache) as above. Opting in, under cmake (>= 3.25,
single-config generator) loomworks asks for embedded per-object debug info
(/Z7: CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded + policy CMP0141 NEW); under
cmake and meson it then SCANS the configured compile commands (and the
configuration's CL / _CL_ environment) for leftover /Zi.
The scan follows the build: when the build re-runs CMake / meson by itself
(e.g. after a CMakeLists edit), the next build or `lw health` re-scans.
Findings show up at the end of the configure and in `lw health` (advisory —
the build still runs; if it then fails, lw's last line points back here), one
line per target:
  fix: switch those targets to /Z7 — replace /Zi in their compile options, or
       set their MSVC_DEBUG_INFORMATION_FORMAT property to Embedded.
When (nearly) EVERY target has it, the finding is one line — "every target
(N units) compiles with /Zi" — and the /Zi comes from a directory-wide setting
(add_compile_options, CMAKE_<LANG>_FLAGS; meson: project-wide c_args/cpp_args).
lw already requests /Z7, so cl warns D9025 "overriding '/Z7' with '/Zi'" and
sccache then fails with C1041 / C1090:
  fix: remove that /Zi (or make it /Z7) where it is set.
A finding in the `environment` group comes from /Zi in the configuration's CL or
_CL_ environment variable — remove it there:
  lw config unset <p> <c> env.CL        (or edit the value to drop /Zi)
Or turn caching off where it was turned on — the finding names the command:
  lw profile set <profile> <project> cache off       (a profile fill)
  lw config set <p> <c> overrides.msvc.cache off     (a compiler-family override)
  lw config set <p> <c> variables.cache off          (a configuration variable)
loomworks never silently turns off a cache you asked for.

CONFIGURING THE TOOL — pass its settings through the configuration's env, e.g.
  lw config set <p> <c> env.SCCACHE_DIR '${workspace_root}/.cache/sccache'
  lw config set <p> <c> overrides.msvc.env.SCCACHE_DIR D:/sccache
(also SCCACHE_CACHE_SIZE, CCACHE_DIR, CCACHE_MAXSIZE, …).

NOT APPLIED — `Cache: not applied (<reason>)`: the configuration cannot take a
launcher. A cmake PRESET owns its cache variables (set CMAKE_<LANG>_COMPILER_
LAUNCHER in the preset's cacheVariables instead); a Visual Studio or Xcode
generator ignores launchers (pick a Ninja or Makefile tool for the profile).

INSTALL — sccache: `scoop install sccache`, `cargo install sccache`, or a
release binary; ccache: `apt install ccache`, `dnf install ccache`,
`brew install ccache`, `scoop install ccache`. Put it on PATH; `auto` picks it
up for gcc/clang (MSVC-style: opt in as above).

RECONFIGURE — changing the policy, or installing/removing the tool, makes the
build reconfigure automatically on the next `lw build` (it prints why). cmake
applies a launcher-only change in place (the first build then rebuilds objects
to fill the cache); when the MSVC /Z7 settings move too it runs `cmake
--fresh`; meson always re-runs `setup --wipe`. A build dir configured by an
older lw takes one full reconfigure. `lw build --reconfigure` forces one.]],
  health = [[lw health [<area>...] [--all] [--verbose | -v] [--json]

List the workspace's advisory suggestions — the detail behind the compact
`N suggestions` line the status overview shows. Health is read-only: it runs
no build and authors no project or build-system files, and it ALWAYS exits 0
(a suggestion never gates an operation and is distinct from a diagnostic) —
only an unknown area is an error.

SCOPE — plain `lw health` checks and shows only what THIS workspace uses (over
all its profiles, not only the active one): its modules' build tools, the
compilers and SDKs its profiles use, the compiler caches and editor tools for
its languages, the repo launcher when pinned, submodule drift, and lw itself.
Things it does not use are not probed (other modules' tools, SDKs no profile
pins, editor tools for other languages) or not listed (other compilers the
scan found); a last line counts them: "N other checks not relevant here (...)
- lw health --all". `--all` checks and lists everything, each area's unused
entries after its own under "not used here". Outside a workspace plain
`lw health` shows only lw (and the launcher when a pin is found) and probes
nothing; `lw health --all` there is the whole machine inventory.

AREAS — the report has one section per area, in this order; name areas to
check only those (combinable with --all; e.g. `lw health toolchains cache`):
  lw          the running lw, update check, channel override, plugins
  workspace   the workspace's own state (a refused working copy)
  toolchains  build tools and compilers
  cache       compiler caches and cache-compatibility findings
  sdks        SDK installations
  editor      language servers and debug adapters (editor only)
  launcher    repo launcher and version pin (lw.pin, lw.sh, lw.cmd)
  submodules  git submodule drift
A narrowed run runs only those areas' checks (`lw health launcher` makes no
network request).

Each suggestion prints a one-line title and, when there is something to do, a
short remedy (some add a line of detail). Actionable suggestions — the ones
`lw status` counts as N suggestions — come first, marked "*" and tagged with
their area; informational notes (e.g. "using sccache") follow in their area's
section, marked "-". The report is plain ASCII. Providers are advisory and
extensible; the compiler-cache one gives a one-line verdict for C/C++
workspaces (using <tool> / available but not enabled / not found / not applied
/ /Zi findings) — `lw help cache` explains each. `lw health` additionally checks
whether a newer `lw` release is available on your update channel — for the
bundle and for the lw binary itself (a binary left behind, or one from before
`lw self-update` could replace it) — (this makes a network request, so it runs
only here — never on the passive count) and notes
when a release-url override is superseding a non-default channel. The check is
bounded (5 s to connect, 10 s in all, no retry), so an unreachable network
costs seconds; a failed/offline check prints an informational "update check
skipped — offline or release server unreachable" (not counted). Health never
spawns a cache tool — usage statistics live behind
`lw status --cache-stats`.

`lw health` never reuses an earlier result: every run re-checks what it covers —
the local checks, the environment inventory and the network update check.
Inside a workspace it then saves the results to `.nvim/loomworks.health.json`
(an internal advisory cache, separate from the build cache) so the passive
`N suggestions` count and the editor status page can show them without
re-checking (they never probe and never touch the network). A run narrowed to
areas saves only what it fully re-checked. Outside a workspace nothing is
saved.

ENVIRONMENT INVENTORY — health also lists what this machine has of everything
loomworks knows how to use: build tools (cmake, ninja, make, meson, node, npm),
compilers (gcc/clang on PATH, Visual Studio installs with their default MSVC
toolset version, clang-cl; VS's bundled cmake/ninja under build tools), compiler
caches, language servers (clangd, qmlls) and debug adapters (codelldb, cppdbg,
js-debug — on PATH or in Mason's install directory), SDKs, the module / SDK /
integration plugins (a rejected one with the reason) and lw itself. Marks:
  + found (version, location)   x missing and required
  - missing, not required       ? unknown (the probe failed or timed out)
Inside a workspace each area lists what is REQUIRED first (what the active
profile's projects and toolchains need — every profile's when none is active —
each naming who needs it, compacted to e.g. "2 profiles (dev, asan)"), then
what only other profiles need ("other profiles: asan"); with --all the unused
rest follows, one line per category (`--verbose` lists every item with its
location and every profile/project that needs it). Only a missing REQUIRED
item is a suggestion (and counts toward `lw status`'s N suggestions); the rest
is information. Minimum versions are not checked, and nothing is installed.

Probing runs version queries and the Visual Studio locator (a second or two),
so it happens only here; the result is cached per workspace and the passive
count reuses it without probing — until PATH, the platform, the installed
plugins or the profiles' pinned SDKs change, when the count stops including it
until the next `lw health`. Outside a workspace nothing is
cached.

LAUNCHER — in a repository with a version pin (lw.pin), health checks the
committed launcher files: the pin's hashes, lw.sh / lw.cmd being current, the
lw.sh exec bit and line endings in git, the .gitattributes rules and the
.nvim/cache/ ignore rule. It reports and never fixes — see `lw help launcher`.

SUBMODULES — in a git repository with submodules, health adds informational
notes on how they (recursively) stand against what the repository records:
checkouts off their recorded commit, pins behind their tracked branch (as of
the last fetch), uninitialized submodules and remotes that do not answer. See
`lw help submodules`; `--verbose` lists every submodule.

`--json` prints one JSON document instead of the report, with the same scope
and areas — `{schema, scope (relevant | all), areas?, workspace?,
suggestions[], inventory[], summary, hidden?, update?, submodules?}`; each
suggestion carries its area, each inventory entry id, label, category, area,
status (found | missing | unknown), version, path, detail, hint, required,
required_by (the full list), relevant and used_by (other profiles needing
it); `hidden` counts what the relevant scope left out, per area; `summary` is
`{required_missing, actionable, found, missing, unknown}` over the document's
entries (`--all --json` for every entry); `update` is the
update check's outcome `{status (available | current | unknown), channel,
current, newest?, detail?}`, absent for a development build — and still exits 0
(CI can test `summary.required_missing > 0`).]],
  launcher = [[lw help launcher — repo launcher checks in `lw health`   (also: pin)

In a repository with a version pin (lw.pin, written by `lw bootstrap install`),
`lw health` checks that lw.sh / lw.cmd / lw.pin will work for every contributor
and CI runner. It reports and never fixes; lines start with `launcher:`.

  lw.pin           parses, and has a hash for every platform's lw binary and
                   for the bundle (a missing hash: that platform cannot run)
  lw.sh / lw.cmd   present, and the launcher this lw writes. An older one
                   with a defect that breaks runs is a suggestion; one that
                   is only older (no download retry, noisy progress) is a
                   note; content lw never wrote is a suggestion (local edits?
                   `lw bootstrap install --force` restores it)
  committed        lw.pin, lw.sh, lw.cmd, .gitignore and .gitattributes are
                   committed - untracked, staged-only or modified files are
                   listed with the `git add ... && git commit` to run
  exec bit         lw.sh is committed as mode 100755 (bootstrapped on Windows
                   it may not be: CI on Linux/macOS then cannot run it)
  .gitattributes   lw.sh and lw.pin `text eol=lf`, lw.cmd `text eol=crlf`,
                   from committed content (your global attributes file, or
                   rules not committed yet, do not count)
  line endings     committed LF-only; in this checkout lw.sh / lw.pin LF and
                   lw.cmd CR LF (a CR LF lw.sh fails under sh)
  .nvim/cache/     ignored by a committed .gitignore of the repository - a rule
                   only in your personal gitignore, or in a .gitignore not
                   committed yet, does not count (teammates and CI do not have
                   it)
  old binaries     cached lw binaries of other versions (removed by the next
                   `lw bootstrap install`)

In a pin-only repository (lw.pin without lw.sh / lw.cmd, written by `lw
bootstrap install --pin-only`) the missing launchers are intended: only the
lw.pin checks run.

The usual remedy is the repair, which rewrites the launchers and adds the
missing rules without moving the pin (add --pin-only in a pin-only repository):

  lw bootstrap install        (./lw.sh bootstrap install through the launcher)

`lw bootstrap` shows the same checks as a status page, with what to do next.

Line endings already committed wrong need `git add --renormalize lw.sh lw.cmd
lw.pin` once the attributes are in place. Git checks need git and a git work
tree; without them only the file checks run. Health never stages or commits.]],
  submodules = [[lw help submodules — submodule drift in `lw health`   (also: submodule)

When the workspace root lies in a git repository with a .gitmodules file,
`lw health` reports its submodules — nested ones included — against what the
repository records. Every note is informational ("·"): none is counted in
`lw status`'s N suggestions, since a checkout ahead of its pin is ordinary work
in progress and an unused submodule may be left uninitialized on purpose.
One line per kind of finding names the first few submodules; `lw health
--verbose` lists them all, `lw health --json` has a `submodules` report.

CHECKED OUT OFF THE RECORDED COMMIT — the commit checked out in a submodule is
not the one its parent records (the parent's index, as `git submodule status`
compares): N ahead / N behind / diverged (both) / unrelated (no common
history) / pin not fetched (the recorded commit is not in the submodule) /
conflicted (unmerged gitlink). Fix: restore the recorded commits with
  git submodule update --init --recursive
or, when the checkout is what you want, record it in the parent:
  git add <path> && git commit

PINS BEHIND THEIR TRACKED BRANCH — the recorded commit against the branch the
submodule tracks, as of the LAST FETCH (no network is used): the .gitmodules
`branch` for it (`.` = the parent's current branch), else the remote's
default branch (`origin/HEAD`). "5 behind origin/dev" means the branch moved on
since the pin; "ahead of" means the pin is not on that branch (others may not
be able to fetch it). Refresh with `git -C <path> fetch`; move the pin by
checking out the newer commit and `git add <path>`.

NOT INITIALIZED — including nested submodules (inside an initialized one).
Fix: git submodule update --init --recursive.

REMOTES — for an uninitialized submodule, health asks the remote an
initialization would clone for its HEAD (`git ls-remote`): the parent's
configured URL, else the .gitmodules one — a relative URL (`../LumeBase`)
resolves against the parent's `origin`, which fails when that remote (a fork,
a mirror) does not host the sibling repository. At most 16 network remotes
(and 64 local paths) are probed, all at once, under a 10 s budget, with
credential prompts disabled; "unreachable" means the remote answered with an
error, while a remote that did not answer in time is only "not verified".

COST — git runs only on `lw health`, never on `lw status` or the editor's
status page: one `git submodule status --recursive`, then small bounded
queries (ahead/behind counts) and the remote probes. Git is run without
optional locks, so health never rewrites the repository's index; nothing is
fetched, and these notes are not cached.]],
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
with `lw settings set module-index <url-or-path>` or LOOMWORKS_MODULE_INDEX.

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
  lw configset publish <name>         (also writes its mapped projects/configs)
  lw config publish <project> <name>
  lw profile publish <key>            (also writes its set + projects)
Each marks the item local+shared and regenerates loomworks.json.

Configuration sets are the portable unit teams share: a profile pins a
machine-specific tool, so publishing config sets (+ projects) lets everyone —
and each CI runner — pick a local tool and create their own profile
(`lw profile create <set> <tool>`). You CAN publish a profile too; it just
resolves as incomplete for anyone without that tool.

Bare `lw publish` warns if the result is empty (nothing is shared yet).

`lw export --published` prints what `lw publish` would write, without writing
it. To carry the whole configuration (local items too) to another machine,
`lw export` here and `lw import` there.

It changes several workspace files as one operation, holding the workspace
operation lock (.nvim/loomworks.op.lock): a second such operation fails
fast with "workspace busy". `--break-locks[=now]` recovers the lock from a
hung holder (see `lw help unlock`).]],
  export = [[lw export [--published] [--no-profiles] [-o <file>]

Print this workspace's configuration as a loomworks.json, without publishing:
to carry it to another machine (`lw import` there), or to see what a publish
would write. Read-only: no file, intent or cache changes.

By default every project, configuration, configuration set and profile is
included, whatever its intent (local, local+shared, shared) — as if all were
published. Machine-local settings never are, exactly as with `lw publish`: the
active profile, device selections, profile variable fills, SDK declarations,
language-server options and debug-adapter choices stay on this machine.

  --published       only what `lw publish` would write now (a dry run of it)
  --no-profiles     leave profiles out: a profile pins toolchains found on THIS
                    machine; configuration sets + projects are the portable part
  -o, --output <f>  write to <f> instead of stdout (`-` = stdout). Refuses this
                    workspace's own loomworks.json and anything under .nvim/.

stdout carries only the JSON, so `lw export > config.json` works; the summary
goes to stderr. Program settings (launch commands, environments, …) are
exported too; on the other machine `lw import` brings them into effect after
you review them — a loomworks.json copied there ignores them.

  lw export > app.json             then, on the other machine: lw import app.json
  lw export | ssh build-box 'cd src/app && lw import - --yes']],
  import = [[lw import <file> [--dry-run] [-y | --yes] [--take-name]   (`-` reads stdin)

Replace this workspace's working configuration (.nvim/loomworks.user.json)
with one made by `lw export` (any loomworks.json works). Projects,
configurations, configuration sets and profiles become exactly the imported
ones. The workspace keeps its own name (the summary shows the export's when it
differs); --take-name adopts the exported name instead. What an export cannot
carry stays: SDK declarations, language-server options, debug adapters, and —
for profiles that still exist — the active profile, device selection and
variable fills.

Nothing is published: loomworks.json is untouched. An imported item your
working copy already has keeps its intent (local / local+shared), so exporting
and importing on the same workspace changes nothing. A new item is
local+shared when loomworks.json already has it (`lw publish` would update
it), else local. With --shared every imported item except profiles is
local+shared; with --local all are local. Build directories are never deleted
— those no profile uses any more stay on disk (`lw reset --all` removes them).

Importing trusts the file: its program settings (launch commands,
environments, …) will be used. Import shows what changes — intent changes, the
active profile, dropped device selections and fills — and those settings
(`(new)` = not in your current working copy), then asks.

A working copy not signed by this machine (written by an older lw, or by hand)
does not block an import: it is replaced unread — none of its settings is kept
— after the usual backup.
  -n, --dry-run   show the summary and review, write nothing
  -y, --yes       don't ask (required with --no-input, and when reading stdin)
  --take-name     use the exported workspace name instead of keeping this one

The previous working copy is saved as .nvim/loomworks.user.json.<time>.bak;
copy it back over .nvim/loomworks.user.json to undo. A working copy
(.nvim/loomworks.user.json) is not an export: on the same machine use
`lw pull`; from another machine run `lw export` there.

It changes several workspace files as one operation, holding the workspace
operation lock (.nvim/loomworks.op.lock): a second such operation fails
fast with "workspace busy". `--break-locks[=now]` recovers the lock from a
hung holder (see `lw help unlock`).]],
  pull = [[lw pull [<source>] [--dry-run]

Fold another checkout's working config into THIS checkout's working copy
(.nvim/loomworks.user.json), so a fresh `git worktree` — which starts with no
.nvim/ and therefore no profiles — inherits a ready-to-build configuration
without re-authoring it.

  <source>    A checkout/worktree directory to pull from. Omitted, the main
              worktree of the current git worktree is used (the same detection
              `lw status` hints with). Errors, never guesses, when no source is
              given and you're not in a linked worktree, when the source has no
              working copy, or when it resolves to this same checkout.
  --dry-run   Report the plan (added / updated / kept) without writing.
              (alias -n)

What it pulls: the source's working config — projects (with their
configurations, launch configs, deploy steps, variables), configuration sets,
profiles, SDK declarations, per-profile default targets, and the debug-adapter /
lsp-option maps. When the source's config is internally consistent, every
reference (set -> projects/configs, profile -> set) stays satisfied.

What it does NOT pull: the ACTIVE PROFILE, the workspace NAME, and the per-machine
DEVICE selection (each checkout keeps its own), plus all build/cache state (that
lives in .nvim/loomworks.cache.json, never the working copy).

Merge: a non-destructive, item-level union where the SOURCE wins on a name
collision — items only here are kept, items in both take the source's version,
items only in the source are added. The debug-adapter and lsp-option maps are
unioned per key (a pulled `c++` adapter keeps your `typescript` one). It writes
the working copy only; it never publishes loomworks.json and never touches the
cache or build dirs.

Another machine? A working copy is signed for the machine that wrote it, so pull
cannot read one copied from elsewhere: run `lw export > file.json` there and
`lw import file.json` here.

It changes several workspace files as one operation, holding the workspace
operation lock (.nvim/loomworks.op.lock): a second such operation fails
fast with "workspace busy". `--break-locks[=now]` recovers the lock from a
hung holder (see `lw help unlock`).]],
  worktree = [[lw worktree [list]
       lw worktree add <branch> [<start-point>] [--no-pull]

Inspect or create the git worktrees of the current repository.

  list  (also bare `lw worktree`)
        List every worktree and whether loomworks is initialised in each (a
        workspace file — loomworks.json or the working copy
        .nvim/loomworks.user.json — is present). Read-only; works from a
        worktree that has no workspace of its own yet. Each row shows the
        worktree path, its branch (`[branch]`, `[detached <sha>]`, or `(bare)`),
        a `main` marker on the repository's main worktree, a `*` marker on the
        worktree you are in, and `workspace` / `no workspace`.

  add <branch> [<start-point>] [--no-pull]
        Create a worktree at <main>/.worktrees/<branch> — the FULL branch path
        is mirrored as directories, so `feature/x` lands at
        `.worktrees/feature/x`. <main> is the repository's main worktree, so
        `add` works from any worktree. A new <branch> is created (from
        <start-point>, else main's HEAD); an existing <branch> is checked out
        (git errors if it is already checked out elsewhere). Then, unless
        --no-pull, it folds the main checkout's working config into the new
        worktree (`lw pull`) so it is ready to build.

        Non-destructive: it never overwrites — a pre-existing target path is
        refused, and if the auto-pull fails after the worktree is created the
        worktree is KEPT (run `lw pull` inside it by hand) and the exit is
        non-zero. --no-pull creates the worktree only.

Requires git: unlike the status hint, `lw worktree` errors (non-zero) when git
is unavailable or the current directory is not a git repository, rather than
degrading silently. An unknown subcommand is an error.]],
  project = [[lw project <add|remove|rename|list|show|set|unset|describe|publish>

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
        ready to map — see `lw config list <name>`.
  remove <name>
        Drop a project. <name> is the unique project key (`lw project list`).
  rename <old-name> <new-name>       (alias: mv)
        Rename a project's key. Updates every profile mapping and configuration
        set that references it; `lw publish` then rewrites loomworks.json.
  list  Show all projects: key, type, path.
  show <name>
        Detail one project: type, path, its configurations, its variable
        declarations, the sets that map it, and its intent.
  set <project> <variable> [<default>] [--type string|path]
        Declare (create-or-update) a project variable. --type defaults to
        `string`. Omit <default> to declare it BLANK — a variable with a type
        but no value that the active profile must fill before a build using it.
        --type may come before or after the optional <default>.
  unset <project> <variable>
        Remove a variable declaration (and any configuration overrides of it).
  describe <project> [<text> | -m <para>... | -F <file> | -F - | - | -e | --clear | --json]
        Print or set the project's description (see `lw help describe`).
  set <project> device.stage|device.archive <glob>...
  set <project> device.working_dir <dir>
  set <project> device.env.<NAME> <value>
  unset <project> device | device.<field> | device.env.<NAME>
        Edit the project's device block (what a device run copies and how it
        runs it — `lw help device`) in your local config. A glob list replaces
        the previous one.
  publish <name>
        Mark the project shared (local+shared) and regenerate loomworks.json.

A declared variable feeds three surfaces:
  lw project set <p> <var> [<default>] [--type …]   declare it here
  lw config set <p> <cfg> variables.<var> …         override per configuration
  lw profile set [<profile>] <p> <var> <value>       fill a blank per profile

Examples:
  lw project set  App out_dir '${project_path}/dist' --type path
  lw project set  App sdk_root --type path      # blank; fill with `lw profile set`
  lw project set  App port 8080                 # string (the default type)
  lw project unset App out_dir

rename / remove / publish change several workspace files as one operation,
holding the workspace operation lock (.nvim/loomworks.op.lock): a second such
operation fails fast with "workspace busy". `--break-locks[=now]` recovers
the lock from a hung holder (see `lw help unlock`).]],
  config = [[lw config <list|add|show|get|set|unset|rename|describe|remove>   (aliases: configuration, cfg)

Manage a project's build configurations in the working copy; `lw publish`
shares the result. Configs are addressed by name (an unambiguous base name
works too). set/unset/remove act on user configs only.

cmake/meson projects already expose auto configurations (variant:Debug,
variant:Release, …) that you can map into a set directly — `add` is only for
custom variants.

  list [project]                     configs for one project, or all
  describe <project> <config> [<text> | -m <para>... | -F <file> | -F - | - | -e | --clear | --json]
                                     print or set the configuration's
                                     description (`lw help describe`); also
                                     `set/unset <project> <config> description`
  add <project> <name> [base...]     create a user configuration, inheriting
                                     the given bases (e.g. variant:Release
                                     asan). Several bases form a mixin chain
                                     merged left to right; a comma-separated
                                     list works too.
  show <project> <name>              detail: variant, inherits, options, ...
  get <project> <name> <param>       print one value
  set <project> <name> <param> <value>
  unset <project> <name> <param>     clear one value
  rename <project> <old> <new>       (alias: mv) rename a user configuration in
                                     place; updates every set mapping and profile
                                     that references it (user configs only)
  remove <project> <name>            delete a user configuration

A config becomes concrete by INHERITING a base that provides a variant; the
variant is not settable directly, so the build type has one declared source
(the built-in `variant:*` configs). Without a base a config is an abstract
mixin — usable as a base, never built.

Params for get/set/unset:
  inherits                    comma-separated base configs (a mixin chain)
  languages                   comma-separated; empty inherits from the module
  options.<KEY>               a generic build option
  variables.<NAME>            a project variable override
  env.<NAME>                  a configuration environment variable
  overrides.<family>.<NAME>   a compiler-family variable override
  overrides.<family>.env.<NAME>  an environment variable for that family only
  <other>                     any module-specific field (e.g. toolchain, generator)

Environment names: the compiler-driver variables (CC, CXX, FC, CUDACXX,
CUDAHOSTCXX, OBJC, OBJCXX, ISPC — in any case) are refused: the profile's tool
chooses the compiler. Setting PATH (any case) is allowed but REPLACES the PATH
the tool sets up (e.g. the MSVC developer environment), so lw warns. Names are
one entry per name ignoring case: setting env.Path when env.PATH exists
replaces it (keeping the new spelling), and lw says so.

Compiler-family overrides (family ∈ clang|gcc|msvc, clang-cl counts as clang)
override a project variable's value only when the active tool's compiler
belongs to that family. The overridden name must already be declared in the
project's `variables` (an empty default is allowed).

Examples:
  lw config set   App Debug options.CMAKE_CXX_FLAGS '${warn_flags}'
  lw config set   App Debug variables.warn_flags '-Werror'
  lw config set   App Debug overrides.clang.warn_flags '-Werror -Wno-unused-command-line-argument'
  lw config get   App Debug overrides.clang.warn_flags
  lw config unset App Debug overrides.clang.warn_flags
  lw config rename App Debug Debug-asan

rename / remove / publish change several workspace files as one operation,
holding the workspace operation lock (.nvim/loomworks.op.lock): a second such
operation fails fast with "workspace busy". `--break-locks[=now]` recovers
the lock from a hung holder (see `lw help unlock`).]],
  configset = [[lw configset <list|show|create|map|unmap|rename|describe|remove>   (aliases: configuration-set, cs)

A configuration set maps each project to one of its configurations — the
cross-project selection a profile builds. Managed in the working copy;
`lw publish` shares it.

  list                                all sets and their mappings
  show <name>                         one set: mappings, validity, profiles
  create <name> [project=config ...]  create a set (optionally with mappings)
  map <name> <project> <config>       set/replace one project's mapping
  unmap <name> <project>              drop a project's mapping
  rename <old> <new>                  (alias: mv) rename the set; re-derives the
                                      keys of profiles that reference it
  remove <name>                       delete the set
  describe <name> [<text> | -m <para>... | -F <file> | -F - | - | -e | --clear | --json]
                                      print or set the set's description
                                      (`lw help describe`)

<config> is a configuration name (an unambiguous base name works, so `Debug`
resolves `variant:Debug`). Build a set with `lw profile create <name> <tool>`.

Examples:
  lw configset rename Dev Development

rename / remove / publish change several workspace files as one operation,
holding the workspace operation lock (.nvim/loomworks.op.lock): a second such
operation fails fast with "workspace busy". `--break-locks[=now]` recovers
the lock from a hung holder (see `lw help unlock`).]],
  describe = [[lw <project|config|configset|profile> describe <item> [text | flags]

Projects, configurations, configuration sets and profiles can carry an
optional description. It reads like a git commit message: the first line is
the summary (shown, shortened with …, next to the item in `lw status` and the
list commands), the rest is the body (shown by `show` and by `describe`).

  lw project describe <project>             print it (nothing if none)
  lw project describe <project> --json      {"kind","name","description","summary","source"}
  lw project describe <project> "text"      set it (quote it as one argument)
  lw project describe <project> -m <para>   set it; repeat -m for more paragraphs
                                            (the first -m is the summary)
  lw project describe <project> -F <file>   read it from a file
  lw project describe <project> -F -        read it from stdin (also a lone -)
  lw project describe <project> -e          edit it in $VISUAL / $EDITOR; lines
                                            starting with # are ignored
  lw project describe <project> --clear     remove it

Long forms: --message for -m, --file for -F, --edit for -e.

The same forms work for `lw config describe <project> <config>`,
`lw configset describe <set>` and `lw profile describe <profile>`. An empty
description ("" or an empty file) removes it too. Descriptions are display text
only: they never change a build. Generated configurations (variant:*,
preset:*) cannot be described; a CMake preset's own displayName/description
is shown instead. `-m <para>` also works on `add`/`create`. -e needs a
terminal; under --no-input use -m, -F or a text argument.

Examples:
  lw profile describe dev -m "Clang debug build with ASan" -m "For the nightly sanitizer run."
  git log -1 --format=%B | lw configset describe Release -]],
  profile = [[lw profile <list|show|select|create|remove|publish|query|set|unset|describe>
  (`lw profiles` is an alias for `lw profile list`)

  list      list the workspace's profiles and their buildability
  show [<profile>]
            One-screen status view for a single profile: its configuration
            set and mappings, the projects the set maps (with each one's
            configuration, resolved toolchain and build state), the profile's
            toolchains, and its launchable targets. Diagnostics are scoped to
            the profile. <profile> defaults to the active profile. Read-only.
  select [<profile> | --none]
            Set the active profile (writes user.json). A named <profile> (a
            unique substring works) needs no terminal, so your own scripts can
            switch it; --none clears the active profile. With neither, an
            interactive picker. Re-selecting the active profile changes nothing.
  create <config-set> [tool ...] [--activate | -a]
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
  remove <profile>
            Drop a profile from the working copy. Removes the profile only —
            its build directories are left in place: `lw reset <profile>`
            first deletes them; afterwards only `lw reset --all` does (it
            resets every profile). Clears the active selection if it pointed
            here.
  publish <profile>
            Mark the profile shared (local+shared) and regenerate
            loomworks.json, including the set and projects it needs.
  query <profile> <project> <field>
            Print one machine-readable fact for scripting (e.g. CI artifact
            collection). Read-only; no build. Fields:
              build-dir  absolute build directory (known before building)
              config     the pinned configuration name
              state      last known build state (unconfigured/configured/built…)
              tool       the resolved toolchain key
              cache      the resolved compiler cache, as the `Cache` row shows
                         it (sccache / off / auto (none found) / auto (off for
                         MSVC-style) / ccache (not found) / not applied
                         (<reason>));
                         empty for a project with no C/C++ compiler cache
              variables  resolved project variables (name=value lines);
                         variables.<name> prints one
            e.g. BD=$(lw profile query Debug:ninja-clang-18 app build-dir)
  describe <profile> [<text> | -m <para>... | -F <file> | -F - | - | -e | --clear | --json]
            Print or set the profile's description (`lw help describe`).
            <profile> is required (never the active profile by default).
  set [<profile>] <project> <variable> <value>
            Set this profile's machine-local fill value for a BLANK project
            variable (one declared with no default — an SDK path, a device
            address that differs per machine). Written to user.json only and
            never published. <profile> defaults to the active profile. A build
            refuses while a blank is unfilled (`lw status` flags it).
  unset [<profile>] <project> <variable>
            Clear a profile's fill value for a project variable.

The active profile is the default for `lw build`. Profiles and toolchains
resolve by a TRUNCATED selector, matched at segment boundaries: `ninja-clang-18`
picks the highest `18.x`, and `msvc-17` picks an installed VS 17 without naming
the edition. A truncated selector never crosses a boundary (`…-1` never matches
`…-18`), and a substring like `lw build clang-19` works when unambiguous.

rename / remove / publish change several workspace files as one operation,
holding the workspace operation lock (.nvim/loomworks.op.lock): a second such
operation fails fast with "workspace busy". `--break-locks[=now]` recovers
the lock from a hung holder (see `lw help unlock`).]],
  settings = [[lw settings <list|get|set|unset> [key] [value]

Read or write lw's OWN user settings (]] .. config_path() .. [[). This is lw's
tool configuration — distinct from `lw config`, which edits a project's build
configurations.

  list                 show all settings and the file path
  get <key>            print one setting
  set <key> <value>    set a setting
  unset <key>          remove a setting

Keys:
  dev-lua         a checked-out loomworks `lua/` directory to run from
                  (the development source).
  default-source  `dev` or `release`. `dev` makes `lw` use dev-lua without
                  needing `--dev` each time; `release` (default) uses the
                  verified release bundle.
  release-url     override where releases are fetched from (a local directory
                  works as an offline mirror); LOOMWORKS_RELEASE_URL wins.
  module-index    where `lw module install` / `lw module update` read the
                  module index from (a URL or a local path);
                  LOOMWORKS_MODULE_INDEX wins. See `lw help module`.
  channel         `stable` (default) or `unstable`. The update channel
                  `lw self-update` follows. `unstable` includes
                  pre-releases; both are equally signature/hash-verified.
                  LOOMWORKS_CHANNEL, or `lw self-update --channel`, overrides.
  release-notes   `on` (default) or `off`. `off` silences the one-line
                  "updated" notice and self-update's "what's new" lines;
                  LOOMWORKS_RELEASE_NOTES wins.

Source precedence (resolved by the host before commands run):
  LOOMWORKS_LUA env > `--dev[=PATH]` > default-source=dev > release bundle.
Dev sources are your own checkout and are not signature-verified.]],
  completion = [[lw completion <bash|zsh>

Print a shell completion script to stdout. It writes nothing to your shell
config — you choose how to enable it, so nothing is installed behind your back:

  eval "$(lw completion bash)"      # this session only
  echo 'eval "$(lw completion bash)"' >> ~/.bashrc   # persist it yourself

Completes commands, subcommands, project / config-set / profile names,
toolchains (from the cache — no scan), configuration names, module types, and
paths. `lw` must be on PATH so the completion can call it back. Completion is
non-interactive and never blocks; names come from a fast (~250ms) load.]],
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
  lw project list | show <name>   lw profile list   lw tools [--cached]
  lw config list|show|get         lw configset list|show
  lw profile query <profile> <project> <field>   (build-dir | config | state | tool | cache | variables[.<name>])
  lw build <profile> [-- args]    builds; read-only toward config (writes only
                                  the build dir + cache)
  lw version

Mutating — only when the task asks (these write the working copy / shared file):
  init · workspace rename · project add|remove|rename ·
  config add|set|unset|rename|remove ·
  configset create|map|unmap|rename|remove · profile create|remove ·
  sdk add|remove ·
  <kind> publish · publish · settings set

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
  sdk = [[lw sdk <types|detect|list|add|remove>

Declare a toolchain installation — one auto-detection cannot find (a compiler
at an arbitrary path, a custom build, a cross-compiler), or a platform SDK its
provider detects. A declared SDK produces a toolchain, so it appears in
`lw tools` and can be pinned by `lw profile create`. Declarations live in the
working copy (machine-local).

  types                 SDK provider ids available on this host. Plugins add
                        more by shipping a provider (e.g. a platform SDK).
  detect [<type>]       The installations each provider (or one) detects on
                        this host. Read-only; works outside a workspace.
  list                  declared SDKs and their paths
  add <type>            Declare the installation the provider detects (as
                        `detect` lists it). None detected is an error — pass
                        the path. Several: pick one (interactive), or, with
                        --no-input, an error listing each as the explicit
                        command. One already declared is not offered again.
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
  lw profile create Debug cpp_compiler-clang-19
  lw sdk detect            # what each provider finds here
  lw sdk add ohos          # declare the detected installation (plugin provider)]],
  ci = [[lw help ci — driving CI jobs with lw

Model: commit the CONFIGURATION SETS (the portable unit) and the projects.
Each matrix cell then picks a local toolchain by major version and creates its
own profile — profiles are per-machine and need not be committed. Run every
command with --no-input (or LW_NO_INPUT=1 / the conventional CI env var); see
`lw help agent` for the non-interactive contract.

1. Get lw on the runner: commit a pinned launcher once
   On a dev machine, once: `lw bootstrap install` (see `lw help bootstrap`), then commit
   lw.sh, lw.cmd, lw.pin (+ .gitattributes / .gitignore). Every job then runs the
   pinned, hash-verified lw straight from the checkout - no install step, no
   `lw self-update`, the same release on every runner:
     ./lw.sh --no-input build Debug:ninja-clang-18    Linux, macOS, Git Bash
     .\lw.cmd --no-input build Debug:ninja-clang-18   cmd, PowerShell
   GitHub Actions on Windows: `shell: bash` runs ./lw.sh; `shell: pwsh` or
   `cmd` runs .\lw.cmd (keep the `.\`: a bare lw.cmd can pick up another one
   on PATH). The first run downloads the lw binary into .nvim/cache/ (retrying
   a failed download) and the release bundle into the per-user data dir; cache
   them keyed on lw.pin to skip that. Move the pin with `./lw.sh bootstrap
   upgrade` and commit the result; `lw bootstrap --check` fails a job when the
   launcher files need attention (`lw bootstrap` shows why). Air-gapped
   runner: point LOOMWORKS_RELEASE_URL at a local mirror directory. (A global
   install also works - `lw help install` - and honors the pin for
   build/run/test/clean; `lw bootstrap install --pin-only` commits just the
   pin for that setup.)
   Below, `lw` stands for ./lw.sh or .\lw.cmd.

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

-- The host commands' help is owned by the host (boot.help, spec §16.7): the
-- same complete text with or without a bundle. boot.help first ships in the
-- v0.1.34 host, and an older host runs this bundle after `lw self-update`, so a
-- missing boot.help must not break loading the CLI: those topics then get a
-- short "host too old" note. (An immediately-invoked function, not a `do`
-- block: this main chunk is at LuaJIT's 200-local limit.)
;(function()
  local ok, bh = pcall(require, "boot.help")
  local topics = ok and type(bh) == "table" and type(bh.TOPICS) == "table" and bh.TOPICS or {}
  for _, k in ipairs({ "version", "install", "self-update", "bootstrap", "release" }) do
    HELP[k] = topics[k]
      or ("lw " .. k .. ": this lw binary (host) is too old to document this command.\n"
        .. "Install the current lw binary as in the README's \"Installing lw\"; "
        .. "`lw self-update` keeps it current from then on.")
  end
end)()

--- Command aliases → their canonical help topic.
local HELP_ALIASES = {
  configuration = "config",
  ["configuration-set"] = "configset",
  cs = "configset",
  cfg = "config",
  profiles = "profile",
  sccache = "cache",
  ccache = "cache",
  ["compiler-cache"] = "cache",
  submodule = "submodules",
  pin = "launcher",
  ws = "workspace",
  mod = "module",
}

--- Whether `lw help <cmd>` has a topic (after alias normalization).
--- @param cmd string|nil
--- @return boolean
function M.has_help_topic(cmd)
  return cmd ~= nil and HELP[HELP_ALIASES[cmd] or cmd] ~= nil
end

--- The section of `HELP[cmd]` that documents sub-command `sub`, or nil when the
--- topic has no entry for it. An entry is a line indented by exactly two
--- spaces that starts with the sub-command's name, plus its deeper-indented
--- continuation lines (up to the next entry or a blank line). Any unindented
--- paragraph whose heading names the sub-command (e.g. `Params for
--- get/set/unset:`) follows it, then a pointer to the full topic.
--- @param cmd string canonical topic
--- @param sub string
--- @return string|nil
function M.subcommand_help(cmd, sub)
  local text = HELP[cmd]
  if not text or type(sub) ~= "string" or not sub:match("^%a[%w_-]*$") then return nil end
  local lines = vim.split(text, "\n", { plain = true })
  local entry
  for i, l in ipairs(lines) do
    if l:match("^  %S") and (l:sub(3, 2 + #sub) == sub)
        and (#l == 2 + #sub or l:sub(3 + #sub, 3 + #sub):match("%s")) then
      entry = { "lw " .. cmd .. " " .. l:sub(3) }
      for j = i + 1, #lines do
        local c = lines[j]
        if c:match("^%s*$") or not c:match("^   ") then break end
        entry[#entry + 1] = c
      end
      break
    end
  end
  if not entry then return nil end
  -- Headed paragraphs naming the sub-command as a word (`get/set/unset:`).
  local i = 1
  while i <= #lines do
    local l = lines[i]
    if l:match("^%S.*:$") and (("/" .. l:gsub("%s", "/") .. "/"):find("[^%w_-]" .. sub:gsub("%-", "%%-") .. "[^%w_-]")) then
      entry[#entry + 1] = ""
      while i <= #lines and not lines[i]:match("^%s*$") do
        entry[#entry + 1] = lines[i]
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  entry[#entry + 1] = ""
  entry[#entry + 1] = "`lw help " .. cmd .. "` for the whole command."
  return table.concat(entry, "\n")
end

--- `lw help [<command> [<sub-command>]]`.
--- @param cmd string|nil
--- @param sub string|nil sub-command: print only its section when it has one
function M.cmd_help(cmd, sub)
  -- Normalize command aliases to their canonical help topic.
  cmd = cmd and (HELP_ALIASES[cmd] or cmd) or nil
  if cmd and HELP[cmd] then
    out(M.subcommand_help(cmd, sub) or HELP[cmd])
    return 0
  end
  if cmd then errw("lw: no help topic '" .. cmd .. "'\n") end
  out([[lw — loomworks standalone runner

Usage: lw [command] [args]

  status            workspace status + active profile (also bare `lw`)
  init              initialize the workspace working copy
  workspace <sub>   show / rename the workspace  (ws)
  project <sub>     add | remove | rename | list | show | set | unset
                    describe | publish
  config <sub>      list | add | show | get | set | unset | rename
                    describe | remove | publish
  configset <sub>   list | show | create | map | unmap | rename
                    describe | remove | publish
  profile <sub>     list | show | select | create | remove | publish
                    query | set | unset | describe
  tools [--cached]  list detected toolchains (scans; --cached reads the cache)
  sdk <sub>         declare toolchain installations (types|detect|list|add|remove)
  build [profile]   build a profile (configure if needed, then build)
  clean [profile]   build-system clean (remove artifacts, keep configuration)
  reset [profile]   hard reset: rm the build dirs, back to unconfigured (--all)
  unlock <profile>  clear a stuck build-dir lock (--all, --force, --device <serial>)
  daemon <sub>      the workspace daemon: status | list | stop | kill | restart | run
                    (experimental, opt-in: runtime-mode)
  trust             review + re-sign the working copy (see `lw help trust`)
  nuke              delete all build state (.nvim/build + caches)
  cleanup           list / remove what lw left outside the workspace (--yes, --all)
  test  [profile]   build a profile, then run its tests (real exit code)
  run [target]      build, then execute a target on the active profile
  run <profile> <target>  same, on a named profile
  target [profile]  list a profile's launchable targets (default marked *)
  target set|clear  set / clear a profile's default target
  device <sub>      list | select | clean devices for cross-built programs
  launch <sub>      launch configurations: list | add | set | show | remove
                    rename | describe
  publish           write loomworks.json from the working copy
  export [-o <file>] print the whole config as a loomworks.json (another machine)
  import <file>     replace the working config with an export (--dry-run, -y)
  pull [<source>]   fold another checkout's working config into this one
  worktree <sub>    list the repo's git worktrees, or `add` a new one (+ pull)
  migrate [--check] bring the workspace files up to current conventions
  health            what this workspace needs: suggestions + inventory (--all: everything)
  module <sub>      install | update | remove | list acquirable modules (mod)
  settings <sub>    list | get | set | unset lw's own settings (dev-lua, …)
  completion <shell> print a shell completion script (bash|zsh)
  version           host version + which system-Lua source (also -v, --version)
  install           install the lw binary on PATH + fetch the first bundle
  self-update       download + verify the latest release (bundle + lw binary)
  release-notes     what changed in each release (--since <version>, --all)
  release query     the newest verified release on a channel (--channel, --json)
  bootstrap [install|upgrade]  repo-local launcher + version pin: status / write / bump
  help  [command]   this help, or details for a command

Quickstart (empty dir -> first build -> shared config):
  lw init                                  initialize the workspace
  lw project add <path>                    register a project (type auto-detected)
  lw configset create <name> <project>=<config>   map a config set (e.g. app=Debug)
  lw profile create <set> <tool>           make a buildable profile (`lw tools`)
  lw build <profile>                       build it
  lw publish                               write the shared loomworks.json

Items you add/create default to local+shared, so `lw publish` writes them to the
committed loomworks.json — profiles excepted, as they pin toolchains found on
this machine. Use --local to keep something private, --shared to share a
profile; or share later with `lw <project|profile|configset> publish
<name>`. See `lw help publish` for the intent model.

New cmake/meson projects already expose configurations (Debug, Release, …) to
map — `lw config list <project>` shows them; you only add configurations
for custom variants.

Global: --no-input (alias --non-interactive) never prompts — a missing
required value errors instead of waiting. Also enabled by LW_NO_INPUT or CI.
--no-daemon: this command starts no workspace daemon; in daemon mode its
build/test/run/clean/reset run the daemon's code in this process, or use a
running daemon (`lw help daemon`).
Otherwise prompting is on only when stdin is a terminal. In non-interactive
mode `lw build` also ignores the active profile (and never picks a sole profile)
— pass the profile explicitly.

Topics (`lw help <topic>`): agent, ci, cache, describe, launcher, submodules

Automation agent? See `lw help agent` — run with --no-input so you never block
or change the user's settings. Driving CI? See `lw help ci`. Compiler cache
(ccache/sccache)? See `lw help cache`.

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

--- Strip `--break-locks` / `--break-locks=now` from `argv` (before any `--`)
--- and configure loomworks.lock_break for this run; records this process as
--- an `lw` lock holder (spec §19.5). Returns the remaining argv.
--- @param argv string[]
--- @param command string|nil
--- @return string[]
function M._take_break_locks(argv, command)
  require("loomworks.lock_record").set_holder_kind("lw")
  local lb = require("loomworks.lock_break")
  lb.command = command and ("lw " .. command) or "lw"
  lb.report = function(line) errw("lw: " .. line .. "\n") end
  local kept, after = {}, false
  for _, v in ipairs(argv) do
    local mode = (not after) and lb.parse_flag(v) or nil
    if v == "--" then after = true end
    if mode == false then
      die("--break-locks takes no value, or `=now` — see `lw help " .. tostring(command) .. "`", 2)
    elseif mode then
      lb.requested = mode
    else
      kept[#kept + 1] = v
    end
  end
  return kept
end

local function main()
  -- A workspace operation lock (spec §19.3) taken inside a guarded operation
  -- is released on every exit path, `die` included.
  on_exit(function()
    pcall(function() require("loomworks.txn").abandon() end)
    pcall(function() require("loomworks.op_lock").release_all() end)
  end)
  -- Before any dispatch: release held build-dir locks if we're interrupted
  -- (Ctrl-C's SIGINT reaches the whole foreground group and would otherwise
  -- kill lw before its exit hooks run — see install_interrupt_handler).
  install_interrupt_handler()

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
    elseif v == "--no-daemon" then
      -- Attached (spec §19.1): launch and use no daemon for this command.
      M._no_daemon = true
    elseif v == "--dev" or v:sub(1, 6) == "--dev=" or v == "--no-pin" then
      -- Source selection and pin redirect are resolved by the host bootstrap
      -- (main.lua) before we run; ignore these here so the nvim-hosted path
      -- doesn't choke on them.
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
    finish(M.cmd_help(a[2], a[3]))
  end
  -- `lw <command> … --help` / `-h` (before any `--`, whose tail belongs to a
  -- build tool / program) is `lw help <command>` for every command, checked
  -- before any handler can read the flag as an operand (`lw build --help`
  -- used to look for a profile named "--help"). A command without a topic of
  -- its own gets the general usage. A sub-command (`lw profile query --help`)
  -- gets its own section of the parent topic when it has one. Exit 0 either way.
  if command then
    for i = 2, #a do
      if a[i] == "--" then break end
      if a[i] == "--help" or a[i] == "-h" then
        local sub = (i > 2) and a[2] or nil
        M.cmd_help(M.has_help_topic(command) and command or nil, sub)
        finish(0)
      end
    end
  end
  -- An option the command does not know is a usage error (spec §16.7), checked
  -- before any handler runs — so a mistyped option can never start a build.
  -- Nothing after `--` is checked (a program's / native tool's arguments).
  do
    local bad, label = require("loomworks.cli_options").find_unknown(a)
    if bad then
      die("unknown option '" .. bad .. "' for `lw " .. label .. "` — see `lw help " .. label
        .. "`\n    (arguments for the program or build tool go after `--`)", 2)
    end
  end
  -- `--break-locks[=now]` (spec §19.5), validated per command above: strip it
  -- (before any `--`) and make it the process-wide request every lock
  -- acquisition of this run consults. This process records itself as an `lw`
  -- lock holder.
  a = M._take_break_locks(a, command)
  -- An unknown command (or an option in the command position) is a usage
  -- error decided from the name alone, BEFORE workspace resolution — outside a
  -- workspace a typo must not read as "no loomworks.json" (spec §16.7).
  if command and not require("loomworks.cli_options").is_command(command) then
    if command:sub(1, 1) == "-" and #command > 1 then
      die("unknown option '" .. command .. "' — see `lw help`", 2)
    end
    die("unknown command '" .. command .. "' — run `lw help`", 2)
  end
  -- `settings` edits lw's OWN user configuration (dev-lua, release-url, …). It
  -- is a global command (no workspace needed). NOTE: `config` no longer routes
  -- here — it is now the project-configuration command (see below).
  if command == "settings" then
    finish(M.cmd_settings(a[2], a[3], a[4]))
  end
  if command == "init" then
    finish(M.cmd_init(a))
  end
  if command == "completion" then
    finish(M.cmd_completion(a[2]))
  end
  if command == "release-notes" then
    finish(M.cmd_release_notes(a))
  end
  -- `lw update` was removed (§16.24): an unknown command that names its
  -- replacements. The luvi host says so before we run; this is the
  -- nvim-hosted fallback's copy of that line.
  if command == "update" then
    die("unknown command 'update' - to move lw.pin to the newest release run " ..
      "`lw bootstrap upgrade`; to update lw itself run `lw self-update`", 2)
  end
  -- The one-line "updated - see what's new" notice (§16.37): the first
  -- interactive run after an update nobody was told about. Never fails a command.
  if command ~= "version" and command ~= "--version" and command ~= "-v"
      and command ~= "self-update" and command ~= "install"
      and command ~= "bootstrap" then
    pcall(M._release_notice, a, force_noninteractive)
  end
  -- `module` acquires third-party modules — no workspace needed.
  if command == "module" or command == "mod" then
    finish(M.cmd_module(a[2], a))
  end
  -- `version` / `self-update` are host commands: on the luvi host the bootstrap
  -- (main.lua) intercepts them before we run — except `--help`/`-h`, which it
  -- leaves to the help dispatcher above. Reaching here means the nvim-hosted
  -- fallback, where they don't apply.
  if command == "version" or command == "--version" or command == "-v"
      or command == "self-update" or command == "install"
      or command == "bootstrap" then
    errw("lw: `" .. command .. "` is provided by the standalone lw " ..
      "binary; it is not available in the nvim-hosted fallback.\n")
    finish(1)
  end

  -- LW_ROOT lets a launcher pass the user's directory when the process itself
  -- runs from elsewhere (the luvi host runs from the bundle dir).
  -- `root_info.submodule` is set when the root came from a superproject.
  local root, root_info = find_root(os.getenv("LW_ROOT"))
  -- Every kill and forced unlock is recorded in the workspace's runtime log
  -- (spec §19.5, §19.10).
  if root then
    pcall(function()
      require("loomworks.lock_break").log = require("loomworks.daemon.rlog").writer(root)
    end)
  end

  -- `daemon` manages the workspace runtime (spec §19.11); it never loads the
  -- workspace, and `status` works outside one.
  if command == "daemon" then
    finish(M.cmd_daemon(root, a))
  end
  -- `cleanup` lists / removes what lw left outside the workspace (spec
  -- §16.40); no workspace needed, none loaded.
  if command == "cleanup" then
    finish(M.cmd_cleanup(root, a))
  end
  -- Housekeeping (spec §16.40): once a day, remove leftovers of interrupted
  -- lw runs outside the workspace, and record the last use of a pinned
  -- release this process runs from. Silent; never fails the command.
  pcall(function()
    local hk = require("loomworks.housekeeping")
    hk.touch_running()
    hk.startup(root)
  end)

  -- Bare `lw` and `lw status` → status (also fine outside a workspace).
  if not command or command == "status" then
    -- `--check` (accepted anywhere in argv) makes status exit non-zero when any
    -- diagnostic is present, for CI; it never changes the rendering.
    local check = false
    local cache_stats = false
    for _, v in ipairs(a) do
      if v == "--check" then check = true end
      if v == "--cache-stats" then cache_stats = true end
    end
    finish(M.cmd_status(root, { check = check, cache_stats = cache_stats,
      submodule = root_info and root_info.submodule }))
  end

  -- `health` lists advisory suggestions; like status it works outside a
  -- workspace (worktree hint) and never fails, so it runs before the guard.
  if command == "health" then
    -- (`--force`/`--refresh` from before health stopped reusing its cache are
    -- accepted as no-ops — cli_options — since every run re-checks all.)
    -- Positional words are areas (§16.36); an unknown one is a usage error.
    local json, verbose, all, names = false, false, false, {}
    for i, v in ipairs(a) do
      if v == "--json" then json = true
      elseif v == "--verbose" or v == "-v" then verbose = true
      elseif v == "--all" then all = true
      elseif i > 1 and v:sub(1, 1) ~= "-" then names[#names + 1] = v end
    end
    local areas, unknown = M._health_areas(names)
    if not areas then
      die("unknown health area '" .. unknown .. "' — areas: "
        .. table.concat(require("loomworks.inventory").AREAS, ", ") .. " (lw help health)")
    end
    finish(M.cmd_health(root, { json = json, verbose = verbose, all = all, areas = areas }))
  end

  -- `pull` folds another checkout's working copy into this one; it works in a
  -- fresh worktree that has no workspace of its own yet, so it must run before
  -- the workspace-required guard below.
  if command == "pull" then
    finish(M.cmd_pull(a))
  end

  -- `worktree` lists the repo's git worktrees; it is about worktrees, not the
  -- current workspace, so it runs before the workspace-required guard.
  if command == "worktree" then
    finish(M.cmd_worktree(a))
  end

  -- `sdk types` / `sdk detect` only ask the providers about this host — no
  -- workspace needed.
  if command == "sdk" and (a[2] == "types" or a[2] == "detect") then
    finish(M.cmd_sdk(a[2], root, a))
  end

  -- Workspace commands.
  if not root then die("no loomworks.json found (searched up from cwd) — `lw init` to create one") end

  -- In `runtime-mode daemon` every workspace command keeps the workspace
  -- daemon running (spec §19.1, §19.19 step 2); `lw build` is then routed to
  -- it (below), so its ensure gives a slow daemon longer (§19.10).
  -- Not the recovery commands: `trust` / `nuke` repair a refused workspace
  -- and `unlock` clears stuck locks — none of them may wait on (or start) a
  -- daemon. Nor the read-only commands: like `lw status` they read a live
  -- compatible daemon or in-process and never launch one (§19.1, §19.14).
  local ensured
  if not M.NO_DAEMON_COMMANDS[command] and not M._read_only_command(a) then
    ensured = M._ensure_daemon(root, M._routed_command(a))
  end

  -- `trust` / `nuke` resolve a refused `.nvim` file (spec §17.10); they never
  -- load the workspace (it would be refused).
  if command == "trust" then
    finish(M.cmd_trust(root, a))
  end
  if command == "nuke" then
    finish(M.cmd_nuke(root, a))
  end

  -- `-m <para>` on an item-creating verb describes the new item (§16.35).
  if (command == "project" or command == "config" or command == "configuration"
        or command == "cfg" or command == "configset" or command == "configuration-set"
        or command == "cs" or command == "profile")
      and (a[2] == "add" or a[2] == "create") then
    M._extract_create_paras(a)
  end

  -- `profile` manages its own workspace load (select skips tool detection).
  if command == "profile" then
    finish(M.cmd_profile(a[2], root, a))
  end
  if command == "publish" then
    finish(M.cmd_publish(root))
  end
  -- `export` / `import` carry the configuration to another machine (§16.39).
  if command == "export" then
    finish(M.cmd_export(root, a))
  end
  if command == "import" then
    finish(M.cmd_import(root, a))
  end
  if command == "migrate" then
    finish(M.cmd_migrate(root, a))
  end
  -- `project` / `configuration` manage their own workspace load (no tools).
  if command == "project" then
    finish(M.cmd_project(a[2], root, a[3], a[4], a[5], a))
  end
  -- `config` is the project-configuration command (canonical); `configuration`
  -- and `cfg` are unpromoted aliases.
  if command == "config" or command == "configuration" or command == "cfg" then
    finish(M.cmd_configuration(a[2], root, a[3], a[4], a[5], a[6], a))
  end
  -- `configset` is canonical; `configuration-set` and `cs` are unpromoted aliases.
  if command == "configset" or command == "configuration-set" or command == "cs" then
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
  -- `device` lists / selects devices and cleans staging (spec §16.34); each
  -- sub-command loads the workspace itself (no tool detection).
  if command == "device" or command == "devices" then
    finish(M.cmd_device(a[2], root, a))
  end
  -- `unlock --device <serial>` needs no workspace (device locks are per user),
  -- nor does `unlock --workspace` (the operation lock is a file under .nvim/).
  if command == "unlock" and (vim.tbl_contains(a, "--device") or vim.tbl_contains(a, "--journal")
      or (vim.tbl_contains(a, "--workspace") and not vim.tbl_contains(a, "--all"))) then
    finish(M.cmd_unlock(nil, a, root))
  end
  -- `launch` manages launch configs in the working copy (no tools needed).
  if command == "launch" then
    finish(M.cmd_launch(a[2], root, a))
  end
  -- `target` lists a profile's launchable targets / sets its default. Manages
  -- its own workspace load (build-free, like status) — no tool detection.
  if command == "target" then
    finish(M.cmd_target(root, a))
  end

  -- `lw build`, the batch `lw test`, the preparation of `lw run`, `lw clean`
  -- and `lw reset` routed to the workspace daemon (spec §19.15, §19.19 steps
  -- 3, 5, 5c, 5d): nil = not routed (every other case runs in-process exactly
  -- as before).
  if command == "build" or command == "test" or command == "run" or command == "clean"
      or command == "reset" then
    -- An attached selection in daemon mode runs them attached (§19.1
    -- "Loopback during the transition", step 5e).
    local routed
    -- A runtime lock an attached run holds: wait for it, or "workspace
    -- busy" (§19.2).
    if ensured == "elsewhere" and M._routed_command(a) then ensured = M._await_attached_runtime(root) end
    if M._attached_selected(ensured) then routed = M._delegate_attached(command, root, a)
    else routed = M._delegate(command, root, a, ensured) end
    if routed then finish(routed) end
  end

  local ws = load_workspace(root)
  if command == "profiles" then
    finish(M.cmd_profiles(ws))
  elseif command == "build" then
    finish(M.cmd_build(ws, a))
  elseif command == "clean" then
    finish(M.cmd_clean(ws, a[2]))
  elseif command == "reset" then
    finish(M.cmd_reset(ws, a))
  elseif command == "unlock" then
    finish(M.cmd_unlock(ws, a))
  elseif command == "test" then
    finish(M.cmd_test(ws, a))
  elseif command == "run" then
    finish(M.cmd_run(ws, a))
  else
    die("unknown command '" .. command .. "' — run `lw help`", 2)
  end
end

-- Both hosts load this file as their entry and rely on this side effect to run.
-- Tests set the global to require the module (for its helpers) without executing.
M.main = main
if not _G.LOOMWORKS_CLI_NO_AUTORUN then
  main()
end

return M
