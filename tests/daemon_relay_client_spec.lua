-- The editor's relay client and the relay process rules (spec §19.16 "The
-- relay process"), against fake relay processes
-- (tests/fixtures/fake_relay_proc.lua): a relay that ignores EOF on its
-- standard input is ended by a plain kill of its own pid after KILL_MS, and
-- the detached child it started (as a relay starts the shared daemon) lives
-- on; the relay's exit and the EOF on its standard output in either order
-- (the EOF_GRACE_MS grace after the exit; the EXIT_WAIT_MS bound after the
-- EOF, then an internal error and the relay is ended).

local client = require("loomworks.daemon.client")
local RC = client.relay
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

local SCRIPT = H.REPO .. "/tests/fixtures/fake_relay_proc.lua"

local function now_ms() return uv.hrtime() / 1e6 end

local function alive(pid)
    local ok, r = pcall(uv.kill, pid, 0)
    return ok and r == 0
end

describe("the editor's relay client: the relay process (§19.16)", function()
    local root, relays, extra_pids
    before_each(function()
        root = H.workspace()
        relays, extra_pids = {}, {}
    end)
    after_each(function()
        for _, r in ipairs(relays) do
            if r.code == nil and r.proc then pcall(function() r.proc:kill("sigkill") end) end
        end
        for _, pid in ipairs(extra_pids) do pcall(uv.kill, pid, "sigkill") end
        H.cleanup()
    end)

    --- Spawn a fake relay of `mode`; `cb` records the outcome.
    local function spawn(mode, a, o)
        local got = {}
        local opts = vim.tbl_extend("force", {
            argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", SCRIPT, mode, a or "0" },
            root = root, form = "ordinary", client = "editor", role = "observer",
        }, o or {})
        local r = assert(RC.connect(opts, function(c, err, info)
            got.n = (got.n or 0) + 1
            got.conn, got.err, got.info, got.at = c, err, info, now_ms()
        end))
        relays[#relays + 1] = r
        return r, got
    end

    it("a relay that ignores EOF is killed (its own pid only) after KILL_MS; its detached child lives on", function()
        local pidfile = H.tmp() .. "-child.pid"
        local r, got = spawn("ignore", pidfile, { kill_ms = 3000 })
        local child
        assert.is_true(vim.wait(20000, function()
            local f = io.open(pidfile, "r")
            if not f then return false end
            child = tonumber(f:read("*a")); f:close()
            return child ~= nil
        end, 20), "the fake relay did not start its child")
        extra_pids[#extra_pids + 1] = child
        -- Block the loop a while first (as a slow condition check or a loaded
        -- machine does): KILL_MS still counts from the close, not from the
        -- loop's last poll (its cached time, which a timer counts from).
        local block = now_ms()
        while now_ms() - block < 600 do end
        local t0 = now_ms()
        r:close()
        assert.is_true(r.ended)
        -- Standard input closed, and the relay ignores that: still running
        -- before KILL_MS.
        vim.wait(700)
        assert.is_nil(r.code)
        assert.is_true(alive(r.pid))
        -- Then killed: a plain kill of its own process.
        assert.is_true(vim.wait(10000, function() return r.code ~= nil end, 10), "the relay was not killed")
        assert.is_true(now_ms() - t0 >= 2900, "killed before KILL_MS")
        -- Nothing else: the detached child it started is untouched.
        assert.is_true(alive(child), "the relay's child was killed too")
        -- Ended by the editor: not mapped.
        assert.is_nil(got.n)
    end)

    it("EOF, then the exit within EXIT_WAIT_MS: the status is mapped once it comes", function()
        local t0 = now_ms()
        local r, got = spawn("eof-exit", "1200", { exit_wait_ms = 5000 })
        assert.is_true(vim.wait(20000, function() return got.n ~= nil end, 10))
        assert.equals(1, got.n)
        assert.equals("exit", got.err)
        assert.equals(10, got.info.code)
        assert.is_true(r.eof)
        assert.is_true(got.at - t0 >= 1100, "reported before the exit")
        assert.is_nil(r.ended)
    end)

    it("the exit, then the EOFs within EOF_GRACE_MS: reported after the EOFs", function()
        -- The EOFs come once the child (a fresh nvim) started and slept 400 ms:
        -- a wide grace, so a slow start on a loaded machine is not mistaken
        -- for EOFs that never come (that case is the next test).
        local r, got = spawn("exit-held", "400", { eof_grace_ms = 15000 })
        assert.is_true(vim.wait(20000, function() return got.n ~= nil end, 10))
        assert.equals("exit", got.err)
        assert.equals(10, got.info.code)
        assert.is_true(r.eof)
    end)

    it("the exit, then EOFs that do not come: reported EOF_GRACE_MS after the exit", function()
        local exited
        local r, got = spawn("exit-held", "6000")
        assert.is_true(vim.wait(20000, function()
            if r.code ~= nil and not exited then exited = now_ms() end
            return got.n ~= nil
        end, 5))
        assert.equals("exit", got.err)
        assert.equals(10, got.info.code)
        -- Still held by the child: reported at the grace, not at the EOF.
        assert.is_nil(r.eof)
        local waited = got.at - exited
        assert.is_true(waited >= RC.EOF_GRACE_MS - 100 and waited < RC.EOF_GRACE_MS + 2500, tostring(waited))
    end)

    it("EOF, then no exit within EXIT_WAIT_MS: an internal error, and the relay is ended (killed after KILL_MS)", function()
        local t0 = now_ms()
        local r, got = spawn("eof-hang", nil, { exit_wait_ms = 800, kill_ms = 800 })
        assert.is_true(vim.wait(20000, function() return got.n ~= nil end, 10))
        assert.equals(1, got.n)
        assert.is_nil(got.conn)
        assert.equals("protocol", got.err)
        assert.is_nil(got.info.code)
        assert.truthy(got.info.line:find("had not exited", 1, true), got.info.line)
        assert.is_true(r.eof)
        assert.is_true(got.at - t0 >= 700, "reported before EXIT_WAIT_MS")
        -- Ended: standard input closed, and (it ignores EOF) killed after KILL_MS.
        assert.is_true(r.ended)
        assert.is_true(vim.wait(10000, function() return r.code ~= nil end, 10), "the relay was not killed")
        assert.equals(1, got.n)
    end)
end)
