-- The plugin pin (spec §19.16 "Plugin pin", step 5h.4): the plugin carries
-- the lw release it downloads in daemon mode (loomworks.provision.pinned,
-- written by scripts/release/pin.sh from a release's signed SHA256SUMS);
-- managed.wanted() is this host's asset of it; the pin is checked against
-- the release (signature, hashes, descriptor interfaces, pin-commit diff) and
-- never ships in the lw bundle.

local managed = require("loomworks.provision.managed")
local needs = require("loomworks.provision.needs")
local pin = dofile("scripts/release/pin.lua")

local sha_a = string.rep("a", 64)
local sha_b = string.rep("b", 64)
local sha_c = string.rep("c", 64)
local fake_pin = {
    version = "0.1.50",
    assets = { ["lw-linux-x86_64"] = sha_a, ["lw-macos-arm64"] = sha_b, ["lw-windows-x86_64.exe"] = sha_c },
}

local function exe(name) return vim.fn.executable(name) == 1 end

--- This build's descriptor, as release <version> would publish it.
local function release_descriptor(version)
    local d = require("loomworks.daemon.descriptor").describe()
    d.binary = { lw_version = version, impl = d.binary.impl, dev = false }
    return d
end

describe("managed.wanted (the plugin pin)", function()
    it("keeps its own host-asset table equal to lw's", function()
        assert.same(require("boot.pin").HOST_ASSETS, managed.HOST_ASSETS)
    end)

    it("maps uname values to the published asset, or says why not", function()
        assert.equals("lw-windows-x86_64.exe", managed.host_asset("Windows_NT", "x86_64"))
        assert.equals("lw-windows-x86_64.exe", managed.host_asset("Windows_NT", "AMD64"))
        assert.equals("lw-linux-x86_64", managed.host_asset("Linux", "x86_64"))
        assert.equals("lw-macos-arm64", managed.host_asset("Darwin", "arm64"))
        local a, why = managed.host_asset("Linux", "aarch64")
        assert.is_nil(a); assert.truthy(why:find("linux/arm64", 1, true))
        a, why = managed.host_asset("Plan9", "x86_64")
        assert.is_nil(a); assert.truthy(why:find("no published lw", 1, true))
        assert.truthy(managed.host_asset() or true) -- this host: no error
    end)

    it("is this host's asset of the pin", function()
        local w = managed.wanted({ pinned = fake_pin, sysname = "Darwin", machine = "arm64" })
        assert.same({ sha256 = sha_b, version = "0.1.50", asset = "lw-macos-arm64" }, w)
        w = managed.wanted({ pinned = fake_pin, sysname = "Windows_NT", machine = "x86_64" })
        assert.same({ sha256 = sha_c, version = "0.1.50", asset = "lw-windows-x86_64.exe" }, w)
    end)

    it("wants nothing on an unsupported host, a pin without the asset, an invalid pin", function()
        local w, why = managed.wanted({ pinned = fake_pin, sysname = "Linux", machine = "riscv64" })
        assert.is_nil(w); assert.truthy(why:find("no published lw for linux/riscv64", 1, true))
        w, why = managed.wanted({ pinned = { version = "0.1.50", assets = {} }, sysname = "Linux", machine = "x86_64" })
        assert.is_nil(w); assert.truthy(why:find("has no lw-linux-x86_64", 1, true))
        w, why = managed.wanted({ pinned = { version = "0.1.50", assets = { ["lw-linux-x86_64"] = "zz" } },
            sysname = "Linux", machine = "x86_64" })
        assert.is_nil(w); assert.truthy(why:find("invalid plugin pin", 1, true))
        w, why = managed.wanted({ pinned = { version = "../x", assets = { ["lw-linux-x86_64"] = sha_a } },
            sysname = "Linux", machine = "x86_64" })
        assert.is_nil(w); assert.truthy(why:find("invalid plugin pin", 1, true))
        w, why = managed.wanted({ pinned = false })
        assert.is_nil(w); assert.equals(managed.NOT_YET, why)
    end)

    it("defaults to the committed pin, so find offers a download when it is missing", function()
        local committed = require("loomworks.provision.pinned")
        local w = managed.wanted()
        if managed.host_asset() then
            assert.equals(committed.version, w.version)
            assert.equals(committed.assets[w.asset], w.sha256)
            local got, why, missing = managed.find({ data = "/nonexistent-data", exists = function() return false end })
            assert.is_nil(got); assert.truthy(why:find("not installed", 1, true))
            assert.same(w, missing)
        end
    end)

    it("the committed pin names one valid hash per host asset and nothing else", function()
        local f = assert(io.open("lua/loomworks/provision/pinned.lua", "rb"))
        local loaded = assert(pin.load_pinned(f:read("*a")))
        f:close()
        assert.is_true(require("loomworks.provision.fetch").valid_version(loaded.version))
        local sums = {}
        for _, a in pairs(managed.HOST_ASSETS) do
            assert.truthy(type(loaded.assets[a]) == "string" and #loaded.assets[a] == 64
                and loaded.assets[a]:match("^%x+$"), a)
            sums[a] = loaded.assets[a]
        end
        assert.same({}, pin.check_pinned(loaded, loaded.version, sums))
    end)
end)

describe("needs.check (the interfaces the plugin needs)", function()
    it("passes this build's own descriptor", function()
        local ok, problems = needs.check(release_descriptor("9.9.9"))
        assert.same({}, problems); assert.is_true(ok)
    end)

    it("names a missing interface, a too-old version, a disjoint transport, newer schemas", function()
        local d = release_descriptor("9.9.9")
        for i = #d.objects, 1, -1 do
            if d.objects[i].path == "/tasks" then table.remove(d.objects, i) end
        end
        local ok, problems = needs.check(d)
        assert.is_false(ok)
        assert.truthy(table.concat(problems, "\n"):find("/tasks loomworks.Tasks/1 is not offered", 1, true))

        d = release_descriptor("9.9.9")
        for _, o in ipairs(d.objects) do
            if o.path == "/workspace" then
                for _, i in ipairs(o.interfaces) do i.versions = { 2 } end
            end
        end
        _, problems = needs.check(d)
        assert.truthy(table.concat(problems, "\n"):find("/workspace loomworks.Workspace/1 is not offered", 1, true))

        d = release_descriptor("9.9.9")
        d.transport = { min = 99, max = 120 }
        _, problems = needs.check(d)
        assert.truthy(table.concat(problems, "\n"):find("does not overlap", 1, true))

        d = release_descriptor("9.9.9")
        d.schemas = { user = d.schemas.user + 1, cache = d.schemas.cache }
        _, problems = needs.check(d)
        assert.truthy(table.concat(problems, "\n"):find("schemas", 1, true))

        ok, problems = needs.check(nil)
        assert.is_false(ok); assert.same({ "no descriptor" }, problems)
    end)
end)

describe("scripts/release/pin.lua", function()
    local sums_text = sha_a .. "  lw-linux-x86_64\n" .. sha_b .. " *lw-macos-arm64\n"
        .. sha_c .. "  lw-windows-x86_64.exe\n" .. string.rep("d", 64) .. "  manifest.json\n"

    it("parses SHA256SUMS and renders a pin that loads back", function()
        local sums = pin.parse_sums(sums_text)
        assert.equals(sha_b, sums["lw-macos-arm64"])
        local text = assert(pin.render("0.1.50", sums))
        local loaded = assert(pin.load_pinned(text))
        assert.same(fake_pin, loaded)
        assert.same({}, pin.check_pinned(loaded, "0.1.50", sums))
        local _, why = pin.render("0.1.50", { ["lw-linux-x86_64"] = sha_a })
        assert.truthy(why:find("SHA256SUMS lists no", 1, true))
        assert.is_nil(pin.render("../x", sums))
    end)

    it("refuses a pin that differs from the signed hashes", function()
        local sums = pin.parse_sums(sums_text)
        local bad = vim.deepcopy(fake_pin)
        bad.version = "0.1.49"
        bad.assets["lw-linux-x86_64"] = sha_b
        bad.assets["lw-other"] = sha_a
        bad.assets["lw-macos-arm64"] = nil
        local p = table.concat(pin.check_pinned(bad, "0.1.50", sums), "\n")
        assert.truthy(p:find("names 0.1.49, not 0.1.50", 1, true))
        assert.truthy(p:find("lw-linux-x86_64 = " .. sha_b, 1, true))
        assert.truthy(p:find("has no lw-macos-arm64", 1, true))
        assert.truthy(p:find("unknown asset lw-other", 1, true))
        assert.is_nil(pin.load_pinned("os.exit(1)"))
    end)

    it("allows only pinned.lua in the pin commit", function()
        assert.same({}, pin.check_diff({ "lua/loomworks/provision/pinned.lua" }))
        assert.equals(1, #pin.check_diff({ "lua/loomworks/provision/pinned.lua", "lua/loomworks/cli.lua" }))
        assert.equals(1, #pin.check_diff({}))
    end)

    it("checks the descriptor names the release and offers the interfaces", function()
        assert.same({}, pin.check_descriptor(release_descriptor("0.1.50"), "0.1.50"))
        local p = pin.check_descriptor(release_descriptor("0.1.49"), "0.1.50")
        assert.truthy(p[1]:find("not release 0.1.50", 1, true))
        assert.truthy(pin.check_descriptor(nil, "0.1.50")[1]:find("no lw-0.1.50-descriptor.json", 1, true))
    end)

    describe("write / verify against a signed release directory", function()
        if not exe("openssl") then
            pending("openssl is not on the search path")
            return
        end
        local priv = "tests/fixtures/dist/test_ec_priv.pem"
        local pub = "tests/fixtures/dist/test_ec_pub.pem"
        local dir, out

        local function put(path, text)
            local f = assert(io.open(path, "wb")); f:write(text); f:close()
        end
        local function sign()
            local r = vim.system({ "openssl", "dgst", "-sha256", "-sign", priv, "-out", dir .. "/SHA256SUMS.sig",
                dir .. "/SHA256SUMS" }):wait()
            assert.equals(0, r.code, r.stderr)
        end
        --- A release dir: host binaries, the descriptor, signed SHA256SUMS.
        local function release(version, d)
            local sha = require("loomworks.provision.sha256")
            local lines = {}
            for _, a in ipairs({ "lw-linux-x86_64", "lw-macos-arm64", "lw-windows-x86_64.exe" }) do
                put(dir .. "/" .. a, "binary " .. a)
                lines[#lines + 1] = sha.file(dir .. "/" .. a) .. "  " .. a
            end
            local dname = "lw-" .. version .. "-descriptor.json"
            put(dir .. "/" .. dname, require("loomworks.daemon.descriptor").encode(d))
            lines[#lines + 1] = sha.file(dir .. "/" .. dname) .. "  " .. dname
            put(dir .. "/SHA256SUMS", table.concat(lines, "\n") .. "\n")
            sign()
        end

        before_each(function()
            dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            out = dir .. "/pinned.lua"
        end)
        after_each(function() vim.fn.delete(dir, "rf") end)

        it("writes a pin that then verifies", function()
            release("0.1.50", release_descriptor("0.1.50"))
            assert.same({}, pin.write("0.1.50", dir, { pub = pub, out = out }))
            assert.same({}, pin.verify("0.1.50", dir, { pub = pub, pinned = out }))
            local loaded = assert(pin.load_pinned(table.concat(vim.fn.readfile(out), "\n")))
            assert.equals("0.1.50", loaded.version)
        end)

        it("refuses a bad signature, a tampered asset, a descriptor without the interfaces", function()
            release("0.1.50", release_descriptor("0.1.50"))
            assert.same({}, pin.write("0.1.50", dir, { pub = pub, out = out }))
            -- Not signed by the release key.
            local p = pin.write("0.1.50", dir, { out = out })
            assert.truthy(p[1]:find("does not verify", 1, true))
            -- An asset in the dir that does not match the signed hash.
            put(dir .. "/lw-linux-x86_64", "tampered")
            p = table.concat(pin.verify("0.1.50", dir, { pub = pub, pinned = out }), "\n")
            assert.truthy(p:find("lw-linux-x86_64 has SHA-256", 1, true))
            -- SHA256SUMS edited after signing.
            put(dir .. "/SHA256SUMS", "x")
            p = pin.verify("0.1.50", dir, { pub = pub, pinned = out })
            assert.truthy(p[1]:find("does not verify", 1, true))
            -- A release missing an interface the plugin needs: never pinned.
            local d = release_descriptor("0.1.51")
            d.objects = {}
            release("0.1.51", d)
            p = table.concat(pin.write("0.1.51", dir, { pub = pub, out = out .. "2" }), "\n")
            assert.truthy(p:find("is not offered", 1, true))
            assert.equals(0, vim.fn.filereadable(out .. "2"))
            assert.same({}, pin.write("0.1.51", dir, { pub = pub, out = out .. "2", no_interface_check = true }))
        end)

        it("checks the pin commit on top of the build commit", function()
            release("0.1.50", release_descriptor("0.1.50"))
            assert.same({}, pin.write("0.1.50", dir, { pub = pub, out = out }))
            local calls = {}
            local function run(names, ancestor)
                return function(cmd)
                    calls[#calls + 1] = table.concat(cmd, " ")
                    if cmd[1] ~= "git" then return vim.system(cmd):wait().code, "" end
                    if cmd[4] == "merge-base" then return ancestor and 0 or 1, "" end
                    return 0, names
                end
            end
            local o = { pub = pub, pinned = out, base = "C", head = "vX" }
            o.run = run("lua/loomworks/provision/pinned.lua\n", true)
            assert.same({}, pin.verify("0.1.50", dir, o))
            assert.truthy(table.concat(calls, "\n"):find("diff --name-only C vX", 1, true))
            o.run = run("lua/loomworks/provision/pinned.lua\nlua/loomworks/cli.lua\n", true)
            assert.truthy(pin.verify("0.1.50", dir, o)[1]:find("changes lua/loomworks/cli.lua", 1, true))
            o.run = run("", false)
            assert.truthy(pin.verify("0.1.50", dir, o)[1]:find("not an ancestor", 1, true))
        end)

        it("--warn reports problems as warnings and exits 0", function()
            release("0.1.50", release_descriptor("0.1.49"))
            local outbuf = {}
            local say = pin.say
            pin.say = function(s) outbuf[#outbuf + 1] = s end
            local code = pin.main({ "verify", "0.1.50", dir, "--pub", pub, "--pinned", out, "--warn" })
            pin.say = say
            assert.equals(0, code)
            assert.truthy(table.concat(outbuf):find("::warning title=lw pin::", 1, true))
            assert.equals(1, pin.main({ "verify", "0.1.50", dir, "--pub", pub, "--pinned", out }))
        end)
    end)
end)

describe("the lw bundle", function()
    it("never carries the plugin pin", function()
        if not (exe("bash") and exe("python3") and exe("openssl")) then
            pending("bash, python3 and openssl are needed to build a bundle")
            return
        end
        local dist = vim.fn.tempname()
        local r = vim.system({ "bash", "scripts/release/build_bundle.sh", "0.0.0-test", dist,
            "tests/fixtures/dist/test_ec_priv.pem" }, { text = true }):wait()
        assert.equals(0, r.code, r.stderr)
        local l = vim.system({ "python3", "-m", "zipfile", "-l", dist .. "/loomworks-lua-0.0.0-test.zip" },
            { text = true }):wait()
        vim.fn.delete(dist, "rf")
        assert.equals(0, l.code, l.stderr)
        assert.truthy(l.stdout:find("loomworks/provision/managed.lua", 1, true))
        assert.is_nil(l.stdout:find("loomworks/provision/pinned.lua", 1, true))
    end)
end)
