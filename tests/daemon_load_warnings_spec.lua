--- Load warnings reach daemon clients (spec/core/daemon.md §19.13 "Load
--- warnings", §19.15 "Roles and verbose"; headless §16.7): what a workspace
--- load raises is kept as persistent workspace diagnostics (`source = "load"`)
--- in the views, and every CLI request that uses the loaded workspace — the
--- one that loaded it and each later one on a warm daemon — carries them in
--- its reply notes with their roles. A load raises them only through the
--- host's notification seam (core `_deps.notify`), never `vim.notify`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local view_state = require("loomworks.view_state")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

--- A project whose declared directory does not exist (config.lua's
--- "directory not found" warning, formerly a direct `vim.notify`).
local function missing_dir_project(root)
    local f = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = vim.json.decode(f:read("*a")); f:close()
    local gone = vim.deepcopy(cfg.projects.app)
    gone.path = "gone"
    cfg.projects.gone = gone
    f = assert(io.open(root .. "/loomworks.json", "wb")); f:write(vim.json.encode(cfg)); f:close()
end

--- Rewrite loomworks.json through `fn(cfg)`.
local function edit_config(root, fn)
    local f = assert(io.open(root .. "/loomworks.json", "rb"))
    local cfg = vim.json.decode(f:read("*a")); f:close()
    fn(cfg)
    f = assert(io.open(root .. "/loomworks.json", "wb")); f:write(vim.json.encode(cfg)); f:close()
end

--- Rewrite the working copy (`.nvim/loomworks.user.json`) through `fn(user)`,
--- signed by this machine.
local function edit_user(root, fn)
    local path = root .. "/.nvim/loomworks.user.json"
    local f = assert(io.open(path, "rb"))
    local status, body = trust.verify("user", f:read("*a")); f:close()
    assert.equals("valid", status)
    local user = vim.json.decode(body)
    fn(user)
    local signed, serr = trust.sign("user", trust.encode(user))
    if not signed then error(serr) end
    f = assert(io.open(path, "wb")); f:write(signed); f:close()
end

--- How many of the view's diagnostics mention `needle`.
local function view_count(ws, needle)
    local n = 0
    for _, d in ipairs(view_state.workspace(ws).diagnostics) do
        if d.message:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

--- A `snapshot` request (any request that uses the loaded workspace) over a
--- fresh CLI connection; its reply.
local function snapshot(srv, hello)
    local conn = assert(client.session(srv.address, hello or {}))
    local reply
    conn:request({ kind = "snapshot", scope = "all", env = envscope.capture() },
        function(r, e) reply = r or { error = e } end)
    vim.wait(60000, function() return reply ~= nil end, 10)
    pcall(conn.close, conn)
    return reply
end

--- The reply note whose text contains `needle`, and its role.
local function find_note(reply, needle)
    for i, n in ipairs(reply.notes or {}) do
        if n:find(needle, 1, true) then return n, (reply.note_roles or {})[i] end
    end
end

describe("load warnings reach daemon clients (§19.13 Load warnings)", function()
    local root, srv, svc
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        missing_dir_project(root)
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        svc = service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("the loading request's notes carry a load warning raised by the config parser, painted warn", function()
        local r = snapshot(srv)
        assert.equals("ok", r.outcome)
        local n, role = find_note(r, "directory not found")
        assert.is_not_nil(n, "no load warning in the notes: " .. vim.inspect(r.notes))
        assert.equals("warn", role)
    end)

    it("a warm daemon: a later request carries the same load warnings with their roles", function()
        local first = snapshot(srv)
        assert.equals("ok", first.outcome)
        local second = snapshot(srv)
        assert.equals("ok", second.outcome)
        local n, role = find_note(second, "directory not found")
        assert.is_not_nil(n, "the warm daemon's reply lost the load warning: " .. vim.inspect(second.notes))
        assert.equals("warn", role)
        -- Once, not once per request that ever used the workspace.
        local count = 0
        for _, t in ipairs(second.notes or {}) do
            if t:find("directory not found", 1, true) then count = count + 1 end
        end
        assert.equals(1, count)
    end)

    it("the views carry them as persistent workspace diagnostics (source load); the header counts them", function()
        assert.equals("ok", snapshot(srv).outcome)
        local ws = svc.ws
        assert.is_not_nil(ws)
        local v = view_state.workspace(ws)
        local found
        for _, d in ipairs(v.diagnostics) do
            if d.source == "load" and d.message:find("directory not found", 1, true) then found = d end
        end
        assert.is_not_nil(found, vim.inspect(v.diagnostics))
        assert.equals("warn", found.severity)
        -- The message is the warning's text without the notification prefix.
        assert.is_nil(found.message:find("^loomworks: "))
        assert.is_not_nil(view_state.header(ws).diagnostics)
    end)

    it("an edit that fixes the warning clears it: the views and a warm daemon's later request", function()
        assert.is_not_nil((find_note(snapshot(srv), "directory not found")))
        edit_config(root, function(cfg) cfg.projects.gone = nil end)
        svc.ws._tracker:sync()
        local r = snapshot(srv)
        assert.equals("ok", r.outcome)
        assert.is_nil((find_note(r, "directory not found")), vim.inspect(r.notes))
        assert.equals(0, view_count(svc.ws, "directory not found"))
    end)

    it("an edit that introduces a warning carries it: the views and a warm daemon's later request", function()
        edit_config(root, function(cfg) cfg.projects.gone = nil end)
        local first = snapshot(srv)
        assert.is_nil((find_note(first, "directory not found")), vim.inspect(first.notes))
        missing_dir_project(root)
        svc.ws._tracker:sync()
        local r = snapshot(srv)
        local n, role = find_note(r, "directory not found")
        assert.is_not_nil(n, vim.inspect(r.notes))
        assert.equals("warn", role)
        assert.equals(1, view_count(svc.ws, "directory not found"))
    end)

    -- A re-assembly after an edit to user.json is a load too (§19.13).
    local STALE = "references unknown configuration"

    it("a user.json edit that fixes a stale mapping clears it: the views and a warm daemon's later request", function()
        edit_user(root, function(u) u.configuration_sets = { bad = { app = "Nope" } } end)
        assert.is_not_nil((find_note(snapshot(srv), STALE)))
        edit_user(root, function(u) u.configuration_sets = nil end)
        svc.ws._tracker:sync()
        local r = snapshot(srv)
        assert.equals("ok", r.outcome)
        assert.is_nil((find_note(r, STALE)), vim.inspect(r.notes))
        assert.equals(0, view_count(svc.ws, "Nope"))
        -- The load's other warnings are carried again, not dropped.
        assert.is_not_nil((find_note(r, "directory not found")), vim.inspect(r.notes))
    end)

    it("a user.json edit that introduces a stale mapping carries it: the views and a warm daemon's later request", function()
        local first = snapshot(srv)
        assert.is_nil((find_note(first, STALE)), vim.inspect(first.notes))
        edit_user(root, function(u) u.configuration_sets = { bad = { app = "Nope" } } end)
        svc.ws._tracker:sync()
        local r = snapshot(srv)
        local n, role = find_note(r, STALE)
        assert.is_not_nil(n, vim.inspect(r.notes))
        assert.equals("warn", role)
        assert.equals(1, view_count(svc.ws, "Nope"))
    end)

    it("a stale mapping removed and then reintroduced by user.json edits is reported again", function()
        assert.equals("ok", snapshot(srv).outcome)
        local core = svc.ws._core
        local host, seen = core._deps.notify, 0
        core._deps.notify = function(msg, level, opts)
            if tostring(msg):find(STALE, 1, true) then seen = seen + 1 end
            return host(msg, level, opts)
        end
        edit_user(root, function(u) u.configuration_sets = { bad = { app = "Nope" } } end)
        svc.ws._tracker:sync()
        edit_user(root, function(u) u.configuration_sets = nil end)
        svc.ws._tracker:sync()
        seen = 0
        edit_user(root, function(u) u.configuration_sets = { bad = { app = "Nope" } } end)
        svc.ws._tracker:sync()
        assert.equals(1, seen, "the reintroduced mapping was not reported")
        local r = snapshot(srv)
        assert.is_not_nil((find_note(r, STALE)), vim.inspect(r.notes))
    end)

    it("a daemon reload keeps the load warnings (once-per-process guards reset per load)", function()
        edit_config(root, function(cfg) cfg.configuration_sets.bad = { app = "Nope" } end)
        local first = snapshot(srv)
        assert.is_not_nil((find_note(first, "references unknown configuration")), vim.inspect(first.notes))
        svc:_unload()
        local r = snapshot(srv)
        assert.equals("ok", r.outcome)
        assert.is_not_nil((find_note(r, "references unknown configuration")), vim.inspect(r.notes))
        assert.is_not_nil((find_note(r, "directory not found")), vim.inspect(r.notes))
    end)

    it("a stale mapping is listed once in the views (the structural diagnostic), still a CLI note", function()
        edit_config(root, function(cfg) cfg.configuration_sets.bad = { app = "Nope" } end)
        local r = snapshot(srv)
        assert.is_not_nil((find_note(r, "references unknown configuration")), vim.inspect(r.notes))
        assert.equals(1, view_count(svc.ws, "Nope"), vim.inspect(view_state.workspace(svc.ws).diagnostics))
    end)

    it("an editor's request that loads the workspace carries no load warning; a later CLI request does", function()
        -- (A cold load for a request that may write — an editor's command.)
        local ctx = { env = envscope.capture(), notes = {}, note_roles = {},
            conn = { observer = true } }
        svc.current = ctx
        local ws = svc:live(ctx)
        svc.current = nil
        assert.is_not_nil(ws)
        assert.equals(0, #ctx.notes, vim.inspect(ctx.notes))
        assert.equals(1, view_count(svc.ws, "directory not found"))
        -- An editor's read-only request on a cold daemon.
        svc:_unload()
        local r = snapshot(srv, { client = "editor", role = "observer" })
        assert.equals("ok", r.outcome)
        assert.is_nil((find_note(r, "directory not found")), vim.inspect(r.notes))
        local cli_r = snapshot(srv)
        assert.is_not_nil((find_note(cli_r, "directory not found")), vim.inspect(cli_r.notes))
    end)

    it("an editor's request whose sync re-assembles the workspace carries no load warning", function()
        assert.equals("ok", snapshot(srv).outcome)
        edit_config(root, function(cfg) cfg.projects.gone2 = vim.deepcopy(cfg.projects.gone); cfg.projects.gone2.path = "gone2" end)
        local ctx = { env = envscope.capture(), notes = {}, note_roles = {},
            conn = { observer = true } }
        svc.current = ctx
        local ws = svc:live(ctx)
        svc.current = nil
        assert.is_not_nil(ws)
        assert.equals(0, #ctx.notes, vim.inspect(ctx.notes))
        assert.equals(2, view_count(svc.ws, "directory not found"))
    end)
end)

describe("once-per-load plugin rejections (§19.13 Load warnings)", function()
    local dir, saved
    before_each(function()
        dir = H.tmp()
        vim.fn.mkdir(dir .. "/lua/loomworks/modules", "p")
        vim.fn.mkdir(dir .. "/lua/loomworks/sdks", "p")
        local f = assert(io.open(dir .. "/lua/loomworks/modules/lwbadmod.lua", "wb"))
        f:write("return { id = 'lwbadmod', api_version = 999 }"); f:close()
        f = assert(io.open(dir .. "/lua/loomworks/sdks/lwbadsdk.lua", "wb"))
        f:write("return { id = 'lwbadsdk', api_version = 999 }"); f:close()
        vim.opt.rtp:append(dir)
        saved = require("loomworks")._core()._deps.notify
    end)
    after_each(function()
        require("loomworks")._core()._deps.notify = saved
        vim.opt.rtp:remove(dir)
    end)

    for _, case in ipairs({ { "modules", "lwbadmod" }, { "sdks", "lwbadsdk" } }) do
        it(case[1] .. ": a rejection is reported once per load, again on the next load", function()
            local seen = {}
            require("loomworks")._core()._deps.notify = function(msg) seen[#seen + 1] = msg end
            local reg = require("loomworks." .. case[1])
            require("loomworks.notify").new_load()
            assert.is_nil(reg.get(case[2]))
            assert.is_nil(reg.get(case[2]))
            assert.equals(1, #seen, vim.inspect(seen))
            require("loomworks.notify").new_load()
            assert.is_nil(reg.get(case[2]))
            assert.equals(2, #seen, vim.inspect(seen))
            assert.equals(seen[1], seen[2])
        end)
    end
end)

describe("the notification seam (§16.7 Highlighting)", function()
    it("a load warning of the config parser goes through the host's core notify, not vim.notify", function()
        local core = require("loomworks")._core()
        local saved, saved_vim = core._deps.notify, vim.notify
        local seen, direct = {}, {}
        core._deps.notify = function(msg, level) seen[#seen + 1] = { msg, level } end
        vim.notify = function(msg) direct[#direct + 1] = msg end
        local ok, err = pcall(function()
            require("loomworks.config").validate({ projects = { gone = { path = "gone",
                shell = { build_cmd = { "x" }, build_dir = "out" } } } }, H.tmp())
        end)
        core._deps.notify, vim.notify = saved, saved_vim
        assert(ok, err)
        assert.equals(0, #direct, vim.inspect(direct))
        assert.equals(1, #seen)
        assert.is_not_nil(seen[1][1]:find("directory not found", 1, true))
        assert.equals(vim.log.levels.WARN, seen[1][2])
    end)
end)
