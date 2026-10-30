-- loomworks.Launch/1 `targets`, loomworks.Profiles/1 `set_default_target`
-- and `projects[].targets` of loomworks.view.Workspace/1 (API.md §9.6, §11,
-- §14.4; step 6b-α, WP-C), called over transport 11 against an in-process
-- server with the build service attached and a real `shell` workspace whose
-- unit is given parsed build targets. References resolve at the boundary
-- (an id, or a key); the default-target write goes through
-- loomworks.model_commands and persists to the working copy.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

--- The decoded working copy (its signature stripped).
local function working_copy(root)
    local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
    return vim.json.decode(content)
end

describe("Launch/1.targets, Profiles/1.set_default_target, view projects[].targets (step 6b-α)", function()
    local root, srv, conn
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" },
            description = "the tool" } } })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        conn = assert(client.session(srv.address, {}))
    end)
    after_each(function()
        L.cleanup()
        if conn then pcall(conn.close, conn) end
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    local function call_on(object, iface, method, args)
        local r, e
        conn:call(object, iface, 1, method, args or {}, function(res, err) r, e = res, err end, envscope.capture())
        assert.is_true(vim.wait(60000, function() return r ~= nil or e ~= nil end, 10), method .. " never answered")
        assert.is_nil(e, vim.inspect(e))
        return r
    end
    local function launch(method, args) return call_on("/launch", "loomworks.Launch", method, args) end
    local function profiles(method, args) return call_on("/profiles", "loomworks.Profiles", method, args) end

    local function id_of(obj) return srv.service.ids:id(obj) end
    local function find(list, field, value)
        for _, o in pairs(list) do if o[field] == value and not o._removed then return o end end
    end

    --- Load the model and give the live workspace, app's unit given two
    --- parsed targets (one executable).
    local function loaded()
        local done
        conn:call("/internal", "lw.internal.Snapshot", 1, "get", { scope = "config" }, function() done = true end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return done end, 10))
        local ws = assert(srv.service.ws)
        local dev = find(ws._profiles, "key", "dev")
        local unit = dev:projects()[1]._config_unit
        unit:set_targets({ server = { type = "executable" }, core = { type = "static_library" } })
        return ws, dev, unit
    end


    it("targets lists launches then executable build targets, with project ids; nothing default yet", function()
        local ws, dev = loaded()
        local app = find(ws._projects, "key", "app")
        local r = launch("targets", { profile = { id = id_of(dev) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({
            { kind = "launch", project = { id = id_of(app), key = "app" }, name = "run", label = "run",
                description = "the tool", default = false },
            { kind = "target", project = { id = id_of(app), key = "app" }, name = "server", label = "server",
                default = false },
        }, r.targets)
        assert.same({}, r.incomplete)
        assert.is_false(r.override)
    end)

    it("targets by key works; an unknown profile and a stale id are refused", function()
        loaded()
        assert.equals("ok", launch("targets", { profile = { key = "dev" } }).outcome)
        local r = launch("targets", { profile = { key = "nope" } })
        assert.equals("refused", r.outcome)
        assert.matches("no profile 'nope'", r.message, 1, true)
        r = launch("targets", { profile = { id = "999:999" } })
        assert.equals("refused", r.outcome)
        assert.matches("stale", r.message, 1, true)
    end)

    it("set_default_target stores the choice, marks it default; without target it clears it", function()
        local ws, dev = loaded()
        local app = find(ws._projects, "key", "app")
        local r = profiles("set_default_target", { profile = { id = id_of(dev) },
            target = { kind = "target", project = { id = id_of(app) }, name = "server" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ project = "app", target = "server" }, dev._default_target_descriptor)
        assert.same({ project = "app", target = "server" }, working_copy(root).default_target.dev)

        r = launch("targets", { profile = { id = id_of(dev) } })
        assert.is_true(r.override)
        assert.is_false(r.targets[1].default)
        assert.is_true(r.targets[2].default)

        -- A launch configuration, the project by key.
        r = profiles("set_default_target", { profile = { key = "dev" },
            target = { kind = "launch", project = { key = "app" }, name = "run" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ project = "app", launch = "run" }, working_copy(root).default_target.dev)

        -- Clearing: no target.
        r = profiles("set_default_target", { profile = { id = id_of(dev) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(dev._default_target_descriptor)
        local wc = working_copy(root)
        assert.is_nil(wc.default_target and wc.default_target.dev)
        r = launch("targets", { profile = { id = id_of(dev) } })
        assert.is_false(r.override)
    end)

    it("set_default_target refuses a target not among the launchable ones, an unknown profile or a stale id;"
        .. " nothing written", function()
        local ws, dev = loaded()
        local app = find(ws._projects, "key", "app")
        local before = read(root .. "/.nvim/loomworks.user.json")
        local r = profiles("set_default_target", { profile = { id = id_of(dev) },
            target = { kind = "target", project = { id = id_of(app) }, name = "core" } })
        assert.equals("refused", r.outcome)
        assert.equals("no launch target 'app:core (target)' in profile 'dev'", r.message)
        r = profiles("set_default_target", { profile = { id = id_of(dev) },
            target = { kind = "launch", project = { id = id_of(app) }, name = "server" } })
        assert.equals("refused", r.outcome)
        assert.equals("no launch target 'app:server (launch)' in profile 'dev'", r.message)
        r = profiles("set_default_target", { profile = { key = "nope" } })
        assert.equals("refused", r.outcome)
        r = profiles("set_default_target", { profile = { id = id_of(dev) },
            target = { kind = "target", project = { id = "999:999" }, name = "server" } })
        assert.equals("refused", r.outcome)
        assert.matches("stale", r.message, 1, true)
        assert.is_nil(dev._default_target_descriptor)
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)

    it("an unconfigured project of a module that parses targets is incomplete", function()
        local _, dev, unit = loaded()
        local impl = unit._project._module.impl
        local orig = impl.parse_targets
        impl.parse_targets = function() return nil end
        unit:set_targets(nil)
        local ok, err = pcall(function()
            local r = launch("targets", { profile = { id = id_of(dev) } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.same({ "app" }, r.incomplete)
            assert.equals(1, #r.targets)
            -- The sole launchable target is the default (spec §16.17).
            assert.is_true(r.targets[1].default)
        end)
        impl.parse_targets = orig
        assert(ok, err)
    end)

    it("view.Workspace/1 carries each project's parsed build targets by name", function()
        loaded()
        local r = call_on("/views", "loomworks.view.Workspace", "get", {})
        local prow
        for _, p in ipairs(r.projects) do if p.key == "app" then prow = p end end
        assert.is_table(prow, vim.inspect(r.projects))
        assert.same({ server = { type = "executable" }, core = { type = "static_library" } }, prow.targets)
    end)

    --- Make app's unit parse its targets: the shell module given a
    --- `parse_targets` (counting its calls, returning `targets()`) and the
    --- unit configured here. `restore()` undoes it.
    local function parsing(unit, targets)
        local impl = unit._project._module.impl
        local orig = impl.parse_targets
        local p = { calls = 0 }
        impl.parse_targets = function()
            p.calls = p.calls + 1
            return targets()
        end
        unit.state_value = "configured"
        unit.build_dir_value = unit.build_dir_value or (root .. "/out/Debug")
        function p.restore() impl.parse_targets = orig end
        return p
    end

    --- A second session subscribed to the workspace view; `updates` its
    --- `update` signals' states.
    local function view_watcher()
        local w = { updates = {} }
        w.conn = assert(client.session(srv.address, { on_message = function(m)
            if m.kind == "signal" and m.name == "update" and m.iface == "loomworks.view.Workspace" then
                w.updates[#w.updates + 1] = m.args
            end
        end }))
        local r, e
        w.conn:call("/", "loomworks.Root", 1, "subscribe", { object = "/views", iface = "loomworks.view.Workspace",
            v = 1, signals = { "update" } }, function(res, err) r, e = res, err end)
        assert.is_true(vim.wait(30000, function() return r ~= nil or e ~= nil end, 10))
        assert.is_nil(e, vim.inspect(e))
        return w
    end
    local function app_targets(state)
        for _, p in ipairs(state.projects or {}) do if p.key == "app" then return p.targets end end
    end

    it("targets parses unknown targets once; a second call does not re-parse; a newer build re-parses and"
        .. " the view signals the change", function()
        local _, dev, unit = loaded()
        local list = { server = { type = "executable" } }
        local p = parsing(unit, function() return vim.deepcopy(list) end)
        local w = view_watcher()
        local ok, err = pcall(function()
            unit.targets = nil
            local r = launch("targets", { profile = { id = id_of(dev) } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.equals(1, p.calls)
            assert.equals("server", r.targets[2].name)
            r = launch("targets", { profile = { id = id_of(dev) } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.equals(1, p.calls, "a second call re-parsed")

            -- A build since: the build system's targets may have changed.
            list.tool = { type = "executable" }
            unit.last_built = "2099-01-01T00:00:00Z"
            w.updates = {}
            r = launch("targets", { profile = { id = id_of(dev) } })
            assert.equals(2, p.calls)
            local names = {}
            for _, t in ipairs(r.targets) do names[#names + 1] = t.kind .. ":" .. t.name end
            assert.same({ "launch:run", "target:server", "target:tool" }, names)
            assert.is_true(vim.wait(10000, function()
                for _, st in ipairs(w.updates) do
                    local t = app_targets(st)
                    if t and t.tool then return true end
                end
            end, 10), "no view update with the new target")
            -- Current again: no parse.
            launch("targets", { profile = { id = id_of(dev) } })
            assert.equals(2, p.calls)
        end)
        p.restore()
        pcall(w.conn.close, w.conn)
        assert(ok, err)
    end)

    it("set_default_target accepts a target a newer build added, parsing once", function()
        local _, dev, unit = loaded()
        local list = { server = { type = "executable" } }
        local p = parsing(unit, function() return vim.deepcopy(list) end)
        local ok, err = pcall(function()
            unit:set_targets(list)
            list.tool = { type = "executable" }
            unit.last_built = "2099-01-01T00:00:00Z"
            local r = profiles("set_default_target", { profile = { id = id_of(dev) },
                target = { kind = "target", project = { key = "app" }, name = "tool" } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.equals(1, p.calls)
            assert.same({ project = "app", target = "tool" }, working_copy(root).default_target.dev)
            r = profiles("set_default_target", { profile = { id = id_of(dev) },
                target = { kind = "target", project = { key = "app" }, name = "server" } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.equals(1, p.calls, "current targets re-parsed")
        end)
        p.restore()
        assert(ok, err)
    end)

    it("device targets: listed with their label, settable as the default, marked default", function()
        local ws, dev, unit = loaded()
        local app = find(ws._projects, "key", "app")
        local impl = unit._project._module.impl
        local has, dt = impl.has_devices, impl.device_targets
        impl.has_devices = true
        impl.device_targets = function(_, config_name)
            assert.equals("Debug", config_name)
            return { { id = "hap", label = "Phone app" } }
        end
        local ok, err = pcall(function()
            local r = launch("targets", { profile = { id = id_of(dev) } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.same({ kind = "device", project = { id = id_of(app), key = "app" }, name = "hap",
                label = "Phone app", default = false }, r.targets[3])
            r = profiles("set_default_target", { profile = { id = id_of(dev) },
                target = { kind = "device", project = { id = id_of(app) }, name = "hap" } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            local stored = { project = "app", device_target = "hap", device_target_label = "Phone app" }
            assert.same(stored, dev._default_target_descriptor)
            assert.same(stored, working_copy(root).default_target.dev)
            r = launch("targets", { profile = { id = id_of(dev) } })
            assert.is_true(r.override)
            assert.same({ false, false, true }, { r.targets[1].default, r.targets[2].default, r.targets[3].default })
            -- A device target id that is not offered.
            r = profiles("set_default_target", { profile = { id = id_of(dev) },
                target = { kind = "device", project = { id = id_of(app) }, name = "nope" } })
            assert.equals("refused", r.outcome)
            assert.equals("no launch target 'app:nope (device)' in profile 'dev'", r.message)
        end)
        impl.has_devices, impl.device_targets = has, dt
        assert(ok, err)
    end)

    it("is_stored_default matches a device target by project and id only", function()
        local run_prep = require("loomworks.run_prep")
        local proj, other = { key = "app" }, { key = "lib" }
        local desc = { project = "app", device_target = "hap", device_target_label = "Phone app" }
        assert.is_true(run_prep.is_stored_default(desc, { kind = "device", project = proj, device_target = "hap" }))
        assert.is_false(run_prep.is_stored_default(desc, { kind = "device", project = proj, device_target = "x" }))
        assert.is_false(run_prep.is_stored_default(desc, { kind = "device", project = other, device_target = "hap" }))
        assert.is_false(run_prep.is_stored_default(desc, { kind = "target", project = proj, target_id = "hap" }))
        assert.is_false(run_prep.is_stored_default(desc, { kind = "launch", project = proj, name = "hap" }))
    end)

    it("a default-target write that fails restores the previous descriptor", function()
        local ws, dev = loaded()
        local app = find(ws._projects, "key", "app")
        local prev = { project = "app", launch = "run" }
        assert.is_true(dev:set_default_target_descriptor(prev))
        local before = read(root .. "/.nvim/loomworks.user.json")
        ws._no_write = "read-only for the test"
        local ok, err = dev:set_default_target(app, "server")
        assert.is_false(ok)
        assert.equals("read-only for the test", err)
        assert.same(prev, dev._default_target_descriptor)
        ok = dev:clear_default_target()
        assert.is_false(ok)
        assert.same(prev, dev._default_target_descriptor)
        -- Over the daemon: refused, nothing changed.
        local r = profiles("set_default_target", { profile = { id = id_of(dev) },
            target = { kind = "target", project = { id = id_of(app) }, name = "server" } })
        assert.equals("refused", r.outcome)
        assert.same(prev, dev._default_target_descriptor)
        ws._no_write = nil
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)

    it("a default-target write refused as stale keeps the working copy reloaded from disk", function()
        local ws, dev = loaded()
        local app = find(ws._projects, "key", "app")
        assert.is_true(dev:set_default_target_descriptor({ project = "app", launch = "run" }))
        -- Another process writes the working copy: its default target differs.
        local wc = working_copy(root)
        wc.default_target = { dev = { project = "app", target = "core" } }
        local signed, serr = trust.sign("user", trust.encode(wc))
        assert.is_string(signed, serr)
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(signed); f:close()
        local ok, err = dev:set_default_target(app, "server")
        assert.is_false(ok)
        assert.is_string(err)
        -- The reloaded value, neither this write's nor the one before it.
        local cur = find(ws._profiles, "key", "dev")
        assert.same({ project = "app", target = "core" }, cur._default_target_descriptor)
    end)
end)
