--- loomworks/cli_color.lua — whether, and how, `lw` colors its own lines
--- (spec §16.7 *Highlighting*).
---
--- Every line the CLI prints on its own behalf has a ROLE (the invocation's
--- lead line, a step header, a configure reason, a printed command, a success
--- outcome, a failure, a warning, or `plain` — an informative line that fits
--- no other role, never colored). `paint(role, text, stream)` wraps the text
--- in the role's `term.sgr` markers when that stream may be colored, and
--- returns it unchanged otherwise — so with color off every line is
--- byte-identical to its plain form. Lines are colored by the role their
--- producer gives them, never by matching their text.
---
--- Whether a stream is colored (`enabled`) follows the global option
--- `--color=auto|always|never` (`--no-color` = never, default auto): `auto`
--- needs that stream (stdout and stderr tested separately) to be a terminal —
--- with escape-sequence processing enabled on its handle on Windows — and
--- `NO_COLOR` unset or empty; `always` colors regardless; `never` never.
---
--- Only lw's own lines go through here. Output relayed from a build tool or a
--- launched program never does, and no child's environment is touched.

local term = require("loomworks.term")
local uv = vim.uv or vim.loop

local M = {}

--- The CLI palette's SGR parameters (shared with `lw status` and the other
--- listings, cli.lua's status_palette).
M.SGR = {
  reset = "0",
  bold = "1",
  dim = "2",
  green = "32",
  red = "31",
  yellow = "33",
  cyan = "36",
}

--- Role → SGR parameters. `phase` is a step header (`==> [<kind>] <name>`,
--- spec §16.7): its arrow gets `phase_arrow`, the rest `phase`. `plain` is
--- false: a line with a role that is never colored.
M.ROLES = {
  lead = M.SGR.bold,
  phase = M.SGR.bold,
  reason = M.SGR.dim,
  command = M.SGR.dim,
  ok = M.SGR.green,
  fail = M.SGR.red,
  warn = M.SGR.yellow,
  plain = false,
}
local PHASE_ARROW = M.SGR.bold .. ";" .. M.SGR.cyan

--- The step-header arrow (spec §16.7). Headers are built with `header`, so the
--- arrow is the one piece the painter places by structure, not by text.
M.ARROW = "==>"

--- A step header's text: `==> [<kind>] <name>`.
--- @param kind string configure|build|clean|test
--- @param name string|nil
--- @return string
function M.header(kind, name)
  return string.format("%s [%s] %s", M.ARROW, tostring(kind), tostring(name or "?"))
end

--- The color mode: "auto" (default), "always" or "never". Set from the global
--- option by the CLI dispatcher (`set_from_option`).
M.mode = "auto"

--- Validate and set the color mode from a global option token. Returns nil and
--- an error message for a bad value (a usage error at the caller).
--- @param token string `--color=<when>` or `--no-color`
--- @return boolean|nil ok, string|nil err
function M.set_from_option(token)
  if token == "--no-color" then
    M.mode = "never"
    return true
  end
  local when = type(token) == "string" and token:match("^%-%-color=(.*)$")
  if when == "auto" or when == "always" or when == "never" then
    M.mode = when
    return true
  end
  return nil, "invalid value '" .. tostring(when) .. "' for --color — use auto, always or never"
end

-- Test seams: `M._isatty(fd)` and `M._getenv(name)` replace the terminal test
-- and the environment read; `M._enable_vt(fd)` the Windows console probe.
M._isatty = nil
M._getenv = nil
M._enable_vt = nil

local function isatty(fd)
  if M._isatty then return M._isatty(fd) end
  local ok, h = pcall(uv.guess_handle, fd)
  return ok and h == "tty"
end

local function getenv(name)
  if M._getenv then return M._getenv(name) end
  return os.getenv(name)
end

local function is_windows() return package.config:sub(1, 1) == "\\" end

-- On Windows a console renders escape sequences only once virtual-terminal
-- processing is on for THAT handle — stdout and stderr each have their own.
-- Enabled once per handle via LuaJIT FFI (kernel32), available on both hosts
-- (nvim and the luvi luajit shim). Memoized; every step is pcall-guarded: no
-- ffi, a redirected stream or a denied syscall all yield false and the stream
-- stays plain. Never touches kernel32 off Windows.
local vt_memo = {} -- fd -> true|false
local cdef_done = false
local function enable_vt(fd)
  if M._enable_vt then return M._enable_vt(fd) end
  if vt_memo[fd] ~= nil then return vt_memo[fd] end
  local enabled = false
  pcall(function()
    local ffi = require("ffi")
    if ffi.os ~= "Windows" then return end
    if not cdef_done then
      cdef_done = true
      ffi.cdef([[
        void* GetStdHandle(unsigned long nStdHandle);
        int GetConsoleMode(void* hConsoleHandle, unsigned long* lpMode);
        int SetConsoleMode(void* hConsoleHandle, unsigned long dwMode);
      ]])
    end
    -- STD_OUTPUT_HANDLE = (DWORD)-11, STD_ERROR_HANDLE = (DWORD)-12
    local which = fd == 2 and 0xFFFFFFF4 or 0xFFFFFFF5
    local ENABLE_VT = 0x0004 -- ENABLE_VIRTUAL_TERMINAL_PROCESSING
    local h = ffi.C.GetStdHandle(which)
    local mode = ffi.new("unsigned long[1]")
    if ffi.C.GetConsoleMode(h, mode) == 0 then return end -- redirected / not a console
    if ffi.C.SetConsoleMode(h, bit.bor(tonumber(mode[0]), ENABLE_VT)) == 0 then return end
    enabled = true
  end)
  vt_memo[fd] = enabled
  return enabled
end

local FD = { stdout = 1, stderr = 2 }

--- Whether lw's own lines written to `stream` are colored (see the module doc).
--- The terminal test runs before the Windows probe, so a piped / redirected /
--- captured stream never reaches the FFI path.
--- @param stream "stdout"|"stderr"
--- @return boolean
function M.enabled(stream)
  if M.mode == "always" then return true end
  if M.mode == "never" then return false end
  local no_color = getenv("NO_COLOR")
  if no_color ~= nil and no_color ~= "" then return false end
  local fd = FD[stream] or 1
  if not isatty(fd) then return false end
  if is_windows() then return enable_vt(fd) end
  return true
end

--- The text of one line wrapped in `role`'s markers (no color check).
local function wrap(role, line)
  if line == "" then return line end
  if role == "phase" and line:sub(1, #M.ARROW) == M.ARROW then
    return term.sgr(PHASE_ARROW) .. M.ARROW .. term.sgr(M.SGR.reset)
      .. term.sgr(M.ROLES.phase) .. line:sub(#M.ARROW + 1) .. term.sgr(M.SGR.reset)
  end
  return term.sgr(M.ROLES[role]) .. line .. term.sgr(M.SGR.reset)
end

--- `text` painted for `role` when `stream` is colored, else unchanged. Each
--- line of a multi-line text is wrapped on its own, so a color never spills
--- past a line end. The `plain` role (and a nil or unknown one) is never
--- colored.
--- @param role string|nil lead|phase|reason|command|ok|fail|warn|plain
--- @param text string
--- @param stream "stdout"|"stderr"
--- @param color? boolean overrides the `enabled(stream)` decision
--- @return string
function M.paint(role, text, stream, color)
  text = tostring(text or "")
  if not role or not M.ROLES[role] then return text end
  if color == nil then color = M.enabled(stream) end
  if not color then return text end
  return (text:gsub("[^\n]+", function(l) return wrap(role, l) end))
end

return M
