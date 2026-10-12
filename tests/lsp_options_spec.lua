--- Tests for Workspace LSP-options API (user.json `lsp` block).
--- Covers validation on load, default merging in get_lsp_options,
--- persistence via set_lsp_option, and the redundancy-elision
--- behaviour that keeps user.json from accumulating default values.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

local mock_modules = {
    cmake = {
        has_keyed_tools = true,
        map_variant = function(variant_type, available_configs)
            for _, name in ipairs(available_configs) do
                if name:lower() == variant_type then return name end
            end
            return nil
        end,
        tool_key = function(tool_data) return tool_data.id end,
        tool_label = function(tool_data) return tool_data.display end,
        detect_tools_async = function(callback) callback({}) end,
        info = function()
            return { configurations = { Debug = {}, Release = {} } }
        end,
    },
}

--- Build a workspace with the given user/lsp overrides. Captures
--- saved user.json content and emitted events for assertion.
local function make_ws(user_overrides)
    local config_json = h.make_config_json()
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil

    local data = workspace.assemble("/root", config_json, user_json, nil, { trust = require("tests.helpers").trust_all })
    assert(data, "assemble failed")

    local events_log = {}
    local notifications = {}
    local saved = nil
    local mock_core = {
        _deps = {
            merge = merge,
            cache = cache_mod,
            events = {
                emit = function(event, ev_data)
                    events_log[#events_log + 1] = { event = event, data = ev_data }
                end,
            },
            user = {
                save = function(_, payload)
                    saved = payload
                    return true
                end,
                filepath = function(root) return root .. "/.nvim/loomworks.user.json" end,
            },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function(msg, level)
                notifications[#notifications + 1] = { msg = msg, level = level }
            end,
            schedule = function(fn) fn() end,
        },
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws, {
        events = events_log,
        notifications = notifications,
        get_saved = function() return saved end,
    }
end

describe("Workspace LSP options", function()
    describe("get_lsp_options with no user config", function()
        it("returns the integration defaults", function()
            local ws = make_ws()
            local opts = ws:get_lsp_options("clangd")
            assert.is_true(opts.clang_tidy)
            assert.is_true(opts.background_index)
            assert.equals("low", opts.background_index_priority)
            assert.same({}, opts.extra_args)
        end)

        it("returns an empty table for unknown servers", function()
            local ws = make_ws()
            assert.same({}, ws:get_lsp_options("eslint"))
        end)
    end)

    describe("get_lsp_options with user overrides", function()
        it("merges user values over defaults", function()
            local ws = make_ws({
                lsp = {
                    clangd = {
                        clang_tidy = false,
                        background_index_priority = "background",
                    },
                },
            })
            local opts = ws:get_lsp_options("clangd")
            assert.is_false(opts.clang_tidy)
            assert.is_true(opts.background_index)  -- default still applies
            assert.equals("background", opts.background_index_priority)
        end)

        it("returns a fresh table so callers can mutate safely", function()
            local ws = make_ws()
            local a = ws:get_lsp_options("clangd")
            a.extra_args[#a.extra_args + 1] = "--foo"
            local b = ws:get_lsp_options("clangd")
            assert.same({}, b.extra_args)
        end)
    end)

    describe("validation", function()
        it("logs and drops unknown keys", function()
            local _, env = make_ws({
                lsp = { clangd = { not_a_real_flag = true } },
            })
            local found = false
            for _, n in ipairs(env.notifications) do
                if n.msg:find("not_a_real_flag") then found = true end
            end
            assert.is_true(found)
        end)

        it("logs and drops values of the wrong type", function()
            local ws, env = make_ws({
                lsp = { clangd = { clang_tidy = "yes" } },
            })
            -- Should fall back to default.
            assert.is_true(ws:get_lsp_options("clangd").clang_tidy)
            local found = false
            for _, n in ipairs(env.notifications) do
                if n.msg:find("clang_tidy") and n.msg:find("boolean") then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("logs and drops priority values outside the enum", function()
            local ws, env = make_ws({
                lsp = { clangd = { background_index_priority = "ultra" } },
            })
            assert.equals("low",
                ws:get_lsp_options("clangd").background_index_priority)
            local found = false
            for _, n in ipairs(env.notifications) do
                if n.msg:find("background_index_priority") then
                    found = true
                end
            end
            assert.is_true(found)
        end)

        it("filters non-string entries from extra_args", function()
            local ws = make_ws({
                lsp = { clangd = { extra_args = { "--ok", 42, "--also-ok" } } },
            })
            assert.same({ "--ok", "--also-ok" },
                ws:get_lsp_options("clangd").extra_args)
        end)
    end)

    describe("set_lsp_option", function()
        it("persists the new value and emits lsp_options_changed", function()
            local ws, env = make_ws()
            ws:set_lsp_option("clangd", "clang_tidy", false)
            assert.is_false(ws:get_lsp_options("clangd").clang_tidy)

            local emitted
            for _, e in ipairs(env.events) do
                if e.event == "lsp_options_changed" then emitted = e.data end
            end
            assert.is_not_nil(emitted)
            assert.equals("clangd", emitted.server)
            assert.equals("clang_tidy", emitted.key)
            assert.is_false(emitted.value)

            -- saved payload should contain the override.
            local payload = env.get_saved()
            assert.is_table(payload.lsp)
            assert.is_false(payload.lsp.clangd.clang_tidy)
        end)

        it("drops the entry when set back to the default", function()
            local ws, env = make_ws({
                lsp = { clangd = { clang_tidy = false } },
            })
            ws:set_lsp_option("clangd", "clang_tidy", true)
            -- get still returns the default.
            assert.is_true(ws:get_lsp_options("clangd").clang_tidy)
            -- saved payload should have NO lsp block (or an empty one).
            local payload = env.get_saved()
            assert.is_true(payload.lsp == nil
                or payload.lsp.clangd == nil
                or next(payload.lsp.clangd) == nil)
        end)

        it("refuses an unknown server or key or a mistyped value, writing and emitting nothing", function()
            local ws, env = make_ws({ lsp = { clangd = { clang_tidy = false } } })
            local cases = {
                { "pyright", "clang_tidy", false },
                { "clangd", "no_such_option", true },
                { "clangd", "no_such_option", nil },
                { "clangd", "clang_tidy", "yes" },
                { "clangd", "background_index_priority", "urgent" },
                { "clangd", "extra_args", "--flag" },
                { "clangd", "extra_args", { "--ok", 42 } },
                { nil, "clang_tidy", true },
            }
            for i, c in ipairs(cases) do
                local ok, err = ws:set_lsp_option(c[1], c[2], c[3])
                assert.is_false(ok, "case " .. i)
                assert.is_string(err, "case " .. i)
            end
            assert.is_nil(env.get_saved(), "nothing was written")
            for _, e in ipairs(env.events) do
                assert.are_not.equal("lsp_options_changed", e.event)
            end
            assert.same({ clangd = { clang_tidy = false } }, ws._lsp_options)
            assert.is_nil(workspace.lsp_option_problem("clangd", "extra_args", { "--a", "--b" }))
            assert.is_nil(workspace.lsp_option_problem("clangd", "background_index_priority", "normal"))
        end)

        it("a refused save puts the options back and emits nothing (clangd is not restarted)", function()
            local ws, env = make_ws({ lsp = { clangd = { clang_tidy = false } } })
            ws._core._deps.user.save = function() return false, "disk full" end
            local ok, err = ws:set_lsp_option("clangd", "background_index", false)
            assert.is_false(ok)
            assert.equals("disk full", err)
            assert.same({ clangd = { clang_tidy = false } }, ws._lsp_options)
            for _, e in ipairs(env.events) do
                assert.are_not.equal("lsp_options_changed", e.event)
            end
        end)
    end)
end)

-- A stale working copy (§2.7), on disk: another process wrote user.json
-- behind this workspace's back, so set_lsp_option is refused, the other
-- process's file stands and the option is not applied.
describe("Workspace:set_lsp_option on a stale working copy", function()
    _G.LOOMWORKS_CLI_NO_AUTORUN = true
    local cli = require("loomworks.cli")
    local Core = require("loomworks.core")
    local FileTracker = require("loomworks.file_tracker")
    local io_mod = require("loomworks.io")
    local user_mod = require("loomworks.user")

    local function capture(fn)
        local rw, rs, rex = io.write, io.stderr, os.exit
        io.write = function() end
        io.stderr = { write = function() end }
        os.exit = function() error({ __exit = true }, 0) end
        local ok, err = pcall(fn)
        io.write, io.stderr, os.exit = rw, rs, rex
        if not ok and not (type(err) == "table" and err.__exit) then error(err, 0) end
    end
    local function stop_cli_tracking()
        local lc = require("loomworks")._core()
        if lc._workspace then lc._workspace:_stop_tracking() end
    end

    it("is refused, never overwrites the other process's file, and leaves the option unset", function()
        local root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root .. "/App", "p")
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
        capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
        stop_cli_tracking()
        local core = Core.new({
            notify = function() end,
            on_save_refused = false,
            FileTracker = { new = function(o) o.interval = 3600 * 1000; return FileTracker.new(o) end },
        })
        core:setup({ root = root })
        assert(vim.wait(15000, function() return core._state ~= "initializing" end, 10))
        local ws = core._workspace
        -- Another process changes the working copy behind this one's back.
        capture(function() cli.cmd_configuration("add", root, "App", "Release", "variant:default") end)
        stop_cli_tracking()
        local theirs = io_mod.read_file(user_mod.filepath(root))
        local events = {}
        local emit = ws._core._deps.events.emit
        ws._core._deps.events.emit = function(ev, ...)
            events[#events + 1] = ev
            return emit(ev, ...)
        end
        local ok, err = ws:set_lsp_option("clangd", "clang_tidy", false)
        ws._core._deps.events.emit = emit
        assert.is_false(ok)
        assert.is_string(err)
        assert.equals(theirs, io_mod.read_file(user_mod.filepath(root)))
        assert.is_true(ws:get_lsp_options("clangd").clang_tidy)
        assert.is_nil(vim.tbl_contains(events, "lsp_options_changed") or nil)
        core:shutdown()
        vim.fn.delete(root, "rf")
    end)
end)
