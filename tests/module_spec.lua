local Module = require("loomworks.module")
local Tool = require("loomworks.tool")

describe("Module", function()
    local function make_impl(overrides)
        return vim.tbl_extend("force", {
            id = "cmake",
            has_keyed_tools = true,
            info = function() return { configurations = {} } end,
            validate = function() return { valid = true } end,
        }, overrides or {})
    end

    describe("new", function()
        it("creates with basic fields", function()
            local impl = make_impl()
            local mod = Module.new("cmake", impl)
            assert.equals("cmake", mod.id)
            assert.is_true(rawequal(impl, mod.impl))
            assert.is_true(mod.has_keyed_tools)
            assert.is_false(mod._removed)
        end)

        it("defaults has_keyed_tools to false", function()
            local mod = Module.new("ets", { id = "ets" })
            assert.is_false(mod.has_keyed_tools)
        end)
    end)

    describe("_update", function()
        it("updates impl in place", function()
            local impl1 = make_impl()
            local mod = Module.new("cmake", impl1)
            local identity = mod

            local impl2 = make_impl({ has_keyed_tools = false })
            mod:_update(impl2)

            assert.is_true(rawequal(identity, mod))
            assert.is_true(rawequal(impl2, mod.impl))
            assert.is_false(mod.has_keyed_tools)
        end)
    end)

    describe("tool registry", function()
        it("get_or_create_tool creates a new tool", function()
            local mod = Module.new("cmake", make_impl())
            local tool = mod:get_or_create_tool("ninja-gcc", { gen = "Ninja" }, "Ninja GCC")
            assert.is_not_nil(tool)
            assert.equals("ninja-gcc", tool.key)
            assert.equals("Ninja GCC", tool.label)
        end)

        it("get_or_create_tool returns same instance on second call", function()
            local mod = Module.new("cmake", make_impl())
            local t1 = mod:get_or_create_tool("ninja-gcc", { gen = "Ninja" }, "label")
            local t2 = mod:get_or_create_tool("ninja-gcc", { gen = "Ninja2" }, "label2")
            assert.is_true(rawequal(t1, t2))
            assert.equals("Ninja2", t2.data.gen)
        end)

        it("find_tool returns existing tool", function()
            local mod = Module.new("cmake", make_impl())
            local created = mod:get_or_create_tool("ninja-gcc", {}, nil)
            local found = mod:find_tool("ninja-gcc")
            assert.is_true(rawequal(created, found))
        end)

        it("find_tool returns nil for unknown key", function()
            local mod = Module.new("cmake", make_impl())
            assert.is_nil(mod:find_tool("nonexistent"))
        end)

        it("find_tool resolves a major-version prefix to the highest patch (spec §16.3)", function()
            local mod = Module.new("cmake", make_impl())
            mod:get_or_create_tool("ninja-clang-18.1.0", {}, nil)
            local hi = mod:get_or_create_tool("ninja-clang-18.1.7", {}, nil)
            assert.is_true(rawequal(hi, mod:find_tool("ninja-clang-18")))
        end)

        it("find_tool major prefix stops at the version boundary (18 != 1)", function()
            local mod = Module.new("cmake", make_impl())
            mod:get_or_create_tool("ninja-clang-18.1.7", {}, nil)
            -- A truncated selector must not cross into a different major.
            assert.is_nil(mod:find_tool("ninja-clang-1"))
        end)

        it("find_tool resolves an edition-agnostic MSVC pin on a dash boundary", function()
            -- CI images differ in VS edition; `msvc-17` must resolve without the
            -- job hardcoding enterprise/buildtools (spec §16.3).
            local mod = Module.new("cmake", make_impl())
            local bt = mod:get_or_create_tool("msvc-17-2022-buildtools", {}, nil)
            mod:get_or_create_tool("msvc-17-2022-enterprise", {}, nil)
            local found = mod:find_tool("msvc-17")
            assert.is_not_nil(found)
            -- Deterministic tie-break (no trailing version -> lowest key).
            assert.is_true(rawequal(bt, found))
        end)

        it("find_tool dash pin is anchored, not a substring", function()
            local mod = Module.new("cmake", make_impl())
            mod:get_or_create_tool("ninja-msvc-17-enterprise", {}, nil)
            -- `msvc-17` must not match a key that merely contains it.
            assert.is_nil(mod:find_tool("msvc-17"))
            assert.is_not_nil(mod:find_tool("ninja-msvc-17"))
        end)

        it("find_tool dash pin does not cross a numeric boundary (17 != 1)", function()
            local mod = Module.new("cmake", make_impl())
            mod:get_or_create_tool("msvc-17-2022-enterprise", {}, nil)
            assert.is_nil(mod:find_tool("msvc-1"))
        end)

        it("nil tool_key uses default slot", function()
            local mod = Module.new("ets", { id = "ets" })
            local tool = mod:get_or_create_tool(nil, {}, nil)
            assert.is_not_nil(tool)
            assert.is_nil(tool.key)
            local found = mod:find_tool(nil)
            assert.is_true(rawequal(tool, found))
        end)

        it("tools() returns all tools", function()
            local mod = Module.new("cmake", make_impl())
            mod:get_or_create_tool("gcc", {}, nil)
            mod:get_or_create_tool("clang", {}, nil)
            local all = mod:tools()
            assert.equals(2, #all)
        end)

        it("different keys create different tools", function()
            local mod = Module.new("cmake", make_impl())
            local t1 = mod:get_or_create_tool("gcc", {}, nil)
            local t2 = mod:get_or_create_tool("clang", {}, nil)
            assert.is_false(rawequal(t1, t2))
        end)
    end)

    describe("__tostring", function()
        it("shows module id", function()
            local mod = Module.new("cmake", make_impl())
            assert.equals("Module(cmake)", tostring(mod))
        end)
    end)

    describe("__eq", function()
        it("equal when same id", function()
            local a = Module.new("cmake", make_impl())
            local b = Module.new("cmake", make_impl())
            assert.is_true(a == b)
        end)

        it("not equal when different id", function()
            local a = Module.new("cmake", make_impl())
            local b = Module.new("ets", { id = "ets" })
            assert.is_false(a == b)
        end)
    end)
end)

-- Regression: file-mtime staleness was removed from the build-system modules.
-- Their generators (Ninja/Make) re-run configure on input-file changes, so an
-- `inspect` that stats a top-level file is redundant and less accurate. Guard
-- against it silently coming back. Option-level staleness lives on
-- ConfigUnit:is_stale(), not `inspect`.
describe("build-system modules expose no file-mtime inspect", function()
    it("cmake has no inspect", function()
        assert.is_nil(require("loomworks.modules.cmake").inspect)
    end)

    it("meson has no inspect", function()
        assert.is_nil(require("loomworks.modules.meson").inspect)
    end)

    it("typescript has no inspect", function()
        assert.is_nil(require("loomworks.modules.typescript").inspect)
    end)
end)
