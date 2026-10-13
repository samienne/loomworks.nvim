-- Saved test targets (spec §1.3.4, §8.7, §16.9, §16.16, §8.9.2–§8.9.4, §17.6,
-- ui "Saved test targets line"): the `tests` array's parsing, resolution and
-- persistence, duplicates by occurrence, `lw test-target`, the `lw test` plan
-- (build-target and launch entries, arg expansion, argv order) and `--list`,
-- the trust stripping and regraft of entry args, launch rename, the
-- saved-targets TestUnit, owning-unit dispatch in the loomtest adapter, and
-- the status page line.

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
    for _, e in ipairs(entries or {}) do out[#out + 1] = e.name or "<invalid>" end
    return out
end

-- ===========================================================================
describe("tests field: shape and resolution (§1.3.4)", function()
    local SECTION = {
        tests = { "P1" },
        configurations = {
            Base = { inherits = "variant:default", tests = { "A", { "B", "--f" } } },
            Other = { inherits = "variant:default" },
            Child = { inherits = "Base" },
            Mix = { inherits = { "Other", "Base" } },
            Off = { inherits = "Base", tests = {} },
            Dups = { inherits = "variant:default", tests = { "A", { "A", "--two" }, "C", { "A" } } },
            Bad = { inherits = "variant:default", tests = { "A", { target = "X", args = { "--x" } }, 5, {}, { "Y", 3 } } },
            BadDecl = { inherits = "variant:default", tests = { targets = { "A" } } },
            BadChild = { inherits = "BadDecl" },
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

    it("keeps duplicates, told apart by occurrence index (not position)", function()
        local decl = tt.parse({ "A", { "A", "--two" }, "C", { "A" } }, "App/Dups")
        assert.same({ "A", "A", "C", "A" }, names(decl.entries))
        local idx = {}
        for _, e in ipairs(decl.entries) do idx[#idx + 1] = e.index end
        assert.same({ 1, 2, 1, 3 }, idx)
        assert.is_true(decl.entries[1].repeated)
        assert.is_nil(decl.entries[3].repeated)
        assert.same({ "--two" }, decl.entries[2].args)
        assert.is_nil(decl.entries[4].args)       -- ["A"] is the same entry as "A"
        assert.equals("A #2", tt.entry_label(decl.entries[2]))
        assert.equals("C", tt.entry_label(decl.entries[3]))
        assert.equals("target:A", tt.entry_id(decl.entries[1], "target"))
        assert.equals("launch:A#3", tt.entry_id(decl.entries[4], "launch"))
        -- Serialized: a string without args, an array with args.
        assert.same({ "A", { "A", "--two" }, "C", "A" }, tt.serialize(decl))
        -- From the file too (the working copy keeps them all).
        local ws = load(make_ws(SECTION, "Child"))
        local d = project(ws, "App"):get_configuration("Dups")
        assert.same({ "A", "A", "C", "A" }, names(d:own_test_targets()))
    end)

    it("an invalid entry is kept verbatim and is missing; a non-array declaration stops the walk", function()
        local raw = { "A", { target = "X", args = { "--x" } }, 5, {}, { "Y", 3 } }
        local decl = tt.parse(raw, "App/Bad")
        assert.equals(5, #decl.entries)
        assert.same({ "A", "<invalid>", "<invalid>", "<invalid>", "<invalid>" }, names(decl.entries))
        assert.same(raw, tt.serialize(decl))      -- written back verbatim
        local r = tt.resolve_entry(decl.entries[2], { targets = {}, level = "App/Bad" })
        assert.equals("missing", r.state)
        -- Even with targets unknown, an invalid entry is missing.
        assert.equals("missing", tt.resolve_entry(decl.entries[3], { level = "App/Bad" }).state)

        local d2, invalid = tt.parse({ targets = { "A" } }, "App/BadDecl")
        assert.is_true(d2.invalid)
        assert.same({}, d2.entries)
        assert.same({ targets = { "A" } }, tt.serialize(d2, invalid))

        local ws = load(make_ws(SECTION, "Child"))
        local p = project(ws, "App")
        local bd = p:get_configuration("BadDecl")
        local eff = p:get_configuration("BadChild"):test_targets()
        assert.equals(bd, eff.source)             -- not the project-wide P1
        assert.is_true(eff.invalid)
        assert.same({ targets = { "A" } }, bd:serialize_user_override().tests)
    end)

    it("an editor edit emits tests_invalidated only (no active_set_changed / LSP re-evaluation)", function()
        local ws = load(make_ws(SECTION, "Child"))
        local events = ws._core._deps.events
        local seen = {}
        local on_inv = function() seen.inv = (seen.inv or 0) + 1 end
        local on_set = function() seen.set = (seen.set or 0) + 1 end
        events.on("tests_invalidated", on_inv)
        events.on("active_set_changed", on_set)
        local ok, err = project(ws, "App"):get_configuration("Child"):set_test_targets({ { name = "Z" } })
        events.off("tests_invalidated", on_inv)
        events.off("active_set_changed", on_set)
        assert.is_true(ok, err)
        assert.truthy((seen.inv or 0) >= 1)
        assert.is_nil(seen.set)
    end)

    it("is persisted only where declared, and a module never sees it", function()
        local root = make_ws(SECTION, "Child")
        local ws = load(root)
        local p = project(ws, "App")
        assert.is_true(p:get_configuration("Other"):set_test_targets({ { name = "Z" }, { name = "Z", args = { "--z" } } }))
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        local cfgs = user.projects.App.typescript.configurations
        assert.same({ "Z", { "Z", "--z" } }, cfgs.Other.tests)
        assert.is_nil(cfgs.Child.tests)           -- derived: never a copy
        assert.same({ "P1" }, user.projects.App.typescript.tests)
        -- What the module is handed carries no `tests` anywhere.
        local tc = p:_type_config_for_module()
        assert.is_nil(tc.tests)
        for _, c in pairs(tc.configurations or {}) do assert.is_nil(c.tests) end
        assert.is_nil(p:get_configuration("Other").module_config.tests)
        -- …and a reload reads it back.
        local ws2 = load(root)
        assert.same({ "Z", "Z" }, names(project(ws2, "App"):get_configuration("Other"):own_test_targets()))
    end)

    it("never makes a unit stale; an older snapshot with `tests` compares without it", function()
        local unit = setmetatable({
            _configuration = { module_config = { variant = "Debug" } },
            _cached_options = {}, _cached_module_config = { variant = "Debug", tests = { "A" } },
            record_outdated = function() return false end,
            resolved_option_fingerprint = function() return {} end,
            env_changed = function() return false end,
            launcher_changed = function() return false end,
        }, { __index = ConfigUnit })
        assert.is_nil(ConfigUnit.stale_reason(unit))
        unit._cached_module_config = { variant = "Release", tests = { "A" } }
        assert.equals("module configuration changed", ConfigUnit.stale_reason(unit))
    end)

    it("`lw config set/unset tests…` is refused, naming lw test-target", function()
        local root = make_ws(SECTION, "Child")
        local r = capture(function() cli.cmd_configuration("set", root, "App", "Base", "tests", "A") end)
        assert.equals(1, r.exit_code)
        assert.truthy(r.stderr:find("lw test-target", 1, true))
        r = capture(function() cli.cmd_configuration("unset", root, "App", "Base", "tests") end)
        assert.equals(1, r.exit_code)
    end)

    it("resolves a launch configuration first, else an executable target; a trust-ignored launch is missing", function()
        local targets = {
            Both = { id = "Both", is_executable = function() return true end, display_name = function() return "Both" end },
            T = { id = "T", is_executable = function() return true end, display_name = function() return "T" end },
            Lib = { id = "Lib", is_executable = function() return false end, display_name = function() return "Lib" end },
            Ign = { id = "Ign", is_executable = function() return true end, display_name = function() return "Ign" end },
        }
        local ctx = {
            launches = { Both = { command = "tool" }, Chk = { target = "T" }, Dead = { target = "Lib" } },
            launch_ignored = function(n) return n == "Ign" end,
            targets = targets, level = "App/Tests",
        }
        local function r(n) return tt.resolve_entry({ name = n, index = 1 }, ctx) end
        assert.equals("launch", r("Both").kind)
        assert.is_true(r("Both").also_target)
        assert.equals("launch", r("Chk").kind)
        assert.equals(targets.T, r("Chk").target)
        assert.equals("missing", r("Dead").state)  -- its target is not an executable
        assert.equals("target", r("T").kind)
        assert.equals("missing", r("Lib").state)
        assert.equals("missing", r("Gone").state)
        local ign = r("Ign")                          -- never falls back to the same-named target
        assert.equals("missing", ign.state)
        assert.truthy(ign.reason:find("ignored", 1, true))
        -- Targets unknown: a command launch still resolves; a name does not.
        ctx.targets = nil
        assert.equals("ok", r("Both").state)
        assert.equals("unknown", r("T").state)
        assert.equals("unknown", r("Chk").state)
    end)
end)

-- ===========================================================================
describe("trust: entry args are program-bearing, regrafted by name + occurrence (§17.6)", function()
    local pf = require("loomworks.program_fields")
    local SHARED = { projects = { App = { cmake = {
        tests = { { "PW", "--pw" } },
        configurations = { Tests = { variant = "Release", tests = {
            "BaseTests", { "RenderTests", "--gtest_filter=-*Slow*" }, { "RenderTests", "--gtest_filter=*Slow*" } } } },
    } } } }

    local function stripped()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        return cfg, pf.strip(cfg, require("loomworks.modules"))
    end

    it("strips only the args; the names still apply; the diagnostic names the occurrence", function()
        local cfg, ignored = stripped()
        local labels = {}
        for _, e in ipairs(ignored) do labels[#labels + 1] = e.label end
        table.sort(labels)
        assert.same({ "projects.App.cmake.configurations.Tests.tests", "projects.App.cmake.configurations.Tests.tests",
            "projects.App.cmake.tests" }, labels)
        assert.same({ "BaseTests", "RenderTests", "RenderTests" },
            cfg.projects.App.type_config.configurations.Tests.tests)
        assert.same({ "PW" }, cfg.projects.App.tests)
        local msgs = {}
        for _, d in ipairs(pf.diagnostics(ignored, cfg)) do msgs[#msgs + 1] = d.message end
        assert.truthy(vim.tbl_contains(msgs, "loomworks.json sets projects.App.cmake.configurations.Tests.tests "
            .. "(RenderTests #2 args = --gtest_filter=*Slow*) — ignored: program settings are used only "
            .. "from your local config (lw help trust)"), vim.inspect(msgs))
        assert.truthy(vim.tbl_contains(msgs, "loomworks.json sets projects.App.cmake.tests "
            .. "(PW args = --pw) — ignored: program settings are used only from your local config (lw help trust)"))
    end)

    it("a working copy that gives the same occurrence args silences only that diagnostic", function()
        local cfg, ignored = stripped()
        local merged = vim.deepcopy(cfg)
        merged.projects.App.type_config.configurations.Tests.tests[3] = { "RenderTests", "--mine" }
        local msgs = {}
        for _, d in ipairs(pf.diagnostics(ignored, merged)) do msgs[#msgs + 1] = d.message end
        assert.equals(2, #msgs)                       -- #1 and PW still reported
        for _, m in ipairs(msgs) do assert.falsy(m:find("RenderTests #2", 1, true)) end
    end)

    it("regraft restores args by name + occurrence index, never by position", function()
        local _, ignored = stripped()
        -- Published list reordered, another name inserted, a working-copy arg on #1.
        local raw = { projects = { App = { cmake = {
            tests = { "PW" },
            configurations = { Tests = { tests = { "New", { "RenderTests", "--mine" }, "BaseTests", "RenderTests" } } } } } } }
        local _, dropped = pf.regraft(raw, ignored)
        local t = raw.projects.App.cmake.configurations.Tests.tests
        assert.same({ "New", { "RenderTests", "--mine" }, "BaseTests", { "RenderTests", "--gtest_filter=*Slow*" } }, t)
        assert.same({ { "PW", "--pw" } }, raw.projects.App.cmake.tests)
        assert.same({}, dropped)
    end)

    it("fewer published entries of a name: the surplus args are dropped and named; extra entries get none", function()
        local _, ignored = stripped()
        local raw = { projects = { App = { cmake = { tests = { "PW" },
            configurations = { Tests = { tests = { "RenderTests" } } } } } } }
        local _, dropped = pf.regraft(raw, ignored)
        assert.same({ { "RenderTests", "--gtest_filter=-*Slow*" } }, raw.projects.App.cmake.configurations.Tests.tests)
        assert.equals(1, #dropped)
        assert.truthy(dropped[1]:find("RenderTests #2 args = --gtest_filter=*Slow*", 1, true), dropped[1])
        -- More entries named N than the shared layer had: the extra one gets nothing.
        local raw2 = { projects = { App = { cmake = { tests = { "PW" },
            configurations = { Tests = { tests = { "RenderTests", "RenderTests", "RenderTests" } } } } } } }
        local _, d2 = pf.regraft(raw2, ignored)
        local t2 = raw2.projects.App.cmake.configurations.Tests.tests
        assert.equals("RenderTests", t2[3])
        assert.same({ "RenderTests", "--gtest_filter=*Slow*" }, t2[2])
        assert.same({}, d2)
    end)

    it("a published entry dropping the item drops its args silently (item not published)", function()
        local _, ignored = stripped()
        local raw = { projects = {} }
        local _, dropped = pf.regraft(raw, ignored)
        assert.same({}, dropped)
    end)
end)

-- ===========================================================================
-- Fakes for the headless plan: a unit with an optional batch runner, a saved
-- list (file shape) and parsed targets.
local function fake_target(name, kind)
    return { id = name, is_executable = function() return kind ~= "lib" end,
        display_name = function() return name end, artifact = name }
end

local function fake_unit(key, o)
    o = o or {}
    local cfg = { name = o.cfg or "Tests", _project = nil, variables = o.cfg_vars }
    local project = { key = key, launch = o.launch, variables = o.variables,
        _module = { impl = { parse_targets = function() return {} end } } }
    cfg._project = project
    local unit = {
        _project = project, targets = o.targets, _configuration = cfg, build_dir_value = o.build_dir,
        variant = function() return "Debug" end,
        configured_here = function() return o.here ~= false end,
        tool_object = function() return o.foreign and { key = "kit", execution_platform = function() return "arm64" end } or nil end,
        batch_runner_test_units = function()
            return o.batch and { { run_command_all = function() return { cmd = { "ctest" } } end } } or {}
        end,
        saved_test_targets = function()
            if not o.saved then return nil end
            local decl = tt.parse(o.saved, key .. "/Tests")
            return { entries = decl.entries, source = cfg, invalid = decl.invalid }
        end,
        build_dir = function() return o.build_dir end,
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
    local probed

    before_each(function()
        probed = {}
        orig_plan, orig_probe = ov.plan_profile_test, gtest.probe_sync
        gtest.probe_sync = function(exe) probed[#probed + 1] = exe; return nil end
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

    --- A fake LaunchTarget for a resolved candidate: a build target runs
    --- /bin/<name>; a launch runs its config's program with its own args, and
    --- records its deploy.
    local function fake_lt(c, log, deploy_fail)
        local cfg = c.kind == "launch" and c.project.launch[c.name] or nil
        return {
            _launch_config = cfg,
            is_valid = function() return true end,
            deploy_sync = function()
                log[#log + 1] = "deploy " .. c.name
                if deploy_fail and deploy_fail[c.name] then return false, "boom" end
                return true
            end,
            resolve_launch_spec = function()
                if cfg then
                    return { cmd = cfg.command or ("/bin/" .. cfg.target), args = vim.deepcopy(cfg.args or {}),
                        cwd = cfg.working_dir or "/", env = cfg.env }
                end
                return { cmd = "/bin/" .. c.name, args = {}, cwd = "/" }
            end,
        }
    end

    local function run_plan(profile, opts, codes, ws, deploy_fail)
        local ran, built, log = {}, nil, {}
        local deps = {
            build = function(_, _, keep) built = keep end,
            run_spec = function(step)
                local line = table.concat(step.cmd, " ")
                ran[#ran + 1] = line
                log[#log + 1] = "run " .. line
                if step.cwd and step.cwd ~= "/" then log[#log + 1] = "cwd " .. step.cwd end
                for k, v in pairs(step.env or {}) do log[#log + 1] = "env " .. k .. "=" .. v end
                return (codes or {})[step.cmd[2] or step.cmd[1]] or 0
            end,
            launch_target = function(_, _, c) return fake_lt(c, log, deploy_fail) end,
        }
        opts.extra = opts.extra or {}
        opts.dev = opts.dev or cli._new_device_opts()
        local r = capture(function() return cli._test_plan(ws or { root = "/" }, profile, opts, deps) end)
        r.ran, r.built, r.log = ran, built, log
        return r
    end

    local function two_units()
        local a, ppa = fake_unit("A", { batch = true, saved = { "X", { "Y", "--y" } },
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
        -- Not a framework executable: judged on its exit status, said so.
        assert.truthy(r.stdout:find("A: X%s+passed  %(exit status only — no per%-case results%)"), r.stdout)
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

    it("a missing, non-executable or invalid saved entry fails before anything runs", function()
        local a, ppa = fake_unit("A", { batch = true, saved = { "X", "Gone", "Lib", "Gone", { k = 1 } },
            targets = { X = fake_target("X"), Lib = fake_target("Lib", "lib") },
            launch = { run = { command = "tool" } } })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.equals(1, r.exit_code)
        assert.same({}, r.ran)
        assert.truthy(r.stderr:find("saved test entry 'Gone #1' (A/Tests): not a target or launch of A/Tests", 1, true), r.stderr)
        assert.truthy(r.stderr:find("'Lib' (A/Tests): not an executable target of A/Tests", 1, true))
        assert.truthy(r.stderr:find("lw test-target remove Dev:kit A:Gone --index 2 --config Tests", 1, true))
        assert.truthy(r.stderr:find("executables: A:X", 1, true))
        assert.truthy(r.stderr:find("launch configurations: A:run", 1, true))
        assert.truthy(r.stderr:find("invalid entry {\"k\":1}", 1, true), r.stderr)
        assert.is_not_nil(a)
        -- A non-array declaration fails the same way.
        local _, ppb = fake_unit("B", { saved = { targets = { "X" } }, targets = { X = fake_target("X") } })
        local d = run_plan(fake_profile({ ppb }), {})
        assert.equals(1, d.exit_code)
        assert.truthy(d.stderr:find("is not an array", 1, true))
    end)

    it("a trust-ignored launch never falls back to a same-named target", function()
        local _, ppa = fake_unit("A", { saved = { "chk" }, targets = { chk = fake_target("chk") } })
        local ws = { root = "/", _shared_ignored = { { kind = "launch", path = { "projects", "A", "launch", "chk" } } } }
        local r = run_plan(fake_profile({ ppa }), {}, nil, ws)
        assert.equals(1, r.exit_code)
        assert.same({}, r.ran)
        assert.truthy(r.stderr:find("launch 'chk' of A/Tests is ignored", 1, true), r.stderr)
    end)

    it("launch entries: deploy, then program + launch env/cwd + own args + entry args; no results option", function()
        local _, ppa = fake_unit("A", {
            saved = { { "chk", "--entry" }, "tool", { "X", "--x" } },
            targets = { X = fake_target("X"), chk = fake_target("chk") },
            launch = {
                chk = { target = "X", args = { "--check" }, env = { MODE = "t" }, working_dir = "/w" },
                tool = { command = "/usr/bin/tool", args = { "--t" } },
            },
        })
        local r = run_plan(fake_profile({ ppa }), { sel = "saved", extra = { "--fwd" } })
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bin/X --check --entry --fwd", "/usr/bin/tool --t --fwd", "/bin/X --x --fwd" }, r.ran)
        assert.same({ "deploy chk", "run /bin/X --check --entry --fwd", "cwd /w", "env MODE=t",
            "deploy tool", "run /usr/bin/tool --t --fwd", "run /bin/X --x --fwd" }, r.log)
        -- A command launch is never probed; a target-backed one and a target are.
        assert.same({ "/bin/X", "/bin/X" }, probed)
        local hdr = {}
        for l in r.stdout:gmatch("==> %[test%] ([^\n]+)") do hdr[#hdr + 1] = l end
        assert.same({ "A: chk", "A: tool", "A: X" }, hdr)
    end)

    it("the results option goes right after the program, before the launch's own args", function()
        gtest.probe_sync = function() return "gtest" end
        local _, ppa = fake_unit("A", { saved = { { "chk", "--entry" } }, targets = { X = fake_target("X") },
            launch = { chk = { target = "X", args = { "--check" } } } })
        local orig_parse = gtest.parse_xml_results
        local r = run_plan(fake_profile({ ppa }), {})
        gtest.parse_xml_results = orig_parse
        assert.equals(1, #r.ran)
        assert.truthy(r.ran[1]:match("^/bin/X %-%-gtest_output=xml:%S+ %-%-check %-%-entry$"), r.ran[1])
    end)

    it("a failed deploy fails its step without running the program; the others still run", function()
        local _, ppa = fake_unit("A", { saved = { "chk", "X" }, targets = { X = fake_target("X") },
            launch = { chk = { command = "/usr/bin/chk" } } })
        local r = run_plan(fake_profile({ ppa }), {}, nil, nil, { chk = true })
        assert.equals(1, r.exit_code)
        assert.same({ "/bin/X" }, r.ran)
        assert.truthy(r.stdout:find("A: chk%s+FAILED %(deploy failed: boom%)"), r.stdout)
    end)

    it("duplicates: one step per entry, labels with the occurrence index", function()
        local _, ppa = fake_unit("A", { saved = { "T", { "T", "--2" } }, targets = { T = fake_target("T") } })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bin/T", "/bin/T --2" }, r.ran)
        local hdr = {}
        for l in r.stdout:gmatch("==> %[test%] ([^\n]+)") do hdr[#hdr + 1] = l end
        assert.same({ "A: T #1", "A: T #2" }, hdr)
        local paths = {}
        local orig = cli._run_test_executable
        cli._run_test_executable = function(_, _, o) paths[#paths + 1] = o.junit_path; return false, {} end
        run_plan(fake_profile({ ppa }), { junit = "/o/r.xml" })
        cli._run_test_executable = orig
        assert.same({ "/o/r.A-T-1.xml", "/o/r.A-T-2.xml" }, paths)
    end)

    it("args expand built-in and project variables (two-pass); names never expand", function()
        local _, ppa = fake_unit("A", {
            saved = { { "T", "--scale=${scale}", "${build_dir}/out", "${lw_no_such_var_xyz}" } },
            targets = { T = fake_target("T") }, build_dir = "/bd",
            variables = { scale = { type = "string", default = "1" }, out = { type = "path", default = "${build_dir}/o" } },
            cfg_vars = { scale = "7" },
        })
        local r = run_plan(fake_profile({ ppa }), {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bin/T --scale=7 /bd/out ${lw_no_such_var_xyz}" }, r.ran)
        -- A name is never expanded: `${scale}` stays a (missing) name.
        local _, ppb = fake_unit("B", { saved = { "T${scale}" }, targets = { T7 = fake_target("T7") },
            variables = { scale = { type = "string", default = "7" } } })
        local m = run_plan(fake_profile({ ppb }), {})
        assert.equals(1, m.exit_code)
        assert.truthy(m.stderr:find("'T${scale}'", 1, true), m.stderr)
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

    it("--junit: one file per step, the label suffix across all steps; exit-only steps get one case", function()
        local ws_root = vim.fn.tempname():gsub("\\", "/")
        local profile = two_units()
        local r = run_plan(profile, { junit = ws_root .. "/out/r.xml" }, { ["/bin/Z"] = 3 })
        assert.equals(1, r.exit_code)
        local f = assert(io.open(ws_root .. "/out/r.Z.xml", "r"))
        local xml = f:read("*a"); f:close()
        assert.truthy(xml:find('tests="1" failures="1"', 1, true), xml)
        local g = assert(io.open(ws_root .. "/out/r.X.xml", "r"))
        local xml2 = g:read("*a"); g:close()
        assert.truthy(xml2:find('tests="1" failures="0"', 1, true), xml2)
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
        local _, ppa = fake_unit("A", { batch = true, here = false, saved = { { "X", "--x" } } })
        local profile = fake_profile({ ppa })
        local r = capture(function() return cli._test_plan_report({}, profile, nil, true) end)
        local j = vim.json.decode(r.stdout)
        assert.equals("Dev:kit", j.profile)
        assert.equals("A", j.units[1].project)
        assert.is_table(j.units[1].batch)
        local e = j.units[1].saved.entries[1]
        assert.equals("X", e.name)
        assert.equals(1, e.index)
        assert.same({ "--x" }, e.args)
        assert.same({ "--x" }, e.args_expanded)
        assert.equals("unknown", e.state)
        assert.equals(vim.NIL, e.kind)              -- unknown kind is null
        assert.equals("own", e.source)
        assert.equals("own", j.units[1].saved.source)
    end)

    it("reports each entry's kind, occurrence index and expanded args", function()
        local _, ppa = fake_unit("A", { build_dir = "/bd",
            saved = { "X", "L", { "L", "--l" }, { "X", "${build_dir}/x" }, { "X", "${lw_no_such_var_xyz}" } },
            targets = { X = fake_target("X"), L = fake_target("L") },
            launch = { L = { command = "tool" } } })
        local r = capture(function() return cli._test_plan_report({}, fake_profile({ ppa }), nil, true) end)
        local es = vim.json.decode(r.stdout).units[1].saved.entries
        local got = {}
        for _, e in ipairs(es) do got[#got + 1] = { e.name, e.index, e.kind, e.state } end
        assert.same({ { "X", 1, "target", "not built" }, { "L", 1, "launch", "ok" }, { "L", 2, "launch", "ok" },
            { "X", 2, "target", "not built" }, { "X", 3, "target", "not built" } }, got)
        assert.same({ "${build_dir}/x" }, es[4].args)
        assert.same({ "/bd/x" }, es[4].args_expanded)
        assert.equals(vim.NIL, es[5].args_expanded)  -- an unresolved reference
        -- The text form shows the kind and the occurrence.
        local t = capture(function() return cli._test_plan_report({}, fake_profile({ ppa }), nil, false) end)
        assert.truthy(t.stdout:find("L #2  --l  [launch, also a build target; own]  ok", 1, true), t.stdout)
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
        Tests = { inherits = "variant:default", tests = { "BaseTests", "X1" } },
        Rel = { inherits = "Tests" },
    } }

    it("add writes to the mapped user configuration and says where", function()
        local root = make_ws(SECTION, "Tests")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("saved CoreTests (target) on App/Tests (used by", 1, true), r.stdout)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "BaseTests", "X1", "CoreTests" },
            user.projects.App.typescript.configurations.Tests.tests)
    end)

    it("add on a generated mapping writes project-wide; args after --; a present name appends", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root); targets_for(ws)
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests", "--", "--a", "${build_dir}" }, ws) end)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ { "CoreTests", "--a", "${build_dir}" } }, user.projects.App.typescript.tests)  -- unexpanded
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests", "--", "--a", "${build_dir}" }, ws) end)
        assert.truthy(r.stdout:find("saved CoreTests #2", 1, true), r.stdout)   -- always writes
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "BaseTests" }, ws) end)
        user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ { "CoreTests", "--a", "${build_dir}" }, { "CoreTests", "--a", "${build_dir}" }, "BaseTests" },
            user.projects.App.typescript.tests)
    end)

    it("add resolves a launch configuration of the project first", function()
        local root = make_ws(SECTION, "Tests")
        local ws = load(root)
        local p = targets_for(ws)
        p.launch = { BaseTests = { command = "tool" }, chk = { command = "tool", args = { "--c" } } }
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "chk", "BaseTests" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("saved chk (launch), BaseTests #2 (launch)", 1, true), r.stdout)
        -- A launch name needs no configured targets.
        local ws2 = load(root)
        project(ws2, "App").launch = { only = { command = "tool" } }
        local impl = project(ws2, "App")._module.impl
        local orig = impl.parse_targets
        impl.parse_targets = function() return nil end
        local ok = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "only" }, ws2) end)
        impl.parse_targets = orig
        assert.is_nil(ok.exit_code, ok.stderr)
    end)

    it("refuses a name that is neither (listing executables + launches) and unknown targets", function()
        local root = make_ws(SECTION, "Tests")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "libcore" }, ws) end)
        assert.equals(1, r.exit_code)
        assert.truthy(r.stderr:find("App:BaseTests", 1, true))
        assert.truthy(r.stderr:find("launch configurations", 1, true))
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
        assert.same({ "BaseTests", "X1", "NewTests" }, user.projects.App.typescript.configurations.Tests.tests)
    end)

    it("remove drops every entry of a name; --index <k> drops only that occurrence", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root); targets_for(ws)
        assert.is_true(project(ws, "App"):set_test_targets({ { name = "BaseTests" },
            { name = "CoreTests" }, { name = "BaseTests", args = { "--b" } }, { name = "BaseTests", args = { "--c" } } }))
        local r = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "BaseTests", "--index", "2" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "BaseTests", "CoreTests", { "BaseTests", "--c" } }, user.projects.App.typescript.tests)
        -- An index with no such entry is refused, listing that name's entries.
        local bad = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "BaseTests", "--index", "5" }, ws) end)
        assert.equals(1, bad.exit_code)
        assert.truthy(bad.stderr:find("#1, #2  --c", 1, true), bad.stderr)
        -- --index takes one name.
        local two = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "BaseTests", "CoreTests", "--index", "1" }, ws) end)
        assert.equals(2, two.exit_code)
        capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "BaseTests" }, ws) end)
        user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ "CoreTests" }, user.projects.App.typescript.tests)
    end)

    it("an edit on an inheriting level copies the inherited list first and says so", function()
        local root = make_ws(SECTION, "Rel")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "X1" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("copied 2 inherited entries from Tests", 1, true), r.stdout)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        local cfgs = user.projects.App.typescript.configurations
        assert.same({ "BaseTests" }, cfgs.Rel.tests)
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
        assert.same({}, user.projects.App.typescript.configurations.Rel.tests)
        local r = capture(function() return cli._tt_clear(root, { "test-target", "clear", "Dev" }, ws) end)
        assert.truthy(r.stdout:find("cleared App/Rel", 1, true), r.stdout)
        user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.is_nil(user.projects.App.typescript.configurations.Rel.tests)
    end)

    it("list shows the effective list in order with occurrence, kind and source", function()
        local root = make_ws(SECTION, "Rel")
        local ws = load(root)
        local r = capture(function() return cli._tt_list(root, nil, ws) end)
        assert.truthy(r.stdout:find("inherited from Tests", 1, true), r.stdout)
        assert.truthy(r.stdout:find("BaseTests", 1, true))
        local p = targets_for(ws)
        p.launch = { X1 = { command = "tool" } }
        assert.is_true(p:get_configuration("Tests"):set_test_targets({ { name = "BaseTests" },
            { name = "X1", args = { "--x" } }, { name = "BaseTests", args = { "--b" } } }))
        local l = capture(function() return cli._tt_list(root, nil, ws) end)
        assert.truthy(l.stdout:find("X1  --x  [launch]", 1, true), l.stdout)
        assert.truthy(l.stdout:find("BaseTests #2  --b", 1, true), l.stdout)
    end)
end)

-- ===========================================================================
describe("launch rename carries saved entries (§8.7)", function()
    it("renames every entry naming the launch, keeping args and position", function()
        local root = make_ws({ configurations = {
            Tests = { inherits = "variant:default" }, Other = { inherits = "variant:default" } } }, "Tests")
        local ws = load(root)
        local p = project(ws, "App")
        p.launch = { chk = { command = "tool" } }
        assert.is_true(p:set_test_targets({ { name = "chk" } }))
        assert.is_true(p:get_configuration("Tests"):set_test_targets({ { name = "A" },
            { name = "chk", args = { "--x" } }, { name = "chk" } }))
        local changed, err = p:rename_launch_config("chk", "check")
        assert.is_true(changed, err)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        local tc = user.projects.App.typescript
        assert.same({ "check" }, tc.tests)
        assert.same({ "A", { "check", "--x" }, "check" }, tc.configurations.Tests.tests)
        assert.is_nil(tc.configurations.Other and tc.configurations.Other.tests)
        assert.same({ "A", "check", "check" }, names(p:get_configuration("Tests"):own_test_targets()))
    end)
end)

-- ===========================================================================
describe("ConfigUnit + saved-targets TestUnit (§8.9.2–§8.9.3)", function()
    it("merge keeps the module's entry for a once-listed target; launch / repeated entries stay beside", function()
        local mod_tu = { is_saved_targets = nil }
        local saved_tu = { is_saved_targets = true }
        local merged = ConfigUnit._merge_test_entries({ mod_tu, saved_tu }, {
            { { id = "target:T", executable = "/b/T" }, { id = "test:S.a", parent = "target:T", executable = "/b/T" } },
            { { id = "target:T", executable = "/b/T", args = { "--q" }, saved_kind = "target" },
              { id = "test:S.a", parent = "target:T" },
              { id = "target:U", executable = "/b/U", saved_kind = "target" },
              { id = "launch:L", executable = "/b/T", saved_kind = "launch" },
              { id = "target:U#2", executable = "/b/U", saved_kind = "target", saved_repeated = true } },
        })
        local ids = {}
        for _, e in ipairs(merged) do ids[#ids + 1] = e.id end
        assert.same({ "target:T", "test:S.a", "target:U", "launch:L", "target:U#2" }, ids)
        assert.same({ "--q" }, merged[1].saved_args)
    end)

    local function saved_unit(entries_raw, launch)
        local unit
        local project = { key = "App", launch = launch }
        local ws = { _projects = { project }, _profiles = {} }
        local profile = { key = "Dev", project = function(_, k) return k == "App" and { _config_unit = unit } or nil end }
        unit = {
            _project = project, _workspace = ws,
            build_dir = function() return "/b" end,
            ensure_targets = function() return unit.targets end,
            saved_test_targets = function()
                local d = tt.parse(entries_raw, "App/Tests")
                return { entries = d.entries, source = { name = "Tests", _project = project }, invalid = d.invalid }
            end,
            context_profile = function() return profile end,
            configured_here = function() return true end,
            run_env = function() return nil end,
        }
        unit.targets = {
            Run = Target.new(unit, "Run", { type = "executable", artifact = "Run" }),
            Lib = Target.new(unit, "Lib", { type = "static_library", artifact = "Lib" }),
        }
        return unit
    end

    it("discovery: target / launch / repeated ids, errored missing, library and invalid entries", function()
        local SavedTU = require("loomworks.test_units.saved_targets")
        local deployed = {}
        local orig_lt = package.loaded["loomworks.launch_target"]
        package.loaded["loomworks.launch_target"] = { new = function(_, _, d)
            return {
                deploy_sync = function() deployed[#deployed + 1] = d.launch; return true end,
                resolve_launch_spec = function()
                    return { cmd = "/usr/bin/tool", args = { "--own" }, cwd = "/w", env = { M = "1" } }
                end,
            }
        end }
        local unit = saved_unit({ { "Run", "--r" }, "Gone", "Lib", { "Run", "--again" }, { "chk", "--e" }, 7 },
            { chk = { command = "tool" } })
        local tu = SavedTU.new(unit)
        local entries = tu:discover()
        local ids = {}
        for _, e in ipairs(entries) do ids[#ids + 1] = e.id end
        assert.equals("target:Run", ids[1])
        assert.equals("target:Gone", ids[2])
        assert.equals("target:Run#2", ids[4])
        assert.equals("launch:chk", ids[5])
        assert.is_true(entries[1].runnable)
        assert.is_false(entries[2].runnable)
        assert.equals("errored", entries[2].status)
        assert.equals("not a target or launch of App/Tests (removed or renamed?)", entries[2].message)
        assert.equals("not an executable target of App/Tests", entries[3].message)
        assert.is_false(entries[6].runnable)          -- invalid entry
        assert.truthy(entries[6].message:find("invalid entry", 1, true))
        local cmd = tu:test_command("target:Run#2")
        assert.equals("--again", cmd.cmd[#cmd.cmd])
        local lc = tu:test_command("launch:chk")
        package.loaded["loomworks.launch_target"] = orig_lt
        assert.same({ "chk" }, deployed)             -- deploy ran before the command
        assert.same({ "/usr/bin/tool", "--own", "--e" }, lc.cmd)
        assert.equals("/w", lc.cwd)
        assert.equals("1", lc.env.M)
        assert.is_nil(lc.output_path)                -- no results option for a command launch
        assert.is_nil(tu:run_command_all())
        assert.is_nil(tu:test_command_all())
    end)

    it("a non-array declaration shows one errored entry", function()
        local SavedTU = require("loomworks.test_units.saved_targets")
        local tu = SavedTU.new(saved_unit({ targets = { "Run" } }))
        local entries = tu:discover()
        assert.equals(1, #entries)
        assert.equals("errored", entries[1].status)
    end)

    it("test_units appends the saved TestUnit; batch_runner_test_units never has it; a list change invalidates", function()
        local list = { { name = "T" } }
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
        list = { { name = "T" }, { name = "T", args = { "--2" } } }
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
            test_command = function(_, tid, o) return { cmd = { "run", tid, o and o.gtest_filter or nil } } end,
            test_command_all = all and function() return { cmd = { "all", id } } end or nil,
            is_saved_targets = not all or nil,
            parse_results = function() return { { test_id = id, status = "passed" } } end,
        }
    end

    it("run-all covers every TestUnit of every unit; run / parse go through the owner", function()
        local m1, s1, m2 = tu("target:A", true), tu("launch:S", false), tu("target:B", true)
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
        assert.same({ "all target:A", "run launch:S", "all target:B" }, cmds)
        local one = captured.run("target:B")
        assert.same({ "run", "target:B" }, one.cmd)
        assert.equals(m2, one._test_unit)
        assert.same("target:B", captured.parse_results("/x.xml", one)[1].test_id)
        -- A suite of a saved `launch:` entry keeps its kind.
        local suite = captured.run_suite("launch:S::Suite")
        assert.same({ "run", "launch:S", "Suite.*" }, suite.cmd)
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

    it("names in order (once per entry), the source when not own, +N to the width, ⚠ on missing", function()
        local base = { name = "Tests", _project = { key = "App" } }
        local cfg = { name = "Rel", _project = base._project }
        local eff = { entries = tt.parse({ "BaseTests", "CoreTests", { "CoreTests", "--x" }, "Gone" }).entries, source = base }
        assert.equals("Tests: BaseTests, CoreTests, CoreTests, Gone  (inherited from Tests)",
            text(helpers.test_targets_chunks(eff, cfg, nil, 200)))
        assert.equals("Tests: BaseTests, CoreTests, CoreTests, Gone", text(helpers.test_targets_chunks(eff, base, nil, 200)))
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

    it("a launch name is not missing; a trust-ignored launch and an invalid list are flagged", function()
        local proj = { key = "App", launch = { chk = { command = "tool" } },
            _workspace = { _shared_ignored = { { kind = "launch", path = { "projects", "App", "launch", "ign" } } } } }
        local base = { name = "Tests", _project = proj }
        local eff = { entries = tt.parse({ "chk", "ign" }).entries, source = base }
        local chunks = helpers.test_targets_chunks(eff, base, {}, 200, proj)
        local warn = {}
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn[#warn + 1] = c[1] end end
        assert.same({ "⚠ ign" }, warn)
        -- Unconfigured (targets unknown): the ignored launch is still flagged.
        chunks = helpers.test_targets_chunks(eff, base, nil, 200, proj)
        warn = {}
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn[#warn + 1] = c[1] end end
        assert.same({ "⚠ ign" }, warn)
        assert.truthy(text(helpers.test_targets_chunks({ entries = {}, source = base, invalid = true }, base, nil, 80))
            :find("invalid", 1, true))
    end)
end)
