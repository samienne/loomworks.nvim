-- The editor's runtime-mode selection and its Runtime line (spec §19.1,
-- §19.16, spec/ui.md §1.1; step 5s): `daemon` by default, the setup option
-- `runtime.mode = "in-process"` the deprecated in-process editor — never the
-- environment or lw's `runtime-mode` setting; the source on the status
-- page's Runtime line, the header's last line; the version-mismatch note.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local runtime = require("loomworks.daemon.runtime")
local observer = require("loomworks.daemon.observer")
local binary_select = require("loomworks.provision.select")
local version = require("loomworks.daemon.version")
local H = require("tests.daemon_helpers")

local function settings_file(content)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/config.json"
    if content then
        local f = assert(io.open(path, "w"))
        f:write(content)
        f:close()
    end
    return path
end

describe("editor runtime-mode selection (§19.1, step 5s)", function()
    local function sel(configured) return runtime.editor_select({ configured = configured }) end

    it("defaults to daemon", function()
        local s = sel(nil)
        assert.same({ "daemon", "default", true }, { s.mode, s.source, s.daemon })
        assert.is_nil(s.warning)
        assert.is_nil(s.deprecated)
    end)

    it("an explicit daemon is the setup's; in-process selects the deprecated in-process editor", function()
        local s = sel("daemon")
        assert.same({ "daemon", "setup", true }, { s.mode, s.source, s.daemon })
        assert.is_nil(s.deprecated)
        s = sel("in-process")
        assert.same({ "in-process", "setup", false, true }, { s.mode, s.source, s.daemon, s.deprecated })
    end)

    it("never reads LOOMWORKS_RUNTIME, LOOMWORKS_NO_DAEMON, CI or lw's runtime-mode setting", function()
        local saved = {}
        for _, n in ipairs({ "LOOMWORKS_RUNTIME", "LOOMWORKS_NO_DAEMON", "CI" }) do saved[n] = vim.env[n] end
        vim.env.LOOMWORKS_RUNTIME, vim.env.LOOMWORKS_NO_DAEMON, vim.env.CI = "in-process", "1", "true"
        local path = settings_file('{"runtime-mode":"no-daemon"}')
        local ok, s = pcall(runtime.editor_select, { settings_file = path })
        for n, v in pairs(saved) do vim.env[n] = v end
        for _, n in ipairs({ "LOOMWORKS_RUNTIME", "LOOMWORKS_NO_DAEMON", "CI" }) do
            if saved[n] == nil then vim.env[n] = nil end
        end
        assert.is_true(ok, s)
        assert.same({ "daemon", "default", true }, { s.mode, s.source, s.daemon })
        assert.is_nil(s.warning)
    end)

    it("an invalid setup value is a note and falls through to the default", function()
        local s = sel("auto")
        assert.same({ "daemon", "default" }, { s.mode, s.source })
        assert.truthy(s.warning:find("runtime.mode 'auto'", 1, true), s.warning)
    end)
end)

describe("the Runtime line (spec/ui.md §1.1)", function()
    local root, core, ws, obs

    before_each(function()
        root = H.shell_workspace({ profile = true })
        core = require("loomworks")._core()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
    end)
    after_each(function()
        if obs then obs:stop() end
        observer.detach()
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    local function attach(configured)
        return observer.attach(ws.root, { configured = configured, keepalive_ms = 100,
            resolve = function() return nil end })
    end

    local function header()
        local Tree = require("loomworks.ui.tree")
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        local lines, hls = tree:render()
        for i, l in ipairs(lines) do
            if l:find("Runtime:", 1, true) then
                local hl
                for _, h in ipairs(hls) do if h.line == i then hl = h.hl_group end end
                return lines, i, hl
            end
        end
        return lines, nil
    end

    it("the deprecated in-process editor says so", function()
        assert.is_nil(attach("in-process"))
        assert.equals("in-process (setup) — deprecated: the in-process editor will be removed",
            (observer.runtime_line(ws)))
        local lines, i = header()
        assert.is_not_nil(i, table.concat(lines, "\n"))
        assert.truthy(lines[i]:find("Runtime:   in-process (setup) — deprecated: the in-process editor will be removed",
            1, true), lines[i])
    end)

    it("shows an ignored setup value in the warning highlight", function()
        obs = attach("fast")
        local text, warn = observer.runtime_line(ws)
        assert.truthy(text:find("^daemon %(default%) — "), text)
        assert.truthy(text:find("runtime.mode 'fast'", 1, true), text)
        assert.is_true(warn)
    end)

    it("is the header's last line, with mode, source and the observer's note", function()
        obs = attach(nil)
        assert.is_not_nil(obs)
        assert.equals("no-binary", obs.state)
        local lines, i, hl = header()
        assert.is_not_nil(i, table.concat(lines, "\n"))
        assert.truthy(lines[i]:find("Runtime:   daemon (default) — " .. binary_select.NONE_NOTE, 1, true), lines[i])
        assert.equals("DiagnosticWarn", hl)
        assert.truthy(lines[i - 1]:find("[?] help", 1, true), lines[i - 1])
        assert.equals("", vim.trim(lines[i + 1]))
        obs:stop()
        obs = attach("daemon")
        assert.truthy(observer.runtime_line(ws):find("^daemon %(setup%) — "), (observer.runtime_line(ws)))
    end)

    it("the version-mismatch note names both sides, the binary and the remedy", function()
        local note = observer.mismatch_note({ protocol = version.PROTOCOL + 1, lw_version = "0.1.44" }, "protocol",
            "/opt/lw")
        assert.truthy(note:find("lw v0.1.44 at /opt/lw (protocol " .. (version.PROTOCOL + 1) .. ")", 1, true), note)
        assert.truthy(note:find("this plugin (v" .. version.identity() .. ", protocol " .. version.PROTOCOL .. ")",
            1, true), note)
        assert.truthy(note:find("update the plugin, or pin or install a matching lw", 1, true), note)
        assert.truthy(note:find("running degraded", 1, true), note)
        local s = version.schemas()
        note = observer.mismatch_note({ protocol = version.PROTOCOL, lw_version = "9.0.0",
            schemas = { user = s.user + 1, cache = s.cache } }, "schemas")
        assert.truthy(note:find("file formats user " .. (s.user + 1), 1, true), note)
        assert.truthy(note:find("file formats user " .. s.user .. ", cache " .. s.cache, 1, true), note)
    end)

    it("the header reads view.Header/1: in-process, then the daemon's as it is (step 5j)", function()
        local store = require("loomworks.views")
        local lines = header()
        local function text() return table.concat(lines, "\n") end
        local function has(s)
            for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end
            return false
        end
        assert.truthy(has("Workspace: " .. ws.name), text())
        -- A daemon that has not loaded the workspace yet.
        local owner = {}
        store.set(owner, "header", { root = root, state = "unloaded", pid = 1, lw_version = "x",
            session_generation = 1 })
        lines = header()
        store.clear(owner)
        assert.truthy(has("Workspace: not loaded in the workspace daemon"), text())
        assert.truthy(has("Root:      " .. root), text())
    end)
end)
