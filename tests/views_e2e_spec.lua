-- The editor's views end to end (spec §19.13 "Views", "Two sources, one
-- shape"; step 5j): the daemon is the real lw of LOOMWORKS_LW
-- (tests/daemon_helpers.lua), its `/views` the real mount, and the editor
-- side is the real observer, connected through a real `--stdio` relay,
-- feeding loomworks.views. What `lw.buf_status` and `lw.buf_project` return
-- comes from the daemon's tables once the daemon loads the workspace on the
-- editor's attach; the editor holds no model (step 6b-alpha).

local observer = require("loomworks.daemon.observer")
local H = require("tests.daemon_helpers")

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("editor views from a real daemon /views (§19.13, step 5j)", function()
    local root, ws_root, obs, buf

    before_each(function()
        root = H.shell_workspace()
        -- The working copy with `dev` active, signed by lw for this editor's
        -- trust key: the daemon reports an active profile, its set and the
        -- project's active record.
        local user = { _meta = { version = 2 }, active_profile = "dev",
            profiles = { dev = { configuration_set = "dev" } } }
        local f = assert(io.open(root .. "/.nvim/loomworks.user.json", "wb"))
        f:write(H.signed_user(root, user)); f:close()
        -- Buffers are named under the resolved root (an 8.3 short temp path
        -- on a runner: the daemon's root is the realpath'd long one, and a
        -- path match is a plain prefix compare).
        ws_root = (vim.uv.fs_realpath(root):gsub("\\", "/"))
        buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, ws_root .. "/app/src/main.c")
    end)

    after_each(function()
        if obs then obs:stop() end
        observer.detach()
        obs = nil
        if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
        H.track_root(root)
        if H.daemon(root) then H.stop_daemon(root, H.editor_env()) end
        H.cleanup()
    end)

    local function attach()
        obs = observer.attach(root, { getenv = daemon_mode, keepalive_ms = 500,
            resolve = function() return "lw" end, relay = H.real_relay() })
        assert.is_not_nil(obs)
        assert.is_true(vim.wait(60000, function() return obs.state == "connected" end, 20), obs:runtime_line())
        H.track_root(root)
    end

    it("buf_status and buf_project read the daemon's views once it loads on attach", function()
        local lw = require("loomworks")
        local store = require("loomworks.views")

        attach()
        assert.is_true(vim.wait(30000, function()
            return store.source("header") == "daemon" and store.source("projects") == "daemon"
        end, 10), obs:runtime_line())

        -- The editor attaching makes the daemon load the workspace (§19.16
        -- "Loaded on attach"): the views follow by `update`, with no other
        -- client's request.
        assert.is_true(vim.wait(60000, function()
            local h = lw.view_header()
            return h and h.state == "loaded" and lw.buf_status(buf) ~= nil
        end, 20), vim.inspect(lw.view_header()))

        assert.equals("daemon", store.source("header"))
        assert.equals("daemon", store.source("projects"))
        local h = lw.view_header()
        assert.equals("dev", h.active_profile)
        assert.is_string(h.active_profile_id)
        assert.equals(H.daemon(root).pid, h.pid)

        -- buf_status adds the editor-local per-buffer LSP state (spec §9.8)
        -- on top of the views.
        assert.same({ profile_key = "dev", set_name = "dev", project = "app", configuration = "Debug",
            status = "unconfigured", profile_state = "unconfigured", lsp = lw.lsp_buf_state(buf) },
            lw.buf_status(buf))
        local rec = lw.buf_project(buf)
        assert.is_string(rec.id)
        assert.equals("app", rec.key)
        assert.equals("shell", rec.type)
        assert.equals("app", rec.path)
        assert.equals(store.normalize(ws_root .. "/app"), store.normalize(rec.abs_path))
        assert.equals("Debug", rec.active.configuration)
        assert.equals("unconfigured", rec.active.state)

        -- A buffer outside every project: nil.
        local other = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(other, ws_root .. "/appendix/x.c")
        assert.is_nil(lw.buf_status(other))
        assert.is_nil(lw.buf_project(other))
        vim.api.nvim_buf_delete(other, { force = true })
    end)

    it("the status page body reads the daemon's view.Workspace/1 (step 5n C1, 6b-alpha)", function()
        local store = require("loomworks.views")
        local source = require("loomworks.status_source")

        attach()
        -- Loaded on attach: the body follows by `update`.
        assert.is_true(vim.wait(60000, function()
            local v = obs:workspace_view()
            return v ~= nil and #v.profiles > 0
        end, 20), obs:runtime_line())
        assert.equals("daemon", store.source("workspace"))

        -- (No model in `daemon` mode, step 6b-alpha: the page passes none.)
        local body = source.read(nil)
        assert.equals("daemon", body.mode)
        assert.is_true(body.loaded)
        local prow = body.view.profiles[1]
        assert.equals("dev", prow.key)
        assert.is_string(prow.id)
        assert.equals("app", body.view.projects[1].key)
        -- No row reaches the editor's model (step 5o C2d-2).
        assert.is_nil(body.ref)
        assert.is_nil(prow.description)
    end)

    it("leaves no daemon running", function()
        assert.equals(0, H.survivors)
    end)
end)
