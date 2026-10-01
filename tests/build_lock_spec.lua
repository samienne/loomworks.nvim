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
