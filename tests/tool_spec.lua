local h = require("tests.helpers")
local Tool = require("loomworks.tool")
local Module = require("loomworks.module")

--- Create a mock Module for testing Tool directly.
local function mock_module(id)
    return Module.new(id, { id = id, has_keyed_tools = (id == "cmake") })
end

describe("Tool", function()
    describe("new", function()
        it("creates a keyed tool", function()
            local mod = mock_module("cmake")
            local tool = Tool.new(mod, "ninja-gcc-12", { generator = "Ninja", compiler_path = "/usr/bin/gcc" }, "Ninja + GCC 12")
            assert.equals("cmake", tool.mod_type)
            assert.is_true(rawequal(mod, tool._module))
            assert.equals("ninja-gcc-12", tool.key)
            assert.equals("Ninja", tool.data.generator)
            assert.equals("Ninja + GCC 12", tool.label)
            assert.is_false(tool._removed)
        end)

        it("creates a default tool with nil key", function()
            local mod = mock_module("ets")
            local tool = Tool.new(mod, nil, {}, nil)
            assert.equals("ets", tool.mod_type)
            assert.is_true(rawequal(mod, tool._module))
            assert.is_nil(tool.key)
            assert.is_nil(tool.label)
        end)
    end)

    describe("is_keyed", function()
        it("returns true for keyed tools", function()
            local tool = Tool.new(mock_module("cmake"), "ninja-gcc-12", {}, "label")
            assert.is_true(tool:is_keyed())
        end)

        it("returns false for default tools", function()
            local tool = Tool.new(mock_module("ets"), nil, {}, nil)
            assert.is_false(tool:is_keyed())
        end)
    end)

    describe("_update", function()
        it("updates data and label in place", function()
            local tool = Tool.new(mock_module("cmake"), "ninja-gcc-12", { old = true }, "old label")
            local identity = tool
            tool:_update({ new = true }, "new label")
            assert.is_true(rawequal(identity, tool))
            assert.is_true(tool.data.new)
            assert.equals("new label", tool.label)
        end)

        it("preserves existing data/label when nil passed", function()
            local tool = Tool.new(mock_module("cmake"), "k", { keep = true }, "keep")
            tool:_update(nil, nil)
            assert.is_true(tool.data.keep)
            assert.equals("keep", tool.label)
        end)
    end)

    describe("to_ref", function()
        it("produces a ToolRef table", function()
            local tool = Tool.new(mock_module("cmake"), "ninja-gcc-12", { gen = "Ninja" }, "label")
            local ref = tool:to_ref()
            assert.equals("ninja-gcc-12", ref.key)
            assert.equals("Ninja", ref.data.gen)
            assert.equals("label", ref.label)
            assert.equals("cmake", ref.mod_type)
        end)
    end)

    describe("__tostring", function()
        it("shows keyed tool", function()
            local tool = Tool.new(mock_module("cmake"), "ninja-gcc", {}, nil)
            assert.equals("Tool(cmake:ninja-gcc)", tostring(tool))
        end)

        it("shows default tool", function()
            local tool = Tool.new(mock_module("ets"), nil, {}, nil)
            assert.equals("Tool(ets:default)", tostring(tool))
        end)
    end)

    describe("__eq", function()
        it("equal when same module and key", function()
            local mod = mock_module("cmake")
            local a = Tool.new(mod, "ninja-gcc", {}, nil)
            local b = Tool.new(mod, "ninja-gcc", { different = true }, "different")
            assert.is_true(a == b)
        end)

        it("not equal when different key", function()
            local mod = mock_module("cmake")
            local a = Tool.new(mod, "ninja-gcc", {}, nil)
            local b = Tool.new(mod, "msvc-17", {}, nil)
            assert.is_false(a == b)
        end)

        it("not equal when different module", function()
            local a = Tool.new(mock_module("cmake"), "k", {}, nil)
            local b = Tool.new(mock_module("ets"), "k", {}, nil)
            assert.is_false(a == b)
        end)
    end)
end)

describe("Workspace Tool registry", function()
    it("get_or_create_tool creates and returns a Tool", function()
        local ws = h.make_mock_workspace()
        local tool = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")
        assert.equals("cmake", tool.mod_type)
        assert.equals("ninja-gcc", tool.key)
        assert.equals("Ninja", tool.data.gen)
        assert.equals("label", tool.label)
    end)

    it("get_or_create_tool returns same instance for same key", function()
        local ws = h.make_mock_workspace()
        local t1 = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")
        local t2 = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja2" }, "label2")
        assert.is_true(rawequal(t1, t2))
        -- Data updated in place
        assert.equals("Ninja2", t1.data.gen)
    end)

    it("get_or_create_tool returns different instances for different keys", function()
        local ws = h.make_mock_workspace()
        local t1 = ws:get_or_create_tool("cmake", "ninja-gcc", {}, nil)
        local t2 = ws:get_or_create_tool("cmake", "msvc-17", {}, nil)
        assert.is_false(rawequal(t1, t2))
    end)

    it("find_tool returns nil when not found", function()
        local ws = h.make_mock_workspace()
        assert.is_nil(ws:find_tool("cmake", "nonexistent"))
    end)

    it("find_tool returns existing tool", function()
        local ws = h.make_mock_workspace()
        local created = ws:get_or_create_tool("cmake", "ninja-gcc", {}, nil)
        local found = ws:find_tool("cmake", "ninja-gcc")
        assert.is_true(rawequal(created, found))
    end)

    it("find_tool distinguishes nil key from string key", function()
        local ws = h.make_mock_workspace()
        ws:get_or_create_tool("ets", nil, {}, nil)
        ws:get_or_create_tool("ets", "somekey", {}, nil)
        local default = ws:find_tool("ets", nil)
        local keyed = ws:find_tool("ets", "somekey")
        assert.is_false(rawequal(default, keyed))
    end)
end)

describe("ConfigUnit accessor methods", function()
    local ConfigUnit = require("loomworks.config_unit")
    local Project = require("loomworks.project")

    it("tool_object() returns Tool domain object", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug:ninja-gcc"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc",
                        type = "cmake",
                        tool_key = "ninja-gcc",
                        tool_data = { gen = "Ninja" },
                    },
                },
            },
        })
        local tool = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")
        local unit = ws._config_units["App/Debug:ninja-gcc"]
            or ConfigUnit.new(ws, "App/Debug:ninja-gcc", "App")
        ws._config_units["App/Debug:ninja-gcc"] = unit
        assert.is_true(rawequal(tool, unit:tool_object()))
    end)

    it("tool_object() returns nil when no tool", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = {}, cached_configurations = {},
        })
        ws._projects["App"] = project
        local unit = ws:ensure_config_unit(project, h.get_or_create_config(project, "Debug"), nil)
        assert.is_nil(unit:tool_object())
    end)

    it("project() returns Project reference", function()
        local ws = h.make_mock_workspace()
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = {}, cached_configurations = {},
        })
        ws._projects["App"] = project
        ws.cache = {
            configurations = {
                ["App/Debug"] = {
                    project_key = "App", config_key = "Debug", type = "cmake",
                },
            },
        }
        local unit = ws._config_units["App/Debug"]
            or ConfigUnit.new(ws, "App/Debug", "App")
        ws._config_units["App/Debug"] = unit
        assert.is_true(rawequal(project, unit:project()))
    end)

    it("configuration() returns Configuration reference", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App", config_key = "Debug",
                        type = "cmake", variant = "Debug",
                    },
                },
            },
        })
        local project = Project.new(ws, "App", {
            type = "cmake", path = "App", status = "unconfigured",
            configurations = { Debug = { variant = "Debug", is_default = true } },
            cached_configurations = {},
        })
        ws._projects["App"] = project
        local unit = ws._config_units["App/Debug"]
            or ConfigUnit.new(ws, "App/Debug", "App")
        ws._config_units["App/Debug"] = unit
        local cfg = unit:configuration()
        assert.is_not_nil(cfg)
        assert.equals("Debug", cfg.name)
    end)

    it("resolve_tool() uses _tool when available", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug:ninja-gcc"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc",
                        type = "cmake",
                        tool_key = "ninja-gcc",
                        tool_data = { gen = "Ninja" },
                    },
                },
            },
        })
        ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "Ninja + GCC")
        local unit = ws._config_units["App/Debug:ninja-gcc"]
            or ConfigUnit.new(ws, "App/Debug:ninja-gcc", "App")
        ws._config_units["App/Debug:ninja-gcc"] = unit
        local ref = unit:resolve_tool()
        assert.is_not_nil(ref)
        assert.equals("ninja-gcc", ref.key)
        assert.equals("Ninja + GCC", ref.label)
        assert.equals("cmake", ref.mod_type)
    end)
end)

describe("ConfigUnit _tool resolution", function()
    local ConfigUnit = require("loomworks.config_unit")

    it("resolves _tool from workspace registry", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug:ninja-gcc"] = {
                        project_key = "App",
                        config_key = "Debug:ninja-gcc",
                        type = "cmake",
                        tool_key = "ninja-gcc",
                        tool_data = { gen = "Ninja" },
                    },
                },
            },
        })
        -- Pre-populate tool registry
        local tool = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")

        local unit = ws._config_units["App/Debug:ninja-gcc"]
            or ConfigUnit.new(ws, "App/Debug:ninja-gcc", "App")
        ws._config_units["App/Debug:ninja-gcc"] = unit
        assert.is_not_nil(unit._tool)
        assert.is_true(rawequal(tool, unit._tool))
    end)

    it("_tool is nil when no tool in cache", function()
        local ws = h.make_mock_workspace({
            cache = {
                configurations = {
                    ["App/Debug"] = {
                        project_key = "App",
                        config_key = "Debug",
                        type = "cmake",
                    },
                },
            },
        })
        local unit = ws._config_units["App/Debug"]
            or ConfigUnit.new(ws, "App/Debug", "App")
        ws._config_units["App/Debug"] = unit
        assert.is_nil(unit._tool)
    end)
end)

describe("Profile _tool_objects resolution", function()
    local Profile = require("loomworks.profile").Profile

    it("resolves tool objects from workspace registry", function()
        local ws = h.make_mock_workspace()
        local tool = ws:get_or_create_tool("cmake", "ninja-gcc", { gen = "Ninja" }, "label")

        local profile = Profile.new(ws, "debug:ninja-gcc", {
            configuration_set = "debug",
            tools = { cmake = { key = "ninja-gcc", data = { gen = "Ninja" }, label = "label" } },
        })
        assert.is_not_nil(profile._tool_objects)
        assert.is_true(rawequal(tool, profile._tool_objects.cmake))
    end)

    it("tool_object_for returns Tool object", function()
        local ws = h.make_mock_workspace()
        ws:get_or_create_tool("cmake", "ninja-gcc", {}, "label")

        local profile = Profile.new(ws, "debug:ninja-gcc", {
            tools = { cmake = { key = "ninja-gcc", data = {}, label = "label" } },
        })
        local t = profile:tool_object_for("cmake")
        assert.is_not_nil(t)
        assert.equals("ninja-gcc", t.key)
    end)

    it("tool_object_for returns nil for missing module type", function()
        local ws = h.make_mock_workspace()
        local profile = Profile.new(ws, "debug", {})
        assert.is_nil(profile:tool_object_for("cmake"))
    end)
end)
