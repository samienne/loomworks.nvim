-- A buffer that resolves its managed server before the workspace loads, in
-- `daemon` runtime mode (integrations.md §9.7, §9.8; daemon.md §19.16 "LSP
-- configuration"): the gate holds it on the workspace marker it finds on
-- disk, and the auto-load's `lw.setup({ root })` must keep it held — no
-- `workspace_closed` drains the gate on the way (that event is for a shutdown
-- with no successor) — so no stock server starts for it. It starts on the
-- daemon's configuration once that arrives.

local lw = require("loomworks")
local observer = require("loomworks.daemon.observer")
local source = require("loomworks.lsp_source")
local lsp = require("loomworks.lsp")
local views = require("loomworks.views")
local events = require("loomworks")
local H = require("tests.daemon_helpers")

local LSP_FEATURE = observer.LSP.feature

describe("daemon mode: a buffer held before the workspace loads (§9.7)", function()
    local root, real_attach, saved_deps
    local obs, calls

    --- What `observer.attach` does, without a daemon: an observer of `r`,
    --- still connecting, over a fake connection the test answers.
    local function stub_attach(r)
        calls = {}
        local conn = { closed = false }
        function conn:call(object, iface, v, method, args, cb, env)
            calls[#calls + 1] = { object = object, method = method, cb = cb }
        end
        function conn:close() self.closed = true end
        obs = setmetatable({
            root = r, state = "connecting", mode = "interfaces", conn = conn,
            daemon = { pid = 1 }, seq = 0, _tasks = {}, _order = {}, _owned = {},
            _feat = { [LSP_FEATURE] = "subscribed" }, _why = {},
            opts = { environ = function() return {} end, resolve = function() return "lw" end,
                relay = function() return { close = function() end } end },
        }, observer.Observer)
        function obs:_spawn() end
        observer._current = obs
        observer._attached_root = "/w"
        views.daemon_root(r)
        return obs
    end

    before_each(function()
        root = H.tmp()
        vim.fn.mkdir(root .. "/app", "p")
        vim.fn.mkdir(root .. "/.nvim", "p")
        local f = io.open(root .. "/.nvim/loomworks.user.json", "w"); f:write("{}"); f:close()
        lw.shutdown()
        real_attach = observer.attach
        observer.attach = function(r) return stub_attach(r) end
        -- setup's hard dependencies, where the test environment lacks them.
        saved_deps = { overseer = package.loaded["overseer"], snacks = package.loaded["snacks"] }
        for _, dep in ipairs({ "overseer", "snacks" }) do
            if not pcall(require, dep) then package.loaded[dep] = {} end
        end
        source._reset_changes()
        lsp._reset_gate()
        lsp._reset_withheld()
        lsp.register("fakesrv", { withhold_reason = function() return nil end })
    end)
    after_each(function()
        observer.attach = real_attach
        if observer._current then views.clear(observer._current) end
        observer._current, observer._attached_root = nil, nil
        views.daemon_root(nil)
        lsp.register("fakesrv", {})
        lsp._reset_gate()
        lsp._reset_withheld()
        package.loaded["overseer"], package.loaded["snacks"] = saved_deps.overseer, saved_deps.snacks
        lw.shutdown()
    end)

    it("stays held through lw.setup({ root }) and starts only on the daemon's configuration", function()
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, root .. "/app/main.cpp")
        local started, fell = {}, 0
        -- The buffer's filetype is set before auto-load: no root is known
        -- yet, the marker on disk holds it.
        lsp.managed_root_dir("fakesrv", buf,
            function(dir) started[#started + 1] = dir end,
            function() fell = fell + 1 end)
        assert.equals("held", lsp.buf_state(buf))
        assert.equals(1, lsp._gate_queue_len())

        local closed = 0
        local function on_closed() closed = closed + 1 end
        events.on("workspace_closed", on_closed)
        lw.setup({ root = root, lsp = false, keys = false })
        events.off("workspace_closed", on_closed)

        assert.equals(obs, observer.current())
        -- A load with a successor closes nothing: the hold stays, no stock
        -- server and no managed one starts.
        vim.wait(100)
        assert.equals(0, fell, "the stock server was started (fallback)")
        assert.equals("held", lsp.buf_state(buf))
        assert.equals(1, lsp._gate_queue_len())
        assert.equals(0, #started)
        assert.equals(0, closed)

        -- The daemon's LspConfig arrives: the buffer gets the managed config.
        obs.state = "connected"
        views.set(obs, "projects", { projects = {
            { key = "app", id = "p1", label = "app", type = "shell", path = "app", abs_path = root .. "/app" },
        } })
        obs:_fetch_lsp()
        calls[#calls].cb({
            state = "loaded", ready = true,
            projects = { { project = "app", id = "p1", path = "app", entries = { {
                server = "fakesrv", root_dir = root .. "/app", db_state = "ready",
                db_dir = root .. "/out/Debug", db_rev = 0,
            } } } },
            options = {},
        })
        assert.is_true(vim.wait(2000, function() return #started == 1 end, 10))
        assert.equals(root .. "/app", started[1])
        assert.equals(0, fell)
        assert.equals("ok", lsp.buf_state(buf))
        assert.equals(0, lsp._gate_queue_len())
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
