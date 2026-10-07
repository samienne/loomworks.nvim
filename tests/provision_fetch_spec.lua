-- The plugin-managed lw (spec §19.16 "Host binary", step 5h.3): SHA-256 of
-- binary data, the download into the managed slot (verify, then rename;
-- nothing left behind on failure; one download per hash) and the pruning of
-- other managed binaries (deletion safety, CLAUDE.md rule 11).

local uv = vim.uv or vim.loop
local sha256 = require("loomworks.provision.sha256")
local fetch = require("loomworks.provision.fetch")
local cache = require("loomworks.provision.cache")
local managed = require("loomworks.provision.managed")
local binsel = require("loomworks.provision.select")

local is_win = package.config:sub(1, 1) == "\\"

local function write(p, data)
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb")); f:write(data); f:close()
end
local function read(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end
local function exists(p) return uv.fs_lstat(p) ~= nil end
local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (uv.fs_realpath(d) or d):gsub("\\", "/")
end
local function listdir(d)
    local out = {}
    for name in vim.fs.dir(d) do out[#out + 1] = name end
    table.sort(out)
    return out
end

describe("provision.sha256", function()
    it("matches the FIPS 180-2 known answers (pure Lua)", function()
        assert.equals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", sha256.lua(""))
        assert.equals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256.lua("abc"))
        assert.equals("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            sha256.lua("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
        assert.equals("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
            sha256.lua(string.rep("a", 1000000)))
    end)

    it("hashes NUL and high bytes, at every padding boundary, like vim.fn.sha256 where that is faithful", function()
        assert.equals(sha256.PROBE_SHA256, sha256.lua(sha256.PROBE))
        -- On the Neovim versions tested a Lua string with NULs reaches
        -- sha256() as a Blob and hashes faithfully; native_ok() checks it.
        assert.is_true(sha256.native_ok())
        for n = 0, 200 do
            local s = string.rep("\0\255x\128", n):sub(1, n)
            assert.equals(sha256.lua(s), vim.fn.sha256(s), "length " .. n)
            assert.equals(sha256.lua(s), sha256.hex(s))
        end
    end)

    it("hashes a file", function()
        local d = tmpdir()
        write(d .. "/b", sha256.PROBE)
        assert.equals(sha256.PROBE_SHA256, (sha256.file(d .. "/b")))
        local got, err = sha256.file(d .. "/missing")
        assert.is_nil(got); assert.truthy(err:find("cannot read", 1, true))
        vim.fn.delete(d, "rf")
    end)
end)

describe("provision.fetch", function()
    local data, mirror
    local payload = "\127ELF\0\0lw-binary\0" .. string.rep("\255\0", 300)
    local good = sha256.lua(payload)
    local function want(o)
        local w = { sha256 = good, version = "0.1.50", asset = "lw-linux-x86_64" }
        for k, v in pairs(o or {}) do w[k] = v end
        return w
    end

    before_each(function()
        fetch.states = {}
        data, mirror = tmpdir(), tmpdir()
        write(mirror .. "/lw-linux-x86_64", payload)
    end)
    after_each(function()
        vim.fn.delete(data, "rf"); vim.fn.delete(mirror, "rf")
    end)

    local function ensure(w, o)
        local got, err, done
        local opts = { data = data, release_url = mirror, getenv = function() return nil end }
        for k, v in pairs(o or {}) do opts[k] = v end
        fetch.ensure(w, opts, function(p, e) got, err, done = p, e, true end)
        assert.is_true(vim.wait(5000, function() return done end, 10))
        return got, err
    end

    it("builds the release URL: lw's origin, a flat mirror, file://, a latest/download base", function()
        local w = want()
        local none = { getenv = function() return nil end }
        assert.equals("https://github.com/samienne/loomworks.nvim/releases/download/v0.1.50/lw-linux-x86_64",
            fetch.url(w, none))
        assert.equals("/m/lw-linux-x86_64", fetch.url(w, { getenv = function() return "/m/" end }))
        assert.equals("https://x/y/lw-linux-x86_64", fetch.url(w, { release_url = "https://x/y",
            getenv = function() return "/ignored" end }))
        assert.equals("https://h/o/r/releases/download/v0.1.50/lw-linux-x86_64",
            fetch.url(w, { release_url = "https://h/o/r/releases/latest/download" }))
        assert.equals("C:/m", fetch.local_path("file:///C:/m"))
        assert.equals("/m", fetch.local_path("file:///m"))
        assert.equals("C:/m", fetch.local_path("C:/m"))
        assert.is_nil(fetch.local_path("https://x"))
    end)

    it("refuses unsafe wanted records (never a path or URL fragment)", function()
        assert.is_nil(fetch.check_wanted(want({ version = "../1" })))
        assert.is_nil(fetch.check_wanted(want({ version = "1/2" })))
        assert.is_nil(fetch.check_wanted(want({ asset = "../lw" })))
        assert.is_nil(fetch.check_wanted(want({ asset = "x/lw" })))
        assert.is_nil(fetch.check_wanted(want({ sha256 = "zz" })))
        assert.equals(good, fetch.check_wanted(want({ sha256 = good:upper() })).sha256)
        local got, err = ensure(want({ version = "../1" }))
        assert.is_nil(got); assert.truthy(err:find("invalid release version", 1, true))
        assert.same({}, listdir(data))
    end)

    it("downloads from a local mirror, verifies, installs into the managed slot and leaves no partial file", function()
        local got, err = ensure(want())
        assert.is_nil(err)
        local slot = managed.path(good, { data = data })
        assert.equals(slot, got)
        assert.equals(payload, read(slot))
        if not is_win then assert.is_true(uv.fs_access(slot, "X")) end
        assert.same({ good }, listdir(managed.dir(data)))
        assert.equals("ready", fetch.states[good].state)
        assert.truthy(fetch.describe(good):find("installed at", 1, true))
        -- Present: no second transfer.
        local transfers = 0
        got = ensure(want(), { transfer = function(_, _, cb) transfers = transfers + 1; cb(false, "x") end })
        assert.equals(slot, got); assert.equals(0, transfers)
    end)

    it("works through file:// too", function()
        local got = ensure(want(), { release_url = "file://" .. mirror })
        assert.equals(managed.path(good, { data = data }), got)
    end)

    it("a hash mismatch installs nothing and leaves nothing behind", function()
        write(mirror .. "/lw-linux-x86_64", payload .. "tampered")
        local got, err = ensure(want())
        assert.is_nil(got)
        assert.truthy(err:find("expected " .. good, 1, true), err)
        assert.same({}, listdir(managed.dir(data)))
        assert.equals("failed", fetch.states[good].state)
        assert.truthy(fetch.describe(good):find("could not install lw v0.1.50", 1, true))
    end)

    it("a failed transfer removes its partial file", function()
        local seen
        local got, err = ensure(want(), { transfer = function(_, dest, cb)
            seen = dest
            write(dest, "partial")
            cb(false, "connection reset")
        end })
        assert.is_nil(got); assert.truthy(err:find("connection reset", 1, true))
        assert.truthy(seen:match("/" .. good .. "%.%d+%.%d+%.dl$"), seen)
        assert.is_false(exists(seen))
        assert.same({}, listdir(managed.dir(data)))
        -- A missing source.
        got, err = ensure(want({ asset = "lw-macos-arm64" }))
        assert.is_nil(got); assert.truthy(err:find("cannot copy", 1, true), err)
        assert.same({}, listdir(managed.dir(data)))
    end)

    it("concurrent requests for one hash share one download", function()
        local transfers, finish = 0, nil
        local results = {}
        local opts = { data = data, release_url = mirror, transfer = function(url, dest, cb)
            transfers = transfers + 1
            finish = function() fetch.transfer(url, dest, cb) end
        end }
        for i = 1, 3 do fetch.ensure(want(), opts, function(p, e) results[i] = { p, e } end) end
        assert.equals(1, transfers)
        assert.equals("downloading", fetch.states[good].state)
        assert.truthy(fetch.describe(good):find("downloading lw v0.1.50", 1, true))
        finish()
        assert.is_true(vim.wait(5000, function() return #results == 3 end, 10))
        for i = 1, 3 do assert.equals(managed.path(good, { data = data }), results[i][1]) end
    end)

    it("follows a linked data directory (dotfile setups) but never a linked lw/ or slot", function()
        local real = tmpdir()
        vim.fn.delete(data, "rf")
        local ok = uv.fs_symlink(real, data, { dir = true, junction = true })
        if not ok then pending("cannot create a directory link here"); return end
        local got, err = ensure(want())
        assert.is_nil(err)
        assert.equals(payload, read(got))
        assert.equals(payload, read(real .. "/loomworks/lw/" .. good .. "/" .. managed.exe_name()))
        uv.fs_unlink(data); if exists(data) then uv.fs_rmdir(data) end
        vim.fn.delete(real, "rf")
        vim.fn.mkdir(data, "p")
    end)

    it("unlinks a link at its partial-download path, never writing through it", function()
        local outside = tmpdir()
        write(outside .. "/victim", "victim")
        local tmp = fetch.partial_path(managed.dir(data), good, fetch._seq + 1)
        vim.fn.mkdir(managed.dir(data), "p")
        -- A file link, else (Windows without the privilege) a junction.
        if not uv.fs_symlink(outside .. "/victim", tmp)
            and not uv.fs_symlink(outside, tmp, { dir = true, junction = true }) then
            pending("cannot create a link here"); return
        end
        local made
        local got, err = ensure(want(), { transfer = function(url, dest, cb, o)
            made = dest
            return fetch.transfer(url, dest, cb, o)
        end })
        assert.equals(tmp, made)
        assert.is_nil(err)
        assert.equals(payload, read(got))
        assert.equals("victim", read(outside .. "/victim"))
        assert.is_false(exists(made))
        vim.fn.delete(outside, "rf")
    end)

    it("retries the rename on Windows while the new binary is held (Defender)", function()
        local calls = 0
        local got, err = ensure(want(), { win = true, rename = function(a, b)
            calls = calls + 1
            if calls < 3 then return nil, "EACCES: permission denied", "EACCES" end
            return uv.fs_rename(a, b)
        end })
        assert.is_nil(err); assert.equals(3, calls)
        assert.equals(payload, read(got))
        calls = 0
        fetch.states = {}
        vim.fn.delete(managed.dir(data), "rf")
        got, err = ensure(want(), { win = false, rename = function()
            calls = calls + 1; return nil, "EACCES: permission denied", "EACCES"
        end })
        assert.is_nil(got); assert.equals(1, calls)
        assert.same({ good }, listdir(managed.dir(data))) -- the empty slot, no partial file
    end)

    it("re-hashes a present binary once per process; a corrupt one is downloaded again over it", function()
        local slot = managed.path(good, { data = data })
        write(slot, "corrupt")
        managed._verified = {}
        local got, err = ensure(want())
        assert.is_nil(err)
        assert.equals(payload, read(got))
        local hashes = 0
        local function counting(p) hashes = hashes + 1; return sha256.file(p) end
        managed._verified = {}
        assert.is_true(managed.verify(slot, good, { hash = counting }))
        assert.is_true(managed.verify(slot, good, { hash = counting }))
        assert.equals(1, hashes)
    end)

    it("cancels an in-flight download: the transfer is stopped, its partial file removed, waiters told", function()
        local killed, tmp, late = false, nil, nil
        local got, err, done
        fetch.ensure(want(), { data = data, release_url = mirror, transfer = function(_, dest, cb)
            tmp = dest; write(dest, "part"); late = cb
            return { cancel = function() killed = true end }
        end }, function(p, e) got, err, done = p, e, true end)
        assert.equals("downloading", fetch.states[good].state)
        assert.is_true(fetch.cancel(good, "restarted"))
        assert.is_true(vim.wait(1000, function() return done end, 10))
        assert.is_true(killed); assert.is_nil(got)
        assert.truthy(err:find("restarted", 1, true))
        assert.is_false(exists(tmp))
        late(true) -- the killed transfer reporting late changes nothing
        vim.wait(50)
        assert.same({}, listdir(managed.dir(data)))
        assert.is_false(fetch.cancel(good))
    end)

    it("bounds curl: connect timeout, low-speed limit, https-only redirects from an https origin", function()
        local a = table.concat(fetch.curl_args("curl", "https://x/lw", "/t/dl", {}), " ")
        assert.truthy(a:find("--connect-timeout " .. fetch.CONNECT_TIMEOUT, 1, true))
        assert.truthy(a:find("--speed-limit " .. fetch.LOW_SPEED_BPS .. " --speed-time " .. fetch.LOW_SPEED_S, 1, true))
        assert.truthy(a:find("--proto-redir =https", 1, true))
        local h = table.concat(fetch.curl_args("curl", "http://mirror/lw", "/t/dl", {}), " ")
        assert.is_nil(h:find("--proto-redir", 1, true))
    end)

    it("classifies curl failures like lw: 4xx final (but 408/429), the rest transient", function()
        assert.is_false(fetch.is_transient(22, "curl: (22) The requested URL returned error: 404"))
        assert.is_true(fetch.is_transient(22, "returned error: 429"))
        assert.is_true(fetch.is_transient(22, "returned error: 503"))
        assert.is_true(fetch.is_transient(6, "could not resolve host"))
        assert.is_false(fetch.is_transient(0, ""))
    end)
end)

describe("provision.select with a wanted managed lw (step 5h.3)", function()
    local sha = string.rep("ef", 32)
    local w = { sha256 = sha, version = "0.1.50", asset = "lw-linux-x86_64" }
    local function run(setting)
        return binsel.resolve("/r", { getenv = function() return nil end, setting = setting, win = false,
            cwd = "/cwd", data = "/d", exists = function() return false end,
            on_path = function() return nil, "no lw on the search path" end,
            managed = function()
                return managed.find({ data = "/d", win = false, wanted = function() return w end,
                    exists = function() return false end })
            end })
    end

    it("selects it for download, which decides the search", function()
        local path, source, sel = run({ prefer = "managed" })
        assert.is_nil(path); assert.equals("managed", source)
        assert.equals(w, sel.download)
        assert.is_nil(sel.note)
        local c = sel.candidates[3]
        assert.equals("download", c.verdict)
        assert.equals("/d/loomworks/lw/" .. sha .. "/lw", c.path)
        assert.equals("not tried", sel.candidates[4].verdict)
        assert.truthy(binsel.describe(sel):find("lw v0.1.50 (lw-linux-x86_64), downloaded first", 1, true))
    end)

    it("binary.download = false: absent, with why, and the none note", function()
        local path, _, sel = run({ download = false })
        assert.is_nil(path); assert.is_nil(sel.download)
        assert.truthy(sel.note:find("binary.download = false", 1, true), sel.note)
    end)

    it("checks the new setup values", function()
        local s, warn = binsel.check_setting({ download = false, release_url = "/m" })
        assert.same({ download = false, release_url = "/m" }, s); assert.is_nil(warn)
        s, warn = binsel.check_setting({ download = "no", release_url = 3 })
        assert.same({}, s)
        assert.truthy(warn:find("binary.download", 1, true)); assert.truthy(warn:find("binary.release_url", 1, true))
    end)
end)

describe("provision.cache.prune (deletion safety rule 11)", function()
    local data, dir
    local A, B, C = string.rep("a", 64), string.rep("b", 64), string.rep("c", 64)
    local exe = is_win and "lw.exe" or "lw"
    local function slot(sha) return dir .. "/" .. sha end
    local function age(p, s)
        local t = os.time() - (s or (cache.UNUSED_S + 3600))
        uv.fs_utime(p, t, t)
    end
    -- An installed slot, last used long ago (unless `fresh`).
    local function install(sha, fresh)
        write(slot(sha) .. "/" .. exe, "bin")
        if not fresh then age(slot(sha)) end
    end

    before_each(function()
        fetch.states = {}
        data = tmpdir()
        dir = managed.dir(data)
        vim.fn.mkdir(dir, "p")
    end)
    after_each(function() vim.fn.delete(data, "rf") end)

    local function prune(o)
        local opts = { data = data, keep = { A }, busy = false }
        for k, v in pairs(o or {}) do opts[k] = v end
        return cache.prune(opts)
    end

    it("keeps the wanted hash and removes the other managed binaries", function()
        install(A); install(B); install(C)
        local r = prune()
        assert.same({ A }, listdir(dir))
        assert.equals(2, #r.removed)
        assert.equals("wanted", r.skipped[A])
    end)

    it("does nothing without a wanted hash or while a download runs", function()
        install(B)
        local _, why = prune({ keep = {} })
        assert.equals("no wanted binary", why)
        _, why = prune({ busy = true })
        assert.equals("a download is running", why)
        fetch.states[A] = { state = "downloading" }
        _, why = cache.prune({ data = data, keep = { A } })
        assert.equals("a download is running", why)
        assert.same({ B }, listdir(dir))
    end)

    it("never touches a binary in use, by its path or its realpath", function()
        local D = string.rep("d", 64)
        install(B); install(C); install(D)
        local r = prune({ in_use = { slot(B) .. "/" .. exe, slot(C) .. "/./" .. exe } })
        assert.same({ B, C }, listdir(dir))
        assert.equals("in use", r.skipped[B])
        assert.equals("in use", r.skipped[C])
        assert.same({ slot(D) }, r.removed)
    end)

    it("only takes exact 64-lowercase-hex names holding just the binary", function()
        local upper, short = string.rep("D", 64), string.rep("d", 63)
        install(upper); install(short); install(B)
        write(slot(B) .. "/extra", "keep me")
        age(slot(B))
        write(dir .. "/" .. C, "a file, not a slot")
        write(dir .. "/notes.txt", "x")
        local r = prune()
        local expect = { B, C, upper, "notes.txt", short }
        table.sort(expect)
        assert.same(expect, listdir(dir))
        assert.equals("unexpected content", r.skipped[B])
        assert.equals("not a real directory", r.skipped[C])
        assert.equals("not a managed binary name", r.skipped[upper])
        assert.equals("not a managed binary name", r.skipped[short])
        assert.equals("keep me", read(slot(B) .. "/extra"))
        assert.equals(0, #r.removed)
    end)

    it("skips a link or junction slot and never follows it", function()
        local outside = tmpdir()
        write(outside .. "/" .. exe, "victim")
        local ok = uv.fs_symlink(outside, slot(B), { dir = true, junction = true })
        if not ok then pending("cannot create a directory link here"); return end
        local r = prune()
        assert.equals("not a real directory", r.skipped[B])
        assert.equals("victim", read(outside .. "/" .. exe))
        uv.fs_unlink(slot(B))
        if exists(slot(B)) then uv.fs_rmdir(slot(B)) end
        vim.fn.delete(outside, "rf")
    end)

    it("refuses a managed directory that is itself a link", function()
        local real = tmpdir()
        install(A)
        vim.fn.delete(dir, "rf")
        write(real .. "/" .. B .. "/" .. exe, "victim")
        local ok = uv.fs_symlink(real, dir, { dir = true, junction = true })
        if not ok then pending("cannot create a directory link here"); return end
        local r, why = prune()
        assert.truthy(why:find("not a directory", 1, true), why)
        assert.equals(0, #r.removed)
        assert.equals("victim", read(real .. "/" .. B .. "/" .. exe))
        uv.fs_unlink(dir)
        if exists(dir) then uv.fs_rmdir(dir) end
        vim.fn.delete(real, "rf")
    end)

    it("keeps a slot used recently (another editor's daemon, another plugin version, an install in progress)", function()
        install(B, true); install(C)
        local r = prune()
        assert.equals("recently used", r.skipped[B])
        assert.same({ slot(C) }, r.removed)
        assert.same({ B }, listdir(dir))
    end)

    it("selecting or connecting to a managed binary marks its slot used; nothing else is touched", function()
        install(B)
        local bin = slot(B) .. "/" .. exe
        assert.is_true(managed.touch(bin, { data = data }))
        local st = uv.fs_lstat(slot(B))
        assert.is_true(os.time() - st.mtime.sec < 60)
        assert.equals("recently used", prune().skipped[B])
        -- Not a managed slot: no-op.
        local other = tmpdir()
        write(other .. "/lw", "x"); age(other)
        assert.is_false(managed.touch(other .. "/lw", { data = data }))
        assert.is_true(os.time() - uv.fs_lstat(other).mtime.sec > 3600)
        assert.is_false(managed.touch(slot(B) .. "/../" .. B .. "/" .. exe .. "x", { data = data }))
        vim.fn.delete(other, "rf")
    end)

    it("find: a link in the slot is never launched; a corrupt binary is missing (downloaded again)", function()
        local w = { sha256 = B, version = "0.1.50", asset = "lw-linux-x86_64" }
        local outside = tmpdir()
        write(outside .. "/lw", "bin")
        vim.fn.mkdir(slot(B), "p")
        local linked = uv.fs_symlink(outside .. "/lw", slot(B) .. "/" .. exe)
        if linked then
            local p, why = managed.find({ data = data, wanted = function() return w end })
            assert.is_nil(p); assert.truthy(why:find("not installed", 1, true), why)
            uv.fs_unlink(slot(B) .. "/" .. exe)
        end
        write(slot(B) .. "/" .. exe, "corrupt")
        managed._verified = {}
        local p, why, missing = managed.find({ data = data, wanted = function() return w end })
        assert.is_nil(p); assert.truthy(why:find("SHA-256", 1, true), why)
        assert.equals(B, missing.sha256); assert.is_true(missing.corrupt)
        vim.fn.delete(outside, "rf")
    end)

    it("removes another process's stale partial download only", function()
        local mine, recent, stale = A .. ".111.1.dl", B .. ".222.1.dl", C .. ".333.4.dl"
        for _, n in ipairs({ mine, recent, stale }) do write(dir .. "/" .. n, "part") end
        write(dir .. "/x.333.1.dl", "not a hash")
        local old = os.time() - cache.STALE_DL_S - 60
        uv.fs_utime(dir .. "/" .. stale, old, old)
        uv.fs_utime(dir .. "/" .. mine, old, old)
        local r = prune({ pid = 111 })
        assert.same({ dir .. "/" .. stale }, r.removed)
        assert.equals("this editor's download", r.skipped[mine])
        assert.equals("recent", r.skipped[recent])
        assert.truthy(exists(dir .. "/x.333.1.dl"))
    end)
end)
