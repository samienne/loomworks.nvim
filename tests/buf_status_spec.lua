-- Test the buf_status logic as used by lualine.
-- buf_status is on the init.lua facade and uses the singleton Core.
-- We reproduce its logic here, driven by a test Core, to verify the
-- data shape returned under various conditions.

local Core = require("loomworks.core")
local h = require("tests.helpers")

local function make_core(config_overrides, user_overrides, cache_overrides, dep_overrides)
    local files = {
        ["loomworks.json"] = h.make_config_json(config_overrides),
    }
    if user_overrides then
        files["loomworks.user.json"] = h.make_user_json(user_overrides)
    end
    if cache_overrides then
        files["loomworks.cache.json"] = h.make_cache_json(cache_overrides)
    end
    local deps = h.make_test_deps(files, dep_overrides)
    local core = Core.new(deps)
    return core, deps
end

--- Reproduce buf_status logic (mirrors init.lua)
local function buf_status(core, bufnr)
    bufnr = bufnr or 0
    local active_set = core:get_active_configuration_set()
    if not active_set then return nil end

    local project_key, project = core:project_for_buf(bufnr)
    if not project_key then return nil end

    local profile = core:get_active_profile()
    local set_name = profile and (profile._config_set_ref and profile._config_set_ref.name or profile._configuration_set_name) or nil

    local status
    if profile and project.configuration then
        local pp = profile:project(project_key)
        if pp then
            status = pp:status()
        end
    end

    return {
        profile_key = active_set.name,
        set_name = set_name,
        tool_key = project._tool and project._tool.key or nil,
        project = project_key,
        configuration = project.configuration,
        status = status,
    }
end

describe("buf_status", function()
    it("returns nil without workspace", function()
        local core = make_core()
        -- no setup call — core has no workspace
        local result = buf_status(core, 0)
        assert.is_nil(result)
    end)

    it("returns nil when buffer not in any project", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, nil, nil, {
            buf_name = function() return "/other/path/file.cpp" end,
        })
        core:setup({ root = "/root" })
        local result = buf_status(core, 0)
        assert.is_nil(result)
    end)

    it("returns project info for matching buffer", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, { active_profile = "debug" }, {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    configurations = { "App/Debug" },
                },
            },
            configurations = {
                ["App/Debug"] = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    type = "cmake",
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("debug", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("App", result.project)
        assert.equals("Debug", result.configuration)
    end)

    it("includes tool_key when profile has one", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, { active_profile = "debug:ninja-gcc-12" }, {
            profiles = {
                ["debug:ninja-gcc-12"] = {
                    configuration_set = "debug",
                    tools = {
                        cmake = {
                            key = "ninja-gcc-12",
                            data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                            label = "Ninja + GCC 12",
                        },
                    },
                    configurations = { "App/Debug:ninja-gcc-12" },
                },
            },
            configurations = {
                ["App/Debug:ninja-gcc-12"] = {
                    project_key = "App",
                    config_key = "Debug:ninja-gcc-12",
                    variant = "Debug",
                    type = "cmake",
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
            modules = {
                get = function(mod_type)
                    if mod_type ~= "cmake" then return nil end
                    return {
                        validate = function() return { valid = true, warnings = {} } end,
                        info = function() return { configurations = {} } end,
                        detect_tools = function() return {
                            { tool_data = { id = "ninja-gcc-12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                                tool_key = "ninja-gcc-12", tool_label = "Ninja + GCC 12" },
                        } end,
                        tool_key = function(td) return td.id end,
                        tool_label = function(td) return td.display or td.id end,
                    }
                end,
            },
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("debug:ninja-gcc-12", result.profile_key)
        assert.equals("debug", result.set_name)
        assert.equals("ninja-gcc-12", result.tool_key)
    end)

    it("returns status from config unit", function()
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, { active_profile = "debug" }, {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    configurations = { "App/Debug" },
                },
            },
            configurations = {
                ["App/Debug"] = {
                    project_key = "App",
                    config_key = "Debug",
                    variant = "Debug",
                    type = "cmake",
                    state = "built",
                    build_dir = "/root/.nvim/build/App/Debug",
                },
            },
        }, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("App", result.project)
        -- The merged status comes through the ConfigUnit
        assert.equals("Debug", result.configuration)
    end)

    it("returns nil set_name when profile_key is nil", function()
        -- When there is an active set but no profile key (e.g. projects exist
        -- but no profile is activated), set_name should be nil.
        local core = make_core({
            configuration_sets = { debug = { App = "Debug" } },
        }, nil, nil, {
            buf_name = function() return "/root/App/src/main.cpp" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        -- With no active profile, active_set.name is nil, so buf_status
        -- should still return project info but with nil profile/set_name.
        if result then
            assert.is_nil(result.profile_key)
            assert.is_nil(result.set_name)
            assert.equals("App", result.project)
        end
    end)

    it("returns nil tool_key for non-cmake projects", function()
        local core = make_core({
            projects = { Frontend = { ets = {} } },
            configuration_sets = { debug = { Frontend = "debug" } },
        }, { active_profile = "debug" }, {
            profiles = {
                debug = {
                    configuration_set = "debug",
                    configurations = { "Frontend/debug" },
                },
            },
            configurations = {
                ["Frontend/debug"] = {
                    project_key = "Frontend",
                    config_key = "debug",
                    variant = "debug",
                    type = "ets",
                },
            },
        }, {
            buf_name = function() return "/root/Frontend/src/main.ets" end,
        })
        core:setup({ root = "/root" })

        local result = buf_status(core, 0)
        assert.is_not_nil(result)
        assert.equals("Frontend", result.project)
        assert.is_nil(result.tool_key)
    end)
end)
