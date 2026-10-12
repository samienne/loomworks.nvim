--- loomworks.build_run — the headless build-step logic behind `lw build`
--- (headless §16.4). Pure unit tests over stubbed collaborators: every
--- function returns values / `nil, err` and never prints or exits.

local build_run = require("loomworks.build_run")
local overseer = require("loomworks.overseer")
local exe = require("loomworks.exe")
local compiler_cache = require("loomworks.compiler_cache")

--- Replace `tbl[name]` for one test; restored in after_each.
local restores = {}
local function stub(tbl, name, fn)
    local orig = tbl[name]
    restores[#restores + 1] = function() tbl[name] = orig end
    tbl[name] = fn
end

describe("build_run", function()
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
        restores = {}
    end)

    local function pp(bd)
        return { build_dir = function() return bd end }
    end

    describe("build_run.profile_build_dirs", function()
        it("lists each distinct build dir once, in project order, skipping none", function()
            local profile = { projects = function()
                return { pp("/b/a"), pp(nil), pp("/b/c"), pp("/b/a"), {} }
            end }
            assert.same({ "/b/a", "/b/c" }, build_run.profile_build_dirs(profile))
        end)
    end)

    describe("build_run.runs_batch_file", function()
        it("recognizes cmd.exe running a batch file or a variable-named program", function()
            assert.is_true(build_run.runs_batch_file({ "cmd", "/C", "x.bat" }))
            assert.is_true(build_run.runs_batch_file({ "C:\\Windows\\System32\\cmd.exe", "/c", "Y.CMD" }))
            assert.is_true(build_run.runs_batch_file({ "cmd", "/d", "/v:on", "/c", "!LOOMWORKS_VCVARS_BAT!" }))
            assert.is_true(build_run.runs_batch_file({ "cmd.exe", "/c", "%BAT%" }))
        end)
        it("is false for anything else", function()
            assert.is_false(build_run.runs_batch_file({ "ninja", "x.bat" }))
            assert.is_false(build_run.runs_batch_file({ "cmd", "/c", "ninja" }))
            assert.is_false(build_run.runs_batch_file({}))
            assert.is_false(build_run.runs_batch_file(nil))
        end)
    end)

    describe("build_run.plan", function()
        local seen_opts
        local function plan_returns(steps, err)
            stub(overseer, "plan_profile_build", function(_, o)
                seen_opts = o
                return steps, err
            end)
        end

        it("refuses an unbuildable profile before planning", function()
            local planned = false
            stub(overseer, "plan_profile_build", function() planned = true; return {} end)
            local steps, err = build_run.plan({ assert_buildable = function() return false, "abstract" end })
            assert.is_nil(steps)
            assert.equals("abstract", err)
            assert.is_false(planned)
        end)

        it("prefixes a plan error with 'cannot build:'", function()
            plan_returns(nil, "no tool")
            local steps, err = build_run.plan({})
            assert.is_nil(steps)
            assert.equals("cannot build: no tool", err)
        end)

        it("returns an empty list when nothing is planned", function()
            plan_returns(nil, nil)
            assert.same({}, build_run.plan({}))
        end)

        it("forwards the build request to the module plan", function()
            plan_returns({}, nil)
            build_run.plan({}, { for_test = true, reconfigure = true,
                extra_args = { "-j1" }, build_targets = { "app" } })
            assert.same({ for_test = true, reconfigure = true,
                build_args = { "-j1" }, build_targets = { "app" } }, seen_opts)
        end)

        it("refuses --target for a module that did not apply it", function()
            plan_returns({ { kind = "configure", name = "c" }, { kind = "build", name = "App/Debug", cmd = { "ninja" } } })
            local steps, err = build_run.plan({}, { build_targets = { "app" } })
            assert.is_nil(steps)
            assert.matches("^App/Debug: this project's module does not support %-%-target", err)
        end)

        it("accepts --target the module applied", function()
            plan_returns({ { kind = "build", name = "b", cmd = { "ninja", "app" }, applied_build_targets = true } })
            local steps = build_run.plan({}, { build_targets = { "app" } })
            assert.same({ "ninja", "app" }, steps[1].cmd)
        end)

        it("appends unapplied forwarded args to a copy of the build command", function()
            local cmd = { "ninja" }
            plan_returns({ { kind = "configure", cmd = { "cmake" } }, { kind = "build", name = "b", cmd = cmd } })
            local steps = build_run.plan({}, { extra_args = { "-k", "0" } })
            assert.same({ "cmake" }, steps[1].cmd)
            assert.same({ "ninja", "-k", "0" }, steps[2].cmd)
            assert.same({ "ninja" }, cmd)
        end)

        it("does not append args the module applied", function()
            plan_returns({ { kind = "build", cmd = { "ninja", "-k", "0" }, applied_build_args = true } })
            local steps = build_run.plan({}, { extra_args = { "-k", "0" } })
            assert.same({ "ninja", "-k", "0" }, steps[1].cmd)
        end)

        -- The resolution is part of the plan, so the in-process `lw build` and
        -- a daemon-routed build (§19.15, both call build_run.plan) resolve
        -- `--target` operands identically (§16.4).
        describe("--target operands", function()
            local App, Lib = { key = "App" }, { key = "Lib" }
            local function unit(project, targets)
                return { _project = project, targets = targets, configure_reason = function() return nil end }
            end
            local function profile()
                local pps = {
                    { _project = App, _config_unit = unit(App, { AppRunner = {}, Common = {} }) },
                    { _project = Lib, _config_unit = unit(Lib, { Common = {} }) },
                }
                return { key = "dev", projects = function() return pps end }
            end

            it("resolves the qualified form to the project and its bare name, before the module plan", function()
                plan_returns({ { kind = "build", name = "b", cmd = { "ninja", "AppRunner" },
                    applied_build_targets = true, unit = { _project = App } } })
                local steps = build_run.plan(profile(), { build_targets = { "App:AppRunner" } })
                assert.same({ [App] = { "AppRunner" } }, seen_opts.build_targets_for)
                assert.same({ "AppRunner" }, steps[1].build_targets)
            end)

            it("refuses an ambiguous operand without planning", function()
                local planned = false
                stub(overseer, "plan_profile_build", function() planned = true; return {} end)
                local steps, err = build_run.plan(profile(), { build_targets = { "Common" } })
                assert.is_nil(steps)
                assert.matches("App:Common, Lib:Common", err)
                assert.is_false(planned)
            end)

            it("gives a name no list has to every project, a qualified one to its project", function()
                plan_returns({}, nil)
                build_run.plan(profile(), { build_targets = { "install", "Lib:docs" } })
                assert.same({ [App] = { "install" }, [Lib] = { "install", "docs" } }, seen_opts.build_targets_for)
            end)

            it("split_target_ref qualifies only with a profile project", function()
                local p = profile()
                local proj, bare = build_run.split_target_ref(p, "Lib:x:y")
                assert.equals(Lib, proj); assert.equals("x:y", bare)
                proj, bare = build_run.split_target_ref(p, "foo:executable")
                assert.is_nil(proj); assert.equals("foo:executable", bare)
            end)
        end)

        -- `Build/1` additions (spec §19.15 "Editor scopes and configure").
        describe("editor scopes (configure_only, jobs, units, { project, target })", function()
            local App, Lib = { key = "App" }, { key = "Lib" }
            local function unit(project, key, targets, compat)
                return { _project = project, targets = targets, configure_reason = function() return nil end,
                    config_key = function() return key end, build_dir = function() return "/b/" .. project.key end,
                    tool_compat_error = function() return compat end }
            end
            local function profile()
                local pps = {
                    { _project = App, _config_unit = unit(App, "Debug", { AppRunner = {} }) },
                    { _project = Lib, _config_unit = unit(Lib, "Debug", { docs = {} }) },
                }
                return { key = "dev", projects = function() return pps end }
            end

            it("forwards configure_only to the profile plan", function()
                plan_returns({ { kind = "configure", cmd = { "cmake" } } })
                local steps = build_run.plan({}, { configure_only = true })
                assert.is_true(seen_opts.configure_only)
                assert.same({ "cmake" }, steps[1].cmd)
            end)

            it("appends jobs to a copy of every build step's command, as the editor's -j option", function()
                local cmd = { "cmake", "--build", "b" }
                plan_returns({ { kind = "configure", cmd = { "cmake" } }, { kind = "build", name = "b", cmd = cmd } })
                local steps = build_run.plan({}, { jobs = 1 })
                assert.same({ "cmake" }, steps[1].cmd)
                assert.same({ "cmake", "--build", "b", "--", "-j1" }, steps[2].cmd)
                assert.same({ "cmake", "--build", "b" }, cmd)
            end)

            it("puts jobs after the build tool's existing `--` (forwarded args), never a second `--`", function()
                plan_returns({ { kind = "build", name = "b", cmd = { "cmake", "--build", "b" } } })
                local steps = build_run.plan({}, { jobs = 2, extra_args = { "--", "-k", "0" } })
                assert.same({ "cmake", "--build", "b", "--", "-j2", "-k", "0" }, steps[1].cmd)
            end)

            it("plans configuration units with their own tasks, never the profile plan", function()
                local profile_planned = false
                stub(overseer, "plan_profile_build", function() profile_planned = true; return {} end)
                local seen_units, seen_o
                stub(overseer, "plan_units_build", function(u, o)
                    seen_units, seen_o = u, o
                    return { { kind = "build", name = "b", cmd = { "x" } } }
                end)
                local u = unit(App, "Debug")
                local steps = build_run.plan(nil, { units = { u }, configure_only = true, reconfigure = true })
                assert.same({ u }, seen_units)
                assert.is_true(seen_o.configure_only)
                assert.is_true(seen_o.reconfigure)
                assert.equals(1, #steps)
                assert.is_false(profile_planned)
            end)

            it("refuses a unit whose tool cannot honor its configuration, before planning", function()
                local planned = false
                stub(overseer, "plan_units_build", function() planned = true; return {} end)
                local steps, err = build_run.plan(nil, { units = { unit(App, "Debug", nil, "tool is x86") } })
                assert.is_nil(steps)
                assert.equals("tool is x86 — change the profile's tool to match the configuration", err)
                assert.is_false(planned)
            end)

            it("resolves a { project, target } operand to that project only", function()
                plan_returns({}, nil)
                build_run.plan(profile(), { build_targets = { { project = "Lib", target = "AppRunner" } } })
                assert.same({ [Lib] = { "AppRunner" } }, seen_opts.build_targets_for)
            end)

            it("refuses a { project, target } operand whose project the scope does not build", function()
                local planned = false
                stub(overseer, "plan_profile_build", function() planned = true; return {} end)
                local steps, err = build_run.plan(profile(), { build_targets = { { project = "Nope", target = "x" } } })
                assert.is_nil(steps)
                assert.equals("target 'x' names project 'Nope', which profile 'dev' does not build", err)
                assert.is_false(planned)
            end)

            it("resolves target operands against the units of a units scope", function()
                local seen_o
                stub(overseer, "plan_units_build", function(_, o) seen_o = o; return {} end)
                local u = unit(Lib, "Debug", { docs = {} })
                build_run.plan(nil, { units = { u }, build_targets = { "docs", { project = "Lib", target = "x" } } })
                assert.same({ [Lib] = { "docs", "x" } }, seen_o.build_targets_for)
                local steps, err = build_run.plan(nil, { units = { u },
                    build_targets = { { project = "App", target = "AppRunner" } } })
                assert.is_nil(steps)
                assert.equals("target 'AppRunner' names project 'App', which Lib/Debug does not build", err)
            end)

            it("names units, their build dirs, and their nothing-to-do refusals", function()
                local a, l = unit(App, "Debug"), unit(Lib, "Release")
                assert.equals("App/Debug, Lib/Release", build_run.units_label({ a, l }))
                assert.same({ "/b/App", "/b/Lib" }, build_run.unit_build_dirs({ a, l, a }))
                assert.equals("nothing to build for App/Debug — no buildable projects (unavailable module or "
                    .. "unresolved tool?)", build_run.nothing_to_build_message(nil, "App/Debug"))
                assert.equals("nothing to clean for profile 'dev' — no configured build directories.",
                    build_run.nothing_to_clean_message({ key = "dev" }))
                assert.equals("nothing to clean for App/Debug — no configured build directories.",
                    build_run.nothing_to_clean_message(nil, "App/Debug"))
            end)

            it("plans a units clean with the units' clean tasks", function()
                local seen
                stub(overseer, "plan_units_clean", function(u) seen = u; return { { kind = "clean" } } end)
                local a = unit(App, "Debug")
                assert.same({ { kind = "clean" } }, build_run.plan_clean(nil, { a }))
                assert.same({ a }, seen)
                stub(overseer, "plan_units_clean", function() return {} end)
                assert.is_nil(build_run.plan_clean(nil, { a }))
            end)

            it("resolves a bare target in several units of ONE project to that project (not ambiguous)", function()
                local picks, err = build_run.resolve_build_targets(nil, { "foo" },
                    { units = { unit(App, "Debug", { foo = {} }), unit(App, "Release", { foo = {} }) } })
                assert.is_nil(err)
                assert.same({ [App] = { "foo" } }, picks)
                -- Two projects still make it ambiguous, each named once.
                picks, err = build_run.resolve_build_targets(nil, { "foo" }, { units = {
                    unit(App, "Debug", { foo = {} }), unit(App, "Release", { foo = {} }),
                    unit(Lib, "Debug", { foo = {} }) } })
                assert.is_nil(picks)
                assert.matches("projects: App:foo, Lib:foo\n", err, 1, true)
            end)

            it("split_target_ref qualifies against a profile or a project list (the one rule)", function()
                local p, bare = build_run.split_target_ref({ App, Lib }, "Lib:x")
                assert.equals(Lib, p); assert.equals("x", bare)
                p, bare = build_run.split_target_ref({ App }, "Lib:x")
                assert.is_nil(p); assert.equals("Lib:x", bare)
                p, bare = build_run.split_target_ref(profile(), "App:y:z")
                assert.equals(App, p); assert.equals("y:z", bare)
            end)
        end)

        -- overseer.plan_units_build / plan_units_clean over fake units (§19.15).
        describe("units plans", function()
            local function task(action, name)
                return { name = name, loomworks = { action = action },
                    builder = function() return { cmd = { name } } end }
            end
            local function mod_project(key, tasks, clean)
                return { key = key, type = "fake", path = key,
                    _type_config_for_module = function() return {} end,
                    _module = { impl = { tasks = tasks and function() return tasks end or nil,
                        clean_tasks = clean and function() return clean end or nil } } }
            end
            local function ounit(project, key, tool)
                return { _project = project, _workspace = { root = "/ws" }, _tool = tool,
                    variant = function() return key end, config_key = function() return key end,
                    tool_key = function() return tool and tool.key or nil end,
                    tool_data = function() return nil end,
                    build_dir = function() return "/b/" .. project.key end,
                    configure_reason = function() return nil end }
            end
            local undetected = { key = "gcc-1", _detected = false }
            before_each(function() stub(vim, "notify", function() end) end)

            it("refuses a unit with no tasks (no module, undetected tool), never an empty plan", function()
                local good = ounit(mod_project("Lib", { task("build", "lb") }), "Debug")
                local steps, err = overseer.plan_units_build({ good, ounit({ key = "App" }, "Debug") },
                    { configure_only = true })
                assert.is_nil(steps)
                assert.equals("App/Debug: no tasks (unavailable module or undetected tool)", err)
                steps, err = build_run.plan(nil, { units = {
                    ounit(mod_project("App", { task("configure", "c") }), "Debug", undetected) } })
                assert.is_nil(steps)
                assert.equals("cannot build: App/Debug: no tasks (unavailable module or undetected tool)", err)
            end)

            it("plans nothing to configure for a module with no configure step", function()
                local steps, err = overseer.plan_units_build({ ounit(mod_project("App", { task("build", "b") }), "Debug") },
                    { configure_only = true })
                assert.is_nil(err)
                assert.same({}, steps)
            end)

            it("refuses a units clean with an undetected tool, as a profile clean does", function()
                local p = mod_project("App", nil, { { name = "clean", builder = function() return { cmd = { "c" } } end } })
                assert.equals(1, #overseer.plan_units_clean({ ounit(p, "Debug") }))
                assert.is_nil(overseer.plan_units_clean({ ounit(p, "Debug"), ounit(p, "Release", undetected) }))
            end)
        end)

        it("refuses forwarded args for a batch-file build", function()
            plan_returns({ { kind = "build", name = "b", cmd = { "cmd", "/c", "!LOOMWORKS_VCVARS_BAT!" } } })
            local steps, err = build_run.plan({}, { extra_args = { "-k", "0" } })
            assert.is_nil(steps)
            assert.matches("^b: cannot forward build%-tool args", err)
        end)
    end)

    describe("build_run.before_step", function()
        it("refuses a build whose artifact conflicts, passing force through", function()
            local forced
            local ws = { artifact_conflict_block = function(_, _, f)
                forced = f
                return { profile = "rel", path = "/o/app.exe" }
            end }
            local ok, err = build_run.before_step(ws, { kind = "build", unit = {} })
            assert.is_nil(ok)
            assert.is_false(forced)
            assert.equals(build_run.conflict_message({ profile = "rel", path = "/o/app.exe" }), err)
            assert.matches("built profile 'rel'", err)
            assert.matches("pass %-%-force", err)
        end)

        it("lets a forced or conflict-free build through", function()
            local ws = { artifact_conflict_block = function(_, _, f) return not f and {} or nil end }
            assert.is_true(build_run.before_step(ws, { kind = "build", unit = {} }, { force = true }))
            -- No unit / no gate on the workspace: nothing checked.
            assert.is_true(build_run.before_step({}, { kind = "build", unit = {} }))
            assert.is_true(build_run.before_step(ws, { kind = "build" }))
        end)

        it("runs the full-reconfigure reset before a configure", function()
            local got
            local ws = { _pre_configure_reset = function(_, bd, entries) got = { bd, entries }; return true end }
            assert.is_true(build_run.before_step(ws, { kind = "configure", build_dir = "/b",
                pre_configure_reset = { "CMakeCache.txt" } }))
            assert.same({ "/b", { "CMakeCache.txt" } }, got)
        end)

        it("reports a refused reset and skips an empty one", function()
            local calls = 0
            local ws = { _pre_configure_reset = function() calls = calls + 1; return nil, "outside build dir" end }
            assert.is_true(build_run.before_step(ws, { kind = "configure", pre_configure_reset = {} }))
            assert.equals(0, calls)
            local ok, err = build_run.before_step(ws, { kind = "configure", pre_configure_reset = { "x" } })
            assert.is_nil(ok)
            assert.equals("outside build dir", err)
        end)
    end)

    describe("build_run.step_lines", function()
        it("announces the step, says why a configure runs, and logs the command", function()
            local logged
            stub(overseer, "configure_reason_line", function() return "full reconfigure (--fresh)" end)
            stub(overseer, "log_task_command", function(ws, name, step, cwd) logged = { ws, name, step, cwd } end)
            local ws = { root = "/ws" }
            local step = { kind = "configure", name = "App/Debug", cmd = { "cmake" } }
            assert.same({ "==> [configure] App/Debug", "    full reconfigure (--fresh)" },
                build_run.step_lines(ws, step))
            assert.same({ ws, "App/Debug", step, "/ws" }, logged)
        end)

        it("adds the command line + cwd with verbose; no reason line for a build", function()
            stub(overseer, "configure_reason_line", function() error("not for a build") end)
            stub(overseer, "log_task_command", function() end)
            stub(overseer, "command_text", function() return "ninja -C /b" end)
            assert.same({ "==> [build] ?", "    $ ninja -C /b", "    (in /b)" },
                build_run.step_lines({ root = "/ws" }, { kind = "build", cwd = "/b" }, { verbose = true }))
        end)
    end)

    describe("build_run.spawn_spec", function()
        it("reports an unresolvable program", function()
            stub(exe, "harden_spec", function() return nil, "ninja: not found" end)
            local spec, err = build_run.spawn_spec({ cmd = { "ninja" } }, "/ws")
            assert.is_nil(spec)
            assert.equals("cannot run step: ninja: not found", err)
        end)

        it("uses the hardened argv, the root as default cwd, and drops an empty env", function()
            stub(exe, "harden_spec", function(s) return { cmd = { "/bin/ninja" }, env = s.env } end)
            assert.same({ cmd = { "/bin/ninja" }, cwd = "/ws" },
                build_run.spawn_spec({ cmd = { "ninja" }, env = {} }, "/ws"))
            assert.same({ cmd = { "/bin/ninja" }, cwd = "/b", env = { A = "1" } },
                build_run.spawn_spec({ cmd = { "ninja" }, cwd = "/b", env = { A = "1" } }, "/ws"))
        end)
    end)

    describe("build_run.record / after_step", function()
        local function ws_spy()
            local ws = { results = {}, populated = {} }
            function ws:record_task_result(r) self.results[#self.results + 1] = r end
            function ws:_populate_resolved_artifacts(u, bd, v) self.populated[#self.populated + 1] = { u, bd, v } end
            return ws
        end

        it("records the outcome with the configure record and profile, not build_dir", function()
            local ws = ws_spy()
            local unit, profile, info = { _variant = "Debug" }, {}, { cache_launcher = "x" }
            build_run.record(ws, { kind = "configure", unit = unit, build_dir = "/b",
                module_info = info, profile = profile }, true)
            assert.equals("/b", unit.build_dir_value)
            assert.same({ unit = unit, action = "configure", success = true,
                module_info = info, profile = profile }, ws.results[1])
            assert.is_nil(ws.results[1].build_dir)
        end)

        it("does nothing without a unit and swallows a recording error", function()
            local ws = ws_spy()
            build_run.record(ws, { kind = "build" }, true)
            assert.equals(0, #ws.results)
            ws.record_task_result = function() error("boom") end
            assert.has_no.errors(function() build_run.record(ws, { kind = "build", unit = {} }, false) end)
        end)

        it("populates artifacts only after a successful configure", function()
            local ws = ws_spy()
            local unit = { _variant = "Debug" }
            build_run.after_step(ws, { kind = "configure", unit = unit, build_dir = "/b" }, 1)
            build_run.after_step(ws, { kind = "build", unit = unit, build_dir = "/b" }, 0)
            assert.equals(0, #ws.populated)
            build_run.after_step(ws, { kind = "configure", unit = unit, build_dir = "/b" }, 0)
            assert.same({ { unit, "/b", "Debug" } }, ws.populated)
            assert.same({ false, true, true }, vim.tbl_map(function(r) return r.success end, ws.results))
        end)
    end)

    describe("build_run.failure_message", function()
        it("names the step and exit code", function()
            assert.equals("configure failed (exit 2): App/Debug",
                build_run.failure_message({ kind = "configure", name = "App/Debug" }, 2))
            assert.equals("build failed (exit 1): ?", build_run.failure_message({ kind = "build" }, 1))
        end)

        it("leads with the extra hint, then the cache-compat hint", function()
            stub(compiler_cache, "compat_failure_hint", function(cc) return cc and "compat: /Zi" or nil end)
            local step = { kind = "build", name = "b", unit = { module_info = { cache_compat = {} } } }
            assert.equals("build failed (exit 1): b\nlw: compat: /Zi", build_run.failure_message(step, 1))
            assert.equals("build failed (exit 1): b\nlw: no target 'x'\nlw: compat: /Zi",
                build_run.failure_message(step, 1, "no target 'x'"))
            assert.equals("build failed (exit 1): b\nlw: no target 'x'",
                build_run.failure_message({ kind = "build", name = "b" }, 1, "no target 'x'"))
        end)
    end)
end)
