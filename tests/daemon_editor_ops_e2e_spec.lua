-- The editor's operations as daemon calls, end to end (spec §19.16 "Editor
-- operations", §19.15 "The editor as owner"; step 5k part C1, the plan's
-- real-daemon check): the editor (this process, holding no workspace model
-- as a `daemon`-mode editor holds none, step 6b-alpha; its Observer
-- connected through a real `--stdio` relay to a real shared daemon) builds
-- its profile, naming the view's rows by id. The build is a `Build/1.build`
-- call: nothing runs in-process, the daemon's task is the editor's own (no
-- origin marker), and the operation ends on the task's `done`. A unit build
-- is a `units` call the same way. Then the editor is unloaded
-- in the middle of a slow build: closing its connection cancels the task it
-- owns. No daemon process is left behind.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local observer = require("loomworks.daemon.observer")
local inspect = require("loomworks.daemon.inspect")
local client = require("loomworks.daemon.client")
local relay_client = require("loomworks.daemon.client").relay
local events = require("loomworks.events")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

--- Real relays from this checkout run by nvim (as the specs' `lw`).
local function real_relays()
    return function(ro, cb)
        ro.argv = { vim.v.progpath, "--headless", "-u", "NONE", "--cmd",
            "lua vim.opt.rtp:prepend(" .. string.format("%q", H.REPO) .. ")", "-l", H.CLI }
        return relay_client.connect(ro, cb)
    end
end

-- The `daemon`-mode editor holds no model (step 6b-alpha): its operations
-- name the view rows of `view.Workspace/1` by id (editor_ops.run_ids), a
-- launch a `Launch/1.targets` record (loomworks.daemon.LaunchRef).
describe("editor operations through a real daemon (§19.16, step 5k C1)", function()
    local root, env, obs, seen
    local handlers = {}
    local function on(ev, fn) events.on(ev, fn); handlers[#handlers + 1] = { ev, fn } end

    --- The profile row of the daemon's workspace view (a read the editor
    --- carries loads the workspace in the daemon first; the view follows).
    local function profile_row()
        local views = require("loomworks.views")
        if not (views.header() and views.header().state == "loaded") then
            obs:request("adapters", {}, function() end)
        end
        assert.is_true(vim.wait(60000, function()
            local v = obs:workspace_view()
            return v ~= nil and #(v.profiles or {}) > 0
        end, 20), obs:runtime_line())
        return obs:workspace_view().profiles[1]
    end

    --- The unit row of a profile row, once the view reports it `built`
    --- (from the daemon's committed cache; the view follows).
    local function built_unit(row_id)
        local state
        local ok = vim.wait(30000, function()
            local v = obs:workspace_view()
            for _, p in ipairs(v and v.profiles or {}) do
                if p.id == row_id then
                    local u = (p.units or {})[1]
                    state = u and u.state
                    return state == "built"
                end
            end
            return false
        end, 20)
        assert.is_true(ok, tostring(state))
    end

    --- The unit row ids of a profile row.
    local function unit_ids(row)
        local out = {}
        for _, u in ipairs(row.units or {}) do out[#out + 1] = u.unit_id end
        return out
    end

    --- Run `method` by row ids; its outcome lands in the returned table.
    local function op(method, scope)
        local st = {}
        require("loomworks.daemon.editor_ops").run_ids(nil, method, scope, {}, {
            resolve = function(v) st.ok = v end,
            reject = function(e) st.err = e end,
        })
        return st
    end

    before_each(function()
        root = H.shell_workspace({ profile = true })
        env = H.env({ LOOMWORKS_DATA_DIR = vim.env.LOOMWORKS_DATA_DIR, LOOMWORKS_RUNTIME = "daemon" })
        seen = { started = {}, stopped = {} }
        on("daemon_task_started", function(d) seen.started[#seen.started + 1] = d.task end)
        on("daemon_task_stopped", function(d) seen.stopped[#seen.stopped + 1] = d.task end)
    end)

    after_each(function()
        vim.env.LW_TEST_SLEEP, vim.env.LW_TEST_SLEEP_STEP = nil, nil
        if obs then obs:stop() end
        obs = nil
        for _, h in ipairs(handlers) do events.off(h[1], h[2]) end
        handlers = {}
        observer.detach()
        if inspect.state(root).kind == "live" then H.stop_daemon(root, env) end
        H.track_root(root)
        H.cleanup()
    end)

    it("builds the profile and a unit as calls the editor owns; unloading cancels its running task", function()
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_not_nil(obs)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.is_true(vim.wait(10000, function() return obs:can_call("build") end, 20), obs:runtime_line())
        local row = profile_row()
        local uids = unit_ids(row)
        assert.equals(1, #uids, vim.inspect(row))

        local st = op("build", { profile_id = row.id, unit_ids = uids })
        assert.is_true(vim.wait(120000, function() return st.ok ~= nil or st.err ~= nil end, 20), obs:runtime_line())
        assert.is_true(st.ok, tostring(st.err))
        local task = seen.started[1]
        assert.is_true(task.owned)
        assert.equals("editor", task.origin)
        assert.is_nil(task:origin_label())
        assert.equals(row.id, task.profile_id)
        assert.equals(0, task.exit_code)
        assert.truthy(task:output():find("step build", 1, true), task:output())
        built_unit(row.id)
        assert.is_false(obs:owns_tasks())

        -- A unit build: `units` by id, no profile.
        local st2 = op("build", { unit_ids = uids })
        assert.is_true(vim.wait(120000, function() return st2.ok ~= nil or st2.err ~= nil end, 20))
        assert.is_true(st2.ok, tostring(st2.err))
        assert.is_nil(seen.started[2].profile_name)
        assert.same(uids, seen.started[2]:unit_ids())

        -- A slow build, then the editor unloads: its connection closes and
        -- the daemon cancels the task it owns (§19.15 "Task ownership").
        vim.env.LW_TEST_SLEEP, vim.env.LW_TEST_SLEEP_STEP = "20000", "build"
        local st3 = op("build", { profile_id = row.id, unit_ids = uids })
        assert.is_true(vim.wait(60000, function() return obs:owns_tasks() and #seen.started >= 3 end, 20))
        local id = seen.started[3].id
        obs:stop()
        assert.is_true(vim.wait(5000, function() return st3.err ~= nil end, 20))
        -- Seen from another client: the task is gone well before its sleep ends.
        local cli = assert(client.session(inspect.state(root).handle.endpoint))
        assert.is_true(vim.wait(15000, function()
            local s = client.request(cli, { kind = "status" })
            for _, t in ipairs(s and s.tasks or {}) do
                if t.task_id == id then return false end
            end
            return s ~= nil
        end, 100))
        cli:close()
    end)

    -- The public API (§19.16 "Public API"): `lw.pick_profile()` activates a
    -- profile row by `Profiles/1.set_active`, and `lw.build_profile()` is
    -- the facade's `Build/1.build` of the active profile row, a task the
    -- editor owns; the row's unit is then `built`.
    it("lw.pick_profile then lw.build_profile builds the active profile row as a call the editor owns", function()
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.is_true(vim.wait(10000, function() return obs:can_call("build") end, 20), obs:runtime_line())
        local row = profile_row()
        assert.is_true(require("loomworks.daemon.facade").active())
        local notes = {}
        local orig_notify, orig_select = vim.notify, vim.ui.select
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        local ok, err = pcall(function()
            -- Activated through `lw.pick_profile()` (Profiles/1.set_active)
            -- when the workspace has none active; the view follows.
            if not row.active then
                vim.ui.select = function(items, _, on_choice)
                    for _, it in ipairs(items) do
                        if it.row.id == row.id then return on_choice(it) end
                    end
                    on_choice(nil)
                end
                require("loomworks").pick_profile()
                assert.is_true(vim.wait(30000, function()
                    local p = obs:workspace_view().profiles[1]
                    return p.active == true
                end, 20), vim.inspect(notes))
                row = obs:workspace_view().profiles[1]
            end
            require("loomworks").build_profile()
            assert.is_true(vim.wait(120000, function()
                local t = seen.started[1]
                return t ~= nil and t.exit_code ~= nil
            end, 20), obs:runtime_line())
        end)
        vim.notify, vim.ui.select = orig_notify, orig_select
        assert(ok, err)
        local task = seen.started[1]
        assert.equals("build", task.kind)
        assert.is_true(task.owned)
        assert.is_nil(task:origin_label())
        assert.equals(row.id, task.profile_id)
        assert.equals(0, task.exit_code)
        built_unit(row.id)
        for _, n in ipairs(notes) do
            assert.is_true((n.level or 0) < vim.log.levels.WARN, vim.inspect(notes))
        end
    end)

    -- Step 5k C2: a launch of a non-device target is prepared by the daemon
    -- (`Launch/1.prepare_run`, `build_scope = "target"`): its unit is built
    -- there, by a task the editor owns, and the returned launch is started
    -- here, in the editor's task runner.
    it("prepares an editor launch in the daemon and starts its program here", function()
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
        obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
            relay = real_relays(), keepalive_ms = 500 })
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
        assert.is_true(vim.wait(10000, function() return obs:can_call("prepare_run") end, 20), obs:runtime_line())
        local ov = require("loomworks.overseer")
        local orig = ov.launch_run_task
        local launched = {}
        ov.launch_run_task = function(spec) launched[#launched + 1] = spec; return nil end
        -- Refused while the daemon has not loaded the workspace (§19.16
        -- "Editor operations", step 5l): a read the editor carries loads it.
        local views = require("loomworks.views")
        -- (The daemon may report the workspace loaded already: then there is
        -- no unloaded window to check here.)
        local header = views.daemon_state(obs, "header")
        if header and header.state == "unloaded" then
            local unloaded = require("loomworks.daemon.launch_ref").new({ key = "dev" },
                { kind = "launch", name = "run", project = { key = "app" } })
            assert.truthy(require("loomworks.session_tracker").launch_refusal(unloaded))
        end
        local row = profile_row()
        -- The launch target: the profile row's `Launch/1.targets` record.
        local refs
        require("loomworks.daemon.facade").targets(row, function(r) refs = r end)
        assert.is_true(vim.wait(30000, function() return refs ~= nil end, 20), obs:runtime_line())
        local target
        for _, r in ipairs(refs) do
            if r.kind == "launch" and r.name == "run" then target = r end
        end
        assert.is_not_nil(target, vim.inspect(refs))
        assert.is_nil(require("loomworks.session_tracker").launch_refusal(target))
        require("loomworks.session_tracker").start(target, "launch")
        local ok = vim.wait(120000, function() return #launched > 0 end, 20)
        ov.launch_run_task = orig
        assert.is_true(ok, obs:runtime_line())
        assert.equals("tool", launched[1].cmd)
        assert.same({ "-v" }, launched[1].args)
        local task = seen.started[1]
        assert.equals("run", task.kind)
        assert.is_true(task.owned)
        assert.equals(0, task.exit_code)
        assert.equals(row.id, task.profile_id)
        built_unit(row.id)
        assert.is_false(obs:owns_tasks())
    end)

    -- Step 5k C1b (§19.16 "Tasks in the task runner"), with the specs' fake
    -- overseer (tests/fake_overseer.lua): the editor's own build is one
    -- overseer task whose stop is `Tasks/1.cancel`; a CLI `lw build` is
    -- listed read-only as `[lw] …`, its stop refused.
    it("lists daemon tasks in overseer: the editor's own stops by cancel, a CLI one is read-only", function()
        local saved = { package.loaded["overseer"], package.loaded["overseer.strategy"],
            package.loaded["overseer.util"] }
        local created = {}
        local ov, strat = require("tests.fake_overseer")(created)
        package.loaded["overseer"], package.loaded["overseer.strategy"] = ov, strat
        package.loaded["overseer.util"] = nil
        local ok, err = pcall(function()
            obs = observer.attach(root, { getenv = daemon_mode, resolve = function() return "lw" end,
                relay = real_relays(), keepalive_ms = 500 })
            assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
            H.track_root(root)
            assert.is_true(vim.wait(10000, function() return obs:can_call("build") end, 20), obs:runtime_line())
            vim.env.LW_TEST_SLEEP, vim.env.LW_TEST_SLEEP_STEP = "20000", "build"
            local row = profile_row()

            local st = op("build", { profile_id = row.id, unit_ids = unit_ids(row) })
            assert.is_true(vim.wait(60000, function() return #created >= 1 end, 20))
            local t = created[1]
            assert.equals(seen.started[1].name, t.name)
            assert.equals("RUNNING", t.status)
            local id = seen.started[1].id
            t:stop()
            assert.equals("CANCELED", t.status)
            assert.is_true(vim.wait(15000, function() return st.err ~= nil end, 20))
            assert.equals("CANCELED", t.status)
            local cli = assert(client.session(inspect.state(root).handle.endpoint))
            assert.is_true(vim.wait(15000, function()
                local s = client.request(cli, { kind = "status" })
                for _, x in ipairs(s and s.tasks or {}) do
                    if x.task_id == id then return false end
                end
                return s ~= nil
            end, 100))
            cli:close()
            vim.env.LW_TEST_SLEEP = nil

            -- Another client's build: read-only, its origin marker in its name.
            local vars = vim.deepcopy(env.vars)
            vars.LW_TEST_SLEEP, vars.LW_TEST_SLEEP_STEP = "3000", "build"
            local p = H.lw_start({ "--no-input", "build", row.key }, { env = { vars = vars }, cwd = root })
            H.track(p.pid, p.start)
            assert.is_true(vim.wait(60000, function() return #created >= 2 end, 20), p.stderr())
            local c = created[2]
            assert.equals("[lw] " .. seen.started[#seen.started].name, c.name)
            assert.is_false(c:stop())
            assert.equals("RUNNING", c.status)
            assert.is_true(vim.wait(60000, function() return c.status ~= "RUNNING" end, 20))
            assert.equals("SUCCESS", c.status)
            assert.is_true(vim.wait(60000, function() return p.code ~= nil end, 20))
            assert.equals(0, p.code, p.stderr())
        end)
        package.loaded["overseer"], package.loaded["overseer.strategy"], package.loaded["overseer.util"] =
            saved[1], saved[2], saved[3]
        assert(ok, err)
    end)
end)
