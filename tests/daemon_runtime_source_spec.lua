-- The editor's runtime-mode selection and its Runtime line (spec §19.1,
-- §19.16, spec/ui.md §1.1): environment > setup option > lw's `runtime-mode`
-- setting (read from lw's settings file, never written) > in-process; the
-- source on the status page's Runtime line, the header's last line; the
-- version-mismatch note.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local runtime = require("loomworks.daemon.runtime")
local observer = require("loomworks.daemon.observer")
local binary_select = require("loomworks.provision.select")
local version = require("loomworks.daemon.version")
local H = require("tests.daemon_helpers")

local function env_of(t) return function(n) return t[n] end end

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

describe("editor runtime-mode selection (§19.1)", function()
    local function sel(env, configured, content)
        return runtime.editor_select({ getenv = env_of(env or {}), configured = configured,
            settings_file = settings_file(content) })
    end

    it("defaults to in-process when nothing selects (missing file, missing key)", function()
        local s = sel({}, nil, nil)
        assert.same({ "in-process", "default", false }, { s.mode, s.source, s.daemon })
        assert.is_nil(s.warning)
        s = sel({}, nil, '{"channel":"stable"}')
        assert.same({ "in-process", "default" }, { s.mode, s.source })
        assert.is_nil(s.warning)
    end)

    it("takes lw's setting, then the setup option over it, then the environment over both", function()
        local s = sel({}, nil, '{"runtime-mode":"daemon"}')
        assert.same({ "daemon", "lw setting", true }, { s.mode, s.source, s.daemon })
        s = sel({}, "in-process", '{"runtime-mode":"daemon"}')
        assert.same({ "in-process", "setup" }, { s.mode, s.source })
        s = sel({ LOOMWORKS_RUNTIME = "daemon" }, "in-process", '{"runtime-mode":"in-process"}')
        assert.same({ "daemon", "env" }, { s.mode, s.source })
    end)

    it("no-daemon in lw's setting selects in-process", function()
        local s = sel({}, nil, '{"runtime-mode":"no-daemon"}')
        assert.same({ "in-process", "lw setting", false }, { s.mode, s.source, s.daemon })
    end)

    it("LOOMWORKS_NO_DAEMON=1 and CI turn daemon into in-process (env); LOOMWORKS_NO_DAEMON=0 keeps it in CI", function()
        local s = sel({ LOOMWORKS_NO_DAEMON = "1" }, "daemon")
        assert.same({ "in-process", "env", "LOOMWORKS_NO_DAEMON=1" }, { s.mode, s.source, s.reason })
        s = sel({ CI = "true" }, nil, '{"runtime-mode":"daemon"}')
        assert.same({ "in-process", "env", "CI" }, { s.mode, s.source, s.reason })
        s = sel({ CI = "true", LOOMWORKS_NO_DAEMON = "0" }, "daemon")
        assert.same({ "daemon", "setup" }, { s.mode, s.source })
    end)

    it("an invalid setting or an unreadable file is a note and falls through to the default", function()
        local s = sel({}, nil, '{"runtime-mode":"fast"}')
        assert.same({ "in-process", "default" }, { s.mode, s.source })
        assert.truthy(s.warning:find("runtime-mode 'fast'", 1, true), s.warning)
        s = sel({}, nil, "{ not json")
        assert.same({ "in-process", "default" }, { s.mode, s.source })
        assert.truthy(s.warning:find("is not a JSON object", 1, true), s.warning)
        -- An invalid setup value is skipped for lw's setting.
        s = sel({}, "auto", '{"runtime-mode":"daemon"}')
        assert.same({ "daemon", "lw setting" }, { s.mode, s.source })
        assert.truthy(s.warning:find("runtime.mode 'auto'", 1, true), s.warning)
    end)

    it("reads the file on every call and never writes it", function()
        local uv = vim.uv or vim.loop
        local path = settings_file('{"runtime-mode":"daemon"}')
        local st0 = assert(uv.fs_stat(path))
        -- The read path (selection, twice) leaves the file as it was.
        for _ = 1, 2 do
            local s = runtime.editor_select({ getenv = env_of({}), settings_file = path })
            assert.same({ "daemon", "lw setting" }, { s.mode, s.source })
        end
        local st1 = assert(uv.fs_stat(path))
        assert.same({ '{"runtime-mode":"daemon"}' }, vim.fn.readfile(path))
        assert.same({ st0.mtime.sec, st0.mtime.nsec, st0.size }, { st1.mtime.sec, st1.mtime.nsec, st1.size })
        -- Absent: selection does not create it.
        local missing = settings_file(nil)
        assert.equals("default", runtime.editor_select({ getenv = env_of({}), settings_file = missing }).source)
        assert.is_nil(uv.fs_stat(missing))
        -- Read on every call: a change by lw is seen by the next selection.
        local f = assert(io.open(path, "w")); f:write('{"runtime-mode":"in-process"}'); f:close()
        local s = runtime.editor_select({ getenv = env_of({}), settings_file = path })
        assert.same({ "in-process", "lw setting" }, { s.mode, s.source })
    end)

    it("a directory at the settings path is unreadable (a note), not absent", function()
        local path = settings_file(nil)
        vim.fn.mkdir(path, "p")
        local v, err = runtime.read_setting(path)
        assert.is_nil(v)
        assert.truthy(err and err:find("cannot read lw's settings file", 1, true), err)
        local s = runtime.editor_select({ getenv = env_of({}), settings_file = path })
        assert.same({ "in-process", "default" }, { s.mode, s.source })
        assert.truthy(s.warning and s.warning:find("cannot read lw's settings file", 1, true), s.warning)
    end)

    it("bad JSON or a non-object is a note; empty or a missing key is absent", function()
        local v, err = runtime.read_setting(settings_file("{ not json"))
        assert.is_nil(v)
        assert.truthy(err and err:find("is not a JSON object", 1, true), err)
        v, err = runtime.read_setting(settings_file('"daemon"'))
        assert.is_nil(v)
        assert.truthy(err and err:find("is not a JSON object", 1, true), err)
        assert.same({}, { runtime.read_setting(settings_file("  \n")) })
        assert.same({}, { runtime.read_setting(settings_file("{}")) })
        assert.same({}, { runtime.read_setting(settings_file(nil)) })
    end)

    it("the default settings file is lw's own (boot.paths.config_file)", function()
        local seen
        runtime.editor_select({ getenv = env_of({}), read_setting = function(p)
            seen = p or require("boot.paths").config_file()
            return nil
        end })
        assert.equals(require("boot.paths").config_file(), seen)
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
        obs = nil
        pcall(function() core:shutdown() end)
    end)

    local function attach(env, content)
        return observer.attach(ws, { getenv = env_of(env), settings_file = settings_file(content),
            keepalive_ms = 100, resolve = function() return nil end })
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

    it("is hidden when the default picked in-process", function()
        assert.is_nil(attach({}, nil))
        assert.is_nil((observer.runtime_line(ws)))
        local _, i = header()
        assert.is_nil(i)
    end)

    it("names the source of an in-process selection", function()
        assert.is_nil(attach({}, '{"runtime-mode":"in-process"}'))
        assert.equals("in-process (lw setting)", (observer.runtime_line(ws)))
        assert.is_nil(attach({ CI = "1", LOOMWORKS_RUNTIME = "daemon" }, nil))
        assert.equals("in-process (env) — CI", (observer.runtime_line(ws)))
    end)

    it("shows an ignored setting in the warning highlight", function()
        assert.is_nil(attach({}, '{"runtime-mode":"fast"}'))
        local text, warn = observer.runtime_line(ws)
        assert.truthy(text:find("^in%-process %(default%) — "), text)
        assert.is_true(warn)
    end)

    it("is the header's last line, with mode, source and the observer's note", function()
        obs = attach({}, '{"runtime-mode":"daemon"}')
        assert.is_not_nil(obs)
        assert.equals("no-binary", obs.state)
        local lines, i, hl = header()
        assert.is_not_nil(i, table.concat(lines, "\n"))
        assert.truthy(lines[i]:find("Runtime:   daemon (lw setting) — " .. binary_select.NONE_NOTE, 1, true), lines[i])
        assert.equals("DiagnosticWarn", hl)
        assert.truthy(lines[i - 1]:find("[?] help", 1, true), lines[i - 1])
        assert.equals("", vim.trim(lines[i + 1]))
    end)

    it("the version-mismatch note names both sides, the binary and the remedy", function()
        local note = observer.mismatch_note({ protocol = version.PROTOCOL + 1, lw_version = "0.1.44" }, "protocol",
            "/opt/lw")
        assert.truthy(note:find("lw v0.1.44 at /opt/lw (protocol " .. (version.PROTOCOL + 1) .. ")", 1, true), note)
        assert.truthy(note:find("this plugin (v" .. version.identity() .. ", protocol " .. version.PROTOCOL .. ")",
            1, true), note)
        assert.truthy(note:find("update the plugin, or pin or install a matching lw", 1, true), note)
        assert.truthy(note:find("running in-process", 1, true), note)
        local s = version.schemas()
        note = observer.mismatch_note({ protocol = version.PROTOCOL, lw_version = "9.0.0",
            schemas = { user = s.user + 1, cache = s.cache } }, "schemas")
        assert.truthy(note:find("file formats user " .. (s.user + 1), 1, true), note)
        assert.truthy(note:find("file formats user " .. s.user .. ", cache " .. s.cache, 1, true), note)
    end)
end)
