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

    it("closes the token handle when reading the token raises", function()
        local ok, ffi = pcall(require, "ffi")
        if not ok then return end
        local closed = {}
        local w = {
            ffi = ffi,
            adv = {
                OpenProcessToken = function(_, _, tok) tok[0] = ffi.cast("void*", 1234); return 1 end,
                GetTokenInformation = function() error("ffi boom") end,
            },
            close = function(h) closed[#closed + 1] = tonumber(ffi.cast("intptr_t", h)) end,
        }
        local I, err = identity._win_token_identity(w, nil)
        assert.is_nil(I)
        assert.truthy(tostring(err):find("ffi boom", 1, true))
        assert.same({ 1234 }, closed)
        -- A failed open has no handle to close.
        w.adv.OpenProcessToken = function() return 0 end
        assert.is_nil((identity._win_token_identity(w, nil)))
        assert.equals(1, #closed)
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

    local function cmd_host()
        local out = {}
        return { out = function(l) out[#out + 1] = l end, note = function() end,
            die = function(m) error("die: " .. m, 0) end }, out
    end

    it("lw daemon stop / kill / --force stop a live legacy daemon of this slot", function()
        local cmd = require("loomworks.daemon.command")
        local lb = require("loomworks.lock_break")
        local saved = lb.break_holder
        identity._process_probe = function() return identity.identity() end
        for _, opts in ipairs({ {}, { force = true }, { kill = true } }) do
            write(L("lock"), lock_rec(proc.self_start_time()))
            local broke
            lb.break_holder = function(info) broke = info.pid; return true end
            local host, out = cmd_host()
            local ok, code = pcall(cmd.stop, root, host, opts)
            lb.break_holder = saved
            assert.is_true(ok, tostring(code))
            assert.equals(0, code)
            assert.equals(uv.os_getpid(), broke)
            local text = table.concat(out, "\n")
            assert.is_truthy(text:find("stopped the workspace daemon of an earlier lw (pid "
                .. uv.os_getpid() .. ")", 1, true), text)
            assert.is_falsy(text:find("no workspace daemon is running", 1, true), text)
        end
    end)

    it("lw daemon stop reports a legacy daemon it could not stop, and leaves another slot's alone", function()
        local cmd = require("loomworks.daemon.command")
        local lb = require("loomworks.lock_break")
        local saved = lb.break_holder
        write(L("lock"), lock_rec(proc.self_start_time()))
        identity._process_probe = function() return identity.identity() end
        lb.break_holder = function() return false, "it would not go" end
        local host = cmd_host()
        local ok, err = pcall(cmd.stop, root, host, {})
        lb.break_holder = saved
        assert.is_false(ok)
        assert.is_truthy(tostring(err):find("it would not go", 1, true))
        -- Another slot's legacy daemon: not stopped, nothing to do here.
        identity._process_probe = function() return "another user" end
        local broke
        lb.break_holder = function() broke = true; return true end
        local host2, out2 = cmd_host()
        local code = cmd.stop(root, host2, {})
        lb.break_holder = saved
        assert.equals(0, code)
        assert.is_nil(broke)
        assert.is_truthy(table.concat(out2, "\n"):find("no workspace daemon is running", 1, true))
        assert.is_true(exists(L("lock")))
    end)

    it("a legacy holder of another host or with no start time is neither stopped nor reported", function()
        local cmd = require("loomworks.daemon.command")
        local lb = require("loomworks.lock_break")
        local saved = lb.break_holder
        identity._process_probe = function() return identity.identity() end
        for _, extra in ipairs({ { host = "some-other-host" }, { start_time = vim.NIL } }) do
            write(L("lock"), lock_rec(proc.self_start_time(), extra))
            local broke
            lb.break_holder = function() broke = true; return false, "refused" end
            local host, out = cmd_host()
            local ok, code = pcall(cmd.stop, root, host, {})
            lb.break_holder = saved
            assert.is_true(ok, tostring(code))
            assert.equals(0, code)
            assert.is_nil(broke)
            local text = table.concat(out, "\n")
            assert.is_falsy(text:find("earlier lw", 1, true), text)
            assert.is_truthy(text:find("no workspace daemon is running", 1, true), text)
            local host2, out2 = cmd_host()
            cmd.status(root, host2)
            local stext = table.concat(out2, "\n")
            assert.is_falsy(stext:find("Legacy", 1, true), stext)
            assert.is_true(exists(L("lock")))
        end
    end)

    it("lw daemon restart stops a live legacy daemon before launching, and does not launch when that fails",
        function()
        local cmd = require("loomworks.daemon.command")
        local lb = require("loomworks.lock_break")
        local launch = require("loomworks.daemon.launch")
        local saved, saved_launch = lb.break_holder, launch.launch
        identity._process_probe = function() return identity.identity() end
        write(L("lock"), lock_rec(proc.self_start_time()))
        local seq = {}
        lb.break_holder = function() seq[#seq + 1] = "stop"; return true end
        launch.launch = function()
            seq[#seq + 1] = "launch"
            return true, { handle = { pid = 1234 } }
        end
        local host = cmd_host()
        local ok, err = pcall(cmd.restart, root, host, {})
        assert.is_true(ok, tostring(err))
        assert.same({ "stop", "launch" }, seq)
        seq = {}
        lb.break_holder = function() seq[#seq + 1] = "stop"; return false, "it would not go" end
        local ok2, err2 = pcall(cmd.restart, root, cmd_host(), {})
        lb.break_holder, launch.launch = saved, saved_launch
        assert.is_false(ok2)
        assert.is_truthy(tostring(err2):find("it would not go", 1, true))
        assert.same({ "stop" }, seq)
    end)

    it("lw daemon status reports a live legacy daemon of this slot without connecting", function()
        local cmd = require("loomworks.daemon.command")
        write(L("lock"), lock_rec(proc.self_start_time()))
        write(L("handle"), handle_rec(proc.self_start_time()))
        identity._process_probe = function() return identity.identity() end
        local saved = cmd.request
        local asked
        cmd.request = function() asked = true end
        local host, out = cmd_host()
        cmd.status(root, host)
        cmd.request = saved
        assert.is_nil(asked)
        local text = table.concat(out, "\n")
        assert.is_truthy(text:find("daemon of an earlier lw (pid " .. uv.os_getpid()
            .. ", legacy runtime lock) — stop it with: lw daemon stop", 1, true), text)
        -- Another slot's: not reported.
        identity._process_probe = function() return "another user" end
        local host2, out2 = cmd_host()
        cmd.status(root, host2)
        assert.is_falsy(table.concat(out2, "\n"):find("earlier lw", 1, true))
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

    it("lw cleanup keeps the legacy logs while a live holder has the legacy lock", function()
        local hk = require("loomworks.housekeeping")
        write(L("log"), "live\n")
        write(L("log1"), "live older\n")
        write(L("lock"), lock_rec(proc.self_start_time()))
        assert.equals(0, #hk_collect(root))
        -- Unreadable lock state: kept too.
        write(L("lock"), "not a lock record")
        assert.equals(0, #hk_collect(root))
        -- Listed while the holder was dead; a holder appearing before the
        -- removal keeps them.
        write(L("lock"), lock_rec(gone_start()))
        local items = hk_collect(root)
        write(L("lock"), lock_rec(proc.self_start_time()))
        for _, it in ipairs(items) do
            if it.kind == "runtime log" then assert.is_false((hk.remove(it))) end
        end
        assert.is_true(exists(L("log"))); assert.is_true(exists(L("log1")))
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

describe("peer check (§19.7, Windows)", function()
    local endpoint = require("loomworks.daemon.endpoint")
    local server_mod = require("loomworks.daemon.server")
    local client = require("loomworks.daemon.client")
    local trust = require("loomworks.trust")
    local H = require("tests.daemon_helpers")
    local CLIENT_PID, SERVER_PID = 7700001, 7700002
    local root, srv, logs

    --- Peer pids per side (the daemon reads its client's, a client its
    --- server's), identities per pid.
    local function stub(ids)
        endpoint._force_peer_check = true
        endpoint._peer_pid_probe = function(_, side)
            return side == "client" and CLIENT_PID or SERVER_PID
        end
        identity._process_probe = function(pid) return ids[pid] end
    end

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        logs = {}
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function(l) logs[#logs + 1] = l end })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        endpoint._force_peer_check, endpoint._peer_pid_probe = nil, nil
        identity._process_probe = nil
        trust._set_key_path(nil)
    end)

    local function connect()
        local res
        client.connect(srv.address, { timeout_ms = 30000 }, function(c, e, d) res = { c, e, d } end)
        vim.wait(30000, function() return res ~= nil end, 5)
        assert.truthy(res, "connect did not finish")
        if res[1] then res[1]:close() end
        return res
    end

    local function others(me)
        -- Another user; this user elevated or not (whichever this is not);
        -- an unreadable token.
        local flip = me:find(" elevated$") and me:gsub(" elevated$", " standard") or (me .. "-elevated")
        return { "S-1-5-21-9-9-9-1002 standard", flip, false }
    end

    it("peer_check refuses another SID, another elevation, an unreadable token or pid", function()
        local me = identity.identity()
        local function check(theirs, pid_ok)
            endpoint._force_peer_check = true
            endpoint._peer_pid_probe = function()
                if pid_ok ~= false then return 42 end
                return nil, "no pid"
            end
            identity._process_probe = function() return theirs end
            return endpoint.peer_check({}, "client")
        end
        assert.is_true((check(me)))
        local ok, why = check("S-1-5-21-9-9-9-1002 standard")
        assert.is_false(ok)
        assert.truthy(why:find("another user or elevation", 1, true), why)
        assert.is_false((check(others(me)[2])))
        ok, why = check(nil)
        assert.is_false(ok)
        assert.truthy(why:find("cannot read the token", 1, true), why)
        assert.is_false((check(me, false)))
    end)

    it("the daemon refuses a client of another SID, elevation or with an unreadable token before reading", function()
        local handshakes = 0
        local real = srv._handshake
        srv._handshake = function(...) handshakes = handshakes + 1; return real(...) end
        local me = identity.identity()
        for _, other in ipairs(others(me)) do
            stub({ [CLIENT_PID] = other or nil, [SERVER_PID] = me })
            local res = connect()
            assert.is_nil(res[1])
            assert.are_not.equals(client.ERR_UNTRUSTED, res[2]) -- the client's own check passed
        end
        assert.equals(0, handshakes)
        local refused = 0
        for _, l in ipairs(logs) do
            if l:find("refused a connection", 1, true) then refused = refused + 1 end
        end
        assert.equals(3, refused, vim.inspect(logs))
        -- A peer of this slot is served.
        stub({ [CLIENT_PID] = me, [SERVER_PID] = me })
        local res = connect()
        assert.truthy(res[1], vim.inspect(res))
    end)

    it("a client refuses a daemon of another SID, elevation or with an unreadable token before hello", function()
        local handshakes = 0
        local real = srv._handshake
        srv._handshake = function(...) handshakes = handshakes + 1; return real(...) end
        local me = identity.identity()
        for _, other in ipairs(others(me)) do
            stub({ [CLIENT_PID] = me, [SERVER_PID] = other or nil })
            local res = connect()
            assert.is_nil(res[1])
            assert.equals(client.ERR_UNTRUSTED, res[2])
            assert.truthy(tostring(res[3]):find("server process", 1, true), tostring(res[3]))
        end
        assert.equals(0, handshakes)
    end)

    if IS_WIN then
        it("reads the real peer process ids of both ends of the pipe", function()
            local seen = {}
            identity._process_probe = function(pid)
                seen[#seen + 1] = pid
                return identity.identity()
            end
            local res = connect()
            assert.truthy(res[1], vim.inspect(res))
            -- The daemon read its client's pid and the client its server's:
            -- both are this process.
            assert.equals(2, #seen, vim.inspect(seen))
            assert.equals(uv.os_getpid(), seen[1])
            assert.equals(uv.os_getpid(), seen[2])
        end)

        it("starting the daemon opens no connection to its own pipe", function()
            -- A stat of the pipe's name opens (connects) an instance: the
            -- daemon used to accept two phantom clients of its own at start.
            vim.wait(300)
            assert.equals(0, vim.tbl_count(srv.conns))
        end)

        it("every pipe instance, not only the first, carries the restricted DACL (audit 1b)", function()
            local first = assert(endpoint.read_dacl(srv.listener))
            assert.truthy(first:find("^D:P"), first)
            -- libuv creates the first instance at bind and the others later,
            -- one per pending accept (4 at first, a new one after each
            -- accept): more connections than that reach later instances.
            local peers = {}
            for i = 1, 6 do
                local p = uv.new_pipe(false)
                local done
                p:connect(srv.address, function(err) done = err or true end)
                vim.wait(5000, function() return done ~= nil end, 5)
                assert.is_true(done, tostring(done))
                peers[i] = p
            end
            vim.wait(5000, function() return vim.tbl_count(srv.conns) >= 6 end, 5)
            local n = 0
            for conn in pairs(srv.conns) do
                assert.equals(first, endpoint.read_dacl(conn.sock))
                n = n + 1
            end
            assert.truthy(n >= 6, tostring(n))
            for _, p in ipairs(peers) do pcall(function() p:close() end) end
        end)
    end
end)

describe("trust key ownership (formats.md §2.1, POSIX)", function()
    local trust = require("loomworks.trust")
    local saved = {}
    local dir = "/home/u/.local/share/loomworks"
    local key = dir .. "/trust.key"
    local fs
    before_each(function()
        saved.lstat, saved.euid = trust._lstat, trust._euid
        fs = {
            [dir] = { type = "directory", uid = 1000, mode = tonumber("40700", 8) },
            [key] = { type = "file", uid = 1000, mode = tonumber("100600", 8) },
        }
        trust._force_posix_owner_check = true
        trust._lstat = function(p) return fs[p] end
        trust._euid = function() return 1000 end
        trust._set_key_path(key)
    end)
    after_each(function()
        trust._lstat, trust._euid = saved.lstat, saved.euid
        trust._force_posix_owner_check = nil
        trust._set_key_path(nil)
    end)

    it("accepts the euid's key in its private directory", function()
        assert.is_true(trust._check_owner(dir, "directory"))
        assert.is_true(trust._check_owner(key, "file"))
    end)

    it("refuses a key or directory of another owner (root with the user's $HOME)", function()
        trust._euid = function() return 0 end
        local k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find(dir, 1, true) and err:find("not this process's effective uid", 1, true), err)
        trust._euid = function() return 1000 end
        fs[key].uid = 1001
        k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find(key, 1, true), err)
    end)

    it("refuses a group- or other-writable key or directory", function()
        fs[key].mode = tonumber("100620", 8)
        local k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find(key, 1, true) and err:find("writable by group or others", 1, true), err)
        fs[key].mode = tonumber("100602", 8)
        assert.is_nil((trust.key()))
        fs[key].mode = tonumber("100644", 8) -- only writability is checked
        assert.is_true(trust._check_owner(key, "file"))
        fs[dir].mode = tonumber("40770", 8)
        k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find(dir, 1, true), err)
    end)

    it("refuses a link at the key or the directory", function()
        fs[key] = { type = "link", uid = 1000, mode = tonumber("120777", 8) }
        local k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find("not a real file", 1, true), err)
        fs[key] = nil
        fs[dir] = { type = "link", uid = 1000, mode = tonumber("120777", 8) }
        k, err = trust.key()
        assert.is_nil(k)
        assert.truthy(err:find("not a real directory", 1, true), err)
    end)
end)

describe("POSIX effective uid (§19.7)", function()
    after_each(function() identity._euid_override = nil end)
    if not IS_WIN then
        it("names the socket directory by the effective uid", function()
            identity._euid_override = 4321
            local c = require("loomworks.daemon.endpoint")._posix_candidates("/home/u/ws")
            assert.truthy(c[#c].dir:find("loomworks%-4321$"), c[#c].dir)
        end)
    end
    it("identity.euid reads the effective uid on POSIX and has none on Windows", function()
        local e = identity.euid()
        if IS_WIN then assert.is_nil(e) else assert.equals("number", type(e)) end
    end)
end)
