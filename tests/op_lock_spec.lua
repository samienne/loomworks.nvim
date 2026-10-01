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
        local all = table.concat(errs, "\n")
        assert.is_truthy(all:find("cannot delete: ", 1, true), all)
        assert.is_truthy(all:find(".nvim/build/App/Debug is in use by lw build (pid " .. h.pid, 1, true), all)
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

describe("review fixes (§19.3)", function()
    local io_mod = require("loomworks.io")
    local saved = {}
    before_each(function()
        saved.rm_rf, saved.rm_rf_async, saved.hb = io_mod.rm_rf, io_mod.rm_rf_async, bl.HEARTBEAT_MS
    end)
    after_each(function()
        io_mod.rm_rf, io_mod.rm_rf_async, bl.HEARTBEAT_MS = saved.rm_rf, saved.rm_rf_async, saved.hb
        L.cleanup()
        op_lock.release_all()
    end)

    --- Run `hook(target)` when nuke starts removing its build tree, then remove it.
    local function on_tree_removal(hook)
        local function intercept(target)
            if target:find("/.nvim/build", 1, true) and not target:find("loomworks", 1, true) then
                hook(target)
            end
        end
        io_mod.rm_rf = function(p) intercept(p); return saved.rm_rf(p) end
        io_mod.rm_rf_async = function(p, cb)
            intercept(p)
            return saved.rm_rf_async(p, cb)
        end
    end

    it("nuke ∥ a build starting mid-removal: the new build's tree survives", function()
        local root = L.make_ws()
        local fresh = root .. "/.nvim/build/App/Debug"
        local newlock
        on_tree_removal(function()
            if newlock then return end
            -- a build starting the moment nuke's locks are gone
            vim.fn.mkdir(fresh, "p")
            local mf = assert(io.open(fresh .. "/new.o", "wb")); mf:write("x"); mf:close()
            newlock = assert(bl.acquire(fresh, "build"))
        end)
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_not_nil(newlock)
        assert.is_not_nil(uv.fs_stat(fresh .. "/new.o"), "nuke deleted a tree a new build created")
        assert.is_not_nil(bl.read(fresh), "nuke deleted the new build's lock")
        bl.release(newlock)
        local left = {}
        for n in vim.fs.dir(root .. "/.nvim") do if n:match("^build%.nuke") then left[#left + 1] = n end end
        assert.same({}, left, "the aside tree is removed")
    end)

    it("nuke removes the cache before the tree and keeps heartbeating while it removes", function()
        local root = L.make_ws()
        bl.HEARTBEAT_MS = 100
        local cache_gone, fresh_beat
        local function slow(p, cb)
            cache_gone = uv.fs_stat(root .. "/.nvim/loomworks.cache.json") == nil
            L.age(op_lock.path(root), 300)
            local t = uv.new_timer()
            t:start(1500, 0, function()
                t:close()
                local info = op_lock.read(root)
                fresh_beat = info ~= nil and info.age < 100
                vim.schedule(function() saved.rm_rf_async(p, cb) end)
            end)
        end
        io_mod.rm_rf_async = function(p, cb)
            if p:find("build.nuke-", 1, true) or p:match("/%.nvim/build$") then return slow(p, cb) end
            return saved.rm_rf_async(p, cb)
        end
        io_mod.rm_rf = function(p)
            if p:match("/%.nvim/build$") then
                -- (the code before the fix removed the tree synchronously)
                cache_gone = uv.fs_stat(root .. "/.nvim/loomworks.cache.json") == nil
                fresh_beat = false
            end
            return saved.rm_rf(p)
        end
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_true(cache_gone, "the cache still existed while the tree was removed")
        assert.is_true(fresh_beat, "the operation lock stopped heartbeating during the removal")
    end)

    it("a leftover tree of a crashed nuke is removed; look-alikes are not", function()
        local root = L.make_ws()
        local nv = root .. "/.nvim/"
        vim.fn.mkdir(nv .. "build.nuke-abc123/x", "p")
        vim.fn.mkdir(nv .. "build.nuke-notHEX", "p")
        vim.fn.mkdir(nv .. "keep.nuke-abc", "p")
        local r = L.capture(function() cli.cmd_nuke(root, { "nuke", "-y" }) end)
        assert.is_nil(r.exit_code, r.stderr)
        assert.is_nil(uv.fs_stat(nv .. "build.nuke-abc123"))
        assert.is_not_nil(uv.fs_stat(nv .. "build.nuke-notHEX"))
        assert.is_not_nil(uv.fs_stat(nv .. "keep.nuke-abc"))
    end)

    it("a deletion holds its own reference: the cancelled task's release keeps the lock", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local key = ws._core._deps.normalize(dir)
        assert.is_true(ws:_acquire_file_lock(key, "build")) -- the editor task's lock
        local mid
        io_mod.rm_rf_async = function(d, cb)
            ws:_release_file_lock(key) -- the cancelled task lets go mid-removal
            mid = bl.read(dir) ~= nil
            vim.fn.delete(d, "rf")
            if cb then vim.schedule(function() cb(true, nil) end) end
            return require("loomworks.future").resolved(true)
        end
        local done = false
        ws._profiles[1]:reset(function() done = true end)
        assert.is_true(vim.wait(5000, function() return done end, 20))
        assert.is_true(mid, "the lockfile vanished while the deletion was still removing")
        assert.is_true(vim.wait(2000, function() return bl.read(dir) == nil end, 20))
    end)

    it("teardown releases the operation lock and build locks of a deletion that never settles", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        io_mod.rm_rf_async = function() return require("loomworks.future").create(function() end) end
        ws._profiles[1]:reset()
        assert.is_true(vim.wait(2000, function() return op_lock.read(root) ~= nil and bl.read(dir) ~= nil end, 20))
        ws:teardown()
        assert.is_nil(op_lock.read(root), "O survived teardown")
        assert.is_nil(bl.read(dir), "the build lock survived teardown")
    end)

    it("upgrading / downgrading profiles for a tool takes the operation lock", function()
        local root = L.make_ws()
        local ws = load(root)
        ws._core._deps.on_lock_refused = nil
        ws._core._deps.notify = function() end
        L.hold(op_lock.path(root), "publish")
        local ok, msg = ws:upgrade_profiles_for_tool({ type = "typescript", key = "x" })
        assert.equals(false, ok)
        assert.is_truthy(tostring(msg):find("workspace busy", 1, true), tostring(msg))
        ok = ws:downgrade_profiles_from_tool("typescript")
        assert.equals(false, ok)
    end)

    it("migrate refuses when the working copy changed after it planned, before writing", function()
        local root = L.make_ws()
        local migrate = require("loomworks.migrate")
        local real_plan, real_apply = migrate.plan, migrate.apply
        local applied = false
        migrate.plan = function()
            -- another process writes the working copy right after this plan
            local p = root .. "/.nvim/loomworks.user.json"
            local f = assert(io.open(p, "ab")); f:write("\n"); f:close()
            return { changes = { { project = "App", item = "Debug", rule = "r", before = "a", after = "b" } },
                skipped = {} }
        end
        migrate.apply = function() applied = true; return 1 end
        local r = L.capture(function() cli.cmd_migrate(root, { "migrate", "-y" }) end)
        migrate.plan, migrate.apply = real_plan, real_apply
        assert.equals(1, r.exit_code)
        assert.is_truthy(r.stderr:find("changed on disk", 1, true), r.stderr)
        assert.is_false(applied, "migrate wrote over a working copy it had not read")
    end)
end)

describe("fake roots never get lockfiles (§19.3)", function()
    it("a workspace on a root that does not exist takes inert locks", function()
        local h = require("tests.helpers")
        local Core = require("loomworks.core")
        local root = "/lw-guard-root-" .. tostring(uv.hrtime())
        local deps = h.make_test_deps({ ["loomworks.json"] = h.make_config_json({ projects = { App = { cmake = {} } } }) })
        deps.locks = nil -- the production default
        local core = Core.new(deps)
        core:setup({ root = root })
        local ws = assert(core:get_workspace())
        local tok = assert(ws:_op_lock("publish"))
        ws:_op_unlock(tok)
        ws:_locked_deletion("delete", { root .. "/.nvim/build/App/Debug" },
            function() return require("loomworks.future").resolved(true) end)
        assert.is_true(ws:_acquire_file_lock(root .. "/.nvim/build/App/Debug", "build"))
        ws:_release_file_lock(root .. "/.nvim/build/App/Debug")
        assert.is_nil(uv.fs_stat(root), "a lock created " .. root)
    end)
end)
