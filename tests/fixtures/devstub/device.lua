-- The devstub module's fake device (tests/fixtures/devstub): `nvim -l
-- device.lua <op> <serial> <arg>`. See the module's header.
local op, serial, a = arg[1], arg[2], arg[3]
local line = op .. " " .. serial .. " " .. a

--- The `log` op's lines: two of the launched program (pid 4242, bundle
--- com.example.app), one of another process and one that does not parse.
local LOG_LINES = {
    "10-19 12:00:00.001  4242  4243 I A00001/com.example.app/AppTag: hello from the app",
    "10-19 12:00:00.002  1000  1000 W C01234/foundation/SysTag: system noise",
    "not a device log line",
    "10-19 12:00:00.003  4242  4242 E A00001/com.example.app/AppTag: something failed",
}

if op == "pid" then
    io.write((os.getenv("LW_TEST_DEVICE_PID") or "4242") .. "\n")
elseif op == "log" then
    -- One write, so the lines arrive together.
    io.write(table.concat(LOG_LINES, "\n") .. "\n")
    io.stdout:flush()
    local n = tonumber(os.getenv("LW_TEST_LOG_COUNT") or "") or 0
    local flood = {}
    for i = 1, n do
        flood[#flood + 1] = string.format(
            "10-19 12:00:01.000  4242  4242 D A00001/com.example.app/AppTag: flood %d", i)
    end
    if n > 0 then io.write(table.concat(flood, "\n") .. "\n") end
else
    io.write(line .. "\n")
end
io.stdout:flush()
local log = os.getenv("LW_TEST_DEVICE_LOG")
if log and log ~= "" then
    local f = io.open(log, "ab")
    if f then
        f:write(line .. " " .. tostring(os.getenv("LW_TEST_DEVICE_OP")) .. "\n")
        f:close()
    end
end
local ms = tonumber(os.getenv("LW_TEST_DEVICE_SLEEP") or "")
if ms and op ~= "pid" and op ~= "log" then vim.uv.sleep(ms) end
local pid_ms = tonumber(os.getenv("LW_TEST_PID_SLEEP") or "")
if pid_ms and op == "pid" then vim.uv.sleep(pid_ms) end
local log_ms = tonumber(os.getenv("LW_TEST_LOG_SLEEP") or "")
if log_ms and op == "log" then vim.uv.sleep(log_ms) end
if os.getenv("LW_TEST_DEVICE_FAIL") == op then
    io.stderr:write(op .. " failed on " .. serial .. "\n")
    os.exit(1)
end
