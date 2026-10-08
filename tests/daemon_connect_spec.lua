-- Connect or start (spec §19.10 "Connections"): loomworks.daemon.connect,
-- the one path the CLI's ensure step and the `--stdio` relay take to the
-- workspace daemon — and the daemon instance id `<pid>:<start_time>` of
-- §19.5 / §19.10 "Skip an instance". Against an in-process server; no real
-- daemon is launched.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local connect = require("loomworks.daemon.connect")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local handle = require("loomworks.daemon.handle")
local dpaths = require("loomworks.daemon.paths")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

-- The suite runs every spec file at once: an in-process handshake can take
-- seconds on a loaded runner.
client.TIMEOUT_MS = 30000
local STEP = 30000

describe("daemon instance ids (§19.5, §19.10 \"Skip an instance\")", function()
    it("formats <pid>:<start_time> from a pid and start time, or a record", function()
        assert.equals("1234:win:133700000000000000", connect.instance_id(1234, "win:133700000000000000"))
        assert.equals("7:linux:0f3a-b2:4711", connect.instance_id({ pid = 7, start_time = "linux:0f3a-b2:4711" }))
        assert.equals("9:mac:1700000000.250", connect.instance_id(9, "mac:1700000000.250"))
    end)

    it("names no instance without a usable pid and start time", function()
        assert.is_nil(connect.instance_id(1234, nil))
        assert.is_nil(connect.instance_id(nil, "win:1"))
        assert.is_nil(connect.instance_id(0, "win:1"))
        assert.is_nil(connect.instance_id(1.5, "win:1"))
        assert.is_nil(connect.instance_id(12, "133700"))  -- no method prefix
        assert.is_nil(connect.instance_id(12, "win:"))
        assert.is_nil(connect.instance_id({ pid = 12 }))
    end)

    it("parses an id at its first colon (a start time may contain colons)", function()
        assert.same({ pid = 7, start_time = "linux:0f3a-b2:4711" }, connect.parse_instance("7:linux:0f3a-b2:4711"))
        assert.same({ pid = 1234, start_time = "win:133700000000000000" },
            connect.parse_instance("1234:win:133700000000000000"))
        local id = connect.instance_id(42, "mac:1700000000.250")
        assert.same({ pid = 42, start_time = "mac:1700000000.250" }, connect.parse_instance(id))
    end)

    it("refuses a value that is not <pid>:<start_time>", function()
        for _, bad in ipairs({ "", "1234", "1234:", ":win:1", "abc:win:1", "-1:win:1", "0:win:1", "12:133700",
            "12:win:", "12:win:1 2", " 12:win:1", "1.5:win:1" }) do
            assert.is_nil(connect.parse_instance(bad), bad)
        end
        assert.is_nil(connect.parse_instance(nil))
        assert.is_nil(connect.parse_instance(1234))
    end)

    it("compares instances by pid and start time", function()
        local h = { pid = 1234, start_time = "win:100", endpoint = "x" }
        assert.is_true(connect.same_instance(h, "1234:win:100"))
        assert.is_true(connect.same_instance("1234:win:100", { pid = 1234, start_time = "win:100" }))
        -- A reused pid (another start time) is another instance.
        assert.is_false(connect.same_instance(h, "1234:win:101"))
        assert.is_false(connect.same_instance(h, "1235:win:100"))
        -- Without a start time a record names no instance: never a match.
        assert.is_false(connect.same_instance({ pid = 1234 }, { pid = 1234 }))
        assert.is_false(connect.same_instance(h, nil))
        assert.is_false(connect.same_instance(h, "garbage"))
    end)
end)

describe("connect or start (§19.10)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = nil
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)
    local function start_server()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
        return srv
    end

    it("connects to the live daemon: an authenticated connection, nothing launched", function()
        start_server()
        local r = connect.connect_or_start(root, { step_ms = STEP, launch = function() error("must not launch") end })
        assert.equals("connected", r.outcome, tostring(r.detail))
        assert.equals("live", r.st.kind)
        assert.is_false(r.launched)
        assert.truthy(r.conn.challenge)
        assert.is_true(connect.same_instance(r.st.handle, { pid = srv.pid, start_time = srv.start_time })
            or srv.start_time == nil)
        assert.truthy(client.request(r.conn, { kind = "ping" }, STEP))
        r.conn:close()
    end)

    it("connect = false only reports the live daemon", function()
        start_server()
        local r = connect.connect_or_start(root, { step_ms = STEP, connect = false,
            launch = function() error("must not launch") end })
        assert.equals("live", r.outcome)
        assert.is_nil(r.conn)
        assert.equals(0, srv:client_count())
    end)

    it("an endpoint that does not prove this lw's key: \"untrusted\", no connection", function()
        start_server()
        local r = connect.connect_or_start(root, { step_ms = STEP, session = { key = string.rep("x", 32) },
            launch = function() error("must not launch") end })
        assert.equals("untrusted", r.outcome)
        assert.is_nil(r.conn)
        assert.equals(0, srv:client_count())
    end)

    it("no daemon: launches one, and connects to it only with connect_launched", function()
        local calls = 0
        local function launch(r0)
            assert.equals(root, r0)
            calls = calls + 1
            start_server()
            return true, require("loomworks.daemon.inspect").state(root)
        end
        local r = connect.connect_or_start(root, { step_ms = STEP, launch = launch })
        assert.equals("launched", r.outcome)
        assert.equals(1, calls)
        assert.is_true(r.launched)
        assert.equals(srv.pid, r.launch_state.handle.pid)
        assert.is_nil(r.conn)
        srv:stop("test end", 0)
        assert.is_true(vim.wait(5000, function() return handle.read(root) == nil end, 20))
        -- (A fresh root: this process cannot rebind the stopped server's
        -- endpoint at once.)
        root = H.workspace()

        local r2 = connect.connect_or_start(root, { step_ms = STEP, launch = launch, connect_launched = true })
        assert.equals("connected", r2.outcome, tostring(r2.detail))
        assert.equals(2, calls)
        assert.is_true(r2.launched)
        assert.truthy(r2.conn.challenge)
        r2.conn:close()
    end)

    it("a launch failure is reported with its reason", function()
        local r = connect.connect_or_start(root, { step_ms = STEP,
            launch = function() return false, "it exited with status 1" end })
        assert.equals("launch_failed", r.outcome)
        assert.equals("it exited with status 1", r.detail)
    end)

    it("a hung daemon is \"hung\" unless on_hung recovers it", function()
        start_server()
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        local launch = function() error("must not launch") end
        local r = connect.connect_or_start(root, { step_ms = STEP, launch = launch })
        assert.equals("hung", r.outcome)
        local seen
        r = connect.connect_or_start(root, { step_ms = STEP, launch = launch,
            on_hung = function(st) seen = st; return nil end })
        assert.equals("hung", r.outcome)
        assert.equals("hung", seen.kind)
    end)

    it("a daemon on another host is \"elsewhere\" (foreign), never launched over", function()
        local rec = require("loomworks.lock_record").new("daemon", { mode = "daemon" })
        rec.host, rec.kind = "OTHERHOST", "daemon"
        local f = assert(io.open(dpaths.lock_path(root), "w")); f:write(vim.json.encode(rec)); f:close()
        local r = connect.connect_or_start(root, { step_ms = STEP, launch = function() error("must not launch") end })
        assert.equals("elsewhere", r.outcome)
        assert.equals("foreign", r.st.kind)
        os.remove(dpaths.lock_path(root))
    end)

    it("waits at most one step for a daemon still starting", function()
        local rec = require("loomworks.lock_record").new("daemon", { mode = "daemon" })
        local f = assert(io.open(dpaths.lock_path(root), "w")); f:write(vim.json.encode(rec)); f:close()
        local t0 = uv.hrtime()
        local r = connect.connect_or_start(root, { step_ms = 300, launch = function() error("must not launch") end })
        local ms = (uv.hrtime() - t0) / 1e6
        assert.equals("starting", r.outcome)
        assert.truthy(ms >= 250 and ms < 5000, ms .. " ms")
        os.remove(dpaths.lock_path(root))
    end)
end)
