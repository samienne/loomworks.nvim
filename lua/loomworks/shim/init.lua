--- loomworks/shim/init.lua — a minimal `vim` shim for the standalone
--- (luvi / LuaJIT + libuv) host. Installs `_G.vim` and returns it.
---
--- Fulfils spec §16.1 (runtime-host neutrality). Provides only what the
--- headless build/detect path touches: JSON (with nvim empty_dict/NIL
--- fidelity), libuv as vim.uv, process spawning, PATH probing, table/string
--- helpers, an event-loop-drained scheduler, and vim.wait over uv.run().
--- No editor surface (buffers, windows, autocommands).

local ok_uv, uv = pcall(require, "uv")
if not ok_uv then uv = require("luv") end
local json = require("loomworks.shim.json")

local vim = _G.vim or {}

vim.uv = uv
vim.loop = uv
vim.NIL = json.NIL
vim._empty_dict_mt = json._empty_dict_mt
function vim.empty_dict() return json.empty_dict() end
vim.json = { encode = json.encode, decode = json.decode }

-- ---------------------------------------------------------------------------
-- table / string helpers (vendorable from nvim shared.lua)
-- ---------------------------------------------------------------------------

function vim.deepcopy(o, seen)
  if type(o) ~= "table" then return o end
  if seen and seen[o] then return seen[o] end
  seen = seen or {}
  local r = setmetatable({}, getmetatable(o))
  seen[o] = r
  for k, v in pairs(o) do r[vim.deepcopy(k, seen)] = vim.deepcopy(v, seen) end
  return r
end

function vim.deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not vim.deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function deep_extend(behavior, ...)
  local ret = {}
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then
      for k, v in pairs(t) do
        if type(v) == "table" and type(ret[k]) == "table" then
          ret[k] = deep_extend(behavior, ret[k], v)
        else
          ret[k] = v
        end
      end
    end
  end
  return ret
end
function vim.tbl_deep_extend(behavior, ...) return deep_extend(behavior, ...) end

function vim.tbl_extend(behavior, ...)
  local ret = {}
  for i = 1, select("#", ...) do
    local t = select(i, ...)
    if type(t) == "table" then for k, v in pairs(t) do ret[k] = v end end
  end
  return ret
end

function vim.list_extend(dst, src, s, e)
  s = s or 1
  e = e or #src
  for i = s, e do dst[#dst + 1] = src[i] end
  return dst
end

function vim.tbl_isempty(t) return next(t) == nil end
function vim.tbl_count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
function vim.tbl_keys(t) local r = {}; for k in pairs(t) do r[#r + 1] = k end; return r end
function vim.tbl_values(t) local r = {}; for _, v in pairs(t) do r[#r + 1] = v end; return r end
function vim.tbl_contains(t, v) for _, x in ipairs(t) do if x == v then return true end end; return false end
function vim.tbl_map(f, t) local r = {}; for k, v in pairs(t) do r[k] = f(v) end; return r end
function vim.tbl_filter(f, t) local r = {}; for _, v in ipairs(t) do if f(v) then r[#r + 1] = v end end; return r end
function vim.tbl_isarray(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do if type(k) ~= "number" then return false end; n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end
vim.islist = vim.tbl_isarray

function vim.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function vim.startswith(s, p) return s:sub(1, #p) == p end
function vim.endswith(s, p) return p == "" or s:sub(-#p) == p end
function vim.split(s, sep, opts)
  local r = {}
  local plain = opts and opts.plain
  local pos = 1
  while true do
    local a, b = s:find(sep, pos, plain)
    if not a then r[#r + 1] = s:sub(pos); break end
    r[#r + 1] = s:sub(pos, a - 1)
    pos = b + 1
  end
  return r
end

-- Best-effort table dump for log messages (not parsed anywhere).
function vim.inspect(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, val in pairs(v) do
    parts[#parts + 1] = tostring(k) .. " = " .. (type(val) == "table" and "{...}" or tostring(val))
  end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

-- ---------------------------------------------------------------------------
-- fs / path
-- ---------------------------------------------------------------------------

vim.fs = vim.fs or {}
function vim.fs.normalize(p)
  if type(p) ~= "string" then return p end
  p = p:gsub("\\", "/")
  if p:sub(1, 1) == "~" then
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    p = home:gsub("\\", "/") .. p:sub(2)
  end
  return p
end

local function which(exe)
  if exe:find("[/\\]") then return exe end
  local exts = { "" }
  local pe = os.getenv("PATHEXT")
  if pe then for e in pe:gmatch("[^;]+") do exts[#exts + 1] = e:lower() end end
  for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do
    for _, ext in ipairs(exts) do
      local p = dir .. "/" .. exe .. ext
      local st = uv.fs_stat(p)
      if st and st.type == "file" then return (p:gsub("\\", "/")) end
    end
  end
  return nil
end

vim.fn = vim.fn or {}
function vim.fn.has(feat)
  if feat == "win32" or feat == "win64" then
    return (uv.os_uname().sysname:lower():find("windows") and 1 or 0)
  end
  if feat == "unix" or feat == "linux" or feat == "mac" then return 0 end
  return 0
end
function vim.fn.executable(name) return which(name) and 1 or 0 end
function vim.fn.exepath(name) return which(name) or "" end
function vim.fn.getcwd() return (uv.cwd():gsub("\\", "/")) end
function vim.fn.isdirectory(p) local st = uv.fs_stat(p); return (st and st.type == "directory") and 1 or 0 end
function vim.fn.filereadable(p) local st = uv.fs_stat(p); return (st and st.type == "file") and 1 or 0 end
function vim.fn.mkdir(path, flags)
  local acc = ""
  local first = true
  for seg in path:gsub("\\", "/"):gmatch("[^/]+") do
    acc = first and seg or (acc .. "/" .. seg)
    first = false
    if not uv.fs_stat(acc) then pcall(uv.fs_mkdir, acc, 493) end
  end
  return 1
end
function vim.fn.fnamemodify(p, m)
  p = p:gsub("\\", "/")
  if m and m:find(":p") then
    if p:sub(2, 2) ~= ":" and p:sub(1, 1) ~= "/" then p = uv.cwd():gsub("\\", "/") .. "/" .. p end
  end
  if m and m:find(":h") then p = p:gsub("/[^/]*$", "") end
  if m and m:find(":t") then p = p:match("[^/]*$") or p end
  return p
end
function vim.fn.system(cmd)
  -- Synchronous run; sets vim.v.shell_error. Accepts list or string.
  local argv = cmd
  if type(cmd) == "string" then argv = { cmd } end
  local exe = which(argv[1]) or argv[1]
  local args = {}
  for i = 2, #argv do args[#args + 1] = argv[i] end
  local out = {}
  local so = uv.new_pipe(false)
  local done, code = false, -1
  local handle
  handle = uv.spawn(exe, { args = args, stdio = { nil, so, nil } }, function(c)
    code = c
    so:read_stop(); so:close(); handle:close()
    done = true
  end)
  if not handle then vim.v.shell_error = 1; return "" end
  uv.read_start(so, function(_, d) if d then out[#out + 1] = d end end)
  while not done do uv.run("once") end
  vim.v.shell_error = code
  return table.concat(out)
end
vim.v = vim.v or { shell_error = 0 }
--- Standard SHA-256 hex (matches nvim's vim.fn.sha256 so cache hashes agree
--- across the editor and the standalone host). Backed by luvi's OpenSSL.
function vim.fn.sha256(s)
  local ok, openssl = pcall(require, "openssl")
  if ok and openssl and openssl.digest then
    return openssl.digest.digest("sha256", s, false)
  end
  error("vim.fn.sha256: no SHA-256 backend available in this host")
end

-- ---------------------------------------------------------------------------
-- process (vim.system async, over uv.spawn)
-- ---------------------------------------------------------------------------

function vim.system(cmd, opts, on_exit)
  opts = opts or {}
  local exe = which(cmd[1]) or cmd[1]
  local args = {}
  for i = 2, #cmd do args[#args + 1] = cmd[i] end
  local so, se = uv.new_pipe(false), uv.new_pipe(false)
  local out, err = {}, {}
  local result, handle
  handle = uv.spawn(exe, { args = args, stdio = { nil, so, se }, cwd = opts.cwd, env = opts.env }, function(code)
    so:read_stop(); se:read_stop(); so:close(); se:close(); handle:close()
    result = { code = code, stdout = table.concat(out), stderr = table.concat(err) }
    if on_exit then on_exit(result) end
  end)
  if not handle then
    result = { code = 127, stdout = "", stderr = "spawn failed: " .. tostring(exe) }
    if on_exit then on_exit(result) end
  else
    uv.read_start(so, function(_, d) if d then out[#out + 1] = d end end)
    uv.read_start(se, function(_, d) if d then err[#err + 1] = d end end)
  end
  return {
    wait = function()
      while not result do uv.run("once") end
      return result
    end,
    pid = handle and uv.process_get_pid and uv.process_get_pid(handle) or nil,
  }
end

-- ---------------------------------------------------------------------------
-- scheduling + event-loop draining (spec §16.1)
-- ---------------------------------------------------------------------------

local sched_q, idle = {}, nil
function vim.schedule(fn)
  sched_q[#sched_q + 1] = fn
  if not idle then
    idle = uv.new_idle()
    idle:start(function()
      while #sched_q > 0 do table.remove(sched_q, 1)() end
      idle:stop(); idle:close(); idle = nil
    end)
  end
end
function vim.schedule_wrap(fn)
  return function(...)
    local a = { ... }
    vim.schedule(function() fn(unpack(a)) end)
  end
end

--- Drive the libuv loop until `condition` is true or `timeout` ms elapse.
--- Returns on the condition (not on loop-empty), so active watchers don't
--- block it. Mirrors nvim's vim.wait for the headless bootstrap.
function vim.wait(timeout, condition, interval)
  interval = interval or 20
  if condition and condition() then return true end
  local start = uv.now()
  local done, result = false, false
  local timer = uv.new_timer()
  timer:start(interval, interval, function()
    if condition and condition() then
      result, done = true, true
    elseif uv.now() - start >= timeout then
      result, done = false, true
    end
    if done then timer:stop(); timer:close() end
  end)
  while not done do uv.run("once") end
  return result
end

-- ---------------------------------------------------------------------------
-- logging / notify / stubs
-- ---------------------------------------------------------------------------

vim.log = { levels = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, OFF = 5 } }
function vim.notify(msg, level)
  if not level or level >= vim.log.levels.WARN then
    io.stderr:write("[loomworks] " .. tostring(msg) .. "\n")
  end
end
function vim.notify_once(msg, level) vim.notify(msg, level) end

-- Editor-only surface: present but inert. The build/detect path never calls
-- these; they exist so any load-time closure that references vim.api doesn't
-- nil-index. If one is actually invoked, that's a real gap to fix.
vim.api = setmetatable({}, {
  __index = function(_, k)
    return function()
      error("vim.api." .. k .. " is not available in the standalone host", 2)
    end
  end,
})
vim.g = {}
vim.o = {}
vim.cmd = function() error("vim.cmd is not available in the standalone host", 2) end

_G.vim = vim
return vim
