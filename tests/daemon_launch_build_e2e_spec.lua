-- Launch/1.build against a real daemon (spec §19.15 "Build of a launch
-- target", "Steps of a task"; step 5t part B), beyond the golden transcripts
-- (spec/protocol/transcripts/loomworks/Launch.1.json, Tasks.1.json), which
-- cannot prepare a deploy source: the shell fixture's launch `staged` with
-- its pre-build source present, so its dependency builds, its pre-build
-- deploy copies the file asynchronously and records its freshness in the
-- workspace cache, and its own unit builds — every step `ok`; built again,
-- the copy is fresh and skipped.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local engine = require("loomworks.proto.conformance")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

require("loomworks.daemon.client").TIMEOUT_MS = 30000

local function call(req_id, object, iface, method, args, no_env)
    return { send = { kind = "call", req_id = req_id, object = object, iface = iface, v = 1, method = method,
        args = args or vim.empty_dict(), env = (not no_env) and { ["$var"] = "env" } or nil } }
end
local function ok(req_id, result) return { expect = { kind = "ok", req_id = req_id, result = result } } end

--- Run `case` against a loopback daemon on `root`, its working copy verified
--- with `key`.
local function run(case, root, key)
    trust._set_key_path(key)
    local d = runner.loopback_driver(root)
    local vars = { lw_version = require("loomworks.daemon.version").identity(), root = root,
        env = runner.wire_env((vim.uv or vim.loop).os_environ()) }
    local okc, a, b = pcall(engine.run_case, case, d, { vars = vars })
    pcall(d.close)
    trust._set_key_path(nil)
    assert(okc, a)
    return a, b
end

--- One Launch/1.build of `staged`, subscribed to its steps: every step `ok`.
local function build_case(name)
    local function step(seq, index, state)
        return { expect = { kind = "signal", object = "/tasks", name = "step", seq = seq,
            args = { task_id = { ["$var"] = "task" }, seq = seq, index = index, state = state } }, timeout_ms = 120000 }
    end
    return {
        name = name,
        allow = { { kind = "task" }, { kind = "model_change" } },
        steps = {
            call(1, "/", "loomworks.Root", "subscribe", { object = "/tasks", iface = "loomworks.Tasks", v = 1 }, true),
            ok(1, { sub_id = { ["$bind"] = "sub" }, seq = 0 }),
            call(2, "/launch", "loomworks.Launch", "build",
                { profile = { key = "dev" }, target = "staged", kind = "launch" }),
            ok(2, { outcome = "accepted", task_id = { ["$bind"] = "task" } }),
            { expect = { kind = "signal", object = "/tasks", name = "started", seq = 1,
                args = { task = { task_id = { ["$var"] = "task" }, kind = "build" } } } },
            step(2, 1, "running"), step(3, 1, "ok"),
            step(4, 2, "running"), step(5, 2, "ok"),
            step(6, 3, "running"), step(7, 3, "ok"),
            { expect = { kind = "signal", object = "/tasks", name = "ended", seq = 8,
                args = { task_id = { ["$var"] = "task" }, exit_code = 0 } }, timeout_ms = 120000 },
            { expect = { kind = "task", task_id = { ["$var"] = "task" }, phase = "done", exit_code = 0,
                result = { exit_code = 0, error = { ["$absent"] = true } } }, timeout_ms = 60000 },
        },
    }
end

describe("Launch/1.build in the daemon (§19.15 Build of a launch target)", function()
    after_each(function() trust._set_key_path(nil) end)

    it("builds the dependency, copies the pre-build deploy and builds the target; a fresh copy is skipped", function()
        local key = H.tmp() .. "/trust.key"
        local root = runner.fixture("shell", key)
        -- The pre-build source, in app's build directory.
        vim.fn.mkdir(root .. "/out/Debug", "p")
        local f = assert(io.open(root .. "/out/Debug/missing.txt", "w"))
        f:write("artifact")
        f:close()
        local okc, err = run(build_case("first build"), root, key)
        assert.is_true(okc, err)
        local copied = io.open(root .. "/staged/missing.txt", "r")
        assert.is_not_nil(copied, "the pre-build deploy did not copy its source")
        assert.are.equal("artifact", copied:read("*a"))
        copied:close()
        -- Its freshness is recorded in the workspace cache, as in-process.
        local cache = table.concat(vim.fn.readfile(root .. "/.nvim/loomworks.cache.json"), "\n")
        assert.truthy(cache:find("deploy_state", 1, true), cache)
        assert.truthy(cache:lower():find("staged/missing.txt", 1, true), cache)
        -- Built again: the same steps succeed, the fresh copy left alone.
        local before = (vim.uv or vim.loop).fs_stat(root .. "/staged/missing.txt").mtime
        okc, err = run(build_case("second build"), root, key)
        assert.is_true(okc, err)
        local after = (vim.uv or vim.loop).fs_stat(root .. "/staged/missing.txt").mtime
        assert.are.same(before, after)
    end)
end)
