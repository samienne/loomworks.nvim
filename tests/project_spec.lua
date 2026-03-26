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
            unit:_update()
            unit:register_task(1, "build")
            assert.equals("build", p:running_action())
        end)
    end)

    describe("is_deleting_config", function()
        it("returns false by default", function()
            local p = make_project()
            assert.is_false(p:is_deleting_config("Debug"))
        end)

        it("checks via ConfigUnit with computed cache key", function()
            local ConfigUnit = require("loomworks.config_unit")
            local core = h.make_mock_core({
                cache = {
                    configurations = {
                        ["App/Debug:ninja-gcc"] = {
                            project_key = "App", config_key = "Debug:ninja-gcc",
                            type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                        },
                    },
                },
            })
            local p = make_project({ tool_key = "ninja-gcc" }, nil, core)
            core._projects["App"] = p
            local unit = core._config_units["App/Debug:ninja-gcc"]
                or ConfigUnit.new(core, "App/Debug:ninja-gcc", "App")
            core._config_units["App/Debug:ninja-gcc"] = unit
            unit:_update()
            unit:mark_deleting(true)
            assert.is_true(p:is_deleting_config("Debug"))
        end)
    end)

    describe("config_running_action", function()
        it("delegates to ConfigUnit with computed cache key", function()
            local ConfigUnit = require("loomworks.config_unit")
            local core = h.make_mock_core({
                cache = {
                    configurations = {
                        ["App/Debug:ninja-gcc"] = {
                            project_key = "App", config_key = "Debug:ninja-gcc",
                            type = "cmake", variant = "Debug", tool_key = "ninja-gcc",
                        },
                    },
                },
            })
            local p = make_project({ tool_key = "ninja-gcc" }, nil, core)
            core._projects["App"] = p
            local unit = core._config_units["App/Debug:ninja-gcc"]
                or ConfigUnit.new(core, "App/Debug:ninja-gcc", "App")
            core._config_units["App/Debug:ninja-gcc"] = unit
            unit:_update()
            unit:register_task(1, "configure")
            assert.equals("configure", p:config_running_action("Debug"))
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
