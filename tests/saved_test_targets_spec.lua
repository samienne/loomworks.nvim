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
        -- A launch with neither `command` nor `target` is still the launch
        -- (missing), never the same-named build target.
        targets.Empty = { id = "Empty", is_executable = function() return true end, display_name = function() return "Empty" end }
        ctx.launches.Empty = { args = { "--x" } }
        local empty = r("Empty")
        assert.equals("launch", empty.kind)
        assert.equals("missing", empty.state)
        assert.is_nil(empty.target)
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
                        junit_dest = opts.junit_dest_for and opts.junit_dest_for(label, u) or nil,
                        -- A self-rebuilding runner without a no-rebuild option (§8.9.2).
                        refused = (opts.no_rebuild and u._cannot_skip_rebuild) and "cannot skip" or nil,
                        no_rebuild = opts.no_rebuild }
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

    local function run_plan(profile, opts, codes, ws, deploy_fail, more)
        local ran, built, log = {}, nil, {}
        local deps = more or {}
        for k, v in pairs({
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
        }) do deps[k] = v end
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

    it("the summary line of a step with per-case results names its skipped and disabled counts", function()
        local _, ppa = fake_unit("A", { saved = { "X", "Y" }, targets = { X = fake_target("X"), Y = fake_target("Y") } })
        local orig = cli._run_test_executable
        cli._run_test_executable = function(_, _, o)
            local c = require("loomworks.remote.test_run").count(o.label == "X" and {
                { status = "passed" }, { status = "skipped" }, { status = "skipped" },
                { status = "skipped", disabled = true },
            } or { { status = "passed" } })
            return false, {}, c, false
        end
        local r = run_plan(fake_profile({ ppa }), {})
        cli._run_test_executable = orig
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stdout:find("A: X%s+passed, 2 skipped, 1 disabled\n"), r.stdout)
        assert.truthy(r.stdout:find("A: Y%s+passed\n"), r.stdout)
    end)

    it("the summary line of a failed step with per-case results keeps its counts", function()
        local _, ppa = fake_unit("A", { saved = { "X", "Y" }, targets = { X = fake_target("X"), Y = fake_target("Y") } })
        local orig = cli._run_test_executable
        cli._run_test_executable = function(_, _, o)
            if o.label == "X" then
                local c = require("loomworks.remote.test_run").count({
                    { status = "passed" }, { status = "passed" }, { status = "failed", test_id = "test:S.f" },
                    { status = "skipped" }, { status = "skipped", disabled = true },
                })
                return true, { "exit status 1", "1 failed test" }, c, false
            end
            return true, { "exit status 3" }, require("loomworks.remote.test_run").count(nil), false
        end
        local r = run_plan(fake_profile({ ppa }), {})
        cli._run_test_executable = orig
        assert.equals(1, r.exit_code)
        assert.truthy(r.stdout:find("A: X%s+FAILED %(exit status 1, 1 failed test, 2 passed, 1 skipped, 1 disabled%): S%.f\n"),
            r.stdout)
        assert.truthy(r.stdout:find("A: Y%s+FAILED %(exit status 3%)\n"), r.stdout)
    end)

    it("the summary line of a failed step names at most 10 failing tests, then 'and K more'", function()
        local _, ppa = fake_unit("A", { saved = { "X" }, targets = { X = fake_target("X") } })
        local orig = cli._run_test_executable
        cli._run_test_executable = function()
            local results = {}
            for i = 1, 12 do results[i] = { status = "failed", test_id = "test:S.t" .. i } end
            return true, { "exit status 1", "12 failed tests" }, require("loomworks.remote.test_run").count(results), false
        end
        local r = run_plan(fake_profile({ ppa }), {})
        cli._run_test_executable = orig
        assert.equals(1, r.exit_code)
        assert.truthy(r.stdout:find("A: X%s+FAILED %(exit status 1, 12 failed tests, 0 passed%): "
            .. "S%.t1, S%.t2, S%.t3, S%.t4, S%.t5, S%.t6, S%.t7, S%.t8, S%.t9, S%.t10, and 2 more\n"), r.stdout)
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

    it("foreign without saved targets, beside other steps, is skipped with a note naming it", function()
        local _, ppa = fake_unit("A", { batch = true, foreign = true })
        local _, ppb = fake_unit("B", { saved = { "X" }, targets = { X = fake_target("X") } })
        local r = run_plan(fake_profile({ ppa, ppb }), {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bin/X" }, r.ran)
        assert.truthy(r.stderr:find("A: skipped", 1, true), r.stderr)
        assert.truthy(r.stderr:find("(arm64)", 1, true), r.stderr)
        assert.truthy(r.stderr:find("lw test-target add", 1, true), r.stderr)
        -- A foreign unit WITH saved entries gets the batch-dropped note, not this one.
        local _, ppc = fake_unit("C", { batch = true, foreign = true, saved = { "X" },
            targets = { X = fake_target("X") } })
        local c = run_plan(fake_profile({ ppc }), {})
        assert.is_nil(c.stderr:find("C: skipped", 1, true), c.stderr)
    end)

    it("foreign skip note under --discovered: no saved-target claim or advice", function()
        -- A has saved targets, but --discovered leaves them out of the plan.
        local _, ppa = fake_unit("A", { batch = true, foreign = true, saved = { "X" },
            targets = { X = fake_target("X") } })
        local _, ppb = fake_unit("B", { batch = true })
        local r = run_plan(fake_profile({ ppa, ppb }), { sel = "discovered" })
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stderr:find("A: skipped — its discovered tests cannot run on this host (arm64)", 1, true),
            r.stderr)
        assert.is_nil(r.stderr:find("no saved test targets", 1, true), r.stderr)
        assert.is_nil(r.stderr:find("lw test-target add", 1, true), r.stderr)
    end)

    it("foreign skip note when its saved targets are unsupported: says so, no add advice", function()
        local _, ppa = fake_unit("A", { batch = true, foreign = true, saved = { "X" },
            targets = { X = fake_target("X") } })
        ppa._config_unit._project._module.impl.parse_targets = nil
        local _, ppb = fake_unit("B", { saved = { "Y" }, targets = { Y = fake_target("Y") } })
        local r = run_plan(fake_profile({ ppa, ppb }), {})
        assert.is_nil(r.exit_code, r.stderr)
        assert.truthy(r.stderr:find("A: skipped", 1, true), r.stderr)
        assert.truthy(r.stderr:find("its saved test targets are not supported by its module", 1, true), r.stderr)
        -- Exactly one note for A: the skip note already says the targets are
        -- unsupported, so the generic "— ignored" note must not repeat it.
        local _, n_a = r.stderr:gsub("lw: note: A:", "")
        assert.are.equal(1, n_a, r.stderr)
        assert.is_nil(r.stderr:find("ignored", 1, true), r.stderr)
        assert.is_nil(r.stderr:find("no saved test targets", 1, true), r.stderr)
        assert.is_nil(r.stderr:find("lw test-target add", 1, true), r.stderr)
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

    describe("--no-build (§16.16 Skipping the build)", function()
        local function all_built() return true, "/bd/x" end

        it("builds and deploys nothing, asks runners not to rebuild, holds the locks", function()
            local _, ppa = fake_unit("A", { batch = true, build_dir = "/bd",
                saved = { "chk", "tool", "X" },
                targets = { X = fake_target("X") },
                launch = { chk = { target = "X" }, tool = { command = "/usr/bin/tool" } } })
            local locked, in_lock, checked = {}, false, {}
            local more = {
                with_locks = function(p, action, fn)
                    locked[#locked + 1] = p.key .. " " .. action
                    in_lock = true; fn(); in_lock = false
                end,
                artifact_built = function(_, t) checked[#checked + 1] = t.id; return true, "/bd/" .. t.id end,
            }
            local r = run_plan(fake_profile({ ppa }), { no_build = true }, nil, nil, nil, more)
            assert.is_nil(r.exit_code, r.stderr)
            assert.is_nil(r.built)                                  -- deps.build never called
            assert.same({ "Dev:kit build" }, locked)
            assert.same({ "ctest A:Debug", "/bin/X", "/usr/bin/tool", "/bin/X" }, r.ran)
            for _, l in ipairs(r.log) do assert.falsy(l:match("^deploy "), l) end  -- no deploy
            assert.same({ "X", "X" }, checked)          -- target-backed launch + target; not the command
            assert.truthy(r.stdout:find("TESTS OK", 1, true))
        end)

        it("forwards no_rebuild to the batch runners", function()
            local seen
            local stub = ov.plan_profile_test
            ov.plan_profile_test = function(profile, opts)
                if opts.junit_dest_for then seen = opts.no_rebuild end
                return stub(profile, opts)
            end
            local _, ppa = fake_unit("A", { batch = true })
            local r = run_plan(fake_profile({ ppa }), { no_build = true })
            assert.is_nil(r.exit_code, r.stderr)
            assert.is_true(seen)
            r = run_plan(fake_profile({ ppa }), {})
            assert.is_nil(seen)
        end)

        it("unconfigured units and unbuilt executables fail the whole run before any step", function()
            local _, ppa = fake_unit("A", { batch = true, here = false })
            local _, ppb = fake_unit("B", { batch = true, build_dir = "/nonexistent-lw-bd",
                saved = { "X", { "X", "--2" }, "Y" }, targets = { X = fake_target("X"), Y = fake_target("Y") } })
            -- Unconfigured, but only a command launch: needs neither check.
            local _, ppc = fake_unit("C", { here = false, saved = { "tool" },
                launch = { tool = { command = "/usr/bin/tool" } } })
            -- Unconfigured with a target entry: one line for the unit.
            local _, ppd = fake_unit("D", { here = false, saved = { "Z", "W" } })
            local more = { artifact_built = function(_, t) return t.id == "Y", "/nonexistent-lw-bd/" .. t.id end }
            local r = run_plan(fake_profile({ ppa, ppb, ppc, ppd }), { no_build = true }, nil, nil, nil, more)
            assert.equals(1, r.exit_code)
            assert.same({}, r.ran)
            assert.is_nil(r.built)
            local e = r.stderr
            assert.truthy(e:find("A: not configured on this machine", 1, true), e)
            assert.truthy(e:find("saved test entry 'X #1' (", 1, true), e)
            assert.truthy(e:find("saved test entry 'X #2' (", 1, true), e)
            assert.truthy(e:find("not built (/nonexistent-lw-bd/X)", 1, true), e)
            assert.falsy(e:find("'Y'", 1, true), e)
            assert.falsy(e:find("C: not configured", 1, true), e)
            local _, n = e:gsub("D: not configured on this machine", "")
            assert.equals(1, n)
            assert.truthy(e:find("lw build Dev:kit", 1, true), e)
            assert.truthy(e:find("without --no-build", 1, true), e)
        end)

        it("a self-rebuilding runner that cannot skip the rebuild is refused before any step", function()
            local a, ppa = fake_unit("A", { batch = true })
            a._cannot_skip_rebuild = true
            local _, ppb = fake_unit("B", { batch = true })
            local r = run_plan(fake_profile({ ppa, ppb }), { no_build = true })
            assert.equals(1, r.exit_code)
            assert.same({}, r.ran)
            assert.truthy(r.stderr:find("A: cannot skip", 1, true), r.stderr)
            -- Without --no-build it is not asked to skip anything.
            r = run_plan(fake_profile({ ppa, ppb }), {})
            assert.is_nil(r.exit_code, r.stderr)
        end)

        it("notes a possibly stale build from recorded state and runs anyway", function()
            local a, ppa = fake_unit("A", { batch = true })
            a.configure_reason = function(_, forced, p)
                assert.is_false(forced); assert.equals("Dev:kit", p.key)
                return "options changed (FOO changed)"
            end
            local b, ppb = fake_unit("B", { batch = true })
            b.configure_reason = function() return nil end
            b.state_value = "failed_build"
            local c, ppc = fake_unit("C", { batch = true })
            c.configure_reason = function() return nil end
            c.state_value = "built"
            local r = run_plan(fake_profile({ ppa, ppb, ppc }), { no_build = true }, nil, nil, nil,
                { artifact_built = all_built })
            assert.is_nil(r.exit_code, r.stderr)
            assert.truthy(r.stderr:find("A: its build may be stale (options changed (FOO changed))", 1, true), r.stderr)
            assert.truthy(r.stderr:find("B: its build may be stale (last build failed)", 1, true), r.stderr)
            assert.falsy(r.stderr:find("C: ", 1, true), r.stderr)
            assert.equals(3, #r.ran)
        end)

        it("--list accepts and ignores it", function()
            local orig_report, orig_resolve = cli._test_plan_report, cli._resolve_profile_for_listing
            local got
            cli._resolve_profile_for_listing = function() return "P" end
            cli._test_plan_report = function(_, p, sel, json) got = { p, sel, json }; return 0 end
            local r = capture(function() return cli.cmd_test({}, { "test", "--list", "--no-build", "--saved" }) end)
            cli._test_plan_report, cli._resolve_profile_for_listing = orig_report, orig_resolve
            assert.is_nil(r.exit_code, r.stderr)
            assert.same({ "P", "saved" }, { got[1], got[2] })
        end)

        it("is a known option of lw test (the command line's unknown-option check)", function()
            local opts_mod = require("loomworks.cli_options")
            assert.is_nil((opts_mod.find_unknown({ "test", "dev", "--no-build" })))
            assert.is_nil((opts_mod.find_unknown({ "test", "--target", "x", "--no-build", "--junit", "j.xml" })))
        end)

        it("named targets: nothing built, unbuilt ones fail before any runs, locks held", function()
            local _, ppa = fake_unit("A", {})
            local profile = fake_profile({ ppa })
            local ran, built, locked = {}, false, 0
            local function lt(name)
                return { _config_unit = ppa._config_unit, is_valid = function() return true end,
                    deploy_sync = function() error("no deploy") end,
                    resolve_launch_spec = function() return { cmd = "/bin/" .. name, args = {}, cwd = "/" } end }
            end
            local function deps(built_set)
                return {
                    build = function() built = true end,
                    with_locks = function(_, _, fn) locked = locked + 1; fn() end,
                    resolve_target = function(_, _, name) return lt(name) end,
                    artifact_built = function(l) local n = l.resolve_launch_spec().cmd:match("[^/]+$")
                        return built_set[n] or false, "/bd/" .. n end,
                    run_spec = function(step) ran[#ran + 1] = step.cmd[1]; return 0 end,
                }
            end
            local opts = { extra = {}, dev = cli._new_device_opts(), no_build = true }
            local r = capture(function()
                return cli._test_targets({ root = "/" }, profile, { "T1", "T2" }, opts, deps({ T1 = true }))
            end)
            assert.equals(1, r.exit_code)
            assert.same({}, ran)
            assert.truthy(r.stderr:find("--target T2: not built (/bd/T2)", 1, true), r.stderr)
            assert.falsy(r.stderr:find("T1:", 1, true), r.stderr)
            r = capture(function()
                return cli._test_targets({ root = "/" }, profile, { "T1", "T2" }, opts, deps({ T1 = true, T2 = true }))
            end)
            assert.is_nil(r.exit_code, r.stderr)
            assert.same({ "/bin/T1", "/bin/T2" }, ran)
            assert.is_false(built)
            assert.equals(2, locked)
        end)

        it("a configured unit whose build targets are unknown is said so, not 'not configured'", function()
            -- Configured here, but no build dir to read targets from.
            local _, ppe = fake_unit("E", { saved = { "Z" } })
            local _, ppd = fake_unit("D", { here = false, saved = { "W" } })
            local r = run_plan(fake_profile({ ppe, ppd }), { no_build = true })
            assert.equals(1, r.exit_code)
            assert.same({}, r.ran)
            local e = r.stderr
            assert.truthy(e:find("E: its build targets are unknown (build directory missing or unreadable)", 1, true), e)
            assert.falsy(e:find("E: not configured", 1, true), e)
            assert.truthy(e:find("D: not configured on this machine", 1, true), e)
            assert.truthy(e:find("lw build Dev:kit", 1, true), e)
        end)

        describe("named targets not found", function()
            --- A: configured, has T1 (and Dup); B: configured, has Dup;
            --- U: unconfigured cmake-like; S: unconfigured shim (no targets).
            local function setup(with_unconfigured)
                local _, ppa = fake_unit("A", { targets = {} })
                local _, ppb = fake_unit("B", { targets = {} })
                local pps = { ppa, ppb }
                if with_unconfigured then
                    local _, ppu = fake_unit("U", { here = false })
                    local _, pps_ = fake_unit("S", { here = false })
                    pps_._config_unit._project._module = { impl = {} }
                    pps[#pps + 1] = ppu; pps[#pps + 1] = pps_
                end
                local profile = fake_profile(pps)
                local pa, pb = ppa._config_unit._project, ppb._config_unit._project
                local cands = {
                    { kind = "target", project = pa, name = "T1" },
                    { kind = "target", project = pa, name = "Dup" },
                    { kind = "target", project = pb, name = "Dup" },
                }
                local ran = {}
                local deps = {
                    with_locks = function(_, _, fn) fn() end,
                    candidates = function() return cands end,
                    launch_target = function(_, _, c)
                        return { _config_unit = ppa._config_unit, is_valid = function() return true end,
                            resolve_launch_spec = function() return { cmd = "/bin/" .. c.name, args = {}, cwd = "/" } end }
                    end,
                    artifact_built = function() return true, "/bd/x" end,
                    run_spec = function(step) ran[#ran + 1] = step.cmd[1]; return 0 end,
                }
                return profile, deps, ran
            end
            local function run(names, with_unconfigured)
                local profile, deps, ran = setup(with_unconfigured)
                local opts = { extra = {}, dev = cli._new_device_opts(), no_build = true }
                local r = capture(function() return cli._test_targets({ root = "/" }, profile, names, opts, deps) end)
                r.ran = ran
                return r
            end

            it("an unfound name may belong to an unconfigured project that can have targets", function()
                local r = run({ "T1", "Nope" }, true)
                assert.equals(1, r.exit_code)
                assert.same({}, r.ran)
                assert.truthy(r.stderr:find(
                    "--target Nope: not found — may belong to a project not configured on this machine (U)", 1, true),
                    r.stderr)
                assert.falsy(r.stderr:find("S)", 1, true), r.stderr)          -- the shim is not listed
                assert.truthy(r.stderr:find("lw build Dev:kit", 1, true), r.stderr)
            end)

            it("with no such project, the usual not-found error", function()
                local r = run({ "Nope" }, false)
                assert.equals(1, r.exit_code)
                assert.truthy(r.stderr:find("no executable target 'Nope' in profile 'Dev:kit'", 1, true), r.stderr)
                assert.falsy(r.stderr:find("may belong", 1, true), r.stderr)
            end)

            it("an ambiguous name keeps the qualify message", function()
                local r = run({ "Dup" }, true)
                assert.equals(1, r.exit_code)
                assert.same({}, r.ran)
                assert.truthy(r.stderr:find("'Dup' is ambiguous", 1, true), r.stderr)
                assert.truthy(r.stderr:find("qualify with <project>:<name>", 1, true), r.stderr)
                assert.falsy(r.stderr:find("may belong", 1, true), r.stderr)
            end)
        end)

        it("the early failure releases the real build-dir locks (exit hook)", function()
            local build_lock = require("loomworks.build_lock")
            local bd = vim.fn.tempname():gsub("\\", "/")
            vim.fn.mkdir(bd, "p")
            local _, ppa = fake_unit("A", { targets = {} })
            ppa.build_dir = function() return bd end
            local _, ppu = fake_unit("U", { here = false })
            local profile = fake_profile({ ppa, ppu })
            local held_during
            local deps = {                                  -- no with_locks: the real one
                candidates = function()
                    return { { kind = "target", project = ppa._config_unit._project, name = "T1" } }
                end,
                launch_target = function() return { _config_unit = ppa._config_unit } end,
                artifact_built = function() held_during = build_lock.read(bd) ~= nil; return true, bd .. "/T1" end,
                run_spec = function() error("must not run") end,
            }
            local opts = { extra = {}, dev = cli._new_device_opts(), no_build = true }
            local r = capture(function()
                return cli._test_targets({ root = "/" }, profile, { "T1", "Nope" }, opts, deps)
            end)
            assert.equals(1, r.exit_code)
            assert.truthy(r.stderr:find("--target Nope: not found", 1, true), r.stderr)
            assert.is_true(held_during)
            assert.is_nil(build_lock.read(bd))
            vim.fn.delete(bd, "rf")
        end)
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

    it("remove on a level whose own `tests` is not an array is refused (not 'not saved')", function()
        local root = make_ws({ tests = { targets = { "BaseTests" } } }, "variant:default")
        local ws = load(root); targets_for(ws)
        local r = capture(function() return cli._tt_remove(root, { "test-target", "remove", "Dev", "BaseTests" }, ws) end)
        assert.equals(1, r.exit_code, r.stdout)
        assert.truthy(r.stderr:find("is not an array of saved test entries", 1, true), r.stderr)
        assert.falsy(r.stdout:find("not saved", 1, true))
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
describe("lw project show: saved test targets (§16.9)", function()
    local function show(section)
        local root = make_ws(section, "variant:default")
        local r = capture(function() return cli.cmd_project_show(root, "App") end)
        assert.equals(0, r.ret, r.stderr)
        return r.stdout
    end
    -- The `tests` sub-line printed under configuration `name`.
    local function cfg_tests(stdout, name)
        return stdout:match("\n    " .. name .. " [^\n]*\n      tests  ([^\n]*)")
    end

    it("shows the project-wide list, and configurations inherit it", function()
        local s = show({ tests = { "PW1", "PW2" },
            configurations = { Rel = { inherits = "variant:default" } } })
        assert.truthy(s:find("\n  tests           PW1, PW2  (project-wide)\n", 1, true), s)
        assert.equals("PW1, PW2  (project-wide)", cfg_tests(s, "Rel"), s)
    end)

    it("shows a configuration's own list", function()
        local s = show({ configurations = {
            Tests = { inherits = "variant:default", tests = { "BaseTests", "X1" } } } })
        assert.equals("BaseTests, X1  (own)", cfg_tests(s, "Tests"), s)
    end)

    it("shows an inherited list with its source", function()
        local s = show({ configurations = {
            Tests = { inherits = "variant:default", tests = { "BaseTests", "X1" } },
            Rel = { inherits = "Tests" } } })
        assert.equals("BaseTests, X1  (inherited from Tests)", cfg_tests(s, "Rel"), s)
        -- No project-wide list: the project row still shows `none` + the add hint.
        assert.truthy(s:find("\n  tests           none — add: lw test-target add <profile> App:<name>", 1, true), s)
    end)

    it("shows none and the add hint when no list exists anywhere", function()
        local s = show({ configurations = { Rel = { inherits = "variant:default" } } })
        assert.truthy(s:find("\n  tests           none — add: lw test-target add <profile> App:<name>"
            .. " [--config <name> | --project-wide]\n", 1, true), s)
        -- A configuration with an empty effective list shows no `tests` line.
        assert.is_nil(cfg_tests(s, "Rel"), s)
        assert.falsy(s:find("\n      tests  ", 1, true), s)
        -- One hint for the project, none repeated per configuration.
        local _, n = s:gsub("lw test%-target add", "")
        assert.equals(1, n, s)
    end)

    it("hides an explicit empty list on a configuration", function()
        local s = show({ configurations = {
            Tests = { inherits = "variant:default", tests = { "BaseTests" } },
            Rel = { inherits = "Tests", tests = {} } } })
        assert.equals("BaseTests  (own)", cfg_tests(s, "Tests"), s)
        assert.is_nil(cfg_tests(s, "Rel"), s)
        assert.falsy(s:find("none (explicit)", 1, true), s)
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
        -- The deploy runs when the step executes (its `prepare`), not while
        -- the command is built.
        assert.same({}, deployed)
        assert.is_function(lc.prepare)
        assert.is_true(lc.prepare())
        assert.same({ "chk" }, deployed)
        assert.equals("launch:chk", lc.test_id)
        assert.same({ "/usr/bin/tool", "--own", "--e" }, lc.cmd)
        assert.equals("/w", lc.cwd)
        assert.equals("1", lc.env.M)
        assert.is_nil(lc.output_path)                -- no results option for a command launch
        assert.is_nil(tu:run_command_all())
        assert.is_nil(tu:test_command_all())
    end)

    it("a failed deploy fails its step at execution (run-all keeps it; editor + loomtest runners)", function()
        local SavedTU = require("loomworks.test_units.saved_targets")
        local orig_lt = package.loaded["loomworks.launch_target"]
        package.loaded["loomworks.launch_target"] = { new = function()
            return {
                deploy_sync = function() return false, "boom" end,
                resolve_launch_spec = function() return { cmd = "/usr/bin/tool", args = {}, cwd = "/w" } end,
            }
        end }
        local unit = saved_unit({ "Run", "chk" }, { chk = { command = "tool" } })
        local tu = SavedTU.new(unit)
        tu:discover()
        unit.test_units = function() return { tu } end
        local cmds = ConfigUnit.test_commands_all(unit, {})
        package.loaded["loomworks.launch_target"] = orig_lt
        local ids = {}
        for _, c in ipairs(cmds) do ids[#ids + 1] = c.id end
        assert.same({ "target:Run", "launch:chk" }, ids)     -- never silently dropped
        local chk = cmds[2].cmd

        -- Editor run: the step fails, no task starts, the entry is marked failed.
        local orig_ov = package.loaded["overseer"]
        local started = {}
        package.loaded["overseer"] = { new_task = function(t) started[#started + 1] = t.name
            return { id = 1, subscribe = function() end, start = function() end } end, open = function() end }
        local applied
        unit._apply_test_results = function(_, res) applied = res end
        local f = ConfigUnit._run_test_task(unit, "test: chk", chk, tu)
        assert.equals("rejected", f._state)
        assert.same({}, started)
        assert.equals("launch:chk", applied[1].test_id)
        assert.equals("failed", applied[1].status)
        assert.truthy(applied[1].message:find("deploy failed: boom", 1, true))

        -- loomtest runner: same, and the next spec still runs (on_done).
        local loomtest = { apply_results = function(res) applied = res end, get_node = function() return nil end }
        local explorer = { is_open = function() return false end, refresh = function() end }
        applied = nil
        local done = false
        require("loomtest.runner")._execute_task({}, chk, { "launch:chk" }, loomtest, explorer, function() done = true end)
        package.loaded["overseer"] = orig_ov
        assert.same({}, started)
        assert.is_true(done)
        assert.equals("launch:chk", applied[1].test_id)
        assert.equals("failed", applied[1].status)
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
    -- (test_source reads the active profile from the model,
    -- test_state.active_profile.)
    local orig_ws
    before_each(function() orig_ws = lw.get_workspace end)
    after_each(function() lw.get_workspace = orig_ws end)

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
        local profile = { projects = function() return { { _config_unit = u1 }, { _config_unit = u2 } } end }
        lw.get_workspace = function() return { _active_profile = profile } end
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
    local Project = require("loomworks.project")
    -- The status page formats the project's resolved view.
    local function line(eff, item, targets, width, proj)
        proj = setmetatable(proj or { key = "App" }, { __index = Project })
        return helpers.test_targets_chunks(proj:saved_tests_view(eff, item, targets), width)
    end
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
            text(line(eff, cfg, nil, 200)))
        assert.equals("Tests: BaseTests, CoreTests, CoreTests, Gone", text(line(eff, base, nil, 200)))
        local cut = text(line(eff, base, nil, 30))
        assert.truthy(cut:find(", %+%d$"), cut)
        local targets = { BaseTests = fake_target("BaseTests"), CoreTests = fake_target("CoreTests") }
        local chunks = line(eff, base, targets, 200)
        local warn
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn = c[1] end end
        assert.equals("⚠ Gone", warn)
        assert.equals("Tests: none (explicit)", text(line({ entries = {}, source = base }, base, nil, 80)))
        assert.is_nil(line(nil, base, nil, 80))
    end)

    it("a launch name is not missing; a trust-ignored launch and an invalid list are flagged", function()
        local proj = { key = "App", launch = { chk = { command = "tool" } },
            _workspace = { _shared_ignored = { { kind = "launch", path = { "projects", "App", "launch", "ign" } } } } }
        local base = { name = "Tests", _project = proj }
        local eff = { entries = tt.parse({ "chk", "ign" }).entries, source = base }
        local chunks = line(eff, base, {}, 200, proj)
        local warn = {}
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn[#warn + 1] = c[1] end end
        assert.same({ "⚠ ign" }, warn)
        -- Unconfigured (targets unknown): the ignored launch is still flagged.
        chunks = line(eff, base, nil, 200, proj)
        warn = {}
        for _, c in ipairs(chunks) do if c[2] == "DiagnosticWarn" then warn[#warn + 1] = c[1] end end
        assert.same({ "⚠ ign" }, warn)
        assert.truthy(text(line({ entries = {}, source = base, invalid = true }, base, nil, 80))
            :find("invalid", 1, true))
    end)
end)

-- ===========================================================================
-- Table entries with working_dir, ${target_dir} and `lw test --target --cwd`
-- (spec §1.3.4 "Shape" / "Working directory" / "Persistence", §8.7, §16.9,
-- §16.16, §17.6).
describe("table entries and working_dir (§1.3.4)", function()
    it("parses the table form; the form never changes the entry or its occurrence", function()
        local decl = tt.parse({ "X", { name = "X" }, { name = "X", args = { "a" } }, { "X", "a" },
            { name = "X", working_dir = "${target_dir}" }, { name = "X", args = {}, future = { k = 1 } } }, "App/T")
        assert.same({ "X", "X", "X", "X", "X", "X" }, names(decl.entries))
        local idx = {}
        for _, e in ipairs(decl.entries) do idx[#idx + 1] = e.index end
        assert.same({ 1, 2, 3, 4, 5, 6 }, idx)
        assert.same({ "a" }, decl.entries[3].args)
        assert.equals("${target_dir}", decl.entries[5].working_dir)
        assert.same({ future = { k = 1 } }, decl.entries[6].extra)
        assert.equals("target:X#2", tt.entry_id(decl.entries[2], "target"))
        -- Written back in the shortest form; unknown keys keep the table form.
        assert.same({ "X", "X", { "X", "a" }, { "X", "a" },
            { name = "X", working_dir = "${target_dir}" }, { name = "X", future = { k = 1 } } }, tt.serialize(decl))
    end)

    it("an invalid table entry is kept verbatim (no string name, bad args / working_dir)", function()
        local raw = { { args = { "a" } }, { name = 3 }, { name = "" }, { name = "X", args = "a" },
            { name = "X", args = { "a", 1 } }, { name = "X", working_dir = 5 } }
        local decl = tt.parse(raw, "App/Bad")
        for _, e in ipairs(decl.entries) do assert.is_not_nil(e.invalid) end
        assert.same(raw, tt.serialize(decl))
    end)

    it("persists a working_dir in the table form and reads it back", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root)
        assert.is_true(project(ws, "App"):set_test_targets({ { name = "A", working_dir = "data" },
            { name = "B", args = { "--b" } }, { name = "C", extra = { later = true } } }))
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ { name = "A", working_dir = "data" }, { "B", "--b" }, { name = "C", later = true } },
            user.projects.App.typescript.tests)
        local own = project(load(root), "App"):own_test_targets()
        assert.equals("data", own[1].working_dir)
        assert.same({ later = true }, own[3].extra)
    end)

    it("a working_dir change changes the fingerprint (invalidates the test tree)", function()
        assert.are_not.equal(tt.fingerprint({ { name = "A" } }), tt.fingerprint({ { name = "A", working_dir = "d" } }))
    end)

    it("resolve_working_dir: absolute as-is, else workspace-root-relative, expanded", function()
        assert.equals("/abs/d", require("loomworks.test_plan").resolve_working_dir("/abs/d", {}, "/root"))
        assert.equals("/root/rel/x", require("loomworks.test_plan").resolve_working_dir("rel/${v}", { v = "x" }, "/root"))
        local p, un = require("loomworks.test_plan").resolve_working_dir("${target_dir}/data", {}, "/root")
        assert.equals("/root/${target_dir}/data", p)
        assert.same({ "target_dir" }, un)
        assert.is_nil(require("loomworks.test_plan").resolve_working_dir(nil, {}, "/root"))
    end)
end)

describe("trust: entry working_dir is program-bearing (§17.6)", function()
    local pf = require("loomworks.program_fields")
    local SHARED = { projects = { App = { cmake = {
        configurations = { Tests = { variant = "Release", tests = {
            { name = "AssetTests", working_dir = "${target_dir}" },
            { name = "R", args = { "--a" }, working_dir = "w", future = 1 }, "R" } } },
    } } } }
    local function stripped()
        local cfg = require("loomworks.config").parse(vim.json.encode(SHARED), "/root")
        return cfg, pf.strip(cfg, require("loomworks.modules"))
    end

    it("strips args and working_dir, keeps names and unknown keys; names the value", function()
        local cfg, ignored = stripped()
        assert.same({ "AssetTests", { name = "R", future = 1 }, "R" },
            cfg.projects.App.type_config.configurations.Tests.tests)
        local msgs = {}
        for _, d in ipairs(pf.diagnostics(ignored, cfg)) do msgs[#msgs + 1] = d.message end
        assert.truthy(vim.tbl_contains(msgs, "loomworks.json sets projects.App.cmake.configurations.Tests.tests "
            .. "(AssetTests working_dir = ${target_dir}) — ignored: program settings are used only from your "
            .. "local config (lw help trust)"), vim.inspect(msgs))
        assert.equals(3, #msgs)
        -- A working copy giving that occurrence a working_dir silences only that one.
        local merged = vim.deepcopy(cfg)
        merged.projects.App.type_config.configurations.Tests.tests[1] = { name = "AssetTests", working_dir = "mine" }
        assert.equals(2, #pf.diagnostics(ignored, merged))
    end)

    it("regraft restores the working_dir by name + occurrence, in the table form", function()
        local _, ignored = stripped()
        local raw = { projects = { App = { cmake = { configurations = { Tests = { tests = {
            "New", "R", "AssetTests", { name = "R", working_dir = "mine" } } } } } } } }
        local _, dropped = pf.regraft(raw, ignored)
        assert.same({ "New", { name = "R", args = { "--a" }, working_dir = "w" },
            { name = "AssetTests", working_dir = "${target_dir}" }, { name = "R", working_dir = "mine" } },
            raw.projects.App.cmake.configurations.Tests.tests)
        assert.same({}, dropped)
    end)
end)

describe("${target_dir} (§8.7)", function()
    local expand = require("loomworks.expand")
    local vars = require("loomworks.variables")
    local function unit_at(bd, here)
        return { build_dir = function() return bd end, configured_here = function() return here ~= false end }
    end

    it("is the artifact's host directory; absent without a target or while unconfigured", function()
        local u = unit_at("/bd")
        assert.equals("/bd/bin", expand.target_dir({ artifact = "bin/app" }, u))
        assert.equals("C:/x/out", expand.target_dir({ artifact = "C:\\x\\out\\app.exe" }, nil))
        assert.is_nil(expand.target_dir({ artifact = "bin/app" }, unit_at("/bd", false)))
        assert.is_nil(expand.target_dir({ artifact = "bin/app" }, unit_at(nil)))
        assert.is_nil(expand.target_dir(nil, u))
    end)

    it("is in the launch context only with a target; project variables may use it", function()
        local _, pp = fake_unit("A", { build_dir = "/bd", variables = { data = { type = "path", default = "${target_dir}/data" } } })
        local profile = fake_profile({ pp })
        local proj = pp._config_unit._project
        local without = expand.launch_context({ root = "/r" }, profile, proj)
        assert.is_nil(without.target_dir)
        assert.same({ "target_dir" }, expand.unresolved_vars("${target_dir}", without))
        local with = expand.launch_context({ root = "/r" }, profile, proj, { target = fake_target("T") })
        assert.equals("/bd", with.target_dir)
        assert.equals("/bd/data", with.data)
    end)

    it("is a reserved name, but unresolved in configure options", function()
        assert.is_true(vars.RESERVED_NAMES.target_dir)
        assert.is_true(vars.LAUNCH_ONLY_NAMES.target_dir)
    end)

    it("LaunchTarget: a target's --cwd / working_dir and a target-backed launch expand it; deploy too", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root)
        local p = project(ws, "App")
        local unit
        for _, u in pairs(ws._config_units) do if u._project == p then unit = u end end
        unit.state_value, unit.build_dir_value = "built", root .. "/build"
        unit.targets = { CoreTests = Target.new(unit, "CoreTests", { type = "executable", artifact = "bin/c" }) }
        p.launch = { chk = { target = "CoreTests", working_dir = "${target_dir}/w", args = { "${target_dir}" } },
            cmd = { command = "tool", working_dir = "${target_dir}" } }
        local profile = ws._profiles[1]
        local LT = require("loomworks.launch_target")
        local t = LT.new(ws, profile, { project = "App", target = "CoreTests" })
        assert.equals(root .. "/build/bin/x", t:_effective_cwd("${target_dir}/x"))
        local l = LT.new(ws, profile, { project = "App", launch = "chk" })
        local spec = l:resolve_command_spec()
        assert.equals(root .. "/build/bin/w", spec.cwd)
        assert.same({ root .. "/build/bin" }, spec.args)
        -- A command launch resolves no target: the reference stays unresolved.
        local c = LT.new(ws, profile, { project = "App", launch = "cmd" })
        assert.truthy(c:resolve_command_spec().cwd:find("${target_dir}", 1, true))
        -- Deploy destinations of a target-backed launch.
        local deploy = require("loomworks.deploy")
        local orig = expand.launch_context
        local seen
        expand.launch_context = function(w, pr, pj, o) seen = o and o.target; return orig(w, pr, pj, o) end
        deploy.resolve_deploy_step("${target_dir}/x", { project = "App", path = "f" },
            { workspace = ws, profile = profile, launch_project = p, launch_build_target = unit.targets.CoreTests })
        expand.launch_context = orig
        assert.equals(unit.targets.CoreTests, seen)
    end)
end)

describe("lw test: working directories (§16.16)", function()
    local gtest = require("loomworks.gtest")
    local orig_probe
    before_each(function() orig_probe = gtest.probe_sync; gtest.probe_sync = function() return nil end end)
    after_each(function() gtest.probe_sync = orig_probe end)

    local function lt_for(c, seen)
        local cfg = c.kind == "launch" and c.project.launch[c.name] or nil
        return {
            _launch_config = cfg,
            is_valid = function() return true end,
            deploy_sync = function() return true end,
            resolve_launch_spec = function(_, o)
                seen[#seen + 1] = o and o.working_dir or false
                if cfg then return { cmd = cfg.command or "/bin/L", args = {}, cwd = cfg.working_dir or "/proj" } end
                return { cmd = "/bin/" .. c.name, args = {}, cwd = "/proj" }
            end,
        }
    end

    it("an entry runs in its working_dir, else the launch's, else the project directory", function()
        local _, ppa = fake_unit("A", { build_dir = "/bd",
            saved = { { name = "T", working_dir = "${target_dir}/data" }, "T", { name = "chk", working_dir = "rel" }, "chk" },
            targets = { T = fake_target("T") },
            launch = { chk = { command = "/usr/bin/chk", working_dir = "/w" } } })
        local cwds, seen = {}, {}
        local deps = {
            build = function() end,
            run_spec = function(step) cwds[#cwds + 1] = step.cwd; return 0 end,
            launch_target = function(_, _, c) return lt_for(c, seen) end,
        }
        local r = capture(function()
            return cli._test_plan({ root = "/root" }, fake_profile({ ppa }), { extra = {}, dev = cli._new_device_opts() }, deps)
        end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "/bd/data", "/proj", "/root/rel", "/w" }, cwds)
    end)

    it("a device step ignores the entry's working_dir and says so", function()
        local _, ppa = fake_unit("A", { saved = { { name = "T", working_dir = "d" } }, targets = { T = fake_target("T") } })
        local orig_f = cli._foreign_of
        local foreign = require("loomworks.remote.foreign")
        local orig_ref = foreign.refusal
        cli._foreign_of = function() return { name = "T" } end
        foreign.refusal = function() return "no runner here" end
        local r = capture(function()
            return cli._test_plan({ root = "/root" }, fake_profile({ ppa }), { extra = {}, dev = cli._new_device_opts() },
                { build = function() end, run_spec = function() return 0 end,
                  launch_target = function(_, _, c) return lt_for(c, {}) end })
        end)
        cli._foreign_of, foreign.refusal = orig_f, orig_ref
        assert.truthy(r.stdout:find("==> [test] A: T (on a device; its working_dir is not used there)", 1, true), r.stdout)
    end)

    it("--target --cwd overrides every named target's directory; refused without --target and on a device", function()
        local seen = {}
        local c = { kind = "target", name = "T", project = { key = "A" } }
        local deps = { build = function() end, run_spec = function() return 0 end,
            resolve_target = function() return lt_for(c, seen) end }
        local r = capture(function()
            return cli._test_targets({ root = "/root" }, { key = "P" }, { "T", "T" },
                { extra = {}, dev = cli._new_device_opts(), cwd_override = "${target_dir}" }, deps)
        end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.same({ "${target_dir}", "${target_dir}" }, seen)      -- expanded per target by its LaunchTarget
        local u = capture(function() cli.cmd_test({}, { "test", "--cwd", "/x" }) end)
        assert.equals(2, u.exit_code)
        assert.truthy(u.stderr:find("--target", 1, true))
        local orig_f = cli._foreign_of
        cli._foreign_of = function() return { name = "T", platform = "arm64" } end
        local d = capture(function()
            return cli._test_targets({ root = "/root" }, { key = "P" }, { "T" },
                { extra = {}, dev = cli._new_device_opts(), cwd_override = "/x" }, deps)
        end)
        cli._foreign_of = orig_f
        assert.equals(2, d.exit_code)      -- a usage error, like `lw run --cwd`
        assert.truthy(d.stderr:find("--cwd does not apply to a device run", 1, true), d.stderr)
    end)

    it("--list --json: working_dir as written and expanded (null when unresolved), also_target", function()
        local _, ppa = fake_unit("A", { build_dir = "/bd",
            saved = { { name = "T", working_dir = "${target_dir}" }, "T", { name = "L", working_dir = "${lw_no_such_var_xyz}" }, "L" },
            targets = { T = fake_target("T"), L = fake_target("L") }, launch = { L = { command = "tool" } } })
        local r = capture(function() return cli._test_plan_report({ root = "/root" }, fake_profile({ ppa }), nil, true) end)
        local es = vim.json.decode(r.stdout).units[1].saved.entries
        assert.equals("${target_dir}", es[1].working_dir)
        assert.equals("/bd", es[1].working_dir_expanded)
        assert.equals(vim.NIL, es[2].working_dir)
        assert.equals(vim.NIL, es[2].working_dir_expanded)
        assert.equals(vim.NIL, es[3].working_dir_expanded)    -- unresolved reference
        assert.is_true(es[4].also_target)
        assert.is_nil(es[1].also_target)
        -- Not configured here: ${target_dir} is unavailable, also_target absent.
        local _, ppb = fake_unit("B", { here = false, build_dir = "/bd",
            saved = { { name = "T", working_dir = "${target_dir}" }, "L" }, launch = { L = { command = "tool" } } })
        local u = capture(function() return cli._test_plan_report({ root = "/root" }, fake_profile({ ppb }), nil, true) end)
        local ub = vim.json.decode(u.stdout).units[1].saved.entries
        assert.equals(vim.NIL, ub[1].working_dir_expanded)
        assert.is_nil(ub[2].also_target)
        -- Text form shows it.
        local t = capture(function() return cli._test_plan_report({ root = "/root" }, fake_profile({ ppa }), nil, false) end)
        assert.truthy(t.stdout:find("(in ${target_dir} → /bd)", 1, true), t.stdout)
    end)
end)

describe("lw test-target add --working-dir (§16.9)", function()
    it("stores the working_dir unexpanded in the table form; list shows it; remove refuses it", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root)
        for _, u in pairs(ws._config_units or {}) do
            u.targets = { CoreTests = Target.new(u, "CoreTests", { type = "executable", artifact = "c" }) }
        end
        local r = capture(function() return cli._tt_add(root,
            { "test-target", "add", "Dev", "CoreTests", "--working-dir", "${target_dir}", "--", "--a" }, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests", "--cwd", "data" }, ws) end)
        capture(function() return cli._tt_add(root, { "test-target", "add", "Dev", "CoreTests" }, ws) end)
        local user = read_json(root .. "/.nvim/loomworks.user.json")
        assert.same({ { name = "CoreTests", args = { "--a" }, working_dir = "${target_dir}" },
            { name = "CoreTests", working_dir = "data" }, "CoreTests" }, user.projects.App.typescript.tests)
        local l = capture(function() return cli._tt_list(root, nil, ws) end)
        assert.truthy(l.stdout:find("CoreTests #1  --a  (in ${target_dir})", 1, true), l.stdout)
        local rm = capture(function() return cli._tt_remove(root,
            { "test-target", "remove", "Dev", "CoreTests", "--working-dir", "x" }, ws) end)
        assert.equals(2, rm.exit_code)
    end)
end)

describe("saved-targets TestUnit: working directories (§8.9.2)", function()
    it("target and launch entries run in the entry's working_dir; such a target never merges", function()
        local SavedTU = require("loomworks.test_units.saved_targets")
        local orig_lt = package.loaded["loomworks.launch_target"]
        package.loaded["loomworks.launch_target"] = { new = function()
            return { deploy_sync = function() return true end,
                resolve_launch_spec = function() return { cmd = "/usr/bin/tool", args = {}, cwd = "/w" } end }
        end }
        local unit
        local project = { key = "App", launch = { chk = { command = "tool" } } }
        local ws = { root = "/root", _projects = { project }, _profiles = {} }
        local profile = { key = "Dev", project = function(_, k) return k == "App" and { _config_unit = unit } or nil end }
        local raw = { { name = "Run", working_dir = "${target_dir}/d" }, { name = "chk", working_dir = "rel" }, "chk" }
        unit = {
            _project = project, _workspace = ws,
            build_dir = function() return "/b" end,
            ensure_targets = function() return unit.targets end,
            saved_test_targets = function()
                local d = tt.parse(raw, "App/Tests")
                return { entries = d.entries, source = { name = "Tests", _project = project } }
            end,
            context_profile = function() return profile end,
            configured_here = function() return true end,
            run_env = function() return nil end,
        }
        unit.targets = { Run = Target.new(unit, "Run", { type = "executable", artifact = "bin/Run" }) }
        local tu = SavedTU.new(unit)
        local entries = tu:discover()
        assert.is_true(entries[1].saved_working_dir)
        assert.equals("/b/bin/d", tu:test_command("target:Run").cwd)
        assert.equals("/root/rel", tu:test_command("launch:chk").cwd)
        assert.equals("/w", tu:test_command("launch:chk#2").cwd)
        package.loaded["loomworks.launch_target"] = orig_lt
        local merged = ConfigUnit._merge_test_entries({ {}, { is_saved_targets = true } }, {
            { { id = "target:Run", executable = entries[1].executable } }, { entries[1] } })
        assert.equals(2, #merged)
    end)
end)

-- ===========================================================================
-- Review fixes (#208): neotest runs a step's `prepare`; unresolved deploy
-- paths fail the step; `lw test --target --cwd` on a device is refused up
-- front; the loomtest debug path clears pending children on a failed prepare.
describe("saved launch deploys: every runner path (§16.16, §8.8)", function()
    local function neotest_unit(cmds)
        local applied = {}
        local unit = setmetatable({
            state = function() return "built" end,
            local_state = function() return "built" end,
            test_command_for = function(_, id) return cmds[id], { kind = "tu" } end,
            test_commands_all = function()
                local all = {}
                for _, id in ipairs(cmds._order or {}) do all[#all + 1] = { cmd = cmds[id], tu = { kind = "tu" }, id = id } end
                return all
            end,
            _apply_test_results = function(_, res) for _, r in ipairs(res) do applied[#applied + 1] = r end end,
        }, { __index = ConfigUnit })
        return unit, applied
    end
    local function tree(unit, pos, id)
        return {
            data = function() return pos end,
            iter_nodes = function()
                local done = false
                return function()
                    if done then return nil end
                    done = true
                    return 1, { data = function() return { _config_unit = unit, _original_id = id } end }
                end
            end,
        }
    end
    local function cmd(log, name, fail)
        return { cmd = { "/bin/" .. name }, cwd = "/w", test_id = "launch:" .. name,
            prepare = function()
                log[#log + 1] = "deploy " .. name
                if fail then return false, "deploy failed: boom" end
                return true
            end }
    end
    local function quiet(fn)
        local orig = vim.notify
        vim.notify = function() end
        local ok, a, b = pcall(fn)
        vim.notify = orig
        if not ok then error(a, 0) end
        return a, b
    end

    it("neotest: a test's spec runs its deploy once, at build_spec, and carries no prepare", function()
        local adapter = require("loomworks.neotest")
        local log = {}
        local unit = neotest_unit({ ["launch:chk"] = cmd(log, "chk") })
        local spec = adapter.build_spec({ tree = tree(unit, { type = "test", name = "chk", id = "f::launch:chk" }, "launch:chk") })
        assert.same({ "deploy chk" }, log)
        assert.same({ "/bin/chk" }, spec.command)
        assert.is_nil(spec.prepare)
        assert.is_nil(spec.context.prepare)
    end)

    it("neotest: a failed deploy marks the entry failed and runs nothing", function()
        local adapter = require("loomworks.neotest")
        local log = {}
        local unit, applied = neotest_unit({ ["launch:chk"] = cmd(log, "chk", true) })
        local spec = quiet(function()
            return adapter.build_spec({ tree = tree(unit, { type = "test", name = "chk", id = "f::launch:chk" }, "launch:chk") })
        end)
        assert.is_nil(spec)
        assert.equals("launch:chk", applied[1].test_id)
        assert.equals("failed", applied[1].status)
        assert.truthy(applied[1].message:find("deploy failed: boom", 1, true))
    end)

    it("neotest: run-all deploys each entry once and skips the one whose deploy failed", function()
        local adapter = require("loomworks.neotest")
        local log = {}
        local unit, applied = neotest_unit({ ["launch:a"] = cmd(log, "a"), ["launch:b"] = cmd(log, "b", true),
            ["launch:c"] = cmd(log, "c"), _order = { "launch:a", "launch:b", "launch:c" } })
        local specs = quiet(function()
            return adapter.build_spec({ tree = tree(unit, { type = "file", name = "f", id = "f" }, nil) })
        end)
        assert.same({ "deploy a", "deploy b", "deploy c" }, log)
        assert.equals(2, #specs)
        assert.same({ "/bin/a" }, specs[1].command)
        assert.same({ "/bin/c" }, specs[2].command)
        assert.equals("launch:b", applied[1].test_id)
        assert.equals("failed", applied[1].status)
    end)

    it("loomtest debug: a failed prepare fails the entry and clears its pending children", function()
        local nodes = { ["launch:chk"] = { id = "launch:chk", status = "pending" },
            ["test:S.a@launch:chk"] = { id = "test:S.a@launch:chk", parent = "launch:chk", status = "pending" } }
        local applied
        local saved = {}
        for _, m in ipairs({ "loomtest", "loomtest.explorer", "loomworks.debug" }) do saved[m] = package.loaded[m] end
        package.loaded["loomtest"] = { get_node = function(id) return nodes[id] end,
            apply_results = function(res) applied = res end }
        package.loaded["loomtest.explorer"] = { is_open = function() return false end, refresh = function() end }
        package.loaded["loomworks.debug"] = { available = function() return true end,
            run = function() error("must not debug") end }
        local ok, err = pcall(quiet, function()
            require("loomtest.runner").debug({}, { cmd = { "/bin/chk" }, test_id = "launch:chk",
                prepare = function() return false, "deploy failed: boom" end }, { "launch:chk", "test:S.a@launch:chk" })
        end)
        for m, v in pairs(saved) do package.loaded[m] = v end
        assert.is_true(ok, err)
        assert.equals("launch:chk", applied[1].test_id)
        assert.equals("failed", applied[1].status)
        assert.is_nil(nodes["test:S.a@launch:chk"].status)
    end)

    it("ConfigUnit: a prepare that errors fails the step like one that returns false", function()
        local applied
        local unit = setmetatable({ _apply_test_results = function(_, res) applied = res end }, { __index = ConfigUnit })
        local orig_ov = package.loaded["overseer"]
        local started = {}
        package.loaded["overseer"] = { new_task = function(t) started[#started + 1] = t.name
            return { id = 1, subscribe = function() end, start = function() end } end, open = function() end }
        local f = quiet(function()
            return ConfigUnit._run_test_task(unit, "test: chk", { cmd = { "/bin/chk" }, test_id = "launch:chk",
                prepare = function() error("kaput") end }, {})
        end)
        package.loaded["overseer"] = orig_ov
        assert.same({}, started)
        assert.equals("rejected", f._state)
        assert.equals("failed", applied[1].status)
        assert.truthy(applied[1].message:find("kaput", 1, true))
    end)

    it("deploy: an unresolved ${...} in a destination or source path fails the step, never copies", function()
        local root = make_ws(nil, "variant:default")
        local ws = load(root)
        local p = project(ws, "App")
        local unit
        for _, u in pairs(ws._config_units) do if u._project == p then unit = u end end
        unit.state_value, unit.build_dir_value = "built", root .. "/build"
        local profile = ws._profiles[1]
        local deploy = require("loomworks.deploy")
        local ctx = { workspace = ws, profile = profile, launch_project = p }
        -- A command launch resolves no target: ${target_dir} stays unresolved.
        local r, err = deploy.resolve_deploy_step("${target_dir}/x", { project = "App", path = "f" }, ctx)
        assert.is_nil(r)
        assert.truthy(err:find("target_dir", 1, true), err)
        r, err = deploy.resolve_deploy_step("out/x", { project = "App", path = "${lw_no_such_var_xyz}/f" }, ctx)
        assert.is_nil(r)
        assert.truthy(err:find("lw_no_such_var_xyz", 1, true), err)
        -- Resolved references still deploy.
        r, err = deploy.resolve_deploy_step("${workspace_root}/out/x", { project = "App", path = "${build_dir}/f" }, ctx)
        assert.is_table(r, err)
        -- The temp root may be an 8.3 short path on Windows (RUNNER~1) while
        -- the workspace root is long-form; compare canonical forms.
        local function canon(p) return vim.fs.normalize(vim.uv.fs_realpath(p) or p):lower() end
        assert.equals(canon(root) .. "/out/x", vim.fs.normalize(r.dest_path):lower())
    end)

    it("lw test --target --cwd: a device target is a usage error before any build or run", function()
        local builds, runs = 0, 0
        local lts = { H = { name = "H" }, T = { name = "T" } }
        for _, lt in pairs(lts) do
            lt.is_valid = function() return true end
            lt.deploy_sync = function() return true end
            lt.resolve_launch_spec = function() return { cmd = "/bin/" .. lt.name, args = {}, cwd = "/proj" } end
        end
        local deps = { build = function() builds = builds + 1 end,
            run_spec = function() runs = runs + 1; return 0 end,
            resolve_target = function(_, _, name) return lts[name] end }
        local orig_f = cli._foreign_of
        cli._foreign_of = function(lt) return lt == lts.T and { name = "T", platform = "arm64" } or nil end
        local d = capture(function()
            return cli._test_targets({ root = "/root" }, { key = "P" }, { "H", "T" },
                { extra = {}, dev = cli._new_device_opts(), cwd_override = "/x" }, deps)
        end)
        cli._foreign_of = orig_f
        assert.equals(2, d.exit_code)
        assert.truthy(d.stderr:find("--cwd does not apply to a device run ('T')", 1, true), d.stderr)
        assert.equals(0, builds)
        assert.equals(0, runs)
    end)

    it("lw test --target --cwd: a module-declared device launch target is a usage error before any build or run", function()
        local builds, runs = 0, 0
        local lts = { H = { name = "H" }, D = { name = "D" } }
        for n, lt in pairs(lts) do
            lt.is_valid = function() return true end
            lt.deploy_sync = function() return true end
            lt.requires_device = function() return n == "D" end
            lt.resolve_launch_spec = function() return { cmd = "/bin/" .. lt.name, args = {}, cwd = "/proj" } end
        end
        local deps = { build = function() builds = builds + 1 end,
            run_spec = function() runs = runs + 1; return 0 end,
            resolve_target = function(_, _, name) return lts[name] end }
        local d = capture(function()
            return cli._test_targets({ root = "/root" }, { key = "P" }, { "H", "D" },
                { extra = {}, dev = cli._new_device_opts(), cwd_override = "/x" }, deps)
        end)
        assert.equals(2, d.exit_code)
        assert.truthy(d.stderr:find("--cwd does not apply to a device run ('D')", 1, true), d.stderr)
        assert.equals(0, builds)
        assert.equals(0, runs)
    end)

    it("resolve_entry: a launch with neither command nor target is missing, also with targets unknown", function()
        local r = tt.resolve_entry({ name = "E", index = 1 }, { launches = { E = { args = { "--x" } } }, level = "App/Tests" })
        assert.equals("launch", r.kind)
        assert.equals("missing", r.state)
        assert.truthy(r.reason:find("neither a command nor a target", 1, true))
    end)
end)

-- ===========================================================================
-- An asynchronous host (the workspace daemon's, §19.15): the probe and the
-- deploy go through it — never the blocking in-process calls — and a step it
-- ends without calling back (a cancel) has its results file removed.
describe("test_plan.exec_step through an asynchronous host", function()
    local test_plan = require("loomworks.test_plan")
    local gtest = require("loomworks.gtest")
    local uv = vim.uv or vim.loop
    local orig_probe
    before_each(function()
        orig_probe = gtest.probe_sync
        gtest.probe_sync = function() error("probe_sync on an asynchronous host") end
    end)
    after_each(function() gtest.probe_sync = orig_probe end)

    local function host()
        local h = { lines = {}, spawned = {} }
        h.out = function(s) h.lines[#h.lines + 1] = s end
        h.err = function(s) h.lines[#h.lines + 1] = s end
        h.fail = function(msg) error("fail: " .. msg) end
        h.foreign_of = function() return nil end
        h.spawn = function(spec, cb) h.spawned[#h.spawned + 1] = { spec = spec, cb = cb } end
        h.probe = function(exe, _, _, cb) h.probing = { exe = exe, cb = cb } end
        h.deploy = function(_, cb) h.deploying = cb end
        return h
    end
    local function lt(cfg)
        return {
            _launch_config = cfg,
            is_valid = function() return true end,
            deploy_sync = function() error("deploy_sync on an asynchronous host") end,
            resolve_launch_spec = function()
                return { cmd = cfg and cfg.command or "/bin/T", args = {}, cwd = "/" }
            end,
        }
    end
    local function ws()
        local root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root .. "/.nvim", "p")
        return { root = root }
    end

    it("a target's probe goes through the host; the program runs once it answered", function()
        local h, done = host(), nil
        test_plan.exec_step(ws(), lt(nil), { label = "A: T", saved = true }, h, function(...) done = { ... } end)
        assert.equals("/bin/T", h.probing.exe)
        assert.equals(0, #h.spawned)
        h.probing.cb(nil)
        assert.equals(1, #h.spawned)
        assert.same({ "/bin/T" }, h.spawned[1].spec.cmd)
        assert.is_nil(h.spawned[1].spec.cleanup)
        h.spawned[1].cb(0)
        assert.is_false(done[1])
    end)

    it("a launch's deploy goes through the host; a failed one fails the step without running it", function()
        local h, done = host(), nil
        local cfg = { command = "/usr/bin/chk" }
        test_plan.exec_step(ws(), lt(cfg), { label = "A: chk", saved = true }, h, function(...) done = { ... } end)
        assert.is_function(h.deploying)
        assert.equals(0, #h.spawned)
        h.deploying(false, "cancelled")
        assert.equals(0, #h.spawned)
        assert.is_true(done[1])
        assert.same({ "deploy failed: cancelled" }, done[2])
        -- A successful deploy runs the program (a command launch: no probe).
        h, done = host(), nil
        test_plan.exec_step(ws(), lt(cfg), { label = "A: chk", saved = true }, h, function(...) done = { ... } end)
        h.deploying(true)
        assert.is_nil(h.probing)
        assert.same({ "/usr/bin/chk" }, h.spawned[1].spec.cmd)
    end)

    it("a step ended without a callback (a cancel) has its gtest results file removed by cleanup", function()
        local h, done = host(), nil
        test_plan.exec_step(ws(), lt(nil), { label = "A: T", saved = true }, h, function(...) done = { ... } end)
        h.probing.cb("gtest")
        local spec = h.spawned[1].spec
        local xml = spec.cmd[2]:match("^%-%-gtest_output=xml:(.+)$")
        assert.truthy(xml and xml:find("/.nvim/tmp/lw-test-", 1, true), spec.cmd[2])
        local f = assert(io.open(xml, "w")); f:write("<partial"); f:close()
        assert.is_function(spec.cleanup)
        spec.cleanup()
        assert.is_nil(uv.fs_stat(xml))
        assert.is_nil(done)
    end)
end)
