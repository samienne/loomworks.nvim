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

    local data = workspace.assemble("/root", config_json, user_json, nil)
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
    end)
end)
