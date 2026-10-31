--- A profile-level operation with an invalid ProfileProject (core
--- state-lifecycle §5.4 "Invalid ProfileProjects"): every valid
--- ProfileProject runs; an invalid one (a tool compat error) is not run,
--- counts as finished and failed with its reason in the result message, the
--- Operation fails and a CLI invocation exits non-zero after the others ran.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local build_run = require("loomworks.build_run")
local cli = require("loomworks.cli")
local Operation = require("loomworks.operation")
local real_modules = require("loomworks.modules")

local REASON = "targets OpenHarmony but profile tool is HarmonyOS"

--- Shell projects `app` and `lib`, set + profile `dev` (app=Debug, lib=Debug).
--- `opts.collide`: lib's build directory is app's (`out/app/Debug`), so
--- lib/Debug is refused (core §1.7 "One build directory per configuration").
--- `opts.clean`: each project has a `cln-<name>` clean command and its build
--- directory exists (so a clean plans a step for it). `opts.invalid`: the
--- named projects' build_dir template names a variable a shell template may
--- not use, so the module reports an `error` for their Debug (§8 `info`): the
--- configuration is invalid. `opts.exe`: each command
--- runs this nvim with the name as its argument (resolvable on PATH, for the
--- editor's task hardening).
local function make_ws(opts)
    opts = opts or {}
    local function cmd(word)
        if opts.exe then return { (vim.v.progpath:gsub("\\", "/")), word } end
        return { word }
    end
    local root = (vim.fn.tempname():gsub("\\", "/"))
    for _, d in ipairs({ "app", "lib" }) do
        vim.fn.mkdir(root .. "/" .. d, "p")
        if opts.clean then vim.fn.mkdir(root .. "/out/" .. d .. "/Debug", "p") end
    end
    local function proj(name)
        return { path = name, shell = {
            build_dir = (opts.invalid and opts.invalid[name])
                and "${workspace_root}/out/${LW_PIPP_UNDECLARED}/${variant}"
                or (opts.collide and name == "lib" and "${workspace_root}/out/app/${variant}")
                or ("${workspace_root}/out/" .. name .. "/${variant}"),
            configure_cmd = cmd("cfg-" .. name), build_cmd = cmd("bld-" .. name),
            clean_cmd = opts.clean and cmd("cln-" .. name) or nil,
            configurations = { Debug = vim.empty_dict() },
        } }
    end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { app = proj("app"), lib = proj("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = { dev = { configuration_set = "dev" } },
            active_profile = "dev",
        }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    return ws, profile, root
end

--- Give the named projects' ProfileProjects a tool compat error.
local function mark_incompatible(profile, names)
    for _, pp in ipairs(profile:projects()) do
        if names[pp._project.key] then pp._tool_compat_error = REASON end
    end
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, a, b, c = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(a))
    return a, b, c
end

local function step_projects(steps)
    local out = {}
    for _, s in ipairs(steps or {}) do
        local u = s.unit
        out[#out + 1] = (u and u._project and u._project.key or "?") .. ":" .. s.kind
    end
    return out
end

describe("profile-level operation with an invalid ProfileProject (§5.4)", function()
    local root
    after_each(function()
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("the plan runs the valid projects and names the invalid one as refused", function()
        local ws, profile, r = make_ws()
        root = r
        mark_incompatible(profile, { lib = true })
        local steps, err, refused = with_ws(ws, function() return overseer.plan_profile_build(profile) end)
        assert.is_nil(err)
        assert.same({ "app:configure", "app:build" }, step_projects(steps))
        assert.equals(1, #refused)
        assert.truthy(refused[1]:find("lib/Debug", 1, true), refused[1])
        assert.truthy(refused[1]:find(REASON, 1, true), refused[1])
    end)

    it("build_run.plan hands the refusals on with the steps", function()
        local ws, profile, r = make_ws()
        root = r
        mark_incompatible(profile, { lib = true })
        local steps, err, refused = with_ws(ws, function() return build_run.plan(profile) end)
        assert.is_nil(err)
        assert.same({ "app:configure", "app:build" }, step_projects(steps))
        assert.equals(1, #refused)
        assert.truthy(build_run.refused_message(refused):find(REASON, 1, true))
    end)

    describe("headless lw build", function()
        local orig_spawn, orig_stderr, orig_exit, orig_write
        before_each(function()
            orig_spawn = cli._run_spec
            orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
        end)
        after_each(function()
            cli._run_spec = orig_spawn
            io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
        end)

        local function run(ws, profile)
            local spawned, err = {}, {}
            cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
            io.write = function() end
            io.stderr = { write = function(_, s) err[#err + 1] = s end }
            local code
            os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
            local loomworks = require("loomworks")
            local orig = loomworks.get_workspace
            loomworks.get_workspace = function() return ws end
            local ok, e = pcall(cli._run_build_steps, profile, ws, {})
            loomworks.get_workspace = orig
            if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
            return spawned, code, table.concat(err)
        end

        it("builds the valid projects, then exits non-zero naming the refused one", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { lib = true })
            local spawned, code, err = run(ws, profile)
            assert.same({ "cfg-app", "bld-app" }, spawned)
            assert.equals(1, code)
            assert.truthy(err:find("lib/Debug", 1, true), err)
            assert.truthy(err:find(REASON, 1, true), err)
        end)

        it("with every project refused, runs nothing and exits non-zero with the reasons", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { app = true, lib = true })
            local spawned, code, err = run(ws, profile)
            assert.same({}, spawned)
            assert.equals(1, code)
            assert.truthy(err:find("app/Debug", 1, true), err)
            assert.truthy(err:find("lib/Debug", 1, true), err)
            assert.is_nil(err:find("nothing to build", 1, true), err)
        end)
    end)

    describe("editor in-process profile action", function()
        local loomworks = require("loomworks")
        local saved
        before_each(function()
            saved = { gw = loomworks.get_workspace, pd = loomworks.has_pending_deletions,
                co = loomworks.create_operation, ov = package.loaded["overseer"] }
        end)
        after_each(function()
            loomworks.get_workspace, loomworks.has_pending_deletions = saved.gw, saved.pd
            loomworks.create_operation = saved.co
            package.loaded["overseer"] = saved.ov
        end)

        for _, action in ipairs({ "build", "configure" }) do
            it(action .. " with every project refused runs nothing, fails, and records a failed operation", function()
                local ws, profile, r = make_ws()
                root = r
                mark_incompatible(profile, { app = true, lib = true })
                local created = {}
                package.loaded["overseer"] = { new_task = function() error("no task may start") end }
                loomworks.get_workspace = function() return ws end
                loomworks.has_pending_deletions = function() return false end
                loomworks.create_operation = function(p, a, u, t, o)
                    local op = ws:create_operation(p, a, u, t, o)
                    created[#created + 1] = op
                    return op
                end
                local rejected
                overseer.run_profile_action(profile, action):catch(function(e) rejected = e end)
                vim.wait(1000, function() return rejected ~= nil end, 10)
                assert.truthy(rejected, "the action fails")
                assert.truthy(tostring(rejected):find("app/Debug", 1, true), tostring(rejected))
                assert.truthy(tostring(rejected):find(REASON, 1, true), tostring(rejected))
                assert.equals(1, #created)
                assert.is_true(created[1].completed)
                assert.is_false(created[1].success)
                assert.truthy(created[1].message:find("lib/Debug", 1, true), created[1].message)
            end)
        end
    end)

    describe("Operation", function()
        local function fake_ws()
            return { _core = { _deps = { clock = function() return 0 end,
                events = { emit = function() end } } } }
        end

        it("a refused ProfileProject fails the operation, its reason in the message", function()
            local unit = { on_state_change = function() return function() end end }
            local op = Operation.new(fake_ws(), nil, "build", { unit }, { [unit] = "built" }, nil,
                { track_tasks = true, refused = { "lib/Debug not run: " .. REASON } })
            op:unit_finished(unit, true)
            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.truthy(op.message:find(REASON, 1, true), op.message)
        end)

        it("with no unit to run, completes failed on its first check", function()
            local op = Operation.new(fake_ws(), nil, "build", {}, {}, nil,
                { refused = { "lib/Debug not run: " .. REASON } })
            op:_check_completion()
            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.truthy(op.message:find(REASON, 1, true), op.message)
        end)
    end)

    --- Each unit gets a native batch test runner `tst-<project>`.
    local function give_runners(profile)
        for _, pp in ipairs(profile:projects()) do
            local name = pp._project.key
            pp._config_unit.batch_runner_test_units = function()
                return { { run_command_all = function() return { cmd = { "tst-" .. name } } end } }
            end
        end
    end

    describe("tests (lw test / plan_profile_test)", function()
        it("plan_profile_test plans the valid projects' runners and names the refused one", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { lib = true })
            give_runners(profile)
            local steps, _, refused = with_ws(ws, function() return overseer.plan_profile_test(profile) end)
            assert.equals(1, #steps)
            assert.same({ "tst-app" }, steps[1].cmd)
            assert.equals(1, #refused)
            assert.truthy(refused[1]:find("lib/Debug", 1, true), refused[1])
            assert.truthy(refused[1]:find(REASON, 1, true), refused[1])
        end)

        it("the test plan leaves the refused project out and names it", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { lib = true })
            give_runners(profile)
            local pre = with_ws(ws, function()
                return require("loomworks.test_plan").precheck(profile, { extra = {} })
            end)
            assert.equals(1, #pre.plan)
            assert.equals("app", pre.plan[1].project.key)
            assert.equals(1, #pre.refused)
            assert.truthy(pre.refused[1]:find("lib/Debug", 1, true), pre.refused[1])
        end)

        describe("headless lw test", function()
            local orig_spawn, orig_stderr, orig_exit, orig_write
            before_each(function()
                orig_spawn = cli._run_spec
                orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
            end)
            after_each(function()
                cli._run_spec = orig_spawn
                io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
            end)

            local function run_test(ws, profile)
                local spawned, err = {}, {}
                cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
                io.write = function() end
                io.stderr = { write = function(_, s) err[#err + 1] = s end }
                local code
                os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
                local loomworks = require("loomworks")
                local orig = loomworks.get_workspace
                loomworks.get_workspace = function() return ws end
                local ok, e = pcall(cli._test_plan, ws, profile, { extra = {}, dev = cli._new_device_opts() }, {
                    with_locks = function(_, _, fn) fn() end,
                    run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end,
                })
                loomworks.get_workspace = orig
                if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
                if ok then code = e end
                return spawned, code, table.concat(err)
            end

            it("builds and tests the valid projects, then exits non-zero naming the refused one", function()
                local ws, profile, r = make_ws()
                root = r
                mark_incompatible(profile, { lib = true })
                give_runners(profile)
                local spawned, code, err = run_test(ws, profile)
                assert.same({ "cfg-app", "bld-app", "tst-app" }, spawned)
                assert.equals(1, code)
                assert.truthy(err:find("lib/Debug", 1, true), err)
                assert.truthy(err:find(REASON, 1, true), err)
            end)

            it("with every project refused, runs nothing and exits non-zero with the reasons", function()
                local ws, profile, r = make_ws()
                root = r
                mark_incompatible(profile, { app = true, lib = true })
                give_runners(profile)
                local spawned, code, err = run_test(ws, profile)
                assert.same({}, spawned)
                assert.equals(1, code)
                assert.truthy(err:find("app/Debug", 1, true), err)
                assert.truthy(err:find("lib/Debug", 1, true), err)
            end)
        end)
    end)

    describe("clean (§8.4: clean is blocked on an incompatible tool)", function()
        it("plan_profile_clean cleans the valid projects and names the refused one", function()
            local ws, profile, r = make_ws({ clean = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local steps, refused = with_ws(ws, function() return overseer.plan_profile_clean(profile) end)
            assert.same({ "app:clean" }, step_projects(steps))
            assert.equals(1, #refused)
            assert.truthy(refused[1]:find("lib/Debug", 1, true), refused[1])
        end)

        describe("headless lw clean", function()
            local orig_spawn, orig_stderr, orig_exit, orig_write
            before_each(function()
                orig_spawn = cli._run_spec
                orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
            end)
            after_each(function()
                cli._run_spec = orig_spawn
                io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
            end)

            local function run_clean(ws)
                local spawned, err = {}, {}
                cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
                io.write = function() end
                io.stderr = { write = function(_, s) err[#err + 1] = s end }
                local code
                os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
                local loomworks = require("loomworks")
                local orig = loomworks.get_workspace
                loomworks.get_workspace = function() return ws end
                local ok, e = pcall(cli.cmd_clean, ws, { "clean", "dev" })
                loomworks.get_workspace = orig
                if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
                if ok then code = e end
                return spawned, code, table.concat(err)
            end

            it("cleans the valid projects, then exits non-zero naming the refused one", function()
                local ws, profile, r = make_ws({ clean = true })
                root = r
                mark_incompatible(profile, { lib = true })
                local spawned, code, err = run_clean(ws)
                assert.same({ "cln-app" }, spawned)
                assert.equals(1, code)
                assert.truthy(err:find("lib/Debug", 1, true), err)
                assert.truthy(err:find(REASON, 1, true), err)
            end)

            it("with every project refused, exits non-zero with the reasons (not 'nothing to clean')", function()
                local ws, profile, r = make_ws({ clean = true })
                root = r
                mark_incompatible(profile, { app = true, lib = true })
                local spawned, code, err = run_clean(ws)
                assert.same({}, spawned)
                assert.equals(1, code)
                assert.truthy(err:find("app/Debug", 1, true), err)
                assert.truthy(err:find("lib/Debug", 1, true), err)
            end)
        end)
    end)

    describe("editor in-process partial operation", function()
        local loomworks = require("loomworks")
        local saved
        before_each(function()
            saved = { gw = loomworks.get_workspace, pd = loomworks.has_pending_deletions,
                co = loomworks.create_operation, ov = package.loaded["overseer"] }
        end)
        after_each(function()
            loomworks.get_workspace, loomworks.has_pending_deletions = saved.gw, saved.pd
            loomworks.create_operation = saved.co
            package.loaded["overseer"] = saved.ov
        end)

        --- A fake overseer whose tasks complete when the test says so.
        local function fake_overseer()
            local tasks = {}
            package.loaded["overseer"] = {
                new_task = function(spec)
                    local subs, done = {}, false
                    local t = { id = #tasks + 1, name = spec.name, cmd = spec.cmd }
                    function t.subscribe(_, ev, fn) subs[ev] = subs[ev] or {}; table.insert(subs[ev], fn) end
                    function t.start() end
                    function t.stop() end
                    function t.is_complete() return done end
                    function t.complete(_, status)
                        done = true
                        for _, fn in ipairs(subs["on_complete"] or {}) do fn(t, status) end
                    end
                    tasks[#tasks + 1] = t
                    return t
                end,
            }
            return tasks
        end

        local function setup_editor(ws)
            local created = {}
            loomworks.get_workspace = function() return ws end
            loomworks.has_pending_deletions = function() return false end
            loomworks.create_operation = function(p, a, u, t, o)
                local op = ws:create_operation(p, a, u, t, o)
                created[#created + 1] = op
                return op
            end
            return created
        end

        it("configure runs the valid project's task, then fails the operation naming the refused one", function()
            local ws, profile, r = make_ws({ exe = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local tasks = fake_overseer()
            local created = setup_editor(ws)
            local rejected, resolved
            overseer.run_profile_action(profile, "configure"):next(
                function() resolved = true end, function(e) rejected = e end)
            vim.wait(2000, function() return #tasks >= 1 end, 10)
            assert.equals(1, #tasks, "only the valid project's configure task starts")
            assert.truthy(tostring(tasks[1].name):find("app", 1, true), tostring(tasks[1].name))
            assert.equals(1, #created)
            assert.is_false(created[1].completed, "waits for the valid project's task")
            tasks[1]:complete("SUCCESS")
            vim.wait(2000, function() return rejected ~= nil or resolved ~= nil end, 10)
            assert.is_nil(resolved)
            assert.truthy(tostring(rejected):find("lib/Debug", 1, true), tostring(rejected))
            assert.is_true(created[1].completed)
            assert.is_false(created[1].success)
            assert.truthy(created[1].message:find(REASON, 1, true), created[1].message)
        end)

        it("profile clean cleans the valid project, then fails the operation naming the refused one", function()
            local ws, profile, r = make_ws({ clean = true, exe = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local tasks = fake_overseer()
            setup_editor(ws)
            -- (Profile:clean creates its operation on the workspace itself.)
            local created, orig_create = {}, ws.create_operation
            ws.create_operation = function(self, ...)
                local op = orig_create(self, ...)
                created[#created + 1] = op
                return op
            end
            local rejected, resolved
            profile:clean():next(function() resolved = true end, function(e) rejected = e end)
            vim.wait(2000, function() return #tasks >= 1 end, 10)
            assert.equals(1, #tasks, "only the valid project's clean task starts")
            assert.truthy(tostring(tasks[1].name):find("app", 1, true), tostring(tasks[1].name))
            tasks[1]:complete("SUCCESS")
            vim.wait(2000, function() return rejected ~= nil or resolved ~= nil end, 10)
            assert.is_nil(resolved)
            assert.truthy(tostring(rejected):find("lib/Debug", 1, true), tostring(rejected))
            assert.equals(1, #created)
            vim.wait(2000, function() return created[1].completed end, 10)
            assert.is_false(created[1].success)
            assert.truthy(created[1].message:find(REASON, 1, true), created[1].message)
        end)

        it("a failed clean task fails the clean naming the refused one beside it", function()
            local ws, profile, r = make_ws({ clean = true, exe = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local tasks = fake_overseer()
            setup_editor(ws)
            local rejected, resolved
            profile:clean():next(function() resolved = true end, function(e) rejected = e end)
            vim.wait(2000, function() return #tasks >= 1 end, 10)
            tasks[1]:complete("FAILURE")
            vim.wait(2000, function() return rejected ~= nil or resolved ~= nil end, 10)
            assert.is_nil(resolved)
            assert.truthy(tostring(rejected):find("clean failed", 1, true), tostring(rejected))
            assert.truthy(tostring(rejected):find("lib/Debug not run", 1, true), tostring(rejected))
        end)

        it("the in-process Build/1.clean names the refused ones as not_run", function()
            local ws, profile, r = make_ws({ clean = true, exe = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local tasks = fake_overseer()
            setup_editor(ws)
            local model = require("loomworks.ui.model_calls")
            local row = { key = "dev", units = {} }
            require("loomworks.status_source").bind(row, profile)
            local got
            model.call(ws, "Build/1.clean", { profile = row }, function(res) got = res end)
            vim.wait(2000, function() return #tasks >= 1 end, 10)
            tasks[1]:complete("SUCCESS")
            vim.wait(2000, function() return got ~= nil end, 10)
            assert.equals("refused", got.outcome)
            assert.truthy(got.message:find("lib/Debug not run", 1, true), got.message)
            assert.equals(1, #got.not_run)
            -- A failed clean task is a real failure: no not_run.
            got = nil
            model.call(ws, "Build/1.clean", { profile = row }, function(res) got = res end)
            vim.wait(2000, function() return #tasks >= 2 end, 10)
            tasks[2]:complete("FAILURE")
            vim.wait(2000, function() return got ~= nil end, 10)
            assert.equals("refused", got.outcome)
            assert.is_nil(got.not_run)
        end)

        it("the status-page rebuild builds the valid project after the clean, then fails naming the refused one",
            function()
            local ws, profile, r = make_ws({ clean = true, exe = true })
            root = r
            mark_incompatible(profile, { lib = true })
            local tasks = fake_overseer()
            setup_editor(ws)
            local actions = require("loomworks.ui.actions")
            local fidget = require("loomworks.fidget")
            local saved_show, saved_start = actions._show_confirmation, fidget.start_op_action
            local handle = { reports = {} }
            function handle:report(m) self.reports[#self.reports + 1] = m.message end
            function handle:finish() self.finished = true end
            function handle:cancel() self.failed = true end
            actions._show_confirmation = function(_, on_confirm) on_confirm() end
            fidget.start_op_action = function() return handle end
            local row = { key = "dev", units = {} }
            require("loomworks.status_source").bind(row, profile)
            local ok, err = pcall(function()
                actions.rebuild(row, ws)()
                -- Complete every task as it starts: the clean, then the build.
                vim.wait(5000, function()
                    for _, t in ipairs(tasks) do
                        if not t:is_complete() then t:complete("SUCCESS") end
                    end
                    return handle.finished or handle.failed
                end, 10)
            end)
            actions._show_confirmation, fidget.start_op_action = saved_show, saved_start
            assert.is_true(ok, tostring(err))
            local names = {}
            for _, t in ipairs(tasks) do names[#names + 1] = tostring(t.name) end
            assert.truthy(#tasks >= 2, vim.inspect(names))
            for _, n in ipairs(names) do
                assert.truthy(n:find("app", 1, true), "only the valid project runs: " .. vim.inspect(names))
            end
            assert.truthy(table.concat(names, "|"):find("clean", 1, true), vim.inspect(names))
            assert.is_true(handle.failed == true, vim.inspect(handle))
            assert.truthy(handle.reports[#handle.reports]:find("lib/Debug not run", 1, true),
                vim.inspect(handle.reports))
        end)

        it("shell's default wipe clean keeps a build directory a refused project shares", function()
            local function run(refuse)
                local ws, profile, r = make_ws({ exe = true })
                root = r
                if refuse then mark_incompatible(profile, { lib = true }) end
                -- Both configured into one directory, as a module's shared
                -- tree would be (two shell templates resolving to one
                -- directory are a collision, core §1.7, so it is set here).
                vim.fn.mkdir(r .. "/out/shared", "p")
                for _, pp in ipairs(profile:projects()) do
                    pp._config_unit.build_dir_value = r .. "/out/shared"
                end
                ws:_sync_build_dir_refs()
                fake_overseer()
                setup_editor(ws)
                local removed = {}
                local io_dep = ws._core._deps.io
                io_dep.rm_rf_async = function(path, cb)
                    removed[#removed + 1] = path
                    cb(true, nil)
                end
                io_dep.rm_rf = function(path) removed[#removed + 1] = path; return true end
                -- The daemon's / CLI's plan: no wipe of the shared dir either.
                local steps = with_ws(ws, function() return build_run.plan_clean(profile) end)
                local planned = {}
                for _, st in ipairs(steps or {}) do
                    if st.wipe_build_dir then planned[#planned + 1] = st.build_dir end
                end
                local settled, rejected
                profile:clean():next(function() settled = true end,
                    function(e) settled = true; rejected = e end)
                vim.wait(3000, function() return settled end, 10)
                vim.fn.delete(r, "rf"); root = nil
                return removed, rejected, planned
            end
            -- Control: nothing refused, the shared directory is wiped.
            local removed, rejected, planned = run(false)
            assert.is_nil(rejected, tostring(rejected))
            assert.truthy(#removed >= 1, "the wipe ran")
            assert.truthy(#planned >= 1, "the plan wipes it")
            -- lib refused: the valid project's wipe keeps the directory lib uses.
            removed, rejected, planned = run(true)
            assert.truthy(tostring(rejected):find("lib/Debug not run", 1, true), tostring(rejected))
            assert.same({}, planned)
            for _, p in ipairs(removed) do
                assert.is_nil(p:find("out/shared", 1, true), "removed " .. p)
            end
        end)
    end)
    describe("clean of a configuration the module reported an error for (§8 info, §5.4)", function()
        local loomworks = require("loomworks")
        local saved
        before_each(function()
            saved = { gw = loomworks.get_workspace, pd = loomworks.has_pending_deletions,
                co = loomworks.create_operation, ov = package.loaded["overseer"] }
        end)
        after_each(function()
            loomworks.get_workspace, loomworks.has_pending_deletions = saved.gw, saved.pd
            loomworks.create_operation = saved.co
            package.loaded["overseer"] = saved.ov
        end)

        local function fake_overseer()
            local tasks = {}
            package.loaded["overseer"] = {
                new_task = function(spec)
                    local subs, done = {}, false
                    local t = { id = #tasks + 1, name = spec.name, cmd = spec.cmd }
                    function t.subscribe(_, ev, fn) subs[ev] = subs[ev] or {}; table.insert(subs[ev], fn) end
                    function t.start() end
                    function t.stop() end
                    function t.is_complete() return done end
                    function t.complete(_, status)
                        done = true
                        for _, fn in ipairs(subs["on_complete"] or {}) do fn(t, status) end
                    end
                    tasks[#tasks + 1] = t
                    return t
                end,
            }
            return tasks
        end

        local function setup_editor(ws)
            loomworks.get_workspace = function() return ws end
            loomworks.has_pending_deletions = function() return false end
            loomworks.create_operation = function(p, a, u, t, o) return ws:create_operation(p, a, u, t, o) end
        end

        it("plan_profile_clean cleans the valid project and names the invalid one with its error", function()
            local ws, profile, r = make_ws({ clean = true, invalid = { lib = true } })
            root = r
            local steps, refused = with_ws(ws, function() return overseer.plan_profile_clean(profile) end)
            assert.same({ "app:clean" }, step_projects(steps))
            assert.equals(1, #(refused or {}), vim.inspect(refused))
            assert.truthy(refused[1]:find("lib/Debug not run", 1, true), refused[1])
            assert.truthy(refused[1]:find("LW_PIPP_UNDECLARED", 1, true), refused[1])
        end)

        it("headless lw clean cleans the valid project, then exits non-zero naming the invalid one", function()
            local ws, _, r = make_ws({ clean = true, invalid = { lib = true } })
            root = r
            local orig_spawn, orig_stderr, orig_exit, orig_write = cli._run_spec, io.stderr, os.exit, io.write
            local spawned, err = {}, {}
            cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
            io.write = function() end
            io.stderr = { write = function(_, s) err[#err + 1] = s end }
            local code
            os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
            local orig_gw = loomworks.get_workspace
            loomworks.get_workspace = function() return ws end
            local ok, e = pcall(cli.cmd_clean, ws, { "clean", "dev" })
            loomworks.get_workspace = orig_gw
            cli._run_spec, io.stderr, os.exit, io.write = orig_spawn, orig_stderr, orig_exit, orig_write
            if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
            if ok then code = e end
            local text = table.concat(err)
            assert.same({ "cln-app" }, spawned)
            assert.equals(1, code)
            assert.truthy(text:find("lib/Debug not run", 1, true), text)
            assert.truthy(text:find("LW_PIPP_UNDECLARED", 1, true), text)
        end)

        it("the editor's profile clean cleans the valid project, then fails naming the invalid one", function()
            local ws, profile, r = make_ws({ clean = true, exe = true, invalid = { lib = true } })
            root = r
            local tasks = fake_overseer()
            setup_editor(ws)
            local rejected, resolved
            profile:clean():next(function() resolved = true end, function(e) rejected = e end)
            vim.wait(2000, function() return #tasks >= 1 or rejected ~= nil end, 10)
            assert.equals(1, #tasks, tostring(rejected))
            assert.truthy(tostring(tasks[1].name):find("app", 1, true), tostring(tasks[1].name))
            tasks[1]:complete("SUCCESS")
            vim.wait(2000, function() return rejected ~= nil or resolved ~= nil end, 10)
            assert.is_nil(resolved)
            assert.truthy(tostring(rejected):find("lib/Debug not run", 1, true), tostring(rejected))
        end)

        it("the in-process Build/1.clean names the invalid one as not_run", function()
            local ws, profile, r = make_ws({ clean = true, exe = true, invalid = { lib = true } })
            root = r
            local tasks = fake_overseer()
            setup_editor(ws)
            local model = require("loomworks.ui.model_calls")
            local row = { key = "dev", units = {} }
            require("loomworks.status_source").bind(row, profile)
            local got
            model.call(ws, "Build/1.clean", { profile = row }, function(res) got = res end)
            vim.wait(2000, function() return #tasks >= 1 or got ~= nil end, 10)
            assert.equals(1, #tasks, vim.inspect(got))
            tasks[1]:complete("SUCCESS")
            vim.wait(2000, function() return got ~= nil end, 10)
            assert.equals("refused", got.outcome)
            assert.truthy(got.message:find("lib/Debug not run", 1, true), got.message)
            assert.equals(1, #(got.not_run or {}), vim.inspect(got))
        end)
    end)
    -- Core §1.7 "One build directory per configuration": a configuration whose
    -- directory another one keeps is refused, an invalid ProfileProject
    -- (`ProfileProject:invalid_reason`), so the §5.4 rule applies to it.
    describe("a refused build directory (§1.7)", function()
        local WANT = "lib/Debug not run: Build directory out/app/Debug of lib/Debug is already used by app/Debug"
        local orig_notify
        before_each(function()
            orig_notify = vim.notify
            vim.notify = function() end
        end)
        after_each(function() vim.notify = orig_notify end)

        it("is an invalid ProfileProject without a ConfigUnit", function()
            local _, profile, r = make_ws({ collide = true })
            root = r
            local lib = profile:project("lib")
            assert.is_nil(lib._config_unit)
            local reason, remedy = lib:invalid_reason()
            assert.truthy(reason and reason:find("cannot be built until", 1, true), tostring(reason))
            assert.is_nil(remedy)
            assert.is_nil(profile:project("app"):invalid_reason())
            assert.is_true((profile:assert_buildable()))
        end)

        it("the build plan runs the valid project and names the refused one", function()
            local ws, profile, r = make_ws({ collide = true })
            root = r
            local steps, err, refused = with_ws(ws, function() return build_run.plan(profile) end)
            assert.is_nil(err)
            assert.same({ "app:configure", "app:build" }, step_projects(steps))
            assert.equals(1, #refused)
            assert.truthy(refused[1]:find(WANT, 1, true), refused[1])
        end)

        it("the test plan leaves it out and names it", function()
            local ws, profile, r = make_ws({ collide = true })
            root = r
            local pre = with_ws(ws, function()
                return require("loomworks.test_plan").precheck(profile, { extra = {} })
            end)
            assert.equals(1, #pre.refused)
            assert.truthy(pre.refused[1]:find(WANT, 1, true), pre.refused[1])
            for _, u in ipairs(pre.plan or {}) do assert.equals("app", u.project.key) end
        end)

        describe("headless lw", function()
            local orig_spawn, orig_stderr, orig_exit, orig_write
            before_each(function()
                orig_spawn = cli._run_spec
                orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
            end)
            after_each(function()
                cli._run_spec = orig_spawn
                io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
            end)

            local function run(ws, fn, ...)
                local spawned, err = {}, {}
                cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
                io.write = function() end
                io.stderr = { write = function(_, s) err[#err + 1] = s end }
                local code
                os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
                local loomworks = require("loomworks")
                local orig = loomworks.get_workspace
                loomworks.get_workspace = function() return ws end
                local ok, e = pcall(fn, ...)
                loomworks.get_workspace = orig
                if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
                if ok and code == nil then code = e end
                return spawned, code, table.concat(err)
            end

            it("lw build builds the valid project, then exits 1 naming the refused one", function()
                local ws, profile, r = make_ws({ collide = true })
                root = r
                local spawned, code, err = run(ws, cli._run_build_steps, profile, ws, {})
                assert.same({ "cfg-app", "bld-app" }, spawned)
                assert.equals(1, code)
                assert.truthy(err:find(WANT, 1, true), err)
            end)

            it("lw clean cleans the valid project, then exits 1 naming the refused one", function()
                local ws, _, r = make_ws({ collide = true, clean = true })
                root = r
                local spawned, code, err = run(ws, cli.cmd_clean, ws, { "clean", "dev" })
                assert.same({ "cln-app" }, spawned)
                assert.equals(1, code)
                assert.truthy(err:find(WANT, 1, true), err)
            end)
        end)
    end)
end)
