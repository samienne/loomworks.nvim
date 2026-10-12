--- Unit tests of the daemon's `lw run` handling (spec §19.15 "Run"): the
--- cross-kit decline in Service:_accept, and the `--prefix` refusal of a
--- device target in the runner's preparation (before any deploy, as the
--- in-process `_run_launch_target_impl`); and of `Launch/1.prepare_debug`
--- (§19.15 "Debug") and the target build scope of both preparations
--- (§19.15 "Build scope of a launch").

local service = require("loomworks.daemon.service")
local runner = require("loomworks.daemon.runner")
local build_run = require("loomworks.build_run")
local run_prep = require("loomworks.run_prep")

local function stub(tbl, key, fn)
    local orig = tbl[key]
    tbl[key] = fn
    return function() tbl[key] = orig end
end

describe("daemon run preparation (§19.15 Run)", function()
    local restores
    before_each(function() restores = {} end)
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
    end)
    local function with(tbl, key, fn) restores[#restores + 1] = stub(tbl, key, fn) end

    it("declines a run of a profile whose kit builds for another platform, before any task", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        with(run_prep, "kit_platform", function(p) return p == profile and "ohos-arm64" or nil end)
        local created = false
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() created = true end },
        }, service.Service)
        local reply
        svc:_accept({ op = "run", conn = { closed = false }, args = {}, interactive = false,
            reply = function(f) reply = f end })
        assert.is_false(created)
        assert.are.same({ outcome = "declined", reason = "profile 'ohos-debug' builds for ohos-arm64; "
            .. "device runs stay in this process" }, reply)
    end)

    it("does not decline a build of that profile (only a run is a device run)", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        local asked = false
        with(run_prep, "kit_platform", function() asked = true; return "ohos-arm64" end)
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() error("stop here") end },
        }, service.Service)
        assert.has_error(function()
            svc:_accept({ op = "build", conn = { closed = false }, args = {}, reply = function() end })
        end)
        assert.is_false(asked)
    end)

    --- Run the runner's preparation (`--no-build`: no lock, straight to it)
    --- for a launch target `lt`; returns the task's `done` record.
    local function prepare(lt, args)
        with(run_prep, "select", function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return nil end)
        with(run_prep, "resolve_spec", function()
            return { name = "app", cmd = "/bin/app", args = {}, cwd = "/ws" }
        end)
        with(run_prep, "env_overrides", function() return {} end)
        local ws = { root = "/ws" }
        local done
        local task = {
            start = function() end, line = function() end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        runner.run({ ws = ws }, { op = "run", task = task, ws = ws, profile = profile, env = {},
            args = vim.tbl_extend("force", { no_build = true }, args) })
        return done
    end

    it("--prefix refuses a device target with the in-process message, before deploy", function()
        local deployed = false
        local lt = {
            requires_device = function() return true end,
            display_name = function() return "phone-app" end,
            deploy_sync = function() deployed = true; return true end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(1, done.code)
        assert.are.equal("--prefix cannot wrap a device target ('phone-app') — a local wrapper does not "
            .. "apply to on-device execution.", done.err)
        assert.is_false(deployed)
    end)

    it("--prefix with a local target prepares the launch", function()
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app" end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(0, done.code)
        assert.are.equal("/bin/app", done.fields.launch.cmd)
    end)
    -- ---- Launch/1.prepare_debug (§19.15 "Debug") ----------------------------

    it("never declines a debug of a profile whose kit builds for another platform", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        local asked = false
        with(run_prep, "kit_platform", function() asked = true; return "ohos-arm64" end)
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() error("stop here") end },
        }, service.Service)
        local reply
        assert.has_error(function()
            svc:_accept({ op = "debug", conn = { closed = false }, args = {}, reply = function(f) reply = f end })
        end)
        assert.is_false(asked)
        assert.is_nil(reply)
    end)

    it("refuses a debug request with run-only arguments or an unknown build scope as malformed", function()
        local svc = setmetatable({ server = {} }, service.Service)
        local env = { PATH = "/bin" }
        for _, args in ipairs({ { quiet = true }, { prefix = false }, { build_scope = "everything" } }) do
            local reply
            svc:_on_operation("debug", { closed = false }, { args = args, env = env }, function(f) reply = f end)
            assert.are.same({ outcome = "declined", reason = "malformed request" }, reply)
        end
        local reply
        svc:_on_operation("run", { closed = false }, { args = { build_scope = 7 }, env = env },
            function(f) reply = f end)
        assert.are.same({ outcome = "declined", reason = "malformed request" }, reply)
    end)

    --- A launch target stub of project `app` (module language c++).
    local function launch_target(fields)
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app: hello" end,
            _project = { key = "app", _module = { primary_language = function() return "c++" end } },
        }
        for k, v in pairs(fields or {}) do lt[k] = v end
        return lt
    end

    --- Run the runner (op `op`) with the resolution stubbed; returns the
    --- task's `done` record and the lines it printed.
    local function run_op(op, lt, args, opts)
        opts = opts or {}
        with(run_prep, "select", function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return opts.foreign end)
        with(run_prep, "resolve_spec", function()
            return { name = "app: hello", cmd = "/bin/app", args = { "--x" }, cwd = "/ws/app" }
        end)
        with(run_prep, "env_overrides", function() return { APP_MODE = "dev" } end)
        local ws = { root = "/ws" }
        local done, lines = nil, {}
        local task = {
            start = function() end, progress = function() end,
            line = function(_, _, text) lines[#lines + 1] = text end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        runner.run({ ws = ws }, { op = op, task = task, ws = ws, profile = profile, env = {}, args = args })
        return done, lines
    end

    it("ends a debug preparation with the run's resolved launch and the ordered adapters", function()
        local lt = launch_target({ _launch_config = { command = "/bin/app", debug = { "typescript", "c++" } } })
        local done = run_op("debug", lt, { no_build = true })
        assert.are.equal(0, done.code)
        assert.is_nil(done.fields.launch)
        assert.are.same({
            name = "app: hello", program = "/bin/app", args = { "--x" }, cwd = "/ws/app", env = { APP_MODE = "dev" },
            language = "typescript",
            adapters = { { language = "typescript", adapter = "pwa-node" }, { language = "c++", adapter = "codelldb" } },
        }, done.fields.result.debug)
    end)

    it("debugs a module target in its primary language with the workspace's adapter", function()
        local done = run_op("debug", launch_target(), { no_build = true })
        assert.are.equal(0, done.code)
        assert.are.equal("c++", done.fields.result.debug.language)
        assert.are.same({ { language = "c++", adapter = "codelldb" } }, done.fields.result.debug.adapters)
    end)

    it("refuses a device target nonzero before any deploy, never as a device run", function()
        local deployed = false
        local lt = launch_target({
            requires_device = function() return true end,
            deploy_sync = function() deployed = true; return true end,
        })
        local done = run_op("debug", lt, { no_build = true })
        assert.are.equal(1, done.code)
        assert.matches("device target; this host cannot debug it", done.err, 1, true)
        assert.is_nil(done.fields)
        assert.is_false(deployed)
    end)

    it("refuses a foreign artifact found by probing with the in-process refusal, before deploy", function()
        local foreign = require("loomworks.remote.foreign")
        with(foreign, "refusal", function(f) return "REFUSED " .. f.name end)
        local deployed = false
        with(build_run, "profile_build_dirs", function() return {} end)
        with(build_run, "plan", function() return {} end)
        local lt = launch_target({ deploy_sync = function() deployed = true; return true end })
        local done = run_op("debug", lt, {}, { foreign = { reason = "probe", name = "app" } })
        assert.are.equal(1, done.code)
        assert.are.equal("REFUSED app", done.err)
        assert.is_false(deployed)
    end)

    it("refuses a target its kit tells is foreign before the build", function()
        local foreign = require("loomworks.remote.foreign")
        with(foreign, "refusal", function(f) return "REFUSED " .. f.name end)
        with(build_run, "profile_build_dirs", function() error("no lock may be taken") end)
        local done = run_op("debug", launch_target(), {}, { foreign = { reason = "token", name = "app" } })
        assert.are.equal(1, done.code)
        assert.are.equal("REFUSED app", done.err)
    end)

    -- ---- build_scope = "target" (§19.15 "Build scope of a launch") ----------

    it("builds the dependencies, deploys around the launch's own unit, then prepares; not the profile", function()
        local overseer = require("loomworks.overseer")
        local calls = {}
        local lib_unit, app_unit = { name = "lib" }, { name = "app" }
        with(overseer, "plan_unit_build", function(_, unit, o)
            calls[#calls + 1] = "build " .. unit.name .. (o.target_id and (":" .. o.target_id) or "")
            return {}
        end)
        with(build_run, "plan", function() error("the profile is not planned") end)
        with(build_run, "profile_build_dirs", function() error("no profile lock") end)
        local lt = launch_target({
            _launch_config = { command = "/bin/app" }, _config_unit = app_unit,
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return lib_unit end,
            _deploy_phase = function(_, phase, cb) calls[#calls + 1] = "deploy " .. phase; cb(true) end,
            deploy_sync = function() error("deployed twice") end,
        })
        local done, lines = run_op("run", lt, { build_scope = "target", target = "hello" })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({ "build lib", "deploy pre_build", "build app", "deploy post_build" }, calls)
        assert.are.equal("/bin/app", done.fields.launch.cmd)
        assert.are.same({ "building launch target: app: hello", "building dependency: lib" }, lines)
    end)

    it("builds a module target's one target, and with no_build neither builds nor deploys", function()
        local overseer = require("loomworks.overseer")
        local calls = {}
        with(overseer, "plan_unit_build", function(_, unit, o)
            calls[#calls + 1] = unit.name .. ":" .. tostring(o.target_id)
            return {}
        end)
        local lt = launch_target({
            _target = { id = "hello", _config_unit = { name = "app" } },
            abstract_error = function() return nil end,
            build_dependencies = function() return {} end,
            _deploy_phase = function(_, _, cb) cb(true) end,
        })
        local done = run_op("debug", lt, { build_scope = "target" })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({ "app:hello" }, calls)
        calls = {}
        lt._deploy_phase = function() error("no deploy under no_build") end
        done = run_op("debug", lt, { build_scope = "target", no_build = true })
        assert.are.equal(0, done.code, done.err)
        assert.are.same({}, calls)
    end)

    it("ends at the first failing phase with the in-process message, the later phases not run", function()
        local overseer = require("loomworks.overseer")
        local planned = false
        with(overseer, "plan_unit_build", function() planned = true; return {} end)
        local lt = launch_target({
            _launch_config = { command = "/bin/app" }, _config_unit = { name = "app" },
            abstract_error = function() return nil end,
            build_dependencies = function() return { { project = { key = "lib" } } } end,
            _resolve_dep_config_unit = function() return nil end,
            _deploy_phase = function() error("no deploy after a failure") end,
        })
        local done = run_op("run", lt, { build_scope = "target" })
        assert.are.equal(1, done.code)
        assert.matches("cannot resolve a configuration to build for dependency 'lib'", done.err, 1, true)
        assert.is_false(planned)
    end)
end)
