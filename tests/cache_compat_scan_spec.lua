--- Tests for the post-configure compiler-cache compatibility scan (core §5.1,
--- §8 `cache_compat_scan`; cmake §5d; meson §5a): the shared PDB-flag helpers,
--- the cmake (file-api codemodel) and meson (intro-targets.json) scanners, core's
--- recording in record_task_result, and the health items.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local cpp = require("loomworks.cpp_compilers")
local cc = require("loomworks.compiler_cache")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")
local suggestions = require("loomworks.suggestions")
local h = require("tests.helpers")

local function write(path, body)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end

local MSVC = { generator = "Ninja", compiler_id = "msvc-17", compiler_path = "C:/VS/cl.exe" }
local GCC = { generator = "Ninja", compiler_id = "gcc-13" }

describe("PDB debug-flag helpers", function()
    it("detects /Zi, /ZI, -Zi, -ZI but not /Z7", function()
        assert.equals("/Zi", cpp.pdb_debug_flag({ "/O2", "/Zi" }))
        assert.equals("-ZI", cpp.pdb_debug_flag({ "-ZI" }))
        assert.is_nil(cpp.pdb_debug_flag({ "/Z7", "/Zc:inline" }))
    end)

    it("aggregates per group with counts, samples and launcher severity", function()
        local acc = {}
        for i = 1, 5 do cpp.pdb_scan_add(acc, "zlib", "/Zi", "z" .. i .. ".c") end
        cpp.pdb_scan_add(acc, "app", "/ZI", "main.cpp")
        local f = cpp.pdb_scan_findings(acc, "sccache")
        assert.equals(2, #f)
        assert.equals("app", f[1].group)
        assert.equals("zlib", f[2].group)
        assert.equals(5, f[2].units)
        assert.equals(3, #f[2].sample)
        assert.equals("error", f[1].severity)
        assert.equals("warning", cpp.pdb_scan_findings(acc, "ccache")[1].severity)
    end)
end)

describe("cmake.cache_compat_scan", function()
    local tmp, bd
    local function write_reply(targets)
        local reply = bd .. "/.cmake/api/v1/reply"
        local trefs = {}
        for _, t in ipairs(targets) do
            local jf = "target-" .. t.name .. ".json"
            trefs[#trefs + 1] = { name = t.name, jsonFile = jf, id = t.name .. "::@1" }
            local sources, sidx = {}, {}
            for j, s in ipairs(t.sources) do
                sources[#sources + 1] = { path = s }
                sidx[#sidx + 1] = j - 1
            end
            write(reply .. "/" .. jf, vim.json.encode({
                name = t.name, type = "STATIC_LIBRARY", sources = sources,
                compileGroups = { {
                    language = "CXX", sourceIndexes = sidx,
                    compileCommandFragments = { { fragment = t.flags } },
                } },
            }))
        end
        write(reply .. "/codemodel-v2-x.json", vim.json.encode({
            paths = { source = "C:/src/app", build = bd },
            configurations = { { name = "Debug", targets = trefs } },
        }))
        write(reply .. "/index-2025.json", vim.json.encode({ objects = { {
            kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2-x.json",
        } } }))
    end
    before_each(function()
        tmp = (vim.fn.tempname():gsub("\\", "/"))
        bd = tmp .. "/build"
    end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("reports each target whose compile fragments carry /Zi (dependencies included)", function()
        write_reply({
            { name = "app", flags = "/DWIN32 /Z7 /Ob0", sources = { "main.cpp" } },
            { name = "zlib", flags = "/DWIN32 /Zi /Ob0", sources = { "_deps/zlib/a.c", "_deps/zlib/b.c" } },
        })
        local r = cmake.cache_compat_scan({
            build_dir = bd, tool_data = MSVC, variant = "Debug",
            compiler_cache = { tool = "sccache", path = "/x/sccache" },
        })
        assert.is_true(r.scanned)
        assert.equals(1, #r.findings)
        local f = r.findings[1]
        assert.equals("zlib", f.group)
        assert.equals("/Zi", f.flag)
        assert.equals(2, f.units)
        assert.equals("error", f.severity)
        assert.equals("C:/src/app/_deps/zlib/a.c", f.sample[1])
    end)

    it("ccache findings are warnings", function()
        write_reply({ { name = "zlib", flags = "-Zi", sources = { "a.c" } } })
        local r = cmake.cache_compat_scan({ build_dir = bd, tool_data = MSVC,
            compiler_cache = { tool = "ccache", path = "/x/ccache" } })
        assert.equals("warning", r.findings[1].severity)
    end)

    it("is clean when every target uses /Z7", function()
        write_reply({ { name = "app", flags = "/Z7", sources = { "main.cpp" } } })
        local r = cmake.cache_compat_scan({ build_dir = bd, tool_data = MSVC,
            compiler_cache = { tool = "sccache", path = "/x/sccache" } })
        assert.is_true(r.scanned)
        assert.same({}, r.findings)
    end)

    it("is skipped (scanned = false, with a reason) without a codemodel reply", function()
        local r = cmake.cache_compat_scan({ build_dir = bd, tool_data = MSVC,
            compiler_cache = { tool = "sccache", path = "/x/sccache" } })
        assert.is_false(r.scanned)
        assert.is_string(r.reason)
    end)

    it("reports clean for a gcc kit without reading anything", function()
        local r = cmake.cache_compat_scan({ build_dir = bd, tool_data = GCC,
            compiler_cache = { tool = "ccache", path = "/x/ccache" } })
        assert.is_true(r.scanned)
        assert.same({}, r.findings)
    end)
end)

describe("meson.cache_compat_scan", function()
    local tmp
    before_each(function() tmp = (vim.fn.tempname():gsub("\\", "/")) end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("reads meson-info/intro-targets.json and reports /Zi targets", function()
        write(tmp .. "/meson-info/intro-targets.json", vim.json.encode({
            { name = "app", target_sources = { {
                language = "cpp", parameters = { "/Z7" }, sources = { "C:/s/main.cpp" } } } },
            { name = "sub", target_sources = { {
                language = "c", parameters = { "/Zi", "/Od" }, sources = { "C:/s/a.c", "C:/s/b.c" } } } },
        }))
        local r = meson.cache_compat_scan({ build_dir = tmp,
            tool_data = { compiler_family = "msvc", compiler_path = "cl" },
            compiler_cache = { tool = "sccache", path = "/x/sccache" } })
        assert.is_true(r.scanned)
        assert.equals(1, #r.findings)
        assert.equals("sub", r.findings[1].group)
        assert.equals(2, r.findings[1].units)
        assert.equals("error", r.findings[1].severity)
    end)

    it("is skipped without introspection data", function()
        local r = meson.cache_compat_scan({ build_dir = tmp,
            tool_data = { compiler_family = "clang-cl" },
            compiler_cache = { tool = "sccache", path = "/x/sccache" } })
        assert.is_false(r.scanned)
        assert.matches("intro%-targets", r.reason)
    end)
end)

describe("compiler_cache.run_compat_scan / compat_message", function()
    it("does not run without an applied launcher or without the hook", function()
        local called = false
        local impl = { cache_compat_scan = function() called = true return { scanned = true, findings = {} } end }
        assert.is_nil(cc.run_compat_scan(impl, {}, "none"))
        assert.is_nil(cc.run_compat_scan(impl, {}, nil))
        assert.is_nil(cc.run_compat_scan({}, {}, "/x/sccache"))
        assert.is_false(called)
    end)

    it("passes the applied launcher and records a throwing hook as skipped", function()
        local seen
        local rec = cc.run_compat_scan({ cache_compat_scan = function(ctx)
            seen = ctx
            return { scanned = true, findings = {} }
        end }, { build_dir = "/b" }, "C:/tools/sccache.exe")
        assert.equals("sccache", seen.compiler_cache.tool)
        assert.equals("sccache", rec.tool)
        assert.is_true(rec.scanned)
        local bad = cc.run_compat_scan({ cache_compat_scan = function() error("boom") end }, {}, "/x/ccache")
        assert.is_false(bad.scanned)
        assert.matches("boom", bad.reason)
    end)

    it("formats an error-severity message naming groups and both remedies", function()
        local msg, sev = cc.compat_message({ tool = "sccache", scanned = true, findings = {
            { severity = "error", flag = "/Zi", group = "zlib", units = 2, sample = { "a.c" } },
        } }, "App", "Debug")
        assert.equals("error", sev)
        assert.matches("sccache will FAIL", msg)
        assert.matches("zlib: 2 units %(/Zi%)", msg)
        assert.matches("lw config set App Debug variables.cache off", msg, 1, true)
        assert.is_nil((cc.compat_message({ tool = "sccache", scanned = true, findings = {} }, "A", "B")))
    end)
end)

-- ---------------------------------------------------------------------------
-- Core recording (record_task_result) + health items
-- ---------------------------------------------------------------------------
describe("cache_compat recording and health", function()
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local orig_lookup = cpp.lookup_path
    after_each(function() cpp.lookup_path = orig_lookup end)

    local scan_result
    local notified
    --- `opts.no_active`: leave no profile active; `opts.second_profile`: a
    --- second profile (set `debug2`) mapping the SAME App/Debug unit.
    local function make_core(opts)
        opts = opts or {}
        local fake_cmake = setmetatable({
            cache_compat_scan = function() return scan_result end,
        }, { __index = real_modules.get("cmake") })
        local function get(id)
            if id == "cmake" then return fake_cmake end
            return id and real_modules.get(id) or nil
        end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" }, debug2 = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({ profiles = {
                debug = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-msvc", data = MSVC } },
                },
                debug2 = opts.second_profile and {
                    configuration_set = "debug2",
                    tools = { cmake = { key = "ninja-msvc", data = MSVC } },
                } or nil,
            } }),
        }
        local deps = h.make_test_deps(files, { modules = { get = get }, cache = { save = function() return true end } })
        notified = {}
        deps.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = { cmake = { { tool_key = "ninja-msvc", tool_data = MSVC, tool_label = "msvc" } } }
        core:remerge()
        local ws = core:get_workspace()
        if not opts.no_active then ws._active_profile = ws._profiles[1] end
        return core, ws, ws._profiles[1]:projects()[1]._config_unit
    end

    local FINDINGS = { { severity = "error", flag = "/Zi", group = "zlib", units = 3, sample = { "a.c" } } }

    it("records findings after a successful configure that applied a launcher and prints an error", function()
        local core, _, unit = make_core()
        scan_result = { scanned = true, findings = FINDINGS }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "C:/t/sccache.exe" } })
        local rec = unit.module_info.cache_compat
        assert.equals("sccache", rec.tool)
        assert.equals(1, #rec.findings)
        local found
        for _, n in ipairs(notified) do
            if n.msg:match("sccache will FAIL") then found = n end
        end
        assert.is_not_nil(found)
        assert.equals(vim.log.levels.ERROR, found.level)
    end)

    it("drops the record when a reconfigure applies no launcher, or fails", function()
        local core, _, unit = make_core()
        scan_result = { scanned = true, findings = FINDINGS }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        assert.is_not_nil(unit.module_info.cache_compat)
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        assert.is_nil(unit.module_info.cache_compat)
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        core:record_task_result({ unit = unit, action = "configure", success = false,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        assert.is_nil(unit.module_info.cache_compat)
    end)

    it("health: an actionable item per configuration with both remedies (not gating)", function()
        local core, ws, unit = make_core()
        scan_result = { scanned = true, findings = FINDINGS }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        local items = suggestions.cache_compat_provider(ws)
        assert.equals(1, #items)
        assert.equals("suggestion", items[1].kind)
        assert.matches("sccache will fail 3 compiles in App/Debug", items[1].title, 1, true)
        assert.matches("zlib: 3 units", items[1].detail, 1, true)
        assert.matches("/Z7", items[1].remedy, 1, true)
        assert.matches("lw config set App Debug variables.cache off", items[1].remedy, 1, true)
        assert.matches("lw help cache", items[1].remedy, 1, true)
    end)

    -- `lw health` with no active profile (a CI / scripted checkout) must still
    -- surface a recorded /Zi finding — every profile's units are considered,
    -- and a unit shared by several profiles is reported once.
    it("health with no active profile reports every profile's findings, once per unit", function()
        local core, ws, unit = make_core({ no_active = true, second_profile = true })
        assert.is_nil(ws._active_profile)
        assert.equals(2, #ws._profiles)
        assert.equals(unit, ws._profiles[2]:projects()[1]._config_unit)
        scan_result = { scanned = true, findings = FINDINGS }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        local items = suggestions.cache_compat_provider(ws)
        assert.equals(1, #items)
        assert.matches("sccache will fail 3 compiles in App/Debug", items[1].title, 1, true)
    end)

    it("health: a skipped scan is an informational item", function()
        local core, ws, unit = make_core()
        scan_result = { scanned = false, reason = "no codemodel", findings = {} }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        local items = suggestions.cache_compat_provider(ws)
        assert.equals(1, #items)
        assert.equals("info", items[1].kind)
        assert.matches("skipped", items[1].title)
        assert.matches("no codemodel", items[1].detail)
    end)

    it("the local-tier fingerprint changes when a scan result is recorded", function()
        local core, ws, unit = make_core()
        local before = suggestions._local_key(ws)
        scan_result = { scanned = true, findings = FINDINGS }
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        assert.are_not.equal(before, suggestions._local_key(ws))
    end)
end)
