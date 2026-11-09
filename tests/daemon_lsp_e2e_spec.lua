-- The editor's LSP configuration end to end (step 5l part C; daemon.md
-- §19.16 "LSP configuration", §19.20 `LspConfig/1`): the daemon is the real
-- lw of LOOMWORKS_LW (tests/daemon_helpers.lua), so `/lsp` is the real mount,
-- and the editor side is the real observer (through a real `--stdio` relay)
-- feeding loomworks.lsp_source and loomworks.lsp. A build (configure, then
-- build) run in the daemon by an `lw build` reaches the editor's LSP layer as
-- a `changed` and a re-read: the entry turns `ready` and the integrations
-- re-evaluate. Whether the daemon has loaded is read from its
-- `view.Header/1` by a non-editor protocol session (H.session).

local observer = require("loomworks.daemon.observer")
local source = require("loomworks.lsp_source")
local lsp = require("loomworks.lsp")
local H = require("tests.daemon_helpers")

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("editor LSP configuration from a real daemon /lsp (§19.16, step 5l)", function()
    local root, env, obs, sess
    local hits

    before_each(function()
        root = H.shell_workspace()
        -- The working copy with `dev` active and a compile database declared
        -- (honored only from the working copy): the shell project's clangd
        -- entry (loomworks spec/modules/shell.md).
        local cfg = vim.json.decode(table.concat(vim.fn.readfile(root .. "/loomworks.json"), "\n"))
        cfg.projects.app.shell.compile_commands = "${build_dir}/compile_commands.json"
        local user = { _meta = { version = 2 }, active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } }, projects = { app = cfg.projects.app } }
        local f = assert(io.open(root .. "/.lw/user.json", "wb"))
        f:write(H.signed_user(root, user)); f:close()
        env = H.editor_env({ LOOMWORKS_RUNTIME = "daemon" })
        source._reset_changes()
        hits = { active = 0 }
        lsp.register("e2esrv", { on_active_set_changed = function() hits.active = hits.active + 1 end })
    end)

    after_each(function()
        lsp.register("e2esrv", {})
        if obs then obs:stop() end
        obs = nil
        observer.detach()
        if sess then sess:close() end
        sess = nil
        H.track_root(root, env)
        if H.daemon(root, env) then H.stop_daemon(root, env) end
        H.cleanup()
    end)

    local function attach_editor()
        obs = observer.attach(root, { getenv = daemon_mode, keepalive_ms = 500,
            resolve = function() return "lw" end, relay = H.real_relay() })
        assert.is_not_nil(obs)
        H.track_root(root, env)
    end

    --- The daemon's load state (`view.Header/1`), read by a CLI session.
    local function header_state()
        sess = sess or H.session(root)
        H.track_root(root, env)
        local h, err = H.call(sess, "/views", "loomworks.view.Header", 1, "get")
        assert.is_not_nil(h, vim.inspect(err))
        return h.state
    end

    --- `lw build dev` in the daemon (configure, then build).
    local function build()
        local r = H.lw({ "--no-input", "build", "dev" }, { env = env, cwd = root })
        assert.equals(0, r.code, r.stderr .. r.stdout)
    end

    it("an attaching editor makes the daemon load; a build in the daemon makes the entry ready", function()
        -- Nothing loaded before the editor attaches.
        assert.same({}, source.projects())
        assert.equals("unloaded", header_state())

        -- The editor attaching alone loads the workspace in the daemon
        -- (§19.16 "Loaded on attach"): in use, with no other request.
        attach_editor()
        assert.is_true(vim.wait(60000, function() return source.in_use() end, 20),
            tostring((source.daemon_phase())) .. " " .. obs:runtime_line())
        assert.equals("loaded", header_state())
        local rec = source.projects()[1]
        assert.equals("app", rec.project)
        assert.is_string(rec.id)
        assert.equals("unconfigured", rec.entries[1].db_state)
        -- The switch to the daemon's state re-evaluated as an active-set change.
        assert.is_true(vim.wait(5000, function() return hits.active >= 1 end, 10))
        local before = hits.active

        -- A build run in the daemon by another client: `changed`, a re-read, ready.
        build()
        assert.is_true(vim.wait(120000, function()
            local e = source.in_use() and source.projects()[1].entries[1]
            return e and e.db_state == "ready"
        end, 20), vim.inspect(source.projects()))
        assert.is_true(vim.wait(5000, function() return hits.active > before end, 10))
    end)

    it("an editor-only session reaches loaded and a ready entry with no other request", function()
        -- Built beforehand by a CLI client; that daemon then stops, and a
        -- fresh one starts unloaded.
        build()
        H.stop_daemon(root, env)
        assert.equals("unloaded", header_state())
        sess:close(); sess = nil

        -- Only the editor from here.
        attach_editor()
        assert.is_true(vim.wait(60000, function()
            local e = source.in_use() and source.projects()[1].entries[1]
            return e and e.db_state == "ready"
        end, 20), tostring((source.daemon_phase())) .. " " .. vim.inspect(source.projects()))
        assert.equals("loaded", header_state())
    end)

    -- GAP: a slow attach load (the editor's /lsp subscription and first `get`
    -- inside the load's model segment) needs the daemon's load delayed, which
    -- neither lw's CLI nor the protocol exposes. loomworks covers the
    -- daemon's side of it.
    pending("an editor that subscribes while the attach load still runs sees it loaded "
        .. "(GAP: no way to slow a real daemon's load from outside)")

    it("a CLI client does not make the daemon load", function()
        assert.equals("unloaded", header_state())
        vim.wait(500, function() return false end, 20)
        assert.equals("unloaded", header_state())
    end)

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
