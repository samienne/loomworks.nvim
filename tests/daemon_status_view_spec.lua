-- The status page's body in daemon mode (step 5n part C1; daemon.md §19.13
-- "The workspace view", "Freshness of views"; API.md §14.4 "Progress is not
-- in the view"): in `daemon` mode the Diagnostics, Suggestions, Profiles,
-- Orphaned, Configuration Sets, Projects and SDKs sections render only from
-- the daemon's `loomworks.view.Workspace/1`; nothing of them is built
-- in-process; while the view is not held each is one `unavailable — <why>`
-- line; the page re-renders on the view's `update`; an editor write makes
-- the observer `get` the view; a busy profile's percent and a running unit's
-- elapsed time come from the tasks observed through `Tasks/1`.
--
-- The cases drive a real loaded (shell) workspace with a fake connected
-- observer whose connection records its calls.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local remote_task = require("loomworks.daemon.remote_task")
local view_state = require("loomworks.view_state")
local views = require("loomworks.views")
local status_source = require("loomworks.status_source")
local Tree = require("loomworks.ui.tree")
local H = require("tests.daemon_helpers")

describe("the status page body in daemon mode (§19.13 The workspace view)", function()
    local root, core, ws, obs, calls
    local built

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        -- Count in-process builds of the body: none in daemon mode.
        built = 0
        local orig = ws.view_workspace
        ws.view_workspace = function(...)
            built = built + 1
            return orig(...)
        end
    end)
    after_each(function()
        if obs then views.clear(obs) end
        if ws then ws._daemon_observer = nil end
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    --- A connected observer of `ws` over a fake connection recording calls;
    --- `get` answers `answer_get()`.
    local function fake_obs(feat, answer_get)
        calls = {}
        local conn = { closed = false }
        function conn:call(object, iface, v, method, args, cb)
            calls[#calls + 1] = { object = object, iface = iface, method = method, args = args }
            if method == "get" and answer_get then cb(answer_get(), nil) end
        end
        function conn:close() self.closed = true end
        obs = setmetatable({
            ws = ws, root = ws.root, state = "connected", mode = "interfaces", conn = conn,
            daemon = { pid = 1 }, seq = 0, _tasks = {}, _order = {}, _owned = {},
            _feat = feat or { [observer.VIEW_WORKSPACE.feature] = "subscribed", [observer.TASKS.feature] = "subscribed" },
            _why = {},
            opts = { environ = function() return {} end },
        }, observer.Observer)
        function obs:_spawn() end
        ws._daemon_observer = obs
        return obs
    end

    --- The daemon's view of this workspace: its shape built by the daemon's
    --- builder from the loaded model (before the in-process count starts to
    --- matter), with daemon ids and a marker the in-process model lacks.
    local function daemon_view(mutate)
        local v = view_state.workspace(ws, { published = true, stray_dirs = {},
            id = function(o) return "id:" .. tostring(o.key or o.name) end })
        v.profiles[1].description = "from the daemon"
        if mutate then mutate(v) end
        return v
    end

    local function header(state)
        views.set(obs, "header", { root = ws.root, state = state or "loaded", name = ws.name, pid = 1,
            lw_version = "x", session_generation = 1 })
    end

    local function render()
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local lines = tree:render()
        return lines, table.concat(lines, "\n")
    end

    local function count(lines, s)
        local n = 0
        for _, l in ipairs(lines) do if l:find(s, 1, true) then n = n + 1 end end
        return n
    end

    it("declares view.Workspace/1 on /views, subscribed and re-fetched like the other views", function()
        assert.equals("/views", observer.VIEW_WORKSPACE.object)
        assert.equals("loomworks.view.Workspace", observer.VIEW_WORKSPACE.iface)
        assert.equals(1, observer.VIEW_WORKSPACE.v)
        assert.equals("workspace", observer.VIEW_WORKSPACE.view)
        assert.is_true(vim.tbl_contains(observer.VIEWS, observer.VIEW_WORKSPACE))
        assert.is_true(vim.tbl_contains(observer.FEATURES, observer.VIEW_WORKSPACE))
    end)

    it("renders the body only from the daemon's view; nothing of it is built in-process", function()
        fake_obs()
        header()
        local v = daemon_view()
        views.set(obs, "workspace", v)
        assert.equals("daemon", status_source.read(ws).mode)
        local lines, text = render()
        assert.equals(0, built)
        assert.truthy(text:find("from the daemon", 1, true), text)
        assert.truthy(text:find("Profiles", 1, true), text)
        assert.truthy(text:find("Projects", 1, true), text)
        -- (Only the Debug Adapters section's own: DebugConfig/1 is not carried here.)
        assert.equals(1, count(lines, "unavailable —"))
        -- The status buffer's 'modified' is the daemon's view's (5o C2a:
        -- publish and revert run in the daemon).
        assert.is_false(status_source.modified(ws))
        v.modified = true
        assert.is_true(status_source.modified(ws))
        assert.equals(0, built)
    end)

    it("the rows' actions not routed yet reach the editor's model objects by the keys they show (until 5o C2b/C2c)", function()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view())
        local body = status_source.read(ws)
        local prow = body.view.profiles[1]
        assert.equals(ws:get_active_profile() or ws:get_profiles()[1], body.ref(prow))
        assert.equals("dev", body.ref(prow).key)
        assert.equals("app", body.ref(prow.units[1]):project_key())
        assert.equals("dev", body.ref(body.view.config_sets[1]).name)
        local proj = body.ref(body.view.projects[1])
        assert.equals("app", proj.key)
        assert.equals(proj:get_configuration("Debug"), body.ref(body.view.projects[1].configurations[1]))
        assert.equals(0, built)
    end)

    it("a project the editor's model does not have yet: its configuration editor and Add configuration act by the row's id (5o C2b2)", function()
        fake_obs({ [observer.VIEW_WORKSPACE.feature] = "subscribed", [observer.TASKS.feature] = "subscribed",
            [observer.PROJECTS.feature] = "available" })
        header()
        -- A project the daemon just added: in its view with ids, not (yet) in
        -- the editor's model.
        views.set(obs, "workspace", daemon_view(function(v)
            local p = vim.deepcopy(v.projects[1])
            p.key, p.id = "fresh", "id:fresh"
            p.configurations = { p.configurations[1] }
            p.configurations[1].id = "id:fresh/Debug"
            v.projects[#v.projects + 1] = p
        end))
        local body = status_source.read(ws)
        local fresh = body.view.projects[#body.view.projects]
        assert.equals("fresh", fresh.key)
        assert.is_nil(body.ref(fresh))
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local lines = tree:render()
        local at, cfg_enter, add_enter
        for i, l in ipairs(lines) do
            if l:find("fresh [shell]", 1, true) then at = i end
            if at and i > at then
                local meta = tree.line_meta[i]
                if not cfg_enter and l:find("Debug", 1, true) and meta and meta.fold_key then
                    cfg_enter = meta.on_enter or false
                end
                if not add_enter and l:find("Add configuration", 1, true) then
                    add_enter = meta and meta.on_enter or false
                end
            end
        end
        assert.is_not_nil(at, table.concat(lines, "\n"))
        assert.is_function(cfg_enter, "the configuration row has no editor")
        assert.is_function(add_enter, "Add configuration is inert")
        -- The editor's read names the project by the row's id.
        local orig = observer.loaded_workspace
        observer.loaded_workspace = function() return ws end
        local ok, err = pcall(cfg_enter)
        observer.loaded_workspace = orig
        assert(ok, err)
        local sent
        for _, c in ipairs(calls) do
            if c.method == "declaration" then sent = c end
        end
        assert.is_not_nil(sent, vim.inspect(calls))
        assert.same({ project = { id = "id:fresh" } }, sent.args)
        assert.equals(0, built)
    end)

    it("a launch row reaches its launch configuration; the rows keep the view's ids (for 5o C2)", function()
        core:shutdown()
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view())
        local body = status_source.read(ws)
        local prow = body.view.projects[1]
        local lrow = prow.launches[1]
        assert.equals("run", lrow.key)
        local launch = body.ref(lrow)
        assert.is_not_nil(launch)
        assert.equals("run", launch.name)
        assert.equals(body.ref(prow):launch_configs()[1], launch)
        -- The ids the daemon's view carries are on the rows the page renders.
        assert.equals("id:dev", body.view.profiles[1].id)
        assert.equals("id:dev", body.view.config_sets[1].id)
        assert.equals("id:app", prow.id)
        assert.equals("id:Debug", prow.configurations[1].id)
        assert.equals("id:run", lrow.id)
    end)

    it("while the view is not offered each body section is one `unavailable — <why>` line", function()
        local feat = {}
        fake_obs(feat)
        obs._why[observer.VIEW_WORKSPACE.feature] = observer.feature_note(observer.VIEW_WORKSPACE, {})
        header()
        local lines, text = render()
        assert.equals(0, built)
        local why = "unavailable — daemon offers no loomworks.view.Workspace, editor needs /1"
        assert.equals(7, count(lines, why), text)
        for _, title in ipairs({ "Diagnostics", "Suggestions", "Profiles", "Orphaned Build Dirs",
            "Configuration Sets", "Projects", "SDKs" }) do
            assert.truthy(vim.tbl_contains(vim.tbl_map(vim.trim, lines), title), title .. "\n" .. text)
        end
        -- Never the "not on disk" banner from a view it does not have.
        assert.equals(0, count(lines, "not on disk"))
        assert.equals(0, count(lines, "from the daemon"))
    end)

    it("waiting for the daemon (subscription pending) and a lost connection say so", function()
        fake_obs({ [observer.VIEW_WORKSPACE.feature] = "pending" })
        local lines = render()
        assert.equals(7, count(lines, "unavailable — waiting for the workspace daemon"))
        obs._lost = true
        lines = render()
        -- (And the Debug Adapters section's, from the same note.)
        assert.equals(8, count(lines, "unavailable — " .. observer.LOST_NOTE))
        assert.equals(0, built)
    end)

    it("takes loaded from view.Header/1: an unloaded workspace's published=false shows no banner", function()
        fake_obs()
        header("unloaded")
        views.set(obs, "workspace", view_state.workspace(nil))
        local lines, text = render()
        assert.equals(0, count(lines, "not on disk"), text)
        -- Loaded and really unpublished: the banner.
        header("loaded")
        views.set(obs, "workspace", daemon_view(function(v) v.published = false end))
        lines, text = render()
        assert.equals(1, count(lines, "not on disk"), text)
        assert.equals(0, built)
    end)

    it("re-renders on the view's update (daemon_view_changed)", function()
        fake_obs()
        header()
        obs:_view_subscribed(observer.VIEW_WORKSPACE, { sub_id = 1, seq = 1, initial = daemon_view() })
        local seen = 0
        local events = require("loomworks.events")
        local function on() seen = seen + 1 end
        events.on("daemon_view_changed", on)
        obs:_on_message({ kind = "signal", object = "/views", iface = "loomworks.view.Workspace", v = 1,
            name = "update", seq = 2, args = daemon_view(function(v) v.profiles[1].description = "updated" end) })
        events.off("daemon_view_changed", on)
        assert.equals(1, seen)
        local _, text = render()
        assert.truthy(text:find("updated", 1, true), text)
        assert.is_nil(text:find("from the daemon", 1, true))
        assert.equals(0, built)
    end)

    it("an editor write (working copy, cache, publish) makes the observer get the view once", function()
        local fresh = daemon_view(function(v) v.profiles[1].description = "fresh" end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view())
        local function gets()
            local n = 0
            for _, c in ipairs(calls) do
                if c.method == "get" and c.iface == "loomworks.view.Workspace" then n = n + 1 end
            end
            return n
        end
        -- Several files in one turn: one get.
        assert.is_true(ws:_save_user())
        ws:_save_cache()
        assert.equals(0, gets())
        assert.is_true(vim.wait(1000, function() return gets() == 1 end, 10))
        vim.wait(50)
        assert.equals(1, gets())
        assert.equals("fresh", views.daemon_state(obs, "workspace").profiles[1].description)
        -- A publish (loomworks.json) too.
        local ok = ws:publish()
        assert.is_true(ok)
        assert.is_true(vim.wait(1000, function() return gets() == 2 end, 10))
        -- Not subscribed: no get.
        obs._feat[observer.VIEW_WORKSPACE.feature] = nil
        ws:_save_user()
        vim.wait(50)
        assert.equals(2, gets())
    end)

    it("overlays a busy profile's percent and a running unit's elapsed time from Tasks/1", function()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view(function(v)
            local row = v.profiles[1]
            row.busy, row.running, row.status = true, true, "building"
            row.units[1].state = "building"
        end))
        -- A task another client started, as Tasks/1 `start` names it, with
        -- its last `progress` percent; the editor's model has no operation.
        local t = remote_task.new(nil, 7, { kind = "build", name = "dev", profile = "dev",
            units = { { project = "app", configuration = "Debug" } } }, obs:_clock() - 65)
        t.pct = 42
        obs._tasks[7], obs._order = t, { 7 }
        local dev = ws:get_profiles()[1]
        assert.is_nil(dev:operation_pct())
        local lines, text = render()
        assert.truthy(text:find("42%", 1, true), text)
        assert.truthy(count(lines, "1m05s") >= 2, text)
        -- No task: no progress (never the editor's model).
        obs._tasks, obs._order = {}, {}
        lines, text = render()
        assert.is_nil(text:find("42%", 1, true), text)
        assert.equals(0, count(lines, "1m05s"))
        assert.equals(0, built)
    end)

    --- An acwrite buffer as the status page's: 'modified' from
    --- status_source.modified, BufReadCmd (`:e` / `:e!`) wired by
    --- ui/view.lua's attach_revert to the page's revert. Returns the buffer
    --- and the `Workspace/1.revert_to_baseline` calls made (model_calls spied).
    local function status_buffer()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "acwrite"
        vim.api.nvim_buf_set_name(buf, "loomworks://status-revert-spec-" .. buf)
        vim.bo[buf].modified = status_source.modified(ws)
        local reverts = {}
        local mc = require("loomworks.ui.model_calls")
        local orig = mc.call
        mc.call = function(w, method, ...)
            if method == "Workspace/1.revert_to_baseline" then reverts[#reverts + 1] = w; return end
            return orig(w, method, ...)
        end
        require("loomworks.ui.view").attach_revert(buf, require("loomworks.ui.status")._on_revert)
        local function done()
            mc.call = orig
            vim.api.nvim_buf_delete(buf, { force = true })
        end
        local function edit(cmd)
            return pcall(vim.api.nvim_buf_call, buf, function() vim.cmd(cmd) end)
        end
        return reverts, edit, done, buf
    end

    --- A status-page write not routed to the daemon yet (Sdks/1 until 5o
    --- C2c), run in-process through ui/model_calls: an SDK added (the
    --- editor's model's write stubbed).
    local function in_process_write()
        local wv = require("loomworks.workspace_view")
        local orig = wv.add_sdk
        local saved = false
        wv.add_sdk = function() saved = true; return {} end
        local r
        require("loomworks.ui.model_calls").call(ws, "Sdks/1.add",
            { provider = "x", path = "/sdk" }, function(x) r = x end)
        wv.add_sdk = orig
        assert.is_true(saved)
        assert.equals("ok", r and r.outcome)
    end

    --- The `get`s of the workspace view sent so far.
    local function view_gets()
        local n = 0
        for _, c in ipairs(calls) do
            if c.method == "get" and c.iface == "loomworks.view.Workspace" then n = n + 1 end
        end
        return n
    end

    it("the buffer's 'modified' follows the daemon's view while it is held and fresh, else the editor's model (5o C2a)", function()
        fake_obs()
        header()
        -- An unpublished edit of the editor's own model.
        ws:get_profiles()[1]._intent = "local+shared"
        assert.is_true(ws:has_any_modified())
        -- Waiting for the view (none held yet): the daemon's state is not
        -- known — the editor's model's (modified here).
        assert.is_nil((obs:workspace_view()))
        assert.is_true(status_source.modified(ws))
        -- Held and fresh: the daemon's view's.
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        assert.is_false(status_source.modified(ws))
        views.set(obs, "workspace", daemon_view(function(v) v.modified = true end))
        assert.is_true(status_source.modified(ws))
        -- Selected for daemon mode but not connected at all: the editor's
        -- model's.
        views.clear(obs)
        ws._daemon_observer = nil
        ws._runtime_selection = { daemon = true }
        obs = nil
        assert.is_true(status_source.modified(ws))
    end)

    it("view not held and the editor's model modified: `:e` is refused (E37), no revert runs", function()
        fake_obs()
        header()
        ws:get_profiles()[1]._intent = "local+shared"
        assert.is_nil((obs:workspace_view()))
        local reverts, edit, done = status_buffer()
        local ok, err = edit("edit")
        done()
        assert.is_false(ok)
        assert.truthy(tostring(err):find("E37", 1, true), tostring(err))
        assert.equals(0, #reverts)
    end)

    it("in daemon mode a plain `:e` never reverts (the buffer's flag can lag); `:e!` does", function()
        fake_obs()
        header()
        -- View not held, the editor's model clean: not marked, `:e` allowed —
        -- it re-renders, never reverts.
        assert.is_false(ws:has_any_modified())
        assert.is_false(status_source.modified(ws))
        local reverts, edit, done = status_buffer()
        assert.is_true((edit("edit")))
        assert.equals(0, #reverts)
        -- `:e!` is the user's revert.
        assert.is_true((edit("edit!")))
        done()
        assert.equals(1, #reverts)
    end)

    it("an in-process write the daemon has not answered the freshness `get` for marks the buffer; `:e` reverts nothing", function()
        -- `get` never answered: the view stays the one before the write.
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        assert.is_false(status_source.modified(ws))
        -- An editor-side save alone (e.g. a reload's) is not a status-page
        -- write: the view's flag still.
        ws:get_profiles()[1]._intent = "local+shared"
        assert.is_true(ws:_save_user())
        assert.is_false(status_source.modified(ws))
        -- An in-process write (Projects/1 until 5o C2b) leaving the working
        -- copy unpublished: the observer gets the view; until it answers,
        -- the held view does not know the write.
        in_process_write()
        assert.is_true(status_source.modified(ws))
        assert.is_true(vim.wait(1000, function()
            for _, c in ipairs(calls) do
                if c.method == "get" and c.iface == "loomworks.view.Workspace" then return true end
            end
            return false
        end, 10))
        assert.is_true(status_source.modified(ws))
        local reverts, edit, done, buf = status_buffer()
        local ok, err = edit("edit")
        assert.is_false(ok)
        assert.truthy(tostring(err):find("E37", 1, true), tostring(err))
        -- Even were the buffer not marked: a plain `:e` reverts nothing.
        vim.bo[buf].modified = false
        edit("edit")
        done()
        assert.equals(0, #reverts)
    end)

    it("a failed freshness `get` leaves the write unknown: still the editor's model's flag (5o C2b)", function()
        -- The `get` is answered with nothing usable (a failed read).
        fake_obs(nil, function() return nil end)
        -- (Its retry held, not run: below.)
        obs.opts.defer = function() end
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        ws:get_profiles()[1]._intent = "local+shared"
        in_process_write()
        assert.is_true(vim.wait(1000, function() return view_gets() > 0 end, 10))
        vim.wait(50)
        assert.is_true(obs:workspace_view_stale())
        assert.is_true(status_source.modified(ws))
    end)

    it("an async in-process write is stale from its start; the freshness `get` is sent once it ended (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        ws:get_profiles()[1]._intent = "local+shared"
        local wv = require("loomworks.workspace_view")
        local orig = wv.execute_delete_stray_dir
        local done
        wv.execute_delete_stray_dir = function(_, _, cb) done = cb end
        local r
        require("loomworks.ui.model_calls").call(ws, "Maintenance/1.execute_deletion",
            { target = { stray_dir = "/w/x" } }, function(x) r = x end)
        wv.execute_delete_stray_dir = orig
        -- Running: stale, and no `get` yet (its answer could not know the write).
        vim.wait(50)
        assert.is_true(obs:workspace_view_stale())
        assert.equals(0, view_gets())
        assert.is_nil(r)
        -- Ended: the `get` is sent; its answer ends the mark.
        done(true)
        assert.equals("ok", r and r.outcome)
        assert.is_true(vim.wait(1000, function() return views.daemon_state(obs, "workspace") == fresh end, 10))
        assert.is_false(obs:workspace_view_stale())
    end)

    --- Capture the observer's deferred retries (`opts.defer`) instead of
    --- running timers: `due[i] = { fn, ms }`, fired by the test.
    local function capture_retries(delays)
        local due = {}
        obs.opts.defer = function(fn, ms) due[#due + 1] = { fn = fn, ms = ms } end
        obs.opts.view_retry_ms = delays or { 10, 20, 40 }
        return due
    end

    it("a failed freshness `get` is retried with backoff; an answered retry ends the mark (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        local fails = 2
        fake_obs(nil, function()
            if fails > 0 then fails = fails - 1; return nil end
            return fresh
        end)
        local due = capture_retries()
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        in_process_write()
        assert.is_true(vim.wait(1000, function() return #due == 1 end, 10))
        assert.equals(10, due[1].ms)
        assert.equals(1, view_gets())
        assert.is_true(obs:workspace_view_stale())
        due[1].fn()
        assert.is_true(vim.wait(1000, function() return #due == 2 end, 10))
        assert.equals(20, due[2].ms)
        assert.equals(2, view_gets())
        assert.is_true(obs:workspace_view_stale())
        due[2].fn()
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(3, view_gets())
        assert.equals(fresh, views.daemon_state(obs, "workspace"))
        vim.wait(50)
        assert.equals(2, #due)
    end)

    it("freshness `get` retries exhausted: the workspace view is resubscribed, its `initial` held (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return nil end)
        local conn = obs.conn
        local orig_call = conn.call
        function conn:call(object, iface, v, method, args, cb)
            orig_call(self, object, iface, v, method, args, cb)
            if method == "subscribe" then cb({ sub_id = 8, seq = 5, initial = fresh }, nil) end
        end
        local due = capture_retries({ 10, 20 })
        header()
        obs:_view_subscribed(observer.VIEW_WORKSPACE,
            { sub_id = 7, seq = 1, initial = daemon_view(function(v) v.modified = false end) })
        in_process_write()
        for i = 1, 2 do
            assert.is_true(vim.wait(1000, function() return #due == i end, 10))
            due[i].fn()
        end
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(3, view_gets())
        assert.equals(2, #due)
        local unsub, sub
        for _, c in ipairs(calls) do
            if c.method == "unsubscribe" then unsub = c end
            if c.method == "subscribe" then sub = c end
        end
        assert.is_not_nil(unsub)
        assert.equals(7, unsub.args.sub_id)
        assert.is_not_nil(sub)
        assert.equals("/views", sub.args.object)
        assert.equals("loomworks.view.Workspace", sub.args.iface)
        assert.equals("subscribed", obs._feat[observer.VIEW_WORKSPACE.feature])
        assert.equals(fresh, views.daemon_state(obs, "workspace"))
    end)

    --- Run `Sdks/1.add` in-process in daemon mode with the view-model's
    --- `add_sdk` replaced by `body`; returns the outcome box.
    local function in_process_call(body)
        local wv = require("loomworks.workspace_view")
        local orig = wv.add_sdk
        wv.add_sdk = body
        local box = {}
        local ok, err = pcall(require("loomworks.ui.model_calls").call, ws, "Sdks/1.add",
            { provider = "x", path = "/sdk" }, function(x) box.r = x end)
        wv.add_sdk = orig
        box.ok, box.err = ok, err
        return box
    end

    it("an in-process write whose body throws is refused and ends the write: the freshness `get` is sent (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        local box = in_process_call(function() error("boom") end)
        assert.is_true(box.ok, tostring(box.err))
        assert.equals("refused", box.r and box.r.outcome)
        assert.truthy(tostring(box.r.message):find("boom", 1, true), tostring(box.r.message))
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(1, view_gets())
    end)

    --- Start `Maintenance/1.execute_deletion` of a stray dir in-process in
    --- daemon mode with a body that holds its callback (an async write still
    --- running, e.g. a long deletion). Returns `{ late = <the held callback>, r = <the outcome once called> }`.
    local function held_write()
        local mc = require("loomworks.ui.model_calls")
        local wv = require("loomworks.workspace_view")
        local orig = wv.execute_delete_stray_dir
        local box = {}
        wv.execute_delete_stray_dir = function(_, _, cb) box.late = cb end
        mc.call(ws, "Maintenance/1.execute_deletion", { target = { stray_dir = "/w/x" } },
            function(x) box.r = x end)
        wv.execute_delete_stray_dir = orig
        assert.is_function(box.late)
        return box
    end

    it("an in-process write still running stays unknown: no timer or `get` ends its mark (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        -- No watchdog: the module schedules nothing that could end it.
        assert.is_nil(require("loomworks.ui.model_calls").WRITE_WATCHDOG_MS)
        local w = held_write()
        vim.wait(50)
        assert.is_true(obs:workspace_view_stale())
        -- An editor file write's `get` is answered meanwhile.
        obs:_own_write()
        assert.is_true(vim.wait(1000, function() return view_gets() >= 1 end, 10))
        vim.wait(50)
        assert.is_true(obs:workspace_view_stale())
        assert.is_nil(w.r)
        -- The body's answer ends the write: its `get` ends the mark.
        local before = view_gets()
        w.late(true)
        assert.equals("ok", w.r and w.r.outcome)
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(before + 1, view_gets())
    end)

    it("a write started while a failed `get` waits for its retry: the retry's answer leaves the mark (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        local fails = 1
        fake_obs(nil, function()
            if fails > 0 then fails = fails - 1; return nil end
            return fresh
        end)
        local due = capture_retries()
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        -- W1 ends; its `get` fails: a retry is due.
        in_process_write()
        assert.is_true(vim.wait(1000, function() return #due == 1 end, 10))
        -- W2 starts (still running) before the retry fires.
        local w2 = held_write()
        -- The retry fires while W2 runs: no `get` could end the mark now.
        due[1].fn()
        vim.wait(50)
        assert.equals(1, view_gets())
        assert.is_true(obs:workspace_view_stale())
        -- An editor file write's `get` answered meanwhile leaves it too.
        obs:_own_write()
        assert.is_true(vim.wait(1000, function() return view_gets() == 2 end, 10))
        vim.wait(50)
        assert.is_true(obs:workspace_view_stale())
        -- W2 ends: its `get` ends the mark.
        w2.late(true)
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(3, view_gets())
    end)

    it("stop with a retry of the freshness `get` pending: the retry state is reset, the retry sends nothing (5o C2b)", function()
        fake_obs(nil, function() return nil end)
        local due = capture_retries()
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        in_process_write()
        assert.is_true(vim.wait(1000, function() return #due == 1 end, 10))
        assert.is_not_nil(obs._view_retry_due)
        obs:stop()
        assert.is_nil(obs._view_retry_due)
        assert.is_nil(obs._view_retries)
        local n = view_gets()
        due[1].fn()
        vim.wait(50)
        assert.equals(n, view_gets())
        assert.equals(1, #due)
    end)

    it("a write that ends while the view is resubscribing: a `get` once subscribed, the mark kept until it is answered (5o C2b)", function()
        local old = daemon_view(function(v) v.modified = false end)
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        local conn = obs.conn
        local orig_call = conn.call
        local sub_cb
        function conn:call(object, iface, v, method, args, cb)
            orig_call(self, object, iface, v, method, args, cb)
            if method == "subscribe" then sub_cb = cb end
        end
        header()
        obs:_view_subscribed(observer.VIEW_WORKSPACE, { sub_id = 7, seq = 1, initial = old })
        obs:_resubscribe_view(observer.VIEW_WORKSPACE)
        assert.equals("pending", obs._feat[observer.VIEW_WORKSPACE.feature])
        assert.is_function(sub_cb)
        -- A write starts and ends while the subscribe is unanswered.
        in_process_write()
        assert.is_true(obs:workspace_view_stale())
        vim.wait(50)
        assert.equals(0, view_gets())
        -- The `initial` may predate the write: held, but still stale until a
        -- `get` sent now is answered.
        sub_cb({ sub_id = 8, seq = 2, initial = old }, nil)
        assert.is_true(vim.wait(1000, function() return view_gets() == 1 end, 10))
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(fresh, views.daemon_state(obs, "workspace"))
    end)

    it("freshness `get` retries exhausted without a known `sub_id`: no second subscription, the mark kept (5o C2b)", function()
        fake_obs(nil, function() return nil end)
        local due = capture_retries({ 10 })
        header()
        obs:_view_subscribed(observer.VIEW_WORKSPACE,
            { seq = 1, initial = daemon_view(function(v) v.modified = false end) })
        in_process_write()
        assert.is_true(vim.wait(1000, function() return #due == 1 end, 10))
        due[1].fn()
        assert.is_true(vim.wait(1000, function() return view_gets() == 2 end, 10))
        vim.wait(50)
        for _, c in ipairs(calls) do assert.is_not.equals("subscribe", c.method) end
        assert.equals("subscribed", obs._feat[observer.VIEW_WORKSPACE.feature])
        assert.is_true(obs:workspace_view_stale())
    end)

    it("a body that throws after starting async work: its late answer still sends a freshness `get` (5o C2b)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        local wv = require("loomworks.workspace_view")
        local orig = wv.execute_delete_stray_dir
        local late
        wv.execute_delete_stray_dir = function(_, _, cb) late = cb; error("boom") end
        local box = {}
        box.ok, box.err = pcall(require("loomworks.ui.model_calls").call, ws, "Maintenance/1.execute_deletion",
            { target = { stray_dir = "/w/x" } }, function(x) box.r = x end)
        wv.execute_delete_stray_dir = orig
        assert.is_true(box.ok, tostring(box.err))
        assert.equals("refused", box.r and box.r.outcome)
        assert.is_function(late)
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
        assert.equals(1, view_gets())
        local refused = box.r
        late(true)
        assert.is_true(vim.wait(1000, function() return view_gets() == 2 end, 10))
        assert.equals(refused, box.r)
        assert.is_true(vim.wait(1000, function() return not obs:workspace_view_stale() end, 10))
    end)

    it("the answered freshness `get` ends it: the daemon's view's flag again", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        ws:get_profiles()[1]._intent = "local+shared"
        in_process_write()
        assert.is_true(status_source.modified(ws))
        assert.is_true(vim.wait(1000, function() return views.daemon_state(obs, "workspace") == fresh end, 10))
        assert.is_true(status_source.modified(ws))
        -- The daemon's view says clean (e.g. another client published).
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        assert.is_false(status_source.modified(ws))
    end)

    it("a routed write with no workspace given is decided by the runtime selection: refused with the observer gone, never in-process", function()
        -- The loaded workspace selected for daemon mode, its observer gone
        -- (stopped: no longer current, detached from the workspace).
        observer.attach(ws, { configured = "in-process" })
        ws._runtime_selection = { daemon = true }
        ws._daemon_observer = nil
        assert.is_nil(observer.current())
        local lw = require("loomworks")
        local orig = lw.trust_user_prefs
        local ran = false
        lw.trust_user_prefs = function() ran = true; return "trusted" end
        local out
        require("loomworks.ui.model_calls").call(nil, "Workspace/1.trust_accept", {}, function(r) out = r end)
        lw.trust_user_prefs = orig
        assert.is_false(ran)
        assert.equals("refused", out and out.outcome)
    end)

    it("a unit's elapsed time comes only from a task running that unit's configuration", function()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view(function(v)
            local row = v.profiles[1]
            row.busy, row.running, row.status = true, true, "building"
            row.units[1].state = "building"
        end))
        local key = ws:get_profiles()[1]:projects()[1]:config_key()
        assert.is_not_nil(key)
        -- A units-scoped task (no profile) of another configuration of app.
        local t = remote_task.new(nil, 8, { kind = "build", name = "app/Release",
            units = { { project = "app", configuration = "Release" } } }, obs:_clock() - 65)
        t.pct = 42
        obs._tasks[8], obs._order = t, { 8 }
        local body = status_source.read(ws)
        local row = body.view.profiles[1]
        assert.is_nil(body.unit_progress(row.units[1]))
        assert.is_nil(body.profile_progress(row))
        -- One of the row's unit's configuration: its elapsed time.
        local t2 = remote_task.new(nil, 9, { kind = "build", name = "app/" .. key,
            units = { { project = "app", configuration = key } } }, obs:_clock() - 65)
        obs._tasks[9], obs._order = t2, { 8, 9 }
        body = status_source.read(ws)
        row = body.view.profiles[1]
        local p = body.unit_progress(row.units[1])
        assert.is_not_nil(p)
        assert.equals(65, math.floor(p.elapsed + 0.5))
        assert.is_not_nil(body.profile_progress(row))
    end)

    it("in-process mode still builds the view from the editor's model", function()
        assert.equals("in-process", status_source.read(ws).mode)
        assert.equals(1, built)
        local _, text = render()
        assert.equals(2, built)
        assert.is_nil(text:find("unavailable —", 1, true))
    end)

    it("an in-process row no longer reaches its object once its workspace is torn down", function()
        local body = status_source.read(ws)
        local row = body.view.profiles[1]
        local profile = status_source.object_of(row)
        assert.is_not_nil(profile)
        assert.equals(ws, profile._workspace)
        core:shutdown()
        assert.is_nil(status_source.object_of(row))
        assert.is_nil(body.profile_progress(row))
    end)
end)
