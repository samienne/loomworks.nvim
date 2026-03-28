local h = require("tests.helpers")
local Configuration = require("loomworks.configuration")
local Project = require("loomworks.project")

describe("Configuration", function()
    local function make_project(ws_overrides, project_data)
        local ws = h.make_mock_workspace(ws_overrides or {})
        local data = vim.tbl_deep_extend("force", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {
                Debug = { variant = "Debug", is_default = true },
                Release = { variant = "Release", is_default = true },
            },
            cached_configurations = {},
        }, project_data or {})
        local project = Project.new(ws, "App", data)
        return project, ws
    end

    describe("new", function()
        it("creates with basic fields", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug", {
                variant = "Debug",
                is_default = true,
            })
            assert.equals("Debug", cfg.name)
            assert.equals("Debug", cfg.module_config.variant)
            assert.is_true(cfg.is_default)
            assert.is_false(cfg.is_user)
            assert.is_false(cfg.from_preset)
            assert.is_false(cfg._removed)
            assert.is_true(rawequal(project, cfg._project))
        end)

        it("separates generic from module-specific fields", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug-asan", {
                variant = "Debug",
                inherits = "Debug",
                options = { ASAN = "ON" },
                toolchain = "/path/to/tc.cmake",
                generator = "Ninja",
                is_user = true,
            })
            assert.equals("Debug", cfg.module_config.variant)
            assert.same({ "Debug" }, cfg.inherits_names)
            assert.same({ ASAN = "ON" }, cfg.options)
            assert.equals("/path/to/tc.cmake", cfg.module_config.toolchain)
            assert.equals("Ninja", cfg.module_config.generator)
            assert.is_true(cfg.is_user)
        end)

        it("handles array inherits", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Mixed", {
                inherits = { "Debug", "Release" },
            })
            assert.same({ "Debug", "Release" }, cfg.inherits_names)
        end)

        it("handles nil inherits", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug", {
                variant = "Debug",
            })
            assert.same({}, cfg.inherits_names)
        end)
    end)

    describe("is_abstract", function()
        it("returns true when no variant", function()
            local project = make_project()
            local cfg = Configuration.new(project, "mixin", {})
            assert.is_true(cfg:is_abstract())
        end)

        it("returns false when variant present", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug", { variant = "Debug" })
            assert.is_false(cfg:is_abstract())
        end)
    end)

    describe("_update", function()
        it("updates in place preserving identity", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug", { variant = "Debug" })
            local identity = cfg
            cfg:_update({ variant = "Release", is_default = true, generator = "Ninja" })
            assert.is_true(rawequal(identity, cfg))
            assert.equals("Release", cfg.module_config.variant)
            assert.equals("Ninja", cfg.module_config.generator)
        end)
    end)

    describe("_resolve_inherits", function()
        it("resolves references to other configurations", function()
            local project = make_project(nil, {
                configurations = {
                    Debug = { variant = "Debug", is_default = true },
                    ["Debug-asan"] = { variant = "Debug", inherits = "Debug", is_user = true },
                },
            })
            local debug_cfg = project:get_configuration("Debug")
            local asan_cfg = project:get_configuration("Debug-asan")
            assert.is_not_nil(debug_cfg)
            assert.is_not_nil(asan_cfg)
            assert.equals(1, #asan_cfg._inherits)
            assert.is_true(rawequal(debug_cfg, asan_cfg._inherits[1]))
        end)

        it("handles missing base gracefully", function()
            local project = make_project(nil, {
                configurations = {
                    Custom = { inherits = "NonExistent" },
                },
            })
            local cfg = project:get_configuration("Custom")
            assert.is_not_nil(cfg)
            assert.equals(0, #cfg._inherits)
        end)
    end)

    describe("__tostring", function()
        it("shows project and name", function()
            local project = make_project()
            local cfg = Configuration.new(project, "Debug", {})
            assert.equals("Configuration(App/Debug)", tostring(cfg))
        end)
    end)

    describe("__eq", function()
        it("equal when same project and name", function()
            local project = make_project()
            local a = Configuration.new(project, "Debug", { variant = "Debug" })
            local b = Configuration.new(project, "Debug", { variant = "Release" })
            assert.is_true(a == b)
        end)

        it("not equal when different name", function()
            local project = make_project()
            local a = Configuration.new(project, "Debug", {})
            local b = Configuration.new(project, "Release", {})
            assert.is_false(a == b)
        end)
    end)
end)

describe("Project _configurations", function()
    local function make_project(configurations, preset_configurations)
        local ws = h.make_mock_workspace()
        local data = {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = configurations or {},
            preset_configurations = preset_configurations,
            cached_configurations = {},
        }
        local project = Project.new(ws, "App", data)
        return project, ws
    end

    it("creates Configuration objects from configurations dict", function()
        local project = make_project({
            Debug = { variant = "Debug", is_default = true },
            Release = { variant = "Release", is_default = true },
        })
        assert.is_not_nil(project:get_configuration("Debug"))
        assert.is_not_nil(project:get_configuration("Release"))
        assert.equals("Debug", project:get_configuration("Debug").module_config.variant)
        assert.equals("Release", project:get_configuration("Release").module_config.variant)
    end)

    it("get_configuration returns by name", function()
        local project = make_project({
            Debug = { variant = "Debug", is_default = true },
        })
        local cfg = project:get_configuration("Debug")
        assert.is_not_nil(cfg)
        assert.equals("Debug", cfg.name)
    end)

    it("get_configuration returns nil for missing", function()
        local project = make_project({})
        assert.is_nil(project:get_configuration("NonExistent"))
    end)

    it("includes preset configurations", function()
        local project = make_project(
            { Debug = { variant = "Debug", is_default = true } },
            { mypreset = { from_preset = true, generator = "Ninja" } }
        )
        assert.is_not_nil(project:get_configuration("Debug"))
        assert.is_not_nil(project:get_configuration("mypreset"))
        assert.is_true(project:get_configuration("mypreset").from_preset)
    end)

    it("preserves identity across updates", function()
        local project = make_project({
            Debug = { variant = "Debug", is_default = true },
        })
        local cfg = project:get_configuration("Debug")
        -- Re-update with same configurations
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true, generator = "Ninja" } },
            cached_configurations = {},
        })
        local cfg2 = project:get_configuration("Debug")
        assert.is_true(rawequal(cfg, cfg2))
        assert.equals("Ninja", cfg2.module_config.generator)
    end)

    it("removes configurations no longer present", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {
                Debug = { variant = "Debug" },
                Release = { variant = "Release" },
            },
            cached_configurations = {},
        })
        assert.is_not_nil(project:get_configuration("Release"))

        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
        })
        assert.is_nil(project:get_configuration("Release"))
    end)

    -- Cache-sourced Configuration enrichment (Phase 1)

    it("enriches from cache: creates Configuration with _source_missing for cache-only variant", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg = project:get_configuration("Release")
        assert.is_not_nil(cfg)
        assert.equals("Release", cfg.name)
        assert.is_true(cfg._source_missing)
    end)

    it("module-sourced configuration has _source_missing = false", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        local cfg = project:get_configuration("Debug")
        assert.is_not_nil(cfg)
        assert.is_false(cfg._source_missing)
    end)

    it("_source_missing clears when source reappears on re-update", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {},
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg = project:get_configuration("Release")
        assert.is_true(cfg._source_missing)

        -- Source reappears on re-update
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Release = { variant = "Release", is_default = true } },
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg2 = project:get_configuration("Release")
        assert.is_false(cfg2._source_missing)
    end)

    it("preserves identity for cache-sourced Configuration across remerge", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {},
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg = project:get_configuration("Release")
        assert.is_not_nil(cfg)

        -- Re-update with same cache — identity must be preserved
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {},
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg2 = project:get_configuration("Release")
        assert.is_true(rawequal(cfg, cfg2))
    end)

    it("removes Configuration absent from both module output and cache", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        assert.is_not_nil(project:get_configuration("Release"))

        -- Remove from cache — now absent from both sources
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
        })
        assert.is_nil(project:get_configuration("Release"))
    end)

    it("ConfigUnit._configuration resolves for cache-only variant", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Release"] = {
                        project_key = "App",
                        config_key = "Release",
                        type = "cmake",
                        variant = "Release",
                    },
                },
            },
        })
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {},
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        ws._projects["App"] = project

        local unit = h.ensure_config_unit_by_id(ws, "App/Release", "App")
        assert.is_not_nil(unit._configuration)
        assert.equals("Release", unit._configuration.name)
        assert.is_true(unit._configuration._source_missing)
    end)

    it("retains cache-enriched Configuration when module source is removed", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {
                Debug = { variant = "Debug" },
                Release = { variant = "Release" },
            },
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        assert.is_false(project:get_configuration("Release")._source_missing)

        -- Module source removed, but cache still references Release
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {
                Release = { variant = "Release", build_dir = "/build/Release" },
            },
        })
        local cfg = project:get_configuration("Release")
        assert.is_not_nil(cfg)
        assert.is_true(cfg._source_missing)
    end)
end)

describe("ConfigUnit _configuration resolution", function()
    it("resolves _configuration from project registry", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App",
                        config_key = "Debug",
                        type = "cmake",
                        variant = "Debug",
                    },
                },
            },
        })
        -- Create a project with Debug configuration
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project

        local unit = h.ensure_config_unit_by_id(ws, "App/Debug", "App")
        assert.is_not_nil(unit._configuration)
        assert.equals("Debug", unit._configuration.name)
        assert.equals("Debug", unit._configuration.module_config.variant)
    end)

    it("_configuration is nil when variant not in project configs", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/OldConfig"] = {
                        project_key = "App",
                        config_key = "OldConfig",
                        type = "cmake",
                        variant = "OldConfig",
                    },
                },
            },
        })
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
        })
        ws._projects["App"] = project

        local unit = h.ensure_config_unit_by_id(ws, "App/OldConfig", "App")
        assert.is_nil(unit._configuration)
    end)
end)

describe("ProfileProject accessor methods", function()
    local ProfileProject = require("loomworks.profile").ProfileProject
    local Profile = require("loomworks.profile").Profile

    it("configuration() returns Configuration from project registry", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project

        local profile = Profile.new(ws, "debug", {
            mappings = { App = "Debug" },
        })
        local pp = ProfileProject.new(ws, "App", {
            profile = profile,
            project = project,
            configuration = project:get_configuration("Debug"),
        })

        local cfg = pp:configuration()
        assert.is_not_nil(cfg)
        assert.equals("Debug", cfg.name)
        assert.equals("Debug", cfg.module_config.variant)
    end)

    it("configuration() returns nil when variant not found", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
        })
        ws._projects["App"] = project

        local profile = Profile.new(ws, "debug", {
            mappings = { App = "Release" },
        })
        local pp = ProfileProject.new(ws, "App", {
            profile = profile,
            project = project,
            configuration = project:get_configuration("Release"),
        })

        assert.is_nil(pp:configuration())
    end)

    it("tool_object() returns Tool from profile", function()
        local ws = h.make_mock_workspace()
        local tool = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")
        local cmake_mod = ws:find_module("cmake")
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
            _module = cmake_mod,
        })
        ws._projects["App"] = project

        local profile = Profile.new(ws, "debug:ninja-gcc", {
            tools = { cmake = { key = "ninja-gcc", data = { gen = "Ninja" }, label = "label" } },
            _tool_objects = { [cmake_mod] = tool },
            mappings = { App = "Debug" },
        })
        local pp = ProfileProject.new(ws, "App", {
            profile = profile,
            project = project,
            configuration = project:get_configuration("Debug"),
        })

        local t = pp:tool_object()
        assert.is_not_nil(t)
        assert.is_true(rawequal(tool, t))
    end)

    it("tool_object() returns nil when no tools on profile", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = {}, cached_configurations = {},
        })
        ws._projects["App"] = project

        local profile = Profile.new(ws, "debug", {
            mappings = { App = "Debug" },
        })
        local pp = ProfileProject.new(ws, "App", {
            profile = profile,
            project = project,
        })

        assert.is_nil(pp:tool_object())
    end)
end)

describe("ConfigurationSet mappings store Configuration objects", function()
    local ConfigurationSet = require("loomworks.configuration_set")

    it("stores Configuration objects directly in mappings", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project
        local debug_cfg = project:get_configuration("Debug")

        local cs = ConfigurationSet.new(ws, "debug", { [project] = debug_cfg })
        assert.is_not_nil(cs.mappings[project])
        assert.equals("Debug", cs.mappings[project].name)
    end)

    it("configuration() returns Configuration for project", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project
        local debug_cfg = project:get_configuration("Debug")

        local cs = ConfigurationSet.new(ws, "debug", { [project] = debug_cfg })
        local cfg = cs:configuration(project)
        assert.is_not_nil(cfg)
        assert.equals("Debug", cfg.name)
    end)

    it("configuration() returns nil for unmapped project", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = {},
            cached_configurations = {},
        })
        ws._projects["App"] = project

        local cs = ConfigurationSet.new(ws, "debug", {})
        assert.is_nil(cs:configuration(project))
    end)
end)
