local merge = require("loomworks.merge")
local workspace = require("loomworks.workspace")
local h = require("tests.helpers")

--- Assemble a workspace from helper-generated JSON.
--- Uses typescript projects by default to avoid cmake kit detection.
--- @param config_overrides? table
--- @param user_overrides? table
--- @param cache_overrides? table
--- @return loomworks.Workspace
local function make_ws(config_overrides, user_overrides, cache_overrides)
    -- Default to typescript to avoid cmake kit detection in profile generation
    local defaults = {
        projects = { App = { typescript = {} } },
    }
    local merged = config_overrides
            and vim.tbl_deep_extend("force", defaults, config_overrides)
            or defaults
    -- Replace projects entirely if provided in overrides (avoid type key merging)
    if config_overrides and config_overrides.projects then
        merged.projects = config_overrides.projects
    end

    local ws, err = workspace.assemble(
        "/root",
        h.make_config_json(merged),
        user_overrides and h.make_user_json(user_overrides) or nil,
        cache_overrides and h.make_cache_json(cache_overrides) or nil
    )
    assert(ws, err)
    return ws
end

describe("merge", function()
    describe("profile_key", function()
        it("returns set_name when no tool_key", function()
            assert.equals("debug", merge.profile_key("debug", nil))
        end)

        it("combines set_name and tool key from tools dict", function()
            assert.equals("debug:ninja-gcc", merge.profile_key("debug", { cmake = { key = "ninja-gcc" } }))
        end)

        it("sorts multi-tool keys by module type", function()
            assert.equals("debug:ninja-gcc+meson-ninja", merge.profile_key("debug", {
                meson = { key = "meson-ninja" },
                cmake = { key = "ninja-gcc" },
            }))
        end)
    end)

    -- parse_profile_key was removed (zero runtime callers)

    describe("get_all_profiles", function()
        it("returns empty when no pinned or explicit profiles", function()
            local ws = make_ws()
            local profiles = merge.get_all_profiles(ws.config, ws.cache, {})
            assert.are.same({}, profiles)
        end)

        it("includes pinned profiles from user_data", function()
            local ws = make_ws({
                configuration_sets = { debug = { App = "development" } },
            })
            local user_data = {
                _meta = { version = 2 },
                profiles = {
                    ["App/development"] = { mappings = { App = "development" } },
                },
            }
            local profiles = merge.get_all_profiles(ws.config, ws.cache, {}, user_data)
            assert.is_not_nil(profiles["App/development"])
            assert.is_true(profiles["App/development"]._pinned)
        end)

        it("explicit profiles from config", function()
            local ws = make_ws({
                configuration_sets = { debug = { App = "development" } },
                profiles = {
                    debug = { configuration_set = "debug", kit_id = "custom" },
                },
            })
            local profiles = merge.get_all_profiles(ws.config, ws.cache, {})
            assert.is_true(profiles.debug.explicit)
            assert.equals("debug", profiles.debug.configuration_set)
        end)
    end)

    describe("merge", function()
        it("produces an ActiveSet with projects", function()
            local ws = make_ws({
                configuration_sets = { debug = { App = "development" } },
            })
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.is_not_nil(result)
            assert.is_not_nil(result.projects)
            assert.is_not_nil(result.projects.App)
        end)

        it("sets project type from config", function()
            local ws = make_ws()
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.equals("typescript", result.projects.App.type)
        end)

        it("sets status to unconfigured when no cache", function()
            local ws = make_ws(
                { configuration_sets = { debug = { App = "development" } } },
                { active_profile = "debug" },
                {
                    profiles = {
                        debug = {
                            configuration_set = "debug",
                            configurations = { "App/development" },
                        },
                    },
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            type = "typescript",
                        },
                    },
                }
            )
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.equals("unconfigured", result.projects.App.status)
        end)

        it("reads status from cache", function()
            local ws = make_ws(
                { configuration_sets = { debug = { App = "development" } } },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root",
                nil, ws.user)
            assert.equals("built", result.projects.App.status)
        end)

        it("resolves active profile from user preferences", function()
            local ws = make_ws(
                { configuration_sets = { debug = { App = "development" } } },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            type = "typescript",
                        },
                    },
                }
            )
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root",
                nil, ws.user)
            assert.equals("debug", result.name)
        end)

        it("has nil name when no active profile", function()
            local ws = make_ws({
                configuration_sets = { debug = { App = "development" } },
            })
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.is_nil(result.name)
        end)

        it("resolves configuration from active set", function()
            local ws = make_ws(
                { configuration_sets = { debug = { App = "development" } } },
                {
                    active_profile = "debug",
                    profiles = {
                        debug = { configuration_set = "debug" },
                    },
                },
                {
                    configurations = {
                        ["App/development"] = {
                            project_key = "App",
                            config_key = "development",
                            type = "typescript",
                        },
                    },
                }
            )
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root",
                nil, ws.user)
            assert.equals("development", result.projects.App.configuration)
        end)

        it("detects orphaned projects", function()
            local ws = make_ws(
                nil,
                nil,
                {
                    configurations = {
                        ["OldProject/development"] = {
                            project_key = "OldProject",
                            config_key = "development",
                            type = "typescript",
                            state = "built",
                        },
                    },
                }
            )
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.is_not_nil(result.projects.OldProject)
            assert.is_true(result.projects.OldProject.orphaned)
        end)

        it("marks existing projects as not orphaned", function()
            local ws = make_ws()
            local result = merge.merge(ws.config, ws.user and ws.user.active_profile, ws.cache, "/root")
            assert.is_false(result.projects.App.orphaned)
        end)
    end)
end)
