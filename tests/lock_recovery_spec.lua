-- Recovery from dead and hung lock holders (spec §19.5), against REAL helper
-- processes (tests/fixtures/lock_holder.lua): a holder killed outright, a
-- suspended (hung) holder, a reused process id, a holder on another host, an
-- editor-held lock, `--break-locks` and `lw unlock --force`, and the state
-- recovery of a build directory whose configure or build step was killed.
--
-- Process control is portable: kill = proc.kill_tree (TerminateProcess /
-- SIGKILL); suspend = proc._suspend (NtSuspendProcess / SIGSTOP).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local bl = require("loomworks.build_lock")
local lock_record = require("loomworks.lock_record")
local lock_break = require("loomworks.lock_break")
local proc = require("loomworks.proc")
local uv = vim.uv or vim.loop

local REPO = (uv.cwd():gsub("\\", "/"))
local HELPER = REPO .. "/tests/fixtures/lock_holder.lua"

local spawned = {}

--- Start a helper holding `lockfile`; returns { pid, start, child }.
local function hold(lockfile, op, kind, with_child)
    local out = uv.new_pipe(false)
    local buf = ""
    local handle, pid = uv.spawn(vim.v.progpath, {
        args = { "--headless", "--clean", "-l", HELPER, REPO, lockfile, op or "build",
            kind or "lw", with_child and "1" or "0", "60000" },
        stdio = { nil, out, nil },
        env = { "LW_TEST_HEARTBEAT_MS=300" },
    }, function() end)
    assert(handle, "could not spawn the helper: " .. tostring(pid))
    out:read_start(function(_, data) if data then buf = buf .. data end end)
    assert(vim.wait(20000, function() return buf:find("\n") ~= nil end, 20),
        "helper never reported: " .. buf)
    local child = tonumber(buf:match("LOCKED (%d+)"))
    assert(child, "helper did not lock: " .. buf)
    local h = { pid = pid, start = proc.start_time(pid), child = child ~= 0 and child or nil }
    if h.child then h.child_start = proc.start_time(h.child) end
    spawned[#spawned + 1] = h
    pcall(function() out:read_stop(); out:close() end)
    return h
end

local function cleanup()
    for _, h in ipairs(spawned) do
        pcall(proc._resume, h.pid)
        if type(h.start) == "string" and proc.alive(h.pid, h.start) then
            proc.kill_tree(h.pid, h.start)
        end
        if h.child and type(h.child_start) == "string" and proc.alive(h.child, h.child_start) then
            proc.kill_tree(h.child, h.child_start)
        end
    end
    spawned = {}
end

local function age(path, secs)
    local t = os.time() - secs
    uv.fs_utime(path, t, t)
end

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, err = pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
    if not ok and not (type(err) == "table" and err.__exit) then error(err) end
    return { exit_code = exit_code, stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function tmpdir()
    local d = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(d, "p")
    return d
end

describe("proc", function()
    after_each(cleanup)

    it("reports this process's start time and a missing process as gone", function()
        assert.is_string(proc.self_start_time())
        assert.equals(false, proc.start_time(4194300))
        assert.equals(false, proc.start_time(-1))
    end)

    it("kills a holder and its child process tree; verifies they are gone", function()
        local h = hold(tmpdir() .. "/x.lock", "build", "lw", true)
        assert.is_string(h.start)
        assert.is_number(h.child)
        assert.is_true(proc.alive(h.pid, h.start))
        local gone, err = proc.kill_tree(h.pid, h.start)
        assert.is_true(gone, err)
        assert.equals(false, proc.alive(h.pid, h.start))
        assert.is_true(vim.wait(5000, function() return proc.alive(h.child, h.child_start) == false end, 50),
            "the holder's child survived")
    end)

    it("never signals a process whose start time differs (reused id)", function()
        local h = hold(tmpdir() .. "/x.lock")
        local method = proc.method_of(h.start)
        local gone = proc.kill_tree(h.pid, method .. ":0")
        assert.is_true(gone) -- "the holder" (that start time) is gone…
        assert.is_true(proc.alive(h.pid, h.start)) -- …and the unrelated process lives
    end)
end)

describe("lock holder classification (§19.5)", function()
    local dir
    before_each(function() dir = tmpdir() .. "/build/variant" end)
    after_each(function()
        cleanup()
        lock_break.requested = nil
    end)

    it("a killed holder is dead and reclaimed at once, without waiting for the heartbeat", function()
        local path = bl.lock_path(dir)
        local h = hold(path, "configure")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local info = assert(bl.read(dir))
        assert.is_false(info.stale) -- heartbeat still fresh
        assert.equals("dead", lock_record.classify(info))
        local mine = assert(bl.acquire(dir, "build"))
        assert.is_table(mine.reclaimed)
        assert.equals("dead", mine.reclaimed.state)
        assert.equals("configure", lock_record.operation_of(mine.reclaimed))
        bl.release(mine)
    end)

    it("a record whose pid now belongs to another process is dead; that process is never signalled", function()
        local other = hold(tmpdir() .. "/other.lock")
        local path = bl.lock_path(dir)
        vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = other.pid, host = lock_record.this_host(),
            start_time = proc.method_of(other.start) .. ":1", lock_nonce = "abc", kind = "lw",
            operation = "build", started_at = os.time() }))
        f:close()
        lock_break.requested = "now"
        local mine = assert(bl.acquire(dir, "build"))
        assert.equals("dead", mine.reclaimed.state)
        bl.release(mine)
        assert.is_true(proc.alive(other.pid, other.start), "an unrelated process was signalled")
    end)

    it("a suspended holder is hung: refused with the recovery command, never reclaimed", function()
        local path = bl.lock_path(dir)
        local h = hold(path, "build")
        assert.is_true(proc._suspend(h.pid))
        age(path, bl.STALE_SECONDS + 30)
        local mine, reason, info = bl.acquire(dir, "build", { what = "build/variant", command = "lw build" })
        assert.is_nil(mine)
        assert.equals("hung", info.state)
        assert.is_truthy(reason:find("hung", 1, true), reason)
        assert.is_truthy(reason:find("lw build --break-locks", 1, true), reason)
        assert.is_true(proc.alive(h.pid, h.start))
    end)

    it("--break-locks recovers a hung holder: kills its tree and reclaims the lock", function()
        local path = bl.lock_path(dir)
        local h = hold(path, "build", "lw", true)
        assert.is_true(proc._suspend(h.pid))
        age(path, bl.STALE_SECONDS + 30)
        lock_break.requested = "now"
        local lines = {}
        lock_break.report = function(l) lines[#lines + 1] = l end
        local ran = false
        local r = capture(function()
            cli._with_build_dir_locks({ dir }, "build", function() ran = true end)
        end)
        lock_break.report = nil
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_true(ran)
        assert.equals(false, proc.alive(h.pid, h.start))
        assert.is_true(vim.wait(5000, function() return proc.alive(h.child, h.child_start) == false end, 50))
        assert.is_truthy(table.concat(lines, "\n"):find("killed", 1, true))
        assert.is_nil(bl.read(dir)) -- released after fn
    end)

    it("--break-locks stops a live, responsive holder too (ask, then kill)", function()
        local path = bl.lock_path(dir)
        local h = hold(path, "build")
        lock_break.requested = "ask"
        local saved = lock_break.ASK_MS
        lock_break.ASK_MS = 300
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end) end)
        lock_break.ASK_MS = saved
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals(false, proc.alive(h.pid, h.start))
    end)

    it("without --break-locks a live holder refuses (fail-fast) naming it", function()
        local h = hold(bl.lock_path(dir), "build")
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("in use by lw build (pid " .. h.pid, 1, true), r.stderr)
        assert.is_true(proc.alive(h.pid, h.start))
    end)

    it("an editor-held lock is never killed, even with --break-locks", function()
        local path = bl.lock_path(dir)
        local h = hold(path, "build", "editor")
        lock_break.requested = "now"
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("held by nvim (pid " .. h.pid, 1, true), r.stderr)
        assert.is_truthy(r.stderr:find("lw unlock --force", 1, true), r.stderr)
        assert.is_true(proc.alive(h.pid, h.start))
    end)

    it("a lock from another host is never killed; refused naming the host", function()
        local path = bl.lock_path(dir)
        vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = lock_record.this_pid(), host = "far-away-host", start_time = "x:1",
            lock_nonce = "n1", kind = "lw", operation = "build", started_at = os.time() }))
        f:close()
        lock_break.requested = "now"
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("far-away-host", 1, true), r.stderr)
        assert.is_not_nil(bl.read(dir))
        -- stale on the other host: reclaimed by the heartbeat rule
        age(path, bl.STALE_SECONDS + 30)
        local mine = assert(bl.acquire(dir, "build"))
        assert.equals("stale_foreign", mine.reclaimed.state)
        bl.release(mine)
    end)

    it("an older record without a start time is judged by its heartbeat alone", function()
        local path = bl.lock_path(dir)
        vim.fn.mkdir(vim.fn.fnamemodify(dir, ":h"), "p")
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = 4194300, host = lock_record.this_host(), action = "build",
            started_at = os.time() }))
        f:close()
        assert.is_nil((bl.acquire(dir, "build"))) -- fresh: live, though the pid is gone
        age(path, bl.STALE_SECONDS + 30)
        local mine = assert(bl.acquire(dir, "build"))
        assert.equals("stale", mine.reclaimed.state)
        bl.release(mine)
    end)

    it("a reclaim removes only the record it judged (nonce)", function()
        local path = tmpdir() .. "/n.lock"
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = 1, host = "h", lock_nonce = "current" }))
        f:close()
        assert.is_false(lock_record.reclaim(path, { lock_nonce = "observed-earlier" }))
        local info = assert(lock_record.read(path, 20))
        assert.equals("current", info.lock_nonce)
        assert.is_true(lock_record.reclaim(path, { lock_nonce = "current" }))
        assert.is_nil(uv.fs_stat(path))
    end)

    it("a holder never removes a record that replaced its own", function()
        local mine = assert(bl.acquire(dir, "build"))
        local path = bl.lock_path(dir)
        assert.is_true(bl.force_path(path))
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = 1, host = "x", lock_nonce = "someone-else" }))
        f:close()
        bl.release(mine)
        assert.equals("someone-else", bl.read(dir).lock_nonce)
        bl.force_path(path)
    end)

    it("the held lock records the step: configure, then build", function()
        local mine = assert(bl.acquire(dir, "build"))
        local build_run = require("loomworks.build_run")
        build_run.before_step({}, { kind = "configure", build_dir = dir })
        assert.equals("configure", bl.read(dir).operation)
        build_run.before_step({}, { kind = "build", build_dir = dir })
        local info = bl.read(dir)
        assert.equals("build", info.operation)
        assert.equals("build", info.action) -- older readers
        bl.release(mine)
    end)
end)

describe("state recovery of a killed holder's build directory (§19.5 step 5)", function()
    local function make_ws()
        local root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root .. "/App", "p")
        local f = assert(io.open(root .. "/loomworks.json", "w"))
        f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
        capture(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
        capture(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
        capture(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
        local ws = assert(cli._load_workspace(root, false))
        local profile = ws._profiles[1]
        local unit = profile:projects()[1]._config_unit
        local dir = root .. "/.nvim/build/App/Debug"
        vim.fn.mkdir(dir, "p")
        unit.build_dir_value = dir
        unit.state_value = "built"
        ws:_sync_build_dir_refs()
        ws:_save_cache()
        return root, dir
    end

    local function state_after_reload(root)
        local ws = assert(cli._load_workspace(root, false))
        return ws._profiles[1]:projects()[1]._config_unit.state_value
    end

    after_each(cleanup)

    it("killed during configure: the units read unconfigured", function()
        local root, dir = make_ws()
        local h = hold(bl.lock_path(dir), "configure")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local ws = assert(cli._load_workspace(root, false))
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("interrupted during configure", 1, true), r.stderr)
        assert.is_nil(state_after_reload(root))
    end)

    it("killed during the build step: the units read configured (configure record kept)", function()
        local root, dir = make_ws()
        local h = hold(bl.lock_path(dir), "build")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local ws = assert(cli._load_workspace(root, false))
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals("configured", state_after_reload(root))
    end)

    it("the editor's acquisition recovers the same way", function()
        local root, dir = make_ws()
        local h = hold(bl.lock_path(dir), "configure")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local ws = assert(cli._load_workspace(root, false))
        local ok = ws:_acquire_file_lock(ws._core._deps.normalize(dir), "build")
        assert.is_true(ok)
        ws:_release_file_lock(ws._core._deps.normalize(dir))
        assert.is_nil(state_after_reload(root))
    end)

    it("a deletion's lock keeps its state (unknown stays unknown)", function()
        local root, dir = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local unit = ws._profiles[1]:projects()[1]._config_unit
        unit.state_value = "unknown"
        if unit._build_dir then unit._build_dir.state = "unknown" end
        ws:_save_cache()
        local h = hold(bl.lock_path(dir), "reset")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local r = capture(function() cli._with_build_dir_locks({ dir }, "build", function() end, ws) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals("unknown", state_after_reload(root))
    end)

    it("lw unlock removes a dead holder's lock (recovering state) but refuses a live one", function()
        local root, dir = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local live = hold(bl.lock_path(dir), "build")
        local r = capture(function() cli.cmd_unlock(ws, { "unlock", ".nvim/build/App/Debug" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("in use by lw build", 1, true), r.stderr)
        assert.is_not_nil(bl.read(dir))
        assert.is_true(proc.kill_tree(live.pid, live.start))
        r = capture(function() cli.cmd_unlock(ws, { "unlock", ".nvim/build/App/Debug" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stdout:find("unlocked .nvim/build/App/Debug", 1, true), r.stdout)
        assert.is_nil(bl.read(dir))
        assert.equals("configured", state_after_reload(root))
    end)

    it("lw unlock --force removes a live holder's record without killing it, loudly", function()
        local root, dir = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local live = hold(bl.lock_path(dir), "build")
        local r = capture(function() cli.cmd_unlock(ws, { "unlock", "--force", ".nvim/build/App/Debug" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("WARNING", 1, true), r.stderr)
        assert.is_truthy(r.stderr:find("may still be running", 1, true), r.stderr)
        assert.is_nil(bl.read(dir))
        assert.is_true(proc.alive(live.pid, live.start))
    end)

    it("lw unlock --force removes another host's lock with the warning", function()
        local root, dir = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local f = assert(io.open(bl.lock_path(dir), "wb"))
        f:write(vim.json.encode({ pid = 7, host = "far-away-host", lock_nonce = "n", kind = "lw",
            operation = "build", started_at = os.time() }))
        f:close()
        local r = capture(function() cli.cmd_unlock(ws, { "unlock", ".nvim/build/App/Debug" }) end)
        assert.equals(1, r.exit_code)
        r = capture(function() cli.cmd_unlock(ws, { "unlock", "--force", ".nvim/build/App/Debug" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("on far-away-host", 1, true), r.stderr)
        assert.is_nil(bl.read(dir))
        local _ = root
    end)

    it("lw unlock refuses a path outside the workspace root", function()
        local root = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local r = capture(function() cli.cmd_unlock(ws, { "unlock", "--force", root .. "-other/build" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("not a directory under the workspace root", 1, true), r.stderr)
    end)

    it("lw unlock --force never follows '..' out of the workspace", function()
        local root = make_ws()
        local ws = assert(cli._load_workspace(root, false))
        local outside = root .. "-outside"
        vim.fn.mkdir(outside, "p")
        local lockf = outside .. "/x.loomworks-lock"
        local f = assert(io.open(lockf, "wb")); f:write("{}"); f:close()
        local base = outside:match("[^/]+$")
        local r = capture(function()
            cli.cmd_unlock(ws, { "unlock", "--force", ".nvim/../../" .. base .. "/x" })
        end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("no '.' or '..' segments", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(lockf), "a lockfile outside the workspace was removed")
        vim.fn.delete(outside, "rf")
    end)
end)

describe("lock order (§19.3)", function()
    it("build directories are taken in normalized-path order, duplicates dropped", function()
        local order = cli._lock_order({ "/w/b/z", "/w/a", "/w/b/z/", "/w/B" })
        if package.config:sub(1, 1) == "\\" then
            assert.same({ "/w/a", "/w/B", "/w/b/z" }, order)
        else
            assert.same({ "/w/B", "/w/a", "/w/b/z" }, order)
        end
    end)

    it("two processes locking the same set never deadlock: the loser fails fast", function()
        local d = tmpdir()
        local a, b = d .. "/a", d .. "/b"
        local h = hold(bl.lock_path(a), "build") -- a holder of the first dir in order
        local r = capture(function() cli._with_build_dir_locks({ b, a }, "build", function() end) end)
        assert.equals(1, r.exit_code)
        -- the refused acquirer released what it took (b) and changed nothing
        assert.is_nil(bl.read(b))
        local _ = h
        cleanup()
    end)
end)

describe("device locks (§18.7 under §19.5)", function()
    local device_lock = require("loomworks.remote.device_lock")
    local saved_env
    before_each(function()
        saved_env = os.getenv("LOOMWORKS_DEVICE_LOCK_DIR")
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = tmpdir()
    end)
    after_each(function()
        cleanup()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_env
        lock_break.requested = nil
    end)

    it("a hung holder is reported, not waited for; --break-locks recovers it", function()
        local h = hold(device_lock.path("SER1"), "run")
        assert.is_true(proc._suspend(h.pid))
        age(device_lock.path("SER1"), 60)
        local lock, err = device_lock.acquire("SER1", { wait = true, command = "lw run" })
        assert.is_nil(lock)
        assert.is_truthy(err:find("hung", 1, true), err)
        assert.is_truthy(err:find("lw run --break-locks", 1, true), err)
        lock, err = device_lock.acquire("SER1", { break_locks = "now", on_break = function() end })
        assert.is_table(lock, err)
        assert.equals(false, proc.alive(h.pid, h.start))
        device_lock.release(lock)
    end)

    it("a killed holder's device lock is reclaimed at once", function()
        local h = hold(device_lock.path("SER2"), "run")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local lock = assert(device_lock.acquire("SER2", { wait = false }))
        assert.equals("dead", lock.reclaimed.state)
        device_lock.release(lock)
    end)
end)
