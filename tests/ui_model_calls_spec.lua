-- The status page's one route to model writes (loomworks.ui.model_calls,
-- step 5o part C0): every method it serves is a catalogue method named with
-- its interface (spec §19.20), and no other ui/ file reaches a model write
-- itself (guard ratchet).

local model = require("loomworks.ui.model_calls")

local root = vim.fn.getcwd()

--- The methods `iface` (e.g. "Profiles") declares at version `v`.
local function schema_methods(iface, v)
    local fh = io.open(("%s/spec/protocol/interfaces/loomworks/%s.%d.json"):format(root, iface, v), "rb")
    if not fh then return nil end
    local doc = vim.json.decode(fh:read("*a"))
    fh:close()
    return doc.methods or {}
end

describe("ui.model_calls", function()
    it("serves only catalogue methods, each named <Interface>/<version>.<method>", function()
        local bad = {}
        local names = model.methods()
        assert.is_true(#names > 0)
        for _, name in ipairs(names) do
            local iface, v, method = name:match("^([%w_]+)/(%d+)%.([%w_]+)$")
            local methods = iface and schema_methods(iface, tonumber(v))
            if not methods then
                bad[#bad + 1] = name .. ": no interface loomworks." .. tostring(iface) .. "/" .. tostring(v)
            elseif not methods[method] then
                bad[#bad + 1] = name .. ": the interface has no method " .. method
            end
        end
        assert.same({}, bad)
    end)

    it("refuses an unknown method loudly", function()
        assert.has_error(function() model.call(nil, "Profiles/1.nope", {}) end)
        assert.has_error(function() model.call(nil, "set_active", {}) end)
    end)

    -- C0: each method's body is the in-process write the editor ran before.
    -- The view-model and the loomworks API are stubbed to record what each
    -- method passes and to check how its answer becomes the outcome. From
    -- C2a an entity param is a row: in-process, the object bound to it.
    describe("in-process bodies", function()
        local saved, calls
        local function recorder(ret)
            return setmetatable({}, { __index = function(_, name)
                return function(...)
                    calls[#calls + 1] = { name, ... }
                    if type(ret[name]) == "function" then return ret[name](...) end
                    return true
                end
            end })
        end
        local WS, P, CS, PR, CFG, L, SDK, U = { root = "/w" }, {}, {}, {}, {}, {}, {}, {}
        -- The rows the in-process view bound to the objects (step 5o C2a).
        local ss = require("loomworks.status_source")
        local PROW, CSROW, LROW, CROW = { key = "p" }, { name = "cs" }, { key = "l" }, { key = "c" }
        local SDKROW = { key = "ohos-1" }
        ss.bind(PROW, P); ss.bind(CSROW, CS); ss.bind(LROW, L); ss.bind(CROW, CFG); ss.bind(SDKROW, SDK)
        before_each(function()
            calls = {}
            saved = { package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] }
            package.loaded["loomworks.workspace_view"] = recorder({
                set_description = function() return false end,
                execute_create_profile = function() return P end,
                execute_create_config_set = function() return nil, "taken" end,
                execute_create_config_set_from_candidate = function() return CS end,
                execute_add_project = function() return true, nil, PR end,
                execute_save_launch_config = function() return true, nil, L end,
                add_sdk = function() return SDK end,
                remove_sdk = function() return false, "in use" end,
                sdk_detect = function() return { outcome = "ok", providers = { { id = "ohos", label = "OHOS",
                    found = { { path = "/sdk", version = "5" } } } } } end,
                -- Confirms without `yes`; with it, ends (ok) through `cb`.
                execute_deletion = function(_, _, plan, yes, cb)
                    if not yes then return cb({ outcome = "confirm", lines = { "Delete x:" }, plan = "T" }) end
                    cb({ outcome = plan == "T" and "ok" or "refused" })
                end,
                nuke = function(_, _, yes)
                    if not yes then return { outcome = "confirm", lines = { "Will delete" }, plan = "N" } end
                    return { outcome = "ok" }
                end,
            })
            package.loaded["loomworks"] = recorder({
                trust_user_prefs = function() return "trusted" end,
            })
        end)
        after_each(function()
            package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] = saved[1], saved[2]
        end)
        local function run(ws, method, params)
            local got
            model.call(ws, method, params, function(r) got = r end)
            return got
        end

        it("passes each method's params to the write the editor ran before", function()
            local m = { a = 1 }
            local r = {}
            r[#r + 1] = run(WS, "Workspace/1.publish", {})
            r[#r + 1] = run(WS, "Workspace/1.set_intent", { item = PROW, intent = "shared" })
            r[#r + 1] = run(WS, "Workspace/1.set_description", { item = { _kind = "launch", _row = LROW }, text = "t" })
            r[#r + 1] = run(WS, "Profiles/1.add_tool", { profile = PROW, tool = "gcc" })
            r[#r + 1] = run(WS, "Profiles/1.set_active", { profile = PROW })
            local pm = { [PR] = CFG }
            r[#r + 1] = run(WS, "ConfigSets/1.add", { name = "Dev", mappings = pm })
            r[#r + 1] = run(WS, "ConfigSets/1.add", { name = "Auto", mappings = { app = "Debug" } })
            r[#r + 1] = run(WS, "ConfigSets/1.update", { config_set = CSROW, name = "D2", mappings = pm })
            r[#r + 1] = run(WS, "Projects/1.add", { key = "app", type = "cmake", path = "app", mappings = m, tool = m })
            r[#r + 1] = run(nil, "Projects/1.configuration_save",
                { project = PROW, configuration = CROW, name = "Debug", fields = m })
            r[#r + 1] = run(nil, "Projects/1.launch_save", { project = PROW, launch = LROW, name = "run", data = m })
            r[#r + 1] = run(nil, "Projects/1.variable_save", { project = PROW, variable = "v", name = "w", data = m })
            r[#r + 1] = run(nil, "Projects/1.type_config_set", { project = PROW, field = "f", value = 3 })
            r[#r + 1] = run(nil, "Projects/1.deploy_save", { project = PROW, deploy = m })
            r[#r + 1] = run(WS, "Sdks/1.add", { provider = "ohos", path = "/sdk" })
            r[#r + 1] = run(WS, "Sdks/1.remove", { sdk = SDKROW })
            assert.same({
                { "publish", WS },
                { "set_intent", P, "shared" },
                { "set_description", L, "t" },
                { "add_profile_tool", P, "gcc" },
                { "activate_profile", P },
                { "execute_create_config_set", WS, "Dev", pm },
                { "candidate_token", "Auto", { app = "Debug" } },
                { "execute_create_config_set_from_candidate", WS, true },
                { "execute_edit_config_set", CS, "D2", pm },
                { "execute_add_project", WS, "app", "cmake", "app", { mappings = m, tool_entry = m } },
                { "execute_save_configuration", P, CFG, "Debug", m },
                { "execute_save_launch_config", P, L, "run", m },
                { "execute_save_variable", P, "v", "w", m },
                { "save_type_config_field", P, "f", 3 },
                { "save_deploy", P, m },
                { "add_sdk", WS, "ohos", "/sdk" },
                { "remove_sdk", WS, SDK },
            }, calls)
            assert.same({ outcome = "ok" }, r[1])
            assert.same({ outcome = "ok", changed = false }, r[3])
            assert.same({ outcome = "refused", message = "taken" }, r[6])
            assert.equals(CS, r[7].config_set)
            assert.equals(PR, r[9].project)
            assert.equals(L, r[11].launch)
            assert.equals(SDK, r[15].sdk)
            assert.same({ outcome = "refused", message = "in use" }, r[16])
        end)

        it("names a project's configuration, launch and variable by their rows (step 5o C2b)", function()
            local r = {}
            r[#r + 1] = run(nil, "Projects/1.configuration_remove", { project = PROW, configuration = CROW })
            r[#r + 1] = run(nil, "Projects/1.launch_remove", { project = PROW, launch = LROW })
            r[#r + 1] = run(nil, "Projects/1.variable_remove", { project = PROW, variable = "v" })
            r[#r + 1] = run(WS, "Projects/1.candidates", { path = "/w/sub/app", type = "cmake" })
            -- A row the in-process view did not bind names nothing: refused,
            -- nothing written.
            r[#r + 1] = run(nil, "Projects/1.launch_remove", { project = PROW, launch = { key = "l" } })
            r[#r + 1] = run(nil, "Projects/1.type_config_set", { project = { key = "p" }, field = "f" })
            assert.same({ "execute_delete_configuration", P, CFG }, calls[1])
            assert.same({ "execute_delete_launch_config", P, L }, calls[2])
            assert.same({ "execute_delete_variable", P, "v" }, calls[3])
            assert.same({ "derive_key_and_path", "/w", "/w/sub/app", "app" }, calls[4])
            assert.equals(4, #calls)
            assert.equals("ok", r[4].outcome)
            assert.equals("refused", r[5].outcome)
            assert.equals("refused", r[6].outcome)
        end)

        it("resolves each deletion target's row to its object; confirm, then the deletion with its plan (step 5o C2c-2)", function()
            local BD, UNIT = {}, setmetatable({ mark_deleting = function() end }, {})
            local OROW, UROW, PRROW = { key = "gone/Debug" }, { project = "p" }, { key = "app" }
            ss.bind(OROW, { build_dir_obj = BD }); ss.bind(UROW, { _config_unit = UNIT }); ss.bind(PRROW, PR)
            local c = run(WS, "Maintenance/1.execute_deletion", { target = { profile = PROW } })
            assert.same({ outcome = "confirm", lines = { "Delete x:" }, plan = "T" }, c)
            local r = {}
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { profile = PROW }, plan = "T", yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { unit = UROW }, plan = "T", yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { build_dir = OROW }, plan = "T", yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { project = PRROW }, plan = "T", yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion",
                { target = { stray_dir = "/w/.nvim/build/x" }, plan = "T", yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { orphans = true }, plan = "old", yes = true })
            assert.same({ { outcome = "ok" }, { outcome = "ok" }, { outcome = "ok" }, { outcome = "ok" },
                { outcome = "ok" }, { outcome = "refused" } }, r)
            local targets = {}
            for i, call in ipairs(calls) do
                assert.equals("execute_deletion", call[1])
                assert.equals(WS, call[2])
                targets[i] = call[3]
            end
            assert.same({ { profile = P }, { profile = P }, { unit = UNIT }, { build_dir = BD }, { project = PR },
                { stray_dir = "/w/.nvim/build/x" }, { orphans = true } }, targets)
            assert.same({ nil, false }, { calls[1][4], calls[1][5] })
            assert.same({ "T", true }, { calls[2][4], calls[2][5] })
        end)

        it("refuses a deletion of an unbound row, of no single target, and `yes` without the plan; nothing runs", function()
            local r = {}
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { profile = { key = "p" } } })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { unit = { project = "p" } } })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = {} })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { profile = PROW, orphans = true } })
            r[#r + 1] = run(WS, "Maintenance/1.execute_deletion", { target = { profile = PROW }, yes = true })
            r[#r + 1] = run(WS, "Maintenance/1.nuke", { yes = true })
            for i, x in ipairs(r) do assert.equals("refused", x.outcome, i) end
            assert.same({}, calls)
        end)

        it("detects SDKs; an SDK row the in-process view did not bind is refused, nothing removed (step 5o C2c-1)", function()
            local r = run(WS, "Sdks/1.detect", { provider = "ohos" })
            assert.same({ { "sdk_detect", "ohos" } }, calls)
            assert.same({ { path = "/sdk", version = "5" } }, r.providers[1].found)
            r = run(WS, "Sdks/1.remove", { sdk = { key = "ohos-1" } })
            assert.equals("refused", r.outcome)
            assert.equals(1, #calls)
        end)

        it("runs the trust review and the rescan as before; the nuke confirms, then runs with its plan", function()
            assert.same({ outcome = "ok", trust = "trusted" }, run(WS, "Workspace/1.trust_accept", {}))
            run(WS, "Toolchains/1.rescan", {})
            assert.same({ outcome = "confirm", lines = { "Will delete" }, plan = "N" }, run(nil, "Maintenance/1.nuke", {}))
            assert.same({ outcome = "ok" }, run(nil, "Maintenance/1.nuke", { plan = "N", yes = true, root = "/x" }))
            assert.same({ { "trust_user_prefs" }, { "rescan_tools" }, { "nuke", nil, nil, false },
                { "nuke", nil, "N", true } }, calls)
        end)

        it("names an unbound row's entity by nothing (refused by the command), never by its key", function()
            package.loaded["loomworks.workspace_view"] = saved[1]
            local got = run(WS, "Workspace/1.set_intent", { item = { key = "p" }, intent = "shared" })
            assert.equals("refused", got.outcome)
        end)
    end)

    -- Step 5o C2c-1: in `daemon` mode the SDK section's Sdks/1 calls and
    -- `L`'s Toolchains/1.rescan are calls to the workspace daemon (a fake
    -- observer here; the real one in tests/daemon_model_calls_e2e_spec.lua):
    -- an SDK by its row's id, a row without one refused, never in-process.
    describe("daemon mode: SDKs and the toolchain rescan", function()
        local saved, sent, carried, answer
        local WS = { root = "/w" }
        local obs = { state = "connected" }
        function obs:request(method, args, cb)
            sent[#sent + 1] = { method, args }
            cb({ outcome = "ok", result = answer or { outcome = "ok" } })
        end
        function obs:refusal(method) return "the daemon does not carry " .. method end
        before_each(function()
            sent, carried, answer = {}, true, nil
            saved = { package.loaded["loomworks.daemon.editor_ops"], package.loaded["loomworks.workspace_view"],
                package.loaded["loomworks"] }
            package.loaded["loomworks.daemon.editor_ops"] = {
                daemon_of = function() return true, carried and obs or nil end,
                carrier = function() return carried and obs or nil end,
            }
            -- No in-process body may run.
            local function never(_, name) return function() error("in-process " .. name .. " in daemon mode") end end
            package.loaded["loomworks.workspace_view"] = setmetatable({}, { __index = never })
            package.loaded["loomworks"] = setmetatable({}, { __index = never })
        end)
        after_each(function()
            package.loaded["loomworks.daemon.editor_ops"], package.loaded["loomworks.workspace_view"],
                package.loaded["loomworks"] = saved[1], saved[2], saved[3]
        end)
        local function run(method, params)
            local got
            model.call(WS, method, params, function(r) got = r end)
            return got
        end

        it("routes detect, add, remove and rescan", function()
            for _, m in ipairs({ "Sdks/1.detect", "Sdks/1.add", "Sdks/1.remove", "Toolchains/1.rescan" }) do
                assert.is_true(model.routed(m), m)
            end
        end)

        it("sends the SDK row's id, the provider and the absolute path as given; the outcomes as answered", function()
            answer = { outcome = "ok", providers = { { id = "ohos", label = "OHOS", path_prompt = "p",
                found = { { path = "/sdk", version = "5" } } } } }
            local r = run("Sdks/1.detect", {})
            assert.same(answer, r)
            answer = { outcome = "ok", sdk = { id = "7:1", key = "ohos-1" } }
            r = run("Sdks/1.add", { provider = "ohos", path = "/sdk" })
            assert.same({ id = "7:1", key = "ohos-1" }, r.sdk)
            answer = nil
            assert.equals("ok", run("Sdks/1.remove", { sdk = { id = "7:1", key = "ohos-1", label = "OHOS" } }).outcome)
            answer = { outcome = "ok", notes = { "detection still running" }, note_roles = { "warn" } }
            r = run("Toolchains/1.rescan", {})
            assert.same({ false, "detection still running" }, { model.result(r) })
            assert.same({
                { "Sdks/1.detect", {} },
                { "Sdks/1.add", { provider = "ohos", path = "/sdk" } },
                { "Sdks/1.remove", { sdk = { id = "7:1" } } },
                { "Toolchains/1.rescan", {} },
            }, sent)
        end)

        it("refuses an SDK row without an id (never by its key) and a call the daemon cannot carry", function()
            local r = run("Sdks/1.remove", { sdk = { key = "ohos-1", label = "OHOS" } })
            assert.equals("refused", r.outcome)
            assert.truthy(r.message:find("no SDK id", 1, true), r.message)
            answer = { outcome = "refused", message = "stale reference" }
            r = run("Sdks/1.remove", { sdk = { id = "9:9" } })
            assert.equals("SDK: stale reference", r.message)
            carried = false
            r = run("Toolchains/1.rescan", {})
            assert.equals("refused", r.outcome)
            assert.truthy(r.message:find("^toolchain detection: "), r.message)
            r = run("Sdks/1.add", { provider = "ohos", path = "/sdk" })
            assert.equals("refused", r.outcome)
            assert.same({ { "Sdks/1.remove", { sdk = { id = "9:9" } } } }, sent)
        end)
    end)

    -- Step 5o C2c-2: in `daemon` mode Maintenance/1's deletions and nuke are
    -- calls to the workspace daemon (a fake observer here; the real one in
    -- tests/daemon_model_calls_e2e_spec.lua): the confirmation a plain call,
    -- the confirmed one a task the editor owns, followed to its `done`.
    describe("daemon mode: deletions and the nuke", function()
        local saved, sent, owned, carried, answer, cancelled_by
        local WS = { root = "/w" }
        local obs = { state = "connected" }
        function obs:request(method, args, cb)
            sent[#sent + 1] = { method, args }
            cb({ outcome = "ok", result = answer or { outcome = "confirm", lines = { "Delete x:" }, plan = "T" } })
        end
        function obs:start_owned(method, args, h)
            owned[#owned + 1] = { method = method, args = args, h = h }
        end
        function obs:refusal(method) return "the daemon does not carry " .. method end
        before_each(function()
            sent, owned, carried, answer, cancelled_by = {}, {}, true, nil, nil
            saved = { package.loaded["loomworks.daemon.editor_ops"], package.loaded["loomworks.workspace_view"],
                package.loaded["loomworks"] }
            package.loaded["loomworks.daemon.editor_ops"] = {
                daemon_of = function() return true, carried and obs or nil end,
                carrier = function() return carried and obs or nil end,
                cancel_owned_matching = function(ws, match, done)
                    assert.equals(WS, ws)
                    cancelled_by = match
                    done()
                end,
            }
            -- No in-process body may run.
            local function never(_, name) return function() error("in-process " .. name .. " in daemon mode") end end
            package.loaded["loomworks.workspace_view"] = setmetatable({}, { __index = never })
            package.loaded["loomworks"] = setmetatable({}, { __index = never })
        end)
        after_each(function()
            package.loaded["loomworks.daemon.editor_ops"], package.loaded["loomworks.workspace_view"],
                package.loaded["loomworks"] = saved[1], saved[2], saved[3]
        end)
        local function run(method, params)
            local got, n = nil, 0
            model.call(WS, method, params, function(r) got = r; n = n + 1 end)
            return got, function() return n end
        end
        local PROW = { id = "1:1", key = "dev", units = { { project = "app", unit_id = "2:1", build_dir = "/w/b/Dbg" } } }

        it("routes execute_deletion and nuke; every status-page method is routed", function()
            assert.is_true(model.routed("Maintenance/1.execute_deletion"))
            assert.is_true(model.routed("Maintenance/1.nuke"))
            -- (step 5o C2c-2) In `daemon` mode no status-page method runs in-process.
            for _, m in ipairs(model.methods()) do assert.is_true(model.routed(m), m) end
        end)

        it("asks the confirmation by the rows' ids, the stray path verbatim; never a plan or yes", function()
            local SROW = { key = "s", unit_id = nil }
            local c = run("Maintenance/1.execute_deletion", { target = { profile = PROW } })
            assert.same({ outcome = "confirm", lines = { "Delete x:" }, plan = "T" }, c)
            run("Maintenance/1.execute_deletion", { target = { unit = PROW.units[1] } })
            run("Maintenance/1.execute_deletion", { target = { build_dir = { id = "3:1", key = "gone/Debug" } } })
            run("Maintenance/1.execute_deletion", { target = { project = { id = "4:1", key = "app" } } })
            run("Maintenance/1.execute_deletion", { target = { stray_dir = "C:/W/.nvim/Build/X" } })
            run("Maintenance/1.execute_deletion", { target = { orphans = true } })
            run("Maintenance/1.nuke", { root = "/elsewhere" })
            assert.same({
                { "Maintenance/1.execute_deletion", { target = { profile = { id = "1:1" } } } },
                { "Maintenance/1.execute_deletion", { target = { unit = { id = "2:1" } } } },
                { "Maintenance/1.execute_deletion", { target = { build_dir = { id = "3:1" } } } },
                { "Maintenance/1.execute_deletion", { target = { project = { id = "4:1" } } } },
                { "Maintenance/1.execute_deletion", { target = { stray_dir = "C:/W/.nvim/Build/X" } } },
                { "Maintenance/1.execute_deletion", { target = { orphans = true } } },
                { "Maintenance/1.nuke", {} },
            }, sent)
            assert.same({}, owned)
            assert.is_nil(SROW.unit_id)
        end)

        it("refuses an id-less row (never by its key), no single target, and yes without the plan; nothing sent", function()
            local r = {}
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { profile = { key = "dev" } } })
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { unit = { project = "app", id = "x" } } })
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { project = { key = "app" } } })
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { build_dir = { key = "gone/Debug" } } })
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { profile = PROW, orphans = true } })
            r[#r + 1] = run("Maintenance/1.execute_deletion", { target = { profile = PROW }, yes = true })
            r[#r + 1] = run("Maintenance/1.nuke", { yes = true })
            for i, x in ipairs(r) do assert.equals("refused", x.outcome, i) end
            assert.truthy(r[1].message:find("no profile id", 1, true), r[1].message)
            assert.truthy(r[2].message:find("no configuration unit id", 1, true), r[2].message)
            assert.same({}, sent)
            assert.same({}, owned)
        end)

        it("a refusal keeps its stream (nothing to delete); a call the daemon cannot carry is refused", function()
            answer = { outcome = "refused", message = "nothing to delete", stream = "out", exit_code = 0 }
            local r = run("Maintenance/1.execute_deletion", { target = { orphans = true } })
            assert.same({ "refused", "deletion: nothing to delete", "out" }, { r.outcome, r.message, r.stream })
            carried = false
            sent = {}
            r = run("Maintenance/1.execute_deletion", { target = { orphans = true } })
            assert.equals("refused", r.outcome)
            r = run("Maintenance/1.nuke", { plan = "N", yes = true })
            assert.equals("refused", r.outcome)
            assert.truthy(r.message:find("^nuke: the workspace is no longer loaded"), r.message)
            assert.same({}, sent)
            assert.same({}, owned)
        end)

        it("a confirmed deletion is a task the editor owns: answered only at its done", function()
            local r, n = nil, 0
            model.call(WS, "Maintenance/1.execute_deletion", { target = { profile = PROW }, plan = "T", yes = true },
                function(x) r = x; n = n + 1 end)
            assert.equals(1, #owned)
            assert.equals("Maintenance/1.execute_deletion", owned[1].method)
            assert.same({ target = { profile = { id = "1:1" } }, plan = "T", yes = true }, owned[1].args)
            owned[1].h.on_reply({ outcome = "accepted", task_id = 7 })
            assert.equals(0, n)
            owned[1].h.on_done({ exit_code = 0 })
            assert.same({ outcome = "ok" }, r)
            assert.equals(1, n)
            local got
            model.call(WS, "Maintenance/1.execute_deletion", { target = { orphans = true }, plan = "T", yes = true },
                function(x) got = x end)
            owned[2].h.on_reply({ outcome = "accepted", task_id = 8 })
            assert.is_nil(got)
            owned[2].h.on_done({ exit_code = 1, error = "delete stopped: cancelled" })
            assert.same({ "refused", "deletion: delete stopped: cancelled" }, { got.outcome, got.message })
        end)

        it("reports a failed task, a lost connection, a refusal, a decline and a degraded method as refused", function()
            local outs = {}
            local function start()
                model.call(WS, "Maintenance/1.nuke", { plan = "N", yes = true }, function(x) outs[#outs + 1] = x end)
                return owned[#owned].h
            end
            start().on_done({ exit_code = 1, error = "cannot nuke: a build holds it" })
            start().on_done(nil, "the workspace daemon disconnected")
            start().on_reply({ outcome = "refused", message = "the build directories to delete changed" })
            start().on_reply({ outcome = "declined", reason = "retiring" })
            start().on_reply({ outcome = "degraded", reason = "unknown_method" })
            start().on_reply({ outcome = "failed", reason = "timeout" })
            assert.equals(6, #outs)
            for _, o in ipairs(outs) do assert.equals("refused", o.outcome) end
            assert.equals("nuke: cannot nuke: a build holds it", outs[1].message)
            assert.equals("nuke: the workspace daemon disconnected", outs[2].message)
            assert.equals("nuke: the build directories to delete changed", outs[3].message)
            for _, o in ipairs(owned) do assert.same({ plan = "N", yes = true }, o.args) end
        end)

        it("cancels the editor's own tasks on the target first: the profile's, its build dirs', the project's; all for a nuke", function()
            local function task(t) t.units = t.units or {}; return t end
            local of_profile = task({ profile_name = "dev" })
            local on_dir = task({ units = { { project = "app", unit = { build_dir_value = "/W/B/Dbg" } } } })
            local other = task({ profile_name = "rel", units = { { project = "lib", unit = { build_dir_value = "/w/b/R" } } } })
            local on_app = task({ units = { { project = "app" } } })
            run("Maintenance/1.execute_deletion", { target = { profile = PROW }, plan = "T", yes = true })
            assert.same({ true, true, false, false }, { cancelled_by(of_profile), cancelled_by(on_dir),
                cancelled_by(other), cancelled_by(nil) })
            run("Maintenance/1.execute_deletion", { target = { unit = PROW.units[1] }, plan = "T", yes = true })
            assert.same({ false, true, false }, { cancelled_by(of_profile), cancelled_by(on_dir), cancelled_by(other) })
            run("Maintenance/1.execute_deletion", { target = { project = { id = "4:1", key = "app" } }, plan = "T", yes = true })
            assert.same({ true, false, false }, { cancelled_by(on_app), cancelled_by(other), cancelled_by(of_profile) })
            run("Maintenance/1.execute_deletion", { target = { orphans = true }, plan = "T", yes = true })
            assert.same({ false, false }, { cancelled_by(on_app), cancelled_by(of_profile) })
            run("Maintenance/1.nuke", { plan = "N", yes = true })
            assert.same({ true, true }, { cancelled_by(other), cancelled_by(nil) })
            assert.equals(5, #owned)
        end)
    end)

    -- Step 5o C2c-1: the SDK section's picker lists Sdks/1.detect's
    -- installations (version, the provider's prompt), makes a typed path
    -- absolute, and offers `D` on a row only when actionable.
    describe("the SDK section", function()
        local saved, sent, picks, typed, input, notes
        before_each(function()
            sent, picks, input, notes = {}, {}, "rel/sdk", {}
            saved = { model.call, vim.ui.select, vim.ui.input, vim.notify, package.loaded["loomworks.ui.status"] }
            model.call = function(_, method, params, cb)
                sent[#sent + 1] = { method, params }
                if method == "Sdks/1.detect" then
                    return cb({ outcome = "ok", providers = { { id = "fake", label = "Fake", path_prompt = "Path to fake",
                        found = { { path = "/opt/fake", version = "2" }, { path = "/declared" } } } } })
                end
                cb({ outcome = "ok", sdk = { id = "1:1", key = "fake-2" } })
            end
            vim.ui.select = function(items, _, cb) picks[#picks + 1] = items; cb(items[#items]) end
            vim.ui.input = function(opts, cb) typed = opts.prompt; cb(input) end
            vim.notify = function(msg) notes[#notes + 1] = msg end
            package.loaded["loomworks.ui.status"] = { refresh = function() end }
        end)
        after_each(function()
            model.call, vim.ui.select, vim.ui.input, vim.notify, package.loaded["loomworks.ui.status"] =
                saved[1], saved[2], saved[3], saved[4], saved[5]
        end)
        local function render(ctx)
            local nodes, items = {}, {}
            local tree = { blank = function() end, leaf = function() end,
                node = function(_, label, opts) nodes[#nodes + 1] = { label = label, opts = opts } end,
                item = function(_, label, opts) items[#items + 1] = { label = label, opts = opts } end }
            package.loaded["loomworks.ui.sections.sdks"] = nil
            require("loomworks.ui.sections.sdks")(tree, ctx)
            return nodes, items
        end

        it("picks from detect; a typed path is sent absolute; `D` only on a row with an id (daemon mode)", function()
            local view = { sdk_providers = 1, sdks = {
                { id = "1:1", key = "a", label = "A", path = "/declared", resolved = true, kits = {} },
                { key = "b", label = "B", resolved = false, kits = {} } } }
            local nodes, items = render({ mode = "daemon", view = view, ws = {}, ref = function() return nil end })
            assert.is_function(nodes[1].opts.on_delete)
            assert.is_nil(nodes[2].opts.on_delete)
            items[1].opts.on_enter()
            -- The declared path is not offered again; the browse entry last.
            assert.same({ "Fake 2  /opt/fake", "Fake  (browse for path...)" },
                vim.tbl_map(function(c) return c.label end, picks[1]))
            assert.equals("Path to fake: ", typed)
            assert.same({ "Sdks/1.add", { provider = "fake", path = vim.fn.fnamemodify("rel/sdk", ":p") } }, sent[2])
            assert.is_true(vim.fn.fnamemodify(sent[2][2].path, ":p") == sent[2][2].path)
            vim.ui.select = function(choices, _, cb) cb(choices[1]) end -- "Yes"
            nodes[1].opts.on_delete()
            assert.same({ "Sdks/1.remove", { sdk = view.sdks[1] } }, sent[3])
        end)

        it("a typed path is trimmed of whitespace and one pair of quotes; blank adds nothing; the added message names the entry", function()
            local view = { sdk_providers = 1, sdks = {} }
            local abs = vim.fn.fnamemodify("rel/sdk", ":p")
            for _, typed_in in ipairs({ '  "rel/sdk"  ', "'rel/sdk'", "\t rel/sdk \n" }) do
                sent, input = {}, typed_in
                local _, items = render({ mode = "daemon", view = view, ws = {}, ref = function() return nil end })
                items[1].opts.on_enter()
                assert.same({ "Sdks/1.add", { provider = "fake", path = abs } }, sent[2], typed_in)
            end
            -- The picked entry's name (the provider's label), not the SDK's key.
            assert.equals("loomworks: SDK 'Fake' added", notes[#notes])
            for _, blank in ipairs({ "", "   ", '""', "' '" }) do
                sent, input = {}, blank
                local _, items = render({ mode = "daemon", view = view, ws = {}, ref = function() return nil end })
                items[1].opts.on_enter()
                assert.equals(1, #sent, blank) -- only the detect
            end
            vim.ui.select = function(choices, _, cb) cb(choices[1]) end
            notes = {}
            local _, items = render({ mode = "daemon", view = view, ws = {}, ref = function() return nil end })
            items[1].opts.on_enter()
            assert.equals("loomworks: SDK 'Fake 2' added", notes[#notes])
        end)
    end)

    it("a deletion's confirmation shows the listing; `y` sends exactly its plan with yes; success only once ended (5o C2c-2)", function()
        local actions = require("loomworks.ui.actions")
        local saved_call, saved_dialog, saved_notify = model.call, package.loaded["loomworks.ui.dialog"], vim.notify
        local sent, shown, notes, finish = {}, nil, {}, nil
        model.call = function(ws, method, params, cb)
            sent[#sent + 1] = { ws, method, params }
            if not params.yes then return cb({ outcome = "confirm", lines = { "Delete project 'app':" }, plan = "P1" }) end
            finish = cb
        end
        package.loaded["loomworks.ui.dialog"] = { show = function(o) shown = o end }
        vim.notify = function(msg, level) notes[#notes + 1] = { msg, level } end
        local ok, err = pcall(function()
            local WS, PROW = {}, { id = "4:1", key = "app" }
            actions.delete_project(PROW, WS)()
            assert.is_table(shown)
            assert.truthy(table.concat(shown.lines, " "):find("Delete project 'app':", 1, true))
            shown.keys.y({ close = function() end })
            assert.same({ { WS, "Maintenance/1.execute_deletion", { target = { project = PROW } } },
                { WS, "Maintenance/1.execute_deletion", { target = { project = PROW }, plan = "P1", yes = true } } }, sent)
            assert.same({}, notes)
            finish({ outcome = "ok" })
            assert.same({ { "loomworks: project 'app' removed", vim.log.levels.INFO } }, notes)
            -- Nothing to delete is information, not an error; no dialog.
            shown, notes = nil, {}
            model.call = function(_, _, _, cb)
                cb({ outcome = "refused", message = "deletion: nothing to delete", stream = "out" })
            end
            actions.delete_orphans(WS)()
            assert.is_nil(shown)
            assert.same({ { "loomworks: deletion: nothing to delete", vim.log.levels.INFO } }, notes)
        end)
        model.call, package.loaded["loomworks.ui.dialog"], vim.notify = saved_call, saved_dialog, saved_notify
        assert(ok, err)
    end)

    it("editor_ops.cancel_owned_matching cancels the selected owned calls and waits for each to end (5o C2c-2)", function()
        local eo = require("loomworks.daemon.editor_ops")
        local saved = package.loaded["loomworks.daemon.observer"]
        local ended, asked = {}, {}
        local T1, T2 = { name = "a" }, { name = "b" }
        local fake = {}
        function fake:owned_calls() return { { id = 1, task = T1 }, { id = 2, task = T2 }, { id = 3 } } end
        function fake:cancel_owned_id(id, cb) asked[#asked + 1] = id; ended[id] = cb end
        package.loaded["loomworks.daemon.observer"] = { of = function() return fake end }
        local ok, err = pcall(function()
            local done = 0
            eo.cancel_owned_matching({}, function(t) return t == T1 or t == nil end, function() done = done + 1 end)
            table.sort(asked)
            assert.same({ 1, 3 }, asked)
            assert.equals(0, done)
            ended[1](true)
            assert.equals(0, done)
            ended[3](true)
            assert.equals(1, done)
            -- Nothing selected (or no observer): done at once.
            asked = {}
            eo.cancel_owned_matching({}, function() return false end, function() done = done + 1 end)
            assert.same({}, asked)
            assert.equals(2, done)
            package.loaded["loomworks.daemon.observer"] = { of = function() return nil end }
            eo.cancel_owned_matching({}, function() return true end, function() done = done + 1 end)
            assert.equals(3, done)
        end)
        package.loaded["loomworks.daemon.observer"] = saved
        assert(ok, err)
    end)

    it("reads an outcome as ok, err (a warn note of an ok is the error shown)", function()
        assert.same({ true }, { model.result({ outcome = "ok" }) })
        assert.same({ false, "no" }, { model.result({ outcome = "refused", message = "no" }) })
        assert.same({ false, "half" },
            { model.result({ outcome = "ok", notes = { "fine", "half" }, note_roles = { "info", "warn" } }) })
    end)

    -- Guard ratchet (5o C0): the status page's sections and dialogs reach
    -- model writes only through ui/model_calls.lua — never the view-model's
    -- write adapters, the command layer, or the loomworks / workspace / unit
    -- write functions themselves.
    it("is the only ui/ file that reaches a model write", function()
        local adapters = { "execute_[%w_]+", "publish", "revert_to_baseline", "publish_one", "revert_one",
            "set_intent", "set_description", "activate_profile", "add_profile_tool", "remove_profile_tool",
            "save_deploy", "save_type_config_field", "add_sdk", "remove_sdk", "resolve_config_set_choice" }
        local patterns = {}
        for _, a in ipairs(adapters) do
            patterns[#patterns + 1] = "%f[%w_]wv%." .. a .. "%("
            patterns[#patterns + 1] = "%f[%w_]workspace_view%." .. a .. "%("
            patterns[#patterns + 1] = 'workspace_view"%)%.' .. a .. "%("
        end
        vim.list_extend(patterns, {
            'require%("loomworks%.model_commands"%)',
            "%.execute_deletion%(", "%.nuke_cache%(", "%.delete_user_prefs%(", "%.trust_user_prefs%(",
            "%.rescan_tools%(", ":delete%(", ":delete_orphaned_build_dir%(", ":ensure_profile%(",
            ":add_sdk%(", ":remove_sdk%(", ":publish%(", ":publish_one%(", ":revert_one%(",
            ":revert_to_baseline%(", ":set_description%(", ":save_[%w_]+%(", ":rename_[%w_]+%(",
            ":delete_[%w_]+%(", ":add_configuration_set%(", ":remove_configuration_set%(", ":add_project%(",
            ":remove_project%(",
            -- The domain objects' own writes (C0 review).
            ":activate%(", ":set_intent%(", ":update_mapping%(", ":add_tool%(", ":remove_tool%(",
            ":map_variant%(", "%.set_lsp_option%(",
        })
        -- Recorded exceptions (file → the exact line), each with its reason:
        -- the LSP section's options go through `lw.set_lsp_option`, which in
        -- `daemon` mode is only `LspConfig/1.set_option` (editor_ops, step
        -- 5l) -- already a daemon call, not a catalogue method of the seam.
        local allowed = {
            ["lua/loomworks/ui/sections/lsp.lua"] = {
                ['lw.set_lsp_option("clangd", "clang_tidy", not opts.clang_tidy)'] = true,
                ['lw.set_lsp_option("clangd", "background_index",'] = true,
                ['lw.set_lsp_option("clangd", "background_index_priority", next_v)'] = true,
                ['lw.set_lsp_option("clangd", "extra_args", parts)'] = true,
                ['lw.set_lsp_option("clangd", "extra_args", {})'] = true,
            },
        }
        local found = {}
        local base = root .. "/lua/loomworks/ui"
        for _, path in ipairs(vim.fn.globpath(base, "**/*.lua", false, true)) do
            local rel = path:gsub("\\", "/"):match("lua/loomworks/ui/.*$")
            if rel ~= "lua/loomworks/ui/model_calls.lua" then
                local fh = assert(io.open(path, "r"))
                local n = 0
                for line in fh:lines() do
                    n = n + 1
                    if not line:match("^%s*%-%-") and not (allowed[rel] or {})[vim.trim(line)] then
                        for _, pat in ipairs(patterns) do
                            if line:find(pat) then
                                found[#found + 1] = rel .. ":" .. n .. ": " .. vim.trim(line)
                                break
                            end
                        end
                    end
                end
                fh:close()
            end
        end
        assert.same({}, found)
    end)
end)
