-- Step 5o C2d-2: the rest of the Profiles section's actions by row id —
-- cancel, task output, options, the device choice and the progress overlay
-- match tasks to rows by the `start` meta's ids (API.md §4.2) and name rows
-- by their ids; nothing reaches the editor's model through a `ref`.

local model = require("loomworks.ui.model_calls")
local remote_task = require("loomworks.daemon.remote_task")

--- A fake observer carrying every method: records owned calls, plain
--- requests and cancels; `tasks` / `ended` its observed tasks.
local function fake_obs()
    local obs = { state = "connected", owned = {}, cancelled = {}, requests = {}, carried = true,
        running = {}, ended = {} }
    function obs:can_call() return self.carried end
    function obs:refusal(method) return "the daemon does not carry " .. method end
    function obs:start_owned(method, args, h)
        self.owned[#self.owned + 1] = { method = method, args = args, h = h, id = #self.owned + 100 }
    end
    function obs:request(method, args, cb)
        self.requests[#self.requests + 1] = { method = method, args = args, cb = cb }
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
        if on_ended then on_ended(true) end
    end
    function obs:cancel_owned(task, on_ended)
        if not task.owned then
            if on_ended then on_ended(false, "started by lw (cli) — cancel it there") end
            return
        end
        self:cancel_owned_id(task.id, on_ended)
    end
    function obs:tasks() return self.running end
    function obs:ended_tasks() return self.ended end
    function obs:_clock() return 10 end
    return obs
end

local function task(id, meta, owned)
    local t = remote_task.new(nil, id, meta, 0)
    t.owned = owned or nil
    return t
end

describe("Profiles section by row id (step 5o C2d-2)", function()
    local obs, ws, saved_notify, notes
    before_each(function()
        obs = fake_obs()
        ws = { root = "/w", _daemon_observer = obs }
        saved_notify = vim.notify
        notes = {}
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)
    after_each(function() vim.notify = saved_notify end)

    describe("editor_ops replies", function()
        it("only a clean's refusal on stdout is its nothing-to-clean INFO; any other operation's is an error", function()
            local got
            local eo = require("loomworks.daemon.editor_ops")
            eo.run_ids(ws, "build", { unit_ids = { "u:1" } }, { force = true }, {
                resolve = function() got = "resolved" end,
                reject = function() got = "rejected" end,
            })
            obs.owned[1].h.on_reply({ outcome = "refused", stream = "out", exit_code = 1, message = "no" })
            assert.equals("rejected", got)
            assert.equals(vim.log.levels.ERROR, notes[#notes].level)
            got = nil
            eo.run_ids(ws, "clean", { unit_ids = { "u:1" } }, {}, {
                resolve = function() got = "resolved" end,
                reject = function() got = "rejected" end,
            })
            obs.owned[2].h.on_reply({ outcome = "refused", stream = "out", exit_code = 1, message = "nothing" })
            assert.equals("resolved", got)
            assert.equals(vim.log.levels.INFO, notes[#notes].level)
        end)
    end)

    -- The section's rendering with a fake tree: the nodes and items with
    -- their opts.
    local function render(view, mode)
        local nodes = {}
        local tree = setmetatable({}, { __index = function() return function() end end })
        function tree:node(label, opts, children)
            nodes[#nodes + 1] = { label = label, opts = opts }
            if children then children() end
        end
        function tree:item(label, opts) nodes[#nodes + 1] = { label = label, opts = opts } end
        function tree:group(_, _, children) children() end
        package.loaded["loomworks.ui.sections.profiles"] = nil
        view.projects = view.projects or { {} }
        require("loomworks.ui.sections.profiles")(tree, { mode = mode or "daemon", view = view, ws = ws, lw = {},
            unit_progress = function() return nil end, profile_progress = function() return {} end })
        local function find(pred)
            for _, n in ipairs(nodes) do if pred(n) then return n.opts end end
        end
        return {
            profile = function(key)
                return find(function(n) return n.opts and n.opts.fold_key == "profile:" .. key end)
            end,
            unit = function(key, project)
                return find(function(n) return n.opts and n.opts.fold_key == "profile_proj:" .. key .. ":" .. project end)
            end,
            item = function(text)
                return find(function(n) return type(n.label) == "string" and n.label:find(text, 1, true) ~= nil end)
            end,
        }
    end

    local function prow(extra)
        local r = { id = "p:1", key = "dev", status = "built", intent = "local", running = true, units = {
            { project = "app", configuration = "Debug", unit_id = "u:1", state = "building" },
            { project = "lib", configuration = "Debug", unit_id = "u:2", state = "built" } } }
        for k, v in pairs(extra or {}) do
            if v == false then r[k] = nil else r[k] = v end
        end
        return r
    end

    describe("cancel", function()
        it("a profile row cancels the editor's own tasks naming its ids; another client's: cancel it there", function()
            local mine = task(7, { name = "build dev", profile = "dev", profile_id = "p:1",
                units = { { project = "app", id = "u:1" } } }, true)
            local cli = task(8, { name = "build lib", origin = "cli", units = { { project = "lib", id = "u:2" } } })
            -- Named by the profile's key only: not this row's task.
            local by_key = task(9, { name = "old", profile = "dev", units = { { project = "app" } } }, true)
            obs.running = { mine, cli, by_key }
            local acts = render({ profiles = { prow() } }).profile("dev")
            assert.is_function(acts.on_cancel)
            acts.on_cancel()
            assert.same({ 7 }, obs.cancelled)
            local text = {}
            for _, n in ipairs(notes) do text[#text + 1] = n.msg end
            text = table.concat(text, "\n")
            assert.truthy(text:find("cancel it there", 1, true), text)
            assert.truthy(text:find("cancelled 1 task(s) for profile 'dev'", 1, true), text)
        end)

        it("no cancel while no task names the row, or the row is not running", function()
            obs.running = { task(9, { name = "old", profile = "dev", units = { { project = "app" } } }, true) }
            assert.is_nil(render({ profiles = { prow() } }).profile("dev").on_cancel)
            obs.running = { task(7, { name = "b", profile_id = "p:1" }, true) }
            assert.is_nil(render({ profiles = { prow({ running = false }) } }).profile("dev").on_cancel)
        end)

        it("a unit row cancels the task that runs it, even the profile's whole build", function()
            obs.running = { task(7, { name = "build dev", profile_id = "p:1",
                units = { { project = "app", id = "u:1" }, { project = "lib", id = "u:2" } } }, true) }
            local lib = render({ profiles = { prow() } }).unit("dev", "lib")
            assert.is_function(lib.on_cancel)
            lib.on_cancel()
            assert.same({ 7 }, obs.cancelled)
            assert.truthy(notes[#notes].msg:find("cancelled task build dev", 1, true), notes[#notes].msg)
            -- A unit-scoped task of another unit is not this one's.
            obs.running = { task(8, { name = "build app", units = { { project = "app", id = "u:1" } } }, true) }
            assert.is_nil(render({ profiles = { prow() } }).unit("dev", "lib").on_cancel)
        end)
    end)

    describe("task output", function()
        local ro = require("loomworks.ui.remote_output")
        local saved, shown
        before_each(function()
            saved, shown = ro.show, nil
            ro.show = function(t) shown = t end
        end)
        after_each(function() ro.show = saved end)

        it("opens the running task naming the unit, else the last that ended; none: INFO", function()
            local done = task(5, { name = "configure app", units = { { project = "app", id = "u:1" } } })
            done.finished = true
            local later = task(6, { name = "build app", units = { { project = "app", id = "u:1" } } })
            later.finished = true
            obs.ended = { done, later }
            local open = render({ profiles = { prow() } }).unit("dev", "app").on_enter
            open()
            assert.equals(later, shown)
            local running = task(7, { name = "build dev", profile_id = "p:1" })
            obs.running = { running }
            open()
            assert.equals(running, shown)
            shown = nil
            obs.running, obs.ended = {}, {}
            open()
            assert.is_nil(shown)
            assert.equals(vim.log.levels.INFO, notes[#notes].level)
        end)
    end)

    describe("options", function()
        local actions = require("loomworks.ui.actions")
        local saved, opened
        before_each(function()
            saved, opened = actions._options_float, nil
            actions._options_float = function(tree, project) opened = { tree, project } end
        end)
        after_each(function() actions._options_float = saved end)

        it("routes unit_options and sends the unit row's id; the float shows its answer", function()
            assert.is_true(model.routed("Projects/1.unit_options"))
            assert.is_true(vim.tbl_contains(require("loomworks.daemon.observer").PROJECTS.methods, "unit_options"))
            render({ profiles = { prow() } }).unit("dev", "app").on_options()
            assert.equals(1, #obs.requests)
            assert.equals("Projects/1.unit_options", obs.requests[1].method)
            assert.same({ unit = { id = "u:1" } }, obs.requests[1].args)
            local tree = { { key = "A", value = "1" } }
            obs.requests[1].cb({ outcome = "ok", result = { outcome = "ok", options = tree } })
            assert.same({ tree, "app" }, opened)
        end)

        it("a refusal is told, no float; a unit row without an id offers none", function()
            render({ profiles = { prow() } }).unit("dev", "app").on_options()
            obs.requests[1].cb({ outcome = "ok", result = { outcome = "refused", exit_code = 1,
                message = "configuration unit app/Debug is not configured" } })
            assert.is_nil(opened)
            assert.truthy(notes[#notes].msg:find("not configured", 1, true), notes[#notes].msg)
            local bare = prow()
            bare.units[2].unit_id = nil
            assert.is_nil(render({ profiles = { bare } }).unit("dev", "lib").on_options)
            local got
            model.call(ws, "Projects/1.unit_options", { unit = bare.units[2] }, function(x) got = x end)
            assert.equals("refused", got.outcome)
            assert.equals(1, #obs.requests)
        end)

        it("in-process: the bound unit's options, synchronously", function()
            local ss = require("loomworks.status_source")
            local unit = { options = function() return { { key = "B", value = "2" } } end }
            local row = prow()
            ss.bind(row, setmetatable({}, {}))
            ss.bind(row.units[1], setmetatable({ _config_unit = unit }, {}))
            ws = { root = "/w" }
            render({ profiles = { row } }, "in-process").unit("dev", "app").on_options()
            assert.same({ { { key = "B", value = "2" } }, "app" }, opened)
        end)
    end)

    describe("device choice", function()
        local ds = require("loomworks.device_source")
        local saved_scan, saved_select
        local LIST = { { key = "SER1", label = "Phone", state = "online", id = "d:1" },
            { key = "SER2", label = "Tab", state = "online", id = "d:2" } }
        before_each(function()
            saved_scan, saved_select = ds.scan, vim.ui.select
            ds.scan = function(_, cb) cb(LIST) end
        end)
        after_each(function() ds.scan, vim.ui.select = saved_scan, saved_select end)
        local function pick(row, which)
            local formatted
            vim.ui.select = function(items, opts, cb)
                formatted = vim.tbl_map(opts.format_item, items)
                cb(which(items))
            end
            render({ profiles = { row } }).item("Device:").on_enter()
            return formatted
        end

        it("marks the current device by the row's device id; sends the profile and device ids", function()
            local row = prow({ device_capable = true,
                device = { key = "SER2", label = "Tab", state = "online", id = "d:2" } })
            local shown = pick(row, function(items) return items[1] end)
            assert.same({ "Phone (SER1)", "Tab (SER2) (current)", "(clear selection)" }, shown)
            assert.equals("Profiles/1.set_device", obs.requests[1].method)
            assert.same({ profile = { id = "p:1" }, device = { id = "d:1" } }, obs.requests[1].args)
            pick(row, function(items) return items[#items] end)
            assert.equals("Profiles/1.clear_device", obs.requests[2].method)
            assert.same({ profile = { id = "p:1" } }, obs.requests[2].args)
            -- A refusal is reported.
            obs.requests[2].cb({ outcome = "ok", result = { outcome = "refused", message = "stale" } })
            assert.equals(vim.log.levels.ERROR, notes[#notes].level)
        end)

        it("no choice yet: no clear item; a row without an id offers no picker", function()
            local shown = pick(prow({ device_capable = true }), function() return nil end)
            assert.same({ "Phone (SER1)", "Tab (SER2)" }, shown)
            assert.same({}, obs.requests)
            assert.is_nil(render({ profiles = { prow({ id = false, device_capable = true }) } }).item("Device:").on_enter)
        end)
    end)

    describe("progress", function()
        local ss = require("loomworks.status_source")
        it("matches the observed tasks to the rows by the meta's ids, never by key", function()
            local row = prow()
            obs.workspace_view = function() return { profiles = { row } } end
            obs.running = { task(9, { name = "by key", profile = "dev", units = { { project = "app" } } }) }
            local body = ss.read(ws)
            assert.is_nil(body.ref)
            assert.is_nil(body.profile_progress(row))
            assert.is_nil(body.unit_progress(row.units[1]))
            local t = task(7, { name = "build app", units = { { project = "app", id = "u:1" } } })
            t.pct = 40
            obs.running = { t }
            body = ss.read(ws)
            assert.equals(40, body.profile_progress(row).pct)
            assert.is_not_nil(body.unit_progress(row.units[1]))
            assert.is_nil(body.unit_progress(row.units[2]))
            local p = task(8, { name = "build dev", profile_id = "p:1" })
            p.pct = 70
            obs.running = { t, p }
            body = ss.read(ws)
            assert.equals(70, body.profile_progress(row).pct)
            assert.is_not_nil(body.unit_progress(row.units[2]))
        end)
    end)

    it("the observer keeps the last ended tasks (not the ones teardown cleared)", function()
        local observer = require("loomworks.daemon.observer")
        local o = setmetatable({ _tasks = {}, _order = {} }, observer.Observer)
        for i = 1, observer.ENDED_KEEP + 2 do
            local t = task(i, { name = "t" .. i })
            o._tasks[i], o._order[#o._order + 1] = t, i
            t.finished = true
            o:_forget(i)
        end
        local ended = o:ended_tasks()
        assert.equals(observer.ENDED_KEEP, #ended)
        assert.equals(3, ended[1].id)
        local c = task(99, { name = "c" })
        c.finished, c.cleared = true, true
        o._tasks[99], o._order[1] = c, 99
        o:_forget(99)
        ended = o:ended_tasks()
        assert.equals(observer.ENDED_KEEP + 2, ended[#ended].id)
        assert.same({}, o:tasks())
    end)
end)
