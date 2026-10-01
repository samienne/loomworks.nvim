-- The workspace operation lock O and the lock order (spec §19.3), against
-- real helper processes: publish ∥ rename, import ∥ publish, nuke ∥ build,
-- reset / trust --discard / pull under a held O, hung and dead O holders,
-- `lw unlock --workspace`, and the editor's deletion path taking O + B.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local bl = require("loomworks.build_lock")
local op_lock = require("loomworks.op_lock")
local lock_break = require("loomworks.lock_break")
local proc = require("loomworks.proc")
local L = require("tests.lock_helpers")
local uv = vim.uv or vim.loop

local function load(root) return assert(cli._load_workspace(root, false)) end

describe("workspace operation lock (§19.3)", function()
    after_each(function()
        L.cleanup()
        lock_break.requested = nil
        lock_break.command = nil
        op_lock.release_all()
    end)

    it("is re-entrant within a process and released with the outermost holder", function()
        local root = L.tmpdir()
        local a = assert(op_lock.acquire(root, "reset"))
        local b = assert(op_lock.acquire(root, "delete"))
        assert.is_true(b.nested)
        op_lock.release(b)
        assert.is_not_nil(op_lock.read(root))
        op_lock.release(a)
        assert.is_nil(op_lock.read(root))
    end)

    it("another process's multi-file operation makes it fail fast: workspace busy", function()
        local root = L.tmpdir()
        local h = L.hold(op_lock.path(root), "publish")
        local tok, msg = op_lock.acquire(root, "rename")
        assert.is_nil(tok)
        assert.is_truthy(msg:find("workspace busy: publish (pid " .. h.pid .. " on ", 1, true), msg)
        assert.is_truthy(msg:find("retry when it finishes", 1, true), msg)
    end)

    it("publish ∥ rename: the rename is refused and changes nothing", function()
        local root = L.make_ws()
        local before_user = L.read(root .. "/.nvim/loomworks.user.json")
        local before_cache = L.read(root .. "/.nvim/loomworks.cache.json")
        L.hold(op_lock.path(root), "publish")
        local r = L.capture(function() cli.cmd_project_rename(root, "App", "App2") end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy: publish", 1, true), r.stderr)
        assert.equals(before_user, L.read(root .. "/.nvim/loomworks.user.json"))
        assert.equals(before_cache, L.read(root .. "/.nvim/loomworks.cache.json"))
    end)

    it("import ∥ publish: lw publish is refused while an import holds the lock", function()
        local root = L.make_ws()
        L.hold(op_lock.path(root), "import")
        local r = L.capture(function() cli.cmd_publish(root) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy: import", 1, true), r.stderr)
        assert.is_nil(r.stdout:find("published", 1, true))
    end)

    it("reset under a held operation lock is refused before anything is removed", function()
        local root, dir = L.make_ws()
        L.hold(op_lock.path(root), "publish")
        local ws = load(root)
        local r = L.capture(function() cli.cmd_reset(ws, { "reset", "Dev", "-y" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_nil(bl.read(dir), "no build lock left behind")
    end)

    it("trust --discard and pull are refused under a held operation lock", function()
        local root = L.make_ws()
        L.hold(op_lock.path(root), "publish")
        local r = L.capture(function() cli.cmd_trust(root, { "trust", "--discard", "--yes" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(root .. "/.nvim/loomworks.user.json"))
    end)

    it("a hung holder is reported with the recovery command; --break-locks recovers", function()
        local root = L.make_ws()
        local path = op_lock.path(root)
        local h = L.hold(path, "publish")
        assert.is_true(proc._suspend(h.pid))
        L.age(path, bl.STALE_SECONDS + 30)
        lock_break.command = "lw publish"
        local r = L.capture(function() cli.cmd_publish(root) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("the workspace is locked by a hung lw publish", 1, true), r.stderr)
        assert.is_truthy(r.stderr:find("lw publish --break-locks", 1, true), r.stderr)
        lock_break.requested = "now"
        lock_break.report = function() end
        r = L.capture(function() cli.cmd_publish(root) end)
        lock_break.report = nil
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals(false, proc.alive(h.pid, h.start))
        assert.is_nil(op_lock.read(root))
    end)

    it("a dead holder's operation lock is reclaimed at once and reported", function()
        local root = L.make_ws()
        local h = L.hold(op_lock.path(root), "publish")
        assert.is_true(proc.kill_tree(h.pid, h.start))
        local r = L.capture(function() cli.cmd_publish(root) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("reclaimed the workspace operation lock from lw publish", 1, true),
            r.stderr)
    end)

    it("lw unlock --workspace: a gone holder's lock goes; a running one only with --force", function()
        local root = L.make_ws()
        local path = op_lock.path(root)
        local h = L.hold(path, "publish")
        local r = L.capture(function() cli.cmd_unlock(nil, { "unlock", "--workspace" }, root) end)
        assert.equals(1, r.exit_code)
        assert.is_not_nil(op_lock.read(root))
        r = L.capture(function() cli.cmd_unlock(nil, { "unlock", "--workspace", "--force" }, root) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_truthy(r.stderr:find("WARNING", 1, true), r.stderr)
        assert.is_nil(op_lock.read(root))
        assert.is_true(proc.alive(h.pid, h.start), "--force never stops the holder")
        -- a dead holder's record goes without --force
        local f = assert(io.open(path, "wb"))
        f:write(vim.json.encode({ pid = 4194300, host = require("loomworks.lock_record").this_host(),
            start_time = proc.self_start_time(), lock_nonce = "x", kind = "lw", operation = "publish",
            started_at = os.time() }))
        f:close()
        r = L.capture(function() cli.cmd_unlock(nil, { "unlock", "--workspace" }, root) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_nil(op_lock.read(root))
    end)
end)

describe("nuke takes the build locks (§19.3)", function()
    local saved_core
    after_each(function()
        L.cleanup()
        lock_break.requested = nil
        lock_break.command = nil
        op_lock.release_all()
    end)

    it("nuke ∥ build: refuses while a build holds a build directory, deletes nothing", function()
        local root, dir = L.make_ws()
        local h = L.hold(bl.lock_path(dir), "build")
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("cannot nuke: a build is running in .nvim/build/App/Debug (pid "
            .. h.pid, 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_not_nil(uv.fs_stat(root .. "/.nvim/loomworks.cache.json"))
        assert.is_nil(op_lock.read(root), "the operation lock was released on refusal")
        local _ = saved_core
    end)

    it("nuke --break-locks=now stops the build and nukes", function()
        local root, dir = L.make_ws()
        local h = L.hold(bl.lock_path(dir), "build", "lw", true)
        lock_break.requested = "now"
        lock_break.report = function() end
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        lock_break.report = nil
        assert.is_nil(r.exit_code, r.stderr)
        assert.equals(false, proc.alive(h.pid, h.start))
        assert.is_nil(uv.fs_stat(dir))
    end)

    it("nuke under a held operation lock is refused", function()
        local root, dir = L.make_ws()
        L.hold(op_lock.path(root), "publish")
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("workspace busy", 1, true), r.stderr)
        assert.is_not_nil(uv.fs_stat(dir))
    end)
end)

describe("the editor's deletion takes O and B (§19.3)", function()
    after_each(function() L.cleanup(); op_lock.release_all() end)

    it("a profile reset is refused while another process builds the directory", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        ws._core._deps.on_lock_refused = nil
        local errs = {}
        ws._core._deps.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
        end
        local h = L.hold(bl.lock_path(dir), "build")
        local done, result = false, nil
        ws._profiles[1]:reset(function() done = true end)
            :next(function(v) result = v end)
        assert.is_true(vim.wait(5000, function() return done end, 20))
        assert.equals(false, result)
        assert.is_truthy(table.concat(errs, "\n"):find("cannot delete: .nvim/build/App/Debug is in use by lw build (pid "
            .. h.pid, 1, true), table.concat(errs, "\n"))
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_nil(op_lock.read(root))
    end)

    it("a profile reset holds O and B while it runs and releases both", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local saw_o, saw_b = false, false
        local io_mod = require("loomworks.io")
        local real = io_mod.rm_rf_async
        io_mod.rm_rf_async = function(d, cb)
            saw_o = op_lock.read(root) ~= nil
            saw_b = bl.read(dir) ~= nil
            vim.fn.delete(d, "rf")
            if cb then vim.schedule(function() cb(true, nil) end) end
            return require("loomworks.future").resolved(true)
        end
        local done = false
        ws._profiles[1]:reset(function() done = true end)
        local ok = vim.wait(5000, function() return done end, 20)
        io_mod.rm_rf_async = real
        assert.is_true(ok)
        assert.is_true(saw_o, "O held during the deletion")
        assert.is_true(saw_b, "B held during the deletion")
        assert.is_true(vim.wait(2000, function() return op_lock.read(root) == nil and bl.read(dir) == nil end, 20))
    end)
end)
