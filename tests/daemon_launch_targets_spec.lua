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
end)
