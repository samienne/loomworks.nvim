--- Tests for the FRESHNESS of the post-configure compiler-cache compatibility
--- scan (core §5.1, §8 `cache_compat_scan` / `cache_compat_stamp`; cmake §5d;
--- meson §5a; headless §16.31).
---
--- Real-project scenario (Windows MSVC + Ninja, sccache): the build tool
--- re-runs the generator by itself after a CMakeLists / .cmake edit — no
--- `lw configure` — which rewrites the compile data the scan read. The recorded
--- result must follow that data: after /Zi → /Z7 the finding must go away, and
--- after re-adding /Zi it must come back (health item + failed-build closing
--- line). Driven through the REAL cmake scanner on real reply files in a temp
--- build dir; independent of the host PATH (launcher lookups are stubbed).

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local meson = require("loomworks.modules.meson")
local suggestions = require("loomworks.suggestions")
local h = require("tests.helpers")

local MSVC = { generator = "Ninja", compiler_id = "msvc-17", compiler_path = "C:/VS/cl.exe" }

local function write(path, body)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end

--- Write a CMake file-api reply (codemodel + one target) the way a (re)configure
--- does: a NEW uniquely named index file, the previous reply's index removed.
--- @param bd string build dir
--- @param index_name string e.g. "index-2026-09-25T06-43-16-0773.json"
--- @param flags string the target's compile fragment
local function write_reply(bd, index_name, flags)
    local reply = bd .. "/.cmake/api/v1/reply"
    for _, old in ipairs(vim.fn.glob(reply .. "/index-*.json", false, true)) do
        os.remove(old)
    end
    write(reply .. "/target-zlib.json", vim.json.encode({
        name = "zlib", type = "STATIC_LIBRARY",
        sources = { { path = "a.c" }, { path = "b.c" } },
        compileGroups = { {
            language = "C", sourceIndexes = { 0, 1 },
            compileCommandFragments = { { fragment = flags } },
        } },
    }))
    write(reply .. "/codemodel-v2-x.json", vim.json.encode({
        paths = { source = "C:/src/app", build = bd },
        configurations = { { name = "Debug", targets = {
            { name = "zlib", jsonFile = "target-zlib.json", id = "zlib::@1" },
        } } },
    }))
    write(reply .. "/" .. index_name, vim.json.encode({ objects = { {
        kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2-x.json",
    } } }))
end

describe("module compile-data stamps (cache_compat_stamp)", function()
    local tmp
    before_each(function() tmp = (vim.fn.tempname():gsub("\\", "/")) end)
    after_each(function() vim.fn.delete(tmp, "rf") end)

    it("cmake: the current reply's index — changes when the reply is rewritten", function()
        assert.is_nil(cmake.cache_compat_stamp({ build_dir = tmp, tool_data = MSVC }))
        write_reply(tmp, "index-2026-09-25T06-43-16-0773.json", "/Zi")
        local s1 = cmake.cache_compat_stamp({ build_dir = tmp, tool_data = MSVC })
        assert.is_string(s1)
        write_reply(tmp, "index-2026-09-25T06-43-20-0380.json", "/Z7")
        local s2 = cmake.cache_compat_stamp({ build_dir = tmp, tool_data = MSVC })
        assert.is_string(s2)
        assert.are_not.equal(s1, s2)
    end)

    it("cmake: a gcc/clang kit's scan reads nothing, so its stamp is constant", function()
        local gcc = { generator = "Ninja", compiler_id = "gcc-13" }
        local a = cmake.cache_compat_stamp({ build_dir = tmp, tool_data = gcc })
        write_reply(tmp, "index-2026-09-25T06-43-16-0773.json", "/Zi")
        assert.equals(a, cmake.cache_compat_stamp({ build_dir = tmp, tool_data = gcc }))
    end)

    it("meson: intro-targets.json's stat — changes when meson rewrites it", function()
        local td = { compiler_family = "msvc", compiler_path = "cl" }
        assert.is_nil(meson.cache_compat_stamp({ build_dir = tmp, tool_data = td }))
        write(tmp .. "/meson-info/intro-targets.json", "[]")
        local s1 = meson.cache_compat_stamp({ build_dir = tmp, tool_data = td })
        assert.is_string(s1)
        write(tmp .. "/meson-info/intro-targets.json", '[{"name":"sub","target_sources":[]}]')
        assert.are_not.equal(s1, meson.cache_compat_stamp({ build_dir = tmp, tool_data = td }))
    end)
end)

describe("cache_compat follows the build's current compile data", function()
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local orig_lookup = cpp.lookup_path
    local tmp, bd
    before_each(function()
        -- Independent of the host PATH (no real ccache/sccache lookup).
        cpp.lookup_path = function() return nil end
        tmp = (vim.fn.tempname():gsub("\\", "/"))
        bd = tmp .. "/build"
    end)
    after_each(function()
        cpp.lookup_path = orig_lookup
        vim.fn.delete(tmp, "rf")
    end)

    local notified, health_store
    local function make_core()
        -- The REAL cmake scanner; only the owned-LSP-database refresh (which
        -- needs an editor file tracker) is left out.
        local cm = setmetatable({ refresh_lsp_database = false, lsp_database_watch_path = false },
            { __index = real_modules.get("cmake") })
        local function get(id)
            if id == "cmake" then return cm end
            return id and real_modules.get(id) or nil
        end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({ profiles = {
                debug = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-msvc", data = MSVC } },
                },
            } }),
        }
        local deps = h.make_test_deps(files, { modules = { get = get }, cache = { save = function() return true end } })
        -- An in-memory health cache so the passive / health tiers can be read back.
        health_store = {}
        deps.io.read_json = function(p) return health_store[p] and vim.deepcopy(health_store[p]) or nil end
        deps.io.write_json = function(p, d) health_store[p] = vim.deepcopy(d) return true end
        notified = {}
        deps.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = { cmake = { { tool_key = "ninja-msvc", tool_data = MSVC, tool_label = "msvc" } } }
        core:remerge()
        local ws = core:get_workspace()
        ws._active_profile = ws._profiles[1]
        return core, ws, ws._profiles[1]:projects()[1]._config_unit
    end

    local function configure(core, unit)
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = bd, module_info = { cache_launcher = "C:/t/sccache.exe" } })
    end

    local function compat_items(items)
        local out = {}
        for _, s in ipairs(items) do
            if s.title:find("sccache will fail", 1, true) then out[#out + 1] = s end
        end
        return out
    end

    it("records the stamp of the compile data it scanned", function()
        local core, _, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Zi")
        configure(core, unit)
        local rec = unit.module_info.cache_compat
        assert.equals(1, #rec.findings)
        assert.equals(cmake.cache_compat_stamp({ build_dir = bd, tool_data = MSVC }), rec.source_stamp)
    end)

    it("/Zi → /Z7 via a build-tool re-run: health drops the finding and updates the record", function()
        local core, ws, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Zi")
        configure(core, unit)
        assert.equals(1, #compat_items(suggestions.collect_health(ws)))
        local s1 = unit.module_info.cache_compat.source_stamp

        -- The user switches to /Z7; ninja re-runs CMake (no lw configure).
        write_reply(bd, "index-2026-09-25T06-50-02-0112.json", "/Z7")
        assert.equals(0, #compat_items(suggestions.collect_health(ws)))
        local rec = unit.module_info.cache_compat
        assert.same({}, rec.findings)
        assert.are_not.equal(s1, rec.source_stamp)
        assert.equals("sccache", rec.tool)
    end)

    it("a record from an older lw (no stamp) is re-scanned by health", function()
        local core, ws, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Z7")
        configure(core, unit)
        -- Simulate a 0.1.29 record: a stale finding, no stamp.
        unit.module_info.cache_compat = { tool = "sccache", scanned = true, findings = {
            { severity = "error", flag = "/Zi", group = "zlib", units = 2, sample = { "a.c" } },
        } }
        assert.equals(0, #compat_items(suggestions.collect_health(ws)))
        assert.is_string(unit.module_info.cache_compat.source_stamp)
    end)

    it("/Z7 → /Zi via a build-tool re-run: health shows the finding", function()
        local core, ws, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Z7")
        configure(core, unit)
        assert.equals(0, #compat_items(suggestions.collect_health(ws)))

        write_reply(bd, "index-2026-09-25T06-50-02-0112.json", "/Zi")
        local items = compat_items(suggestions.collect_health(ws))
        assert.equals(1, #items)
        assert.matches("sccache will fail 2 compiles in App/Debug", items[1].title, 1, true)
    end)

    it("the passive count follows a re-run too (local-tier key includes the current stamp)", function()
        local core, ws, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Z7")
        configure(core, unit)
        local k1 = suggestions._local_key(ws)
        assert.equals(0, #compat_items(suggestions.collect(ws)))

        write_reply(bd, "index-2026-09-25T06-50-02-0112.json", "/Zi")
        assert.are_not.equal(k1, suggestions._local_key(ws))
        local persisted = vim.deepcopy(unit.module_info.cache_compat)
        assert.equals(1, #compat_items(suggestions.collect(ws)))
        -- The passive path never writes the build cache, so the next `lw
        -- status` process reads the record as persisted: its key must match
        -- the cached tier, which is then reused (no re-scan per status run).
        unit.module_info.cache_compat = persisted
        assert.equals(suggestions._local_key(ws),
            health_store["/root/.nvim/loomworks.health.json"].local_tier.key)
        assert.equals(1, #compat_items(suggestions.collect(ws)))
    end)

    it("a build (ninja re-ran CMake) refreshes the record and reports the new finding", function()
        local core, _, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Z7")
        configure(core, unit)
        notified = {}
        write_reply(bd, "index-2026-09-25T06-50-02-0112.json", "/Zi")
        core:record_task_result({ unit = unit, action = "build", success = false })
        assert.equals(1, #unit.module_info.cache_compat.findings)
        local hit
        for _, n in ipairs(notified) do if n.msg:find("sccache will FAIL", 1, true) then hit = n end end
        assert.is_not_nil(hit)
        -- A build that did NOT re-run the generator re-reads nothing and says nothing.
        notified = {}
        core:record_task_result({ unit = unit, action = "build", success = false })
        assert.equals(0, #notified)
    end)

    it("`lw build`: a failed build after a ninja-triggered re-run to /Zi prints the closing line", function()
        local core, ws, unit = make_core()
        write_reply(bd, "index-2026-09-25T06-43-16-0773.json", "/Z7")
        configure(core, unit)
        local cli = require("loomworks.cli")
        local overseer = require("loomworks.overseer")
        local profile = ws._profiles[1]
        local orig_plan, orig_spawn = overseer.plan_profile_build, cli._run_spec
        overseer.plan_profile_build = function()
            return { { kind = "build", name = "App/Debug", unit = unit, cmd = { "ninja" } } }
        end
        -- The build tool re-runs CMake (new reply with /Zi), then C1041 fails.
        cli._run_spec = function()
            write_reply(bd, "index-2026-09-25T06-50-02-0112.json", "/Zi")
            return 2
        end
        local orig_assert = profile.assert_buildable
        profile.assert_buildable = function() return true end
        local err_buf, rs, rex, rw = {}, io.stderr, os.exit, io.write
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
        io.write = function() end
        local code
        os.exit = function(c) code = c; error({ __exit = true }, 0) end
        local ok, e = pcall(function() cli._run_build_steps(profile, ws, {}) end)
        io.stderr, os.exit, io.write = rs, rex, rw
        overseer.plan_profile_build, cli._run_spec = orig_plan, orig_spawn
        profile.assert_buildable = orig_assert
        assert.is_true(ok or (type(e) == "table" and e.__exit), tostring(e))
        assert.equals(2, code)
        local text = table.concat(err_buf)
        assert.matches("lw: build failed %(exit 2%): App/Debug\nlw: build failed — 2 compiles use /Zi", text)
    end)
end)
