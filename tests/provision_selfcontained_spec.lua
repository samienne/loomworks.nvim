-- The managed lw is the self-contained executable alone (spec §19.16 "Plugin
-- pin", "Channel upgrades"): the pinned release's host binary carries its
-- code, so a pin needs no bundle entry, a leftover bundle entry (in the pin or
-- a channel record) is ignored, and the selected managed lw gets no
-- install-folder override. No network: the download comes from a local mirror.

local uv = vim.uv or vim.loop
local sha256 = require("loomworks.provision.sha256")
local fetch = require("loomworks.provision.fetch")
local managed = require("loomworks.provision.managed")
local binsel = require("loomworks.provision.select")
local channel = require("loomworks.provision.channel")

local is_win = package.config:sub(1, 1) == "\\"
local function sha(c) return string.rep(c, 64) end

local function tmpdir()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d, "p")
    return (uv.fs_realpath(d) or d):gsub("\\", "/")
end
local function write(p, data)
    vim.fn.mkdir(vim.fs.dirname(p), "p")
    local f = assert(io.open(p, "wb")); f:write(data); f:close()
end

--- A binary descriptor (spec §16.41) offering what this plugin needs.
local function descriptor()
    local cv = require("loomworks.daemon.client.version")
    local objects, by = {}, {}
    for _, w in ipairs(require("loomworks.provision.needs").needed()) do
        local o = by[w.object]
        if not o then
            o = { path = w.object, interfaces = {} }
            by[w.object], objects[#objects + 1] = o, o
        end
        o.interfaces[#o.interfaces + 1] = { name = w.iface, versions = { w.v } }
    end
    return { descriptor = 1, binary = { lw_version = "9.9.9", impl = "lua", dev = false },
        transport = { min = cv.PROTOCOL_MIN, max = cv.PROTOCOL }, schemas = { user = 1, cache = 1 }, objects = objects }
end

describe("the self-contained managed lw (no bundle)", function()
    local data, mirror
    local payload = "\127ELF\0\0lw-self-contained\0" .. string.rep("\1\254", 300)
    local good = sha256.lua(payload)
    local linux = { sysname = "Linux", machine = "x86_64" }

    before_each(function()
        fetch.states = {}
        data, mirror = tmpdir(), tmpdir()
        write(mirror .. "/lw-linux-x86_64", payload)
    end)
    after_each(function()
        vim.fn.delete(data, "rf"); vim.fn.delete(mirror, "rf")
    end)

    it("a pin without a bundle entry wants this host's binary alone", function()
        local pin = { version = "0.2.0-beta.3", assets = { ["lw-linux-x86_64"] = good } }
        local w, why = managed.wanted({ pinned = pin, sysname = linux.sysname, machine = linux.machine })
        assert.is_nil(why)
        assert.same({ sha256 = good, version = "0.2.0-beta.3", asset = "lw-linux-x86_64" }, w)
    end)

    it("ignores a leftover bundle entry in the pin", function()
        local pin = { version = "0.2.0-beta.3", assets = { ["lw-linux-x86_64"] = good,
            ["loomworks-lua-0.2.0-beta.3.zip"] = sha("e") } }
        local w = managed.wanted({ pinned = pin, sysname = linux.sysname, machine = linux.machine })
        assert.same({ sha256 = good, version = "0.2.0-beta.3", asset = "lw-linux-x86_64" }, w)
    end)

    it("provisions from the pin and is selected with no install-folder override", function()
        local pin = { version = "0.2.0-beta.3", assets = { ["lw-linux-x86_64"] = good } }
        local function wanted()
            return managed.pinned_wanted({ pinned = pin, sysname = linux.sysname, machine = linux.machine })
        end
        local function resolve()
            return binsel.resolve("/r", { getenv = function() return nil end, setting = { prefer = "managed" },
                win = is_win, cwd = data, data = data, exists = function() return false end,
                on_path = function() return nil, "no lw on the search path" end,
                managed = function(o) return managed.find({ data = data, win = is_win, wanted = wanted }) end })
        end
        -- Not installed: the selection asks for the binary alone.
        local path, source, sel = resolve()
        assert.is_nil(path); assert.equals("managed", source)
        assert.same({ sha256 = good, version = "0.2.0-beta.3", asset = "lw-linux-x86_64" }, sel.download)
        local got, err, done
        fetch.ensure(sel.download, { data = data, release_url = mirror, win = is_win,
            getenv = function() return nil end }, function(p, e) got, err, done = p, e, true end)
        assert.is_true(vim.wait(5000, function() return done end, 10))
        assert.is_nil(err)
        assert.equals(managed.path(good, { data = data, win = is_win }), got)
        -- Nothing but the binary slot was installed.
        assert.is_nil(uv.fs_lstat(managed.root(data) .. "/bundle"))
        -- Installed: chosen as is, with no environment of its own.
        path, source, sel = resolve()
        assert.equals(got, path); assert.equals("managed", source)
        assert.is_nil(sel.env)
    end)

    it("the channel accepts a newer release offered without a bundle", function()
        local doc = { query = 1, channel = "unstable", channel_ignored = false, source = "origin",
            version = "0.2.0", prerelease = false, assets = { ["lw-linux-x86_64"] = sha("d") }, descriptor = descriptor() }
        local out = channel.classify({ code = 0, stdout = vim.json.encode(doc), stderr = "" }, {
            channel = "unstable", asset = "lw-linux-x86_64", pinned_version = "0.2.0-beta.3",
            current = { version = "0.2.0-beta.3", sha256 = good, asset = "lw-linux-x86_64" } })
        assert.equals("accepted", out.kind, out.note)
        assert.same({ sha256 = sha("d"), version = "0.2.0", asset = "lw-linux-x86_64", channel = "unstable" }, out.wanted)
        assert.is_nil(out.accepted.bundle_sha256)
    end)

    it("reads a channel record with a leftover bundle field for its binary only", function()
        write(channel.file(data), vim.json.encode({ format = channel.FORMAT, channel = "unstable", checked = 1,
            accepted = { version = "0.2.0", asset = "lw-linux-x86_64", sha256 = sha("d"),
                bundle_sha256 = sha("e"), descriptor = descriptor() } }))
        local a = channel.accepted({ channel = "unstable" }, "lw-linux-x86_64", { data = data })
        assert.same({ sha256 = sha("d"), version = "0.2.0", asset = "lw-linux-x86_64", channel = "unstable" }, a)
        -- And a record without one is just as usable.
        write(channel.file(data), vim.json.encode({ format = channel.FORMAT, channel = "unstable", checked = 1,
            accepted = { version = "0.2.0", asset = "lw-linux-x86_64", sha256 = sha("d"), descriptor = descriptor() } }))
        a = channel.accepted({ channel = "unstable" }, "lw-linux-x86_64", { data = data })
        assert.same({ sha256 = sha("d"), version = "0.2.0", asset = "lw-linux-x86_64", channel = "unstable" }, a)
    end)
end)
