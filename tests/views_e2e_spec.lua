-- The editor's views end to end (spec §19.13 "Views", "Two sources, one
-- shape"; step 5j): the daemon side is real — an in-process server with the
-- real build service (cli._daemon_build_host, as the conformance specs use),
-- so `/views` is the real mount (loomworks.daemon.views over
-- loomworks.view_state) — and the editor side is the real observer
-- subscription feeding loomworks.views. What `lw.buf_status` and
-- `lw.buf_project` return comes from the daemon's tables once the daemon
-- loads the workspace, and equals what the in-process views give.
--
-- One process holds both sides, so the editor is its own Core here: the
-- build host loads the daemon's model into `require("loomworks")._core()`,
-- and a load there would replace (and tear down, with its observer) an
-- editor workspace living in the same Core.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("editor views from a real daemon /views (§19.13, step 5j)", function()
    local root, ws_root, srv, core, obs, sess, buf

    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true })
        -- The working copy with `dev` active: both sides then report an
        -- active profile, its set and the project's active record.
        local user = { _meta = { version = 2 }, active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } } }
        local signed = trust.sign("user", trust.encode(user))
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(signed); f:close()
        core = Core.new()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        -- Buffers are named under the workspace's resolved root: on a runner
        -- whose temp dir is an 8.3 short path (C:/Users/RUNNER~1/...),
        -- `root` is that short form while the workspace root (and so every
        -- `abs_path`) is the realpath'd long one, and a path match is a plain
        -- prefix compare.
        ws_root = core:get_workspace().root
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, ws_root .. "/app/src/main.c")
    end)

    after_each(function()
        if obs then obs:stop() end
        obs = nil
        if sess then sess:close() end
        sess = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        srv = nil
        if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
        pcall(function() core:shutdown() end)
        -- The model the daemon loaded (the build host's Core).
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    it("buf_status and buf_project read the daemon's views after it loads, equal to the in-process ones", function()
        local lw = require("loomworks")
        local store = require("loomworks.views")

        -- In-process first: the reference the daemon's views must match.
        -- (The store's in-process builders are init.lua's, over the build
        -- host's Core: the editor Core's views are read directly here.)
        local function in_process_status(b)
            return store.status_of(core:view_header(), core:view_projects_index(), vim.api.nvim_buf_get_name(b))
        end
        local want_status = in_process_status(buf)
        assert.same({ profile_key = "dev", set_name = "dev", project = "app", configuration = "Debug",
            status = "unconfigured", profile_state = "unconfigured" }, want_status)
        local want_rec = store.match(core:view_projects_index(), vim.api.nvim_buf_get_name(buf))
        assert.equals("app", want_rec.key)
        assert.is_nil(want_rec.id)

        -- The real daemon side: server + build service, /views mounted by it.
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function() end })
        srv:registry()
        service.attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start())
        assert.is_not_nil(srv.interfaces:resolve("/views", "loomworks.view.Header", 1))

        local fr = FR.new({})
        obs = observer.attach(core:get_workspace(), { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(10000, function()
            return store.source("header") == "daemon" and store.source("projects") == "daemon"
        end, 10), obs:runtime_line())

        -- Shown literally: the daemon has not loaded the workspace yet.
        assert.equals("unloaded", lw.view_header().state)
        assert.is_nil(lw.buf_status(buf))
        assert.is_nil(lw.buf_project(buf))

        -- Another client's request loads it in the daemon; the views follow
        -- by `update`.
        sess = assert(client.session(srv.address))
        local env = require("loomworks.daemon.envscope").capture()
        local r, err = client.call_sync(sess, "/toolchains", "loomworks.Toolchains", 1, "list", {}, { env = env })
        assert.is_not_nil(r, err and err.message)
        assert.is_true(vim.wait(30000, function()
            local h = lw.view_header()
            return h and h.state == "loaded" and lw.buf_status(buf) ~= nil
        end, 20), vim.inspect(lw.view_header()))

        assert.equals("daemon", store.source("header"))
        assert.equals("daemon", store.source("projects"))
        local h = lw.view_header()
        assert.equals("dev", h.active_profile)
        assert.is_string(h.active_profile_id)
        assert.equals(srv.pid, h.pid)

        -- The same answers as in-process, from the daemon's tables.
        -- buf_status adds the editor-local per-buffer LSP state (spec §9.8) on
        -- top of the views, in both sources.
        assert.same(vim.tbl_extend("force", want_status, { lsp = lw.lsp_buf_state(buf) }), lw.buf_status(buf))
        local rec = lw.buf_project(buf)
        assert.is_string(rec.id)
        assert.equals("app", rec.key)
        assert.equals("shell", rec.type)
        assert.equals(want_rec.path, rec.path)
        assert.equals(store.normalize(want_rec.abs_path), store.normalize(rec.abs_path))
        assert.equals("Debug", rec.active.configuration)
        assert.equals("unconfigured", rec.active.state)

        -- A buffer outside every project: nil from both.
        local other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(other, ws_root .. "/appendix/x.c")
        assert.is_nil(lw.buf_status(other))
        assert.is_nil(lw.buf_project(other))
        vim.api.nvim_buf_delete(other, { force = true })
    end)
end)
