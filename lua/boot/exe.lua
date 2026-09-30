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

--- Interrupts the re-exec'ing host outlives (see run_in_place).
M.INTERRUPT_SIGNALS = { "sigint", "sigbreak", "sighup", "sigterm" }

--- Run `bin` with `args` in this process's place — the redirect's re-exec
--- (spec §16.23) — sharing standard input/output/error, and wait for it.
--- Returns its exit status (128 + signal when a signal ended it), or nil + err
--- when it cannot be started.
---
--- The child is the one that handles an interrupt (spec §16.6: it releases its
--- locks, stops a remote run, exits 130), so this process must neither die on
--- one nor end first: libuv puts spawned children in a kill-on-close job on
--- Windows, so an early exit would kill the child mid-cleanup, and a shell would
--- take the terminal back while the child still writes to it. Windows delivers
--- a console event (Ctrl-C, Ctrl-Break, close) to every process on the console,
--- the child included, so it is only ignored here. On POSIX a terminal's
--- SIGINT/SIGHUP reach the whole process group, but a signal sent to this pid
--- alone (kill, a supervisor's SIGTERM) would not reach the child: each is
--- forwarded — the child's cleanup runs once however many arrive.
--- @param bin string
--- @param args string[]
--- @param opts? { is_windows?: boolean, new_signal?: fun(): table }
--- @return integer|nil code, string|nil err
function M.run_in_place(bin, args, opts)
  opts = opts or {}
  local windows = opts.is_windows
  if windows == nil then windows = M.is_windows end
  local new_signal = opts.new_signal or uv.new_signal
  local handle
  -- Installed before the spawn, so no interrupt falls between the two.
  local watchers = {}
  for _, sig in ipairs(M.INTERRUPT_SIGNALS) do
    pcall(function()
      local w = new_signal()
      if not w then return end
      w:start(sig, function()
        if not windows and handle then pcall(uv.process_kill, handle, sig) end
      end)
      w:unref()
      watchers[#watchers + 1] = w
    end)
  end
  local function close_watchers()
    for _, w in ipairs(watchers) do
      pcall(function() w:stop(); w:close() end)
    end
  end
  local code, signal
  local err
  handle, err = uv.spawn(bin, { args = args, stdio = { 0, 1, 2 } },
    function(c, s) code, signal = c, s end)
  if not handle then close_watchers(); return nil, tostring(err) end
  uv.run()
  handle:close()
  close_watchers()
  if (code or 0) == 0 and (signal or 0) ~= 0 then return 128 + signal end
  return code or 0
end

return M
