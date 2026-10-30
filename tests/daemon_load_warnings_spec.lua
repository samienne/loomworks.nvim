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

--- A `snapshot` request (any request that uses the loaded workspace) over a
--- fresh CLI connection; its reply.
local function snapshot(srv)
    local conn = assert(client.session(srv.address, {}))
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
