--- Palette tests — verify build_entries against a real workspace.
---
--- We don't go through vim.ui.select; the palette module exposes
--- `build_entries()` so the contents are testable without UI.

local workspace = require("loomworks.workspace")
local merge     = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h         = require("tests.helpers")
local Configuration = require("loomworks.configuration")
local Workspace = workspace.Workspace

local mock_modules = {
    cmake = {
        id = "cmake",
        has_keyed_tools = true,
        has_options = true,
        tools_match = function(a, b)
            if a == nil and b == nil then return true end
            if a == nil or b == nil then return false end
            return vim.deep_equal(a, b)
        end,
        default_configurations = function()
            return {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
            }
        end,
        map_variant = function(v, configs)
            for _, n in ipairs(configs) do if n:lower() == v then return n end end
        end,
        tool_key = function(td) return td.id end,
        tool_label = function(td) return td.display end,
        detect_tools_async = function(cb) cb({}) end,
        info = function(_, config)
            local d = {
                Debug = { prefix = "variant", variant = "Debug" },
                Release = { prefix = "variant", variant = "Release" },
            }
            return { configurations = Configuration.canonicalize(d, config and config.configurations, "cmake") }
        end,
    },
}

local function make_ws(config_overrides, user_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local data = workspace.assemble("/root", config_json, user_json, nil)
    local mock_core = {
        _deps = {
            merge = merge, cache = cache_mod,
            events = { emit = function() end },
            user = { save = function() return true end },
            io = { write_json = function() return true end, ensure_dir = function() return true end,
                   rm_rf_async = function(_, cb) cb(true, nil) end },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            clock = function() return 0 end,
            now = function() return "2000-01-01T00:00:00Z" end,
            log = require("loomworks.log").test(),
        },
    }
    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws
end

--- Patch `loomworks.get_workspace` for the duration of a test.
local function with_workspace(ws, fn)
    local lw = require("loomworks")
    local original = lw.get_workspace
    lw.get_workspace = function() return ws end
    local ok, err = pcall(fn)
    lw.get_workspace = original
    if not ok then error(err) end
end

describe("ui v2 palette — build_entries", function()
    local palette = require("loomworks.ui.v2.palette")

    it("includes Open UI, Rescan tools, and Add project always", function()
        local ws = make_ws({ projects = { App = { cmake = {} } } })
        with_workspace(ws, function()
            local entries = palette.build_entries()
            local labels = {}
            for _, e in ipairs(entries) do labels[e.label] = true end
            assert.is_true(labels["Open loomworks v2 UI"])
            assert.is_true(labels["Rescan tools"])
            assert.is_true(labels["Add project"])
            assert.is_true(labels["Add configuration set"])
        end)
    end)

    it("emits Build/Configure entries for the active profile", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        with_workspace(ws, function()
            local entries = palette.build_entries()
            local labels = {}
            for _, e in ipairs(entries) do labels[e.label] = true end
            assert.is_true(labels["Build active profile (Debug)"])
            assert.is_true(labels["Configure active profile (Debug)"])
        end)
    end)

    it("emits Activate entries for non-active profiles", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug   = { App = "variant:Debug" },
                    Release = { App = "variant:Release" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug   = { configuration_set = "Debug" },
                    Release = { configuration_set = "Release" },
                },
            }
        )
        with_workspace(ws, function()
            local entries = palette.build_entries()
            local found_release = false
            local found_debug = false
            for _, e in ipairs(entries) do
                if e.label == "Activate profile: Release" then found_release = true end
                if e.label == "Activate profile: Debug" then found_debug = true end
            end
            assert.is_true(found_release)
            assert.is_false(found_debug, "active profile should not appear in Activate list")
        end)
    end)

    it("emits Inspect entries for projects, profiles, and configuration sets", function()
        local ws = make_ws(
            {
                projects = {
                    App   = { cmake = {} },
                    Other = { cmake = {} },
                },
                configuration_sets = { Debug = { App = "variant:Debug" } },
            },
            {
                active_profile = "Debug",
                profiles = { Debug = { configuration_set = "Debug" } },
            }
        )
        with_workspace(ws, function()
            local entries = palette.build_entries()
            local labels = {}
            for _, e in ipairs(entries) do labels[e.label] = true end
            assert.is_true(labels["Inspect project: App"])
            assert.is_true(labels["Inspect project: Other"])
            assert.is_true(labels["Inspect profile: Debug"])
            assert.is_true(labels["Inspect configuration set: Debug"])
        end)
    end)

    it("Activate entry's run callback activates the chosen profile", function()
        local ws = make_ws(
            {
                projects = { App = { cmake = {} } },
                configuration_sets = {
                    Debug   = { App = "variant:Debug" },
                    Release = { App = "variant:Release" },
                },
            },
            {
                active_profile = "Debug",
                profiles = {
                    Debug   = { configuration_set = "Debug" },
                    Release = { configuration_set = "Release" },
                },
            }
        )
        with_workspace(ws, function()
            local entries = palette.build_entries()
            local activate_release
            for _, e in ipairs(entries) do
                if e.label == "Activate profile: Release" then activate_release = e end
            end
            assert.is_not_nil(activate_release)
            activate_release.run()
            assert.equals("Release", ws._active_profile.key)
        end)
    end)

    it("returns workspace-independent entries when no workspace is loaded", function()
        with_workspace(nil, function()
            local entries = require("loomworks.ui.v2.palette").build_entries()
            local labels = {}
            for _, e in ipairs(entries) do labels[e.label] = true end
            assert.is_true(labels["Open loomworks v2 UI"])
            assert.is_true(labels["Rescan tools"])
            -- No Build / Activate / Inspect when no workspace
            assert.is_nil(labels["Add project"])
        end)
    end)
end)
