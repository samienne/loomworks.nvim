-- The workspace daemon's server, endpoint and authentication (spec §19.2,
-- §19.6–§19.8, §19.11 commands). In-process servers (with an injected exit)
-- cover the wire rules; real `lw daemon …` processes cover launch, stop,
-- stop --force / kill and one daemon per workspace. Every test leaves no
-- daemon process behind (asserted by pid and start time).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local protocol = require("loomworks.daemon.protocol")
local auth = require("loomworks.daemon.auth")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local endpoint = require("loomworks.daemon.endpoint")
local handle = require("loomworks.daemon.handle")
local rlock = require("loomworks.daemon.rlock")
local dpaths = require("loomworks.daemon.paths")
local trust = require("loomworks.trust")
local lock_record = require("loomworks.lock_record")
local proc = require("loomworks.proc")
local H = require("tests.daemon_helpers")
local uv = vim.uv or vim.loop

-- The suite runs every spec file at once: an in-process handshake can take
-- seconds on a loaded runner.
client.TIMEOUT_MS = 30000

local function with_key()
    local d = H.tmp()
    trust._set_key_path(d .. "/trust.key")
    return d
end

--- A raw (unauthenticated) peer: connects, records every byte it receives.
local function raw_peer(addr)
    local p = uv.new_pipe(false)
    local peer = { bytes = 0, closed = false, connected = false }
    p:connect(addr, function(err)
        if err then peer.closed = true; return end
        peer.connected = true
        p:read_start(function(rerr, chunk)
            if rerr or not chunk then peer.closed = true; return end
            peer.bytes = peer.bytes + #chunk
        end)
    end)
    peer.pipe = p
    function peer.send(s) p:write(s) end
    function peer.close() pcall(function() if not p:is_closing() then p:close() end end) end
    vim.wait(2000, function() return peer.connected or peer.closed end, 5)
    return peer
end

describe("protocol framing (§19.8)", function()
    it("round-trips and splits frames across chunks", function()
        local d = protocol.new_decoder()
        local wire = protocol.encode({ kind = "ping", req_id = 1 }) .. protocol.encode({ kind = "status", req_id = 2 })
        local msgs = assert(d:push(wire:sub(1, 7)))
        assert.equals(0, #msgs)
        msgs = assert(d:push(wire:sub(8)))
        assert.equals(2, #msgs)
        assert.equals("status", msgs[2].kind)
    end)
    it("refuses a frame over the pre-auth cap on its length prefix alone", function()
        local d = protocol.new_decoder()
        local msgs, err = d:push(tostring(protocol.PREAUTH_MAX + 1) .. "\n{")
        assert.is_nil(msgs)
        assert.equals("frame too large", err)
        d = protocol.new_decoder(protocol.MAX_FRAME)
        assert.truthy(d:push(tostring(protocol.PREAUTH_MAX + 1) .. "\n{"))
    end)
    it("refuses garbage", function()
        assert.is_nil((protocol.new_decoder():push("GET / HTTP/1.1\r\n")))
        assert.is_nil((protocol.new_decoder():push("2\n[]")))
        assert.is_nil((protocol.new_decoder():push(string.rep("9", 40))))
    end)
end)

describe("handshake proofs (§19.8)", function()
    it("are bound to the endpoint and the nonces, and compared in constant time", function()
        with_key()
        local K = assert(auth.key())
        local nc, ns = auth.nonce(), auth.nonce()
        assert.is_true(auth.valid_nonce(nc))
        local p = auth.server_proof(K, "E1", nc, ns)
        assert.is_true(auth.equal(p, auth.server_proof(K, "E1", nc, ns)))
        assert.is_false(auth.equal(p, auth.server_proof(K, "E2", nc, ns)))
        assert.is_false(auth.equal(p, auth.client_proof(K, "E1", nc, ns)))
        assert.is_false(auth.equal(p, p:sub(1, -2)))
        trust._set_key_path(nil)
    end)
end)

describe("daemon server (in-process)", function()
    local root, srv, exited
    before_each(function()
        with_key()
        root = H.workspace()
        exited = nil
        -- A real handshake must never hit the unauthenticated timeout on a
        -- loaded runner; the test of that timeout shortens it.
        srv = server_mod.new(root, { exit = function(code) exited = code end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("holds the runtime lock and publishes the handle", function()
        local lk = rlock.read(root)
        assert.equals("daemon", lk.kind)
        assert.equals("daemon", lk.mode)
        local h = handle.read(root)
        assert.is_true(h.valid)
        assert.equals(srv.pid, h.pid)
        assert.equals(srv.address, h.endpoint)
        assert.equals(protocol.VERSION, h.protocol)
        assert.equals(lk.lock_nonce, h.lock_nonce)
        assert.equals(0, h.clients)
        -- One runtime per workspace: a second daemon refuses with EXIT_HELD.
        local s2 = server_mod.new(root, { exit = function() end })
        local ok, _, code = s2:start()
        assert.is_nil(ok)
        assert.equals(server_mod.EXIT_HELD, code)
    end)

    it("authenticates a client, answers ping and status, counts it", function()
        local conn = assert(client.session(srv.address))
        assert.equals(protocol.VERSION, conn.challenge.protocol)
        assert.truthy(conn.welcome)
        assert.truthy(client.request(conn, { kind = "ping" }))
        local st = assert(client.request(conn, { kind = "status" }))
        assert.equals(1, st.clients)
        assert.equals(srv.pid, st.pid)
        assert.equals(1, handle.read(root).clients)
        local _, err = client.request(conn, { kind = "build" })
        assert.truthy(tostring(err):find("unknown request kind", 1, true))
        conn:close()
        assert.is_true(vim.wait(2000, function() return srv:client_count() == 0 end, 10))
        assert.equals(0, handle.read(root).clients)
    end)

    it("a client with another key is refused; a squatter cannot impersonate the daemon", function()
        local _, err = client.session(srv.address, { key = string.rep("x", 32) })
        -- The client cannot verify the daemon's proof under its key: untrusted.
        assert.equals(client.ERR_UNTRUSTED, err)
        assert.equals(0, srv:client_count())
        -- A fake server at another endpoint that cannot prove K.
        local fake_addr = H.is_win and ([[\\.\pipe\lwtest-]] .. dpaths.short_hash(root)) or (H.tmp() .. "/f.sock")
        local fake = uv.new_pipe(false)
        assert(fake:bind(fake_addr))
        local got = {}
        fake:listen(4, function()
            local c = uv.new_pipe(false)
            fake:accept(c)
            c:read_start(function(_, chunk)
                if chunk then
                    got[#got + 1] = chunk
                    c:write(protocol.encode({ kind = "challenge", server_nonce = auth.nonce(),
                        server_proof = string.rep("0", 64) }))
                end
            end)
        end)
        local conn, e2 = client.session(fake_addr)
        assert.is_nil(conn)
        assert.equals(client.ERR_UNTRUSTED, e2)
        vim.wait(200, function() return false end, 10)
        -- It received only the hello (no proof of the client's own).
        local all = table.concat(got)
        assert.truthy(all:find('"hello"', 1, true))
        assert.is_nil(all:find('"auth"', 1, true))
        pcall(function() fake:close() end)
    end)

    it("a forged client proof gets no welcome and is closed", function()
        local peer = raw_peer(srv.address)
        peer.send(protocol.encode({ kind = "hello", protocol = 2, nonce = auth.nonce() }))
        vim.wait(500, function() return peer.bytes > 0 end, 10)
        local challenge_bytes = peer.bytes
        assert.truthy(challenge_bytes > 0)
        peer.send(protocol.encode({ kind = "auth", client_proof = string.rep("a", 64) }))
        assert.is_true(vim.wait(2000, function() return peer.closed end, 10))
        assert.equals(challenge_bytes, peer.bytes)
        assert.equals(0, srv:client_count())
    end)

    it("before authentication accepts only hello/auth, caps frames at 64 KiB and times out", function()
        local p1 = raw_peer(srv.address)
        p1.send(protocol.encode({ kind = "status", req_id = 1 }))
        assert.is_true(vim.wait(2000, function() return p1.closed end, 10))
        assert.equals(0, p1.bytes)
        local p2 = raw_peer(srv.address)
        p2.send(tostring(protocol.PREAUTH_MAX + 1) .. "\n")
        assert.is_true(vim.wait(2000, function() return p2.closed end, 10))
        assert.equals(0, p2.bytes)
        srv.auth_timeout_ms = 500
        local p3 = raw_peer(srv.address) -- says nothing
        assert.is_true(vim.wait(8000, function() return p3.closed end, 10))
        assert.equals(0, p3.bytes)
    end)

    it("a peer that never authenticates receives 0 bytes while a client talks", function()
        local eaves = raw_peer(srv.address)
        local conn = assert(client.session(srv.address))
        for _ = 1, 5 do assert(client.request(conn, { kind = "status" })) end
        conn:close()
        -- Then the eavesdropper is closed by the unauthenticated timeout.
        srv.auth_timeout_ms = 500
        local late = raw_peer(srv.address)
        assert.is_true(vim.wait(8000, function() return late.closed end, 10))
        assert.equals(0, late.bytes)
        eaves.close()
        assert.equals(0, eaves.bytes)
    end)

    it("stop ends the daemon: handle, socket and lock removed, exit 0", function()
        local addr = srv.address
        assert(client.call(addr, "stop"))
        assert.is_true(vim.wait(2000, function() return exited ~= nil end, 10))
        assert.equals(0, exited)
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
        if not H.is_win then assert.is_nil(uv.fs_lstat(addr)) end
    end)

    it("retire: exits once the last client disconnects", function()
        local conn = assert(client.session(srv.address))
        assert(client.request(conn, { kind = "retire" }))
        assert.is_nil(exited)
        conn:close()
        assert.is_true(vim.wait(2000, function() return exited ~= nil end, 10))
        assert.equals(0, exited)
    end)

    it("a replaced runtime-lock record means lost authority: exit 1, nothing touched", function()
        local path = dpaths.lock_path(root)
        local rec = lock_record.new("daemon", { mode = "daemon" })
        rec.pid = 1
        local f = assert(io.open(path, "w")); f:write(vim.json.encode(rec)); f:close()
        assert.is_true(vim.wait(2000, function() return exited ~= nil end, 10))
        assert.equals(1, exited)
        -- The handle and the new holder's record are left alone.
        assert.truthy(handle.read(root))
        assert.equals(rec.lock_nonce, rlock.read(root).lock_nonce)
        os.remove(path)
        handle.remove(root)
    end)

    it("rewrites a removed handle on its heartbeat", function()
        handle.remove(root)
        assert.is_true(vim.wait(2000, function() return handle.read(root) ~= nil end, 10))
    end)

    if H.is_win then
        it("the named pipe carries the protected owner/SYSTEM-only DACL (§19.7)", function()
            local sddl = assert(endpoint.read_dacl(srv.listener))
            local sid = assert(endpoint.user_sid())
            -- The user as Windows names it back (a SID, or an alias such as
            -- LA for the built-in Administrator a CI runner runs as).
            local user = assert(endpoint._normalize_sddl("D:(A;;GA;;;" .. sid .. ")")):match(";;;([^)]+)%)$")
            assert.truthy(sddl:find("^D:P"), sddl)
            local aces = {}
            for ace in sddl:gmatch("%(([^)]*)%)") do aces[#aces + 1] = ace end
            assert.equals(3, #aces, sddl)
            local function has(kind, who)
                for _, a in ipairs(aces) do
                    local k, rights, w2 = a:match("^(%a);;(%u+);;;(.+)$")
                    if k == kind and w2 == who and (rights == "GA" or rights == "FA") then return true end
                end
                return false
            end
            assert.is_true(has("D", "NU"), sddl)
            assert.is_true(has("A", user), sddl)
            assert.is_true(has("A", "SY"), sddl)
            assert.is_nil(sddl:find(";;;WD)", 1, true), sddl)
            assert.is_nil(sddl:find(";;;AN)", 1, true), sddl)
            assert.is_nil(sddl:find(";;;BA)", 1, true), sddl)
        end)
    else
        it("the socket lives in a 0700 per-user directory, path within sun_path (§19.7)", function()
            local dir = srv.address:match("^(.*)/[^/]+$")
            local st = uv.fs_lstat(dir)
            assert.equals("directory", st.type)
            assert.equals(tonumber("700", 8), st.mode % 512)
            assert.truthy(#srv.address <= endpoint.SUN_PATH_MAX)
            assert.equals("socket", uv.fs_lstat(srv.address).type)
        end)
    end
end)

describe("endpoint address", function()
    it("a deep workspace root still gives a short endpoint", function()
        local deep = "/" .. string.rep("very-long-directory-name/", 12) .. "ws"
        local a = endpoint.address(deep)
        if H.is_win then
            assert.truthy(a:match("^\\\\%.\\pipe\\loomworks%-%x+$"), a)
        else
            assert.truthy(#a <= endpoint.SUN_PATH_MAX, a)
        end
        assert.are_not.equal(a, endpoint.address(deep .. "2"))
    end)
end)

describe("lw daemon run | stop | kill | restart (real processes)", function()
    local root, env
    before_each(function()
        root = H.workspace()
        env = H.env({ LW_TEST_HEARTBEAT_MS = "300", LW_TEST_DAEMON_TICK_MS = "300" })
    end)
    after_each(function()
        H.track_root(root)
        H.cleanup()
    end)

    local function lw(args) return H.lw(args, { env = env, cwd = root }) end

    it("restart launches a detached daemon that outlives lw and holds no std handle", function()
        local r = lw({ "daemon", "restart" })
        assert.equals(0, r.code, r.stderr)
        local lk = H.track_root(root)
        assert.truthy(lk, "no runtime lock")
        -- `lw` returned (both its pipes reached EOF): the daemon holds none of
        -- them (the 2m56s `lw build | tail` spike bug, §19.10).
        assert.truthy(r.ms < 15000, "lw took " .. r.ms .. " ms")
        assert.truthy(r.stdout:find("started the workspace daemon (pid " .. lk.pid, 1, true), r.stdout)
        assert.is_true(H.alive(lk.pid, lk.start_time))
        local s = lw({ "daemon", "status" })
        assert.truthy(s.stdout:find("answers      1 client", 1, true), s.stdout)
        -- stop ends the process.
        local st = lw({ "daemon", "stop" })
        assert.equals(0, st.code, st.stderr)
        assert.is_true(vim.wait(5000, function() return not H.alive(lk.pid, lk.start_time) end, 50))
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
        -- Stopping when none runs succeeds with nothing to do.
        st = lw({ "daemon", "stop" })
        assert.equals(0, st.code)
        assert.truthy(st.stdout:find("no workspace daemon is running", 1, true))
    end)

    it("is spawned detached, hidden, without std handles, in the state directory (§19.10)", function()
        -- (That the workspace can be deleted under a running daemon — it is
        -- nobody's cwd — is checked with real processes by the lifetime spec.)
        local seen
        local real = uv.spawn
        uv.spawn = function(exe, o, cb) seen = { exe = exe, o = o }; return nil, "stubbed" end
        local ok, err = pcall(require("loomworks.daemon.launch").spawn, root)
        uv.spawn = real
        assert.is_true(ok, err)
        assert.truthy(seen, "spawn not called")
        local o = seen.o
        assert.equals(dpaths.state_dir(), o.cwd)
        assert.is_true(o.detached)
        assert.is_true(o.hide)
        assert.is_nil(o.stdio[1]); assert.is_nil(o.stdio[2]); assert.is_nil(o.stdio[3])
        local args = table.concat(o.args, " ")
        assert.truthy(args:find("daemon run --root " .. root, 1, true), args)
        local keys, lw_root = {}, nil
        for _, kv in ipairs(o.env) do
            local k, v = kv:match("^([^=]*)=(.*)$")
            local key = H.is_win and k:upper() or k
            assert.is_nil(keys[key], "duplicate environment entry " .. k)
            keys[key] = true
            if key == "LW_ROOT" then lw_root = v end
        end
        assert.equals(root, lw_root)
    end)

    it("names the same per-user files for every spelling of the root", function()
        local alias = root .. "/."
        assert.equals(dpaths.root_hash(root), dpaths.root_hash(alias))
        if H.is_win then assert.equals(dpaths.root_hash(root), dpaths.root_hash(root:upper())) end
    end)

    it("concurrent launches leave exactly one daemon; the others exit EXIT_HELD", function()
        local codes, pids = {}, {}
        local args = { "--headless", "-u", "NONE", "-l", H.CLI, "daemon", "run", "--root", root }
        for i = 1, 3 do
            local h, pid = uv.spawn(vim.v.progpath, { args = args, env = H.env_list(env.vars), cwd = H.tmp() },
                function(code) codes[i] = code end)
            assert(h)
            pids[i] = pid
            H.track(pid)
        end
        assert.is_true(vim.wait(20000, function()
            local n = 0
            for i = 1, 3 do if codes[i] ~= nil then n = n + 1 end end
            return n == 2
        end, 50), "two of three should have exited")
        local held, running = 0, 0
        for i = 1, 3 do
            if codes[i] == server_mod.EXIT_HELD then held = held + 1 elseif codes[i] == nil then running = running + 1 end
        end
        assert.equals(2, held)
        assert.equals(1, running)
        local lk = rlock.read(root)
        assert.truthy(vim.tbl_contains(pids, lk.pid))
        assert.equals(0, lw({ "daemon", "stop" }).code)
    end)

    it("a suspended daemon: stop reports it not responding; stop --force kills and clears it", function()
        assert.equals(0, lw({ "daemon", "restart" }).code)
        local lk = H.track_root(root)
        assert.is_true(proc._suspend(lk.pid))
        local t = os.time() - 120
        uv.fs_utime(dpaths.lock_path(root), t, t)
        local r = lw({ "daemon", "stop" })
        assert.equals(1, r.code)
        assert.truthy(r.stderr:find("is not responding — recover with: lw daemon stop --force", 1, true), r.stderr)
        assert.is_true(H.alive(lk.pid, lk.start_time))
        r = lw({ "daemon", "stop", "--force" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stderr:find("killing the workspace daemon", 1, true), r.stderr)
        assert.is_false(H.alive(lk.pid, lk.start_time))
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
    end)

    it("kill stops a live daemon without asking; the files are cleared", function()
        assert.equals(0, lw({ "daemon", "restart" }).code)
        local lk = H.track_root(root)
        local r = lw({ "daemon", "kill" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("killed the workspace daemon (pid " .. lk.pid, 1, true), r.stdout)
        assert.is_false(H.alive(lk.pid, lk.start_time))
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
    end)

    it("a killed daemon's files read as stale; stop clears them", function()
        assert.equals(0, lw({ "daemon", "restart" }).code)
        local lk = H.track_root(root)
        proc.kill_tree(lk.pid, lk.start_time)
        local s = lw({ "status" })
        assert.truthy(s.stdout:find("stale daemon handle", 1, true), s.stdout)
        local r = lw({ "daemon", "stop" })
        assert.equals(0, r.code, r.stderr)
        assert.truthy(r.stdout:find("cleared a stale daemon handle", 1, true))
        assert.is_nil(handle.read(root))
        assert.is_nil(rlock.read(root))
        -- And a new daemon starts at once (the dead holder's lock is reclaimed).
        assert.equals(0, lw({ "daemon", "restart" }).code)
        H.track_root(root)
        assert.equals(0, lw({ "daemon", "stop" }).code)
    end)

    it("a daemon on another host is never stopped or killed from here", function()
        local rec = lock_record.new("daemon", { mode = "daemon" })
        rec.host, rec.kind = "OTHERHOST", "daemon"
        local f = assert(io.open(dpaths.lock_path(root), "w")); f:write(vim.json.encode(rec)); f:close()
        for _, args in ipairs({ { "daemon", "stop" }, { "daemon", "stop", "--force" }, { "daemon", "kill" } }) do
            local r = lw(args)
            assert.equals(1, r.code)
            assert.truthy(r.stderr:find("OTHERHOST", 1, true), r.stderr)
        end
        assert.truthy(rlock.read(root))
        os.remove(dpaths.lock_path(root))
    end)
end)

describe("version handshake (§19.9)", function()
    local ensure = require("loomworks.daemon.ensure")
    local root, srv, exited
    before_each(function()
        with_key()
        root = H.workspace()
        exited = nil
        srv = server_mod.new(root, { exit = function(code) exited = code end, tick_ms = 100 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("a matching daemon is used as is", function()
        local conn = assert(client.session(srv.address))
        assert.equals("match", (ensure.reconcile(root, conn)))
        conn:close()
        assert.is_nil(exited)
    end)

    it("an idle mismatched daemon is stopped and replaced", function()
        srv.identity = "0.1.0"
        local launched
        local conn = assert(client.session(srv.address))
        local out = ensure.reconcile(root, conn, { launch = function(r) launched = r; return true end })
        assert.equals("restarted", out)
        assert.equals(0, exited)
        assert.equals(root, launched)
        assert.is_nil(rlock.read(root))
    end)

    it("a busy mismatched daemon is retired, never stopped; the command bypasses it", function()
        srv.identity = "0.1.0"
        local other = assert(client.session(srv.address))
        local conn = assert(client.session(srv.address))
        local out, line = ensure.reconcile(root, conn, { launch = function() error("must not launch") end })
        assert.equals("bypass", out)
        assert.equals("lw: the workspace daemon runs lw v0.1.0 and is busy — running this command without it; "
            .. "it restarts when idle", line)
        vim.wait(300, function() return false end, 10)
        assert.is_nil(exited)
        assert.is_true(srv.retiring)
        other:close()
        assert.is_true(vim.wait(2000, function() return exited ~= nil end, 10))
        assert.equals(0, exited)
    end)

    it("a daemon with newer schemas is never stopped by an older client", function()
        local s = require("loomworks.daemon.version").schemas()
        srv.schemas = { user = s.user + 1, cache = s.cache }
        srv.identity = "9.0.0"
        local conn = assert(client.session(srv.address))
        local out, line = ensure.reconcile(root, conn)
        assert.equals("newer", out)
        assert.truthy(line:find("update lw", 1, true))
        vim.wait(200, function() return false end, 10)
        assert.is_nil(exited)
        assert.is_false(srv.retiring)
    end)
end)

describe("daemon processes", function()
    it("none was left running by any test of this file", function()
        H.cleanup()
        assert.equals(0, H.leftovers, "a test left a daemon process running")
    end)
end)
