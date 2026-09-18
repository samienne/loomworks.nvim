-- Daemon server run loop: lock acquisition, handle publish, handshake, ping,
-- graceful shutdown, single-primary, and idle timeout. Driven fully in-process
-- against real libuv pipes (busted pumps the loop with vim.wait).

local server_mod = require("loomworks.daemon.server")
local protocol = require("loomworks.daemon.protocol")
local handle = require("loomworks.daemon.handle")
local lock = require("loomworks.daemon.lock")
local client = require("loomworks.daemon.client")
local uv = vim.uv or vim.loop

local function fresh_root()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d
end

--- Connect a raw client to a pipe address; returns a handle with send()/messages.
local function connect(addr)
    local c = { pipe = uv.new_pipe(false), messages = {}, connected = false,
                decoder = protocol.new_decoder() }
    c.pipe:connect(addr, function(err)
        if err then c.error = err; return end
        c.connected = true
        c.pipe:read_start(function(rerr, chunk)
            if rerr or not chunk then return end
            for _, payload in ipairs(c.decoder:push(chunk)) do
                local msg = protocol.decode(payload)
                if msg then c.messages[#c.messages + 1] = msg end
            end
        end)
    end)
    function c.send(msg) c.pipe:write(protocol.encode(msg)) end
    function c.close() pcall(function() if not c.pipe:is_closing() then c.pipe:close() end end) end
    return c
end

--- Pump the loop until `pred()` or timeout.
local function waitfor(pred, ms) return vim.wait(ms or 2000, pred, 10) end

describe("daemon.server lifecycle", function()
    local root, server
    before_each(function() root = fresh_root() end)
    after_each(function()
        if server and not server:is_stopped() then server:stop("test cleanup") end
        server = nil
    end)

    it("start acquires the lock, publishes the handle, listens", function()
        server = server_mod.new(root, { generation = 123 })
        assert.is_true((server:start()))
        assert.is_string(server.address)
        -- Handle present and pointing at the bound pipe.
        local info = handle.read(root)
        assert.equals(server.address, info.pipe)
        assert.equals(123, info.session_generation)
        assert.equals(protocol.VERSION, info.protocol_version)
        -- Write-authority lock held.
        assert.is_not_nil(lock.read(root))
        -- Client stub detects it live + compatible.
        local st = client.detect(root)
        assert.is_true(st.present)
        assert.is_true(st.live)
        assert.is_true(st.compatible)
    end)

    it("answers the hello handshake with welcome", function()
        server = server_mod.new(root, { generation = 999 })
        assert.is_true((server:start()))
        local c = connect(server.address)
        assert.is_true(waitfor(function() return c.connected end))
        c.send({ kind = protocol.KIND.hello, req_id = 1, protocol_version = protocol.VERSION })
        assert.is_true(waitfor(function() return #c.messages > 0 end))
        local w = c.messages[1]
        assert.equals("welcome", w.kind)
        assert.equals(1, w.req_id)
        assert.equals(999, w.session_generation)
        assert.equals(protocol.VERSION, w.protocol_version)
        assert.is_true(w.compatible)
        assert.is_number(w.current_seq)
        c.close()
    end)

    it("answers ping with ok", function()
        server = server_mod.new(root)
        assert.is_true((server:start()))
        local c = connect(server.address)
        assert.is_true(waitfor(function() return c.connected end))
        c.send({ kind = "ping", req_id = 5 })
        assert.is_true(waitfor(function() return #c.messages > 0 end))
        assert.equals("ok", c.messages[1].kind)
        assert.equals(5, c.messages[1].req_id)
        c.close()
    end)

    it("shuts down gracefully and drops the handle + lock", function()
        server = server_mod.new(root)
        assert.is_true((server:start()))
        local stopped = false
        server.opts.on_stop = function() stopped = true end
        local result
        client.stop(root, {}, function(r) result = r end)
        assert.is_true(waitfor(function() return result ~= nil and server:is_stopped() end, 3000))
        assert.is_true(result.stopped)
        assert.equals("shutdown", result.method)
        assert.is_nil(handle.read(root))
        assert.is_nil(lock.read(root))
    end)

    it("a second daemon for the same root refuses to start (single primary)", function()
        server = server_mod.new(root)
        assert.is_true((server:start()))
        local other = server_mod.new(root)
        local ok, reason = other:start()
        assert.is_nil(ok)
        assert.is_truthy(reason:find("already owns"))
    end)

    it("idle-times-out when no clients are attached", function()
        server = server_mod.new(root, { idle_seconds = 0 })
        local stopped = false
        server = server_mod.new(root, { idle_seconds = 0, on_stop = function() stopped = true end })
        assert.is_true((server:start()))
        assert.is_true(waitfor(function() return server:is_stopped() end, 3000))
        assert.is_true(stopped)
        assert.is_nil(handle.read(root))
    end)
end)
