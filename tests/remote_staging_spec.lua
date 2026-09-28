-- Deploy manifest + staging (spec §18.4, §18.9, §18.12): the manifest mirrors
-- the build layout (artifact, derived libraries, runtime files, stage and
-- archive globs), sync is digest-based and incremental with a per-device
-- record, archive sets travel as one tar, `fresh` re-stages everything, a
-- wiped device is detected through the runner's digest, removed files are
-- removed from the device, and every device-side removal stays under the
-- workspace staging prefix.

local manifest = require("loomworks.remote.manifest")
local staging = require("loomworks.remote.staging")
local transport_mod = require("loomworks.remote.transport")
local fx = require("tests.remote_fixtures")

local function build_tree(root)
    fx.write_foreign_exe(root .. "/test/unit/Runner")
    fx.write(root .. "/lib/libcore.so", "core-v1")
    fx.write(root .. "/lib/libdep.so", "dep-v1")
    fx.write(root .. "/test/unit/libcopied.so", "copied")
    fx.write(root .. "/test/unit/plugins/libp1.so", "p1")
    fx.write(root .. "/test/unit/plugins/readme.txt", "not staged")
    fx.write(root .. "/test/assets/data/a.bin", "AAAA")
    fx.write(root .. "/test/assets/data/deep/b.bin", "BBBB")
    fx.write(root .. "/.device-runs/old/output.log", "never staged")
    fx.write(root .. "/CMakeFiles/x.o", "object")
end

local function unit_with_targets(root)
    local targets = {
        Runner = { type = "executable", artifact = "test/unit/Runner", dependencies = { "core" } },
        core = { type = "shared_library", artifact = "lib/libcore.so", dependencies = { "dep", "stat" } },
        dep = { type = "shared_library", artifact = "lib/libdep.so" },
        stat = { type = "static_library", artifact = "lib/libstat.a" },
        other = { type = "shared_library", artifact = "lib/libother.so" },
    }
    return fx.fake_unit({ build_dir = root, targets = targets, token = "fake-arm64" }), targets
end

describe("remote.manifest", function()
    local root, rt
    before_each(function()
        root = fx.mkroot()
        build_tree(root)
        rt = fx.write(fx.mkroot() .. "/sysroot/libc++_shared.so", "stl")
    end)
    after_each(function() require("loomworks.io").rm_rf(root) end)

    it("globs: ** spans levels, * stays in a segment", function()
        assert.is_true(manifest.glob_match("test/**", "test/a/b/c"))
        assert.is_true(manifest.glob_match("test/**/b.bin", "test/b.bin"))
        assert.is_true(manifest.glob_match("test/**/b.bin", "test/x/y/b.bin"))
        assert.is_false(manifest.glob_match("test/**/b.bin", "test/xb.bin"))
        assert.is_true(manifest.glob_match("a/*.so", "a/libx.so"))
        assert.is_false(manifest.glob_match("a/*.so", "a/p/libx.so"))
        assert.is_true(manifest.glob_match("a/lib?.so", "a/lib1.so"))
    end)

    it("refuses absolute and escaping patterns", function()
        assert.is_false((manifest.validate_pattern("/etc/**")))
        assert.is_false((manifest.validate_pattern("C:/x/*")))
        assert.is_false((manifest.validate_pattern("../outside/*")))
        assert.is_false((manifest.validate_pattern("a/../../b")))
        assert.is_true((manifest.validate_pattern("test/assets/**")))
        local ok, err = manifest.validate_block({ stage = { "../x" } }, "project 'P'")
        assert.is_false(ok)
        assert.truthy(err:find("project 'P'", 1, true))
        ok, err = manifest.validate_block({ stag = {} }, "p")
        assert.truthy(err:find("unknown device field 'stag'", 1, true))
        assert.is_false((manifest.validate_block({ env = { ["BAD-NAME"] = "x" } }, "p")))
        assert.is_true((manifest.validate_block({ env = { OK = "1" }, working_dir = "test/unit" }, "p")))
    end)

    it("a launch-level block replaces the project block field by field", function()
        local eff = manifest.effective_block({ stage = { "a" }, env = { A = "1" } },
            { env = { B = "2" }, working_dir = "w" })
        assert.same({ stage = { "a" }, env = { B = "2" }, working_dir = "w" }, eff)
    end)

    it("builds the union: artifact, transitive shared deps, runtime files, stage, archive", function()
        local unit, targets = unit_with_targets(root)
        local r = fx.fake_runner_table({ runtime_file = rt })
        local m = assert(manifest.build({
            build_dir = root, artifact = root .. "/test/unit/Runner", unit = unit, target = targets.Runner,
            runner = r, tool = unit:tool_object(),
            device = { stage = { "test/unit/*.so", "test/unit/plugins/*.so" }, archive = { "test/assets/**" } },
        }))
        local rels = {}
        for _, f in ipairs(m.files) do rels[#rels + 1] = f.rel .. ":" .. f.kind end
        assert.same({
            "lib/libcore.so:library", "lib/libdep.so:library",
            "test/unit/Runner:artifact", "test/unit/libcopied.so:stage",
            "test/unit/librt.so:runtime", "test/unit/plugins/libp1.so:stage",
        }, rels)
        assert.equals(1, #m.archives)
        assert.equals(2, #m.archives[1].members)
        assert.same({ "lib", "test/unit", "test/unit/plugins" }, m.library_rels)
        assert.equals("test/unit/Runner", m.artifact)
        assert.equals(unit:tool_object(), r.runtime_tool_seen)
    end)

    it("without archive support archive globs are staged file by file", function()
        local unit, targets = unit_with_targets(root)
        local m = assert(manifest.build({
            build_dir = root, artifact = root .. "/test/unit/Runner", unit = unit, target = targets.Runner,
            runner = fx.fake_runner_table({ archive = false }), device = { archive = { "test/assets/**" } },
        }))
        assert.equals(0, #m.archives)
        local n = 0
        for _, f in ipairs(m.files) do if f.kind == "archive" then n = n + 1 end end
        assert.equals(2, n)
    end)

    it("a missing derived library or an out-of-tree one is an error naming it", function()
        local unit, targets = unit_with_targets(root)
        os.remove(root .. "/lib/libdep.so")
        local m, err = manifest.build({ build_dir = root, artifact = root .. "/test/unit/Runner",
            unit = unit, target = targets.Runner, runner = fx.fake_runner_table() })
        assert.is_nil(m)
        assert.truthy(err:find("library dep", 1, true))
        fx.write(root .. "/lib/libdep.so", "dep-v1")
        targets.dep.artifact = "C:/elsewhere/libdep.so"
        if package.config:sub(1, 1) ~= "\\" then targets.dep.artifact = "/elsewhere/libdep.so" end
        m, err = manifest.build({ build_dir = root, artifact = root .. "/test/unit/Runner",
            unit = unit, target = targets.Runner, runner = fx.fake_runner_table() })
        assert.is_nil(m)
        assert.truthy(err:find("outside the build directory", 1, true))
        assert.truthy(err:find("device.stage", 1, true))
    end)

    it("device roots are sanitized and removal stays under the workspace prefix", function()
        local wsp, unit_root = manifest.device_roots("/data/stage/", "my ws", "build/App/Debug")
        assert.equals("/data/stage/my_ws", wsp)
        local hash = vim.fn.sha256("build/App/Debug"):sub(1, 10)
        assert.equals("/data/stage/my_ws/Debug-" .. hash, unit_root)
        assert.is_true(manifest.device_path_under(unit_root .. "/x", wsp))
        assert.is_true(manifest.device_path_under(wsp, wsp))
        assert.is_false(manifest.device_path_under("/data/stage/my_ws2/x", wsp))
        assert.is_false(manifest.device_path_under(wsp .. "/../etc", wsp))
        assert.is_false(manifest.device_path_under("/data", wsp))
        assert.equals("_..", manifest.segment(".."))
    end)

    it("device roots stay short and deterministic (the device truncates process names at 128 bytes)", function()
        -- The real run: a unit id that is a long build-dir path.
        local id = "build_LumeScene_ohos-openharmony-arm64-v8a_OhosRelease"
        local base = "/data/local/tmp/.device-staging"
        local wsp, r1 = manifest.device_roots(base, "LumeScene-ohos", id)
        local _, r2 = manifest.device_roots(base, "LumeScene-ohos", id)
        assert.equals(r1, r2)
        assert.equals(base .. "/LumeScene-ohos", wsp)
        local unit_seg = r1:sub(#wsp + 2)
        assert.is_true(#unit_seg <= 23, unit_seg)
        assert.truthy(unit_seg:match("^[%w%._%-]+%-%x%x%x%x%x%x%x%x%x%x$"), unit_seg)
        -- Different units never share a root, even with the same readable tail.
        local _, r3 = manifest.device_roots(base, "LumeScene-ohos", "build/other/OhosRelease")
        assert.are_not.equal(r1, r3)
        -- A long workspace name is shortened (readable prefix + hash), a short
        -- one kept as is.
        local long = string.rep("VeryLongWorkspaceName", 3)
        local wsl = manifest.device_roots(base, long, id)
        local seg = wsl:sub(#base + 2)
        assert.is_true(#seg <= 24, seg)
        assert.are_not.equal(manifest.device_roots(base, long .. "x", id), wsl)
        -- The run's program path on the device stays well under 128 bytes.
        local program = r1 .. "/test/unittest/api_unit_test/LumeSceneAPITestRunner"
        assert.is_true(#program < 128, tostring(#program))
    end)
end)

describe("remote.staging (fake device)", function()
    local root, dev, r, t, unit, targets
    local ws_prefix, droot = "/data/stage/ws", "/data/stage/ws/build_App_Debug"

    local function make_manifest(block)
        return assert(manifest.build({
            build_dir = root, artifact = root .. "/test/unit/Runner", unit = unit, target = targets.Runner,
            runner = r, device = block or { stage = { "test/unit/*.so" }, archive = { "test/assets/**" } },
        }))
    end
    local function stage(record, fresh, block)
        return staging.stage({ transport = t, manifest = make_manifest(block), ws_prefix = ws_prefix,
            root = droot, record = record, fresh = fresh, tmp_dir = root .. "/.device-runs/.tmp" })
    end

    before_each(function()
        root = fx.mkroot()
        build_tree(root)
        dev = fx.device()
        r = fx.fake_runner_table()
        t = transport_mod.new({ runner = r, serial = "SER1", backend = dev:backend() })
        unit, targets = unit_with_targets(root)
    end)
    after_each(function() require("loomworks.io").rm_rf(root) end)

    it("mirrors the build layout, marks the program executable, unpacks the archive", function()
        local rec, rep = stage(nil, false)
        assert.is_table(rec, rep)
        local b = dev.boards.SER1
        assert.equals("755", b.files[droot .. "/test/unit/Runner"].mode)
        assert.equals("core-v1", b.files[droot .. "/lib/libcore.so"].data)
        assert.equals("copied", b.files[droot .. "/test/unit/libcopied.so"].data)
        assert.equals("AAAA", b.files[droot .. "/test/assets/data/a.bin"].data)
        assert.equals("BBBB", b.files[droot .. "/test/assets/data/deep/b.bin"].data)
        assert.is_nil(b.files[droot .. "/CMakeFiles/x.o"])
        assert.equals(4, rep.sent)
        assert.equals(1, rep.archives_sent)
        -- one push per file + the archive + its completion marker; never a
        -- directory push
        assert.equals(6, #dev:ops("push"))
        -- The archive is deleted after unpacking (it doubled the space); only a
        -- small marker stays, recording the set's digest.
        local markers = {}
        for p, f in pairs(b.files) do
            assert.is_nil(p:match("%.tar$"), "archive left on the device: " .. p)
            if p:find(droot .. "/.loomworks/", 1, true) then markers[#markers + 1] = { p = p, f = f } end
        end
        assert.equals(1, #markers)
        assert.truthy(markers[1].p:match("/%.loomworks/archive%-%x+%.ok$"), markers[1].p)
        assert.equals(rec.archives["test/assets/**"].digest, markers[1].f.data)
        assert.truthy(staging.summary("SER1", rep):find("staging on SER1: 4 changed files", 1, true))
    end)

    it("second run sends only changed files; the unchanged archive is skipped", function()
        local rec = assert(stage(nil, false))
        dev.calls = {}
        fx.write(root .. "/lib/libcore.so", "core-v2")
        local rec2, rep = stage(rec, false)
        assert.is_table(rec2, rep)
        assert.equals(1, rep.sent)
        assert.equals(3, rep.unchanged)
        assert.equals(0, rep.archives_sent)
        assert.equals(1, rep.archives_unchanged)
        assert.is_true(rep.verified)
        local pushes = dev:ops("push")
        assert.equals(1, #pushes)
        assert.truthy(pushes[1].args[3]:find("libcore.so", 1, true))
        assert.equals("core-v2", dev.boards.SER1.files[droot .. "/lib/libcore.so"].data)
        -- an archive member change re-sends the archive
        fx.write(root .. "/test/assets/data/a.bin", "A2")
        local _, rep3 = stage(rec2, false)
        assert.equals(1, rep3.archives_sent)
        assert.equals("A2", dev.boards.SER1.files[droot .. "/test/assets/data/a.bin"].data)
    end)

    it("a wiped device is detected through the runner digest and re-staged", function()
        local rec = assert(stage(nil, false))
        dev.boards.SER1.files = {}
        local _, rep = stage(rec, false)
        assert.equals(4, rep.sent)
        assert.equals(1, rep.archives_sent)
        assert.is_not_nil(dev.boards.SER1.files[droot .. "/test/unit/Runner"])
    end)

    it("an archive set is re-sent when its marker or a sampled member is gone or changed on the device", function()
        local rec = assert(stage(nil, false))
        local b = dev.boards.SER1
        local marker
        for p in pairs(b.files) do if p:match("%.ok$") then marker = p end end
        assert.is_not_nil(marker)
        -- Marker gone (an interrupted unpack never writes it; a partial wipe).
        b.files[marker] = nil
        local rec2, rep = stage(rec, false)
        assert.equals(1, rep.archives_sent)
        assert.equals(0, rep.sent)
        -- A sampled member changed on the device.
        b.files[droot .. "/test/assets/data/a.bin"].data = "tampered"
        local _, rep3 = stage(rec2, false)
        assert.equals(1, rep3.archives_sent)
        assert.equals("AAAA", b.files[droot .. "/test/assets/data/a.bin"].data)
    end)

    it("a record from the tar-keeping scheme re-sends the set once and removes the old archive", function()
        local rec = assert(stage(nil, false))
        local b = dev.boards.SER1
        local a = rec.archives["test/assets/**"]
        -- The earlier record shape: the tar kept on the device, no marker.
        local old_tar = ".loomworks/archive-0123456789ab.tar"
        b.files[droot .. "/" .. old_tar] = { data = "old tar" }
        rec.archives["test/assets/**"] = { digest = a.digest, tar = old_tar,
            remote = vim.fn.sha256("old tar"), locals = a.locals }
        local rec2, rep = stage(rec, false)
        assert.is_table(rec2, rep)
        assert.equals(1, rep.archives_sent)
        assert.is_nil(b.files[droot .. "/" .. old_tar])
        assert.is_nil(rec2.archives["test/assets/**"].tar)
        local _, rep3 = stage(rec2, false)
        assert.equals(0, rep3.archives_sent)
        assert.equals(1, rep3.archives_unchanged)
    end)

    it("without a runner digest the record is trusted; fresh forces a full re-stage", function()
        r = fx.fake_runner_table({ digest = false })
        t = transport_mod.new({ runner = r, serial = "SER1", backend = dev:backend() })
        local rec = assert(stage(nil, false))
        dev.boards.SER1.files = {}
        local _, rep = stage(rec, false)
        assert.equals(0, rep.sent) -- trusted record: nothing re-sent
        local _, rep2 = stage(rec, true)
        assert.equals(4, rep2.sent)
        assert.equals(1, rep2.archives_sent)
        assert.equals(0, #dev:ops("fakesum") + #vim.tbl_filter(function(c)
            return c.req and c.req.argv[1] == "fakesum" end, dev.calls))
    end)

    it("files that left the manifest are removed from the device", function()
        local rec = assert(stage(nil, false))
        local rec2, rep = stage(rec, false, { stage = {}, archive = {} })
        assert.is_table(rec2, rep)
        assert.is_true(rep.removed >= 2)
        local b = dev.boards.SER1
        assert.is_nil(b.files[droot .. "/test/unit/libcopied.so"])
        assert.is_nil(b.files[droot .. "/test/assets/data/a.bin"])
        assert.is_not_nil(b.files[droot .. "/test/unit/Runner"])
        for _, c in ipairs(dev.calls) do
            if c.req and c.req.argv[1] == "rm" then
                for k = 3, #c.req.argv do
                    assert.is_true(manifest.device_path_under(c.req.argv[k], ws_prefix))
                end
            end
        end
    end)

    it("a transfer the connector rejects (printed with exit 0) fails staging, naming the file", function()
        dev.fail_push = "libdep"
        local rec, err = stage(nil, false)
        assert.is_nil(rec)
        assert.truthy(err:find("push " .. droot .. "/lib/libdep.so", 1, true))
        assert.truthy(err:find("[Fail]transfer rejected", 1, true))
    end)

    it("clean removes the whole workspace staging tree, and nothing outside it", function()
        assert(stage(nil, false))
        dev.boards.SER1.files["/data/stage/other/keep"] = { data = "x" }
        assert.is_true(staging.clean(t, ws_prefix, "/data/stage"))
        for p in pairs(dev.boards.SER1.files) do
            assert.is_false(manifest.device_path_under(p, ws_prefix))
        end
        assert.is_not_nil(dev.boards.SER1.files["/data/stage/other/keep"])
        local ok, err = staging.clean(t, "/data/stage", "/data/stage")
        assert.is_nil(ok)
        assert.truthy(err:find("refusing", 1, true))
        ok = staging.clean(t, "/data", "/data/stage")
        assert.is_nil(ok)
    end)
end)
