--- loomworks/daemon/stdio.lua — the standard-I/O transport (spec §19.16
--- "End state", §19.20 "Schemas and conformance"):
--- `lw daemon run --root <root> --stdio`.
---
--- The daemon's server and build service run in this process as an attached
--- runtime (R held in `attached` mode, §19.1, §19.2), with exactly one
--- connection: this process's standard input and output, a private pipe
--- that needs no authentication. Its first frame is the client's `hello`,
--- answered by `welcome` (Server:adopt_pipe); then the protocol is the same
--- as on the endpoint. The runtime stops when the client closes standard
--- input (or the connection is closed for a malformed frame), and the
--- process exits with the runtime's exit status. Nothing else is written to
--- standard output: notes and the runtime log go to standard error and the
--- log file.
---
--- This is the transport the conformance runner drives (step 5g.2) and the
--- editor's child daemon will use (step 5p).

local uv = vim.uv or vim.loop

local M = {}

--- How long the process waits, at exit, for its last frames to be written.
M.FLUSH_MS = 5000

--- A stream over two libuv pipes (read end, write end) with the pipe
--- methods the server calls (see loomworks.daemon.loopback).
--- @param inp table libuv pipe (readable)
--- @param out table libuv pipe (writable)
--- @return table
function M.duplex(inp, out)
    local s = { closing = false }
    function s:write(data, cb) return out:write(data, cb) end
    function s:read_start(cb) return inp:read_start(cb) end
    function s:read_stop() return inp:read_stop() end
    function s:is_closing() return self.closing end
    function s:get_write_queue_size() return out:get_write_queue_size() end
    function s:close(cb)
        if self.closing then return end
        self.closing = true
        pcall(function() inp:read_stop() end)
        pcall(function() if not inp:is_closing() then inp:close() end end)
        -- Standard output is closed by `serve` once its queue drained.
        if cb then vim.schedule(cb) end
    end
    return s
end

--- Serve the protocol on this process's standard input and output until
--- the client closes it. Returns the exit status.
--- @param root string
--- @param host table the CLI host (loomworks.daemon.command)
--- @return integer
function M.serve(root, host)
    local command = require("loomworks.daemon.command")
    local server_mod = require("loomworks.daemon.server")
    local srv = command._new_server(root, host, {})
    local ok, err, code = srv:start_attached({ command = "daemon run --stdio" })
    if not ok then
        if code == server_mod.EXIT_HELD then
            host.note("lw: another runtime holds this workspace: " .. tostring(err))
            return code
        end
        host.note("lw: cannot start the workspace runtime: " .. tostring(err))
        return code or 1
    end
    local inp, out = uv.new_pipe(false), uv.new_pipe(false)
    local oki = pcall(inp.open, inp, 0)
    local oko = pcall(out.open, out, 1)
    if not (oki and oko) then
        srv:stop("standard input or output is not usable", 1)
        host.note("lw: --stdio needs standard input and output")
        return 1
    end
    local conn, aerr = srv:adopt_pipe(M.duplex(inp, out), function()
        vim.schedule(function()
            if not srv.stopped then srv:stop("its client closed standard input", 0) end
        end)
    end)
    if not conn then
        host.note("lw: " .. tostring(aerr))
        return 1
    end
    if host.on_exit then host.on_exit(function() srv:stop("interrupted", 130) end) end
    while not srv.stopped do
        vim.wait(3600 * 1000, function() return srv.stopped end, 50)
    end
    -- The last frames (a reply, a task's `done`) reach the client first.
    vim.wait(M.FLUSH_MS, function() return out:get_write_queue_size() == 0 end, 10)
    pcall(function() out:close() end)
    return srv.exit_code or 0
end

return M
