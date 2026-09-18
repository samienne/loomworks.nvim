-- Daemon client stub: detect() + stop() (shutdown-over-pipe, pid-kill fallback).
-- The graceful path is exercised against an IN-PROCESS mock daemon (a libuv pipe
-- server that answers `shutdown` with `ok`) — no second process needed.

local client = require("loomworks.daemon.client")
local handle = require("loomworks.daemon.handle")
local protocol = require("loomworks.daemon.protocol")
local uv = vim.uv or vim.loop

local is_win = package.config:sub(1, 1) == "\\"
local counter = 0

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

--- A unique pipe endpoint name for a mock server.
local function pipe_name()
    counter = counter + 1
    if is_win then
        return "\\\\.\\pipe\\loomworks-test-" .. tostring(uv.os_getpid()) .. "-" .. counter
    end
    return vim.fn.tempname() .. ".sock"
end

--- Start a mock daemon that replies to a `shutdown` request with `ok` and then
--- closes the connection. Returns the pipe name and a stop() to tear it down.
local function start_mock_daemon(name)
    local server = uv.new_pipe(false)
    server:bind(name)
    local conns = {}
    server:listen(16, function(err)
        if err then return end
        local conn = uv.new_pipe(false)
        server:accept(conn)
        conns[#conns + 1] = conn
        local dec = protocol.new_decoder()
        conn:read_start(function(rerr, chunk)
            if rerr or not chunk then return end
            for _, payload in ipairs(dec:push(chunk)) do
                local msg = protocol.decode(payload)
                if msg and msg.kind == protocol.KIND.shutdown then
                    conn:write(protocol.encode({ kind = protocol.KIND.ok, req_id = msg.req_id }))
                end
            end
        end)
    end)
    return function()
        for _, c in ipairs(conns) do pcall(function() if not c:is_closing() then c:close() end end) end
        pcall(function() if not server:is_closing() then server:close() end end)
    end
end

local function run_stop(root, opts)
    local result, done = nil, false
    client.stop(root, opts or {}, function(r) result = r; done = true end)
    vim.wait(3000, function() return done end, 10)
    return result
end

describe("daemon.client detect", function()
    it("reports absence when no handle exists", function()
        local root = fresh_root()
        local st = client.detect(root)
        assert.is_false(st.present)
    end)

    it("reports a live, compatible daemon", function()
        local root = fresh_root()
        handle.write(root, {
            pid = 1, pipe = "x", protocol_version = protocol.VERSION,
            lw_version = "0.1.0", session_generation = 1, started_at = os.time(),
        })
        local st = client.detect(root)
        assert.is_true(st.present)
        assert.is_true(st.live)
        assert.is_true(st.compatible)
    end)

    it("flags an incompatible protocol version", function()
        local root = fresh_root()
        handle.write(root, {
            pid = 1, pipe = "x", protocol_version = protocol.VERSION + 5,
            lw_version = "9.9.9", session_generation = 1, started_at = os.time(),
        })
        local st = client.detect(root)
        assert.is_true(st.present)
        assert.is_false(st.compatible)
    end)
end)

describe("daemon.client stop", function()
    it("returns method=none when there is no daemon", function()
        local root = fresh_root()
        local r = run_stop(root)
        assert.is_false(r.stopped)
        assert.equals("none", r.method)
    end)

    it("stops gracefully via shutdown when the daemon answers ok", function()
        local root = fresh_root()
        local name = pipe_name()
        local teardown = start_mock_daemon(name)
        handle.write(root, {
            pid = uv.os_getpid(), pipe = name, protocol_version = protocol.VERSION,
            lw_version = "0.1.0", session_generation = 1, started_at = os.time(),
        })
        local r = run_stop(root, { kill = function() error("must not kill on graceful path") end })
        teardown()
        assert.is_true(r.stopped)
        assert.equals("shutdown", r.method)
        -- Handle removed once the daemon acked.
        assert.is_nil(handle.read(root))
    end)

    it("falls back to pid-kill when the pipe cannot be reached", function()
        local root = fresh_root()
        local killed = nil
        handle.write(root, {
            pid = 55555, pipe = pipe_name(), protocol_version = protocol.VERSION,
            lw_version = "0.1.0", session_generation = 1, started_at = os.time(),
        })
        local r = run_stop(root, {
            timeout_ms = 300,
            kill = function(pid) killed = pid; return true end,
        })
        assert.equals("kill", r.method)
        assert.is_true(r.stopped)
        assert.equals(55555, killed)
        assert.is_nil(handle.read(root)) -- handle dropped after kill
    end)

    it("falls back immediately when the handle names no pipe", function()
        local root = fresh_root()
        local killed = nil
        handle.write(root, {
            pid = 4321, protocol_version = protocol.VERSION,
            lw_version = "0.1.0", session_generation = 1, started_at = os.time(),
        })
        local r = run_stop(root, { kill = function(pid) killed = pid; return true end })
        assert.equals("kill", r.method)
        assert.equals(4321, killed)
    end)
end)
