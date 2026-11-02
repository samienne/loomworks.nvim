-- Runtime slots (spec §19.7.1) and the legacy unslotted daemon files (§19.6
-- "Legacy files"): per-slot lock / handle / log names and pipe name, the
-- legacy lock and handle removed only as a reclaimer would, legacy logs as
-- leftovers, links never followed, another slot's files never touched, the
-- process scan keeping only this slot's daemons.

local identity = require("loomworks.daemon.identity")
local paths = require("loomworks.daemon.paths")
local legacy = require("loomworks.daemon.legacy")
local proc = require("loomworks.proc")
local lr = require("loomworks.lock_record")
local uv = vim.uv or vim.loop

local IS_WIN = package.config:sub(1, 1) == "\\"
local OTHER = "0123456789abcdef" -- another slot's token

local function mkdir(p) vim.fn.mkdir(p, "p"); return p end
local function write(p, body)
    mkdir(p:match("^(.*)/[^/]+$"))
    local f = assert(io.open(p, "wb")); f:write(body or "x"); f:close()
    return p
end
local function exists(p) return uv.fs_lstat(p) ~= nil end
local function new_root()
    local r = vim.fn.tempname():gsub("\\", "/")
    mkdir(r .. "/.nvim")
    return r
end

--- A start time of this OS's method that is not this process's: a record
--- naming this pid with it names a process that is gone.
local function gone_start()
    return (proc.self_start_time():gsub("[^:]+$", "1"))
end

local function lock_rec(st, extra)
    local r = { pid = uv.os_getpid(), host = lr.this_host(), start_time = st, lock_nonce = "n" .. tostring(st),
        kind = "daemon", mode = "daemon", operation = "daemon", started_at = os.time() }
    for k, v in pairs(extra or {}) do r[k] = v end
    return vim.json.encode(r)
end
local function handle_rec(st)
    return vim.json.encode({ pid = uv.os_getpid(), host = lr.this_host(), start_time = st,
        endpoint = "legacy-endpoint", protocol = 10 })
end

local function hk_collect(root)
    return require("loomworks.housekeeping").collect({
        root = root, data = root .. "/no-data", tmp_dirs = {}, sockets = false, exe = false,
        cache_dir = false, legacy_logs_any_age = true,
    })
end

describe("runtime slot", function()
    after_each(function()
        identity._set_identity(nil)
        identity._process_probe = nil
    end)

    it("S is 16 lowercase hex digits, stable within the process", function()
        local s = identity.slot()
        assert.truthy(s:match("^[0-9a-f]+$"))
        assert.equals(16, #s)
        assert.equals(s, identity.slot())
        assert.equals(identity.token_of(identity.identity()), s)
        -- SHA-256("loomworks-daemon-slot-v1" LF I), first 16 hex digits.
        assert.equals(vim.fn.sha256("loomworks-daemon-slot-v1\n" .. identity.identity()):sub(1, 16), s)
        if IS_WIN then
            assert.truthy(identity.identity():match("^S%-[%d%-]+ (%a+)$"))
        else
            assert.truthy(identity.identity():match("^%d+$"))
        end
    end)

    it("differs by elevation / euid: distinct lock, handle, log and pipe names", function()
        local root = "C:/ws/one"
        identity._set_identity("S-1-5-21-1-2-3-1001 standard")
        local a = { paths.lock_path(root), paths.handle_path(root), paths.log_path(root),
            require("loomworks.daemon.endpoint").address(root), identity.slot() }
        identity._set_identity("S-1-5-21-1-2-3-1001 elevated")
        local b = { paths.lock_path(root), paths.handle_path(root), paths.log_path(root),
            require("loomworks.daemon.endpoint").address(root), identity.slot() }
        assert.are_not.equal(a[5], b[5])
        for i = 1, 3 do assert.are_not.equal(a[i], b[i]) end
        if IS_WIN then assert.are_not.equal(a[4], b[4]) end
        assert.equals(root .. "/.nvim/loomworks.daemon-" .. a[5] .. ".lock", a[1])
        assert.equals(root .. "/.nvim/loomworks.daemon-" .. a[5] .. ".json", a[2])
        assert.equals(root .. "/.nvim/loomworks.daemon-" .. b[5] .. ".log", b[3])
        identity._set_identity("1000")
        local u = identity.slot()
        identity._set_identity("0")
        assert.are_not.equal(u, identity.slot())
    end)

    it("no shared fallback: an unreadable identity is an error", function()
        local saved = identity.read_identity
        identity._set_identity(nil)
        identity.read_identity = function() return nil, "denied" end
        local ok, err = pcall(paths.lock_path, "C:/ws")
        identity.read_identity = saved
        identity._set_identity(nil)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("daemon slot", 1, true))
    end)

    it("same_slot: true only for a readable, equal identity", function()
        identity._set_identity("42")
        identity._process_probe = function(pid) return pid == 1 and "42" or (pid == 2 and "0" or nil) end
        assert.is_true(identity.same_slot(1))
        assert.is_false(identity.same_slot(2))
        assert.is_false(identity.same_slot(3))
    end)

    it("reads this process's own identity through the process reader", function()
        assert.equals(identity.identity(), identity.process_identity(uv.os_getpid()))
        assert.is_true(identity.same_slot(uv.os_getpid()))
    end)
end)

describe("legacy daemon files", function()
    local root
    before_each(function() root = new_root() end)
    after_each(function()
        identity._process_probe = nil
        vim.fn.delete(root, "rf")
    end)

    local function L(name) return root .. "/.nvim/" .. paths.LEGACY[name] end

    it("a legacy lock with a dead holder is reclaimed with its handle", function()
        write(L("lock"), lock_rec(gone_start()))
        write(L("handle"), handle_rec(gone_start()))
        local removed = legacy.reclaim(root)
        assert.equals(2, #removed)
        assert.is_false(exists(L("lock")))
        assert.is_false(exists(L("handle")))
    end)

    it("a live holder's legacy lock and handle are kept", function()
        write(L("lock"), lock_rec(proc.self_start_time()))
        write(L("handle"), handle_rec(gone_start()))
        assert.equals(0, #legacy.reclaim(root))
        assert.is_true(exists(L("lock")))
        assert.is_true(exists(L("handle")))
    end)

    it("a legacy handle without a lock goes only when its process is gone", function()
        write(L("handle"), handle_rec(proc.self_start_time()))
        assert.equals(0, #legacy.reclaim(root))
        assert.is_true(exists(L("handle")))
        write(L("handle"), handle_rec(gone_start()))
        assert.equals(1, #legacy.reclaim(root))
        assert.is_false(exists(L("handle")))
    end)

    it("the legacy handle is never used to find or connect to a daemon", function()
        write(L("lock"), lock_rec(proc.self_start_time()))
        write(L("handle"), handle_rec(proc.self_start_time()))
        local st = require("loomworks.daemon.inspect").state(root)
        assert.equals("none", st.kind)
        assert.is_nil(st.handle)
        assert.is_nil(require("loomworks.daemon.handle").read(root))
    end)

    it("a live legacy daemon of this slot is stopped as another version; another slot's is not", function()
        write(L("lock"), lock_rec(proc.self_start_time()))
        local lb = require("loomworks.lock_break")
        local saved = lb.break_holder
        local broke
        lb.break_holder = function(info, ctx)
            broke = { pid = info.pid, root = ctx.root }
            return true
        end
        identity._process_probe = function() return "another user" end
        local o1 = legacy.stop_live(root)
        identity._process_probe = function() return identity.identity() end
        local o2 = legacy.stop_live(root)
        lb.break_holder = saved
        assert.equals("none", o1)
        assert.equals("stopped", o2)
        assert.equals(uv.os_getpid(), broke.pid)
        assert.equals(paths.norm_root(root), broke.root)
        -- An attached run of an earlier lw is not a daemon: left alone.
        write(L("lock"), lock_rec(proc.self_start_time(), { kind = "lw", mode = "attached" }))
        broke = nil
        lb.break_holder = function() broke = true; return true end
        local o3 = legacy.stop_live(root)
        lb.break_holder = saved
        assert.equals("none", o3)
        assert.is_nil(broke)
    end)

    it("housekeeping / lw cleanup: legacy logs as leftovers, the lock only of a dead holder", function()
        local hk = require("loomworks.housekeeping")
        write(L("log"), "old\n")
        write(L("log1"), "older\n")
        write(L("lock"), lock_rec(gone_start()))
        write(L("handle"), handle_rec(gone_start()))
        local items = hk_collect(root)
        local kinds = {}
        for _, it in ipairs(items) do kinds[it.path:match("[^/]+$")] = it.kind end
        assert.equals("runtime log", kinds["loomworks.daemon.log"])
        assert.equals("runtime log", kinds["loomworks.daemon.log.1"])
        assert.equals("daemon lock", kinds["loomworks.daemon.lock"])
        assert.equals("daemon handle", kinds["loomworks.daemon.json"])
        for _, it in ipairs(items) do assert.is_true((hk.remove(it))) end
        for _, n in ipairs({ "log", "log1", "lock", "handle" }) do assert.is_false(exists(L(n))) end
        -- A live holder's lock is not listed; recent logs wait for the age at startup.
        write(L("lock"), lock_rec(proc.self_start_time()))
        items = hk_collect(root)
        assert.equals(0, #items)
    end)

    it("another slot's files are never touched", function()
        local other = {}
        for _, ext in ipairs({ "lock", "json", "log", "log.1" }) do
            other[#other + 1] = write(root .. "/.nvim/loomworks.daemon-" .. OTHER .. "." .. ext,
                ext == "lock" and lock_rec(gone_start()) or (ext == "json" and handle_rec(gone_start()) or "x"))
        end
        assert.equals(0, #legacy.reclaim(root))
        assert.equals(0, #hk_collect(root))
        for _, p in ipairs(other) do assert.is_true(exists(p)) end
    end)

    it("a link at a legacy name is neither followed nor removed", function()
        local target = write(root .. "/victim.txt", "keep")
        local made = 0
        for _, n in ipairs({ "log", "lock", "handle" }) do
            if uv.fs_symlink(target, L(n)) then made = made + 1 end
        end
        if made == 0 then return end -- no symlink privilege on this host
        assert.equals(0, #legacy.logs(root))
        assert.is_nil(legacy.read_lock(root))
        assert.equals(0, #legacy.reclaim(root))
        assert.equals(0, #hk_collect(root))
        assert.equals("keep", assert(io.open(target, "rb")):read("*a"))
        for _, n in ipairs({ "log", "lock", "handle" }) do
            local st = uv.fs_lstat(L(n))
            if st then assert.equals("link", st.type) end
        end
    end)

    it("a .nvim that is a link or junction is not used", function()
        local real = mkdir(root .. "-real/.nvim")
        vim.fn.delete(root .. "/.nvim", "rf")
        local ok = uv.fs_symlink(real, root .. "/.nvim", { junction = true, dir = true })
        if not ok then vim.fn.delete(root .. "-real", "rf"); return end
        write(real .. "/" .. paths.LEGACY.log, "x")
        write(real .. "/" .. paths.LEGACY.lock, lock_rec(gone_start()))
        assert.is_nil(legacy.nvim_dir(root))
        assert.equals(0, #legacy.reclaim(root))
        assert.equals(0, #hk_collect(root))
        assert.is_true(exists(real .. "/" .. paths.LEGACY.log))
        assert.is_true(exists(real .. "/" .. paths.LEGACY.lock))
        vim.fn.delete(root .. "-real", "rf")
    end)
end)

describe("process scan", function()
    local saved = {}
    before_each(function()
        saved.processes, saved.probe = proc._processes_probe, proc._probe
        saved.cmdline, saved.is_daemon_for = proc.cmdline, proc.is_daemon_for
        proc._processes_probe = function() return { { pid = 4242001, name = "lw" }, { pid = 4242002, name = "lw" } } end
        proc._probe = function(pid) return "win:" .. pid end
        proc.cmdline = function(pid) return { "lw", "daemon", "run", "--root", "C:/ws/" .. pid } end
        proc.is_daemon_for = function() return true end
    end)
    after_each(function()
        proc._processes_probe, proc._probe = saved.processes, saved.probe
        proc.cmdline, proc.is_daemon_for = saved.cmdline, saved.is_daemon_for
        identity._process_probe = nil
    end)

    it("drops another slot's daemons and those whose identity cannot be read", function()
        identity._process_probe = function(pid)
            if pid == 4242001 then return identity.identity() end
            return nil
        end
        local found = require("loomworks.daemon.discover").scan()
        assert.equals(1, #found)
        assert.equals(4242001, found[1].pid)
        identity._process_probe = function(pid)
            return pid == 4242002 and "another slot" or identity.identity()
        end
        found = require("loomworks.daemon.discover").scan()
        assert.equals(1, #found)
        assert.equals(4242001, found[1].pid)
    end)
end)
