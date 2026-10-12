-- The editor's LSP configuration end to end (step 5l part C; daemon.md
-- §19.16 "LSP configuration", §19.20 `LspConfig/1`): the daemon side is real
-- — an in-process server with the real build service
-- (cli._daemon_build_host, as views_e2e_spec does), so `/lsp` is the real
-- mount — and the editor side is the real observer subscription feeding
-- loomworks.lsp_source and loomworks.lsp. A configure run in the daemon
-- reaches the editor's LSP layer as a `changed` and a re-read: the entry
-- turns `ready` and the integrations re-evaluate, without the editor's own
-- model being asked.
--
-- One process holds both sides: the build host loads the daemon's model
-- into `require("loomworks")._core()`, so the editor is its own Core here,
-- and the LSP source reads it through its facade seam (`_facade`).

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local source = require("loomworks.lsp_source")
local lsp = require("loomworks.lsp")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("editor LSP configuration from a real daemon /lsp (§19.16, step 5l)", function()
    local root, srv, core, obs, sess
    local hits

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        -- The working copy with `dev` active and a compile database declared
        -- (honored only from the working copy): the shell project's clangd
        -- entry (spec/modules/shell.md).
        local cfg = vim.json.decode(table.concat(vim.fn.readfile(root .. "/loomworks.json"), "\n"))
        cfg.projects.app.shell.compile_commands = "${build_dir}/compile_commands.json"
        local user = { _meta = { version = 2 }, active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } }, projects = { app = cfg.projects.app } }
        local signed = trust.sign("user", trust.encode(user))
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(signed); f:close()
        core = Core.new()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        -- The LSP source reads the editor's model (the facade's Core is the
        -- daemon's here).
        source._facade = setmetatable({
            get_workspace = function() return core:get_workspace() end,
            get_projects = function() return core:get_projects() end,
            lsp_ready = function() return core:lsp_ready() end,
            get_lsp_options = function(s) return core:get_lsp_options(s) end,
        }, { __index = require("loomworks") })
        source._reset_changes()
        hits = { active = 0 }
        lsp.register("e2esrv", { on_active_set_changed = function() hits.active = hits.active + 1 end })
    end)

    after_each(function()
        lsp.register("e2esrv", {})
        if obs then obs:stop() end
        obs = nil
        if sess then sess:close() end
        sess = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        srv = nil
        source._facade = nil
        pcall(function() core:shutdown() end)
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("holds while the daemon is unloaded, then a configure in the daemon makes the entry ready", function()
        -- In-process first: the reference (the unit is not configured).
        local inproc = source.projects()
        assert.equals("app", inproc[1].project)
        assert.equals("clangd", inproc[1].entries[1].server)
        assert.equals("unconfigured", inproc[1].entries[1].db_state)

        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function() end })
        srv:registry()
        service.attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start())
        assert.is_not_nil(srv.interfaces:resolve("/lsp", "loomworks.LspConfig", 1))

        local fr = FR.new({})
        obs = observer.attach(core:get_workspace(), { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        -- The daemon has not loaded the workspace: the LSP layer holds.
        assert.is_true(vim.wait(10000, function() return (source.phase()) == "unloaded" end, 10),
            tostring((source.phase())) .. " " .. obs:runtime_line())
        assert.is_true(source.holding())
        assert.equals("pending", obs:lsp_db_owner())

        -- Another client's request loads it in the daemon: in use.
        sess = assert(client.session(srv.address))
        local env = require("loomworks.daemon.envscope").capture()
        local r, err = client.call_sync(sess, "/toolchains", "loomworks.Toolchains", 1, "list", {}, { env = env })
        assert.is_not_nil(r, err and err.message)
        assert.is_true(vim.wait(30000, function() return source.in_use() end, 20),
            tostring((source.phase())) .. " " .. vim.inspect(obs._lsp_read))
        local rec = source.projects()[1]
        assert.equals("app", rec.project)
        assert.is_string(rec.id)
        assert.equals("unconfigured", rec.entries[1].db_state)
        assert.equals("daemon", obs:lsp_db_owner())
        -- The switch to the daemon's state re-evaluated as an active-set change.
        assert.is_true(vim.wait(5000, function() return hits.active >= 1 end, 10))
        local before = hits.active

        -- A configure run in the daemon: `changed`, a re-read, ready.
        local res, cerr = client.call_sync(sess, "/build", "loomworks.Build", 1, "configure",
            { profile = { key = "dev" } }, { env = env })
        assert.is_not_nil(res, cerr and cerr.message)
        assert.is_true(vim.wait(120000, function()
            local e = source.in_use() and source.projects()[1].entries[1]
            return e and e.db_state == "ready"
        end, 20), vim.inspect(source.projects()))
        assert.is_true(vim.wait(5000, function() return hits.active > before end, 10))
        -- The editor's model generated nothing meanwhile.
        assert.is_false(core:get_workspace():generates_lsp_databases())
    end)
end)
