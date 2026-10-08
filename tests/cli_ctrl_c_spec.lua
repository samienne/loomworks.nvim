-- The CLI's two-stage Ctrl-C for a routed operation (spec §19.15 "Task
-- ownership"): the first Ctrl-C sends `loomworks.Tasks/1.cancel` and lw keeps
-- waiting; the second ends lw (closing the connection). A daemon without
-- Tasks/1 (protocol 10) gets the connection closed on the first one.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

--- A client session double: records interface calls; `answer` is what each
--- call's callback receives.
local function fake_conn(transport, answer)
    local c = { transport = transport, calls = {} }
    function c:call(object, iface, v, method, args, cb)
        self.calls[#self.calls + 1] = { object = object, iface = iface, v = v, method = method, args = args }
        cb(answer and answer[1], answer and answer[2])
    end
    return c
end

describe("two-stage Ctrl-C (cli)", function()
    after_each(function() cli._set_interrupt_intercept(nil) end)

    it("the first Ctrl-C goes to the interceptor, the second ends lw with 130", function()
        local code, offered = nil, 0
        local cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
        cli._set_interrupt_intercept(function() offered = offered + 1; return true end)
        cleanup("sigint")
        assert.equals(1, offered)
        assert.is_nil(code)
        cleanup("sigint")
        assert.equals(1, offered)
        assert.equals(130, code)
    end)

    it("only Ctrl-C is intercepted: Ctrl-Break, a hangup, a termination end lw at once", function()
        for _, sig in ipairs({ "sigbreak", "sighup", "sigterm" }) do
            local code, offered = nil, false
            local cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
            cli._set_interrupt_intercept(function() offered = true; return true end)
            cleanup(sig)
            assert.is_false(offered, sig)
            assert.equals(130, code, sig)
            cli._set_interrupt_intercept(nil)
        end
    end)

    it("an interceptor that does not handle it, or escalates, ends lw", function()
        local code
        local cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
        cli._set_interrupt_intercept(function() return false end)
        cleanup("sigint")
        assert.equals(130, code)

        code = nil
        local escalate
        cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
        cli._set_interrupt_intercept(function(e) escalate = e; return true end)
        cleanup("sigint")
        assert.is_nil(code)
        escalate()
        assert.equals(130, code)
        code = nil
        cleanup("sigint") -- fired once only
        assert.is_nil(code)
    end)

    it("_routed_cancel sends Tasks/1.cancel for the task and keeps waiting", function()
        local conn = fake_conn(11, { { outcome = "ok" }, nil })
        local escalated = false
        assert.is_true(cli._routed_cancel(conn, "t-1", function() escalated = true end))
        assert.equals(1, #conn.calls)
        local c = conn.calls[1]
        assert.same({ "/tasks", "loomworks.Tasks", 1, "cancel", { task_id = "t-1" } },
            { c.object, c.iface, c.v, c.method, c.args })
        assert.is_false(escalated)
    end)

    it("_routed_cancel: a task that already ended or a closed connection keeps waiting", function()
        for _, err in ipairs({ { code = "forbidden" }, { code = "closed" } }) do
            local escalated = false
            assert.is_true(cli._routed_cancel(fake_conn(11, { nil, err }), "t-1", function() escalated = true end))
            assert.is_false(escalated, err.code)
        end
    end)

    it("_routed_cancel: a daemon without Tasks/1 closes the connection (protocol 10, no interface)", function()
        -- Protocol 10: no interface calls, an integer task id.
        assert.is_false(cli._routed_cancel(fake_conn(10), 3, function() end))
        assert.is_false(cli._routed_cancel(fake_conn(11), 3, function() end))
        local closed = fake_conn(11); closed.closed = true
        assert.is_false(cli._routed_cancel(closed, "t-1", function() end))
        -- Transport 11 whose daemon has no Tasks/1: escalated.
        for _, code in ipairs({ "unknown_object", "unknown_interface", "unknown_method", "unsupported_version" }) do
            local escalated = false
            assert.is_true(cli._routed_cancel(fake_conn(11, { nil, { code = code } }), "t-1",
                function() escalated = true end))
            assert.is_true(escalated, code)
        end
    end)
    describe("_await_routed / _interrupted_end", function()
        local writes
        local orig_stderr
        before_each(function()
            writes = {}
            orig_stderr = io.stderr
            io.stderr = { write = function(_, s) writes[#writes + 1] = s end, flush = function() end }
        end)
        after_each(function() io.stderr = orig_stderr end)
        local function err_text() return table.concat(writes) end

        it("the first Ctrl-C while waiting cancels, prints one line, and is recorded", function()
            local conn = fake_conn(11, { { outcome = "ok" }, nil })
            local code
            local cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
            local intercepted = cli._await_routed(conn, "t-1", "build", function() cleanup("sigint") end)
            assert.is_true(intercepted)
            assert.is_nil(code)
            assert.equals(1, #conn.calls)
            assert.equals("lw: stopping the build - press Ctrl-C again to stop waiting\n", err_text())
            assert.is_nil(cli._interrupt_intercept)
        end)

        it("no Ctrl-C: not recorded, no line, the previous interceptor restored", function()
            local prev = function() return true end
            cli._set_interrupt_intercept(prev)
            local seen
            local intercepted = cli._await_routed(fake_conn(11), "t-1", "test", function()
                seen = cli._interrupt_intercept
            end)
            assert.is_false(intercepted)
            assert.is_function(seen)
            assert.are_not.equal(prev, seen)
            assert.equals(prev, cli._interrupt_intercept)
            assert.equals("", err_text())
        end)

        it("a Ctrl-C the daemon cannot take (protocol 10) is not recorded and prints nothing", function()
            local code
            local cleanup = cli._make_interrupt_cleanup(130, function(c) code = c end)
            local intercepted = cli._await_routed(fake_conn(10), 3, "build", function() cleanup("sigint") end)
            assert.is_false(intercepted)
            assert.equals(130, code)
            assert.equals("", err_text())
        end)

        it("restores the interceptor when the wait raises, and re-raises", function()
            local prev = function() return true end
            cli._set_interrupt_intercept(prev)
            local ok, err = pcall(cli._await_routed, fake_conn(11), "t-1", "build", function() error("boom", 0) end)
            assert.is_false(ok)
            assert.equals("boom", err)
            assert.equals(prev, cli._interrupt_intercept)
        end)

        it("after an intercepted Ctrl-C a run whose task finished is not started: 130", function()
            assert.equals(130, cli._interrupted_end("run", { code = 0 }))
            assert.truthy(err_text():find("the program was not started", 1, true))
        end)

        it("after an intercepted Ctrl-C every end exits 130", function()
            assert.equals(130, cli._interrupted_end("build", { code = 0 }))
            assert.equals(130, cli._interrupted_end("build", { code = 1 }))
            assert.equals(130, cli._interrupted_end("test", { code = 130 }))
            assert.equals("", err_text())
            assert.equals(130, cli._interrupted_end("build", { code = 1, error = "no running task" }))
            assert.truthy(err_text():find("lw: no running task", 1, true))
        end)

        it("a connection lost after an intercepted Ctrl-C exits 130 with a line", function()
            assert.equals(130, cli._interrupted_end("build", nil))
            assert.equals("lw: lost the connection to the workspace daemon while stopping the build\n", err_text())
        end)
    end)
end)
