--- Post-configure /Zi scan UX (tester feedback, headless §16.31 / cmake §5d):
---   * a finding covering (nearly) every compiled unit collapses to one line
---     naming the likely directory-wide cause, not one line per target, and does
---     not recommend a per-target fix;
---   * sample paths are shortened;
---   * "turn caching off" names the mechanism that enabled the cache (profile
---     fill / compiler-family override / configuration variable);
---   * a build that fails after an error-severity finding closes with one line
---     pointing back at it.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local cc = require("loomworks.compiler_cache")
local cpp = require("loomworks.cpp_compilers")
local cmake = require("loomworks.modules.cmake")
local variables = require("loomworks.variables")
local suggestions = require("loomworks.suggestions")
local h = require("tests.helpers")

local MSVC = { generator = "Ninja", compiler_id = "msvc-17", compiler_path = "C:/VS/cl.exe" }

local function write(path, body)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end

--- A compat record with `n` targets of 10 /Zi units each, out of `total` units.
local function record(n, total, targets)
    local findings = {}
    for i = 1, n do
        findings[#findings + 1] = { severity = "error", flag = "/Zi", group = "t" .. i,
            units = 10, sample = { "C:/very/long/source/tree/_deps/lib" .. i .. "/src/a.c" } }
    end
    return { tool = "sccache", scanned = true, findings = findings,
        totals = { units = total, targets = targets },
        advice = { cause_pervasive = "likely a directory-wide add_compile_options",
            fix_pervasive = "remove it (D9025)", fix_targets = "per-target fix" } }
end

describe("pervasive /Zi findings collapse", function()
    it("every unit → one line, no per-target lines, no per-target advice", function()
        local rec = record(5, 50, 5)
        assert.is_true((cc.compat_pervasive(rec)))
        local lines = cc.compat_group_lines(rec)
        assert.equals(1, #lines)
        assert.equals("every target (50 units) compiles with /Zi — likely a "
            .. "directory-wide add_compile_options", lines[1])
        local msg = cc.compat_message(rec, "App", "Debug")
        assert.matches("remove it (D9025)", msg, 1, true)
        assert.is_nil(msg:find("per-target fix", 1, true))
    end)

    it("≥90% → `nearly every target` with the counts", function()
        local rec = record(19, 200, 21)
        local lines = cc.compat_group_lines(rec)
        assert.equals(1, #lines)
        assert.matches("nearly every target (190 of 200 units, 19 of 21 targets) "
            .. "compiles with /Zi", lines[1], 1, true)
    end)

    it("a minority keeps one line per target, sample paths shortened", function()
        local rec = record(2, 500, 40)
        assert.is_false((cc.compat_pervasive(rec)))
        local lines = cc.compat_group_lines(rec)
        assert.equals(2, #lines)
        assert.equals("t1: 10 units (/Zi) — …/src/a.c", lines[1])
        local msg = cc.compat_message(rec, "App", "Debug")
        assert.matches("per-target fix", msg, 1, true)
    end)

    it("environment findings are kept next to a collapsed line", function()
        local rec = record(3, 30, 3)
        rec.findings[#rec.findings + 1] = { severity = "error", flag = "/Zi",
            group = "environment", sample = { "CL" } }
        local lines = cc.compat_group_lines(rec)
        assert.equals(2, #lines)
        assert.equals("environment: every compile (/Zi) — CL", lines[2])
        assert.matches("env.CL", cc.compat_message(rec, "App", "Debug"), 1, true)
    end)

    it("the cmake scan reports totals and its advice (D9025, C1090, no per-target property)", function()
        local tmp = (vim.fn.tempname():gsub("\\", "/"))
        local bd = tmp .. "/build"
        local reply = bd .. "/.cmake/api/v1/reply"
        local trefs = {}
        for i = 1, 3 do
            local jf = "target-t" .. i .. ".json"
            trefs[#trefs + 1] = { name = "t" .. i, jsonFile = jf }
            write(reply .. "/" .. jf, vim.json.encode({
                name = "t" .. i, sources = { { path = "a.c" }, { path = "b.c" } },
                compileGroups = { { language = "C", sourceIndexes = { 0, 1 },
                    compileCommandFragments = { { fragment = "/Z7 /Zi" } } } },
            }))
        end
        write(reply .. "/codemodel-v2-x.json", vim.json.encode({
            paths = { source = "C:/src", build = bd },
            configurations = { { name = "Debug", targets = trefs } },
        }))
        write(reply .. "/index-1.json", vim.json.encode({ objects = { {
            kind = "codemodel", version = { major = 2, minor = 0 }, jsonFile = "codemodel-v2-x.json",
        } } }))
        local res = cmake.cache_compat_scan({ build_dir = bd, tool_data = MSVC, variant = "Debug",
            compiler_cache = { tool = "sccache", path = "/x/sccache" } })
        vim.fn.delete(tmp, "rf")
        assert.same({ units = 6, targets = 3 }, res.totals)
        local rec = cc.run_compat_scan({ cache_compat_scan = function() return res end },
            {}, "/x/sccache")
        local lines = cc.compat_group_lines(rec)
        assert.equals(1, #lines)
        assert.matches("^every target %(6 units%) compiles with /Zi — likely a directory%-wide "
            .. "add_compile_options or CMAKE_<LANG>_FLAGS", lines[1])
        local msg = cc.compat_message(rec, "App", "Debug")
        assert.matches("D9025", msg, 1, true)
        assert.matches("overriding '/Z7' with '/Zi'", msg, 1, true)
        assert.matches("C1041 / C1090", msg, 1, true)
        assert.is_nil(msg:find("MSVC_DEBUG_INFORMATION_FORMAT", 1, true))
    end)
end)

describe("cache policy provenance", function()
    local project = { key = "App", variables = {} }

    it("names the layer that supplied the policy", function()
        local base = { name = "Base", variables = { cache = "sccache" } }
        local cfg = { name = "Debug", _inherits = { base }, _overrides = { msvc = { cache = "ccache" } } }
        local _, src = variables.resolve_cache_policy(project, cfg, "msvc", nil)
        assert.equals("override", src.layer)
        assert.equals(cfg, src.configuration)
        assert.equals("msvc", src.family)
        _, src = variables.resolve_cache_policy(project, cfg, "gcc", nil)
        assert.equals("configuration", src.layer)
        assert.equals(base, src.configuration)
        local profile = { key = "dev", variable_value = function() return "sccache" end }
        _, src = variables.resolve_cache_policy(project, { name = "X" }, "msvc", profile)
        assert.equals("profile", src.layer)
        assert.equals(profile, src.profile)
        _, src = variables.resolve_cache_policy(project, { name = "X" }, "msvc", nil)
        assert.equals("default", src.layer)
    end)

    it("the off command points at that mechanism", function()
        local function off(source) return cc.cache_off_command({ policy_source = source }, "App", "Debug") end
        assert.equals("lw profile set dev App cache off", off({ layer = "profile", profile = "dev" }))
        assert.equals("lw config set App Base overrides.msvc.cache off",
            off({ layer = "override", configuration = "Base", family = "msvc" }))
        assert.equals("lw config set App Base variables.cache off",
            off({ layer = "configuration", configuration = "Base" }))
        assert.equals("lw config set App Debug variables.cache off", off(nil))
    end)
end)

describe("recorded provenance → configure message, health remedy", function()
    local Core = require("loomworks.core")
    local real_modules = require("loomworks.modules")
    local orig_lookup = cpp.lookup_path
    after_each(function() cpp.lookup_path = orig_lookup end)

    local FINDINGS = { { severity = "error", flag = "/Zi", group = "zlib", units = 3, sample = { "a.c" } } }

    local function make_core()
        local fake_cmake = setmetatable({
            cache_compat_scan = function() return { scanned = true, findings = FINDINGS } end,
        }, { __index = real_modules.get("cmake") })
        local function get(id)
            if id == "cmake" then return fake_cmake end
            return id and real_modules.get(id) or nil
        end
        local files = {
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = {} } },
                configuration_sets = { debug = { App = "Debug" } },
            }),
            ["loomworks.user.json"] = h.make_user_json({
                profiles = { debug = { configuration_set = "debug",
                    tools = { cmake = { key = "ninja-msvc", data = MSVC } } } },
                profile_variables = { ["debug:ninja-msvc"] = { App = { cache = "sccache" } } },
            }),
        }
        local deps = h.make_test_deps(files, { modules = { get = get }, cache = { save = function() return true end } })
        local notified = {}
        deps.notify = function(msg, level) notified[#notified + 1] = { msg = msg, level = level } end
        local core = Core.new(deps)
        core:setup({ root = "/root" })
        core._workspace._tools_by_type = { cmake = { { tool_key = "ninja-msvc", tool_data = MSVC, tool_label = "msvc" } } }
        core:remerge()
        local ws = core:get_workspace()
        return core, ws, ws._profiles[1], notified
    end

    it("a profile-fill opt-in (non-active profile) points at `lw profile set … cache off`", function()
        cpp.lookup_path = function(n) return n == "sccache" and "/x/sccache" or nil end
        local core, ws, profile, notified = make_core()
        assert.is_nil(ws._active_profile)
        local unit = profile:projects()[1]._config_unit
        core:record_task_result({ unit = unit, action = "configure", success = true, profile = profile,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        local rec = unit.module_info.cache_compat
        assert.same({ layer = "profile", profile = profile.key }, rec.policy_source)
        local hit
        for _, n in ipairs(notified) do if n.msg:find("sccache will FAIL", 1, true) then hit = n.msg end end
        assert.is_truthy(hit)
        assert.matches("lw profile set " .. profile.key .. " App cache off", hit, 1, true)
        assert.is_nil(hit:find("variables.cache off", 1, true))
        local items = suggestions.cache_compat_provider(ws)
        assert.equals(1, #items)
        assert.matches("lw profile set " .. profile.key .. " App cache off", items[1].remedy, 1, true)
    end)
end)

describe("a build failing after an error-severity finding", function()
    it("compat_failure_hint names the count and points back", function()
        local hint = cc.compat_failure_hint(record(2, 500, 40))
        assert.equals("build failed — 20 compiles use /Zi, which sccache will fail "
            .. "(see the scan finding above; lw health; lw help cache)", hint)
        local warn = record(1, 10, 1)
        warn.findings[1].severity = "warning"
        assert.is_nil(cc.compat_failure_hint(warn))
        assert.is_nil(cc.compat_failure_hint(nil))
    end)

    it("`lw build` prints the closing line after the failed build step", function()
        local cli = require("loomworks.cli")
        local unit = { module_info = { cache_compat = record(2, 500, 40) } }
        local profile = { key = "p", assert_buildable = function() return true end, projects = function() return {} end }
        local ws = { root = "/ws", record_task_result = function() end }
        local overseer = require("loomworks.overseer")
        local orig_plan, orig_spawn = overseer.plan_profile_build, cli._run_spec
        overseer.plan_profile_build = function()
            return { { kind = "build", name = "App/Debug", unit = unit, cmd = { "ninja" } } }
        end
        cli._run_spec = function() return 2 end
        local err_buf, rs, rex = {}, io.stderr, os.exit
        io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
        local rw = io.write
        io.write = function() end
        local code
        os.exit = function(c) code = c; error({ __exit = true }, 0) end
        local ok, e = pcall(function() cli._run_build_steps(profile, ws, {}) end)
        io.stderr, os.exit, io.write = rs, rex, rw
        overseer.plan_profile_build, cli._run_spec = orig_plan, orig_spawn
        assert.is_true(ok or (type(e) == "table" and e.__exit), tostring(e))
        assert.equals(2, code)
        local text = table.concat(err_buf)
        assert.matches("lw: build failed %(exit 2%): App/Debug\nlw: build failed — 20 compiles use /Zi", text)
    end)
end)
