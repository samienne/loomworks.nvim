--- Unit tests of the daemon's build of a launch target (`Launch/1.build`,
--- spec §19.15 "Build of a launch target") and of the steps of a
--- target-scoped task (§19.15 "Steps of a task"): the plan in the start
--- meta, each step's transitions, `skipped` / `failed` / `cancelled` at the
--- task's end, `force` reaching the conflict gate, a device target built
--- with its post-build deploy (step 5n), a cancel stopping between two deploy copies — and the
--- task stream's step state (Task:step, Task:info) behind Tasks/1.

local service = require("loomworks.daemon.service")
local runner = require("loomworks.daemon.runner")
local build_run = require("loomworks.build_run")
local run_prep = require("loomworks.run_prep")
local tasks_mod = require("loomworks.daemon.tasks")

local function stub(tbl, key, fn)
    local orig = tbl[key]
    tbl[key] = fn
    return function() tbl[key] = orig end
end

describe("daemon launch-target build (§19.15 Build of a launch target)", function()
    local restores
    before_each(function() restores = {} end)
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
    end)
    local function with(tbl, key, fn) restores[#restores + 1] = stub(tbl, key, fn) end

    local function unit(name, nsteps)
        return { name = name, steps = nsteps or 1, config_key = function() return "Debug" end }
    end

    --- A launch target of project `app` with a dependency `lib` and a
    --- pre-build and a post-build deploy (each one copy).
    local function launch_target(fields)
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app: hello" end,
            _project = { key = "app" },
            _launch = { command = "/bin/app" }, _config_unit = unit("app"),
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return unit("lib") end,
            deploy_count = function() return 1 end,
            _deploy_phase = function(_, _, cb) cb(true) end,
        }
        for k, v in pairs(fields or {}) do lt[k] = v end
        return lt
    end

    --- Run the runner (`op`, default the launch target's build) with the
    --- resolution stubbed and every build step a spawn ending with
    --- `opts.exit[unit name]` (0); returns a record of what the task saw.
    local function run_op(lt, args, opts)
        opts = opts or {}
        with(run_prep, "select", function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return opts.foreign and opts.foreign() or nil end)
        with(run_prep, "resolve_spec", function()
            return { name = "app: hello", cmd = "/bin/app", args = {}, cwd = "/ws/app" }
        end)
        with(run_prep, "env_overrides", function() return {} end)
        local rec = { calls = {}, steps = {}, lines = {}, force = {} }
        local overseer = require("loomworks.overseer")
        with(overseer, "plan_unit_build", function(_, u)
            rec.calls[#rec.calls + 1] = "build " .. u.name
            if opts.on_build then opts.on_build(u) end
            local out = {}
            for n = 1, u.steps do out[n] = { kind = "build", name = u.name, cmd = { "x" } } end
            return out
        end)
        with(build_run, "spawn_spec", function() return { cmd = { "x" }, cwd = "/ws" } end)
        with(build_run, "before_step", function(_, _, o)
            rec.force[#rec.force + 1] = o.force
            return true
        end)
        with(build_run, "step_lines", function() return {} end)
        with(build_run, "after_step", function() end)
        with(runner, "spawn", function(spec, sink)
            if opts.hold then opts.hold.sink = sink; return { pid = nil } end
            sink.done((opts.exit or {})[rec.calls[#rec.calls]:sub(7)] or 0)
        end)
        local ws = { root = "/ws" }
        local task = {
            start = function(_, meta) rec.meta = meta end,
            step = function(_, index, state, err) rec.steps[#rec.steps + 1] = { index, state, err } end,
            progress = function() end, output = function() end, set_flow = function() end,
            line = function(_, _, text) rec.lines[#rec.lines + 1] = text end,
            done = function(_, code, err, fields) rec.done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        local svc = { ws = ws, host = {}, with_model = function(_, _, fn) return fn() end }
        rec.run = runner.run(svc, { op = opts.op or "target_build", task = task, ws = ws, profile = profile,
            env = {}, args = args or {} })
        return rec
    end

    --- The steps' (index, state) transitions as strings.
    local function transitions(rec)
        local out = {}
        for _, s in ipairs(rec.steps) do out[#out + 1] = s[1] .. ":" .. s[2] end
        return out
    end

    it("builds the dependencies, the pre-build deploy and the target's own unit, nothing after", function()
        local lt = launch_target()
        lt._deploy_phase = function(_, phase, cb, o)
            lt.deployed = (lt.deployed or "") .. phase
            assert.is_true(o.async)
            cb(true)
        end
        lt.deploy_sync = function() error("no launch deploy") end
        local rec = run_op(lt, {})
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.are.same({ "build lib", "build app" }, rec.calls)
        assert.are.equal("pre_build", lt.deployed)
        -- No launch resolved, no device outcome.
        assert.is_nil(rec.done.fields)
        assert.are.equal("build", rec.meta.kind)
        assert.are.same({ "building launch target: app: hello", "building dependency: lib",
            "deploying (pre_build): 1 copy", "BUILD OK: app: hello" }, rec.lines)
    end)

    it("announces its plan in the start meta, each step pending, no probe or post-build deploy", function()
        local rec = run_op(launch_target({
            _target = { id = "hello", _config_unit = unit("app") }, _config_unit = false,
        }), {})
        assert.are.equal(0, rec.done.code, rec.done.err)
        local steps = rec.meta.steps
        assert.are.equal(3, #steps)
        assert.are.same({ id = "s1", kind = "build", label = "dependency lib", project = "lib",
            configuration = "Debug", state = "pending" }, steps[1])
        assert.are.same({ id = "s2", kind = "deploy", label = "deploy (pre_build)", project = "app",
            phase = "pre_build", state = "pending" }, steps[2])
        assert.are.same({ id = "s3", kind = "build", label = "app: hello", project = "app",
            configuration = "Debug", target = "hello", state = "pending" }, steps[3])
        assert.are.same({ "1:running", "1:ok", "2:running", "2:ok", "3:running", "3:ok" }, transitions(rec))
    end)

    it("plans no deploy step for a phase that declares no copies", function()
        local rec = run_op(launch_target({
            deploy_count = function() return 0 end,
            _deploy_phase = function() error("no deploy without copies") end,
        }), {})
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.are.equal(2, #rec.meta.steps)
        assert.are.equal("build", rec.meta.steps[2].kind)
    end)

    it("ends at a failing step with its failure line, the later steps skipped", function()
        local rec = run_op(launch_target(), {}, { exit = { lib = 2 } })
        assert.are.equal(2, rec.done.code)
        assert.are.same({ "build lib" }, rec.calls)
        assert.are.same({ "1:running", "1:failed", "2:skipped", "3:skipped" }, transitions(rec))
        assert.are.equal(rec.done.err, rec.steps[2][3])
        assert.is_string(rec.done.err)
    end)

    it("fails the pre-build deploy step with the in-process line", function()
        local rec = run_op(launch_target({
            _deploy_phase = function(_, _, cb) cb(false, "source file missing: x") end,
        }), {})
        assert.are.equal(1, rec.done.code)
        assert.are.equal("deploy failed: source file missing: x", rec.done.err)
        assert.are.same({ "1:running", "1:ok", "2:running", "2:failed", "3:skipped" }, transitions(rec))
    end)

    it("builds a device target like any other, its post-build deploy included (step 5n)", function()
        local lt = launch_target({ requires_device = function() return true end })
        lt._deploy_phase = function(_, phase, cb)
            lt.deployed = (lt.deployed or "") .. phase .. ";"
            cb(true)
        end
        local rec = run_op(lt, {})
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.are.same({ "build lib", "build app" }, rec.calls)
        assert.are.equal("pre_build;post_build;", lt.deployed)
        -- No probe, no launch resolved, no device outcome: install and
        -- launch are Devices/1's.
        assert.is_nil(rec.done.fields)
        local kinds = {}
        for _, s in ipairs(rec.meta.steps) do kinds[#kinds + 1] = s.kind .. (s.phase and ("/" .. s.phase) or "") end
        assert.are.same({ "build", "deploy/pre_build", "build", "deploy/post_build" }, kinds)
        assert.are.equal("BUILD OK: app: hello", rec.lines[#rec.lines])
    end)

    it("a device target's post-build deploy failure fails the build", function()
        local lt = launch_target({ requires_device = function() return true end })
        lt._deploy_phase = function(_, phase, cb) cb(phase ~= "post_build", phase == "post_build" and "gone" or nil) end
        local rec = run_op(lt, {})
        assert.are.equal(1, rec.done.code)
        assert.are.equal("deploy failed: gone", rec.done.err)
        assert.are.same({ "1:running", "1:ok", "2:running", "2:ok", "3:running", "3:ok", "4:running", "4:failed" },
            transitions(rec))
    end)

    it("answers the artifact-conflict question with force on every build step", function()
        local rec = run_op(launch_target(), { force = true })
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.are.same({ true, true }, rec.force)
        rec = run_op(launch_target(), {})
        assert.are.same({ false, false }, { rec.force[1] == true, rec.force[2] == true })
    end)

    it("stops a cancelled deploy between two copies: the step cancelled, the later skipped", function()
        local lt = launch_target()
        local pending
        lt._deploy_phase = function(_, _, cb, o)
            -- One copy done; the next one checks the stop predicate first.
            pending = function()
                if o.cancelled() then return cb(false, "cancelled") end
                cb(true)
            end
        end
        local rec = run_op(lt, {})
        assert.is_nil(rec.done)
        rec.run.cancel("cancelled by the client that started it", 130)
        -- (The copy in flight ends the run.)
        assert.is_nil(rec.done)
        pending()
        assert.are.equal(130, rec.done.code)
        assert.matches("stopped: cancelled by the client", rec.done.err, 1, true)
        assert.are.same({ "1:running", "1:ok", "2:running", "2:cancelled", "3:skipped" }, transitions(rec))
        assert.are.same({ "build lib" }, rec.calls)
    end)

    it("closes a deploy ok whose copies all completed though a cancel came during the last one", function()
        local lt = launch_target()
        local pending
        lt._deploy_phase = function(_, _, cb)
            -- The last copy is in flight: it completes, no further check.
            pending = function() cb(true) end
        end
        local rec = run_op(lt, {})
        rec.run.cancel("cancelled by the client that started it", 130)
        pending()
        -- The deploy did its work: ok; the cancel then stops the next phase.
        assert.are.same({ "1:running", "1:ok", "2:running", "2:ok", "3:skipped" }, transitions(rec))
        assert.are.equal(130, rec.done.code)
        assert.are.same({ "build lib" }, rec.calls)
    end)

    it("ends a task whose planning throws as a started failure with no steps", function()
        local rec
        assert.has_no.errors(function()
            rec = run_op(launch_target({ deploy_count = function() error("boom in planning") end }), {})
        end)
        assert.is_table(rec.meta)
        assert.is_nil(rec.meta.steps)
        assert.are.equal(1, rec.done.code)
        assert.matches("boom in planning", rec.done.err, 1, true)
        assert.are.same({}, rec.calls)
        assert.are.same({}, rec.steps)
    end)

    it("cancels a running build step: it is cancelled, the steps not reached skipped", function()
        local hold = {}
        with(runner, "kill", function() hold.sink.done(1) end)
        local rec = run_op(launch_target(), {}, { hold = hold })
        rec.run.cancel("cancelled by the client that started it", 130)
        assert.are.equal(130, rec.done.code)
        assert.are.same({ "1:running", "1:cancelled", "2:skipped", "3:skipped" }, transitions(rec))
    end)

    it("reports a preparation's probe and post-build deploy steps", function()
        local rec = run_op(launch_target(), { build_scope = "target" }, { op = "run" })
        assert.are.equal(0, rec.done.code, rec.done.err)
        local kinds = {}
        for _, s in ipairs(rec.meta.steps) do kinds[#kinds + 1] = s.kind .. (s.phase and ("/" .. s.phase) or "") end
        assert.are.same({ "build", "deploy/pre_build", "build", "probe", "deploy/post_build" }, kinds)
        assert.are.equal("run", rec.meta.kind)
        assert.are.same({ "1:running", "1:ok", "2:running", "2:ok", "3:running", "3:ok", "4:running", "4:ok",
            "5:running", "5:ok" }, transitions(rec))
        assert.are.equal("/bin/app", rec.done.fields.launch.cmd)
    end)

    it("hands a probed-foreign run to the client: the probe ok, the post-build deploy skipped", function()
        local built = false
        local rec = run_op(launch_target(), { build_scope = "target" }, { op = "run",
            foreign = function() return built and { reason = "probe", name = "app" } or nil end,
            on_build = function(u) if u.name == "app" then built = true end end })
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.is_true(rec.done.fields.device)
        assert.are.same({ "1:running", "1:ok", "2:running", "2:ok", "3:running", "3:ok", "4:running", "4:ok",
            "5:skipped" }, transitions(rec))
    end)

    it("fails a debug's probe step with the refusal of a probed-foreign artifact", function()
        local built = false
        with(require("loomworks.remote.foreign"), "refusal", function(f) return "REFUSED " .. f.name end)
        local rec = run_op(launch_target(), { build_scope = "target" }, { op = "debug",
            foreign = function() return built and { reason = "probe", name = "app" } or nil end,
            on_build = function(u) if u.name == "app" then built = true end end })
        assert.are.equal(1, rec.done.code)
        assert.are.equal("REFUSED app", rec.done.err)
        assert.are.same({ "4:running", "4:failed", "5:skipped" }, { transitions(rec)[7], transitions(rec)[8],
            transitions(rec)[9] })
        assert.are.equal("REFUSED app", rec.steps[8][3])
    end)

    it("has no steps for a preparation with no_build", function()
        local rec = run_op(launch_target({
            _deploy_phase = function() error("no deploy under no_build") end,
        }), { build_scope = "target", no_build = true }, { op = "debug" })
        assert.are.equal(0, rec.done.code, rec.done.err)
        assert.is_nil(rec.meta.steps)
        assert.are.same({}, rec.steps)
    end)
end)

describe("Launch/1.build and force: request validation", function()
    local function decline(op, args, interface)
        local reply
        local svc = setmetatable({ server = { _send = function(_, _, f) reply = f end } }, service.Service)
        svc.with_model = function() error("accepted a malformed request") end
        local deliver = interface and function(f) reply = f end or nil
        svc:_on_operation(op, { closed = false }, { args = args, env = { PATH = "/bin" } }, deliver)
        return reply
    end

    it("refuses force on a protocol-10 prepare_run, and a launch build's launch-only arguments", function()
        for _, c in ipairs({
            { "run", { force = true }, false },
            { "run", { force = 1 }, true },
            { "target_build", { cwd = "/x" }, true },
            { "target_build", { no_build = true }, true },
            { "target_build", { build_scope = "profile" }, true },
            { "target_build", { quiet = true }, true },
        }) do
            local r = decline(c[1], c[2], c[3])
            assert.are.equal("declined", r.outcome, vim.inspect(c))
            assert.are.equal("malformed request", r.reason)
        end
    end)
end)

describe("task steps on the task stream (§19.15 Steps of a task)", function()
    it("keeps the plan's current states for list, never in the status rows, and hooks each change", function()
        local stream = tasks_mod.new({ _send = function() end, conns = {} })
        local seen = {}
        stream.on_step = function(_, index, state, err) seen[#seen + 1] = { index, state, err } end
        local t = stream:create({ closed = true })
        local plan = { { id = "s1", kind = "build", label = "x", state = "pending" },
            { id = "s2", kind = "deploy", label = "y", phase = "pre_build", state = "pending" } }
        t:start({ name = "dev", kind = "build", steps = plan })
        t:step(1, "running")
        t:step(1, "running") -- (no change: no signal)
        t:step(1, "failed", "boom")
        t:step(2, "skipped")
        t:step(3, "ok") -- (no such step)
        assert.are.same({ { 1, "running" }, { 1, "failed", "boom" }, { 2, "skipped" } }, seen)
        -- The start meta's plan stays pending; the task's copy moved on.
        assert.are.equal("pending", plan[1].state)
        assert.are.equal("failed", t:info(nil, true).steps[1].state)
        assert.is_nil(t:info(nil).steps)
        assert.is_nil(stream:snapshot(nil)[1].steps)
        assert.are.equal("skipped", stream:snapshot(nil, true)[1].steps[2].state)
        t:done(1, "boom")
        t:step(2, "ok")
        assert.are.equal(3, #seen)
    end)
end)
