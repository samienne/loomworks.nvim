-- Saved test targets (spec §1.3.4, §16.9, §16.16, §8.9.2–§8.9.4, §17.6,
-- ui "Saved test targets line"): the `tests` field's resolution and
-- persistence, `lw test-target`, the `lw test` plan and `--list`, the trust
-- stripping of per-target args, the saved-targets TestUnit, owning-unit
-- dispatch in the loomtest adapter, and the status page line.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local tt = require("loomworks.test_targets")
local ConfigUnit = require("loomworks.config_unit")
local Target = require("loomworks.target")

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex, rstd = io.write, io.stderr, os.exit, io.stdout
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stdout = { write = function(_, s) out_buf[#out_buf + 1] = s end, flush = function() end }
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit, io.stdout = rw, rs, rex, rstd
    if not ok and not (type(ret) == "table" and ret.__exit) then error(ret, 0) end
    return { exit_code = exit_code, ret = ok and ret or nil,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a"); f:close()
    return vim.json.decode(c)
end

--- Temp workspace: a typescript App with the given loomworks.json `App`
--- module section, plus a `Dev` set mapping App to `mapped` and a profile.
local function make_ws(section, mapped)
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root .. "/App", "p")
    local lw = { projects = { App = { typescript = section or vim.empty_dict() } },
        configuration_sets = { Dev = { App = mapped or "variant:default" } } }
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode(lw)); f:close()
    capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
    return root
end

local function load(root)
    local ws
    capture(function() ws = cli._load_workspace(root, false) end)
    return ws
end

local function project(ws, key)
    for _, p in pairs(ws._projects) do if p.key == key then return p end end
end

local function names(entries)
    local out = {}
    for _, e in ipairs(entries or {}) do out[#out + 1] = e.target end
    return out
end

-- ===========================================================================
describe("tests field: resolution (§1.3.4)", function()
    local SECTION = {
        tests = { targets = { "P1" } },
        configurations = {
            Base = { inherits = "variant:default", tests = { targets = { "A", { target = "B", args = { "--f" } } } } },
            Other = { inherits = "variant:default" },
            Child = { inherits = "Base" },
            Mix = { inherits = { "Other", "Base" } },
            Off = { inherits = "Base", tests = { targets = {} } },
            Dups = { inherits = "variant:default", tests = { mode = "x", targets = { "A", "A", "C" } } },
        },
    }

    it("own list, then bases depth-first left-to-right, then project-wide; [] stops", function()
        local ws = load(make_ws(SECTION, "Child"))
        local p = project(ws, "App")
        local base = p:get_configuration("Base")
        local r = p:get_configuration("Child"):test_targets()
        assert.same({ "A", "B" }, names(r.entries))
        assert.equals(base, r.source)             -- an object reference
        -- args from loomworks.json are program-bearing: dropped, entry kept (§17.6)
        assert.is_nil(r.entries[2].args)
        assert.equals(base, p:get_configuration("Mix"):test_targets().source)
        local off = p:get_configuration("Off"):test_targets()
        assert.same({}, off.entries)              -- explicit opt-out
        local gen = p:get_configuration("variant:default"):test_targets()
        assert.same({ "P1" }, names(gen.entries))
        assert.equals(p, gen.source)              -- project-wide
        assert.equals("inherited from Base", tt.source_text(r.source, p:get_configuration("Child")))
        assert.equals("project-wide", tt.source_text(gen.source, p:get_configuration("variant:default")))
    end)

    it("drops a duplicate (first kept) and keeps unknown keys of the object", function()
        local ws = load(make_ws(SECTION, "Child"))
        local d = project(ws, "App"):get_configuration("Dups")
        assert.same({ "A", "C" }, names(d:own_test_targets()))
        assert.same({ mode = "x", targets = { "A", "C" } }, d:serialize_user_override().tests)
    end)

    it("an editor edit emits tests_invalidated only (no active_set_changed / LSP re-evaluation)", function()
        local ws = load(make_ws(SECTION, "Child"))
        local events = ws._core._deps.events
        local seen = {}
        local on_inv = function() seen.inv = (seen.inv or 0) + 1 end
        local on_set = function() seen.set = (seen.set or 0) + 1 end
        events.on("tests_invalidated", on_inv)
        events.on("active_set_changed", on_set)
        local ok, err = project(ws, "App"):get_configuration("Child"):set_test_targets({ { target = "Z" } })
        events.off("tests_invalidated", on_inv)
        events.off("active_set_changed", on_set)
        assert.is_true(ok, err)
        assert.truthy((seen.inv or 0) >= 1)
        assert.is_nil(seen.set)
    end)

    it("keeps unknown keys of an entry object through a rewrite", function()
        local raw = { targets = { "A", { target = "B", args = { "--b" }, timeout = 30, env = { X = "1" } },
            { target = "C", note = "keep" } } }
        local decl = tt.parse(raw, "App/Tests")
        assert.same({ timeout = 30, env = { X = "1" } }, decl.entries[2].extra)
        assert.same(raw, tt.serialize(decl))
        -- A rewrite (as `lw test-target add` does: change args, append) keeps them.
        local entries = vim.deepcopy(decl.entries)
        entries[2].args = nil
        entries[#entries + 1] = { target = "D" }
        local out = tt.serialize(tt.with_entries(decl, entries))
        assert.same({ "A", { target = "B", timeout = 30, env = { X = "1" } },
            { target = "C", note = "keep" }, "D" }, out.targets)
        -- Unknown entry keys do not change the fingerprint (names + args only).
        assert.equals(tt.fingerprint({ { target = "C" } }), tt.fingerprint({ decl.entries[3] }))
    end)

    it("is persisted only where declared, and a module never sees it", function()
        local root = make_ws(SECTION, "Child")
        local ws = load(root)
        local p = project(ws, "App")
        assert.is_true(p:get_configuration("Other"):set_test_targets({ { target = "Z" } }))
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        local cfgs = user.projects.App.typescript.configurations
        assert.same({ targets = { "Z" } }, cfgs.Other.tests)
        assert.is_nil(cfgs.Child.tests)           -- derived: never a copy
        assert.same({ targets = { "P1" } }, user.projects.App.typescript.tests)
        -- What the module is handed carries no `tests` anywhere.
        local tc = p:_type_config_for_module()
        assert.is_nil(tc.tests)
        for _, c in pairs(tc.configurations or {}) do assert.is_nil(c.tests) end
        assert.is_nil(p:get_configuration("Other").module_config.tests)
        -- …and a reload reads it back.
        local ws2 = load(root)
        assert.same({ "Z" }, names(project(ws2, "App"):get_configuration("Other"):own_test_targets()))
    end)

    it("never makes a unit stale; an older snapshot with `tests` compares without it", function()
        local unit = setmetatable({
            _configuration = { module_config = { variant = "Debug" } },
            _cached_options = {}, _cached_module_config = { variant = "Debug", tests = { targets = { "A" } } },
            record_outdated = function() return false end,
            resolved_option_fingerprint = function() return {} end,
            env_changed = function() return false end,
            launcher_changed = function() return false end,
        }, { __index = ConfigUnit })
        assert.is_nil(ConfigUnit.stale_reason(unit))
        unit._cached_module_config = { variant = "Release", tests = { targets = { "A" } } }
        assert.equals("module configuration changed", ConfigUnit.stale_reason(unit))
    end)

    it("`lw config set/unset tests…` is refused, naming lw test-target", function()
        local root = make_ws(SECTION, "Child")
        local r = capture(function() cli.cmd_configuration("set", root, "App", "Base", "tests.targets", "A") end)
        assert.equals(1, r.exit_code)
        assert.truthy(r.stderr:find("lw test-target", 1, true))
        r = capture(function() cli.cmd_configuration("unset", root, "App", "Base", "tests") end)
        assert.equals(1, r.exit_code)
    end)
end)

-- ===========================================================================
describe("trust: per-target args are program-bearing (§17.6)", function()
    local pf = require("loomworks.program_fields")
    local SHARED = { projects = { App = { cmake = {
        tests = { targets = { { target = "PW", args = { "--pw" } } } },
        configurations = { Tests = { variant = "Release", tests = { targets = {
            "BaseTests", { target = "RenderTests", args = { "--gtest_filter=-*Slow*" } } } } } },
    } } } }

    it("strips only the args; the entries still apply", function()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        local ignored = pf.strip(cfg, require("loomworks.modules"))
        local labels = {}
        for _, e in ipairs(ignored) do labels[#labels + 1] = e.label end
        table.sort(labels)
        assert.same({ "projects.App.cmake.configurations.Tests.tests", "projects.App.cmake.tests" }, labels)
        local c = cfg.projects.App.type_config.configurations.Tests.tests.targets
        assert.equals("BaseTests", c[1])
        assert.same({ target = "RenderTests" }, c[2])
        assert.same({ { target = "PW" } }, cfg.projects.App.tests.targets)
        local diags = pf.diagnostics(ignored, cfg)
        local msg
        for _, d in ipairs(diags) do
            if d.message:find("configurations.Tests.tests", 1, true) then msg = d.message end
        end
        assert.equals("loomworks.json sets projects.App.cmake.configurations.Tests.tests "
            .. "(RenderTests args = --gtest_filter=-*Slow*) — ignored: program settings are used only "
            .. "from your local config (lw help trust)", msg)
    end)

    it("no diagnostic when the working copy supplies the args; regraft restores by name", function()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        local ignored = pf.strip(cfg, require("loomworks.modules"))
        local merged = vim.deepcopy(cfg)
        merged.projects.App.type_config.configurations.Tests.tests.targets[2].args = { "--mine" }
        merged.projects.App.tests.targets[1].args = { "--p" }
        assert.same({}, pf.diagnostics(ignored, merged))
        -- Publishing (raw shape, reordered, args-less strings) gets them back.
        local raw = { projects = { App = { cmake = {
            tests = { targets = { "PW" } },
            configurations = { Tests = { tests = { targets = { "RenderTests", "BaseTests" } } } } } } } }
        pf.regraft(raw, ignored)
        local t = raw.projects.App.cmake.configurations.Tests.tests.targets
        assert.same({ target = "RenderTests", args = { "--gtest_filter=-*Slow*" } }, t[1])
        assert.equals("BaseTests", t[2])
        assert.same({ { target = "PW", args = { "--pw" } } }, raw.projects.App.cmake.tests.targets)
    end)
end)

-- ===========================================================================
-- Fakes for the headless plan: a unit with an optional batch runner, a saved
-- list and parsed targets.
local function fake_target(name, kind)
    return { id = name, is_executable = function() return kind ~= "lib" end,
        display_name = function() return name end, artifact = name }
end

local function fake_unit(key, o)
    o = o or {}
    local cfg = { name = o.cfg or "Tests", _project = nil }
    local project = { key = key, _module = { impl = { parse_targets = function() return {} end } } }
    cfg._project = project
    local unit = {
        _project = project, targets = o.targets,
        variant = function() return "Debug" end,
        configured_here = function() return o.here ~= false end,
        tool_object = function() return o.foreign and { key = "kit", execution_platform = function() return "arm64" end } or nil end,
        batch_runner_test_units = function()
            return o.batch and { { run_command_all = function() return { cmd = { "ctest" } } end } } or {}
        end,
        saved_test_targets = function()
            if not o.saved then return nil end
            local entries = {}
            for _, e in ipairs(o.saved) do
                entries[#entries + 1] = type(e) == "string" and { target = e } or e
            end
            return { entries = entries, source = cfg }
        end,
        build_dir = function() return nil end,
    }
    local pp = { _config_unit = unit, variant_name = function() return cfg.name end,
        configuration = function() return cfg end }
    return unit, pp
end

local function fake_profile(pps)
    local by = {}
    for _, pp in ipairs(pps) do by[pp._config_unit._project.key] = pp end
    return { key = "Dev:kit", projects = function() return pps end, project = function(_, k) return by[k] end }
end

describe("lw test plan (§16.16)", function()
    local ov = require("loomworks.overseer")
    local gtest = require("loomworks.gtest")
    local orig_plan, orig_probe

    before_each(function()
        orig_plan, orig_probe = ov.plan_profile_test, gtest.probe_sync
        gtest.probe_sync = function() return nil end
        ov.plan_profile_test = function(profile, opts)
            local steps = {}
            for _, pp in ipairs(profile:projects()) do
                local u = pp._config_unit
                if not (opts.skip_units or {})[u] and u.batch_runner_test_units()[1] then
                    local label = u._project.key .. ":Debug"
                    steps[#steps + 1] = { unit = u, name = label, runner = "ctest", cmd = { "ctest", label },
                        junit_dest = opts.junit_dest_for and opts.junit_dest_for(label, u) or nil }
                end
            end
            return steps, #profile:projects()
        end
    end)
    after_each(function() ov.plan_profile_test, gtest.probe_sync = orig_plan, orig_probe end)

    local function run_plan(profile, opts, codes)
        local ran, built = {}, nil
        local deps = {
            build = function(_, _, keep) built = keep end,
            run_spec = function(step) ran[#ran + 1] = table.concat(step.cmd, " ");
                return (codes or {})[step.cmd[2] or step.cmd[1]] or 0 end,
            launch_target = function(_, _, c)
                return { resolve_launch_spec = function() return { cmd = "/bin/" .. c.name, args = {}, cwd = "/" } end }
            end,
        }
        opts.extra = opts.extra or {}
        opts.dev = opts.dev or cli._new_device_opts()
        local r = capture(function() return cli._test_plan({ root = "/" }, profile, opts, deps) end)
        r.ran, r.built = ran, built
        return r
    end

    local function two_units()
        local a, ppa = fake_unit("A", { batch = true, saved = { "X", { target = "Y", args = { "--y" } } },
            targets = { X = fake_target("X"), Y = fake_target("Y") } })
        local b, ppb = fake_unit("B", { saved = { "Z" }, targets = { Z = fake_target("Z") } })
        return fake_profile({ ppa, ppb }), a, b
    end

    it("runs per unit: batch step first, then saved executables in list order", function()
        local profile, a = two_units()
        local r = run_plan(profile, {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "ctest A:Debug", "/bin/X", "/bin/Y --y", "/bin/Z" }, r.ran)
        assert.truthy(r.built[a])                           -- built despite a batch runner
        local hdr = {}
        for l in r.stdout:gmatch("==> %[test%] ([^\n]+)") do hdr[#hdr + 1] = l end
        assert.same({ "A: ctest", "A: X", "A: Y", "B: Z" }, hdr)
        assert.truthy(r.stdout:find("TESTS OK: Dev:kit (4 steps)", 1, true))
    end)

    it("every step runs after a failure; the summary names it; exit 1", function()
        local profile = two_units()
        local r = run_plan(profile, {}, { ["A:Debug"] = 8 })
        assert.equals(1, r.exit_code)
        assert.equals(4, #r.ran)
        assert.truthy(r.stdout:find("A: ctest%s+FAILED %(exit status 8%)"))
        assert.truthy(r.stderr:find("1 of 4 test steps failed", 1, true))
    end)

    it("--saved runs only executables, --discovered only batch steps", function()
        local profile = two_units()
        assert.same({ "/bin/X", "/bin/Y --y", "/bin/Z" }, run_plan(profile, { sel = "saved" }).ran)
        assert.same({ "ctest A:Debug" }, run_plan(profile, { sel = "discovered" }).ran)
    end)

    it("a missing or non-executable saved entry fails before anything runs", function()
        local a, ppa = fake_unit("A", { batch = true, saved = { "X", "Gone", "Lib" },
            targets = { X = fake_target("X"), Lib = fake_target("Lib", "lib") } })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.equals(1, r.exit_code)
        assert.same({}, r.ran)
        assert.truthy(r.stderr:find("saved test target 'Gone' (A/Tests) is not a target of A", 1, true))
        assert.truthy(r.stderr:find("'Lib' (A/Tests) is not an executable target of A", 1, true))
        assert.truthy(r.stderr:find("lw test-target remove Dev:kit A:Gone --config Tests", 1, true))
        assert.truthy(r.stderr:find("executables: A:X", 1, true))
        assert.is_not_nil(a)
    end)

    it("forwarded args need a one-kind plan (refused before the build)", function()
        local profile = two_units()
        local r = run_plan(profile, { extra = { "-j", "4" } })
        assert.equals(2, r.exit_code)
        assert.is_nil(r.built)
        assert.truthy(r.stderr:find("--saved", 1, true))
        assert.truthy(r.stderr:find("--discovered", 1, true))
        -- One kind: entry args, then the forwarded ones.
        local s = run_plan(profile, { sel = "saved", extra = { "--fwd" } })
        assert.same({ "/bin/X --fwd", "/bin/Y --y --fwd", "/bin/Z --fwd" }, s.ran)
    end)

    it("--junit: one file per step, the label suffix across all steps", function()
        local ws_root = vim.fn.tempname():gsub("\\", "/")
        local profile = two_units()
        local paths = {}
        local orig = cli._run_test_executable
        cli._run_test_executable = function(_, _, o) paths[#paths + 1] = o.junit_path; return false, {} end
        local r = run_plan(profile, { junit = ws_root .. "/out/r.xml" })
        cli._run_test_executable = orig
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ ws_root .. "/out/r.X.xml", ws_root .. "/out/r.Y.xml", ws_root .. "/out/r.Z.xml" }, paths)
    end)

    it("a label two steps share is qualified with the project for the executable", function()
        local a, ppa = fake_unit("A", { saved = { "T" }, targets = { T = fake_target("T") } })
        local b, ppb = fake_unit("B", { saved = { "T" }, targets = { T = fake_target("T") } })
        local paths = {}
        local orig = cli._run_test_executable
        cli._run_test_executable = function(_, _, o) paths[#paths + 1] = o.junit_path; return false, {} end
        run_plan(fake_profile({ ppa, ppb }), { junit = "/o/r.xml" })
        cli._run_test_executable = orig
        assert.same({ "/o/r.A-T.xml", "/o/r.B-T.xml" }, paths)
        assert.is_not_nil(a and b)
    end)

    it("foreign: the batch step is dropped with a note when saved targets exist", function()
        local _, ppa = fake_unit("A", { batch = true, foreign = true, saved = { "X" },
            targets = { X = fake_target("X") } })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bin/X" }, r.ran)
        assert.truthy(r.stderr:find("A: its registered tests cannot run on this host (arm64)", 1, true))
    end)

    it("foreign without saved targets is refused; device options need an executable step", function()
        local _, ppa = fake_unit("A", { batch = true, foreign = true })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.equals(1, r.exit_code)
        assert.truthy(r.stderr:find("lw test-target add", 1, true))
        local _, ppb = fake_unit("B", { batch = true })
        local dev = cli._new_device_opts()
        dev.device = "SER1"
        local d = run_plan(fake_profile({ ppb }), { dev = dev })
        assert.equals(2, d.exit_code)
    end)

    it("selectors are exclusive (usage error)", function()
        local r = capture(function() cli.cmd_test({}, { "test", "--saved", "--discovered" }) end)
        assert.equals(2, r.exit_code)
        r = capture(function() cli.cmd_test({}, { "test", "--target", "X", "--saved" }) end)
        assert.equals(2, r.exit_code)
        r = capture(function() cli.cmd_test({}, { "test", "--json" }) end)
        assert.equals(2, r.exit_code)
    end)
end)

describe("lw test --list (§16.16 plan report)", function()
    it("reports batch + saved steps read-only, unknown when not configured here", function()
        local _, ppa = fake_unit("A", { batch = true, here = false, saved = { { target = "X", args = { "--x" } } } })
        local profile = fake_profile({ ppa })
        local r = capture(function() return cli._test_plan_report({}, profile, nil, true) end)
        local j = vim.json.decode(r.stdout)
        assert.equals("Dev:kit", j.profile)
        assert.equals("A", j.units[1].project)
        assert.is_table(j.units[1].batch)
        assert.equals("X", j.units[1].saved.entries[1].target)
        assert.same({ "--x" }, j.units[1].saved.entries[1].args)
        assert.equals("unknown", j.units[1].saved.entries[1].state)
        assert.equals("own", j.units[1].saved.source)
    end)

    it("an empty plan names the add form", function()
        local _, ppa = fake_unit("A", {})
        local r = capture(function() return cli._test_plan_report({}, fake_profile({ ppa }), nil, false) end)
        assert.truthy(r.stdout:find("lw test-target add Dev:kit <target>", 1, true))
    end)
end)

-- ===========================================================================
describe("lw test-target (§16.9)", function()
    local function targets_for(ws)
        local p = project(ws, "App")
        for _, u in pairs(ws._config_units or {}) do
            if u._project == p then
                u.targets = {
                    CoreTests = Target.new(u, "CoreTests", { type = "executable", artifact = "c" }),
                    BaseTests = Target.new(u, "BaseTests", { type = "executable", artifact = "b" }),
                    libcore = Target.new(u, "libcore", { type = "static_library", artifact = "l" }),
                }
            end
        end
        return p
    end

    local SECTION = { configurations = {
        Tests = { inherits = "variant:default", tests = { targets = { "BaseTests", "X1" } } },
        Rel = { inherits = "Tests" },
    } }

    it("add writes to the mapped user configuration and says where", function()
        local root = make_ws(SECTION, "Tests")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("saved CoreTests on App/Tests (used by Dev)", 1, true)
            or r.stdout:find("saved CoreTests on App/Tests (used by", 1, true), r.stdout)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "BaseTests", "X1", "CoreTests" },
            user.projects.App.typescript.configurations.Tests.tests.targets)
    end)

    it("add on a generated mapping writes project-wide; args after -- ; re-add replaces args", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root); targets_for(ws)
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests", "--", "--a" }, ws) end)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ { target = "CoreTests", args = { "--a" } } }, user.projects.App.typescript.tests.targets)
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests", "--", "--a" }, ws) end)
        assert.truthy(r.stdout:find("(unchanged)", 1, true))
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "BaseTests" }, ws) end)
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests" }, ws) end)
        user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "CoreTests", "BaseTests" }, user.projects.App.typescript.tests.targets)
    end)

    it("refuses a non-executable target (listing the executables) and unknown targets", function()
        local root = make_ws(SECTION, "Tests")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "libcore" }, ws) end)
        assert.equals(1, r.exit_code)
        assert.truthy(r.stderr:find("App:BaseTests", 1, true))
        -- Targets unknown (not configured here): refused unless --unchecked.
        local ws2 = load(root)
        local impl = project(ws2, "App")._module.impl
        local orig = impl.parse_targets
        impl.parse_targets = function() return nil end
        local u = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "NewTests" }, ws2) end)
        assert.equals(1, u.exit_code)
        assert.truthy(u.stderr:find("lw build", 1, true))
        local ok = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "NewTests", "--unchecked" }, ws2) end)
        impl.parse_targets = orig
        assert.is_nil(ok.exit_code, ok.stderr)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "BaseTests", "X1", "NewTests" }, user.projects.App.typescript.configurations.Tests.tests.targets)
    end)

    it("an edit on an inheriting level copies the inherited list first and says so", function()
        local root = make_ws(SECTION, "Rel")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "X1" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("copied 2 inherited targets from Tests", 1, true), r.stdout)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        local cfgs = user.projects.App.typescript.configurations
        assert.same({ "BaseTests" }, cfgs.Rel.tests.targets)
        -- The base keeps its own list.
        assert.same({ "BaseTests", "X1" }, names(project(ws, "App"):get_configuration("Tests"):own_test_targets()))
        local n = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "Nope" }, ws) end)
        assert.truthy(n.stdout:find("nothing to remove", 1, true))
    end)

    it("clear removes the declaration (inherits again); --empty declares []", function()
        local root = make_ws(SECTION, "Rel")
        local ws = load(root); targets_for(ws)
        capture(function() return cli._tt_clear(root, { "test-target", "clear", "Dev", "--empty" }, ws) end)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({}, user.projects.App.typescript.configurations.Rel.tests.targets)
        local r = capture(function() return cli._tt_clear(root, { "test-target", "clear", "Dev" }, ws) end)
        assert.truthy(r.stdout:find("now inherits 2 from inherited from Tests", 1, true)
            or r.stdout:find("cleared App/Rel", 1, true), r.stdout)
        user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.is_nil(user.projects.App.typescript.configurations.Rel.tests)
    end)

    it("list shows the effective list with its source", function()
        local root = make_ws(SECTION, "Rel")
        local ws = load(root)
        local r = capture(function() return cli._tt_list(root, nil, ws) end)
        assert.truthy(r.stdout:find("inherited from Tests", 1, true), r.stdout)
        assert.truthy(r.stdout:find("BaseTests", 1, true))
    end)
end)

-- ===========================================================================
describe("ConfigUnit + saved-targets TestUnit (§8.9.2–§8.9.3)", function()
    it("merge keeps the module's entry for a shared executable; the saved args ride along", function()
        local mod_tu = { is_saved_targets = nil }
        local saved_tu = { is_saved_targets = true }
        local merged = ConfigUnit._merge_test_entries({ mod_tu, saved_tu }, {
            { { id = "target:T", executable = "/b/T" }, { id = "test:S.a", parent = "target:T", executable = "/b/T" } },
            { { id = "target:T", executable = "/b/T", args = { "--q" } },
              { id = "test:S.a", parent = "target:T" },
              { id = "target:U", executable = "/b/U" } },
        })
        local ids = {}
        for _, e in ipairs(merged) do ids[#ids + 1] = e.id end
        assert.same({ "target:T", "test:S.a", "target:U" }, ids)
        assert.same({ "--q" }, merged[1].saved_args)
    end)

    it("discovery: runnable target entries, errored non-runnable missing/library entries", function()
        local SavedTU = require("loomworks.test_units.saved_targets")
        local unit
        unit = {
            _project = { key = "App" },
            build_dir = function() return "/b" end,
            ensure_targets = function() return unit.targets end,
            saved_test_targets = function()
                return { entries = { { target = "Run", args = { "--r" } }, { target = "Gone" }, { target = "Lib" } },
                    source = { name = "Tests", _project = { key = "App" } } }
            end,
            run_env = function() return nil end,
            configured_here = function() return true end,
        }
        unit.targets = {
            Run = Target.new(unit, "Run", { type = "executable", artifact = "Run" }),
            Lib = Target.new(unit, "Lib", { type = "static_library", artifact = "Lib" }),
        }
        local tu = SavedTU.new(unit)
        local entries = tu:discover()
        assert.equals("target:Run", entries[1].id)
        assert.is_true(entries[1].runnable)
        assert.is_false(entries[2].runnable)
        assert.equals("errored", entries[2].status)
        assert.equals("not a target of App/Tests (removed or renamed?)", entries[2].message)
        assert.equals("not an executable target of App/Tests", entries[3].message)
        local cmd = tu:test_command("target:Run")
        assert.equals("--r", cmd.cmd[#cmd.cmd])
        assert.is_nil(tu:run_command_all())
        assert.is_nil(tu:test_command_all())
    end)

    it("test_units appends the saved TestUnit; batch_runner_test_units never has it; a list change invalidates", function()
        local list = { { target = "T" } }
        local unit = setmetatable({
            _project = { key = "App", _module = { impl = {
                parse_targets = function() return {} end,
                create_test_unit = function() return { kind = "module" } end,
            } } },
            _configuration = { test_targets = function() return { entries = list, source = {} } end },
            configured_here = function() return true end,
        }, { __index = ConfigUnit })
        package.loaded["loomworks.remote.foreign"].unit_platform = (function(orig)
            unit._orig_up = orig
            return function() return nil end
        end)(package.loaded["loomworks.remote.foreign"].unit_platform)
        local tus = unit:test_units()
        assert.equals(2, #tus)
        assert.is_true(tus[2].is_saved_targets)
        local batch = unit:batch_runner_test_units()
        assert.equals(1, #batch)
        assert.equals("module", batch[1].kind)
        local before = unit:test_units()
        list = { { target = "T" }, { target = "U" } }
        assert.is_false(rawequal(before, unit:test_units()))
        list = {}
        assert.equals(1, #unit:test_units())
        package.loaded["loomworks.remote.foreign"].unit_platform = unit._orig_up
    end)
end)

-- ===========================================================================
describe("loomtest adapter: owning-unit dispatch (§8.9.4)", function()
    local lw = require("loomworks")
    local orig_active
    before_each(function() orig_active = lw.get_active_profile end)
    after_each(function() lw.get_active_profile = orig_active end)

    local function unit_with(tus)
        return {
            test_units = function() return tus end,
            test_commands_all = function(self, o) return ConfigUnit.test_commands_all(self, o) end,
            test_command_for = function(self, id, o) return ConfigUnit.test_command_for(self, id, o) end,
            _find_test_unit = function(self, id) return ConfigUnit._find_test_unit(self, id) end,
            _tree_entry = function() return nil end,
        }
    end
    local function tu(id, all)
        return {
            entries = function() return { { id = id, runnable = true } } end,
            test_command = function(_, tid) return { cmd = { "run", tid } } end,
            test_command_all = all and function() return { cmd = { "all", id } } end or nil,
            is_saved_targets = not all or nil,
            parse_results = function() return { { test_id = id, status = "passed" } } end,
        }
    end

    it("run-all covers every TestUnit of every unit; run / parse go through the owner", function()
        local m1, s1, m2 = tu("target:A", true), tu("target:S", false), tu("target:B", true)
        local u1, u2 = unit_with({ m1, s1 }), unit_with({ m2 })
        lw.get_active_profile = function()
            return { projects = function() return { { _config_unit = u1 }, { _config_unit = u2 } } end }
        end
        package.loaded["loomworks.loomtest_adapter"] = nil
        local adapter_mod = require("loomworks.loomtest_adapter")
        local captured
        package.loaded["loomtest"] = { register_adapter = function(a) captured = a end }
        adapter_mod.register()
        package.loaded["loomtest"] = nil
        local specs = captured.run_all()
        local cmds = {}
        for _, s in ipairs(specs) do cmds[#cmds + 1] = table.concat(s.cmd, " ") end
        assert.same({ "all target:A", "run target:S", "all target:B" }, cmds)
        local one = captured.run("target:B")
        assert.same({ "run", "target:B" }, one.cmd)
        assert.equals(m2, one._test_unit)
        assert.same("target:B", captured.parse_results("/x.xml", one)[1].test_id)
    end)
end)

-- ===========================================================================
describe("status page Tests: line (ui)", function()
    local helpers = require("loomworks.ui.helpers")
    local function text(chunks)
        local p = {}
        for _, c in ipairs(chunks) do p[#p + 1] = c[1] end
        return table.concat(p)
    end

    it("names in order, the source when not own, +N to the width, ⚠ on missing", function()
        local base = { name = "Tests", _project = { key = "App" } }
        local cfg = { name = "Rel", _project = base._project }
        local eff = { entries = { { target = "BaseTests" }, { target = "CoreTests" }, { target = "Gone" } }, source = base }
        assert.equals("Tests: BaseTests, CoreTests, Gone  (inherited from Tests)", text(helpers.test_targets_chunks(eff, cfg, nil, 200)))
        assert.equals("Tests: BaseTests, CoreTests, Gone", text(helpers.test_targets_chunks(eff, base, nil, 200)))
        local cut = text(helpers.test_targets_chunks(eff, base, nil, 30))
        assert.truthy(cut:find(", %+%d$"), cut)
        local targets = { BaseTests = fake_target("BaseTests"), CoreTests = fake_target("CoreTests") }
        local chunks = helpers.test_targets_chunks(eff, base, targets, 200)
        local warn
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn = c[1] end end
        assert.equals("⚠ Gone", warn)
        assert.equals("Tests: none (explicit)", text(helpers.test_targets_chunks({ entries = {}, source = base }, base, nil, 80)))
        assert.is_nil(helpers.test_targets_chunks(nil, base, nil, 80))
    end)
end)
