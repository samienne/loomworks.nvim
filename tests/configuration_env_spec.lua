--- Configuration `env` (spec §1.3.3): a generic configuration field (name →
--- value) that follows the inheritance chain and compiler-family
--- `overrides.<family>.env`, expands like option values, is layered on top of
--- the tool env for configure/build/test tasks, strips reserved compiler-driver
--- names, is recorded by core at configure (`module_info.configure_env`) and
--- makes a changed unit stale. Plus the CLI grammar (`env.<NAME>`,
--- `overrides.<family>.env.<NAME>`, unknown dotted params rejected) and the
--- `CL` / `_CL_` compat-scan check.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local real_modules = require("loomworks.modules")
local config_env = require("loomworks.config_env")
local Configuration = require("loomworks.configuration")
local variables = require("loomworks.variables")
local cli = require("loomworks.cli")

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

--- A bare Configuration (no project) with resolved inherits.
local function cfg(name, data, inherits)
    local c = Configuration.new(nil, name, data)
    c._inherits = inherits or {}
    return c
end

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------
describe("config_env.merged", function()
    it("merges the chain: bases depth-first, own entries win", function()
        local base = cfg("base", { env = { A = "base", B = "base" } })
        local mid = cfg("mid", { env = { B = "mid", C = "mid" } }, { base })
        local own = cfg("own", { env = { C = "own" } }, { mid })
        assert.same({ A = "base", B = "mid", C = "own" }, config_env.merged(own, "gcc"))
    end)

    it("applies overrides.<family>.env only for the matching family", function()
        local c = cfg("c", {
            env = { DIR = "plain" },
            overrides = { msvc = { env = { DIR = "msvc" } } },
        })
        assert.same({ DIR = "msvc" }, config_env.merged(c, "msvc"))
        assert.same({ DIR = "plain" }, config_env.merged(c, "gcc"))
        assert.same({ DIR = "plain" }, config_env.merged(c, nil))
    end)

    it("a nearer plain value shadows a farther family entry (chain dominates)", function()
        local base = cfg("base", { overrides = { msvc = { env = { DIR = "base-msvc" } } } })
        local own = cfg("own", { env = { DIR = "own-plain" } }, { base })
        assert.same({ DIR = "own-plain" }, config_env.merged(own, "msvc"))
    end)

    it("is empty without a configuration", function()
        assert.same({}, config_env.merged(nil, "gcc"))
    end)
end)

describe("config_env.resolve", function()
    it("expands built-ins and resolved project variables, strips reserved names", function()
        local project = {
            key = "App", path = "app",
            variables = { cache_dir = { type = "path", default = "${workspace_root}/.cache" } },
        }
        local c = cfg("Debug", { env = {
            SCCACHE_DIR = "${cache_dir}/sccache",
            WHERE = "${project_path}",
            CC = "/evil/gcc",
        } })
        c._project = project
        local env, stripped = config_env.resolve(project, c, "gcc", nil, "/ws")
        assert.same({ SCCACHE_DIR = "/ws/.cache/sccache", WHERE = "app" }, env)
        assert.same({ "CC" }, stripped)
    end)

    it("compose layers the configuration env over the tool env", function()
        assert.same({ A = "tool", B = "cfg" },
            config_env.compose({ A = "tool", B = "tool" }, { B = "cfg" }))
    end)
end)

-- ---------------------------------------------------------------------------
-- Data model
-- ---------------------------------------------------------------------------
describe("Configuration env field", function()
    it("is a generic field, not module_config, and is serialized", function()
        local c = Configuration.new(nil, "Dev", { is_user = true, inherits = "variant:Debug",
            env = { FOO = "1" } })
        assert.same({ FOO = "1" }, c.env)
        assert.is_nil(c.module_config.env)
        assert.same({ FOO = "1" }, c:serialize_user_override().env)
    end)

    it("reports reserved names in env and overrides.<family>.env as compiler overrides", function()
        local c = Configuration.new(nil, "Dev", { is_user = true,
            env = { CXX = "x" }, overrides = { msvc = { env = { CC = "y" } } } })
        assert.same({ "CC", "CXX" }, c:compiler_override_warnings())
    end)
end)

describe("variables: the env namespace", function()
    it("rejects declaring a variable named env", function()
        local ok = variables.validate_declarations({ env = { type = "string" } })
        assert.is_false(ok)
    end)

    it("accepts an overrides.<family>.env map without declarations", function()
        assert.is_true(variables.validate_compiler_overrides(
            { msvc = { env = { SCCACHE_DIR = "D:/c" } } }, {}))
    end)

    it("rejects a non-map env sub-block", function()
        assert.is_false(variables.validate_compiler_overrides({ msvc = { env = "x" } }, {}))
    end)
end)

-- ---------------------------------------------------------------------------
-- Workspace integration: task env, record, staleness
-- ---------------------------------------------------------------------------
local function modules_get(id)
    if not id then return nil end
    return real_modules.get(id)
end

--- A workspace with one cmake project whose `Debug` configuration carries
--- `cfg_data` (cache pinned off so host PATH cache tools never matter), a
--- profile with a gcc/Ninja tool, and a hook recording the ctx cmake sees.
local function make_ws(cfg_data, tool_env, project_vars)
    local seen = {}
    cfg_data = vim.deepcopy(cfg_data)
    cfg_data.variables = vim.tbl_extend("force", cfg_data.variables or {}, { cache = "off" })
    local tool_data = { compiler_id = "gcc-12", generator = "Ninja", env = tool_env }
    local proj = { cmake = { configurations = { Debug = cfg_data } } }
    if project_vars then proj.variables = project_vars end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { App = proj },
            configuration_sets = { debug = { App = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({ profiles = { debug = {
            configuration_set = "debug",
            tools = { cmake = { key = "ninja-gcc-12", data = tool_data } },
        } } }),
    }
    local deps = h.make_test_deps(files, { modules = { get = modules_get }, cache = { save = function() return true end } })
    local core = Core.new(deps)
    core:setup({ root = "/root" })
    core._workspace._tools_by_type = { cmake = { {
        tool_key = "ninja-gcc-12", tool_data = tool_data, tool_label = "gcc",
    } } }
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    local unit = profile:projects()[1]._config_unit
    return core, ws, profile, unit, seen
end

local function plan(ws, profile, seen)
    local loomworks = require("loomworks")
    local cmake = require("loomworks.modules.cmake")
    local orig, orig_tasks = loomworks.get_workspace, cmake.tasks
    loomworks.get_workspace = function() return ws end
    cmake.tasks = function(ctx, ...) seen.ctx = ctx; return orig_tasks(ctx, ...) end
    local ok, steps = pcall(overseer.plan_profile_build, profile)
    loomworks.get_workspace, cmake.tasks = orig, orig_tasks
    assert.is_true(ok, tostring(steps))
    return steps
end

describe("configuration env in the task context", function()
    it("module ctx carries configuration_env and env = tool env + config env", function()
        local _, ws, profile, _, seen = make_ws(
            { env = { SCCACHE_DIR = "${workspace_root}/c", CC = "x", SHARED = "cfg" } },
            { SHARED = "tool", TOOL_ONLY = "t" })
        local steps = plan(ws, profile, seen)
        assert.same({ SCCACHE_DIR = "/root/c", SHARED = "cfg" }, seen.ctx.configuration_env)
        assert.equals("/root/c", seen.ctx.env.SCCACHE_DIR)
        assert.equals("cfg", seen.ctx.env.SHARED)     -- config wins over tool
        assert.equals("t", seen.ctx.env.TOOL_ONLY)    -- tool env kept
        assert.is_nil(seen.ctx.env.CC) -- reserved: stripped by core
        local cfg_step
        for _, s in ipairs(steps) do if s.kind == "configure" then cfg_step = s end end
        assert.equals("/root/c", cfg_step.env.SCCACHE_DIR)
    end)

    it("per-unit contexts compose the same way (resolve_task_env)", function()
        local env, cenv = overseer._resolve_task_env(nil, cfg("c", { env = { B = "cfg" } }),
            { env = { A = "tool", B = "tool" } }, nil, "/root")
        assert.same({ B = "cfg" }, cenv)
        assert.same({ A = "tool", B = "cfg" }, env)
    end)
end)

describe("configuration env record + staleness", function()
    it("record_task_result records configure_env; a changed env makes the unit stale", function()
        local core, _, _, unit = make_ws({ env = { FOO = "1" } })
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        assert.same({ FOO = "1" }, unit.module_info.configure_env)
        assert.is_false(unit:is_stale())
        unit._configuration.env = { FOO = "2" }
        assert.is_true(unit:env_changed())
        assert.is_true(unit:is_stale())
        unit._configuration.env = nil
        assert.is_true(unit:is_stale()) -- removed
    end)

    it("an empty env records nothing and is not stale", function()
        local core, _, _, unit = make_ws({ options = { X = "1" } })
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        assert.is_nil(unit.module_info.configure_env)
        assert.is_false(unit:env_changed())
    end)

    it("a unit configured before the record existed is stale only if it now has env", function()
        local core, _, _, unit = make_ws({ env = { FOO = "1" } })
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        unit.module_info.configure_env = nil -- as if recorded by an older version
        assert.is_true(unit:env_changed())
    end)

    it("a variable the env references changing makes the unit stale", function()
        local core, _, _, unit = make_ws({ env = { DIR = "${d}" } },
            nil, { d = { type = "string", default = "a" } })
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "none" } })
        assert.same({ DIR = "a" }, unit.module_info.configure_env)
        unit._project.variables.d.default = "b"
        assert.is_true(unit:is_stale())
    end)

    it("the compat scan receives the configuration env", function()
        local core, _, _, unit = make_ws({ env = { CL = "/Zi" } })
        local got
        local impl = unit._project._module.impl
        local orig = impl.cache_compat_scan
        impl.cache_compat_scan = function(ctx)
            got = ctx.configuration_env
            return { scanned = true, findings = {} }
        end
        core:record_task_result({ unit = unit, action = "configure", success = true,
            build_dir = unit:build_dir(), module_info = { cache_launcher = "/x/sccache" } })
        impl.cache_compat_scan = orig
        assert.same({ CL = "/Zi" }, got)
    end)
end)

describe("save_configuration and env", function()
    it("persists env and rejects reserved names in env and overrides.<family>.env", function()
        local _, ws = make_ws({ options = { X = "1" } })
        local proj = ws._projects[1]
        assert.is_true(proj:save_configuration("Dev", { inherits = "variant:Debug", env = { FOO = "1" } }))
        assert.same({ FOO = "1" }, proj:get_configuration("Dev").env)
        local ok, err = proj:save_configuration("Dev2", { env = { CXX = "g++" } })
        assert.is_false(ok)
        assert.matches("CXX", err)
        ok = proj:save_configuration("Dev3", { overrides = { msvc = { env = { CC = "cl" } } } })
        assert.is_false(ok)
    end)

    it("a configuration rename keeps its env", function()
        local _, ws = make_ws({ options = { X = "1" } })
        local proj = ws._projects[1]
        assert.is_true(proj:save_configuration("Dev", { inherits = "variant:Debug", env = { FOO = "1" } }))
        local data = cli._config_to_data(proj:get_configuration("Dev"))
        assert.is_true(proj:rename_configuration("Dev", "Dev2", data))
        assert.same({ FOO = "1" }, proj:get_configuration("Dev2").env)
    end)
end)

-- ---------------------------------------------------------------------------
-- Test runs
-- ---------------------------------------------------------------------------
describe("configuration env in test runs", function()
    it("ctest's native run layers the configuration env over the run env", function()
        local CTestUnit = require("loomworks.test_units.ctest")
        local unit = {
            build_dir = function() return "/b" end,
            variant = function() return "Debug" end,
            run_env = function() return nil end,
            configuration_env = function() return { SCCACHE_DIR = "/c" } end,
            configuration = function() return nil end,
            _cached_module_config = {},
        }
        local tu = CTestUnit.new(unit)
        tu._ctest_dir = "/b"
        local spec = tu:run_command_all({})
        assert.equals("/c", spec.env.SCCACHE_DIR)
    end)
end)

-- ---------------------------------------------------------------------------
-- CLI grammar
-- ---------------------------------------------------------------------------
describe("lw config param grammar: env", function()
    it("env.<NAME> sets and clears (empty map pruned)", function()
        local data = {}
        cli._apply_param(data, "env.SCCACHE_DIR", "/c")
        assert.same({ SCCACHE_DIR = "/c" }, data.env)
        cli._apply_param(data, "env.SCCACHE_DIR", nil)
        assert.is_nil(data.env)
    end)

    it("overrides.<family>.env.<NAME> sets and clears into the family env block", function()
        local data = { overrides = { msvc = { cache = "sccache" } } }
        cli._apply_param(data, "overrides.msvc.env.SCCACHE_DIR", "D:/c")
        assert.same({ cache = "sccache", env = { SCCACHE_DIR = "D:/c" } }, data.overrides.msvc)
        cli._apply_param(data, "overrides.msvc.env.SCCACHE_DIR", "")
        assert.same({ cache = "sccache" }, data.overrides.msvc)
    end)

    it("rejects bare env, overrides.<family>.env without NAME, and unknown dotted params", function()
        for _, p in ipairs({ "env", "overrides.msvc.env", "foo.bar", "overrides.msvc.x.y" }) do
            local r = capture(function() cli._apply_param({}, p, "v") end)
            assert.equals(1, r.exit_code, p)
        end
        local r = capture(function() cli._apply_param({}, "foo.bar", "v") end)
        assert.matches("unknown parameter 'foo.bar'", r.stderr, 1, true)
    end)

    it("a bare module field still works", function()
        local data = {}
        cli._apply_param(data, "toolchain", "/tc.cmake")
        assert.equals("/tc.cmake", data.toolchain)
    end)

    it("get_param reads env, env.<NAME> and overrides.<family>.env[.<NAME>]", function()
        local c = Configuration.new(nil, "Dev", { is_user = true, env = { A = "1" },
            overrides = { msvc = { env = { B = "2" } } } })
        assert.same({ A = "1" }, cli._get_param(c, "env"))
        assert.equals("1", cli._get_param(c, "env.A"))
        assert.same({ B = "2" }, cli._get_param(c, "overrides.msvc.env"))
        assert.equals("2", cli._get_param(c, "overrides.msvc.env.B"))
    end)

    it("config_to_data round-trips env", function()
        local c = Configuration.new(nil, "Dev", { is_user = true, env = { A = "1" } })
        assert.same({ A = "1" }, cli._config_to_data(c).env)
    end)
end)

-- ---------------------------------------------------------------------------
-- CL / _CL_ compat scan
-- ---------------------------------------------------------------------------
describe("cache_compat_scan: /Zi in CL / _CL_", function()
    local cpp = require("loomworks.cpp_compilers")

    it("pdb_env_findings reports CL and _CL_ (case-insensitive), sccache = error", function()
        local f = cpp.pdb_env_findings({ cl = "/nologo /Zi", _CL_ = "-ZI", OTHER = "/Zi" }, "sccache")
        assert.equals(2, #f)
        assert.equals("environment", f[1].group)
        assert.equals("error", f[1].severity)
        assert.is_nil(f[1].units)
        assert.same({ "cl" }, f[1].sample)
        assert.same({ "_CL_" }, f[2].sample)
    end)

    it("ignores clean values and ccache is a warning", function()
        assert.same({}, cpp.pdb_env_findings({ CL = "/Z7 /MP" }, "ccache"))
        assert.equals("warning", cpp.pdb_env_findings({ CL = "/Zi" }, "ccache")[1].severity)
    end)

    it("cmake reports the env finding even without codemodel data", function()
        local res = require("loomworks.modules.cmake").cache_compat_scan({
            build_dir = vim.fn.tempname(),
            tool_data = { compiler_id = "msvc-17" },
            compiler_cache = { tool = "sccache", path = "/x/sccache" },
            configuration_env = { CL = "/Zi" },
        })
        assert.is_false(res.scanned)
        assert.equals("environment", res.findings[1].group)
    end)

    it("meson reports the env finding too", function()
        local res = require("loomworks.modules.meson").cache_compat_scan({
            build_dir = vim.fn.tempname(),
            tool_data = { compiler_id = "msvc-17", vcvarsall = "x" },
            compiler_cache = { tool = "sccache", path = "/x/sccache" },
            configuration_env = { _CL_ = "/ZI" },
        })
        assert.equals("environment", res.findings[1].group)
    end)

    it("a gcc tool is never scanned", function()
        local res = require("loomworks.modules.cmake").cache_compat_scan({
            build_dir = "/nope", tool_data = { compiler_id = "gcc-13" },
            configuration_env = { CL = "/Zi" },
        })
        assert.same({}, res.findings)
    end)

    it("the group line renders an environment finding without a unit count", function()
        local lines = require("loomworks.compiler_cache").compat_group_lines({ findings = {
            { severity = "error", flag = "/Zi", group = "environment", sample = { "CL" } },
        } })
        assert.equals("environment: every compile (/Zi) — CL", lines[1])
    end)
end)
