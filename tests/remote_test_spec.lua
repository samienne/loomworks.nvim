-- `lw test --target <exe>` (spec §16.16, §18.6): named test executables run
-- directly — on a device when foreign — with gtest's XML results option
-- pointed at a device-side file that is pulled back and parsed with the same
-- parser as local results. Failure = non-zero exit OR a failed test in the
-- XML OR a missing XML when requested OR a crash. Plain (batch-runner) `lw
-- test` refuses on a foreign profile.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local runners = require("loomworks.remote.runners")
local test_run = require("loomworks.remote.test_run")
local Target = require("loomworks.target")
local fx = require("tests.remote_fixtures")
-- The device staging root of the fixture unit (spec §18.4).
local DROOT = select(2, require("loomworks.remote.manifest").device_roots("/data/stage", "ws", "build/App/Debug"))

local function capture(fn)
    local out_buf, err_buf = {}, {}
    local real_write, real_stderr, real_exit = io.write, io.stderr, os.exit
    io.write = function(s) out_buf[#out_buf + 1] = s end
    io.stderr = { write = function(_, s) err_buf[#err_buf + 1] = s end, flush = function() end }
    local exit_code
    os.exit = function(code) exit_code = code or 0; error({ __exit = true }, 0) end
    local ok, ret = pcall(fn)
    io.write, io.stderr, os.exit = real_write, real_stderr, real_exit
    return { ok = ok, ret = ret, exit_code = exit_code,
        stdout = table.concat(out_buf), stderr = table.concat(err_buf) }
end

local function gtest_xml(cases)
    local lines = { '<?xml version="1.0" encoding="UTF-8"?>', '<testsuites tests="2">', '  <testsuite name="Suite">' }
    for _, c in ipairs(cases) do
        if c.fail then
            lines[#lines + 1] = '    <testcase name="' .. c.name .. '" status="run" time="0.01" classname="Suite">'
            lines[#lines + 1] = '      <failure message="t.cpp:3&#x0A;boom" type=""><![CDATA[t.cpp:3\nboom]]></failure>'
            lines[#lines + 1] = '    </testcase>'
        else
            lines[#lines + 1] = '    <testcase name="' .. c.name .. '" status="run" time="0.01" classname="Suite" />'
        end
    end
    lines[#lines + 1] = '  </testsuite>'
    lines[#lines + 1] = '</testsuites>'
    return table.concat(lines, "\n") .. "\n"
end

describe("lw test --target on a device", function()
    local root, lockdir, saved_lock, dev, runner, sdk, unit, target, ws, profile, project
    local xml_cases, write_xml, exit_code_of_run

    local function lt()
        return {
            _target = target, _config_unit = unit, _project = project, _profile = profile,
            is_valid = function() return true end, requires_device = function() return false end,
            deploy_sync = function() return true end, display_name = function() return "Runner" end,
        }
    end

    local function test(names, opts)
        opts = opts or {}
        local deps = {
            backend = dev:backend(), liveness_ms = 100000,
            build = function() end,
            resolve_target = function() return lt() end,
            write_out = function() end, write_err = function() end,
        }
        return capture(function()
            return cli._test_targets(ws, profile, names,
                { junit = opts.junit, extra = opts.extra or {}, dev = cli._new_device_opts() }, deps)
        end)
    end

    before_each(function()
        runners._reset()
        root = fx.mkroot()
        lockdir = fx.mkroot()
        saved_lock = vim.env.LOOMWORKS_DEVICE_LOCK_DIR
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = lockdir
        fx.write_foreign_exe(root .. "/test/Runner")
        dev = fx.device()
        runner = fx.fake_runner_table()
        sdk = fx.fake_sdk(runner)
        local targets = { Runner = { type = "executable", artifact = "test/Runner" } }
        unit = fx.fake_unit({ build_dir = root, targets = targets, token = "fake-arm64", sdk = sdk })
        target = Target.new(unit, "Runner", targets.Runner)
        project = { key = "App" }
        profile = { key = "Debug:kit" }
        ws = { name = "ws", _device_sync = {}, _devices = {} }
        xml_cases = { { name = "a" }, { name = "b" } }
        write_xml, exit_code_of_run = true, 0
        dev.behaviors.Runner = function(ctx)
            local argv = ctx.req.argv
            if argv[2] == "--gtest_list_tests" then
                return { out = { "Suite.", "  a", "  b" } }
            end
            local xml
            for _, a in ipairs(argv) do xml = xml or a:match("^%-%-gtest_output=xml:(.+)$") end
            ctx.seen_argv = argv
            dev.last_argv = argv
            if xml and write_xml then ctx.board.files[xml] = { data = gtest_xml(xml_cases) } end
            return { out = { "[==========] 2 tests" }, exit = exit_code_of_run }
        end
    end)

    after_each(function()
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = saved_lock
        require("loomworks.io").rm_rf(root)
        require("loomworks.io").rm_rf(lockdir)
        runners._reset()
    end)

    it("passes: gtest XML is requested on the device, pulled back and parsed; JUnit written", function()
        local junit = root .. "/out/junit.xml"
        local res = test({ "Runner" }, { junit = junit, extra = { "--gtest_filter=Suite.*" } })
        assert.is_true(res.ok, res.stderr)
        assert.equals(0, res.ret)
        assert.truthy(res.stdout:find("Runner: 2 tests passed", 1, true))
        assert.truthy(res.stdout:find("TESTS OK: Debug:kit", 1, true))
        -- forwarded args first, then the results option pointing into the staging root
        assert.equals("--gtest_filter=Suite.*", dev.last_argv[2])
        assert.equals("--gtest_output=xml:" .. DROOT .. "/.loomworks/results/Runner.xml",
            dev.last_argv[3])
        local j = fx.read(junit)
        assert.truthy(j:find('<testcase classname="Suite" name="a"', 1, true))
        assert.truthy(j:find('tests="2" failures="0"', 1, true))
        -- Pulled result files are cleared from the device afterwards.
        for p in pairs(dev.boards.SER1.files) do
            assert.is_nil(p:find("/.loomworks/results/", 1, true), "left on the device: " .. p)
        end
    end)

    it("a failure in the XML fails the run even with exit status 0", function()
        xml_cases = { { name = "a" }, { name = "b", fail = true } }
        local res = test({ "Runner" }, { junit = root .. "/j.xml" })
        assert.is_false(res.ok)
        assert.equals(1, res.exit_code)
        assert.truthy(res.stdout:find("Runner: FAILED (1 failed test): Suite.b", 1, true))
        assert.truthy(res.stderr:find("1 of 1 test executable failed: Runner", 1, true))
        assert.truthy(fx.read(root .. "/j.xml"):find("<failure", 1, true))
    end)

    it("a non-zero exit fails", function()
        exit_code_of_run = 1
        local res = test({ "Runner" })
        assert.is_false(res.ok)
        assert.truthy(res.stdout:find("exit status 1", 1, true))
    end)

    it("a missing results file (requested) fails", function()
        write_xml = false
        local res = test({ "Runner" }, { junit = root .. "/j.xml" })
        assert.is_false(res.ok)
        assert.truthy(res.stdout:find("no results file came back", 1, true))
        assert.truthy(res.stderr:find("no JUnit output for Runner", 1, true))
    end)

    it("a crash report fails", function()
        dev.behaviors.Runner = (function(orig)
            return function(ctx)
                local r = orig(ctx)
                if ctx.req.argv[2] ~= "--gtest_list_tests" then
                    ctx.board.crashes["cppcrash-9"] = true
                    ctx.board.files["/crash/cppcrash-9"] = { data = "bt" }
                end
                return r
            end
        end)(dev.behaviors.Runner)
        local res = test({ "Runner" })
        assert.is_false(res.ok)
        assert.truthy(res.stdout:find("crash report collected", 1, true))
    end)

    it("a non-gtest executable is judged by its exit status only", function()
        dev.behaviors.Runner = function(ctx)
            dev.last_argv = ctx.req.argv
            if ctx.req.argv[2] == "--gtest_list_tests" then return { out = { "usage: runner" }, exit = 2 } end
            return { out = { "ok" } }
        end
        local res = test({ "Runner" })
        assert.is_true(res.ok, res.stderr)
        for _, a in ipairs(dev.last_argv) do assert.falsy(a:find("gtest_output", 1, true)) end
    end)

    it("several executables write one JUnit file each", function()
        local junit = root .. "/r/junit.xml"
        local res = test({ "Runner", "Runner2" }, { junit = junit })
        assert.is_true(res.ok, res.stderr)
        assert.is_not_nil(fx.read(root .. "/r/junit-Runner.xml"))
        assert.is_not_nil(fx.read(root .. "/r/junit-Runner2.xml"))
        assert.truthy(res.stdout:find("2 executables", 1, true))
    end)
end)

describe("plain lw test on a foreign profile", function()
    it("refuses (the batch runner would execute foreign binaries on the host)", function()
        local unit = fx.fake_unit({ token = "fake-arm64", tool_key = "ohos-kit" })
        local profile = { key = "Debug:ohos-kit", projects = function() return { { _config_unit = unit } } end }
        local res = capture(function() cli._refuse_foreign_batch(profile) end)
        assert.is_false(res.ok)
        assert.truthy(res.stderr:find("builds with kit ohos-kit for fake-arm64", 1, true))
        assert.truthy(res.stderr:find("lw test Debug:ohos-kit --target <exe>", 1, true))
        local host = { key = "h", projects = function() return { { _config_unit = fx.fake_unit({}) } } end }
        res = capture(function() cli._refuse_foreign_batch(host) end)
        assert.is_true(res.ok)
    end)
end)

describe("named test executables on the host", function()
    it("runs locally with --gtest_output and parses the XML", function()
        local root = fx.mkroot()
        fx.write_host_exe(root .. "/t/Local")
        local gtest = require("loomworks.gtest")
        local orig = gtest.probe_sync
        gtest.probe_sync = function() return "gtest", {} end
        local unit = fx.fake_unit({ build_dir = root })
        local tgt = Target.new(unit, "Local", { type = "executable", artifact = "t/Local" })
        local lt = {
            _target = tgt, _config_unit = unit, _project = { key = "P" },
            resolve_launch_spec = function(_, o)
                local s = assert(tgt:resolve_run_spec())
                return { cmd = s.cmd, args = vim.deepcopy(o.extra_args or {}), cwd = s.cwd, env = s.env }
            end,
        }
        local seen
        local res = capture(function()
            return cli._test_targets({ root = root }, { key = "Host" }, { "Local" },
                { extra = { "--x" }, dev = cli._new_device_opts() }, {
                    build = function() end, resolve_target = function() return lt end,
                    run_spec = function(step)
                        seen = step.cmd
                        local xml = step.cmd[#step.cmd]:match("^%-%-gtest_output=xml:(.+)$")
                        fx.write(xml, gtest_xml({ { name = "a" }, { name = "b", fail = true } }))
                        return 0
                    end,
                })
        end)
        gtest.probe_sync = orig
        require("loomworks.io").rm_rf(root)
        assert.is_false(res.ok)
        assert.is_table(seen, tostring(res.ret))
        assert.equals("--x", seen[2])
        assert.truthy(res.stdout:find("Local: FAILED (1 failed test): Suite.b", 1, true))
    end)
end)

describe("test_run helpers", function()
    it("judge covers every failure source", function()
        assert.is_false((test_run.judge({ status = 0, results = { { status = "passed" } } })))
        assert.is_true((test_run.judge({ status = 0, results = { { status = "errored" } } })))
        assert.is_true((test_run.judge({ status = 0, results_requested = true, results_missing = true })))
        assert.is_true((test_run.judge({ status = 0, crashes = 1 })))
        assert.is_true((test_run.judge({ status = nil, transport_error = "x" })))
    end)

    it("junit paths get a per-executable suffix when several run", function()
        assert.equals("/a/j.xml", test_run.junit_path("/a/j.xml", "X", false))
        assert.equals("/a/j-X_Y.xml", test_run.junit_path("/a/j.xml", "X/Y", true))
    end)
end)
