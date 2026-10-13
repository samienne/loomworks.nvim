-- Cross-process build-dir lock (build_lock.lua): O_EXCL lockfile + heartbeat
-- staleness. Exercised against real temp files (no second process needed — a
-- stale lock is simulated by aging the file mtime).

local bl = require("loomworks.build_lock")
local uv = vim.uv or vim.loop

-- cli.lua is required for its interrupt-cleanup seam; the flag stops its
-- bottom-of-file autorun from executing main() on require.
_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")

local function fresh_build_dir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return d .. "/build/variant"
end

describe("build_lock", function()
    local dir
    before_each(function() dir = fresh_build_dir() end)

    it("acquires, fails a second acquire (fail-fast), then releases", function()
        local h = assert(bl.acquire(dir, "build"))
        local h2, reason = bl.acquire(dir, "build")
        assert.is_nil(h2)
        assert.is_truthy(reason:find("in use"))
        bl.release(h)
        local h3 = assert(bl.acquire(dir, "build"))
        bl.release(h3)
    end)

    it("read returns the holder's info and clears after release", function()
        local h = assert(bl.acquire(dir, "configure"))
        local info = bl.read(dir)
        assert.equals("configure", info.action)
        assert.is_number(info.pid)
        assert.is_false(info.stale)
        bl.release(h)
        assert.is_nil(bl.read(dir))
    end)

    it("reclaims a crashed holder's lock; a stale but living holder is hung, not reclaimed", function()
        local h = assert(bl.acquire(dir, "build"))
        -- A living holder (this process) that stopped heartbeating: hung (§19.5).
        h.timer:stop(); h.timer:close(); h.timer = nil
        local old = os.time() - (bl.STALE_SECONDS + 60)
        local path = dir .. ".loomworks-lock"
        uv.fs_utime(path, old, old)
        assert.is_true(bl.read(dir).stale)
        local none, reason, info = bl.acquire(dir, "build")
        assert.is_nil(none)
        assert.equals("hung", info.state)
        -- (this test process records itself as an editor holder: the editor
        -- message, which never suggests killing it)
        assert.is_truthy(reason:find("held by nvim", 1, true), reason)

        -- A crashed holder: the recorded process no longer exists.
        local rec = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
        rec.pid = 4194300
        local f = assert(io.open(path, "wb")); f:write(vim.json.encode(rec)); f:close()
        local h2 = assert(bl.acquire(dir, "build")) -- reclaims the dead holder's lock
        assert.equals("dead", h2.reclaimed.state)
        assert.is_false(bl.read(dir).stale)
        bl.release(h2)
    end)

    it("does NOT reclaim a fresh lock", function()
        local h = assert(bl.acquire(dir, "build"))
        local h2, reason = bl.acquire(dir, "build")
        assert.is_nil(h2)
        assert.is_truthy(reason)
        bl.release(h)
    end)

    it("force removes a lock", function()
        local h = assert(bl.acquire(dir, "build"))
        h.timer:stop(); h.timer:close(); h.timer = nil
        assert.is_true(bl.force(dir))
        assert.is_nil(bl.read(dir))
        assert.is_false(bl.force(dir)) -- nothing to remove
    end)
end)

-- Regression: a Ctrl-C'd `lw build` must release its build locks immediately
-- (not leak them until the stale-mtime reclaim). The CLI's SIGINT/SIGTERM
-- handler routes through the same run_exit_hooks() path that with_build_locks
-- registers its release_all on. This exercises that real chain: hold a lock,
-- register its release as an exit hook (as with_build_locks does), then invoke
-- the interrupt-cleanup callback body with an injected exit stub. Before the fix
-- there was no handler, so an interrupt left the lockfile behind.
describe("build_lock release on interrupt (cli)", function()
    it("interrupt cleanup releases held locks and exits 130 (once)", function()
        local build_dir = fresh_build_dir()
        local h = assert(bl.acquire(build_dir, "build")) -- real lockfile on disk
        cli._on_exit(function() bl.release(h) end)
        assert.is_not_nil(bl.read(build_dir))            -- lock is held

        local exit_code
        local cleanup = cli._make_interrupt_cleanup(130, function(c) exit_code = c end)
        cleanup()

        assert.is_nil(bl.read(build_dir))                -- released by interrupt path
        assert.equals(130, exit_code)

        -- Re-entrancy guard: a repeated Ctrl-C / second signal must not re-run.
        exit_code = nil
        cleanup()
        assert.is_nil(exit_code)
    end)

    it("install_interrupt_handler is best-effort and returns the callback", function()
        -- Must never throw even where a handle can't be installed; returns the
        -- shared guarded cleanup so both signals fire the same one.
        local exit_code
        local cleanup = cli._install_interrupt_handler(function(c) exit_code = c end)
        assert.is_function(cleanup)
        cleanup()
        assert.equals(130, exit_code)
    end)
end)

-- A lockfile was created empty (exclusive create) and its record written right
-- after (still so without hard links, or by an older version): a reader
-- between the two saw an empty body, which has no host and was
-- classified as ANOTHER host's live lock — e.g. a `--no-launch` relay polling
-- the runtime lock R while a daemon starts exited 13 ("the workspace daemon
-- runs on another host (?, pid ?)") and the editor stopped following.
describe("lock_record.read of a lockfile whose record is being written", function()
    local lock_record = require("loomworks.lock_record")
    local path, saved_sleep, saved_ms
    before_each(function()
        local d = vim.fn.tempname()
        vim.fn.mkdir(d, "p")
        path = d .. "/R.lock"
        saved_sleep, saved_ms = lock_record._settle_sleep, lock_record.EMPTY_SETTLE_MS
    end)
    after_each(function()
        lock_record._settle_sleep, lock_record.EMPTY_SETTLE_MS = saved_sleep, saved_ms
    end)

    local function write(body)
        local f = assert(io.open(path, "wb")); f:write(body); f:close()
    end

    it("waits for the record of a fresh empty lockfile: this host's live holder, not a foreign one", function()
        write("")
        local rec = lock_record.new("daemon", { mode = "daemon" })
        local waits = 0
        -- The writer finishes while the reader waits.
        lock_record._settle_sleep = function()
            waits = waits + 1
            if waits == 2 then write(vim.json.encode(rec)) end
        end
        local info = assert(lock_record.read(path, 30))
        assert.is_true(waits >= 2)
        assert.equals(rec.lock_nonce, info.lock_nonce)
        assert.is_true(lock_record.same_host(info))
        assert.equals("live", lock_record.classify(info))
    end)

    it("an empty lockfile that stays empty reads as {} after the bound", function()
        write("")
        lock_record.EMPTY_SETTLE_MS = 30
        lock_record._settle_sleep = function() uv.sleep(1) end
        local info = assert(lock_record.read(path, 30))
        assert.is_nil(info.host)
        assert.is_nil(info.pid)
        -- No host to check and a fresh heartbeat: judged live, never reclaimed.
        assert.equals("live", lock_record.classify(info))
    end)

    it("an old empty lockfile (its writer died) is not waited for", function()
        write("")
        uv.fs_utime(path, os.time() - 60, os.time() - 60)
        lock_record._settle_sleep = function() error("waited for an old empty lockfile") end
        local info = assert(lock_record.read(path, 30))
        assert.is_nil(info.host)
        assert.is_true(info.stale)
    end)

    it("a lockfile removed while it is waited for reads as absent", function()
        write("")
        lock_record._settle_sleep = function() os.remove(path) end
        assert.is_nil(lock_record.read(path, 30))
    end)

    it("a legacy non-JSON body is not waited for", function()
        write("pid 123")
        lock_record._settle_sleep = function() error("waited for a non-empty body") end
        local info = assert(lock_record.read(path, 30))
        assert.is_nil(info.host)
    end)
end)

-- The writer side (spec §19.5): a lock file is created by hard-linking a
-- written temp to its name and rewritten by a rename, so it never exists
-- without its record.
describe("lock files are written atomically", function()
    local lock_record = require("loomworks.lock_record")
    local dir, path, saved
    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        path = dir .. "/x.loomworks-lock"
        saved = { link = lock_record._link, rename = lock_record._rename }
    end)
    after_each(function()
        lock_record._link, lock_record._rename = saved.link, saved.rename
    end)

    local function body(p)
        local fd = uv.fs_open(p, "r", 256)
        if not fd then return nil end
        local st = uv.fs_fstat(fd)
        local data = uv.fs_read(fd, math.max(st and st.size or 0, 1), 0)
        uv.fs_close(fd)
        return data
    end

    -- The directory's entries (a lock file, never a temp left beside it).
    local function names()
        local out = {}
        for n in vim.fs.dir(dir) do out[#out + 1] = n end
        table.sort(out)
        return out
    end

    it("create: the lock file appears with its full record (it does not exist before the link)", function()
        local seen
        lock_record._link = function(from, to)
            if to == path then
                assert.is_nil(uv.fs_stat(path))
                seen = vim.json.decode(body(from))
            end
            return saved.link(from, to)
        end
        local h = assert(bl.try_acquire_path(path, "build"))
        assert.equals(h.record.lock_nonce, seen.lock_nonce)
        assert.equals(h.record.lock_nonce, vim.json.decode(body(path)).lock_nonce)
        assert.same({ "x.loomworks-lock" }, names())
        bl.release(h)
        assert.same({}, names())
    end)

    it("create: a held lock answers EEXIST and leaves no temp", function()
        local h = assert(bl.try_acquire_path(path, "build"))
        local ok, _, code = lock_record.create(path, lock_record.new("build"))
        assert.is_nil(ok)
        assert.equals("EEXIST", code)
        assert.same({ "x.loomworks-lock" }, names())
        bl.release(h)
    end)

    it("create falls back to the exclusive create where hard links are unsupported", function()
        local links = 0
        lock_record._link = function()
            links = links + 1
            return nil, "EPERM: operation not permitted", "EPERM"
        end
        local h = assert(bl.try_acquire_path(path, "build"))
        assert.equals(2, links) -- the link, then the probe to a fresh name
        assert.equals(h.record.lock_nonce, vim.json.decode(body(path)).lock_nonce)
        assert.same({ "x.loomworks-lock" }, names())
        -- Still exclusive: a second create is refused.
        local ok, _, code = lock_record.create(path, lock_record.new("build"))
        assert.is_nil(ok)
        assert.equals("EEXIST", code)
        assert.same({ "x.loomworks-lock" }, names())
        bl.release(h)
    end)

    it("create: a link error about the name only (the probe link works) is returned, no fallback", function()
        lock_record._link = function(from, to)
            if to == path then return nil, "EPERM: operation not permitted", "EPERM" end
            return saved.link(from, to)
        end
        local ok, _, code = lock_record.create(path, lock_record.new("build"))
        assert.is_nil(ok)
        assert.equals("EPERM", code)
        assert.is_nil(uv.fs_stat(path))
        assert.same({}, names())
    end)

    it("update_record replaces the record by a rename (old or new, never empty)", function()
        local h = assert(bl.try_acquire_path(path, "configure"))
        local renamed = 0
        lock_record._rename = function(from, to)
            renamed = renamed + 1
            assert.equals("configure", vim.json.decode(body(path)).operation)
            assert.equals("build", vim.json.decode(body(from)).operation)
            return saved.rename(from, to)
        end
        bl.update_record(h, { operation = "build", action = "build" })
        assert.equals(1, renamed)
        local rec = vim.json.decode(body(path))
        assert.equals("build", rec.operation)
        assert.equals(h.record.lock_nonce, rec.lock_nonce)
        assert.is_true(lock_record.still_ours(path, h.record))
        assert.same({ "x.loomworks-lock" }, names())
        bl.release(h)
        assert.same({}, names())
    end)

    it("update_record never recreates a lock file forced off, and leaves no temp", function()
        local h = assert(bl.try_acquire_path(path, "configure"))
        assert.is_true(bl.force_path(path))
        lock_record._rename = function() error("renamed over a lock that is not ours") end
        bl.update_record(h, { operation = "build" })
        assert.is_nil(uv.fs_stat(path))
        assert.same({}, names())
        bl.release(h)
    end)

    it("update_record: a rename that keeps failing removes its temp and rewrites in place", function()
        local h = assert(bl.try_acquire_path(path, "configure"))
        local saved_ms = lock_record.REPLACE_RETRY_MS
        lock_record.REPLACE_RETRY_MS = 1
        local tries = 0
        lock_record._rename = function()
            tries = tries + 1
            return nil, "EACCES: permission denied", "EACCES"
        end
        bl.update_record(h, { operation = "build" })
        lock_record.REPLACE_RETRY_MS = saved_ms
        assert.equals(lock_record.REPLACE_RETRIES, tries)
        assert.equals("build", vim.json.decode(body(path)).operation)
        assert.same({ "x.loomworks-lock" }, names())
        bl.release(h)
    end)

    it("update_record: the in-place fallback leaves a lock that is no longer ours alone", function()
        local h = assert(bl.try_acquire_path(path, "configure"))
        local saved_ms = lock_record.REPLACE_RETRY_MS
        lock_record.REPLACE_RETRY_MS = 1
        local other = '{"pid":1,"lock_nonce":"someone-else"}'
        local tries = 0
        lock_record._rename = function()
            tries = tries + 1
            if tries == lock_record.REPLACE_RETRIES then
                -- Taken over after the last check, before the fallback.
                local f = assert(io.open(path, "wb"))
                f:write(other)
                f:close()
            end
            return nil, "EACCES: permission denied", "EACCES"
        end
        bl.update_record(h, { operation = "build" })
        lock_record.REPLACE_RETRY_MS = saved_ms
        assert.equals(lock_record.REPLACE_RETRIES, tries)
        assert.equals(other, body(path))
        assert.same({ "x.loomworks-lock" }, names())
        pcall(uv.fs_unlink, path)
        bl.release(h)
    end)

    it("save_guard.lock creates its lock file with the record in place", function()
        local sg = require("loomworks.save_guard")
        local file = dir .. "/f.json"
        local seen
        lock_record._link = function(from, to)
            if to == file .. ".lock" then
                assert.is_nil(uv.fs_stat(to))
                seen = vim.json.decode(body(from))
            end
            return saved.link(from, to)
        end
        local h = assert(sg.lock(file))
        assert.equals(h.token, seen.lock_nonce)
        assert.same({ "f.json.lock" }, names())
        sg.unlock(h)
        assert.same({}, names())
    end)

    -- Another process creates, rewrites and releases the lock in a loop: a
    -- reader polling it never finds it empty or partial.
    it("a reader racing another process never sees an empty or partial record", function()
        local script = dir .. "/writer.lua"
        local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"):gsub("\\", "/")
        local f = assert(io.open(script, "wb"))
        f:write(([[
package.path = %q .. "/lua/?.lua;" .. %q .. "/lua/?/init.lua;" .. package.path
local bl = require("loomworks.build_lock")
local path = %q
-- The in-place fallback (taken only when every rename failed, e.g. on a
-- loaded Windows runner) may expose an empty body by design; count it
-- instead of running it, so the test checks only the rename path.
local fallbacks = 0
bl._rewrite_in_place = function() fallbacks = fallbacks + 1 end
for i = 1, 150 do
    local h = bl.try_acquire_path(path, "configure")
    if h then
        bl.update_record(h, { operation = "build", action = "build", i = i })
        bl.release(h)
    end
end
io.stdout:write("fallbacks=", fallbacks)
]]):format(root, root, path))
        f:close()
        local done = false
        local proc = vim.system({ vim.v.progpath, "--headless", "--clean", "-l", script }, { text = true },
            function() done = true end)
        local reads, bad = 0, {}
        while not done do
            local data = body(path)
            if data ~= nil then
                reads = reads + 1
                local ok, rec = pcall(vim.json.decode, data)
                if not ok or type(rec) ~= "table" or type(rec.lock_nonce) ~= "string" then
                    bad[#bad + 1] = data
                end
            end
            vim.wait(0)
        end
        local res = proc:wait()
        assert.equals(0, res.code, res.stderr)
        -- The writer ran the rename path (its in-place fallback was stubbed).
        assert.truthy((res.stdout or ""):match("fallbacks=%d+"), res.stdout)
        assert.same({}, bad)
        -- Only the writer script remains: no lock file, no temp.
        assert.same({ "writer.lua" }, names())
    end)
end)
