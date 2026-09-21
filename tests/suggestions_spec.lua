--- Tests for the suggestion framework and the compiler-cache provider
--- (headless §16.31), plus the `lw health` command's no-workspace path.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local suggestions = require("loomworks.suggestions")
local cpp = require("loomworks.cpp_compilers")
local h = require("tests.helpers")

local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Framework
-- ---------------------------------------------------------------------------
describe("suggestion framework", function()
    it("aggregates registered providers", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() return { { title = "a", detail = "d", remedy = "r" } } end)
        suggestions.register(function() return { { title = "b" } } end)
        local out = suggestions.collect({})
        assert.equals(2, #out)
        assert.equals("a", out[1].title)
        suggestions._providers = orig
    end)

    it("skips a provider that errors (advisory, never breaks)", function()
        local orig = suggestions._providers
        suggestions._providers = {}
        suggestions.register(function() error("boom") end)
        suggestions.register(function() return { { title = "ok" } } end)
        local out = suggestions.collect({})
        assert.equals(1, #out)
        assert.equals("ok", out[1].title)
        suggestions._providers = orig
    end)

    it("returns nothing for a nil workspace", function()
        assert.same({}, suggestions.collect(nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- Compiler-cache provider
-- ---------------------------------------------------------------------------
describe("compiler-cache suggestion provider", function()
    after_each(function() cpp.lookup_path = orig_lookup end)

    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local function make_ws(projects, cfg_sets)
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = projects,
                configuration_sets = cfg_sets or {},
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        return core:get_workspace()
    end

    it("fires for a C/C++ project with no cache on PATH", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.matches("compiler cache", out[1].title)
        assert.is_string(out[1].detail)
        assert.is_string(out[1].remedy)
    end)

    it("is silent when a cache is already present", function()
        local ws = make_ws({ App = { cmake = {} } })
        set_present({ ccache = true })
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent for a workspace with no C/C++ project", function()
        local ws = make_ws({ Web = { typescript = {} } })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("is silent when every C/C++ project pinned cache off", function()
        local ws = make_ws({
            App = { cmake = { configurations = { Debug = { variables = { cache = "off" } },
                                                 Release = { variables = { cache = "off" } } } } },
        })
        set_present({})
        assert.same({}, suggestions.compiler_cache_provider(ws))
    end)

    it("recommends the platform-preferred tool", function()
        local tool = suggestions._preferred_install_tool()
        assert.is_true(tool == "sccache" or tool == "ccache")
        local ws = make_ws({ App = { cmake = {} } })
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.matches(tool, out[1].remedy)
    end)
end)

-- ---------------------------------------------------------------------------
-- lw health command (no-workspace path)
-- ---------------------------------------------------------------------------
describe("cli.cmd_health", function()
    local cli = require("loomworks.cli")

    it("exits 0 with the worktree hint when no workspace is present", function()
        assert.equals(0, cli.cmd_health(nil))
    end)
end)
