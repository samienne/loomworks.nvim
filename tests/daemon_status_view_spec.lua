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

    it("no row reaches the editor's model: a unit row's options read names it by its unit_id (5o C2d-2)", function()
        fake_obs({ [observer.VIEW_WORKSPACE.feature] = "subscribed", [observer.TASKS.feature] = "subscribed",
            [observer.PROJECTS.feature] = "available" })
        header()
        views.set(obs, "workspace", daemon_view())
        local body = status_source.read(ws)
        assert.is_nil(body.ref)
        local prow = body.view.profiles[1]
        local u = prow.units[1]
        assert.is_string(u.unit_id)
        -- A daemon row is never bound to an object of the editor's model.
        for _, row in ipairs({ prow, u, body.view.config_sets[1], body.view.projects[1],
            body.view.projects[1].configurations[1] }) do
            assert.is_nil(status_source.object_of(row))
        end
        require("loomworks.ui.actions").show_options(u, ws)()
        local sent
        for _, c in ipairs(calls) do
            if c.method == "unit_options" then sent = c end
        end
        assert.is_not_nil(sent, vim.inspect(calls))
        assert.same({ "/projects", "loomworks.Projects" }, { sent.object, sent.iface })
        assert.same({ unit = { id = u.unit_id } }, sent.args)
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
        assert.is_nil(status_source.object_of(fresh))
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

    it("a project the editor's model does not have yet: its launch, deploy and variable rows act by the row's id (5o C2b2-2)", function()
        fake_obs({ [observer.VIEW_WORKSPACE.feature] = "subscribed", [observer.TASKS.feature] = "subscribed",
            [observer.PROJECTS.feature] = "available" })
        header()
        views.set(obs, "workspace", daemon_view(function(v)
            local p = vim.deepcopy(v.projects[1])
            p.key, p.id = "fresh", "id:fresh"
            p.configurations = { p.configurations[1] }
            p.configurations[1].id = "id:fresh/Debug"
            p.launches = { { key = "go", id = "id:fresh:go", command = "tool" } }
            p.deploy = { { destination = "out/", sources = { { project = "fresh", path = "lib" } } } }
            p.variables = { flavor = { type = "string", default = "x" } }
            v.projects[#v.projects + 1] = p
        end))
        local body = status_source.read(ws)
        local fresh = body.view.projects[#body.view.projects]
        assert.is_nil(status_source.object_of(fresh))
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local lines = tree:render()
        local at
        local found = {}
        local function grab(name, l, i, pat)
            if found[name] == nil and l:find(pat, 1, true) then
                local meta = tree.line_meta[i]
                found[name] = meta and meta.on_enter or false
            end
        end
        for i, l in ipairs(lines) do
            if l:find("fresh [shell]", 1, true) then at = i end
            if at and i > at then
                grab("launch", l, i, "go ")
                grab("add_launch", l, i, "Add launch config")
                grab("deploy", l, i, "<- fresh : lib")
                grab("add_deploy", l, i, "Add deploy step")
                grab("variable", l, i, "flavor")
                grab("add_variable", l, i, "Add variable")
            end
        end
        assert.is_not_nil(at, table.concat(lines, "\n"))
        for _, name in ipairs({ "launch", "add_launch", "deploy", "add_deploy", "variable", "add_variable" }) do
            assert.is_function(found[name], name .. " is inert:\n" .. table.concat(lines, "\n"))
        end
        -- The launch editor's read names the project by the row's id.
        local orig = observer.loaded_workspace
        observer.loaded_workspace = function() return ws end
        local ok, err = pcall(found.launch)
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

    it("a deploy step's edit and removal find the shown source in the re-read declaration by content; gone is refused; the editor's variables are the declaration's (5o C2b2-2)", function()
        fake_obs({ [observer.VIEW_WORKSPACE.feature] = "subscribed", [observer.TASKS.feature] = "subscribed",
            [observer.PROJECTS.feature] = "available" })
        header()
        local A, B = { project = "fresh", path = "a" }, { project = "fresh", path = "b" }
        views.set(obs, "workspace", daemon_view(function(v)
            local p = vim.deepcopy(v.projects[1])
            p.key, p.id = "fresh", "id:fresh"
            p.deploy = { { destination = "out/", sources = { vim.deepcopy(A), vim.deepcopy(B) } } }
            v.projects[#v.projects + 1] = p
        end))
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local meta
        for i, l in ipairs(tree:render()) do
            if l:find("<- fresh : b", 1, true) then meta = tree.line_meta[i] end
        end
        assert.is_table(meta)
        assert.is_function(meta.on_delete)
        assert.is_function(meta.on_enter)
        -- The declaration as re-read (changed since the page was shown).
        local model = require("loomworks.ui.model_calls")
        local decl, saves = nil, {}
        local orig_call, orig_notify = model.call, vim.notify
        local notes = {}
        model.call = function(_, m, p, cb)
            if m == "Projects/1.declaration" then
                return cb({ outcome = "ok", deploy = decl, variables = { declared = { type = "path" } } })
            end
            if m == "Projects/1.deploy_save" then saves[#saves + 1] = p.deploy; return cb({ outcome = "ok" }) end
        end
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        local editor = require("loomworks.ui.deploy_editor")
        local orig_open, opened = editor.open, nil
        editor.open = function(o) opened = o end
        local ok, err = pcall(function()
            -- Reordered: the removal takes B, not whatever is at B's shown index.
            decl = { ["out/"] = { vim.deepcopy(B), vim.deepcopy(A) } }
            meta.on_delete()
            assert.same({ ["out/"] = A }, saves[1])
            -- The edit replaces B where it now is.
            meta.on_enter()
            -- Its variables are the declaration's, as the launch editor's.
            assert.same({ declared = { type = "path" } }, opened.variables)
            opened.on_accept("out/", { project = "fresh", path = "c" })
            assert.same({ ["out/"] = { { project = "fresh", path = "c" }, A } }, saves[2])
            -- Gone from the declaration: refused, nothing saved.
            decl = { ["out/"] = vim.deepcopy(A) }
            meta.on_delete()
            opened.on_accept("out/", { project = "fresh", path = "c" })
            assert.equals(2, #saves)
            assert.equals(2, #notes)
            assert.truthy(notes[1].msg:find("changed since", 1, true), notes[1].msg)
        end)
        model.call, vim.notify, editor.open = orig_call, orig_notify, orig_open
        assert(ok, err)
    end)

    it("the launch editor re-renders when the daemon's debug adapter records arrive (5o C2b2-2)", function()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view(function(v)
            v.projects[1].launches = { { key = "go", id = "id:app:go", command = "tool" } }
        end))
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local enter
        for i, l in ipairs(tree:render()) do
            if not enter and l:find("go ", 1, true) and tree.line_meta[i] then enter = tree.line_meta[i].on_enter end
        end
        assert.is_function(enter)
        local model = require("loomworks.ui.model_calls")
        local le = require("loomworks.ui.launch_editor")
        local orig_call, orig_open, opened = model.call, le.open, nil
        model.call = function(_, m, _, cb)
            if m == "Projects/1.declaration" then
                return cb({ outcome = "ok", launches = { { key = "go", id = "id:app:go", fields = { command = "tool" } } } })
            end
        end
        le.open = function(o) opened = o end
        local ok, err = pcall(enter)
        model.call, le.open = orig_call, orig_open
        assert(ok, err)
        assert.is_table(opened)
        assert.is_function(opened.on_debug_adapters)
        -- The read answers: the dialog's `arrived` runs.
        local REC = { language = "c++", adapter = "codelldb" }
        obs.can_call = function() return true end
        obs._debug_adapters = { languages = { REC } }
        local arrived = 0
        opened.on_debug_adapters(function() arrived = arrived + 1 end)
        assert.equals(1, arrived)
        assert.same({ REC }, opened.debug_adapters())
        -- "Add debug language" reads DebugConfig/1.known_languages.
        assert.is_function(opened.debug_languages)
        local asked
        obs.request = function(_, m, _, cb)
            asked = m
            cb({ outcome = "ok", result = { outcome = "ok", languages = { "c++", "typescript" } } })
        end
        local langs
        opened.debug_languages(function(l) langs = l end)
        assert.equals("known_languages", asked)
        assert.same({ "c++", "typescript" }, langs)
    end)

    it("the launch editor is told a target-backed launch resolves ${target_dir}; a command launch not (§8.7)", function()
        fake_obs()
        header()
        views.set(obs, "workspace", daemon_view(function(v)
            v.projects[1].launches = { { key = "chk", id = "id:app:chk", target = "CoreTests" },
                { key = "go", id = "id:app:go", command = "tool" } }
        end))
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        setmetatable(tree._folds, { __index = function() return true end })
        local enters = {}
        for i, l in ipairs(tree:render()) do
            for _, k in ipairs({ "chk", "go" }) do
                if not enters[k] and l:find(k .. " ", 1, true) and tree.line_meta[i] then
                    enters[k] = tree.line_meta[i].on_enter
                end
            end
        end
        local model = require("loomworks.ui.model_calls")
        local le = require("loomworks.ui.launch_editor")
        local orig_call, orig_open, opened = model.call, le.open, nil
        model.call = function(_, m, _, cb)
            if m == "Projects/1.declaration" then
                return cb({ outcome = "ok", launches = {
                    { key = "chk", id = "id:app:chk", fields = { target = "CoreTests" } },
                    { key = "go", id = "id:app:go", fields = { command = "tool" } } } })
            end
        end
        le.open = function(o) opened = o end
        local ok, err = pcall(function()
            assert.is_function(enters.chk)
            enters.chk()
            assert.is_table(opened)
            assert.is_true(opened.target_context)
            opened = nil
            assert.is_function(enters.go)
            enters.go()
            assert.is_table(opened)
            assert.is_falsy(opened.target_context)
        end)
        model.call, le.open = orig_call, orig_open
        assert(ok, err)
    end)

    it("the rows keep the view's ids (for 5o C2)", function()
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
        local v = daemon_view(function(v)
            local row = v.profiles[1]
            row.busy, row.running, row.status = true, true, "building"
            row.units[1].state = "building"
        end)
        views.set(obs, "workspace", v)
        -- A task another client started, as Tasks/1 `start` names it (by the
        -- rows' ids, step 5o C2d-2), with its last `progress` percent; the
        -- editor's model has no operation.
        local t = remote_task.new(nil, 7, { kind = "build", name = "dev", profile = "dev", profile_id = v.profiles[1].id,
            units = { { project = "app", configuration = "Debug", id = v.profiles[1].units[1].unit_id } } },
            obs:_clock() - 65)
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

    --- The `get`s of the workspace view sent so far.
    local function view_gets()
        local n = 0
        for _, c in ipairs(calls) do
            if c.method == "get" and c.iface == "loomworks.view.Workspace" then n = n + 1 end
        end
        return n
    end

    it("an editor state-file write refetches the workspace view once per turn (`_own_write`)", function()
        local fresh = daemon_view(function(v) v.modified = true end)
        fake_obs(nil, function() return fresh end)
        header()
        views.set(obs, "workspace", daemon_view(function(v) v.modified = false end))
        obs:_own_write()
        obs:_own_write()
        assert.is_true(vim.wait(1000, function() return views.daemon_state(obs, "workspace") == fresh end, 10))
        assert.equals(1, view_gets())
        assert.is_true(status_source.modified(ws))
    end)

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

    it("a unit's elapsed time comes only from a task naming that unit's id", function()
        fake_obs()
        header()
        local v = daemon_view(function(v)
            local row = v.profiles[1]
            row.busy, row.running, row.status = true, true, "building"
            row.units[1].state = "building"
        end)
        views.set(obs, "workspace", v)
        local key = ws:get_profiles()[1]:projects()[1]:config_key()
        assert.is_not_nil(key)
        local id = v.profiles[1].units[1].unit_id
        assert.is_string(id)
        -- A units-scoped task (no profile) of another unit of app; and one
        -- naming this unit's key but no id (never matched by key).
        local t = remote_task.new(nil, 8, { kind = "build", name = "app/Release",
            units = { { project = "app", configuration = "Release", id = "id:other" },
                { project = "app", configuration = key } } }, obs:_clock() - 65)
        t.pct = 42
        obs._tasks[8], obs._order = t, { 8 }
        local body = status_source.read(ws)
        local row = body.view.profiles[1]
        assert.is_nil(body.unit_progress(row.units[1]))
        assert.is_nil(body.profile_progress(row))
        -- One of the row's unit's configuration: its elapsed time.
        local t2 = remote_task.new(nil, 9, { kind = "build", name = "app/" .. key,
            units = { { project = "app", configuration = key, id = id } } }, obs:_clock() - 65)
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

    it("in-process mode: a launch row's editor opens on the declaration, its preview answered at once (5o C2b2-2)", function()
        core:shutdown()
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        -- (Loaded as the editor's setup does, in the in-process mode: its
        -- calls given no workspace go to it.)
        require("loomworks.daemon.observer").attach(ws, { configured = "in-process" })
        -- (A preview expands under the active profile.)
        assert(require("loomworks.workspace_view").activate_profile(ws:get_profiles()[1]))
        local body = status_source.read(ws)
        assert.equals("in-process", body.mode)
        local ctx = { lw = require("loomworks"), view = body.view, ws = ws, mode = body.mode }
        local page = Tree.new(function(t) require("loomworks.ui.sections.projects")(t, ctx) end)
        setmetatable(page._folds, { __index = function() return true end })
        local enter
        for i, l in ipairs(page:render()) do
            if l:find("run ", 1, true) and page.line_meta[i] and page.line_meta[i].on_enter then
                enter = page.line_meta[i].on_enter
                break
            end
        end
        assert.is_function(enter)
        local le = require("loomworks.ui.launch_editor")
        local orig, got = le.open, nil
        le.open = function(o) got = o end
        local ok, err = pcall(enter)
        le.open = orig
        assert(ok, err)
        assert.is_table(got)
        assert.equals("run", got.name)
        assert.equals("tool", got.command)
        assert.same({ "-v" }, got.args)
        local value
        got.preview("${workspace_root}/w", function(v) value = v end)
        assert.equals(vim.fs.normalize(ws.root) .. "/w", vim.fs.normalize(value))
        -- The preview is the project's, outside a launch target: ${target_dir}
        -- is unresolved there (§8.7) and stays as written (API.md §19).
        got.preview("${target_dir}/w", function(v) value = v end)
        assert.equals("${target_dir}/w", value)
        -- In-process the debug adapter records are the working copy's.
        assert.is_table(got.debug_adapters())
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
