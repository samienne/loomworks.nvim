-- Step 5o C2d-1: the Profiles section's builds, configures, cleans and
-- rebuilds go through ui/model_calls.lua naming their rows — in `daemon`
-- mode a `Build/1` call by the profile row's id or the unit rows' `unit_id`s
-- (editor_ops.run_ids, a task the editor owns, never by key and never
-- in-process), in the `in-process` mode the rows' bound objects. The
-- artifact-conflict question comes from the unit rows' `artifact_block`;
-- the clean confirmation from the rows; owned calls record the unit ids,
-- and a RemoteTask reads `profile_id` / `units[].id` from its meta.

local model = require("loomworks.ui.model_calls")
local remote_task = require("loomworks.daemon.remote_task")

--- A fake observer carrying every method: records owned calls; each call
--- stays running until the test ends it.
local function fake_obs()
    local obs = { state = "connected", owned = {}, cancelled = {}, carried = true }
    function obs:can_call() return self.carried end
    function obs:refusal(method) return "the daemon does not carry " .. method end
    function obs:start_owned(method, args, h)
        self.owned[#self.owned + 1] = { method = method, args = args, h = h, id = #self.owned + 100 }
    end
    function obs:owned_calls()
        local out = {}
        for _, o in ipairs(self.owned) do
            if not o.ended then
                out[#out + 1] = { id = o.id, task = o.task, unit_ids = o.h.unit_ids, profile_id = o.h.profile_id }
            end
        end
        return out
    end
    function obs:cancel_owned_id(id, on_ended)
        self.cancelled[#self.cancelled + 1] = id
        for _, o in ipairs(self.owned) do
            if o.id == id then o.ended = true end
        end
        on_ended(true)
    end
    return obs
end

local PROW = { id = "p:1", key = "dev", units = {
    { project = "app", configuration = "Debug", unit_id = "u:1", state = "built", build_dir = "/w/b/app" },
    { project = "lib", configuration = "Debug", state = "unconfigured" },
} }
local UROW = PROW.units[1]

describe("ui.model_calls Build/1 (step 5o C2d-1)", function()
    describe("daemon mode", function()
        local obs, ws, saved_select, saved_notify, notes
        before_each(function()
            obs = fake_obs()
            ws = { root = "/w", _daemon_observer = obs }
            saved_select, saved_notify = vim.ui.select, vim.notify
            notes = {}
            vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        end)
        after_each(function()
            vim.ui.select, vim.notify = saved_select, saved_notify
        end)
        local function run(method, params)
            local got, n = nil, 0
            model.call(ws, method, params, function(r) got = r; n = n + 1 end)
            return function() return got, n end
        end

        it("routes build, configure and clean", function()
            for _, m in ipairs({ "Build/1.build", "Build/1.configure", "Build/1.clean" }) do
                assert.is_true(model.routed(m), m)
            end
        end)

        it("sends the profile row's id, recording its units' ids; answered only at the task's end", function()
            local res = run("Build/1.build", { profile = PROW })
            assert.equals(1, #obs.owned)
            local o = obs.owned[1]
            assert.equals("build", o.method)
            assert.same({ interactive = false, profile = { id = "p:1" } }, o.args)
            assert.same({ "u:1" }, o.h.unit_ids)
            assert.equals("p:1", o.h.profile_id)
            o.h.on_reply({ outcome = "accepted", task_id = 7 })
            local got, n = res()
            assert.equals(0, n)
            o.h.on_done({ exit_code = 0 })
            got, n = res()
            assert.same({ outcome = "ok" }, got)
            assert.equals(1, n)
        end)

        it("a serial build sends jobs = 1; a unit row is sent by its unit_id; configure and clean likewise", function()
            run("Build/1.build", { profile = PROW, jobs = 1 })
            run("Build/1.build", { units = { UROW } })
            run("Build/1.configure", { units = { UROW } })
            run("Build/1.configure", { profile = PROW })
            run("Build/1.clean", { units = { UROW } })
            local args = {}
            for i, o in ipairs(obs.owned) do args[i] = { o.method, o.args } end
            assert.same({
                { "build", { interactive = false, profile = { id = "p:1" }, jobs = 1 } },
                { "build", { interactive = false, units = { { id = "u:1" } } } },
                { "configure", { interactive = false, units = { { id = "u:1" } } } },
                { "configure", { interactive = false, profile = { id = "p:1" } } },
                { "clean", { interactive = false, units = { { id = "u:1" } } } },
            }, args)
            assert.same({ "u:1" }, obs.owned[2].h.unit_ids)
            assert.is_nil(obs.owned[2].h.profile_id)
        end)

        it("refuses a row without an id — never by its key; nothing sent", function()
            local r = {}
            r[1] = run("Build/1.build", { profile = { key = "dev", units = {} } })()
            r[2] = run("Build/1.build", { units = { PROW.units[2] } })()
            r[3] = run("Build/1.clean", { units = {} })()
            for i, x in ipairs(r) do assert.equals("refused", x.outcome, i) end
            assert.truthy(r[1].message:find("no profile id", 1, true), r[1].message)
            assert.truthy(r[2].message:find("no configuration unit id", 1, true), r[2].message)
            assert.same({}, obs.owned)
        end)

        it("a failed task, a refusal and a call not carried are refused", function()
            local res = run("Build/1.build", { units = { UROW } })
            obs.owned[1].h.on_done({ exit_code = 2 })
            assert.equals("refused", (res()).outcome)
            res = run("Build/1.configure", { units = { UROW } })
            obs.owned[2].h.on_reply({ outcome = "refused", message = "no unit with id u:1 (a stale reference)" })
            local got = res()
            assert.same({ "refused", true }, { got.outcome, got.notified })
            assert.truthy(got.message:find("stale reference", 1, true))
            obs.carried = false
            got = run("Build/1.build", { profile = PROW })()
            assert.equals("refused", got.outcome)
            assert.equals(2, #obs.owned)
        end)

        it("asks the artifact-conflict question from the unit rows' artifact_block; Yes is force, No sends nothing", function()
            local blocked = { id = "p:2", key = "rel", units = { { project = "app", unit_id = "u:2",
                artifact_block = { profile = "dev", path = "/w/b/app/app.exe" } } } }
            local asked
            vim.ui.select = function(items, opts, cb) asked = opts.prompt; cb("Yes") end
            run("Build/1.build", { profile = blocked })
            assert.truthy(asked and asked:find("dev", 1, true) and asked:find("app.exe", 1, true), asked)
            assert.same({ interactive = false, profile = { id = "p:2" }, force = true }, obs.owned[1].args)
            vim.ui.select = function(_, _, cb) cb("No") end
            local got = run("Build/1.build", { units = blocked.units })()
            assert.equals("refused", got.outcome)
            assert.equals(1, #obs.owned)
            -- No block: no question; configure never asks.
            vim.ui.select = function() error("asked") end
            run("Build/1.build", { profile = PROW })
            run("Build/1.configure", { profile = blocked })
            assert.equals(3, #obs.owned)
            assert.is_nil(obs.owned[2].args.force)
        end)

        it("a clean first cancels the editor's own calls running the profile or its units, then sends", function()
            run("Build/1.build", { profile = PROW }) -- owned 100: by ids, not started
            run("Build/1.build", { units = { UROW } }) -- 101
            local other = { id = "p:9", key = "x", units = { { project = "z", unit_id = "u:9" } } }
            run("Build/1.build", { profile = other }) -- 102
            -- A started call matched by its task's meta ids (a call by objects).
            obs.owned[#obs.owned + 1] = { method = "build", args = {}, id = 103, h = {},
                task = remote_task.new(nil, 5, { name = "dev", profile = "dev", profile_id = "p:1",
                    units = { { project = "app", configuration = "Debug-x", id = "u:1" } } }, 0) }
            run("Build/1.clean", { units = { UROW } })
            assert.same({ 100, 101, 103 }, obs.cancelled)
            assert.equals("clean", obs.owned[#obs.owned].method)
            assert.same({ interactive = false, units = { { id = "u:1" } } }, obs.owned[#obs.owned].args)
        end)
    end)

    -- A rebuild or clean never decides "nothing to clean" from the rows: the
    -- daemon does (its dir gone, a module with no clean), answering a
    -- `refused` on stdout — reported as INFO, and a rebuild goes on to build.
    describe("the page's clean and rebuild (daemon mode)", function()
        local actions = require("loomworks.ui.actions")
        local obs, ws, saved, notes
        local NOTHING = { outcome = "refused", stream = "out", exit_code = 1,
            message = "nothing to clean for app/Debug — no configured build directories." }
        before_each(function()
            obs = fake_obs()
            ws = { root = "/w", _daemon_observer = obs }
            saved = { vim.notify, actions._show_confirmation }
            notes = {}
            vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
            actions._show_confirmation = function(_, on_confirm) on_confirm() end
        end)
        after_each(function() vim.notify, actions._show_confirmation = saved[1], saved[2] end)
        local function levels()
            local out = {}
            for _, n in ipairs(notes) do out[#out + 1] = n.level end
            return out
        end
        -- A row that says built, its directory since deleted.
        local GONE = { project = "app", configuration = "Debug", unit_id = "u:1", state = "built",
            build_dir = "/w/b/gone" }

        it("unit R: nothing to clean is INFO and the rebuild builds", function()
            actions.rebuild_configuration(GONE, ws)()
            assert.equals(1, #obs.owned)
            assert.equals("clean", obs.owned[1].method)
            obs.owned[1].h.on_reply(NOTHING)
            assert.same({ vim.log.levels.INFO }, levels())
            assert.truthy(notes[1].msg:find("nothing to clean", 1, true), notes[1].msg)
            assert.equals(2, #obs.owned)
            assert.equals("build", obs.owned[2].method)
            assert.same({ interactive = false, units = { { id = "u:1" } } }, obs.owned[2].args)
        end)

        it("unit C: nothing to clean is INFO, never an error", function()
            actions.clean_configuration(GONE, ws)()
            assert.equals("clean", obs.owned[1].method)
            obs.owned[1].h.on_reply(NOTHING)
            assert.same({ vim.log.levels.INFO }, levels())
        end)

        it("a row with no build directory still sends its clean: the daemon decides", function()
            local bare = { project = "lib", configuration = "Debug", unit_id = "u:2", state = "unconfigured" }
            actions.rebuild_configuration(bare, ws)()
            assert.equals("clean", obs.owned[1].method)
            actions.clean_configuration(bare, ws)()
            assert.equals("clean", obs.owned[2].method)
        end)

        it("profile R: nothing to clean, then the build", function()
            local prow = { id = "p:1", key = "dev", units = { GONE } }
            actions.rebuild(prow, ws)()
            assert.equals("clean", obs.owned[1].method)
            obs.owned[1].h.on_reply(NOTHING)
            assert.equals(2, #obs.owned)
            assert.equals("build", obs.owned[2].method)
            assert.same({ interactive = false, profile = { id = "p:1" } }, obs.owned[2].args)
            for _, l in ipairs(levels()) do assert.is_true(l < vim.log.levels.WARN, vim.inspect(notes)) end
        end)

        it("profile R: a clean that really fails builds nothing", function()
            local prow = { id = "p:1", key = "dev", units = { GONE } }
            actions.rebuild(prow, ws)()
            obs.owned[1].h.on_reply({ outcome = "accepted", task_id = 7 })
            obs.owned[1].h.on_done({ exit_code = 2 })
            assert.equals(1, #obs.owned)
            -- A refusal not on stdout is a failure too.
            actions.rebuild(prow, ws)()
            obs.owned[2].h.on_reply({ outcome = "refused", exit_code = 1, message = "a lock is held" })
            assert.equals(2, #obs.owned)
        end)
    end)

    -- Step 5o C2d-1: a daemon-mode row without an id offers no build,
    -- configure, clean or rebuild (nor delete); one with an id does.
    describe("the Profiles section's actions (daemon mode)", function()
        local function render(view)
            local nodes = {}
            -- Every other tree method is a no-op.
            local tree = setmetatable({}, { __index = function() return function() end end })
            function tree:node(label, opts, children)
                nodes[#nodes + 1] = { label = label, opts = opts }
                if children then children() end
            end
            function tree:group(_, _, children) children() end
            package.loaded["loomworks.ui.sections.profiles"] = nil
            require("loomworks.ui.sections.profiles")(tree, { mode = "daemon", view = view, ws = {}, lw = {},
                ref = function() return nil end, unit_progress = function() return nil end,
                profile_progress = function() return {} end })
            return nodes
        end
        local OPS = { "on_build", "on_build_serial", "on_rebuild", "on_clean", "on_configure", "on_delete" }

        it("gates the operations on the row's id", function()
            local view = { projects = { {} }, profiles = {
                { id = "p:1", key = "dev", status = "built", intent = "local", units = {
                    { project = "app", configuration = "Debug", unit_id = "u:1", state = "built" },
                    { project = "lib", configuration = "Debug", state = "unconfigured" } } },
                { key = "ghost", status = "unconfigured", intent = "local", units = {} },
            } }
            local by = {}
            for _, n in ipairs(render(view)) do
                local text = type(n.label) == "table" and n.label[1][1] or n.label
                by[#by + 1] = { text = text, opts = n.opts }
            end
            local function find(pat)
                for _, n in ipairs(by) do if tostring(n.text):find(pat, 1, true) then return n.opts end end
                error("no node " .. pat .. ": " .. vim.inspect(vim.tbl_map(function(n) return n.text end, by)))
            end
            local dev, ghost = find("dev"), find("ghost")
            for _, k in ipairs(OPS) do
                assert.is_function(dev[k], "dev " .. k)
                assert.is_nil(ghost[k], "ghost " .. k)
            end
            local app, lib
            for _, n in ipairs(by) do
                if n.opts.fold_key == "profile_proj:dev:app" then app = n.opts end
                if n.opts.fold_key == "profile_proj:dev:lib" then lib = n.opts end
            end
            assert.is_table(app); assert.is_table(lib)
            for _, k in ipairs(OPS) do
                assert.is_function(app[k], "app " .. k)
                assert.is_nil(lib[k], "lib " .. k)
            end
        end)
    end)

    describe("in-process mode", function()
        local ss = require("loomworks.status_source")
        local fut = require("loomworks.future")
        local saved, calls
        before_each(function()
            calls = {}
            saved = package.loaded["loomworks.overseer"]
            package.loaded["loomworks.overseer"] = {
                run_configuration_action = function(unit, action, _, opts)
                    calls[#calls + 1] = { "unit", unit, action, opts }
                    return fut.resolved(true)
                end,
            }
        end)
        after_each(function() package.loaded["loomworks.overseer"] = saved end)
        local function run(method, params)
            local got
            model.call({ root = "/w" }, method, params, function(r) got = r end)
            vim.wait(100, function() return got ~= nil end)
            return got
        end

        it("runs the bound objects' operations", function()
            local P = setmetatable({}, {})
            function P:build(opts) calls[#calls + 1] = { "build", opts }; return fut.resolved(true) end
            function P:configure() calls[#calls + 1] = { "configure" }; return fut.resolved(true) end
            function P:clean() calls[#calls + 1] = { "clean" }; return fut.rejected("boom") end
            local U = setmetatable({ mark_deleting = function() end }, {})
            function U:clean() calls[#calls + 1] = { "uclean" }; return fut.resolved(true) end
            local prow, urow = { key = "dev" }, { project = "app" }
            ss.bind(prow, P); ss.bind(urow, setmetatable({ _config_unit = U }, {}))
            assert.same({ outcome = "ok" }, run("Build/1.build", { profile = prow }))
            assert.same({ outcome = "ok" }, run("Build/1.build", { profile = prow, jobs = 1 }))
            assert.same({ outcome = "ok" }, run("Build/1.configure", { profile = prow }))
            local r = run("Build/1.clean", { profile = prow })
            assert.same({ "refused", "boom" }, { r.outcome, r.message })
            assert.same({ outcome = "ok" }, run("Build/1.build", { units = { urow }, jobs = 1 }))
            assert.same({ outcome = "ok" }, run("Build/1.configure", { units = { urow } }))
            assert.same({ outcome = "ok" }, run("Build/1.clean", { units = { urow } }))
            assert.same({ { "build" }, { "build", { parallel_jobs = 1 } }, { "configure" }, { "clean" },
                { "unit", U, "build", { parallel_jobs = 1 } }, { "unit", U, "configure" }, { "uclean" } }, calls)
        end)

        it("refuses an unbound row and a unit row with no unit yet; nothing runs", function()
            local bare = { project = "lib" }
            ss.bind(bare, setmetatable({}, {}))
            assert.equals("refused", run("Build/1.build", { profile = { key = "dev" } }).outcome)
            assert.equals("refused", run("Build/1.clean", { units = { { project = "x" } } }).outcome)
            assert.equals("refused", run("Build/1.configure", { units = { bare } }).outcome)
            assert.same({}, calls)
        end)
    end)

    describe("the clean confirmation", function()
        local actions = require("loomworks.ui.actions")

        it("lists the rows' configured units and, in daemon mode, the editor's own calls it stops", function()
            local obs = fake_obs()
            local ws = { root = "/w", _daemon_observer = obs }
            obs.owned[1] = { method = "build", args = {}, id = 1, h = { unit_ids = { "u:1" } } }
            obs.owned[2] = { method = "build", args = {}, id = 2, h = {}, task = remote_task.new(nil, 2,
                { name = "build other", profile_id = "p:9", units = { { project = "z", id = "u:9" } } }, 0) }
            local ctx = actions.clean_confirmation(ws, "Clean profile: dev", "p:1", PROW.units)
            local text = table.concat(ctx.lines, "\n")
            assert.truthy(text:find("Will stop running tasks:\n    task 1", 1, true), text)
            assert.falsy(text:find("build other", 1, true), text)
            assert.truthy(text:find("    app / Debug", 1, true), text)
            assert.falsy(text:find("lib / Debug", 1, true), text)
        end)

        it("in-process: the rows' running builds and configures", function()
            local rows = { { project = "app", configuration = "Debug", state = "building", build_dir = "/b" } }
            local ctx = actions.clean_confirmation({ root = "/w" }, "Rebuild: app / Debug", nil, rows, true)
            local text = table.concat(ctx.lines, "\n")
            assert.truthy(text:find("    app: build Debug", 1, true), text)
            assert.truthy(text:find("then rebuild", 1, true), text)
        end)
    end)

    it("a RemoteTask reads the meta's profile_id and units[].id and matches rows by them", function()
        local t = remote_task.new(nil, 1, { name = "dev", profile = "dev", profile_id = "p:1",
            units = { { project = "app", configuration = "app-Debug", id = "u:1" }, { project = "lib" } } }, 0)
        assert.equals("p:1", t.profile_id)
        assert.same({ "u:1" }, t:unit_ids())
        assert.is_true(t:names_ids("p:1", nil))
        assert.is_true(t:names_ids(nil, { "u:1" }))
        assert.is_false(t:names_ids("p:2", { "u:2" }))
        local old = remote_task.new(nil, 2, { name = "x", profile = "dev", units = { { project = "app" } } }, 0)
        assert.is_nil(old.profile_id)
        assert.is_false(old:names_ids("p:1", { "u:1" }))
    end)
end)
