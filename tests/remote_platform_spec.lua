-- Execution platform + host-executability probe (spec §18.1, invariant 19):
-- kit target-platform tokens flow from kits_from_sdk onto Tools (never into
-- tool data / keys), the header probe classifies ELF / PE / Mach-O, and every
-- local execution path refuses a foreign artifact with a message naming the
-- artifact, the platform and the remedy.

local probe = require("loomworks.remote.probe")
local foreign = require("loomworks.remote.foreign")
local runners = require("loomworks.remote.runners")
local fx = require("tests.remote_fixtures")

describe("remote.probe", function()
    it("classifies ELF headers (class/endianness/machine)", function()
        local i = probe.classify_bytes(fx.elf_header(183))
        assert.same({ format = "elf", arch = "aarch64" }, i)
        assert.equals("x86_64", probe.classify_bytes(fx.elf_header(62)).arch)
        assert.equals("arm", probe.classify_bytes(fx.elf_header(40)).arch)
    end)

    it("classifies PE headers via e_lfanew", function()
        assert.same({ format = "pe", arch = "x86_64" }, probe.classify_bytes(fx.pe_header(0x8664)))
        assert.same({ format = "pe", arch = "aarch64" }, probe.classify_bytes(fx.pe_header(0xAA64)))
    end)

    it("classifies thin and universal Mach-O", function()
        assert.same({ format = "macho", arch = "aarch64" }, probe.classify_bytes(fx.macho_header()))
        local fat = probe.classify_bytes("\202\254\186\190" .. string.rep("\0", 60))
        assert.equals("macho", fat.format)
        assert.is_nil(fat.arch)
    end)

    it("does not judge scripts, short or unknown files", function()
        assert.is_nil(probe.classify_bytes("#!/bin/sh\necho hi\n"))
        assert.is_nil(probe.classify_bytes("MZ"))
        assert.is_nil(probe.read("/definitely/not/here"))
        assert.is_false((probe.mismatch(nil)))
    end)

    it("compares format and architecture with the host", function()
        local win64 = { format = "pe", arch = "x86_64", os = "windows" }
        assert.is_true((probe.mismatch({ format = "elf", arch = "aarch64" }, win64)))
        assert.is_false((probe.mismatch({ format = "pe", arch = "x86_64" }, win64)))
        assert.is_false((probe.mismatch({ format = "pe", arch = "x86" }, win64)))
        assert.is_true((probe.mismatch({ format = "pe", arch = "aarch64" }, win64)))
        -- arm64 Windows runs x64 through emulation
        local winarm = { format = "pe", arch = "aarch64", os = "windows" }
        assert.is_false((probe.mismatch({ format = "pe", arch = "x86_64" }, winarm)))
        local linux = { format = "elf", arch = "x86_64", os = "linux" }
        local m, what = probe.mismatch({ format = "elf", arch = "aarch64" }, linux)
        assert.is_true(m)
        assert.equals("an ELF aarch64 executable", what)
        -- unknown architecture in the file: format equality is enough
        assert.is_false((probe.mismatch({ format = "elf", arch = nil }, linux)))
    end)
end)

describe("kit target platform (cmake.kits_from_sdk)", function()
    local cmake = require("loomworks.modules.cmake")
    local sdk = {
        key = "fake-1", sdk_type = function() return "fake" end,
        sdk_version = function() return "1" end, display_name = function() return "Fake 1" end,
    }

    it("returns a per-arch token beside tool_data, never inside it", function()
        local kits = cmake.kits_from_sdk({ platforms = { {
            name = "Plat", toolchain_file = "/t.cmake", archs = { "a64", "a32", "none" },
            target_platform = { a64 = "plat-aarch64", a32 = "plat-arm" },
        } } }, sdk)
        assert.equals(3, #kits)
        assert.equals("plat-aarch64", kits[1].target_platform)
        assert.equals("plat-arm", kits[2].target_platform)
        assert.is_nil(kits[3].target_platform)
        for _, k in ipairs(kits) do assert.is_nil(k.tool_data.target_platform) end
        -- kit identity unchanged
        assert.equals("fake-plat-a64", cmake.tool_key(kits[1].tool_data))
    end)

    it("a string token applies to every arch", function()
        local kits = cmake.kits_from_sdk({ platforms = { {
            name = "Plat", toolchain_file = "/t.cmake", archs = { "x", "y" }, target_platform = "tok",
        } } }, sdk)
        assert.equals("tok", kits[1].target_platform)
        assert.equals("tok", kits[2].target_platform)
    end)
end)

describe("Tool execution platform plumbing", function()
    local data_model = require("loomworks.data_model")
    local Module = require("loomworks.module")

    it("sync_tools sets the token + SDK from detection and clears it for cache-only tools", function()
        local mod = Module.new("fakemod", { id = "fakemod" })
        local ctx = { modules = { fakemod = mod } }
        local sdk_obj = { key = "S" }
        local tbt = { fakemod = {
            { tool_key = "kit-a", tool_data = { id = "kit-a" }, target_platform = "p-1", sdk = sdk_obj },
            { tool_key = "host", tool_data = { id = "host" } },
        } }
        local cache = { build_dirs = { ["b/x"] = { type = "fakemod", tool_key = "cached", tool_data = {} } } }
        data_model._sync_tools(ctx, { mod }, tbt, cache, { get = function() return nil end })
        local a = mod:find_tool("kit-a")
        assert.equals("p-1", a:execution_platform())
        assert.equals(sdk_obj, a:sdk())
        assert.is_nil(mod:find_tool("host"):execution_platform())
        assert.is_nil(mod:find_tool("cached"):execution_platform())
        -- the token never enters data or key
        assert.is_nil(a.data.target_platform)
        -- a later sync without the token makes the kit host-runnable again
        tbt.fakemod[1].target_platform = nil
        data_model._sync_tools(ctx, { mod }, tbt, cache, { get = function() return nil end })
        assert.is_nil(a:execution_platform())
    end)
end)

describe("foreign artifacts never run on the host", function()
    local tmp
    before_each(function()
        tmp = fx.mkroot()
    end)
    after_each(function()
        require("loomworks.io").rm_rf(tmp)
        runners._reset()
    end)

    it("classify: a token makes an artifact foreign without probing", function()
        local unit = fx.fake_unit({ token = "plat-aarch64", tool_key = "kit-x" })
        local f = foreign.classify(unit, tmp .. "/nonexistent")
        assert.equals("token", f.reason)
        assert.equals("plat-aarch64", f.platform)
        local msg = foreign.refusal(f)
        assert.truthy(msg:find("nonexistent was built for plat-aarch64 by kit kit-x", 1, true))
        assert.truthy(msg:find("No device runner serves that platform", 1, true))
    end)

    it("classify: a probe mismatch without a token is refused, never routed", function()
        local exe = fx.write_foreign_exe(tmp .. "/app")
        local f = foreign.classify(fx.fake_unit({}), exe)
        assert.equals("probe", f.reason)
        assert.is_nil(f.platform)
        local ok, err = foreign.check_local(fx.fake_unit({}), exe)
        assert.is_nil(ok)
        assert.truthy(err:find("this host", 1, true))
        assert.truthy(err:find("cannot be routed to a device", 1, true))
    end)

    it("a host-format executable passes", function()
        local exe = fx.write_host_exe(tmp .. "/app")
        assert.is_true(foreign.check_local(fx.fake_unit({}), exe))
    end)

    it("the refusal names the runner when one serves the platform", function()
        local sdk = fx.fake_sdk(fx.fake_runner_table())
        local unit = fx.fake_unit({ token = "fake-arm64", sdk = sdk, tool_key = "kit" })
        local msg = foreign.refusal(foreign.classify(unit, tmp .. "/x"))
        assert.truthy(msg:find("device runner 'fake'", 1, true))
    end)

    it("Target:resolve_run_spec refuses a foreign artifact (no exit-127 attempt)", function()
        local exe = fx.write_foreign_exe(tmp .. "/bin/app")
        local unit = fx.fake_unit({ build_dir = tmp })
        local Target = require("loomworks.target")
        local t = Target.new(unit, "app", { type = "executable", artifact = "bin/app" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.truthy(err:find("this host", 1, true))
    end)

    it("gtest discovery probes never execute a foreign binary", function()
        local exe = fx.write_foreign_exe(tmp .. "/t")
        local gtest = require("loomworks.gtest")
        local fw, list, diag = gtest.probe_sync(exe, "t")
        assert.is_nil(fw)
        assert.is_nil(list)
        assert.truthy(diag:find("not probed", 1, true))
    end)
end)

describe("runner registry validation", function()
    it("accepts the full contract and rejects malformed runners", function()
        assert.is_true(runners.validate(fx.fake_runner_table()))
        local bad = fx.fake_runner_table(); bad.staging_base = "relative"
        assert.is_false((runners.validate(bad)))
        bad = fx.fake_runner_table(); bad.staging_base = "/"
        assert.is_false((runners.validate(bad)))
        bad = fx.fake_runner_table(); bad.staging_base = "/data/../etc"
        assert.is_false((runners.validate(bad)))
        bad = fx.fake_runner_table(); bad.exec = nil
        local ok, err = runners.validate(bad)
        assert.is_false(ok)
        assert.truthy(err:find("exec", 1, true))
        bad = fx.fake_runner_table(); bad.platforms = {}
        assert.is_false((runners.validate(bad)))
    end)

    it("for_foreign requires the runner to list the kit's token", function()
        runners._reset()
        local sdk = fx.fake_sdk(fx.fake_runner_table())
        local r = runners.for_foreign({ platform = "fake-arm64", sdk = sdk })
        assert.equals("fake", r.id)
        local none, err = runners.for_foreign({ platform = "other", sdk = sdk })
        assert.is_nil(none)
        assert.truthy(err:find("does not serve other", 1, true))
        runners._reset()
    end)
end)
