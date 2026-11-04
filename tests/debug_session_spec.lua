-- loomworks.debug.run's `on_terminated` follows the one session its run
-- started (bound on nvim-dap's `on_session`, ended on that session's
-- `on_close`): another session ending never fires it, its own end fires it
-- once whether or not the adapter said `terminated`, and the returned
-- control's `stop` ends it (the live session disconnected, else at once).

describe("debug.run session tracking", function()
    local dbg = require("loomworks.debug")
    local saved_dap
    local fake, next_id

    local function new_session(name, parent)
        next_id = next_id + 1
        local s = { id = next_id, config = { name = name }, on_close = {}, closed = false, parent = parent }
        function s.disconnect(self)
            self.closed = true
            for _, f in pairs(self.on_close) do f(self) end
            self.on_close = {}
        end
        if not parent then fake._sessions[s.id] = s end
        for _, f in pairs(fake.listeners.on_session) do f(nil, s) end
        return s
    end

    local function close(s) s:disconnect() end

    before_each(function()
        saved_dap = package.loaded["dap"]
        next_id = 0
        fake = {
            adapters = { codelldb = {} },
            listeners = { before = { event_terminated = {}, event_exited = {} },
                after = { event_initialized = {} }, on_session = {} },
            _sessions = {},
            runs = {},
        }
        fake.sessions = function() return fake._sessions end
        fake.run = function(config) fake.runs[#fake.runs + 1] = config end
        package.loaded["dap"] = fake
    end)
    after_each(function() package.loaded["dap"] = saved_dap end)

    local function start(name)
        local ended = 0
        local ok, ctl = dbg.run({ name = name, program = "/b/t", adapter = "codelldb" },
            { on_terminated = function() ended = ended + 1 end })
        assert.is_true(ok)
        return function() return ended end, ctl
    end

    it("another session ending does not fire it; its own session's end fires it once", function()
        local other = new_session("Other")
        local ended = start("Debug test")
        local mine = new_session("Debug test")
        local attach = new_session("Debug test (codelldb)")
        close(other)
        close(attach)
        vim.wait(50)
        assert.equals(0, ended())
        close(mine)
        assert.is_true(vim.wait(1000, function() return ended() == 1 end, 10))
        close(mine)
        vim.wait(50)
        assert.equals(1, ended())
    end)

    it("a session already running under the same name is not its own", function()
        local before = new_session("Debug test")
        local ended = start("Debug test")
        close(before)
        vim.wait(50)
        assert.equals(0, ended())
    end)

    it("a session that closes without terminated (an adapter failure) still fires it", function()
        local ended = start("Debug test")
        local mine = new_session("Debug test")
        mine.closed = true
        for _, f in pairs(mine.on_close) do f(mine) end
        assert.is_true(vim.wait(1000, function() return ended() == 1 end, 10))
    end)

    it("stop disconnects its live session, which then fires it once", function()
        local ended, ctl = start("Debug test")
        local mine = new_session("Debug test")
        ctl.stop()
        assert.is_true(mine.closed)
        assert.is_true(vim.wait(1000, function() return ended() == 1 end, 10))
    end)

    it("stop before any session started fires it at once; a late session is disconnected", function()
        local ended, ctl = start("Debug test")
        ctl.stop()
        assert.is_true(vim.wait(1000, function() return ended() == 1 end, 10))
        local late = new_session("Debug test")
        assert.is_true(late.closed)
        vim.wait(50)
        assert.equals(1, ended())
    end)
end)
