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
        "save_type_config_field", "execute_save_configuration", "execute_save_launch_config", "save_deploy",
        "expand_preview", "project_declaration" }

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
        -- A configuration the user declared (removable), not a module's.
        assert.is_true(crow.user)
        local others = {}
        for _, c in ipairs(prow_of("app").configurations) do
            if c.key ~= "Debug" then others[#others + 1] = c.key end
        end
        table.sort(others)
        r = call("Projects/1.configuration_remove", { project = prow_of("app"), configuration = crow })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app", "configurations", "Debug") == nil end)
        -- Gone, the project's other configurations untouched.
        local left = {}
        for _, c in ipairs(prow_of("app").configurations) do left[#left + 1] = c.key end
        table.sort(left)
        assert.same(others, left)
        -- Its id is stale now: a second removal is refused.
        r = call("Projects/1.configuration_remove", { project = prow_of("app"), configuration = crow })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.truthy(r.message:find("stale", 1, true), r.message)
        assert.is_nil(prow_of("app", "configurations", "Debug"))
        assert.same({}, errors())
    end)

    it("Projects/1: the configuration editor reads the declaration and saves by the row's id (5o C2b2)", function()
        serve()
        local r = call("Projects/1.variable_save", { project = prow_of("app"), name = "out",
            data = { type = "string", default = "x" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return prow_of("app").variables.out ~= nil end)
        local crow = assert(prow_of("app", "configurations", "Debug"))

        -- The declaration's derived fields, the configuration by its row's id.
        local d = call("Projects/1.declaration", { project = prow_of("app") })
        assert.equals("ok", d.outcome, vim.inspect(d))
        assert.is_false(d.module.has_options)
        assert.is_table(d.module.languages)
        local entry
        for _, c in ipairs(d.configurations) do if c.key == "Debug" then entry = c end end
        assert.equals(crow.id, entry.id)
        assert.is_true(entry.user)
        assert.same({ { name = "out", value = "x", from = "project" } }, entry.resolved_variables)

        -- The editor opened from the page's row (the daemon's view and the
        -- declaration), and its save: a rename keeping the id.
        local body = status_source.read(ws)
        assert.equals("daemon", body.mode)
        local ctx = { lw = require("loomworks"), view = body.view, ref = body.ref, ws = ws, mode = body.mode }
        local page = require("loomworks.ui.tree").new(function(t) require("loomworks.ui.sections.projects")(t, ctx) end)
        setmetatable(page._folds, { __index = function() return true end })
        local enter
        for i, l in ipairs(page:render()) do
            if l:find("[▼▸] %+?Debug%f[^%w_:%-]") and page.line_meta[i] and page.line_meta[i].on_enter then
                enter = page.line_meta[i].on_enter
                break
            end
        end
        assert.is_function(enter)
        local dialog = require("loomworks.ui.config_editor_dialog")
        local orig_open, got = dialog.open, nil
        dialog.open = function(o) got = o end
        local ok, err = pcall(enter)
        assert.is_true(vim.wait(30000, function() return got ~= nil end, 20))
        dialog.open = orig_open
        assert(ok, err)
        assert.equals("Debug", got.name)
        assert.equals("x", got.resolved_variables.out.value)
        assert.equals("project", got.resolved_variables.out.from)
        got.on_accept({ name = "Dbg", options = {}, variables = { out = "y" } })
        until_view(function()
            local c = prow_of("app", "configurations", "Dbg")
            if not (c and c.id == crow.id and prow_of("app", "configurations", "Debug") == nil) then return false end
            for _, v in ipairs(c.variables or {}) do
                if v.name == "out" then return v.value == "y" end
            end
            return false
        end)
        assert.is_true(vim.wait(5000, function()
            for _, n in ipairs(notes) do
                if n.msg:find("configuration 'Dbg' updated", 1, true) then return true end
            end
            return false
        end, 20))

        -- A new configuration: no configuration, its id in the outcome.
        r = call("Projects/1.configuration_save", { project = prow_of("app"), name = "Fast",
            fields = { inherits = "Dbg", options = {}, variables = {} } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("Fast", r.configuration.key)
        until_view(function()
            local c = prow_of("app", "configurations", "Fast")
            return c ~= nil and c.id == r.configuration.id
        end)
        -- A row without an id is refused, never looked up by its name.
        r = call("Projects/1.configuration_save", { project = prow_of("app"), configuration = { key = "Fast" },
            name = "Fast2", fields = {} })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no configuration id", 1, true), r.message)
        assert.same({}, errors())
    end)

    --- The working copy's declaration of project `key` (the signed file is
    --- JSON).
    local function user_project(key)
        local text = table.concat(vim.fn.readfile(root .. "/.nvim/loomworks.user.json"), "\n")
        return vim.json.decode(text).projects[key]
    end

    --- The projects section of the page as the daemon's view renders it,
    --- and the `on_enter` of its first line matching `pat` after the line
    --- matching `after` (a plain find).
    local function page_action(pat, after)
        local body = status_source.read(ws)
        assert.equals("daemon", body.mode)
        local ctx = { lw = require("loomworks"), view = body.view, ref = body.ref, ws = ws, mode = body.mode }
        local page = require("loomworks.ui.tree").new(function(t) require("loomworks.ui.sections.projects")(t, ctx) end)
        setmetatable(page._folds, { __index = function() return true end })
        local seen = after == nil
        for i, l in ipairs(page:render()) do
            if not seen and l:find(after, 1, true) then seen = true end
            if seen and l:find(pat) and page.line_meta[i] and page.line_meta[i].on_enter then
                return page.line_meta[i].on_enter
            end
        end
        return nil
    end

    --- Run `enter` with `mod.open` stubbed; the opts it was opened with.
    local function opened(mod, enter)
        local m = require(mod)
        local orig, got = m.open, nil
        m.open = function(o) got = o end
        local ok, err = pcall(enter)
        assert.is_true(vim.wait(30000, function() return got ~= nil end, 20), mod)
        m.open = orig
        assert(ok, err)
        return got
    end

    --- Activate the profile `dev` (a preview expands under the active one).
    local function activate()
        local r = call("Profiles/1.set_active", { profile = row("profiles", "dev") })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return row("profiles", "dev").active == true end)
    end

    it("Projects/1: expand_preview expands in the daemon; an unresolved reference stays as written (5o C2b2-2)", function()
        serve()
        activate()
        local r = call("Projects/1.expand_preview", { project = prow_of("app"),
            templates = { "${workspace_root}/x", "${nope}/y" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals(vim.fs.normalize(root) .. "/x", vim.fs.normalize(r.values[1]))
        assert.equals("${nope}/y", r.values[2])
        -- A row without an id is refused, never looked up by its key.
        r = call("Projects/1.expand_preview", { project = { key = "app" }, templates = { "a" } })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no project id", 1, true), r.message)
        assert.same({}, errors())
    end)

    it("Projects/1: the launch editor reads the declaration, previews through the daemon and saves by the row's id (5o C2b2-2)", function()
        serve()
        activate()
        local hello = assert(prow_of("app", "launches", "hello"))
        local enter = page_action("hello", "Launch:")
        assert.is_function(enter)
        local got = opened("loomworks.ui.launch_editor", enter)
        assert.equals("hello", got.name)
        assert.same({ "--version" }, got.args)
        -- The path editors' preview: Projects/1.expand_preview, asynchronous.
        local value
        got.preview("${workspace_root}/w", function(v) value = v end)
        assert.is_true(vim.wait(30000, function() return value ~= nil end, 20))
        assert.equals(vim.fs.normalize(root) .. "/w", vim.fs.normalize(value))
        -- The deploy editor's view rows.
        assert.is_table(got.projects)
        assert.is_table(got.profiles)
        -- A rename with a deploy of both shapes: one source, and an array.
        got.on_accept({ name = "hi", command = got.command, args = got.args, working_dir = "", env = {},
            deploy = { ["one/"] = { project = "app", path = "a" },
                ["two/"] = { { project = "app", path = "b" }, { project = "lib", path = "c" } } } })
        until_view(function()
            local l = prow_of("app", "launches", "hi")
            return l ~= nil and l.id == hello.id and prow_of("app", "launches", "hello") == nil
        end)
        local saved = user_project("app").launch.hi
        assert.same({ project = "app", path = "a" }, saved.deploy["one/"])
        assert.same({ { project = "app", path = "b" }, { project = "lib", path = "c" } }, saved.deploy["two/"])
        assert.is_nil(saved.env)

        -- A new one (no launch): created, its id in the outcome.
        local r = call("Projects/1.launch_save", { project = prow_of("app"), name = "fresh",
            data = { command = "x", env = {} } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("fresh", r.launch.key)
        -- A row without an id is refused, never looked up by its name.
        r = call("Projects/1.launch_save", { project = prow_of("app"), launch = { key = "fresh" },
            name = "fresh", data = { command = "y" } })
        assert.equals("refused", r.outcome)
        assert.truthy(r.message:find("no launch configuration id", 1, true), r.message)
        assert.same({}, errors())
    end)

    it("Projects/1: a deploy step's change saves the declared deploy in its own shape by the row's id (5o C2b2-2)", function()
        serve()
        local r = call("Projects/1.deploy_save", { project = prow_of("app"), deploy = {
            ["one/"] = { project = "app", path = "a" },
            ["two/"] = { { project = "app", path = "b" }, { project = "app", path = "c" } } } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        until_view(function() return #prow_of("app").deploy == 2 end)

        -- "Add deploy step" from the page: the editor gets the view's rows;
        -- its accept reads the declaration and saves the whole deploy.
        local enter = page_action("Add deploy step")
        assert.is_function(enter)
        local got = opened("loomworks.ui.deploy_editor", enter)
        local keys = {}
        for _, p in ipairs(got.projects) do keys[#keys + 1] = p.key end
        table.sort(keys)
        assert.same({ "app", "lib" }, keys)
        got.on_accept("three/", { project = "lib", path = "d" })
        until_view(function() return #prow_of("app").deploy == 3 end)
        local deploy = user_project("app").deploy
        -- The sources keep the shape they were declared in (the view's are
        -- arrays; never saved back).
        assert.same({ project = "app", path = "a" }, deploy["one/"])
        assert.same({ { project = "app", path = "b" }, { project = "app", path = "c" } }, deploy["two/"])
        assert.same({ project = "lib", path = "d" }, deploy["three/"])

        -- A step's removal (D): the rest unchanged.
        local body = status_source.read(ws)
        local ctx = { lw = require("loomworks"), view = body.view, ref = body.ref, ws = ws, mode = body.mode }
        local page = require("loomworks.ui.tree").new(function(t) require("loomworks.ui.sections.projects")(t, ctx) end)
        setmetatable(page._folds, { __index = function() return true end })
        local delete
        for i, l in ipairs(page:render()) do
            if l:find("<- app : c", 1, true) and page.line_meta[i] then delete = page.line_meta[i].on_delete end
        end
        assert.is_function(delete)
        -- (Its save's outcome awaited: the daemon stops at the test's end.)
        local orig_call, saved = model.call, nil
        model.call = function(w, m, p, cb)
            return orig_call(w, m, p, function(x)
                if m == "Projects/1.deploy_save" then saved = x end
                if cb then cb(x) end
            end)
        end
        local ok, err = pcall(delete)
        assert.is_true(vim.wait(30000, function() return saved ~= nil end, 20))
        model.call = orig_call
        assert(ok, err)
        assert.equals("ok", saved.outcome, vim.inspect(saved))
        deploy = user_project("app").deploy
        assert.same({ project = "app", path = "b" }, deploy["two/"])
        assert.same({ project = "app", path = "a" }, deploy["one/"])
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
