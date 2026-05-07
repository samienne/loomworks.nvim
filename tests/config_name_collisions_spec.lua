--- Tests for the configuration name-collision fixes:
---
--- 1. _serialize_user filters auto-gens (same as _serialize_project_shared).
--- 2. compute_edit_configuration_context uses the Configuration's
---    is_default flag, not a raw bare-name lookup against
---    default_configurations() (which used to flag a user-created
---    config named "default" as a default).
--- 3. data_model.sync_config_sets warns once per stale mapping
---    (configuration_set references a variant that doesn't exist
---    on the project).

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local h = require("tests.helpers")

local Workspace = workspace.Workspace

local mock_modules = {
    typescript = {
        has_keyed_tools = false,
        has_options = false,
        default_configurations = function(_, _)
            return { default = { prefix = "variant", variant = "default" } }
        end,
        info = function(path, type_config)
            local Configuration = require("loomworks.configuration")
            local auto = { default = { prefix = "variant", variant = "default" } }
            return {
                configurations = Configuration.canonicalize(
                    auto, type_config and type_config.configurations, "typescript"),
            }
        end,
        map_variant = function() return nil end,
        detect_tools_async = function(callback) callback({}) end,
    },
}

--- Look up a project by key. Workspace doesn't expose a find helper,
--- but the registry is just an array.
local function find_project(ws, key)
    for _, p in ipairs(ws._projects) do
        if p.key == key then return p end
    end
    return nil
end

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
    ws:remerge(data.config, data.cache, data.user)
    return ws, mock_core
end

describe("Issue 1: _serialize_user filters auto-gens", function()
    it("does not write variant:default to user.json", function()
        -- Mark the project user-owned (mirrors UI cascade); without
        -- that, _serialize_user skips the project entirely (it stays
        -- "shared" since only loomworks.json has it). The point of
        -- the test is the auto-gen filter, not the materialisation
        -- gate — so we materialise the project explicitly and then
        -- assert no auto-gen leaks.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        local app = find_project(ws, "App")
        app:_mark_user_owned()

        local user_data = ws:_serialize_user()
        local cfgs = user_data.projects
            and user_data.projects.App
            and user_data.projects.App.typescript
            and user_data.projects.App.typescript.configurations or {}
        assert.is_nil(cfgs["variant:default"],
            "auto-gen variant:default leaked into user.json")
    end)

    it("does write user-named configs to user.json", function()
        -- A genuine user override SHOULD persist. The filter targets
        -- only auto-gens (is_auto_gen() == true).
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["my-debug"] = { inherits = "variant:default" },
                        },
                    },
                },
            },
        })
        -- Trigger materialisation: mark project + config as
        -- user-owned. Mirrors what UI mutations do via
        -- _mark_user_owned cascade.
        local app = find_project(ws, "App")
        app:_mark_user_owned()
        local cfg = app:get_configuration("my-debug")
        assert.is_not_nil(cfg)
        cfg:_mark_user_owned()

        local user_data = ws:_serialize_user()
        local cfgs = user_data.projects
            and user_data.projects.App
            and user_data.projects.App.typescript
            and user_data.projects.App.typescript.configurations or {}
        assert.is_not_nil(cfgs["my-debug"],
            "user override stripped — filter is too aggressive")
        -- Auto-gen still filtered out:
        assert.is_nil(cfgs["variant:default"],
            "auto-gen leaked through alongside user override")
    end)
end)

describe("Issue 3: edit dialog uses Configuration.is_default flag", function()
    local workspace_view = require("loomworks.workspace_view")

    it("user-created config named 'default' is NOT flagged as is_default", function()
        -- Regression: the bare-name `defaults["default"]` lookup
        -- in compute_edit_configuration_context flagged a user
        -- config named "default" as a default config — name became
        -- read-only, inherits picker hidden, dialog effectively
        -- empty. After the fix, is_default reflects the
        -- Configuration's own is_default flag, which canonicalize
        -- sets only on auto-gens.
        local ws = make_ws({
            projects = {
                App = {
                    typescript = {
                        configurations = {
                            ["default"] = { inherits = "variant:default" },
                        },
                    },
                },
            },
        })
        local project = find_project(ws, "App")
        local ctx = workspace_view.compute_edit_configuration_context(project, "default")
        assert.is_false(ctx.is_default,
            "user config 'default' incorrectly flagged is_default — "
            .. "edit dialog will lock its name and hide editable fields")
    end)

    it("auto-gen 'variant:default' IS flagged as is_default", function()
        -- Counter-test: actual auto-gens still get is_default=true,
        -- so the dialog correctly locks their name and treats them
        -- as read-only.
        local ws = make_ws({
            projects = { App = { typescript = {} } },
        })
        local project = find_project(ws, "App")
        local ctx = workspace_view.compute_edit_configuration_context(project, "variant:default")
        assert.is_true(ctx.is_default,
            "auto-gen variant:default should be flagged is_default")
    end)
end)

--- Run a function with vim.notify replaced by a capturing stub.
--- Also clears the data_model module's stale-mapping dedup table so
--- each test sees a fresh report (otherwise sequential tests with
--- the same mapping share state).
local function with_captured_notify(fn)
    local notifications = {}
    local orig = vim.notify
    vim.notify = function(msg, level)
        notifications[#notifications + 1] = { msg = msg, level = level }
    end
    package.loaded["loomworks.data_model"] = nil
    require("loomworks.data_model")
    local ok, err = pcall(fn, notifications)
    vim.notify = orig
    if not ok then error(err) end
end

describe("Issue 2a: stale configuration_set mapping warns", function()
    it("warns when configuration_set references unknown variant", function()
        with_captured_notify(function(notifications)
            make_ws({
                projects = { App = { typescript = {} } },
                configuration_sets = {
                    Debug = { App = "nonexistent-variant" },
                },
            })
            local found = false
            for _, n in ipairs(notifications) do
                if n.msg:find("unknown configuration", 1, true)
                    and n.msg:find("nonexistent-variant", 1, true)
                    and n.msg:find("App", 1, true)
                    and n.msg:find("Debug", 1, true)
                    and n.level == vim.log.levels.WARN then
                    found = true
                    break
                end
            end
            assert.is_true(found,
                "expected a WARN notify naming the set, project, and bad variant")
        end)
    end)

    it("does not warn when mapping resolves to an existing config", function()
        with_captured_notify(function(notifications)
            make_ws({
                projects = { App = { typescript = {} } },
                configuration_sets = {
                    Debug = { App = "variant:default" },
                },
            })
            for _, n in ipairs(notifications) do
                assert.is_nil(n.msg:find("unknown configuration", 1, true),
                    "no warning expected for valid mapping; got: " .. n.msg)
            end
        end)
    end)

    it("warns once per stale mapping across remerges (dedup)", function()
        with_captured_notify(function(notifications)
            local ws = make_ws({
                projects = { App = { typescript = {} } },
                configuration_sets = {
                    Debug = { App = "ghost" },
                },
            })
            -- Trigger a second merge with the same stale mapping.
            ws:remerge()

            local count = 0
            for _, n in ipairs(notifications) do
                if n.msg:find("ghost", 1, true) then count = count + 1 end
            end
            assert.equals(1, count,
                "expected exactly one warning; remerge should not re-notify")
        end)
    end)
end)
