-- Leftover programs (spec §18.7, §18.2 `reap`): a remote run records its
-- device program in the device lockfile; a run that reclaims a STALE device
-- lock naming a program asks the runner to reap it before staging, and
-- reports the outcome (stopped / gone / unknown). Without `reap` core only
-- warns. `lw unlock --device` only reports. The identity check (pid reuse) is
-- the runner's; core must hand it the recorded program and nonce.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local remote_run = require("loomworks.remote.run")
local runners = require("loomworks.remote.runners")
local device_lock = require("loomworks.remote.device_lock")
local build_lock = require("loomworks.build_lock")
local Target = require("loomworks.target")
local fx = require("tests.remote_fixtures")
local DROOT = select(2, require("loomworks.remote.manifest").device_roots("/data/stage", "ws", "build/App/Debug"))
local PROGRAM = DROOT .. "/test/unit/Runner"

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

--- Write a lockfile for `serial` as a dead run left it: `rec` merged over a
--- holder record, mtime pushed past the staleness window unless `live`.
local function plant_lock(serial, rec, live)
    local path = device_lock.path(serial)
    vim.fn.mkdir(device_lock.dir(), "p")
    local body = { pid = 999999, host = "elsewhere", action = "run", started_at = os.time() - 3600 }
    for k, v in pairs(rec or {}) do body[k] = v end
    local f = assert(io.open(path, "wb"))
    f:write(vim.json.encode(body))
    f:close()
    if not live then
        local old = os.time() - (build_lock.STALE_SECONDS + 60)
        vim.uv.fs_utime(path, old, old)
    end
end

describe("leftover programs of interrupted remote runs", function()
    local root, lockdir, saved_lock, dev, runner, sdk, unit, target, ws, profile, project

    local function lt()
        return {
            _target = target, _config_unit = unit, _project = project, _profile = profile,
            is_valid = function() return true end,
            requires_device = function() return false end,
            deploy_sync = function() return true end,
            display_name = function() return "Runner" end,
        }
    end

    local function run()
        local deps = { backend = dev:backend(), liveness_ms = 100000,
            write_out = function() end, write_err = function() end }
        return capture(function() return cli._run_launch_target(lt(), ws, {}, deps) end)
    end

    local function first_index(op)
        for i, c in ipairs(dev.calls) do if c.op == op then return i end end
        return nil
    end

    local function setup(runner_opts)
        runners._reset()
        root = fx.mkroot()
        lockdir = fx.mkroot()
        saved_lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
        fx.write_foreign_exe(root .. "/test/unit/Runner")
        dev = fx.device()
        runner = fx.fake_runner_table(runner_opts)
        sdk = fx.fake_sdk(runner)
        local targets = { Runner = { type = "executable", artifact = "test/unit/Runner" } }
        unit = fx.fake_unit({ build_dir = root, targets = targets, token = "fake-arm64", sdk = sdk,
            tool_key = "fake-kit" })
        target = Target.new(unit, "Runner", targets.Runner)
        project = { key = "App" }
        profile = { key = "Debug:fake-kit" }
        ws = { name = "ws", _device_sync = {}, _devices = {}, _save_cache = function() end }
        dev.behaviors.Runner = function() return { out = { "hello" } } end
    end

    before_each(function() setup() end)

    after_each(function()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_lock
        require("loomworks.io").rm_rf(root)
        require("loomworks.io").rm_rf(lockdir)
        runners._reset()
    end)

    it("a run records its device program in the lock while it runs, and the lock goes on release", function()
        local cancel, seen
        dev.behaviors.Runner = function()
            return { out = { "running" }, hang = true, after = function()
                vim.defer_fn(function() seen = device_lock.read("SER1"); cancel() end, 50)
            end }
        end
        local man = assert(require("loomworks.remote.manifest").build({ build_dir = root,
            artifact = root .. "/test/unit/Runner", unit = unit, target = target, runner = runner }))
        remote_run.execute({
            ws = ws, runner = runner, unit = unit, manifest = man, device = {}, args = {},
            backend = dev:backend(), liveness_ms = 100000,
            write_out = function() end, write_err = function() end, note = function() end,
            on_cleanup = function(fn) cancel = fn end,
        })
        assert.is_table(seen)
        assert.is_number(seen.device_pid)
        assert.equals(PROGRAM, seen.program)
        assert.truthy(type(seen.nonce) == "string" and seen.nonce:match("^%x+$"))
        assert.is_number(seen.program_started_at)
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("reclaiming a stale lock reaps the recorded program before staging: stopped", function()
        dev.procs[4242] = PROGRAM
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 3600 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(1, #dev.reaped)
        -- core hands the runner the recorded pid, nonce and staged program
        assert.same({ pid = 4242, nonce = "abc123", program = PROGRAM }, dev.reaped[1])
        assert.truthy(res.stderr:find(
            "stopped leftover Runner (pid 4242) from an interrupted run on SER1", 1, true), res.stderr)
        assert.truthy(first_index("reap") < first_index("push"), "reap must precede staging")
        assert.is_nil(dev.procs[4242])
    end)

    it("pid reuse: the id now belongs to another program — reported gone, never 'stopped'", function()
        dev.procs[4242] = "/system/bin/someone_else"
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(PROGRAM, dev.reaped[1].program)
        assert.equals("/system/bin/someone_else", dev.procs[4242]) -- untouched
        assert.falsy(res.stderr:find("stopped leftover", 1, true), res.stderr)
        assert.truthy(res.stderr:find("leftover Runner (pid 4242) from an interrupted run on SER1 had already exited",
            1, true), res.stderr)
    end)

    it("gone: a fresh record is reported, a record older than a day is dropped silently", function()
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 2 * 86400 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(1, #dev.reaped)
        assert.falsy(res.stderr:find("leftover", 1, true), res.stderr)
    end)

    it("an unknown outcome is a warning, never a run failure", function()
        dev.reap_output = "something odd"
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stderr:find("warning: could not tell whether leftover Runner (pid 4242)", 1, true),
            res.stderr)
    end)

    it("a failing reap (connector failure) is a warning, never a run failure", function()
        dev.reap_output = "[Fail]device went away"
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stderr:find("warning: could not stop leftover Runner (pid 4242)", 1, true), res.stderr)
    end)

    it("without a runner reap core only warns and never signals the pid", function()
        setup({ no_reap = true })
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(0, #dev.reaped)
        assert.equals(0, #dev.killed)
        assert.truthy(res.stderr:find(
            "warning: an interrupted run may have left Runner (pid 4242) running on SER1", 1, true), res.stderr)
    end)

    it("a stale lock without a program record reaps nothing; a live holder's record is never reaped", function()
        plant_lock("SER1", {})
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(0, #dev.reaped)
    end)

    it("an invalid record (non-numeric pid, non-absolute program) is ignored", function()
        plant_lock("SER1", { device_pid = "12; rm -rf /", nonce = "abc", program = PROGRAM })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(0, #dev.reaped)
        plant_lock("SER1", { device_pid = 7, nonce = "abc", program = "relative/prog" })
        res = run()
        assert.equals(0, #dev.reaped)
    end)

    it("lw unlock --device reports a recorded program and never reaps it", function()
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = capture(function() return cli.cmd_unlock(nil, { "unlock", "--device", "SER1" }) end)
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stdout:find("unlocked device SER1", 1, true), res.stdout)
        local all = res.stdout .. res.stderr
        assert.truthy(all:find("Runner (pid 4242)", 1, true), all)
        assert.truthy(all:find("not stopped", 1, true), all)
        assert.equals(0, #dev.reaped)
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("lw device clean reaps a leftover before removing the staging tree", function()
        dev.procs[4242] = PROGRAM
        plant_lock("SER1", { device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local cws = { name = "ws", _profiles = {}, _devices = {}, _device_sync = {},
            _save_cache = function() end, sdks = function() return { sdk } end }
        local res = capture(function() return cli._device_clean(cws, {}, { backend = dev:backend() }) end)
        assert.is_true(res.ok, res.stderr)
        assert.equals(1, #dev.reaped)
        assert.truthy(res.stderr:find("stopped leftover Runner (pid 4242)", 1, true), res.stderr)
        local reap_i, rm_i
        for i, c in ipairs(dev.calls) do
            if c.op == "reap" and not reap_i then reap_i = i end
            if c.op == "exec" and c.req and c.req.argv[1] == "rm" and not rm_i then rm_i = i end
        end
        assert.is_not_nil(rm_i)
        assert.truthy(reap_i < rm_i, "reap must precede the removal")
    end)

    -- Leftover record file (§18.7): a run that ends with its cleanup but
    -- without stopping its program (transport failure / lost status / a stop
    -- that did not complete) keeps the program in <lock dir>/<serial>.leftover.
    local function leftover_file() return device_lock.dir() .. "/SER1.leftover" end
    local function read_leftover()
        local f = io.open(leftover_file(), "rb")
        if not f then return nil end
        local s = f:read("*a"); f:close()
        return vim.json.decode(s)
    end
    local function plant_leftover(rec)
        vim.fn.mkdir(device_lock.dir(), "p")
        local f = assert(io.open(leftover_file(), "wb"))
        f:write(type(rec) == "string" and rec or vim.json.encode(rec))
        f:close()
    end

    it("a lost exit status runs terminate once; a completed stop leaves no leftover file", function()
        dev.behaviors.Runner = function() return { out = { "partial" }, no_sentinel = true } end
        local res = run()
        assert.equals(remote_run.EXIT_TRANSPORT, res.ret)
        assert.truthy(res.stderr:find("no exit status was recovered", 1, true), res.stderr)
        assert.equals(1, #dev.killed)
        -- the outcome of the stop is visible (beta.3 phone: it was silent)
        assert.truthy(res.stderr:find("the connection to SER1 was lost; stopped Runner (pid ", 1, true), res.stderr)
        assert.is_nil(read_leftover())
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("a lost exit status whose stop fails keeps the program in the leftover file; the lock is released", function()
        dev.kill_fails = true
        dev.behaviors.Runner = function() return { out = { "partial" }, no_sentinel = true } end
        local res = run()
        assert.equals(remote_run.EXIT_TRANSPORT, res.ret)
        assert.equals(1, #dev.killed)
        local rec = read_leftover()
        assert.is_table(rec, "leftover file written")
        assert.is_number(rec.device_pid)
        assert.equals(PROGRAM, rec.program)
        assert.truthy(type(rec.nonce) == "string" and rec.nonce:match("^%x+$"))
        assert.is_number(rec.program_started_at)
        assert.is_nil(device_lock.read("SER1"))
    end)

    it("an interrupt whose stop is unavailable keeps the program in the leftover file", function()
        setup({ no_reap = false })
        runner.terminate = nil
        local cancel
        dev.behaviors.Runner = function()
            return { out = { "running" }, hang = true, after = function()
                vim.schedule(function() cancel() end)
            end }
        end
        local man = assert(require("loomworks.remote.manifest").build({ build_dir = root,
            artifact = root .. "/test/unit/Runner", unit = unit, target = target, runner = runner }))
        remote_run.execute({
            ws = ws, runner = runner, unit = unit, manifest = man, device = {}, args = {},
            backend = dev:backend(), liveness_ms = 100000,
            write_out = function() end, write_err = function() end, note = function() end,
            on_cleanup = function(fn) cancel = fn end,
        })
        local rec = read_leftover()
        assert.is_table(rec)
        assert.equals(PROGRAM, rec.program)
    end)

    it("a normal run writes no leftover file", function()
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.is_nil(read_leftover())
    end)

    it("the next acquisition reaps the leftover file's program before staging and removes the file", function()
        dev.procs[4242] = PROGRAM
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.same({ pid = 4242, nonce = "abc123", program = PROGRAM }, dev.reaped[1])
        assert.truthy(res.stderr:find("stopped leftover Runner (pid 4242) from an interrupted run on SER1", 1, true),
            res.stderr)
        assert.truthy(first_index("reap") < first_index("push"))
        assert.is_nil(read_leftover())
    end)

    it("gone removes the leftover file", function()
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stderr:find("had already exited", 1, true), res.stderr)
        assert.is_nil(read_leftover())
    end)

    it("unknown keeps a fresh leftover file for the next acquisition, drops one older than a day", function()
        dev.reap_output = "something odd"
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stderr:find("warning: could not tell whether leftover", 1, true), res.stderr)
        assert.is_table(read_leftover())
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 2 * 86400 })
        run()
        assert.is_nil(read_leftover())
    end)

    it("without a runner reap: warn once and remove the leftover file", function()
        setup({ no_reap = true })
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.truthy(res.stderr:find("warning: an interrupted run may have left Runner (pid 4242)", 1, true),
            res.stderr)
        assert.equals(0, #dev.killed)
        assert.is_nil(read_leftover())
    end)

    it("an invalid leftover file is removed without reaping; nothing else in the lock dir is touched", function()
        plant_leftover("not json {")
        local other = device_lock.dir() .. "/SER1.leftover.keep"
        local f = assert(io.open(other, "wb")); f:write("x"); f:close()
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(0, #dev.reaped)
        assert.is_nil(read_leftover())
        assert.is_not_nil(vim.uv.fs_stat(other))
        plant_leftover({ device_pid = "1; reboot", nonce = "abc", program = PROGRAM })
        run()
        assert.equals(0, #dev.reaped)
        assert.is_nil(read_leftover())
    end)

    it("a reclaimed lock record and a leftover file for the same run are reaped once", function()
        dev.procs[4242] = PROGRAM
        local rec = { device_pid = 4242, nonce = "abc123", program = PROGRAM, program_started_at = os.time() - 60 }
        plant_lock("SER1", rec)
        plant_leftover(rec)
        local res = run()
        assert.equals(0, res.ret, res.stderr)
        assert.equals(1, #dev.reaped)
        assert.is_nil(read_leftover())
    end)

    it("lw unlock --device reports a leftover file's program and leaves the file", function()
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local res = capture(function() return cli.cmd_unlock(nil, { "unlock", "--device", "SER1" }) end)
        assert.equals(0, res.ret, res.stderr)
        local all = res.stdout .. res.stderr
        assert.truthy(all:find("Runner (pid 4242)", 1, true), all)
        assert.truthy(all:find("not stopped", 1, true), all)
        assert.is_table(read_leftover())
        assert.equals(0, #dev.reaped)
    end)

    it("lw device clean reaps the leftover file's program and removes the file", function()
        dev.procs[4242] = PROGRAM
        plant_leftover({ device_pid = 4242, nonce = "abc123", program = PROGRAM,
            program_started_at = os.time() - 60 })
        local cws = { name = "ws", _profiles = {}, _devices = {}, _device_sync = {},
            _save_cache = function() end, sdks = function() return { sdk } end }
        local res = capture(function() return cli._device_clean(cws, {}, { backend = dev:backend() }) end)
        assert.is_true(res.ok, res.stderr)
        assert.equals(1, #dev.reaped)
        assert.truthy(res.stderr:find("stopped leftover Runner (pid 4242)", 1, true), res.stderr)
        assert.is_nil(read_leftover())
    end)
end)

describe("build_lock record + reclaim info", function()
    local dir
    before_each(function() dir = fx.mkroot() end)
    after_each(function() require("loomworks.io").rm_rf(dir) end)

    it("try_acquire_path exposes the reclaimed stale record on the handle", function()
        local path = dir .. "/x.lock"
        local f = assert(io.open(path, "wb")); f:write(vim.json.encode({ pid = 1, marker = "old" })); f:close()
        local old = os.time() - (build_lock.STALE_SECONDS + 60)
        vim.uv.fs_utime(path, old, old)
        local h = assert(build_lock.try_acquire_path(path, "run", { serial = "S" }))
        assert.is_table(h.reclaimed)
        assert.equals("old", h.reclaimed.marker)
        build_lock.release(h)
        local h2 = assert(build_lock.try_acquire_path(path, "run"))
        assert.is_nil(h2.reclaimed)
        build_lock.release(h2)
    end)

    it("update_record merges fields into the held lockfile and can clear them", function()
        local path = dir .. "/y.lock"
        local h = assert(build_lock.try_acquire_path(path, "run", { serial = "S" }))
        build_lock.update_record(h, { device_pid = 7, program = "/p" })
        local info = build_lock.read_path(path)
        assert.equals(7, info.device_pid)
        assert.equals("S", info.serial)
        assert.equals("run", info.action)
        build_lock.update_record(h, { device_pid = vim.NIL, program = vim.NIL })
        info = build_lock.read_path(path)
        assert.is_nil(info.device_pid)
        assert.equals("S", info.serial)
        build_lock.release(h)
        -- a released handle never rewrites a lockfile someone else may own now
        build_lock.update_record(h, { device_pid = 9 })
        assert.is_nil(build_lock.read_path(path))
    end)
end)
