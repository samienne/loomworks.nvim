--- Compiler-cache launcher NOT applicable (cmake §5d non-goals, core §8
--- `cache_launcher_applicable`): CMake honors CMAKE_<LANG>_COMPILER_LAUNCHER
--- only for Ninja and Makefile generators, and a preset owns its own cache
--- variables. For those configurations the module injects nothing, records
--- "none", reports `false, reason, hint`, and status / health say
--- `not applied (<reason>)` instead of naming a launcher the build ignores.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local cmake = require("loomworks.modules.cmake")
local cpp = require("loomworks.cpp_compilers")
local h = require("tests.helpers")

local orig_lookup = cpp.lookup_path
local function set_present(present)
    cpp.lookup_path = function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

local function find_configure(tasks)
    for _, t in ipairs(tasks) do
        if t.loomworks and t.loomworks.action == "configure" then return t end
    end
end

local function has_prefix(cmd, prefix)
    for _, a in ipairs(cmd) do if a:sub(1, #prefix) == prefix then return true end end
    return false
end

describe("cmake cache_launcher_applicable", function()
    local function applicable(cfg_mc, tool_data, from_preset)
        return cmake.cache_launcher_applicable({
            configuration = { from_preset = from_preset or false, module_config = cfg_mc or {} },
            tool_data = tool_data,
        })
    end

    it("Ninja, Ninja Multi-Config and Makefile generators are applicable", function()
        for _, g in ipairs({ "Ninja", "Ninja Multi-Config", "Unix Makefiles",
                "NMake Makefiles", "MinGW Makefiles" }) do
            assert.is_true(applicable(nil, { generator = g }), g)
        end
    end)

    it("an unknown (unresolved) generator is treated as applicable", function()
        assert.is_true(applicable(nil, {}))
    end)

    it("Visual Studio is not applicable, with a reason naming the generator and a hint", function()
        local ok, reason, hint = applicable(nil, { generator = "Visual Studio 17 2022" })
        assert.is_false(ok)
        assert.equals("Visual Studio 17 2022 generator", reason)
        assert.matches("Ninja or Makefile generator", hint)
    end)

    it("Xcode is not applicable", function()
        local ok, reason = applicable(nil, { generator = "Xcode" })
        assert.is_false(ok)
        assert.equals("Xcode generator", reason)
    end)

    it("a configuration's own generator wins over the tool's", function()
        assert.is_false((applicable({ generator = "Xcode" }, { generator = "Ninja" })))
        assert.is_true((applicable({ generator = "Ninja" }, { generator = "Visual Studio 17 2022" })))
    end)

    it("a preset is not applicable (reason 'preset')", function()
        local ok, reason, hint = applicable(nil, { generator = "Ninja" }, true)
        assert.is_false(ok)
        assert.equals("preset", reason)
        assert.matches("cacheVariables", hint)
    end)
end)

describe("cmake tasks under a Visual Studio generator", function()
    before_each(function()
        cmake._warned = {}
        cmake._cmake_version_cache = { ["/fake/cmake"] = { major = 3, minor = 28 } }
    end)

    local VS = { generator = "Visual Studio 17 2022", compiler_id = "msvc-17",
        cmake_path = "/fake/cmake" }

    local function vs_ctx(extra)
        local c = {
            name = "App", path = "App", workspace_root = "/fake/root",
            configurations = { Debug = { variant = "Debug" } },
            type_config = {}, tool_data = VS,
            cached_build_dir = "/fake/root/App/build",
            compiler_cache = { tool = "sccache", path = "/x/sccache" },
        }
        for k, v in pairs(extra or {}) do c[k] = v end
        return c
    end

    it("injects no launcher and no debug-info keys, records 'none', warns once", function()
        local warned = {}
        local orig = vim.notify
        vim.notify = function(msg) warned[#warned + 1] = msg end
        local t = find_configure(cmake.tasks(vs_ctx(), "Debug"))
        find_configure(cmake.tasks(vs_ctx(), "Debug"))
        vim.wait(50, function() return #warned > 0 end)
        vim.notify = orig
        local cmd = t.builder().cmd
        assert.is_false(has_prefix(cmd, "-DCMAKE_C_COMPILER_LAUNCHER"))
        assert.is_false(has_prefix(cmd, "-DCMAKE_CXX_COMPILER_LAUNCHER"))
        assert.is_false(has_prefix(cmd, "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT"))
        assert.equals("none", t.loomworks.module_info.cache_launcher)
        assert.equals(1, #warned)
        assert.matches("Visual Studio 17 2022", warned[1])
    end)

    it("a current record with a launcher under VS retracts it in place (-U, no --fresh)", function()
        local t = find_configure(cmake.tasks(vs_ctx({
            recorded_cache_launcher = "/x/sccache",
            recorded_module_info = { generator = "Visual Studio 17 2022", cache_launcher = "/x/sccache",
                record_version = cmake.configure_record_version,
                passed_options = {
                    CMAKE_C_COMPILER_LAUNCHER = "/x/sccache",
                    CMAKE_CXX_COMPILER_LAUNCHER = "/x/sccache",
                } },
        }), "Debug"))
        local cmd = t.builder().cmd
        local u = {}
        for _, a in ipairs(cmd) do if a:match("^%-U") then u[#u + 1] = a end end
        table.sort(u)
        assert.same({ "-UCMAKE_CXX_COMPILER_LAUNCHER", "-UCMAKE_C_COMPILER_LAUNCHER" }, u)
        for _, a in ipairs(cmd) do assert.is_not.equals("--fresh", a) end
    end)
end)

describe("status and health for a not-applicable configuration", function()
    after_each(function() cpp.lookup_path = orig_lookup end)

    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local suggestions = require("loomworks.suggestions")
    local function modules_get(id) return id and real_modules.get(id) or nil end

    local VS_TOOL = {
        compiler_id = "msvc-19.40", generator = "Visual Studio 17 2022",
        compiler_path = "C:/VS/VC/bin/cl.exe", vcvarsall = "C:/VS/vcvarsall.bat",
    }

    local function make_ws(cfg_extra, tool_data)
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = cfg_extra or {} } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = { debug = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "vs-msvc", data = tool_data } },
                } },
            }),
        }
        local deps = h.make_test_deps(files, {
            modules = { get = modules_get },
            cache = { save = function() return true end },
        })
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = { cmake = { {
            tool_key = "vs-msvc", tool_data = tool_data, tool_label = "msvc",
        } } }
        core:remerge()
        local ws = core:get_workspace()
        ws._active_profile = ws._profiles[1]
        return ws
    end

    local EXPLICIT = { configurations = { Debug = {
        overrides = { msvc = { cache = "sccache" } },
    } } }

    it("the profile row reads 'Cache: not applied (<generator> generator)'", function()
        local ws = make_ws(EXPLICIT, VS_TOOL)
        set_present({ sccache = true })
        local st = ws._active_profile:compiler_cache_status()
        assert.is_false(st.applicable)
        assert.equals("Visual Studio 17 2022 generator", st.not_applied_reason)
        assert.equals("Cache: not applied (Visual Studio 17 2022 generator)", st.text)
        assert.is_false(st.stale)
    end)

    it("policy off still reads 'Cache: off'", function()
        local ws = make_ws({ configurations = { Debug = { variables = { cache = "off" } } } }, VS_TOOL)
        set_present({ sccache = true })
        assert.equals("Cache: off", ws._active_profile:compiler_cache_status().text)
    end)

    it("health reports an info item with the module's hint, not 'using sccache'", function()
        local ws = make_ws(EXPLICIT, VS_TOOL)
        set_present({ sccache = true })
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.equals("Compiler cache not applied (Visual Studio 17 2022 generator)", out[1].title)
        assert.matches("Ninja or Makefile generator", out[1].detail)
        assert.equals(0, suggestions.count_actionable(ws))
    end)

    it("the info item appears even when no cache is installed (installing would not help)", function()
        local ws = make_ws(EXPLICIT, VS_TOOL)
        set_present({})
        local out = suggestions.compiler_cache_provider(ws)
        assert.equals(1, #out)
        assert.equals("info", out[1].kind)
        assert.matches("not applied", out[1].title)
    end)
end)
