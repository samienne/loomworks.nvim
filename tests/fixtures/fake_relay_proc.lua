-- A fake `--stdio` relay process for the editor's relay client tests
-- (tests/daemon_relay_client_spec.lua), run as `nvim --headless -u NONE -l
-- fake_relay_proc.lua <mode> <arg> daemon run ...`. Modes:
--   ignore <pidfile>   starts a detached child (as a relay launches its
--                      daemon) that writes its pid to <pidfile>, then ignores
--                      EOF on standard input and never exits
--   eof-hang           closes its standard output, ignores EOF, never exits
--   eof-exit <ms>      closes its standard output, exits 10 <ms> later
--   exit-held <ms>     leaves a child holding its standard output and error
--                      for <ms>, then exits 10 at once
--   sleep <ms>         (the child) sleeps <ms>, then exits 0
local uv = vim.uv or vim.loop
local mode, a = arg[1], arg[2]

local function child(args, inherit)
    local h, pid = uv.spawn(vim.v.progpath, {
        args = vim.list_extend({ "--headless", "-u", "NONE", "-l", arg[0] }, args),
        stdio = inherit and { nil, 1, 2 } or nil,
        detached = true, hide = true,
    }, function() end)
    if h then h:unref() end
    return h, pid
end

-- Close this process's standard output for good (the C library's stream,
-- the descriptor, and on Windows the OS handle), so its reader sees EOF.
local function close_stdout()
    pcall(function() io.stdout:close() end)
    local ffi = require("ffi")
    if package.config:sub(1, 1) == "\\" then
        pcall(ffi.cdef, "void* GetStdHandle(unsigned long n); int CloseHandle(void* h); int _close(int fd);")
        local h = ffi.C.GetStdHandle(4294967285) -- STD_OUTPUT_HANDLE (-11)
        pcall(function() ffi.C._close(1) end)
        pcall(function() ffi.C.CloseHandle(h) end)
    else
        pcall(ffi.cdef, "int close(int fd);")
        ffi.C.close(1)
    end
end

local function ignore_stdin()
    local p = uv.new_pipe(false)
    if pcall(p.open, p, 0) then p:read_start(function() end) end
end

if mode == "sleep" then
    vim.wait(tonumber(a))
    os.exit(0)
elseif mode == "ignore" then
    local h, pid = child({ "sleep", "60000" }, false)
    local f = assert(io.open(a, "w")); f:write(tostring(pid)); f:close()
    ignore_stdin()
    while true do vim.wait(1000) end
elseif mode == "eof-hang" then
    close_stdout()
    ignore_stdin()
    while true do vim.wait(1000) end
elseif mode == "eof-exit" then
    close_stdout()
    vim.wait(tonumber(a))
    os.exit(10)
elseif mode == "exit-held" then
    child({ "sleep", a }, true)
    os.exit(10)
end
