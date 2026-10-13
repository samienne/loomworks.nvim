-- The binary descriptor (spec §16.41): `lw version --json` and the release
-- asset lw-<version>-descriptor.json. It must be the binary half of
-- Root.describe (§19.20) — the same interfaces, versions and schema digests a
-- daemon of this build mounts — valid against its schema, and canonical bytes.

local descriptor = require("loomworks.daemon.descriptor")
local documents = require("loomworks.proto.documents")
local version = require("loomworks.daemon.version")
local core = require("loomworks.daemon.core_interfaces")
local interfaces = require("loomworks.daemon.interfaces")

local function find_iface(doc, path, name)
    for _, o in ipairs(doc.objects) do
        if o.path == path then
            for _, i in ipairs(o.interfaces) do
                if i.name == name then return i, o end
            end
        end
    end
    return nil
end

describe("binary descriptor", function()
    it("is valid against spec/protocol/meta/descriptor.schema.json", function()
        local doc = descriptor.describe()
        local ok, err = documents.set():validate("meta/descriptor.schema.json", "", doc)
        assert.is_true(ok, tostring(err))
        -- The schema really constrains: a descriptor without objects fails.
        local bad = vim.deepcopy(doc)
        bad.objects = nil
        assert.is_false((documents.set():validate("meta/descriptor.schema.json", "", bad)))
    end)

    it("states the transport range, the working-copy schemas and the build's identity", function()
        local doc = descriptor.describe()
        assert.equals(descriptor.FORMAT, doc.descriptor)
        assert.same({ min = version.PROTOCOL_MIN, max = version.PROTOCOL }, doc.transport)
        assert.same(version.schemas(), doc.schemas)
        assert.equals(version.identity(), doc.binary.lw_version)
        assert.equals(interfaces.IMPL, doc.binary.impl)
        assert.equals(version.is_dev(version.identity()), doc.binary.dev)
        assert.same(interfaces.ROOT_METHODS, doc.root_methods)
    end)

    it("lists the root and every core interface with its versions and a schema digest", function()
        local doc = descriptor.describe()
        local root = find_iface(doc, "/", "loomworks.Root")
        assert.truthy(root, "loomworks.Root on /")
        for _, w in ipairs({ core.WORKSPACE, core.TASKS, core.SNAPSHOT, core.BUILD, core.TESTS, core.LAUNCH,
            core.TOOLCHAINS, core.PROFILES }) do
            local i, o = find_iface(doc, w.path, w.iface)
            assert.truthy(i, w.iface .. " on " .. w.path)
            assert.equals("core", o.owner)
            assert.is_true(vim.tbl_contains(i.versions, w.v), w.iface)
            local d = i.schema_digest[tostring(w.v)]
            assert.truthy(type(d) == "string" and d:match("^[0-9a-f]+$") and #d == 64, w.iface .. " digest")
        end
        local snap = find_iface(doc, core.SNAPSHOT.path, core.SNAPSHOT.iface)
        assert.is_true(snap.same_build)
        assert.is_true(snap.internal)
    end)

    it("equals what a real daemon's Root.describe reports for its core objects", function()
        -- A daemon of this build on a real workspace, asked over the loopback
        -- transport (§19.1): its core-owned objects, binary, transport and
        -- root methods are the descriptor's; what modules mount is not in it.
        _G.LOOMWORKS_CLI_NO_AUTORUN = true
        local server_mod = require("loomworks.daemon.server")
        local client = require("loomworks.daemon.client")
        local trust = require("loomworks.trust")
        local H = require("tests.daemon_helpers")
        trust._set_key_path(H.tmp() .. "/trust.key")
        local srv = server_mod.new(H.workspace(), { exit = function() end, tick_ms = 100 })
        -- The build service a daemon runs mounts the core interfaces.
        require("loomworks.daemon.service").attach(srv, require("loomworks.cli")._daemon_build_host())
        local ok, err = pcall(function()
            assert(srv:start_attached({ command = "build" }))
            local conn = assert(client.loopback_session(srv))
            local d = assert(client.call_sync(conn, "/", "loomworks.Root", 1, "describe", {}))
            conn:close()
            local core_objects = {}
            for _, o in ipairs(d.objects) do
                if o.owner == "core" then core_objects[#core_objects + 1] = o end
            end
            local doc = descriptor.describe()
            assert.is_true(#core_objects > 1, vim.inspect(d.objects))
            assert.same(core_objects, doc.objects)
            assert.same(d.transport, doc.transport)
            assert.same(d.root_methods, doc.root_methods)
            assert.equals(d.binary.lw_version, doc.binary.lw_version)
        end)
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
        assert(ok, err)
    end)

    it("encodes canonically: sorted keys, stable bytes, round-trips", function()
        local doc = descriptor.describe()
        local a, b = descriptor.encode(doc), descriptor.encode(descriptor.describe())
        assert.equals(a, b)
        assert.same(doc, vim.json.decode(a))
        local first = a:match('^{%s*"(%w+)"')
        assert.equals("binary", first) -- "binary" < "descriptor" < "objects" ...
    end)
end)
