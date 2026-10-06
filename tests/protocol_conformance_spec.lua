-- Protocol conformance (spec §19.20 "Schemas and conformance", step 5g.2
-- parts A and B): every golden transcript under spec/protocol/transcripts/ replayed
-- against this checkout's daemon over the standard-I/O transport
-- (`lw daemon run --stdio`) and over the loopback transport; the engine's
-- matchers and frame validation; and what a single-connection transcript
-- cannot show (another connection's cancel is forbidden).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local uv = vim.uv or vim.loop
local engine = require("loomworks.proto.conformance")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

client.TIMEOUT_MS = 30000

local FILES = runner.files()

describe("conformance transcripts (§19.20)", function()
    it("exist for every mounted core interface", function()
        local have = {}
        for _, rel in ipairs(FILES) do have[rel] = true end
        for _, rel in ipairs({ "transcripts/loomworks/Root.1.json", "transcripts/loomworks/Workspace.1.json",
            "transcripts/loomworks/Tasks.1.json", "transcripts/lw/internal.Snapshot.1.json",
            "transcripts/loomworks/Build.1.json", "transcripts/loomworks/Tests.1.json",
            "transcripts/loomworks/Launch.1.json", "transcripts/loomworks/Toolchains.1.json",
            "transcripts/loomworks/Profiles.1.json" }) do
            assert.is_true(have[rel] == true, rel)
        end
    end)

    for _, transport in ipairs({ "stdio", "loopback" }) do
        for _, rel in ipairs(FILES) do
            local t = runner.load(rel)
            for _, case in ipairs(t.cases) do
                it(string.format("[%s] %s/%d: %s", transport, t.interface, t.version, case.name), function()
                    local ok, err = runner.run_case(case, { transport = transport })
                    assert.is_true(ok, err)
                end)
            end
        end
    end
end)

--- A driver replaying canned frames.
local function canned(frames)
    local d = { sent = {} }
    function d.send(f) d.sent[#d.sent + 1] = f; return true end
    function d.recv()
        if #frames == 0 then return nil, "timeout" end
        return table.remove(frames, 1)
    end
    return d
end

local function J(s) return vim.json.decode(s) end

describe("conformance engine", function()
    it("matches partially, binds and compares variables, and applies the matchers", function()
        local vars = { root = "/r" }
        assert.is_true((engine.match(J('{"a":1,"b":{"$bind":"x","$type":"integer"}}'), J('{"a":1,"b":7,"c":3}'), vars)))
        assert.equals(7, vars.x)
        assert.is_false((engine.match(J('{"b":{"$var":"x"}}'), J('{"b":8}'), vars)))
        assert.is_true((engine.match(J('{"r":{"$var":"root"},"z":{"$absent":true}}'), J('{"r":"/r"}'), vars)))
        assert.is_false((engine.match(J('{"z":{"$absent":true}}'), J('{"z":1}'), vars)))
        assert.is_true((engine.match(J('{"l":{"$contains":[2,{"k":"v"}]}}'), J('{"l":[{"k":"v","o":1},1,2]}'), vars)))
        assert.is_false((engine.match(J('{"l":{"$contains":[2,2]}}'), J('{"l":[2]}'), vars)))
        assert.is_false((engine.match(J('{"l":[]}'), J('{"l":[1]}'), vars)))
        assert.is_false((engine.match(J('{"o":{"$exact":{"a":1}}}'), J('{"o":{"a":1,"b":2}}'), vars)))
        assert.is_true((engine.match(J('{"s":{"$pattern":"^[0-9a-f]+$"}}'), J('{"s":"ab12"}'), vars)))
        local env = engine.expand(J('{"env":{"$var":"e","$with":{"B":"2"}}}'), { e = { A = "1" } })
        assert.same({ A = "1", B = "2" }, env.env)
    end)

    it("fails a result that violates its schema, an undeclared error code and a seq gap", function()
        local function run(steps, frames)
            return engine.run_case({ name = "t", handshake = false, steps = steps }, canned(frames),
                { timeout_ms = 10, settle_ms = 0 })
        end
        local call = { send = J('{"kind":"call","req_id":1,"object":"/tasks","iface":"loomworks.Tasks","v":1,"method":"list","args":{}}') }
        local ok, err = run({ call, { expect = { kind = "ok", req_id = 1 } } }, { J('{"kind":"ok","req_id":1,"result":{"tasks":3}}') })
        assert.is_false(ok)
        assert.truthy(err:find("result", 1, true), err)
        ok, err = run({ call, { expect = { kind = "error", req_id = 1 } } },
            { J('{"kind":"error","req_id":1,"error":{"code":"made_up","message":"x"}}') })
        assert.is_false(ok)
        assert.truthy(err:find("neither a transport code", 1, true), err)
        local sub = { send = J('{"kind":"call","req_id":1,"object":"/","iface":"loomworks.Root","v":1,"method":"subscribe","args":{"object":"/tasks","iface":"loomworks.Tasks","v":1}}') }
        ok, err = run({ sub, { expect = { kind = "ok", req_id = 1 } }, { expect = { kind = "signal" } } }, {
            J('{"kind":"ok","req_id":1,"result":{"sub_id":1,"seq":0}}'),
            J('{"kind":"signal","object":"/tasks","iface":"loomworks.Tasks","v":1,"name":"ended","sub_id":1,"seq":2,"args":{"task_id":1,"exit_code":0}}'),
        })
        assert.is_false(ok)
        assert.truthy(err:find("gap", 1, true), err)
        -- An unconsumed frame that no `allow` pattern covers fails the case.
        ok, err = run({}, { J('{"kind":"model_change","seq":1}') })
        assert.is_false(ok)
        assert.truthy(err:find("unexpected frame", 1, true), err)
        ok = engine.run_case({ name = "t", handshake = false, steps = {}, allow = { { kind = "model_change" } } },
            canned({ J('{"kind":"model_change","seq":1}') }), { timeout_ms = 10, settle_ms = 0 })
        assert.is_true(ok)
    end)

    it("types the task frames of a task-streamed method: the start meta names it, done carries its result", function()
        local function run(frames)
            local build = { send = J('{"kind":"call","req_id":1,"object":"/build","iface":"loomworks.Build","v":1,"method":"build","args":{},"env":{}}') }
            return engine.run_case({ name = "t", handshake = false, allow = { { kind = "task" } },
                steps = { build, { expect = { kind = "ok", req_id = 1 } } } }, canned(frames),
                { timeout_ms = 10, settle_ms = 0 })
        end
        local accepted = J('{"kind":"ok","req_id":1,"result":{"outcome":"accepted","task_id":4}}')
        local start = J('{"kind":"task","task_id":4,"phase":"start","meta":{"object":"/build","iface":"loomworks.Build","v":1,"method":"build","kind":"build"}}')
        local ok, err = run({ accepted, start, J('{"kind":"task","task_id":4,"phase":"done","exit_code":0,"result":{"exit_code":0}}') })
        assert.is_true(ok, err)
        ok, err = run({ accepted, start, J('{"kind":"task","task_id":4,"phase":"done","exit_code":0}') })
        assert.is_false(ok)
        assert.truthy(err:find("done without a result", 1, true), err)
        ok, err = run({ accepted, J('{"kind":"task","task_id":4,"phase":"start","meta":{"kind":"build"}}') })
        assert.is_false(ok)
        assert.truthy(err:find("does not name its method", 1, true), err)
        ok, err = run({ accepted, start, J('{"kind":"task","task_id":4,"phase":"done","exit_code":0,"result":{"exit_code":"zero"}}') })
        assert.is_false(ok)
        assert.truthy(err:find("result", 1, true), err)
        -- A task no interface call started (protocol 10) is only matched.
        ok, err = run({ J('{"kind":"ok","req_id":1,"result":{"outcome":"refused","message":"m","exit_code":1}}'),
            J('{"kind":"task","task_id":9,"phase":"done","exit_code":0}') })
        assert.is_true(ok, err)
    end)
end)

describe("transcript lint (§19.20)", function()
    it("checks a transcript against its meta-schema, its path and its fixtures", function()
        local check = require("loomworks.proto.schema_check")
        local documents = require("loomworks.proto.documents")
        local rel = "transcripts/loomworks/Root.1.json"
        local set = documents.set(function(r)
            if r == rel then
                return vim.json.encode({ transcripts = 1, interface = "loomworks.Tasks", version = 1,
                    cases = { { name = "x", fixture = "nope", steps = { { bogus = 1 } } } } })
            end
            return documents.read(r)
        end)
        local text = table.concat(check.lint(set, rel), "\n")
        assert.truthy(text:find("meta/transcript.schema.json", 1, true), text)
        assert.truthy(text:find("names loomworks.Tasks/1 but lives at", 1, true), text)
        assert.truthy(text:find("unknown fixture nope", 1, true), text)
        assert.same({}, check.lint(documents.set(), rel))
    end)
end)

describe("loomworks.Tasks/1 across connections (§19.20 Tasks and cancel)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        srv = server_mod.new(root, { tick_ms = 100, log = function() end })
        require("loomworks.daemon.service").attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("only the owner may cancel; another connection gets forbidden and sees owned = false", function()
        local a = assert(client.loopback_session(srv))
        local b = assert(client.loopback_session(srv))
        local env = require("loomworks.daemon.envscope").capture()
        env.LW_TEST_SLEEP = "60000"
        local r = assert(client.request(a, { kind = "build", args = { profile = "dev" }, interactive = false,
            env = env, command = "lw build" }))
        assert.equals("accepted", r.outcome, r.message)
        local tid = r.task_id
        local list
        assert.is_true(vim.wait(30000, function()
            list = client.call_sync(b, "/tasks", "loomworks.Tasks", 1, "list", {})
            return list and #list.tasks == 1
        end, 50))
        assert.is_false(list.tasks[1].owned)
        local res, err = client.call_sync(b, "/tasks", "loomworks.Tasks", 1, "cancel", { task_id = tid })
        assert.is_nil(res)
        assert.equals("forbidden", err.code)
        res = assert(client.call_sync(a, "/tasks", "loomworks.Tasks", 1, "cancel", { task_id = tid }))
        assert.equals("ok", res.outcome)
        assert.is_true(vim.wait(30000, function() return #srv.service.tasks:snapshot() == 0 end, 20))
        a:close()
        b:close()
    end)
end)
