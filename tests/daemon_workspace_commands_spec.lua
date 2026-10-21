-- loomworks.Workspace/1 commands in the daemon (API.md §6, spec daemon.md
-- §19.14 "As interfaces"; step 5o part B1): publish, publish_one,
-- revert_one, revert_to_baseline, set_intent, set_description, trust_accept
-- and delete_user_prefs, called over transport 11 against an in-process
-- server with the build service attached and a real `shell` workspace. Ids
-- resolve to the live objects at the boundary; the write goes through
-- loomworks.model_commands; a publish takes the workspace operation lock O.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local op_lock = require("loomworks.op_lock")
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

--- The decoded loomworks.json.
local function shared(root) return vim.json.decode(read(root .. "/loomworks.json")) end

--- The decoded working copy (its signature stripped).
local function working_copy(root)
    local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
    return vim.json.decode(content)
end

describe("loomworks.Workspace/1 commands (step 5o part B1)", function()
    local root, srv, conn
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
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

    --- A Workspace/1 call: its result (or error).
    local function call(method, args)
        local r, e
        conn:call("/workspace", "loomworks.Workspace", 1, method, args or {}, function(res, err) r, e = res, err end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return r ~= nil or e ~= nil end, 10), method .. " never answered")
        return r, e
    end

    --- Load the model (a snapshot) and give the live workspace.
    local function loaded()
        local done
        conn:call("/internal", "lw.internal.Snapshot", 1, "get", { scope = "config" }, function() done = true end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return done end, 10))
        return assert(srv.service.ws)
    end

    local function id_of(obj) return srv.service.ids:id(obj) end
    local function profile(ws) for _, p in pairs(ws._profiles) do if p.key == "dev" then return p end end end
    local function project(ws) for _, p in pairs(ws._projects) do if p.key == "app" then return p end end end

    it("set_intent makes a profile shared; publish writes it to loomworks.json", function()
        local ws = loaded()
        local dev = profile(ws)
        local r, e = call("set_intent", { item = { id = id_of(dev) }, intent = "local+shared" })
        assert.is_nil(e, vim.inspect(e))
        assert.same({ outcome = "ok" }, { outcome = r.outcome })
        assert.equals("local+shared", dev._intent)
        assert.is_nil((shared(root).profiles or {}).dev)
        r, e = call("publish")
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil((shared(root).profiles or {}).dev, read(root .. "/loomworks.json"))
        assert.is_nil(op_lock.read(root), "O left behind")
    end)

    it("publish_one and revert_one act on one item by id", function()
        local ws = loaded()
        local app = project(ws)
        local r = call("set_description", { item = { id = id_of(app) }, text = "The app" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        r = call("publish_one", { item = { id = id_of(app) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        -- (A project's description lives in its module section, spec §1.10.)
        assert.equals("The app", shared(root).projects.app.shell.description)
        r = call("set_description", { item = { id = id_of(app) }, text = "Changed" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        r = call("revert_one", { item = { id = id_of(app) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("The app", app.description)
    end)

    it("set_description takes a launch id; no text removes it", function()
        local ws = loaded()
        local launch = project(ws)._launches.run
        local r = call("set_description", { item = { id = id_of(launch) }, text = "Runs it" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("Runs it", launch.description)
        assert.equals("Runs it", working_copy(root).projects.app.launch.run.description)
        r = call("set_description", { item = { id = id_of(launch) } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(launch.description)
    end)

    it("publish_one, revert_one and set_intent refuse a launch id, naming its project", function()
        local ws = loaded()
        local id = id_of(project(ws)._launches.run)
        local before = read(root .. "/loomworks.json")
        for _, m in ipairs({ { "publish_one", {} }, { "revert_one", {} }, { "set_intent", { intent = "local" } } }) do
            local args = m[2]
            args.item = { id = id }
            local r = call(m[1], args)
            assert.equals("refused", r.outcome, vim.inspect(r))
            assert.equals("a launch configuration is published with its project app", r.message)
            assert.equals(1, r.exit_code)
        end
        assert.equals(before, read(root .. "/loomworks.json"))
    end)

    it("a stale or unknown id is refused and changes nothing", function()
        loaded()
        local before = read(root .. "/.nvim/loomworks.user.json")
        local r = call("set_intent", { item = { id = "999.999" }, intent = "local" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("no item with id 999.999 %(a stale reference%)", r.message)
        r = call("set_description", { item = { id = "999.999" }, text = "x" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)

    it("an unknown intent or a key reference is invalid", function()
        local ws = loaded()
        local _, e = call("set_intent", { item = { id = id_of(profile(ws)) }, intent = "public" })
        assert.equals("invalid_args", e and e.code, vim.inspect(e))
        _, e = call("publish_one", { item = { key = "dev" } })
        assert.equals("invalid_args", e and e.code, vim.inspect(e))
    end)

    it("publish is refused while another process holds the workspace operation lock", function()
        local ws = loaded()
        assert.equals("ok", call("set_intent", { item = { id = id_of(profile(ws)) }, intent = "local+shared" }).outcome)
        local before = read(root .. "/loomworks.json")
        local h = L.hold(op_lock.path(root), "import")
        local r = call("publish")
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("pid " .. h.pid, r.message, 1, true)
        assert.equals(before, read(root .. "/loomworks.json"))
        r = call("publish_one", { item = { id = id_of(profile(ws)) } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(before, read(root .. "/loomworks.json"))
    end)

    it("revert_to_baseline drops the working copy's changes to published items", function()
        local ws = loaded()
        local app = project(ws)
        assert.equals("ok", call("set_description", { item = { id = id_of(app) }, text = "Local" }).outcome)
        local r = call("revert_to_baseline")
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(project(srv.service.ws).description)
    end)

    describe("a working copy this machine did not sign", function()
        local user_path
        before_each(function()
            user_path = root .. "/.nvim/loomworks.user.json"
            -- Unsigned: written by hand.
            write(user_path, trust.encode(working_copy(root)))
        end)

        local function header()
            local h = call("header")
            return h
        end

        it("trust_accept confirms the review, then signs exactly what was shown and loads", function()
            pcall(loaded)
            assert.equals("refused", header().state)
            local r, e = call("trust_accept", {})
            assert.is_nil(e, vim.inspect(e))
            assert.equals("confirm", r.outcome, vim.inspect(r))
            assert.is_string(r.plan)
            assert.is_truthy(table.concat(r.lines, "\n"):find("Program settings", 1, true), vim.inspect(r.lines))
            r = call("trust_accept", { plan = r.plan })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.equals("valid", (trust.verify("user", read(user_path))))
            assert.equals("loaded", header().state)
        end)

        it("trust_accept refuses a plan when the working copy changed since it was shown", function()
            pcall(loaded)
            local r = call("trust_accept", {})
            assert.equals("confirm", r.outcome, vim.inspect(r))
            local data = working_copy(root)
            data.profiles.other = { configuration_set = "dev" }
            write(user_path, trust.encode(data))
            local r2 = call("trust_accept", { plan = r.plan })
            assert.equals("refused", r2.outcome, vim.inspect(r2))
            assert.equals("the working copy changed since it was shown — review it again", r2.message)
            assert.is_not.equals("valid", (trust.verify("user", read(user_path))))
            assert.equals("refused", header().state)
        end)

        it("delete_user_prefs confirms, then removes the working copy and loads", function()
            pcall(loaded)
            local r = call("delete_user_prefs", {})
            assert.equals("confirm", r.outcome, vim.inspect(r))
            assert.is_truthy(table.concat(r.lines, "\n"):lower():find(user_path:lower(), 1, true),
                vim.inspect(r.lines))
            assert.is_not_nil(read(user_path))
            r = call("delete_user_prefs", { plan = r.plan })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.is_nil(read(user_path))
            assert.equals("loaded", header().state)
        end)

        it("delete_user_prefs refuses a stale plan and keeps the file", function()
            pcall(loaded)
            local r = call("delete_user_prefs", {})
            write(user_path, read(user_path) .. "\n")
            local r2 = call("delete_user_prefs", { plan = r.plan })
            assert.equals("refused", r2.outcome, vim.inspect(r2))
            assert.is_not_nil(read(user_path))
        end)

        it("delete_user_prefs re-checks the plan under O: a change before the lock is refused", function()
            pcall(loaded)
            local r = call("delete_user_prefs", {})
            assert.equals("confirm", r.outcome, vim.inspect(r))
            -- Another process (the editor's save takes no O) rewrites the
            -- working copy after the plan was checked, before O is taken.
            local changed = read(user_path) .. "\n"
            local real_locks = op_lock.locks
            op_lock.locks = function(...)
                local l = real_locks(...)
                local op = setmetatable({}, { __index = l.op })
                op.acquire = function(...)
                    write(user_path, changed)
                    return l.op.acquire(...)
                end
                return setmetatable({ op = op }, { __index = l })
            end
            local ok_c, r2 = pcall(call, "delete_user_prefs", { plan = r.plan })
            op_lock.locks = real_locks
            assert.is_true(ok_c, tostring(r2))
            assert.equals("refused", r2.outcome, vim.inspect(r2))
            assert.equals("the working copy changed since it was shown — review it again", r2.message)
            assert.equals(changed, read(user_path))
            assert.is_nil(op_lock.read(root), "O left behind")
        end)

        it("delete_user_prefs refused while O is held names the holder", function()
            pcall(loaded)
            local r = call("delete_user_prefs", {})
            assert.equals("confirm", r.outcome, vim.inspect(r))
            local h = L.hold(op_lock.path(root), "import")
            local r2 = call("delete_user_prefs", { plan = r.plan })
            assert.equals("refused", r2.outcome, vim.inspect(r2))
            assert.matches("pid " .. h.pid, r2.message, 1, true)
            assert.is_not_nil(read(user_path))
        end)
    end)
end)
