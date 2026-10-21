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
            calls[#calls + 1] = { object = object, iface = iface, method = method }
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

    it("the buffer's 'modified' follows the daemon's view, not the editor's model: `:e` refused (5o C2a)", function()
        fake_obs()
        header()
        -- An edit of the editor's own model is not what `:w` / `:e!` act on
        -- in daemon mode: it does not mark the buffer.
        ws:get_profiles()[1]._intent = "local+shared"
        assert.is_true(ws:has_any_modified())
        -- Waiting for the view (none held yet): nothing known, not modified.
        assert.is_nil((obs:workspace_view()))
        assert.is_false(status_source.modified(ws))
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        assert.is_false(status_source.modified(ws))
        -- The daemon's working copy has unpublished changes.
        views.set(obs, "workspace", daemon_view(function(v) v.modified = true end))
        assert.is_true(status_source.modified(ws))
        -- An acwrite buffer as the status page's (ui/view.lua: 'modified'
        -- from `is_modified`, `:e` -> BufReadCmd -> revert): Vim refuses
        -- `:e` (E37), so no revert runs.
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "acwrite"
        vim.api.nvim_buf_set_name(buf, "loomworks://status-e37-spec")
        local reverted = false
        vim.api.nvim_create_autocmd("BufReadCmd", { buffer = buf, callback = function() reverted = true end })
        vim.bo[buf].modified = status_source.modified(ws)
        local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd("edit") end)
        assert.is_false(ok)
        assert.truthy(tostring(err):find("E37", 1, true), tostring(err))
        assert.is_false(reverted)
        vim.api.nvim_buf_delete(buf, { force = true })
        -- Selected for daemon mode but not connected at all: not modified
        -- (`:w` / `:e!` are refused then).
        views.clear(obs)
        ws._daemon_observer = nil
        ws._runtime_selection = { daemon = true }
        obs = nil
        assert.is_false(status_source.modified(ws))
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
end)
