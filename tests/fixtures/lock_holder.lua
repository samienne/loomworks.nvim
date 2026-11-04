-- A lock-holding helper process for the lock-recovery specs (spec §19.5).
--
--   nvim --headless --clean -l tests/fixtures/lock_holder.lua <repo root> <lockfile> \
--        <operation> <holder kind> <with child: 0|1> [lifetime ms]
--
-- Takes the lockfile with the real build_lock path API (record + heartbeat),
-- optionally starts a child process of its own (a build tool stand-in), prints
-- `LOCKED <child pid|0>` and then keeps its event loop running (so it
-- heartbeats) until killed — or until the lifetime cap (default 120 s), so a
-- failed test never leaves it running for long.

local a = _G.arg
local root, lockfile, op, kind = a[1], a[2], a[3], a[4]
local with_child = a[5] == "1"
local lifetime = tonumber(a[6] or "") or 120000
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local uv = vim.uv or vim.loop
require("loomworks.lock_record").set_holder_kind(kind)
local bl = require("loomworks.build_lock")
bl.HEARTBEAT_MS = tonumber(os.getenv("LW_TEST_HEARTBEAT_MS") or "") or bl.HEARTBEAT_MS

local h, info = bl.try_acquire_path(lockfile, op)
if not h then
    io.stdout:write("BUSY " .. tostring(info and info.state) .. "\n")
    io.stdout:flush()
    os.exit(3)
end

local child_pid = 0
if with_child then
    local handle, pid = uv.spawn(vim.v.progpath, {
        args = { "--headless", "--clean", "--cmd", "lua vim.wait(" .. lifetime .. ", function() return false end, 200)",
            "-c", "qa!" },
        stdio = { nil, nil, nil },
    }, function() end)
    if handle then child_pid = pid end
end

io.stdout:write("LOCKED " .. tostring(child_pid) .. "\n")
io.stdout:flush()
vim.wait(lifetime, function() return false end, 100)
bl.release(h)
os.exit(0)
