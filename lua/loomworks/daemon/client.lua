--- loomworks/daemon/client.lua — the Phase-0 daemon CLIENT STUB.
---
--- This is daemon-*awareness* without daemon-*capability* (DAEMON.md §8, rung 1):
--- it can DISCOVER a running daemon via the handle file (§4) and STOP one, but it
--- does not hydrate a projection, send mutations, or stream tasks — that is the
--- Phase-1 daemon backend. Its whole reason to exist on mainline is so that any
--- `lw` (daemon-capable or not) can retire a stray daemon when the user goes
--- daemonless.
---
--- Transport is a libuv pipe on both hosts (`uv.new_pipe` + `pipe:connect`), NOT
--- nvim's `sockconnect`, so the identical code runs headless (CLI) and in the
--- editor. All I/O is async; nothing blocks the Neovim loop — the CLI wraps a
--- `stop` in `vim.wait`, the editor would drive it off the loop.

local uv = vim.uv or vim.loop
local handle = require("loomworks.daemon.handle")
local protocol = require("loomworks.daemon.protocol")

local M = {}

--- Default time to wait for a graceful `shutdown` ack before the pid-kill
--- fallback (DAEMON.md §8: "connect + shutdown, pid-kill fallback").
M.STOP_TIMEOUT_MS = 2000

--- Inspect the workspace for a daemon, without connecting.
--- @param root string workspace root
--- @return table status { present, live?, compatible?, info? }
function M.detect(root)
    local info = handle.read(root)
    if not info then
        return { present = false }
    end
    return {
        present = true,
        readable = info._decoded == true,
        live = handle.is_live(info),
        compatible = protocol.compatible(info.protocol_version),
        info = info,
    }
end

--- Best-effort process termination for the pid-kill fallback. libuv maps
--- sigterm/sigkill to TerminateProcess on Windows, where signal delivery is
--- otherwise unreliable (the same reason liveness uses mtime, not uv.kill).
--- @param pid integer|nil
--- @return boolean attempted
local function kill_pid(pid)
    if type(pid) ~= "number" or pid <= 0 then return false end
    local ok = pcall(function()
        if uv.kill then uv.kill(pid, "sigterm") end
    end)
    return ok
end

--- Stop the daemon for a workspace root, if any.
---
--- Tries a graceful `shutdown` command over the pipe; on connect failure or ack
--- timeout, falls back to terminating the handle's pid. The handle file is
--- removed once the daemon is gone (a clean daemon removes its own; the kill
--- path removes it here). The callback receives:
---   { stopped = boolean, method = "none"|"shutdown"|"kill", reason? = string }
---
--- @param root string workspace root
--- @param opts? { timeout_ms?: integer, kill?: fun(pid:integer|nil):boolean }
--- @param callback fun(result: table)
function M.stop(root, opts, callback)
    opts = opts or {}
    local timeout_ms = opts.timeout_ms or M.STOP_TIMEOUT_MS
    local kill = opts.kill or kill_pid

    local info = handle.read(root)
    if not info then
        callback({ stopped = false, method = "none", reason = "no daemon running" })
        return
    end

    local done = false
    local pipe, timer
    local function cleanup()
        if timer then pcall(function() timer:stop(); timer:close() end); timer = nil end
        if pipe then
            pcall(function() if not pipe:is_closing() then pipe:close() end end)
            pipe = nil
        end
    end
    local function finish(result)
        if done then return end
        done = true
        cleanup()
        callback(result)
    end

    --- Graceful path failed → terminate the pid and drop the handle.
    local function fallback(reason)
        if done then return end
        local attempted = kill(info.pid)
        handle.remove(root)
        finish({
            stopped = attempted,
            method = attempted and "kill" or "none",
            reason = reason,
        })
    end

    if type(info.pipe) ~= "string" or info.pipe == "" then
        fallback("handle names no pipe")
        return
    end

    timer = uv.new_timer()
    timer:start(timeout_ms, 0, function()
        fallback("shutdown ack timed out")
    end)

    pipe = uv.new_pipe(false)
    pipe:connect(info.pipe, function(cerr)
        if cerr then
            fallback("cannot connect: " .. tostring(cerr))
            return
        end
        local decoder = protocol.new_decoder()
        pipe:read_start(function(rerr, chunk)
            if rerr then
                -- EOF/reset after we asked to shut down is a success signal too:
                -- the daemon closed the pipe on its way out.
                finish({ stopped = true, method = "shutdown" })
                return
            end
            if not chunk then
                -- Clean EOF: daemon closed the connection → treat as stopped.
                finish({ stopped = true, method = "shutdown" })
                return
            end
            for _, payload in ipairs(decoder:push(chunk)) do
                local msg = protocol.decode(payload)
                if msg and (msg.kind == protocol.KIND.ok
                        or msg.kind == protocol.KIND.error) then
                    handle.remove(root)
                    finish({
                        stopped = msg.kind == protocol.KIND.ok,
                        method = "shutdown",
                        reason = msg.error,
                    })
                    return
                end
            end
        end)
        pipe:write(protocol.encode({ kind = protocol.KIND.shutdown, req_id = 1 }))
    end)
end

return M
