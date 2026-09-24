--- Tests for compiler-cache status surfacing (spec/ui.md, headless §16.18).
---
--- Covers `Profile:compiler_cache_status()` text/stale for present / off /
--- auto-none, and the CLI `--cache-stats` stats fetcher `cli._cache_stats`
--- (arg selection + output parsing, with an injected runner).

-- Requiring loomworks.cli auto-runs its main() as a side effect; suppress that
-- so the module can be required for its helpers.
_G.LOOMWORKS_CLI_NO_AUTORUN = true

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
-- Profile:compiler_cache_status()
-- ---------------------------------------------------------------------------
describe("Profile compiler-cache status", function()
    after_each(function() cpp.lookup_path = orig_lookup end)

    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local GCC_TOOL = { compiler_id = "gcc-12", generator = "Ninja", compiler_path = "/usr/bin/g++" }

    local function make_core(cfg_extra, tool_data)
        tool_data = tool_data or GCC_TOOL
        local proj = { cmake = cfg_extra or {} }
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = proj },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = {
                    debug = {
                        configuration_set = "debug",
                        tools = { cmake = { key = "ninja-gcc-12", data = tool_data } },
                    },
                },
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = {
            cmake = { {
                tool_key = "ninja-gcc-12",
                tool_data = tool_data,
                tool_label = "gcc 12",
            } },
        }
        core:remerge()
        return core
    end

    local function the_profile(core)
        for _, p in ipairs(core:get_workspace()._profiles) do return p end
    end

    local function the_unit(core)
        for _, p in ipairs(core:get_workspace()._profiles) do
            for _, pp in ipairs(p:projects()) do
                if pp._init_project_key == "App" then return pp._config_unit end
            end
        end
    end

    -- Regression: status resolved via family_from_tool_data (which folds
    -- clang-cl → clang) and skipped the MSVC-ABI promotion the build uses, so a
    -- clang-cl profile with both tools installed reported "ccache" while the
    -- build actually used sccache. Status must route through the same resolver.
    it("clang-cl profile with both tools reports sccache (what the build uses)", function()
        local clang_cl = {
            compiler_id = "clang-cl-17.0.0", generator = "Ninja",
            compiler_path = "C:/Program Files/LLVM/bin/clang-cl.exe",
        }
        local core = make_core(nil, clang_cl)
        set_present({ ccache = true, sccache = true })
        local st = the_profile(core):compiler_cache_status()
        assert.is_not_nil(st)
        -- Must agree with the build-context resolution.
        local unit = the_unit(core)
        local built = require("loomworks.compiler_cache").resolve_for(
            unit._project, unit._configuration, clang_cl, the_profile(core))
        assert.equals("sccache", built.tool)
        assert.equals("sccache", st.tool)
        assert.equals("/usr/bin/sccache", st.path)
        assert.equals("Cache: sccache", st.text)
    end)

    it("reports the resolved launcher under auto", function()
        local core = make_core()
        set_present({ ccache = true })
        local st = the_profile(core):compiler_cache_status()
        assert.is_not_nil(st)
        assert.equals("ccache", st.tool)
        assert.is_true(st.present)
        assert.equals("Cache: ccache", st.text)
        assert.is_false(st.stale)
    end)

    it("reports auto (none found) when no launcher is on PATH", function()
        local core = make_core()
        set_present({})
        local st = the_profile(core):compiler_cache_status()
        assert.is_false(st.present)
        assert.equals("Cache: auto (none found)", st.text)
    end)

    it("reports off when the policy resolves off", function()
        local core = make_core({ configurations = { Debug = { variables = { cache = "off" } } } })
        set_present({ ccache = true })
        local st = the_profile(core):compiler_cache_status()
        assert.is_false(st.present)
        assert.equals("Cache: off", st.text)
    end)

    it("flags stale when a configured unit's launcher changed", function()
        local core = make_core()
        local unit = the_unit(core)
        -- Configure while ccache was present (recorded).
        core:record_task_result({
            unit = unit, action = "configure", success = true, build_dir = unit:build_dir(),
            module_info = { generator = "Ninja", cache_launcher = "/usr/bin/ccache" },
        })
        set_present({})  -- ccache removed → launcher disappeared
        local st = the_profile(core):compiler_cache_status()
        assert.is_true(st.stale)
    end)

    it("is nil for a profile with no C/C++-caching module", function()
        -- A typescript-only workspace: the shim declares no c/c++ language.
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { Web = { typescript = {} } },
                configuration_sets = { debug = { Web = "default" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = { debug = { configuration_set = "debug", tools = {} } },
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core:remerge()
        assert.is_nil(the_profile(core):compiler_cache_status())
    end)
end)

-- ---------------------------------------------------------------------------
-- cli._cache_stats
-- ---------------------------------------------------------------------------
describe("cli._cache_stats", function()
    local cli = require("loomworks.cli")

    it("uses `-s` for ccache and parses non-empty lines", function()
        local seen
        local out = cli._cache_stats("ccache", "/usr/bin/ccache", function(cmd)
            seen = cmd
            return "cache hit rate  42 %\n\ncache size  10 GB\n"
        end)
        assert.same({ "/usr/bin/ccache", "-s" }, seen)
        assert.same({ "cache hit rate  42 %", "cache size  10 GB" }, out)
    end)

    it("uses `--show-stats` for sccache", function()
        local seen
        cli._cache_stats("sccache", "/usr/bin/sccache", function(cmd)
            seen = cmd
            return "Compile requests  5\n"
        end)
        assert.same({ "/usr/bin/sccache", "--show-stats" }, seen)
    end)

    it("returns a note when the tool produces nothing", function()
        local out = cli._cache_stats("ccache", "/usr/bin/ccache", function() return "" end)
        assert.equals(1, #out)
        assert.matches("could not read", out[1])
    end)
end)
