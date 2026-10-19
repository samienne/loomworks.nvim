-- The devstub module's fake device (tests/fixtures/devstub): `nvim -l
-- device.lua <op> <serial> <arg>`. See the module's header.
local op, serial, a = arg[1], arg[2], arg[3]
local line = op .. " " .. serial .. " " .. a
if op == "pid" then
    io.write((os.getenv("LW_TEST_DEVICE_PID") or "4242") .. "\n")
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
if ms and op ~= "pid" then vim.uv.sleep(ms) end
local pid_ms = tonumber(os.getenv("LW_TEST_PID_SLEEP") or "")
if pid_ms and op == "pid" then vim.uv.sleep(pid_ms) end
if os.getenv("LW_TEST_DEVICE_FAIL") == op then
    io.stderr:write(op .. " failed on " .. serial .. "\n")
    os.exit(1)
end
