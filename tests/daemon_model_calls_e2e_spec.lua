-- The status page's Workspace/1, Profiles/1, ConfigSets/1 and Projects/1
-- writes through a real daemon (step 5o parts C2a, C2b; daemon.md §19.16
-- "Model writes", API.md §6, §11, §19, §20): the daemon side is real — an in-process server with the
-- real build service (cli._daemon_build_host) on the conformance runner's
-- `shell` fixture — and the editor side is the real observer and
-- loomworks.ui.model_calls. A call names its entity by the id of the
-- `view.Workspace/1` row it was taken on; the page follows the view's
-- `update`; a refusal (a stale id, the daemon unreachable) is the outcome,
-- shown, and never run in-process instead.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local observer = require("loomworks.daemon.observer")
local trust = require("loomworks.trust")
local Core = require("loomworks.core")
local views = require("loomworks.views")
local model = require("loomworks.ui.model_calls")
local status_source = require("loomworks.status_source")
local H = require("tests.daemon_helpers")
local FR = require("tests.daemon_fake_relay")

local runner = dofile(H.REPO .. "/scripts/conformance.lua")

client.TIMEOUT_MS = 30000

local function daemon_mode(name)
    if name == "LOOMWORKS_RUNTIME" then return "daemon" end
    if name == "CI" or name == "LOOMWORKS_NO_DAEMON" then return nil end
    return os.getenv(name)
end

describe("status page model writes through a real daemon (step 5o C2a)", function()
    local root, srv, core, obs, ws, key
    local notes, orig_notify, wv_saved

    -- The in-process writes of the routed methods: never reached in daemon
    -- mode (no plugin-side fallback).
    local IN_PROCESS = { "publish", "revert_to_baseline", "publish_one", "revert_one", "set_intent",
        "set_description", "activate_profile", "add_profile_tool", "remove_profile_tool",
        "execute_create_config_set", "execute_create_config_set_from_candidate", "execute_edit_config_set",
        "execute_delete_config_set", "execute_add_project", "execute_delete_configuration",
        "execute_delete_launch_config", "execute_save_variable", "execute_delete_variable",
        "save_type_config_field" }

    before_each(function()
        key = H.tmp() .. "/trust.key"
        trust._set_key_path(key)
        root = runner.fixture("shell", key)
        trust._set_key_path(key)
        core = Core.new()
        core:setup({ root = root })
        assert.is_true(vim.wait(30000, function() return core._state == "initialized" end, 20))
        ws = core:get_workspace()
        notes = {}
        orig_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
        local wv = require("loomworks.workspace_view")
        wv_saved = {}
        for _, name in ipairs(IN_PROCESS) do
            wv_saved[name] = wv[name]
            wv[name] = function() error("in-process write " .. name .. " in daemon mode") end
        end
    end)

    after_each(function()
        local wv = require("loomworks.workspace_view")
        for name, fn in pairs(wv_saved) do wv[name] = fn end
        vim.notify = orig_notify
        if obs then obs:stop() end
        obs = nil
        if srv and not srv.stopped then srv:stop("test end", 0) end
        srv = nil
        pcall(function() core:shutdown() end)
        trust._set_key_path(nil)
    end)

    local function errors()
        local out = {}
        for _, n in ipairs(notes) do
            if n.level == vim.log.levels.ERROR then out[#out + 1] = n.msg end
        end
        return out
    end

    --- The daemon and the editor's observer, connected, the workspace view
    --- held and loaded.
    local function serve()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000,
            log = function() end })
        srv:registry()
        service.attach(srv, require("loomworks.cli")._daemon_build_host())
        assert(srv:start())
        local fr = FR.new({})
        obs = observer.attach(ws, { getenv = daemon_mode, keepalive_ms = 100,
            resolve = function() return "lw" end, relay = fr.relay })
        assert.is_true(vim.wait(60000, function()
            return obs:can_call("Workspace/1.set_intent") and obs:can_call("Profiles/1.set_active")
                and obs:can_call("ConfigSets/1.add")
        end, 20), obs:runtime_line())
        -- A first call loads the workspace in the daemon; the view follows.
        local r
        model.call(ws, "ConfigSets/1.candidates", {}, function(x) r = x end)
        assert.is_true(vim.wait(60000, function() return r ~= nil end, 20))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_true(vim.wait(60000, function()
            local v = obs:workspace_view()
            return v ~= nil and #v.profiles > 0
        end, 20), obs:runtime_line())
    end

    --- `method` called with `params`; its outcome once it arrived.
    local function call(method, params)
        local r
        model.call(ws, method, params, function(x) r = x end)
        assert.is_true(vim.wait(60000, function() return r ~= nil end, 20), method)
        return r
    end

    --- The view's row of `kind` ("profiles", "config_sets") named `name`.
    local function row(kind, name)
        for _, x in ipairs(obs:workspace_view()[kind] or {}) do
            if (x.key or x.name) == name then return x end
        end
        return nil
    end

    --- Wait until `pred(view)` holds.
    local function until_view(pred)
        assert.is_true(vim.wait(30000, function()
            local v = obs:workspace_view()
            return v ~= nil and pred(v)
        end, 20), vim.inspect(obs:workspace_view()))
    end

    it("set_intent, publish and revert name the row by its id; the page and its modified flag follow the view", function()
        serve()
        local prow = assert(row("profiles", "dev"))
        assert.is_not_nil(prow.id)
        assert.equals("local", prow.intent)

        -- `P` on the profile row (helpers.cycle_intent: local → local+shared).
        require("loomworks.ui.helpers").cycle_intent(prow, ws)
        until_view(function(v) return row("profiles", "dev").intent == "local+shared" end)
        -- Unpublished: the buffer is modified (`:e` refused), from the view.
        until_view(function(v) return v.modified == true end)
        assert.is_true(status_source.modified(ws))

        -- `:w`: Workspace/1.publish; the view's update precedes the reply.
        local r = call("Workspace/1.publish", {})
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_false(obs:workspace_view().modified)
        assert.is_false(status_source.modified(ws))
        local published = vim.json.decode(table.concat(vim.fn.readfile(root .. "/loomworks.json"), "\n"))
        assert.is_not_nil(published.profiles and published.profiles.dev)

        -- `:e!`: Workspace/1.revert_to_baseline.
        r = call("Workspace/1.revert_to_baseline", {})
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({}, errors())
    end)

    it("a stale id is refused and shown; nothing runs in-process", function()
        serve()
        local prow = assert(row("profiles", "dev"))
        local stale = vim.deepcopy(prow)
        stale.id = "999999:999999"
        require("loomworks.ui.helpers").cycle_intent(stale, ws)
        assert.is_true(vim.wait(30000, function() return #errors() > 0 end, 20))
        assert.truthy(errors()[1]:find("^loomworks: intent: "), errors()[1])
        assert.truthy(errors()[1]:find("stale", 1, true), errors()[1])
        -- The profile is unchanged.
        assert.equals("local", row("profiles", "dev").intent)
        -- A row with no id (an in-process row) is refused without a call.
        local r = call("Profiles/1.set_active", { profile = { key = "dev" } })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no profile id", 1, true), r.message)
    end)

    it("activates, creates from an automatic set, edits a profile's toolchain and a set by their rows", function()
        serve()
        local r = call("Profiles/1.set_active", { profile = assert(row("profiles", "dev")) })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return row("profiles", "dev").active == true end)

        -- The create-profile picker: ConfigSets/1.candidates → tool_choices
        -- → create (the automatic set added by the daemon, one call).
        local c = call("ConfigSets/1.candidates", {})
        local auto
        for _, s in ipairs(c.sets) do if s.auto then auto = s end end
        assert.is_not_nil(auto, vim.inspect(c.sets))
        assert.is_not_nil(auto.candidate)
        local t = call("Profiles/1.tool_choices", { config_set = auto })
        assert.equals("ok", t.outcome, vim.inspect(t))
        r = call("Profiles/1.create", { config_set = auto, activate = false })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil(r.profile and r.profile.id)
        until_view(function() return row("config_sets", auto.name) ~= nil end)

        -- A toolchain key the profile cannot use is the daemon's refusal.
        r = call("Profiles/1.add_tool", { profile = row("profiles", "dev"), tool = "no-such-tool" })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("^toolchain: "), r.message)

        -- ConfigSets/1.add (a template's mappings), update and remove by row.
        r = call("ConfigSets/1.add", { name = "two", mappings = { app = "Debug" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return row("config_sets", "two") ~= nil end)
        r = call("ConfigSets/1.update", { config_set = row("config_sets", "two"), name = "three",
            mappings = { app = "Debug", lib = "Debug" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return row("config_sets", "three") ~= nil and row("config_sets", "two") == nil end)
        r = call("ConfigSets/1.remove", { config_set = row("config_sets", "three") })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return row("config_sets", "three") == nil end)
        assert.same({}, errors())
    end)

    it("delete_user_prefs confirms with a plan; a changed working copy is refused; accepted it deletes", function()
        serve()
        local path = root .. "/.nvim/loomworks.user.json"
        local r = call("Workspace/1.delete_user_prefs", {})
        assert.equals("confirm", r.outcome, vim.inspect(r))
        assert.truthy(r.lines[1]:find("loomworks.user.json", 1, true), r.lines[1])
        -- The working copy changes after it was shown: the plan is refused.
        local plan = r.plan
        local signed = trust.sign("user", trust.encode({ _meta = { version = 2 },
            profiles = { dev = { configuration_set = "dev" } } }))
        vim.fn.writefile(vim.split(signed, "\n", { plain = true }), path, "b")
        r = call("Workspace/1.delete_user_prefs", { plan = plan })
        assert.equals("refused", r.outcome)
        assert.equals(1, vim.fn.filereadable(path))
        -- Through the page's `U`: the dialog shows the daemon's lines; `y`
        -- sends the plan back.
        local shown
        local dialog = require("loomworks.ui.dialog")
        local orig_show = dialog.show
        dialog.show = function(o) shown = o end
        require("loomworks.ui.tree").new():_confirm_delete_user_prefs()
        assert.is_true(vim.wait(30000, function() return shown ~= nil end, 20))
        dialog.show = orig_show
        assert.truthy(table.concat(shown.lines, "\n"):find("loomworks.user.json", 1, true))
        shown.keys.y({ close = function() end })
        assert.is_true(vim.wait(30000, function() return vim.fn.filereadable(path) == 0 end, 20), vim.inspect(notes))
    end)

    it("trust_accept of a trusted working copy is ok with its note, asked nothing", function()
        serve()
        local asked = false
        require("loomworks.ui.tree").new():_trust(function() asked = true; return 3 end)
        assert.is_true(vim.wait(30000, function()
            for _, n in ipairs(notes) do if n.msg:find("already trusted", 1, true) then return true end end
            return false
        end, 20), vim.inspect(notes))
        assert.is_false(asked)
    end)

    it("refused, never in-process, once the daemon cannot carry the call", function()
        serve()
        local prow = assert(row("profiles", "dev"))
        obs:stop()
        local r = call("Profiles/1.set_active", { profile = prow })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("^profile activation: "), r.message)
        r = call("Workspace/1.publish", {})
        assert.equals("refused", r.outcome)
    end)

    -- Step 5o C2b: Projects/1.

    --- The view's row of project `key` and its entry `name` of `list`
    --- ("configurations", "launches"), when given.
    local function prow_of(key, list, name)
        local p = row("projects", key)
        if not (p and list) then return p end
        for _, x in ipairs(p[list] or {}) do
            if x.key == name then return x end
        end
        return nil
    end

    --- The value of `type_config` field `name` in project `key`'s row.
    local function field_value(key, name)
        for _, f in ipairs(prow_of(key).type_config.fields) do
            if f.name == name then return f.value end
        end
        return nil
    end

    it("Projects/1: a field, variables, a launch and a configuration by their rows' ids; the declaration read", function()
        serve()
        local prow = assert(prow_of("app"))
        assert.is_not_nil(prow.id)

        local r = call("Projects/1.type_config_set", { project = prow, field = "clangd", value = "/x/clangd" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return field_value("app", "clangd") == "/x/clangd" end)

        r = call("Projects/1.variable_save", { project = prow_of("app"), name = "out",
            data = { type = "path", default = "${build_dir}/o" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app").variables.out ~= nil end)

        -- The variable editor's read: the declaration, its launches by id.
        local d = call("Projects/1.declaration", { project = prow_of("app") })
        assert.equals("ok", d.outcome, vim.inspect(d))
        assert.equals("path", d.variables.out.type)
        local hello = assert(prow_of("app", "launches", "hello"))
        local ids = {}
        for _, l in ipairs(d.launches) do ids[l.key] = l.id end
        assert.equals(hello.id, ids.hello)

        r = call("Projects/1.variable_save", { project = prow_of("app"), variable = "out", name = "out2",
            data = { type = "string", default = "x" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app").variables.out2 ~= nil and prow_of("app").variables.out == nil end)
        r = call("Projects/1.variable_remove", { project = prow_of("app"), variable = "out2" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app").variables.out2 == nil end)
        -- A variable the project does not declare: the daemon's refusal.
        r = call("Projects/1.variable_remove", { project = prow_of("app"), variable = "out2" })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("^variable: "), r.message)

        r = call("Projects/1.launch_remove", { project = prow_of("app"), launch = hello })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app", "launches", "hello") == nil end)
        -- Its id is stale now: refused, never looked up by its name.
        r = call("Projects/1.launch_remove", { project = prow_of("app"), launch = hello })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("stale", 1, true), r.message)

        local crow = assert(prow_of("app", "configurations", "Debug"))
        assert.is_not_nil(crow.id)
        r = call("Projects/1.configuration_remove", { project = prow_of("app"), configuration = crow })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function()
            local c = prow_of("app", "configurations", "Debug")
            return c == nil or c.user ~= true
        end)
        assert.same({}, errors())
    end)

    it("Projects/1: the browser's add is candidates then add, both the daemon's", function()
        serve()
        vim.fn.mkdir(root .. "/tools/gen", "p")
        local c = call("Projects/1.candidates", { path = root .. "/tools/gen", type = "shell" })
        assert.equals("ok", c.outcome, vim.inspect(c))
        assert.equals("tools_gen", c.key)
        assert.equals("tools/gen", c.path)
        local r = call("Projects/1.add", { key = c.key, type = "shell", path = c.path, mappings = {} })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil(r.project and r.project.id)
        until_view(function() return prow_of("tools_gen") ~= nil end)
        -- The same key again: the daemon's refusal, shown as the add's.
        r = call("Projects/1.add", { key = c.key, type = "shell", path = c.path })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("^project: "), r.message)
    end)

    it("Projects/1: a stale or missing project id is refused; refused once the daemon cannot carry it", function()
        serve()
        local stale = vim.deepcopy(prow_of("app"))
        stale.id = "999999:999999"
        local r = call("Projects/1.type_config_set", { project = stale, field = "clangd", value = "x" })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("stale", 1, true), r.message)
        r = call("Projects/1.declaration", { project = { key = "app" } })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no project id", 1, true), r.message)
        local prow = prow_of("app")
        obs:stop()
        r = call("Projects/1.variable_remove", { project = prow, variable = "x" })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("^variable: "), r.message)
        -- Nothing ran in-process: the editor's model is unchanged.
        for _, proj in pairs(ws:get_projects()) do
            if proj.key == "app" then assert.is_nil((proj.type_config or {}).clangd) end
        end
    end)
end)
