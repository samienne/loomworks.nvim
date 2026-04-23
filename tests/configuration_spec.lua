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

    describe("canonical / split_canonical", function()
        it("joins prefix+base with `:`", function()
            assert.equals("variant:Debug", Configuration.canonical("variant", "Debug"))
            assert.equals("preset:debug-custom",
                Configuration.canonical("preset", "debug-custom"))
        end)

        it("returns base alone when prefix is nil (user config)", function()
            assert.equals("my-debug", Configuration.canonical(nil, "my-debug"))
            assert.equals("my-debug", Configuration.canonical("", "my-debug"))
        end)

        it("splits canonical back into (prefix, base)", function()
            local p, b = Configuration.split_canonical("variant:Debug")
            assert.equals("variant", p)
            assert.equals("Debug", b)
        end)

        it("returns (nil, name) when no `:` (user config)", function()
            local p, b = Configuration.split_canonical("my-debug")
            assert.is_nil(p)
            assert.equals("my-debug", b)
        end)
    end)

    describe("prefix + base_name derivation", function()
        it("splits a prefixed canonical name", function()
            local project = make_project()
            local cfg = Configuration.new(project, "variant:Debug",
                { variant = "Debug", is_default = true })
            assert.equals("variant:Debug", cfg.name)
            assert.equals("variant", cfg.prefix)
            assert.equals("Debug", cfg.base_name)
            assert.is_true(cfg:is_auto_gen())
        end)

        it("treats an unprefixed name as a user config", function()
            local project = make_project()
            local cfg = Configuration.new(project, "my-debug",
                { is_user = true })
            assert.is_nil(cfg.prefix)
            assert.equals("my-debug", cfg.base_name)
            assert.is_false(cfg:is_auto_gen())
        end)
    end)

    describe("unresolved_inherits_names", function()
        it("returns an empty list when all bases resolved", function()
            local project = make_project()
            local cfg = Configuration.new(project, "variant:Debug-asan",
                { inherits = "variant:Debug" })
            -- Simulate resolution: base Debug exists, got linked
            cfg._inherits = { project:get_configuration("Debug") or {} }
            cfg._inherits[1].name = "variant:Debug"
            assert.are.same({}, cfg:unresolved_inherits_names())
        end)

        it("returns names that didn't resolve", function()
            local project = make_project()
            local cfg = Configuration.new(project, "my-mix",
                { inherits = { "variant:Debug", "does-not-exist",
                               "also-gone" } })
            cfg._inherits = { { name = "variant:Debug" } }
            assert.are.same({ "does-not-exist", "also-gone" },
                cfg:unresolved_inherits_names())
        end)

        it("returns all names when nothing resolved", function()
            local project = make_project()
            local cfg = Configuration.new(project, "my-mix",
                { inherits = "ghost" })
            cfg._inherits = {}
            assert.are.same({ "ghost" }, cfg:unresolved_inherits_names())
        end)
    end)

    describe("dependents", function()
        local function project_with_configs(configs)
            local ws = h.make_mock_workspace({})
            local data = {
                type = "cmake", path = "App", status = "unconfigured",
                configurations = configs, cached_configurations = {},
            }
            return Project.new(ws, "App", data)
        end

        it("returns configs whose inherits_names includes this one", function()
            local project = project_with_configs({
                ["variant:Debug"] = { prefix = "variant", variant = "Debug" },
                ["my-debug"] = { inherits = "variant:Debug" },
                ["test-debug"] = { inherits = { "variant:Debug", "asan" } },
                ["asan"] = {},  -- abstract mixin
            })
            local debug = project:get_configuration("variant:Debug")
            local deps = debug:dependents()
            table.sort(deps, function(a, b) return a.name < b.name end)
            assert.equals(2, #deps)
            assert.equals("my-debug", deps[1].name)
            assert.equals("test-debug", deps[2].name)
        end)

        it("returns empty when nothing inherits from this config", function()
            local project = project_with_configs({
                ["variant:Debug"] = { prefix = "variant", variant = "Debug" },
                ["variant:Release"] = { prefix = "variant", variant = "Release" },
            })
            local release = project:get_configuration("variant:Release")
            assert.are.same({}, release:dependents())
        end)

        it("includes stale dependents (user's broken ref still shows up)", function()
            -- Even though `my-debug` inherits from a name that doesn't
            -- resolve, its intent to depend is real — the user wrote
            -- it in loomworks.json. Showing it under the would-be
            -- base (if the base ever materialises) helps the user see
            -- the connection.
            local project = project_with_configs({
                ["variant:Debug"] = { prefix = "variant", variant = "Debug" },
                ["my-debug"] = { inherits = "variant:Debug" },
            })
            local debug = project:get_configuration("variant:Debug")
            assert.equals(1, #debug:dependents())
            assert.equals("my-debug", debug:dependents()[1].name)
        end)
    end)

    describe("_source_missing lifecycle", function()
        it("is cleared when a module-emitted refresh arrives", function()
            local project = make_project()
            local cfg = Configuration.new(project, "variant:Debug",
                { is_default = true, variant = "Debug" })
            -- Stub state: config exists but neither default nor user
            cfg._source_missing = true
            cfg:_update({ is_default = true, variant = "Debug" })
            assert.is_false(cfg._source_missing)
        end)

        it("stays set when a refresh has no backing (no is_default/is_user)", function()
            local project = make_project()
            local cfg = Configuration.new(project, "variant:Debug", {})
            cfg._source_missing = true
            cfg:_update({})  -- still no backing
            assert.is_true(cfg._source_missing)
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

    -- Configurations come only from module.info() and user overrides, not cache

    it("does not create Configuration for cache-only variant", function()
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
        -- Release only in cache, not in config sources — no Configuration created
        assert.is_nil(project:get_configuration("Release"))
    end)

    it("removes Configuration absent from config sources", function()
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

        -- Remove Release from config sources
        project:_update({
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug" } },
            cached_configurations = {},
        })
        assert.is_nil(project:get_configuration("Release"))
    end)
end)

describe("ConfigUnit _configuration resolution", function()
    it("resolves _configuration from project registry", function()
        local ws = h.make_mock_workspace()
        -- Create a project with Debug configuration
        local project = Project.new(ws, "App", {
            type = "cmake",
            path = "App",
            status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project

        -- Create ConfigUnit via ensure_config_unit (profile-resolution style)
        local cfg = project:get_configuration("Debug")
        local unit = ws:ensure_config_unit(project, cfg, nil)
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

        local profile = Profile.new(ws, {
            _key = "debug",
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

        local profile = Profile.new(ws, {
            _key = "debug",
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

        local profile = Profile.new(ws, {
            _key = "debug:ninja-gcc",
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

        local profile = Profile.new(ws, {
            _key = "debug",
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
