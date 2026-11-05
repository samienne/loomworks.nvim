-- The managed lw's release bundle (spec §19.16 "The managed bundle"): the
-- zip reader's checks (nothing written unless every entry passes), the slot's
-- presence rules (any other state is never used, repaired or removed), the
-- provisioning (hash, stage, rename, a slot another editor installed is used,
-- failure cleanup of only this process's own staging directory and partial
-- file) and LOOMWORKS_INSTALL_DIR on every process started from the managed
-- binary. No network: the "release" is a local mirror directory.

local uv = vim.uv or vim.loop
local unzip = require("loomworks.provision.unzip")
local bundle = require("loomworks.provision.bundle")
local fetch = require("loomworks.provision.fetch")
local managed = require("loomworks.provision.managed")
local sha256 = require("loomworks.provision.sha256")
local binsel = require("loomworks.provision.select")
local LibDeflate = require("loomworks.provision.libdeflate")

local is_win = package.config:sub(1, 1) == "\\"
local VERSION = "0.1.50"

local function write(p, data)
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb")); f:write(data); f:close()
end
local function read(p)
    local f = io.open(p, "rb"); if not f then return nil end
    local d = f:read("*a"); f:close(); return d
end
local function ltype(p) local st = uv.fs_lstat(p); return st and st.type or nil end
local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (uv.fs_realpath(d) or d):gsub("\\", "/")
end
local function listdir(d)
    local out = {}
    if ltype(d) ~= "directory" then return out end
    for name in vim.fs.dir(d) do out[#out + 1] = name end
    table.sort(out)
    return out
end
--- A directory link: a junction on Windows (no privilege needed), else a symlink.
local function dirlink(target, path)
    return uv.fs_symlink(target, path, is_win and { junction = true } or nil)
end

-- A zip writer for the fixtures --------------------------------------------

local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- entries: { name, content?, method? (0|8, or any other number: stored
--- bytes under that method), made_by?, ext?, crc?, flags?, usize? (the
--- central directory's recorded uncompressed size) }
local function zip(entries)
    local body, central = {}, {}
    local off = 0
    for _, e in ipairs(entries) do
        local content = e.content or ""
        local method = e.method or 8
        local data = method == 8 and LibDeflate:CompressDeflate(content) or content
        local crc = e.crc or unzip.crc32(content)
        local dir = e.name:sub(-1) == "/"
        local ext = e.ext or ((dir and 0x41ED or 0x81A4) * 65536)
        local flags = e.flags or 0
        local lh = le32(0x04034b50) .. le16(20) .. le16(flags) .. le16(method) .. le16(0) .. le16(0) .. le32(crc)
            .. le32(#data) .. le32(#content) .. le16(#e.name) .. le16(0) .. e.name
        body[#body + 1] = lh .. data
        central[#central + 1] = le32(0x02014b50) .. le16(e.made_by or 0x0314) .. le16(20) .. le16(flags) .. le16(method)
            .. le16(0) .. le16(0) .. le32(crc) .. le32(#data) .. le32(e.usize or #content) .. le16(#e.name) .. le16(0) .. le16(0)
            .. le16(0) .. le16(0) .. le32(ext) .. le32(off) .. e.name
        off = off + #lh + #data
    end
    local cd = table.concat(central)
    return table.concat(body) .. cd .. le32(0x06054b50) .. le16(0) .. le16(0) .. le16(#entries) .. le16(#entries)
        .. le32(#cd) .. le32(off) .. le16(0)
end

local CLI = "return 'cli'\n" .. string.rep("-- padding\n", 50)
local function good_entries()
    return {
        { name = "loomworks/" },
        { name = "loomworks/cli.lua", content = CLI },
        { name = "loomworks/sub/a.lua", content = "return 1\n", method = 0 },
        { name = "loomworks/sub/b.bin", content = "\0\255" .. string.rep("x", 1000) },
    }
end

describe("provision.unzip (§19.16: nothing installed unless every entry passes)", function()
    it("CRC-32 matches the known answer", function()
        assert.equals(0xCBF43926, unzip.crc32("123456789"))
        assert.equals(0, unzip.crc32(""))
    end)

    it("reads a good zip: stored and deflate entries, a directory entry", function()
        local entries = assert(unzip.read(zip(good_entries())))
        assert.equals(4, #entries)
        assert.same({ "directory", "loomworks" }, { entries[1].type, entries[1].name })
        assert.equals(CLI, entries[2].content)
        assert.equals("return 1\n", entries[3].content)
        assert.equals("\0\255" .. string.rep("x", 1000), entries[4].content)
    end)

    local function refused(entries, pattern)
        local got, why = unzip.read(zip(entries))
        assert.is_nil(got)
        assert.truthy(tostring(why):find(pattern, 1, true), why)
    end

    it("refuses a link and any other type", function()
        refused({ { name = "loomworks/cli.lua", content = CLI }, { name = "loomworks/l", content = "../x", ext = 0xA1FF * 65536 } },
            "symbolic link")
        refused({ { name = "loomworks/cli.lua", content = CLI }, { name = "loomworks/fifo", ext = 0x11A4 * 65536 } },
            "not a regular file or directory")
        -- A DOS/NTFS reparse point (a link or junction).
        refused({ { name = "loomworks/cli.lua", content = CLI }, { name = "loomworks/j", made_by = 0x0014, ext = 0x410 } },
            "reparse point")
    end)

    it("refuses '..', '.', an empty segment, an absolute name, a backslash, ':' and NUL", function()
        refused({ { name = "loomworks/../x.lua", content = "x" } }, "'..'")
        refused({ { name = "loomworks/./x.lua", content = "x" } }, "'..'")
        refused({ { name = "loomworks//x.lua", content = "x" } }, "empty")
        refused({ { name = "/loomworks/x.lua", content = "x" } }, "absolute")
        refused({ { name = "loomworks\\x.lua", content = "x" } }, "backslash")
        refused({ { name = "loomworks/C:x.lua", content = "x" } }, "':'")
        refused({ { name = "loomworks/x\0.lua", content = "x" } }, "NUL")
    end)

    it("refuses a name another entry repeats case-insensitively", function()
        refused({ { name = "loomworks/cli.lua", content = CLI }, { name = "loomworks/CLI.lua", content = "x" } },
            "case-insensitively")
    end)

    it("refuses an entry outside loomworks/", function()
        refused({ { name = "other/cli.lua", content = CLI } }, "not under loomworks/")
        refused({ { name = "loomworks", content = "x" } }, "not under loomworks/")
    end)

    it("refuses a CRC mismatch", function()
        refused({ { name = "loomworks/cli.lua", content = CLI, crc = 12345 } }, "CRC-32")
        refused({ { name = "loomworks/cli.lua", content = CLI, crc = 12345, method = 0 } }, "CRC-32")
    end)

    it("refuses zip64, an encrypted entry and an unknown compression method", function()
        refused({ { name = "loomworks/cli.lua", content = CLI, usize = 0xFFFFFFFF } }, "zip64")
        refused({ { name = "loomworks/cli.lua", content = CLI, flags = 1 } }, "encrypted")
        refused({ { name = "loomworks/cli.lua", content = CLI, method = 12 } }, "compression method 12")
    end)

    it("refuses archives whose recorded sizes total more than the bound, before inflating", function()
        local half = math.floor(unzip.MAX_TOTAL / 2) + 1
        refused({ { name = "loomworks/cli.lua", content = CLI },
            { name = "loomworks/a.bin", content = "x", method = 0, usize = half },
            { name = "loomworks/b.bin", content = "y", method = 0, usize = half } }, "more than the limit")
        refused({ { name = "loomworks/cli.lua", content = CLI, usize = unzip.MAX_TOTAL + 1 } }, "more than the limit")
    end)

    it("refuses an entry that inflates to another length than recorded", function()
        refused({ { name = "loomworks/cli.lua", content = CLI, usize = #CLI + 1 } }, "inflates to")
        refused({ { name = "loomworks/cli.lua", content = CLI, usize = #CLI - 1, method = 0 } }, "inflates to")
    end)

    it("refuses a truncated archive", function()
        local z = zip(good_entries())
        for _, n in ipairs({ #z - 1, #z - 22, math.floor(#z / 2), 10, 0 }) do
            local got, why = unzip.read(z:sub(1, n))
            assert.is_nil(got, "length " .. n)
            assert.truthy(why, "length " .. n)
        end
        -- Data cut short inside an entry.
        local z1 = zip({ { name = "loomworks/cli.lua", content = CLI, method = 0 } })
        local at = z1:find("-- padding", 1, true)
        local got, why = unzip.read(z1:sub(1, at) .. z1:sub(at + 2))
        assert.is_nil(got); assert.truthy(why)
    end)
end)

describe("provision.bundle slot state (§19.16: present only by the rule, any other state never used)", function()
    local data, bdir, sha
    before_each(function()
        data = tmpdir()
        bdir = managed.bundle_dir(data)
        sha = string.rep("ab", 32)
    end)
    after_each(function() vim.fn.delete(data, "rf") end)

    local function fill(slot)
        write(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua", CLI)
    end

    it("absent, then present", function()
        assert.equals("absent", (bundle.state(sha, VERSION, { data = data })))
        vim.fn.mkdir(bdir, "p")
        assert.equals("absent", (bundle.state(sha, VERSION, { data = data })))
        fill(bdir .. "/" .. sha)
        local st, slot = bundle.state(sha, VERSION, { data = data })
        assert.equals("present", st)
        assert.equals(bdir .. "/" .. sha, slot)
    end)

    it("any other state: a file, an empty slot, no cli.lua, cli.lua a directory, a linked slot or bundle dir", function()
        local function other(why)
            local st, _, w = bundle.state(sha, VERSION, { data = data })
            assert.equals("other", st)
            assert.truthy(w and w:find(why, 1, true), w)
        end
        local slot = bdir .. "/" .. sha
        write(slot, "x")
        other("not a real directory")
        os.remove(slot)
        vim.fn.mkdir(slot, "p")
        other("lua-" .. VERSION .. " is not a real directory")
        vim.fn.mkdir(slot .. "/lua-" .. VERSION .. "/loomworks", "p")
        other("cli.lua is not a regular file")
        vim.fn.mkdir(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua", "p")
        other("cli.lua is not a regular file")
        vim.fn.delete(slot, "rf")
        -- A linked slot to a complete bundle is still never used.
        local elsewhere = data .. "/elsewhere"
        fill(elsewhere)
        assert.truthy(dirlink(elsewhere, slot))
        other("not a real directory")
        -- And it is never repaired or removed: still there.
        assert.equals("link", ltype(slot))
        assert.equals(CLI, read(elsewhere .. "/lua-" .. VERSION .. "/loomworks/cli.lua"))
        uv.fs_unlink(slot)
        -- A linked bundle directory.
        vim.fn.delete(bdir, "rf")
        local real = data .. "/realbundle"
        fill(real .. "/" .. sha)
        assert.truthy(dirlink(real, bdir))
        other("is not a real directory")
        uv.fs_unlink(bdir)
    end)

    it("managed.find: present with its slot; absent offers the bundle; any other state is one note, no download", function()
        local payload = "binary"
        local want = { sha256 = sha256.lua(payload), bundle_sha256 = sha, version = VERSION, asset = "lw-linux-x86_64" }
        local function find() return managed.find({ data = data, wanted = function() return want end }) end
        local bin = managed.path(want.sha256, { data = data })
        write(bin, payload)
        local p, why, missing = find()
        assert.is_nil(p)
        assert.truthy(why:find("bundle is not installed", 1, true), why)
        assert.is_true(missing.bundle_missing)
        assert.equals(sha, missing.bundle_sha256)
        fill(bdir .. "/" .. sha)
        local p2, _, _, install = find()
        assert.equals(bin, p2)
        assert.equals(bdir .. "/" .. sha, install)
        -- Any other state: never used, no `missing` record (nothing downloaded).
        os.remove(bdir .. "/" .. sha .. "/lua-" .. VERSION .. "/loomworks/cli.lua")
        local p3, why3, missing3 = find()
        assert.is_nil(p3); assert.is_nil(missing3)
        assert.truthy(why3:find(bdir .. "/" .. sha, 1, true), why3)
        assert.truthy(why3:find("never repaired or removed", 1, true), why3)
        local _, _, sel = binsel.resolve("/r", { getenv = function() end, setting = {}, win = false,
            on_path = function() return nil, "none" end,
            managed = function() return managed.find({ data = data, wanted = function() return want end }) end })
        assert.is_nil(sel.download)
        assert.truthy(sel.note:find("never repaired or removed", 1, true), sel.note)
    end)
end)

describe("provision.fetch: the managed bundle (§19.16)", function()
    local data, mirror, bdir, zipdata, w, payload
    before_each(function()
        fetch.states, fetch.bundle_states = {}, {}
        data, mirror = tmpdir(), tmpdir()
        bdir = managed.bundle_dir(data)
        payload = "\127ELF lw " .. string.rep("\1", 100)
        zipdata = zip(good_entries())
        write(mirror .. "/lw-linux-x86_64", payload)
        write(mirror .. "/" .. managed.bundle_asset(VERSION), zipdata)
        w = { sha256 = sha256.lua(payload), bundle_sha256 = sha256.lua(zipdata), version = VERSION, asset = "lw-linux-x86_64" }
    end)
    after_each(function()
        vim.fn.delete(data, "rf"); vim.fn.delete(mirror, "rf")
    end)

    local function run(fn)
        local res, done = nil, false
        fn(function(...) res = { ... }; done = true end)
        assert.is_true(vim.wait(10000, function() return done end, 10), "timed out")
        return res
    end
    local function counting(n)
        return function(url, dest, cb, o) n[1] = n[1] + 1; return fetch.transfer(url, dest, cb, o) end
    end

    it("installs the pair: the binary and the bundle slot, nothing else left behind", function()
        local n = { 0 }
        local res = run(function(cb) fetch.ensure(w, { data = data, release_url = mirror, transfer = counting(n) }, cb) end)
        assert.equals(managed.path(w.sha256, { data = data }), res[1], res[2])
        assert.equals(2, n[1])
        local slot = bdir .. "/" .. w.bundle_sha256
        assert.equals("present", (bundle.state(w.bundle_sha256, VERSION, { data = data })))
        assert.equals(CLI, read(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua"))
        assert.equals("return 1\n", read(slot .. "/lua-" .. VERSION .. "/loomworks/sub/a.lua"))
        assert.same({ w.bundle_sha256 }, listdir(bdir)) -- no .dl, no .stage-
        -- Present now: used by presence, nothing fetched again.
        res = run(function(cb) fetch.ensure(w, { data = data, release_url = mirror, transfer = counting(n) }, cb) end)
        assert.truthy(res[1]); assert.equals(2, n[1])
    end)

    it("requests for one hash share one provisioning", function()
        local n = { 0 }
        local got, done = {}, 0
        for _ = 1, 3 do
            fetch.ensure_bundle(w, { data = data, release_url = mirror, transfer = counting(n) }, function(s)
                got[#got + 1] = s; done = done + 1
            end)
        end
        assert.is_true(vim.wait(10000, function() return done == 3 end, 10))
        assert.equals(1, n[1])
        assert.same({ bdir .. "/" .. w.bundle_sha256, bdir .. "/" .. w.bundle_sha256, bdir .. "/" .. w.bundle_sha256 }, got)
    end)

    it("a hash mismatch installs nothing and leaves no partial file", function()
        w.bundle_sha256 = string.rep("0", 64)
        local res = run(function(cb) fetch.ensure_bundle(w, { data = data, release_url = mirror }, cb) end)
        assert.is_nil(res[1])
        assert.truthy(res[2]:find("expected " .. w.bundle_sha256, 1, true), res[2])
        assert.same({}, listdir(bdir))
    end)

    it("a refused bundle installs nothing: no staging directory, no partial file", function()
        local bad = zip({ { name = "loomworks/cli.lua", content = CLI }, { name = "loomworks/../evil", content = "x" } })
        write(mirror .. "/" .. managed.bundle_asset(VERSION), bad)
        w.bundle_sha256 = sha256.lua(bad)
        local res = run(function(cb) fetch.ensure_bundle(w, { data = data, release_url = mirror }, cb) end)
        assert.is_nil(res[1])
        assert.truthy(res[2]:find("refused", 1, true), res[2])
        assert.same({}, listdir(bdir))
        assert.is_nil(ltype(data .. "/loomworks/evil"))
    end)

    it("a failed install removes its own staging directory and nothing else", function()
        local other = bdir .. "/.stage-" .. string.rep("c", 64) .. ".1.1" -- another process's: never touched
        write(other .. "/f", "x")
        local res = run(function(cb)
            fetch.ensure_bundle(w, { data = data, release_url = mirror,
                rename_bundle = function() return nil, "EIO: i/o error", "EIO" end }, cb)
        end)
        assert.is_nil(res[1])
        assert.truthy(res[2]:find("cannot install", 1, true), res[2])
        assert.same({ ".stage-" .. string.rep("c", 64) .. ".1.1" }, listdir(bdir))
        assert.equals("x", read(other .. "/f"))
    end)

    it("the rename race: a slot another editor installed meanwhile is used, the own stage removed", function()
        local slot = bdir .. "/" .. w.bundle_sha256
        local res = run(function(cb)
            fetch.ensure_bundle(w, { data = data, release_url = mirror, rename_bundle = function(from, to)
                -- The other editor wins between the check and the rename.
                write(to .. "/lua-" .. VERSION .. "/loomworks/cli.lua", "other editor")
                return uv.fs_rename(from, to)
            end }, cb)
        end)
        assert.equals(slot, res[1], res[2])
        assert.equals("other editor", read(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua"))
        assert.same({ w.bundle_sha256 }, listdir(bdir))
    end)

    it("a slot already present is used without a download; one in any other state is never used or touched", function()
        local n = { 0 }
        local slot = bdir .. "/" .. w.bundle_sha256
        write(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua", "installed before")
        local res = run(function(cb) fetch.ensure_bundle(w, { data = data, release_url = mirror, transfer = counting(n) }, cb) end)
        assert.equals(slot, res[1]); assert.equals(0, n[1])
        os.remove(slot .. "/lua-" .. VERSION .. "/loomworks/cli.lua")
        fetch.bundle_states = {}
        res = run(function(cb) fetch.ensure_bundle(w, { data = data, release_url = mirror, transfer = counting(n) }, cb) end)
        assert.is_nil(res[1]); assert.equals(0, n[1])
        assert.truthy(res[2]:find("never repaired or removed", 1, true), res[2])
        assert.equals("directory", ltype(slot .. "/lua-" .. VERSION .. "/loomworks"))
    end)

    it("whatever sits at the partial file's path is unlinked, never written through", function()
        vim.fn.mkdir(bdir, "p")
        local target = data .. "/precious"
        write(target, "keep")
        fetch._seq = 41
        local tmp = fetch.partial_path(bdir, w.bundle_sha256, 42)
        if uv.fs_symlink(target, tmp) then
            local res = run(function(cb) fetch.ensure_bundle(w, { data = data, release_url = mirror }, cb) end)
            assert.truthy(res[1], res[2])
            assert.equals("keep", read(target))
            assert.is_nil(ltype(tmp))
        end
    end)
end)

describe("provision.bundle.install (§19.16: nothing installed unless every entry passes)", function()
    local data, bdir, dir
    before_each(function()
        data, dir = tmpdir(), tmpdir()
        bdir = managed.bundle_dir(data)
        vim.fn.mkdir(bdir, "p")
    end)
    after_each(function() vim.fn.delete(data, "rf"); vim.fn.delete(dir, "rf") end)

    local function install(z, o)
        local p = dir .. "/bundle.dl"
        write(p, z)
        local w = { bundle_sha256 = sha256.lua(z), version = VERSION }
        local res
        bundle.install(p, w, vim.tbl_extend("force", { data = data }, o or {}), function(...) res = { ... } end)
        assert.is_true(vim.wait(5000, function() return res ~= nil end, 10), "timed out")
        return res, w
    end
    local function nothing_installed(res, pattern)
        assert.is_nil(res[1])
        assert.truthy(tostring(res[2]):find(pattern, 1, true), res[2])
        assert.same({}, listdir(bdir)) -- no slot, no staging directory
    end

    it("refuses zip64, encryption, an unknown method and an oversize total: nothing installed", function()
        local cli = { name = "loomworks/cli.lua", content = CLI }
        nothing_installed(install(zip({ cli, { name = "loomworks/z", content = "z", usize = 0xFFFFFFFF } })), "zip64")
        nothing_installed(install(zip({ cli, { name = "loomworks/e", content = "e", flags = 1 } })), "encrypted")
        nothing_installed(install(zip({ cli, { name = "loomworks/m", content = "m", method = 14 } })), "compression method 14")
        nothing_installed(install(zip({ cli, { name = "loomworks/big", content = "b", method = 0,
            usize = unzip.MAX_TOTAL + 1 } })), "more than the limit")
    end)

    it("a short write installs nothing and removes its own staging directory", function()
        local real = uv.fs_write
        uv.fs_write = function(fd, content, off)
            if type(content) == "string" and #content > 1 then return real(fd, content:sub(1, -2), off) end
            return real(fd, content, off)
        end
        local ok, err = pcall(function()
            nothing_installed(install(zip(good_entries())), "short write")
        end)
        uv.fs_write = real
        assert(ok, err)
    end)

    it("the hash covers the very bytes unzipped: the file is read once", function()
        local good = zip(good_entries())
        local evil = zip({ { name = "loomworks/cli.lua", content = "return 'evil'\n" } })
        -- Swapped on disk right after the one read: the verified bytes install.
        local reads = 0
        local res, w = install(good, { read = function(p)
            reads = reads + 1
            local d = read(p)
            write(p, evil)
            return d
        end })
        assert.equals(1, reads)
        assert.equals(bdir .. "/" .. w.bundle_sha256, res[1], res[2])
        assert.equals(CLI, read(res[1] .. "/lua-" .. VERSION .. "/loomworks/cli.lua"))
        vim.fn.delete(bdir, "rf"); vim.fn.mkdir(bdir, "p")
        -- Swapped before the read (after any earlier hash): refused, nothing installed.
        nothing_installed(install(good, { read = function(p) write(p, evil); return read(p) end }),
            "expected " .. sha256.lua(good))
    end)
end)

describe("provision.bundle.remove_stage (deletion safety)", function()
    local data, bdir
    before_each(function()
        data = tmpdir()
        bdir = managed.bundle_dir(data)
        vim.fn.mkdir(bdir, "p")
    end)
    after_each(function() vim.fn.delete(data, "rf") end)
    local stage_name = ".stage-" .. string.rep("d", 64) .. ".7.1"

    it("removes only an exact staging path; never a slot or another name", function()
        local slot = bdir .. "/" .. string.rep("d", 64)
        write(slot .. "/f", "x")
        assert.is_false((bundle.remove_stage(slot, bdir)))
        assert.is_false((bundle.remove_stage(bdir .. "/.stage-x.1.1", bdir)))
        assert.is_false((bundle.remove_stage(data .. "/x/" .. stage_name, bdir)))
        assert.equals("x", read(slot .. "/f"))
    end)

    it("unlinks a link inside, never follows it", function()
        local outside = data .. "/outside"
        write(outside .. "/keep", "keep")
        local stage = bdir .. "/" .. stage_name
        write(stage .. "/lua-x/a/f", "y")
        assert.truthy(dirlink(outside, stage .. "/lua-x/link"))
        assert.is_true((bundle.remove_stage(stage, bdir)))
        assert.is_nil(ltype(stage))
        assert.equals("keep", read(outside .. "/keep"))
    end)

    it("refuses a staging path that is itself a link", function()
        local outside = data .. "/outside"
        write(outside .. "/keep", "keep")
        local stage = bdir .. "/" .. stage_name
        assert.truthy(dirlink(outside, stage))
        assert.is_false((bundle.remove_stage(stage, bdir)))
        assert.equals("keep", read(outside .. "/keep"))
        uv.fs_unlink(stage)
    end)
end)

describe("LOOMWORKS_INSTALL_DIR on every process started from the managed lw (§19.16)", function()
    local SLOT = "/d/loomworks/bundle/" .. string.rep("e", 64)
    local function get(list, k)
        for _, kv in ipairs(list) do
            local a, b = kv:match("^([^=]+)=(.*)$")
            if a and (is_win and a:upper() or a) == k then return b end
        end
    end

    it("the selection: the managed lw gets its bundle slot, a search-path or explicit lw none", function()
        local function run(o)
            return binsel.resolve("/r", { getenv = function(n) return (o.env or {})[n] end, setting = o.setting or {},
                win = false, exists = function() return true end,
                on_path = function() if o.path then return o.path end return nil, "none" end,
                managed = function() return "/m/lw", nil, nil, SLOT end })
        end
        local _, src, sel = run({ setting = { prefer = "managed" } })
        assert.equals("managed", src)
        assert.same({ LOOMWORKS_INSTALL_DIR = SLOT }, sel.env)
        _, src, sel = run({ path = "/p/lw" })
        assert.equals("PATH", src); assert.is_nil(sel.env)
        _, src, sel = run({ env = { LOOMWORKS_LW = "/e/lw" } })
        assert.equals("LOOMWORKS_LW", src); assert.is_nil(sel.env)
    end)

    it("the relay and the daemon it launches, and a retirement's relaunch, get the selection's env", function()
        local observer = require("loomworks.daemon.observer")
        local relays = {}
        local sel = { path = "/m/lw", source = "managed", label = "plugin-managed lw", candidates = {},
            env = { LOOMWORKS_INSTALL_DIR = SLOT } }
        local obs = observer.attach("/r", {
            getenv = function(n) if n == "LOOMWORKS_RUNTIME" then return "daemon" end end,
            data = tmpdir(), binary = {},
            relay = function(o) relays[#relays + 1] = o; return { close = function() end } end,
            inspect = function() return { kind = "absent" } end,
            resolve = function() return "/m/lw", "managed", sel end,
        })
        assert.is_true(#relays >= 1)
        assert.equals(SLOT, relays[1].env.LOOMWORKS_INSTALL_DIR)
        obs:_end_relay()
        obs:_spawn({ form = "retiring", instance = "i1" })
        assert.equals("retiring", relays[#relays].form)
        assert.equals(SLOT, relays[#relays].env.LOOMWORKS_INSTALL_DIR)
        obs:stop()
        -- The relay process's environment (the daemon inherits it from the relay).
        local settings = require("loomworks.daemon.client.settings")
        assert.equals(SLOT, get(settings.env("/r", sel.env), "LOOMWORKS_INSTALL_DIR"))
    end)

    it("the channel query and the probe pass it to the process", function()
        local real = vim.system
        local seen = {}
        vim.system = function(argv, o, cb)
            seen[#seen + 1] = { argv = argv, env = o.env }
            cb({ code = 1, stdout = "", stderr = "" })
            return {}
        end
        local ok, err = pcall(function()
            require("loomworks.provision.channel").run("/m/lw", "stable", { install_dir = SLOT, cwd = "/" }, function() end)
            local bin = tmpdir() .. "/lw-probe"
            write(bin, tostring(os.time()) .. tostring(math.random()))
            require("loomworks.provision.probe").run(bin, { env = { LOOMWORKS_INSTALL_DIR = SLOT }, cwd = "/" },
                function() end)
        end)
        vim.system = real
        assert(ok, err)
        assert.equals(2, #seen)
        assert.equals(SLOT, seen[1].env.LOOMWORKS_INSTALL_DIR)
        assert.equals(SLOT, seen[2].env.LOOMWORKS_INSTALL_DIR)
    end)
end)
