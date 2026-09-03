--- Tests for compiler-family variable overrides (core §1.3.1).
---
--- Covers: compiler-family resolution (family-override wins within a level,
--- chain position dominates, empty-default fallback, unknown family,
--- undeclared name), the compiler-family accessor, cmake `-D` emission with
--- the resolved override, resolved-fingerprint staleness (both directions),
--- override serialization round-trip, and workspace diagnostics.

local variables = require("loomworks.variables")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local h = require("tests.helpers")

-- ---------------------------------------------------------------------------
-- Compiler-family accessor
-- ---------------------------------------------------------------------------
describe("compiler family accessor", function()
    it("normalizes families, folding clang-cl → clang", function()
        assert.equals("clang", cpp.normalize_family("clang"))
        assert.equals("gcc", cpp.normalize_family("gcc"))
        assert.equals("msvc", cpp.normalize_family("msvc"))
        assert.equals("clang", cpp.normalize_family("clang-cl"))
        assert.is_nil(cpp.normalize_family("tcc"))
        assert.is_nil(cpp.normalize_family(nil))
    end)

    it("uses an explicit compiler_family field (meson-shaped tool_data)", function()
        assert.equals("clang", cpp.family_from_tool_data({ compiler_family = "clang-cl" }))
        assert.equals("msvc", cpp.family_from_tool_data({ compiler_family = "msvc" }))
        assert.equals("gcc", cpp.family_from_tool_data({ compiler_family = "gcc" }))
    end)

    it("derives from compiler_id (cmake kits carry no family field)", function()
        assert.equals("gcc", cpp.family_from_tool_data({ compiler_id = "gcc-14.2.0" }))
        assert.equals("clang", cpp.family_from_tool_data({ compiler_id = "clang-18.1.8" }))
        assert.equals("clang", cpp.family_from_tool_data({ compiler_id = "clang-cl-17.0.0" }))
        assert.equals("msvc", cpp.family_from_tool_data({ compiler_id = "msvc-17" }))
    end)

    it("derives from compiler_path when no id/family present", function()
        assert.equals("clang", cpp.family_from_tool_data({ compiler_path = "/usr/bin/clang++" }))
        assert.equals("gcc", cpp.family_from_tool_data({ compiler_path = "/usr/bin/g++" }))
        assert.equals("clang", cpp.family_from_tool_data({
            compiler_path = "C:/VS/VC/Tools/Llvm/x64/bin/clang-cl.exe" }))
    end)

    it("returns nil for undeterminable tool_data", function()
        assert.is_nil(cpp.family_from_tool_data(nil))
        assert.is_nil(cpp.family_from_tool_data({}))
        assert.is_nil(cpp.family_from_tool_data({ generator = "Ninja" }))
    end)

    it("Tool:compiler_family() delegates to the shared logic", function()
        local Tool = require("loomworks.tool")
        local module = { id = "cmake", languages = { "c++" } }
        local t = Tool.new(module, "ninja-clang-18", { compiler_id = "clang-18.1.8" })
        assert.equals("clang", t:compiler_family())
    end)
end)

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------
describe("compiler-family variable resolution", function()
    local function project(decls)
        return { variables = decls }
    end

    it("family override wins over plain variables at the same level", function()
        local proj = project({ warn = { type = "string", default = "-W0" } })
        local cfg = {
            name = "Debug",
            variables = { warn = "-Wall" },
            _overrides = { clang = { warn = "-Wall -Wextra-clang" } },
            _inherits = {},
        }
        local r = variables.resolve(proj, cfg, "clang")
        assert.equals("-Wall -Wextra-clang", r.warn.value)
        assert.is_true(r.warn.from_override)
        assert.equals(cfg, r.warn.source_config)
    end)

    it("falls through to the level's plain variables when family has no entry", function()
        local proj = project({ warn = { type = "string", default = "-W0" } })
        local cfg = {
            name = "Debug",
            variables = { warn = "-Wall" },
            _overrides = { clang = { warn = "-Wclang" } },
            _inherits = {},
        }
        local r = variables.resolve(proj, cfg, "gcc")
        assert.equals("-Wall", r.warn.value)
        assert.is_false(r.warn.from_override)
    end)

    it("chain position dominates compiler-specificity", function()
        -- A nearer config's plain `variables` shadows a farther config's
        -- `overrides` entry, even when the compiler matches that override.
        local proj = project({ warn = { type = "string", default = "-W0" } })
        local base = {
            name = "Base",
            variables = nil,
            _overrides = { clang = { warn = "-Wfar-clang" } },
            _inherits = {},
        }
        local child = {
            name = "Debug",
            variables = { warn = "-Wnear" },  -- plain, but nearer
            _overrides = nil,
            _inherits = { base },
        }
        local r = variables.resolve(proj, child, "clang")
        assert.equals("-Wnear", r.warn.value)
        assert.equals(child, r.warn.source_config)
        assert.is_false(r.warn.from_override)
    end)

    it("finds a farther override when nearer levels set nothing", function()
        local proj = project({ warn = { type = "string", default = "-W0" } })
        local base = {
            name = "Base",
            _overrides = { clang = { warn = "-Wfar-clang" } },
            _inherits = {},
        }
        local child = { name = "Debug", _inherits = { base } }
        local r = variables.resolve(proj, child, "clang")
        assert.equals("-Wfar-clang", r.warn.value)
        assert.equals(base, r.warn.source_config)
        assert.is_true(r.warn.from_override)
    end)

    it("falls back to the project default (which may be empty)", function()
        local proj = project({ warn = { type = "string", default = "" } })
        local cfg = { name = "Debug", _inherits = {} }
        local r = variables.resolve(proj, cfg, "clang")
        assert.equals("", r.warn.value)
        assert.is_nil(r.warn.source_config)
        assert.is_false(r.warn.from_override)
    end)

    it("nil active_family never consults overrides", function()
        local proj = project({ warn = { type = "string", default = "-W0" } })
        local cfg = {
            name = "Debug",
            _overrides = { clang = { warn = "-Wclang" } },
            _inherits = {},
        }
        local r = variables.resolve(proj, cfg, nil)
        assert.equals("-W0", r.warn.value)
    end)
end)

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------
describe("compiler-override validation", function()
    local decls = { output_dir = { type = "path", default = "/o" } }

    it("accepts a block whose names are all declared", function()
        local ok = variables.validate_compiler_overrides(
            { clang = { output_dir = "/o/clang" } }, decls)
        assert.is_true(ok)
    end)

    it("rejects an undeclared overridden name", function()
        local ok, err = variables.validate_compiler_overrides(
            { clang = { missing = "x" } }, decls)
        assert.is_false(ok)
        assert.truthy(err:find("not declared"))
    end)

    it("does NOT reject an unknown family key (that is a diagnostic)", function()
        local ok = variables.validate_compiler_overrides(
            { klang = { output_dir = "/o" } }, decls)
        assert.is_true(ok)
    end)

    it("unknown_families lists only unrecognized keys", function()
        local unknown = variables.unknown_families(
            { clang = {}, klang = {}, msvc = {}, tcc = {} })
        assert.are.same({ "klang", "tcc" }, unknown)
    end)

    it("save_configuration rejects an overrides block with an undeclared name", function()
        local ConfigUnit = require("loomworks.config_unit")  -- luacheck: ignore
        local Project = require("loomworks.project")
        local core = h.make_mock_core()
        core._projects.App = Project.new(core, "App", {
            type = "cmake", path = "App",
            configurations = {}, cached_configurations = {},
            variables = { warn = { type = "string", default = "-W0" } },
        })
        local project = core._projects.App
        local ok, err = project:save_configuration("Custom", {
            inherits = "variant:Debug",
            overrides = { clang = { undeclared = "x" } },
        })
        assert.is_false(ok)
        assert.truthy(err:find("not declared"))
        -- The bad block never reached the working copy.
        assert.is_nil(project:get_configuration("Custom"))
    end)
end)

-- ---------------------------------------------------------------------------
-- cmake -D emission
-- ---------------------------------------------------------------------------
describe("cmake option expansion with compiler overrides", function()
    local function find_configure(tasks)
        for _, t in ipairs(tasks) do
            if t.loomworks and t.loomworks.action == "configure" then return t end
        end
    end

    local function d_value(cmd, key)
        for _, arg in ipairs(cmd) do
            local v = arg:match("^%-D" .. key .. "=(.*)$")
            if v then return v end
        end
    end

    --- Build a Ninja single-config ctx whose CXXFLAGS option references a
    --- project variable, with the variable resolved for `family` upstream.
    local function ctx_for(family)
        local proj = { variables = { warn = { type = "string", default = "-Wall" } } }
        local cfg = {
            name = "Debug",
            variables = { warn = "-Wall" },
            _overrides = { clang = { warn = "-Wall -Wno-clang-thing" } },
            _inherits = {},
        }
        local resolved = variables.resolve(proj, cfg, family)
        local resolved_variables = {}
        for name, entry in pairs(resolved) do
            resolved_variables[name] = { value = entry.value, type = entry.type }
        end
        return {
            name = "App",
            path = "App",
            workspace_root = "/fake/root",
            configurations = { Debug = { variant = "Debug", generator = "Ninja" } },
            type_config = { options = { CMAKE_CXX_FLAGS = "${warn}" } },
            tool_data = { generator = "Ninja" },
            cached_build_dir = "/fake/root/App/build",
            resolved_variables = resolved_variables,
        }
    end

    it("expands ${warn} using the clang override", function()
        local tasks = cmake.tasks(ctx_for("clang"), "Debug")
        local cmd = find_configure(tasks).builder().cmd
        assert.equals("-Wall -Wno-clang-thing", d_value(cmd, "CMAKE_CXX_FLAGS"))
    end)

    it("expands ${warn} to the plain value for gcc (no clang override)", function()
        local tasks = cmake.tasks(ctx_for("gcc"), "Debug")
        local cmd = find_configure(tasks).builder().cmd
        assert.equals("-Wall", d_value(cmd, "CMAKE_CXX_FLAGS"))
    end)
end)

-- ---------------------------------------------------------------------------
-- Staleness over resolved options (both directions)
-- ---------------------------------------------------------------------------
describe("is_stale over resolved option values", function()
    local Configuration = require("loomworks.configuration")

    --- Build a configured unit whose option references a project variable.
    --- Returns (unit, project, cfg). `family` selects the active compiler.
    local function make_configured(family)
        local ConfigUnit = require("loomworks.config_unit")  -- luacheck: ignore
        local Project = require("loomworks.project")
        local core = h.make_mock_core()
        local project = Project.new(core, "App", {
            type = "cmake", path = "App",
            configurations = {}, cached_configurations = {},
        })
        core._projects.App = project
        project.variables = { warn = { type = "string", default = "-Wa" } }
        local cfg = Configuration.new(project, "Debug", {
            variant = "Debug",
            options = { CMAKE_CXX_FLAGS = "${warn}" },
        })
        project._configurations[#project._configurations + 1] = cfg
        local unit = core:ensure_config_unit(project, cfg, nil)
        unit._tool_data = { compiler_family = family }
        -- Simulate a configure: snapshot the resolved fingerprint.
        unit._cached_options = unit:resolved_option_fingerprint()
        unit._cached_module_config = cfg.module_config
        return unit, project, cfg
    end

    it("snapshot captures the RESOLVED value, not the raw template", function()
        local unit = make_configured("gcc")
        assert.are.same({ CMAKE_CXX_FLAGS = "-Wa" }, unit._cached_options)
    end)

    it("editing a variable default that changes a -D value → stale", function()
        local unit, project = make_configured("gcc")
        assert.is_false(unit:is_stale())        -- no-op baseline
        project.variables.warn.default = "-Wb"  -- changes resolved -D
        assert.is_true(unit:is_stale())
    end)

    it("adding a matching compiler override that changes a -D value → stale", function()
        local unit, _, cfg = make_configured("clang")
        assert.is_false(unit:is_stale())
        cfg._overrides = { clang = { warn = "-Wclang" } }
        assert.is_true(unit:is_stale())
    end)

    it("a no-op change (no resolved effect) does NOT report stale", function()
        local unit, _, cfg = make_configured("clang")
        -- An override for a DIFFERENT family than the active one: no effect.
        cfg._overrides = { gcc = { warn = "-Wgcc-only" } }
        assert.is_false(unit:is_stale())
    end)
end)

-- ---------------------------------------------------------------------------
-- Serialization round-trip
-- ---------------------------------------------------------------------------
describe("overrides serialization", function()
    local Configuration = require("loomworks.configuration")

    it("round-trips through _update → serialize_user_override", function()
        local project = { key = "App" }
        local cfg = Configuration.new(project, "Debug", {
            is_user = true,
            variant = "Debug",
            options = { CMAKE_CXX_FLAGS = "${warn}" },
            variables = { warn = "-Wall" },
            overrides = { clang = { warn = "-Wall -Wno-x" } },
        })
        assert.are.same({ clang = { warn = "-Wall -Wno-x" } }, cfg._overrides)
        local entry = cfg:serialize_user_override()
        assert.are.same({ clang = { warn = "-Wall -Wno-x" } }, entry.overrides)

        -- Reconstruct from the serialized entry.
        local cfg2 = Configuration.new(project, "Debug", entry)
        assert.are.same(cfg._overrides, cfg2._overrides)
    end)

    it("emits no overrides key when the block is empty/absent", function()
        local project = { key = "App" }
        local cfg = Configuration.new(project, "Debug", {
            is_user = true, variant = "Debug", options = { A = "1" },
        })
        local entry = cfg:serialize_user_override()
        assert.is_nil(entry.overrides)
    end)
end)
