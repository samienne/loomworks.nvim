--- Tests for the structural diagnostics surface.
---
--- Each state-bearing domain object exposes a `:diagnostic()`
--- returning a Diagnostic table or nil. Workspace:diagnostics()
--- aggregates the lot, sorted by (severity, source) for stable
--- output. UI is intentionally not exercised here — the section
--- is a thin renderer.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

--- Fake `harmony`-shaped module: SDK-capable (has kits_from_sdk),
--- so a profile without a tool surfaces as incomplete.
local mock_modules = {
    harmony = {
        has_keyed_tools = false,
        -- kits_from_sdk on the module impl marks it SDK-capable;
        -- a profile without an SDK-derived tool surfaces incomplete.
        kits_from_sdk = function() return {} end,
        info = function()
            local Configuration = require("loomworks.configuration")
            return {
                configurations = Configuration.canonicalize(
                    { default = { prefix = "auto", variant = "default-default" } },
                    nil, "harmony"),
            }
        end,
        default_configurations = function()
            return { default = { prefix = "auto", variant = "default-default" } }
        end,
        map_variant = function() return nil end,
        detect_tools_async = function(callback) callback({}) end,
    },
    typescript = {
        has_keyed_tools = false,
        info = function(_, type_config)
            local Configuration = require("loomworks.configuration")
            return {
                configurations = Configuration.canonicalize(
                    { default = { prefix = "variant", variant = "default" } },
                    type_config and type_config.configurations,
                    "typescript"),
            }
        end,
        default_configurations = function()
            return { default = { prefix = "variant", variant = "default" } }
        end,
        map_variant = function() return nil end,
        detect_tools_async = function(callback) callback({}) end,
    },
}

local function make_ws(config_overrides, user_overrides)
    local config_json = h.make_config_json(config_overrides)
    local user_json = user_overrides and h.make_user_json(user_overrides) or nil
    local data = workspace.assemble("/root", config_json, user_json, nil)
    assert(data, "assemble failed")

    local mock_core = {
        _deps = {
            merge = merge,
            cache = cache_mod,
            events = { emit = function() end },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = function(_, cb) cb(true, nil) end,
            },
            normalize = function(p) return p end,
            modules = { get = function(id) return mock_modules[id] end },
            notify = function() end,
            schedule = function(fn) fn() end,
            log = require("loomworks.log").test(),
        },
    }

    local ws = Workspace.new(mock_core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    -- Suppress vim.notify for stale-mapping warnings so the test
    -- output is clean — they're a separate concern.
    local orig_notify = vim.notify
    vim.notify = function() end
    package.loaded["loomworks.data_model"] = nil
    require("loomworks.data_model")
    ws:remerge(data.config, data.cache, data.user)
    vim.notify = orig_notify
    return ws, mock_core
end

describe("Workspace:diagnostics", function()
    it("returns empty list when everything is healthy", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        assert.are.same({}, ws:diagnostics())
    end)

    it("flags incomplete profiles (SDK-capable module without tool)", function()
        local ws = make_ws({
            projects = { App = { harmony = {} } },
            configuration_sets = {
                Debug = { App = "auto:default-default" },
            },
            profiles = {
                ["Debug:noop"] = { configuration_set = "Debug" },
            },
        })
        local diags = ws:diagnostics()
        local found_profile = false
        for _, d in ipairs(diags) do
            if d.source:find("Profile/", 1, true) then
                found_profile = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("incomplete", 1, true))
                assert.is_truthy(d.message:find("App", 1, true))
                assert.is_truthy(d.target_fold_key:find("profile:", 1, true))
            end
        end
        assert.is_true(found_profile,
            "expected an incomplete-profile diagnostic")
    end)

    it("flags configurations with stale (source-missing) references", function()
        -- Configuration_set maps to a variant the project doesn't
        -- emit — sync_config_sets creates a `_source_missing` stub,
        -- which `Configuration:diagnostic()` then surfaces.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source:find("Project/App/ghost-config", 1, true) then
                found = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("not defined", 1, true)
                    or d.message:find("referenced", 1, true))
                -- target_fold_key should point at the referrer
                -- (the config_set that has the stale mapping).
                assert.is_truthy(d.target_fold_key:find("set:Debug", 1, true))
            end
        end
        assert.is_true(found,
            "expected a source-missing diagnostic for the ghost config")
    end)

    it("flags configuration sets with stale mappings (set-side view)", function()
        -- Same condition as above, viewed from the set's perspective.
        -- Both diagnostics fire — they answer different questions
        -- (project-side: 'this config is missing'; set-side:
        -- 'this set has broken refs').
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "ghost-config" },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source == "ConfigurationSet/Debug" then
                found = true
                assert.equals("warn", d.severity)
                assert.is_truthy(d.message:find("stale mappings", 1, true))
                assert.equals("set:Debug", d.target_fold_key)
            end
        end
        assert.is_true(found,
            "expected a stale-mapping diagnostic for the set")
    end)

    it("flags unresolved inherits", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["my-debug"] = { inherits = "no-such-base" },
                        },
                    },
                },
            },
        })
        local diags = ws:diagnostics()
        local found = false
        for _, d in ipairs(diags) do
            if d.source == "Project/App/my-debug" then
                found = true
                assert.is_truthy(d.message:find("inherits from unknown bases", 1, true))
                assert.is_truthy(d.message:find("no-such-base", 1, true))
                assert.equals("config:App:my-debug", d.target_fold_key)
            end
        end
        assert.is_true(found,
            "expected an unresolved-inherits diagnostic")
    end)

    it("sorts by (severity, source) for stable output", function()
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["zlast"] = { inherits = "no-such" },
                            ["aearly"] = { inherits = "no-such" },
                        },
                    },
                },
            },
        })
        local diags = ws:diagnostics()
        for i = 2, #diags do
            -- Within same severity, source is alphabetical.
            if diags[i - 1].severity == diags[i].severity then
                assert.is_true(diags[i - 1].source <= diags[i].source,
                    "diagnostics not sorted: " .. diags[i - 1].source
                    .. " before " .. diags[i].source)
            end
        end
    end)

    it("returns empty when configurations have no issues", function()
        local ws = make_ws({
            projects = { App = { typescript = {} } },
            configuration_sets = {
                Debug = { App = "variant:default" },
            },
        })
        assert.are.same({}, ws:diagnostics())
    end)
end)
