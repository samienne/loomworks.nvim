local Project = require("loomworks.project")
local h = require("tests.helpers")

--- Create a Project with mock core and standard data.
--- @param data_overrides? table
--- @param core_overrides? table
--- @param existing_core? table pre-built mock core
--- @return loomworks.Project, table core
local function make_project(data_overrides, core_overrides, existing_core)
    local core = existing_core or h.make_mock_core(core_overrides)
    local data = vim.tbl_deep_extend("force", {
        type = "cmake",
        path = "App",
        configuration = "Debug",
        configuration_key = "Debug",
        status = "unconfigured",
        orphaned = false,
        needs_refresh = false,
        refresh_reasons = {},
        configurations = {
            Debug = { generator = "Ninja" },
            Release = { generator = "Ninja" },
        },
        cached_configurations = {},
    }, data_overrides or {})
    -- Pre-resolve Module and Tool (mirrors _sync_projects behavior)
    if data.type and core.find_module then
        data._module = core:find_module(data.type)
        if data.tool_key and data._module then
            data._tool = data._module:find_tool(data.tool_key)
        end
    end
    return Project.new(core, "App", data), core
end

describe("Project", function()
    describe("new", function()
        it("sets fields from data", function()
            local p = make_project()
            assert.equals("App", p.key)
            assert.equals("cmake", p.type)
            assert.equals("Debug", p.configuration)
            assert.equals("unconfigured", p.status)
            assert.is_false(p.orphaned)
        end)
    end)

    describe("running_action", function()
        it("returns nil when nothing running", function()
            local p = make_project()
            assert.is_nil(p:running_action())
        end)

        it("returns action when a ConfigUnit is running", function()
            local core = h.make_mock_core()
            local p = make_project(nil, nil, core)
            -- Register the project so ConfigUnit._project resolves
            core._projects["App"] = p
            local unit = core:ensure_config_unit(p, h.get_or_create_config(p, "Debug"), nil)
            h.refresh_config_unit(core, unit)
            unit:register_task(1, "build")
            assert.equals("build", p:running_action())
        end)
    end)

    describe("is_deleting_config", function()
        it("returns false by default", function()
            local p = make_project()
            local cfg = p:get_configuration("Debug")
            assert.is_false(p:is_deleting_config(cfg))
        end)

        it("checks via ConfigUnit matching Configuration object", function()
            local ConfigUnit = require("loomworks.config_unit")
            local core = h.make_mock_core()
            local p = make_project({ tool_key = "ninja-gcc" }, nil, core)
            core._projects[#core._projects + 1] = p
            local unit = ConfigUnit.new(core, "App/Debug:ninja-gcc", "App")
            unit:_apply({
                cached = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                },
            })
            core._config_units[#core._config_units + 1] = unit
            h.refresh_config_unit(core, unit)
            unit:mark_deleting(true)
            local cfg = p:get_configuration("Debug")
            assert.is_true(p:is_deleting_config(cfg))
        end)
    end)

    describe("config_running_action", function()
        it("delegates to ConfigUnit matching Configuration object", function()
            local ConfigUnit = require("loomworks.config_unit")
            local core = h.make_mock_core()
            local p = make_project({ tool_key = "ninja-gcc" }, nil, core)
            core._projects[#core._projects + 1] = p
            local unit = ConfigUnit.new(core, "App/Debug:ninja-gcc", "App")
            unit:_apply({
                cached = {
                    project_key = "App", config_key = "Debug:ninja-gcc",
                    type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                },
            })
            core._config_units[#core._config_units + 1] = unit
            h.refresh_config_unit(core, unit)
            unit:register_task(1, "configure")
            local cfg = p:get_configuration("Debug")
            assert.equals("configure", p:config_running_action(cfg))
        end)
    end)

    describe("cached_config", function()
        it("returns nil when no cached configurations", function()
            local p = make_project({ cached_configurations = {} })
            assert.is_nil(p:cached_config("Debug"))
        end)

        it("returns cached config by name", function()
            local p = make_project({
                cached_configurations = {
                    Debug = { state = "built", last_built = "2025-01-01" },
                },
            })
            local cached = p:cached_config("Debug")
            assert.is_not_nil(cached)
            assert.equals("built", cached.state)
        end)

        it("tries kit-qualified key first", function()
            local core = h.make_mock_core()
            core:get_or_create_tool("cmake", "ninja-gcc", {}, nil)
            local p = make_project({
                tool_key = "ninja-gcc",
                cached_configurations = {
                    Debug = { state = "configured" },
                    ["Debug:ninja-gcc"] = { state = "built" },
                },
            }, nil, core)
            local cached = p:cached_config("Debug")
            assert.equals("built", cached.state)
        end)

        it("falls back to bare name when kit-qualified not found", function()
            local core = h.make_mock_core()
            core:get_or_create_tool("cmake", "ninja-gcc", {}, nil)
            local p = make_project({
                tool_key = "ninja-gcc",
                cached_configurations = {
                    Debug = { state = "configured" },
                },
            }, nil, core)
            local cached = p:cached_config("Debug")
            assert.equals("configured", cached.state)
        end)
    end)

    describe("to_module_context", function()
        it("builds module context with correct fields", function()
            local core = h.make_mock_core()
            core:get_or_create_tool("cmake", "ninja-gcc", { generator = "Ninja", env = { CC = "gcc" } }, nil)
            local p = make_project({
                tool_key = "ninja-gcc",
            }, nil, core)
            local ctx = p:to_module_context("/workspace")
            assert.equals("App", ctx.name)
            assert.equals("App", ctx.path)
            assert.equals("cmake", ctx.type)
            assert.equals("Debug", ctx.configuration)
            assert.equals("ninja-gcc", ctx.tool_key)
            assert.equals("/workspace", ctx.workspace_root)
            assert.equals("gcc", ctx.env.CC)
        end)

        it("uses empty env when no tool_data", function()
            local p = make_project({ tool_data = nil })
            local ctx = p:to_module_context("/workspace")
            assert.are.same({}, ctx.env)
        end)
    end)

    describe("abs_path", function()
        it("combines workspace root and project path", function()
            local p = make_project(nil, {
                get_workspace = function()
                    return { root = "/workspace" }
                end,
            })
            assert.equals("/workspace/App", p:abs_path())
        end)

        it("uses default workspace root", function()
            local p = make_project()
            -- default mock workspace has root = "/test"
            assert.equals("/test/App", p:abs_path())
        end)

        it("uses key when no path", function()
            local p = make_project({ path = nil }, {
                get_workspace = function()
                    return { root = "/workspace" }
                end,
            })
            assert.equals("/workspace/App", p:abs_path())
        end)
    end)

end)
