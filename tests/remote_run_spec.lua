-- Remote run of a foreign build target (spec §18.5, §18.8, §18.13, §16.17):
-- `lw run` routes a foreign artifact to the fake runner's in-memory device —
-- lock → log session → stage → exec with the nonce sentinel → collect — and
-- maps the outcome to the invocation's exit status (program status, signal,
-- lost status = transport failure, timeout, crash). Also: log option
-- pass-through + validation, liveness, cancellation paths, --print, --prefix,
-- refusal without a runner, and run-folder retention.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local remote_run = require("loomworks.remote.run")
local runners = require("loomworks.remote.runners")
local Target = require("loomworks.target")
local fx = require("tests.remote_fixtures")
-- The device staging root of the fixture unit (spec §18.4).
local DROOT = select(2, require("loomworks.remote.manifest").device_roots("/data/stage", "ws", "build/App/Debug"))

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return { ok = ok, ret = ret, exit_code = exit_code,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function read(p) return fx.read(p) end

describe("lw run on a foreign target", function()
    local root, lockdir, saved_lock, dev, runner, sdk, unit, target, ws, profile, project
    local prog_out, prog_err

    local function lt(launch_cfg)
        return {
            _target = target, _config_unit = unit, _project = project, _profile = profile,
            _launch_config = launch_cfg, _config_target = launch_cfg and target or nil,
            is_valid = function() return true end,
            requires_device = function() return false end,
            deploy_sync = function() return true end,
            display_name = function() return "Runner" end,
        }
    end

    local function run(opts, launch_cfg, extra_deps)
        opts = opts or {}
        local deps = { backend = dev:backend(), liveness_ms = 40,
            write_out = function(s) prog_out[#prog_out + 1] = s end,
            write_err = function(s) prog_err[#prog_err + 1] = s end }
        for k, v in pairs(extra_deps or {}) do deps[k] = v end
        return capture(function() return cli._run_launch_target(lt(launch_cfg), ws, opts, deps) end)
    end

    local function exec_calls()
        local out = {}
        for _, c in ipairs(dev.calls) do
            if c.op == "exec" and c.req.argv[1]:match("/Runner$") then out[#out + 1] = c end
        end
        return out
    end

    local function run_dirs()
        local out = {}
        local h = vim.uv.fs_scandir(root .. "/.device-runs")
        while h do
            local n = vim.uv.fs_scandir_next(h)
            if not n then break end
            if n:match("^%d+T%d+Z%-") then out[#out + 1] = root .. "/.device-runs/" .. n end
        end
        table.sort(out)
        return out
    end

    before_each(function()
        runners._reset()
        root = fx.mkroot()
        lockdir = fx.mkroot()
        saved_lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
        fx.write_foreign_exe(root .. "/test/unit/Runner")
        fx.write(root .. "/lib/libcore.so", "core")
        fx.write(root .. "/test/assets/a.txt", "asset")
        dev = fx.device()
        runner = fx.fake_runner_table()
        sdk = fx.fake_sdk(runner)
        local targets = {
            Runner = { type = "executable", artifact = "test/unit/Runner", dependencies = { "core" } },
            core = { type = "shared_library", artifact = "lib/libcore.so" },
        }
        unit = fx.fake_unit({ build_dir = root, targets = targets, token = "fake-arm64", sdk = sdk,
            tool_key = "fake-kit" })
        target = Target.new(unit, "Runner", targets.Runner)
        project = { key = "App", device = { archive = { "test/assets/**" }, env = { APP_MODE = "test" } } }
        profile = { key = "Debug:fake-kit", _device_serial = nil }
        ws = { name = "ws", _device_sync = {}, _devices = {}, _save_cache = function() end }
        prog_out, prog_err = {}, {}
        dev.behaviors.Runner = function() return { out = { "hello", "[  PASSED  ] 1 test" }, err = { "warn line" } } end
        dev.log_lines = { "I app started", "noise dropped", "E app boom" }
    end)

    after_each(function()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_lock
        require("loomworks.io").rm_rf(root)
        require("loomworks.io").rm_rf(lockdir)
        runners._reset()
    end)

    it("stages, runs with forwarded args verbatim, streams output, exit status = program's", function()
        local res = run({ extra_args = { "--gtest_filter=A.*", "a b; $(x)" } })
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)
        assert.same({ "hello", "[  PASSED  ] 1 test" }, prog_out)
        assert.same({ "warn line" }, prog_err)
        local calls = exec_calls()
        assert.equals(1, #calls)
        local req = calls[1].req
        local droot = DROOT
        assert.same({ droot .. "/test/unit/Runner", "--gtest_filter=A.*", "a b; $(x)" }, req.argv)
        assert.equals(droot .. "/test/unit", req.cwd)
        assert.same({ droot .. "/lib" }, req.library_dirs)
        assert.same({ APP_MODE = "test" }, req.env)
        assert.truthy(req.nonce:match("^%x+$"))
        assert.truthy(res.stderr:find("staging on SER1", 1, true))
        -- output.log: program output, unfiltered, no connector lines
        local dirs = run_dirs()
        assert.equals(1, #dirs)
        local log = read(dirs[1] .. "/output.log")
        assert.truthy(log:find("hello\n", 1, true))
        assert.truthy(log:find("warn line", 1, true))
        assert.falsy(log:find("__EXIT_", 1, true))
        assert.falsy(log:find("__PID_", 1, true))
        -- device.log: the runner's kept lines (receive filter applied)
        local dlog = read(dirs[1] .. "/device.log")
        assert.truthy(dlog:find("I app started", 1, true))
        assert.falsy(dlog:find("noise", 1, true))
        -- the log stream was started with the program's pid, after a clear
        local streams = dev:ops("logstream")
        assert.equals(1, #streams)
        assert.truthy(streams[1].pid:match("^%d+$"))
        assert.equals(1, dev.log_cleared)
        -- the staged tree mirrors the build layout
        assert.equals("asset", dev.boards.SER1.files[droot .. "/test/assets/a.txt"].data)
        -- the sync record lives in the workspace (build cache)
        assert.is_table(ws._device_sync.SER1[droot])
    end)

    it("a non-zero status is the exit code; the device log tail is printed on failure", function()
        dev.behaviors.Runner = function() return { out = { "FAILED" }, exit = 3 } end
        local res = run()
        assert.equals(3, res.ret)
        assert.truthy(res.stderr:find("exited with status 3", 1, true))
        assert.truthy(res.stderr:find("run folder:", 1, true))
        local all = table.concat(prog_err, "\n")
        -- show = stdout by default in the fake runner: log on_failure, tail 2
        assert.truthy(res.stderr:find("device log (last 2 lines)", 1, true))
        assert.truthy(res.stderr:find("LOG E app boom", 1, true))
        assert.falsy(all:find("LOG", 1, true))
    end)

    it("unterminated last output sharing the sentinel line is program output", function()
        dev.behaviors.Runner = function()
            return { out = { "first" }, unterminated = "no newline at end", exit = 4 }
        end
        local res = run()
        assert.equals(4, res.ret)
        assert.same({ "first", "no newline at end" }, prog_out)
        local log = read(run_dirs()[1] .. "/output.log")
        assert.truthy(log:find("first\nno newline at end\n", 1, true))
        assert.falsy(log:find("__EXIT_", 1, true))
    end)

    it("a status above 128 is reported as a signal", function()
        dev.behaviors.Runner = function() return { out = { "Segmentation fault" }, exit = 139 } end
        local res = run()
        assert.equals(139, res.ret)
        assert.truthy(res.stderr:find("terminated by signal 11", 1, true))
    end)

    it("a transport that loses the sentinel is a transport failure, never exit 0/127", function()
        dev.behaviors.Runner = function() return { out = { "partial" }, no_sentinel = true } end
        local res = run()
        assert.equals(remote_run.EXIT_TRANSPORT, res.ret)
        assert.truthy(res.stderr:find("no exit status was recovered", 1, true))
    end)

    it("a connector failure printed after the sentinel (exit 0) is a transport failure", function()
        dev.behaviors.Runner = function() return { connector_tail = { "[Fail]device lost" } } end
        local res = run()
        assert.equals(remote_run.EXIT_TRANSPORT, res.ret)
        assert.truthy(res.stderr:find("[Fail]device lost", 1, true))
    end)

    it("collects new crash reports; a crash fails the run even with status 0", function()
        dev.boards.SER1.crashes["cppcrash-old"] = true
        dev.behaviors.Runner = function(ctx)
            ctx.board.crashes["cppcrash-new"] = true
            ctx.board.files["/crash/cppcrash-new"] = { data = "backtrace" }
            return { out = { "ok" } }
        end
        local res = run()
        assert.equals(1, res.ret)
        assert.truthy(res.stderr:find("crash report: ", 1, true))
        assert.truthy(res.stderr:find("fails because the device recorded a crash", 1, true))
        local dirs = run_dirs()
        assert.equals("backtrace", read(dirs[1] .. "/crash/cppcrash-new"))
        assert.is_nil(read(dirs[1] .. "/crash/cppcrash-old"))
        -- crash_collect learns the program's pid (spec §18.2 `ctx`).
        assert.is_table(runner.crash_ctx_seen)
        assert.is_number(runner.crash_ctx_seen.pid)
        assert.equals(tostring(runner.crash_ctx_seen.pid),
            res.stderr:match("running Runner on SER1 %(pid (%d+)%)"))
    end)

    it("log options: device_log + --log merge (CLI wins per key) and reach the runner opaquely", function()
        local res = run({ log_options = { show = "both" } },
            { target = "Runner", device_log = { show = "stdout", level = "E" } })
        assert.is_true(res.ok, res.stderr)
        assert.same({ show = "both", level = "E" }, runner.log_options_seen)
        assert.same({ path = DROOT .. "/test/unit/Runner", name = "Runner" },
            runner.log_program_seen)
        -- show=both → log displayed live (display filter applied: level E only)
        local all = table.concat(prog_err, "\n")
        assert.truthy(all:find("LOG E app boom", 1, true))
        assert.falsy(all:find("LOG I app", 1, true))
        -- the saved device.log keeps every kept line regardless of display
        assert.truthy(read(run_dirs()[1] .. "/device.log"):find("I app started", 1, true))
    end)

    it("an invalid log option fails the run before any device-side effect", function()
        local res = run({ log_options = { bogus = "1" } })
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.truthy(res.stderr:find("unknown option 'bogus'", 1, true))
        assert.equals(0, #dev:ops("push"))
        assert.equals(0, #dev:ops("exec"))
    end)

    it("show = log hides program output from the terminal but saves it", function()
        local res = run({ log_options = { show = "log" } })
        assert.equals(0, res.ret)
        assert.same({}, prog_out)
        assert.truthy(read(run_dirs()[1] .. "/output.log"):find("hello", 1, true))
    end)

    it("a log stream that cannot start is a warning, never a failure", function()
        dev.log_fails = true
        local res = run()
        assert.equals(0, res.ret)
        assert.truthy(res.stderr:find("warning: device log", 1, true))
    end)

    it("liveness: a device missing from two listings ends the run as a transport failure", function()
        dev.behaviors.Runner = function(ctx)
            return { out = { "working" }, hang = true, after = function(d) d.boards.SER1.hidden = true end }
        end
        local res = run()
        assert.equals(remote_run.EXIT_TRANSPORT, res.ret)
        assert.truthy(res.stderr:find("disappeared during the run", 1, true))
        assert.equals(1, #dev.killed) -- terminate ran for the device-side program
    end)

    it("--timeout stops the program (terminate) and exits 124", function()
        dev.behaviors.Runner = function() return { out = { "slow" }, hang = true } end
        local res = run({ timeout = 0.3 })
        assert.equals(remote_run.EXIT_TIMEOUT, res.ret)
        assert.truthy(res.stderr:find("execution timeout", 1, true))
        assert.equals(1, #dev.killed)
    end)

    it("cancellation kills the connector, terminates the device program, stops the log, frees the lock", function()
        local cancel
        local notes = {}
        dev.behaviors.Runner = function()
            return { out = { "running" }, hang = true, after = function()
                vim.schedule(function() cancel() end)
            end }
        end
        local man = assert(require("loomworks.remote.manifest").build({ build_dir = root,
            artifact = root .. "/test/unit/Runner", unit = unit, target = target, runner = runner }))
        local result = remote_run.execute({
            ws = ws, runner = runner, unit = unit, manifest = man, device = {}, args = {},
            backend = dev:backend(), liveness_ms = 100000,
            write_out = function() end, write_err = function() end,
            note = function(s) notes[#notes + 1] = s end,
            on_cleanup = function(fn) cancel = fn end,
        })
        assert.is_table(result)
        assert.equals(remote_run.EXIT_TRANSPORT, result.exit_code)
        assert.truthy(result.transport_error:find("cancelled", 1, true))
        assert.equals(1, #dev.killed)
        assert.is_nil(require("loomworks.remote.device_lock").read("SER1"))
        -- The interrupt is reported, with the run folder (output.log written).
        local all = table.concat(notes, "\n")
        assert.truthy(all:find("running Runner on SER1 (pid ", 1, true), all)
        assert.truthy(all:find("interrupted — stopped Runner on SER1", 1, true), all)
        local folder = all:match("run folder: ([^\n]+)")
        assert.is_not_nil(folder, all)
        assert.equals(result.run_dir, folder)
        assert.truthy((read(folder .. "/output.log") or ""):find("running", 1, true))
    end)

    it("an interrupt without a runner terminate says the device program may still run", function()
        local cancel
        runner.terminate = nil
        dev.behaviors.Runner = function()
            return { out = { "running" }, hang = true, after = function()
                vim.schedule(function() cancel() end)
            end }
        end
        local notes = {}
        local man = assert(require("loomworks.remote.manifest").build({ build_dir = root,
            artifact = root .. "/test/unit/Runner", unit = unit, target = target, runner = runner }))
        remote_run.execute({
            ws = ws, runner = runner, unit = unit, manifest = man, device = {}, args = {},
            backend = dev:backend(), liveness_ms = 100000,
            write_out = function() end, write_err = function() end,
            note = function(s) notes[#notes + 1] = s end,
            on_cleanup = function(fn) cancel = fn end,
        })
        local all = table.concat(notes, "\n")
        assert.truthy(all:find("interrupted", 1, true), all)
        assert.truthy(all:find("may not have completed", 1, true), all)
    end)

    it("parses run/test device options", function()
        local o = cli._new_device_opts()
        local argv = { "--device", "S", "--fresh", "--timeout", "30", "--query-timeout", "5",
            "--transfer-timeout", "9", "--log", "show=both", "--log", "level=D", "--no-wait" }
        local i = 1
        while argv[i] do
            assert.is_true(cli._parse_device_opt(argv, i, o))
            i = o._next
        end
        assert.equals("S", o.device)
        assert.is_true(o.fresh)
        assert.equals(30, o.timeout)
        assert.same({ query = 5, transfer = 9 }, o.timeouts)
        assert.same({ show = "both", level = "D" }, o.log_options)
        assert.is_true(o.no_wait)
        assert.is_false(cli._parse_device_opt({ "--other" }, 1, o))
        local res = capture(function() cli._parse_device_opt({ "--timeout", "x" }, 1, o) end)
        assert.truthy(res.stderr:find("positive number", 1, true))
        res = capture(function() cli._parse_device_opt({ "--log", "novalue" }, 1, o) end)
        assert.truthy(res.stderr:find("key=value", 1, true))
    end)

    it("combined_output runners deliver one stream (stderr merged into output)", function()
        runner.combined_output = true
        dev.combined = true
        local res = run()
        assert.equals(0, res.ret)
        assert.same({ "hello", "[  PASSED  ] 1 test", "warn line" }, prog_out)
        assert.same({}, prog_err)
    end)

    it("--device selects; an unknown serial is an error naming it", function()
        dev:add("SER2", "Two")
        local res = run({ device = "SER2" })
        assert.equals(0, res.ret)
        assert.equals("SER2", exec_calls()[1].serial)
        res = run({ device = "NOPE" })
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("device 'NOPE' is not attached", 1, true))
        -- two online, nothing selected → error listing them
        res = run()
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("2 devices online (SER1, SER2)", 1, true))
        -- the profile's persisted serial wins over "sole"
        profile._device_serial = "SER2"
        res = run()
        assert.equals(0, res.ret)
    end)

    it("--no-wait fails fast when another process holds the device", function()
        local dl = require("loomworks.remote.device_lock")
        local h = assert(dl.acquire("SER1", { action = "test" }))
        local res = run({ no_wait = true })
        dl.release(h)
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("device SER1 is in use", 1, true))
        assert.equals(0, #dev:ops("push"))
    end)

    it("--prefix and --cwd are errors on a foreign target", function()
        local res = run({ prefix_tokens = { "valgrind" } })
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("--prefix cannot wrap 'Runner'", 1, true))
        res = run({ cwd_override = "x" })
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("--cwd does not apply", 1, true))
    end)

    it("--print reports the device-side invocation + manifest without staging or executing", function()
        local res = run({ print_mode = "json", extra_args = { "x y" } })
        assert.is_true(res.ok, res.stderr)
        local rep = vim.json.decode(res.stdout)
        assert.equals("SER1", rep.device)
        assert.equals(DROOT .. "/test/unit/Runner", rep.program)
        assert.same({ "x y" }, rep.args)
        assert.same({ DROOT .. "/lib" }, rep.library_dirs)
        assert.equals("test", rep.env.APP_MODE)
        assert.equals(2, #rep.manifest.files)
        assert.equals(1, #rep.manifest.archives)
        assert.equals(0, #dev:ops("push"))
        assert.equals(0, #dev:ops("exec"))
        res = run({ print_mode = "sh" })
        assert.truthy(res.stdout:find("program:      " .. DROOT .. "/test/unit/Runner", 1, true))
    end)

    it("refuses (never runs locally) when no runner serves the kit's platform", function()
        unit = fx.fake_unit({ build_dir = root, targets = unit.targets, token = "other-plat", sdk = sdk,
            tool_key = "fake-kit" })
        target = Target.new(unit, "Runner", unit.targets.Runner)
        local res = run()
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("Runner was built for other-plat by kit fake-kit", 1, true))
        assert.truthy(res.stderr:find("No device runner serves that platform", 1, true))
    end)

    it("a probe-only mismatch (no kit token) is refused, never guessed onto a device", function()
        unit = fx.fake_unit({ build_dir = root, targets = unit.targets, sdk = sdk })
        target = Target.new(unit, "Runner", unit.targets.Runner)
        local res = run()
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("cannot be routed to a device", 1, true))
        assert.equals(0, #dev.calls)
    end)

    it("device options on a host-runnable target are an error", function()
        fx.write_host_exe(root .. "/test/unit/Runner")
        unit = fx.fake_unit({ build_dir = root, targets = unit.targets })
        target = Target.new(unit, "Runner", unit.targets.Runner)
        local res = run({ device = "SER1" })
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("--device applies only", 1, true))
    end)
end)

describe("run folders", function()
    it("keeps the 10 newest per build dir; never touches other entries", function()
        local root = fx.mkroot()
        for i = 1, 12 do
            fx.write(string.format("%s/.device-runs/202601%02dT000000Z-SER/output.log", root, i), "x")
        end
        fx.write(root .. "/.device-runs/keepme/file", "k")
        fx.write(root .. "/.device-runs/.tmp/x", "k")
        local removed = remote_run.prune_runs(root, 10)
        assert.equals(2, #removed)
        assert.is_nil(vim.uv.fs_stat(root .. "/.device-runs/20260101T000000Z-SER"))
        assert.is_nil(vim.uv.fs_stat(root .. "/.device-runs/20260102T000000Z-SER"))
        assert.is_not_nil(vim.uv.fs_stat(root .. "/.device-runs/20260103T000000Z-SER"))
        assert.is_not_nil(vim.uv.fs_stat(root .. "/.device-runs/keepme/file"))
        assert.is_not_nil(vim.uv.fs_stat(root .. "/.device-runs/.tmp/x"))
        assert.same({}, remote_run.prune_runs(nil))
        assert.same({}, remote_run.prune_runs(""))
        require("loomworks.io").rm_rf(root)
    end)

    it("a symlinked .device-runs pointing elsewhere is never pruned through", function()
        local root, other = fx.mkroot(), fx.mkroot()
        for i = 1, 12 do fx.write(string.format("%s/202601%02dT000000Z-SER/f", other, i), "x") end
        local ok = pcall(vim.uv.fs_symlink, other, root .. "/.device-runs", { dir = true, junction = true })
        if ok and vim.uv.fs_lstat(root .. "/.device-runs") then
            assert.same({}, remote_run.prune_runs(root, 10))
            assert.is_not_nil(vim.uv.fs_stat(other .. "/20260101T000000Z-SER/f"))
        end
        require("loomworks.io").rm_rf(root)
        require("loomworks.io").rm_rf(other)
    end)

    it("parse_log_arg splits on the first '='", function()
        assert.same({ "grep", "a=b" }, { remote_run.parse_log_arg("grep=a=b") })
        assert.is_nil((remote_run.parse_log_arg("novalue")))
    end)
end)
