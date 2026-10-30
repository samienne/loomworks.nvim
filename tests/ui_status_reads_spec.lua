-- WP-B part 1 (6b-alpha, spec/core/daemon.md): the status page's remaining
-- editor-model reads. In `daemon` mode the configuration-set dialogs read
-- only the workspace view and daemon calls; the editor's model is never
-- touched (a trap workspace errors on any read).

local model = require("loomworks.ui.model_calls")

--- A fake observer carrying every method: records plain requests and
--- answers each with `answer` (default `ok`).
local function fake_obs()
    local obs = { state = "connected", requests = {}, carried = true }
    function obs:can_call() return self.carried end
    function obs:refusal(method) return "the daemon does not carry " .. method end
    function obs:request(method, args, cb)
        self.requests[#self.requests + 1] = { method = method, args = args }
        cb({ outcome = "ok", result = self.answer or { outcome = "ok" } })
    end
    return obs
end

--- A daemon-mode workspace whose model fields are a trap: any read other
--- than its root and observer errors.
local function trap_ws(obs)
    return setmetatable({ root = "/w", _daemon_observer = obs }, {
        __index = function(_, k) error("editor model read in daemon mode: " .. tostring(k), 2) end,
    })
end

--- A tree recording nodes and items (label + opts).
local function fake_tree()
    local nodes = {}
    local tree = setmetatable({}, { __index = function() return function() end end })
    function tree:node(label, opts, children)
        nodes[#nodes + 1] = { label = label, opts = opts }
        if children then children() end
    end
    function tree:item(label, opts) nodes[#nodes + 1] = { label = label, opts = opts } end
    function tree:leaf(label) nodes[#nodes + 1] = { label = label } end
    function tree:group(_, _, children) children() end
    return tree, nodes
end

describe("status page reads in daemon mode (WP-B)", function()
    local obs, ws, saved_notify, notes
    before_each(function()
        obs = fake_obs()
        ws = trap_ws(obs)
        saved_notify = vim.notify
        notes = {}
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)
    after_each(function() vim.notify = saved_notify end)

    describe("configuration set dialogs", function()
        local saved_editor, opened
        before_each(function()
            opened = nil
            saved_editor = package.loaded["loomworks.ui.config_set_editor"]
            package.loaded["loomworks.ui.config_set_editor"] = { open = function(o) opened = o end }
        end)
        after_each(function() package.loaded["loomworks.ui.config_set_editor"] = saved_editor end)

        local APP = { id = "pr:1", key = "app", configurations = {
            { id = "c:1", key = "Debug" }, { id = "c:2", key = "Release" } } }
        local LIB = { id = "pr:2", key = "lib", configurations = { { id = "c:3", key = "Debug" } } }
        local SET = { id = "cs:1", name = "Dev", mappings = { app = "Debug", lib = "Gone" }, missing = { lib = true } }

        local function render(view)
            local tree, nodes = fake_tree()
            package.loaded["loomworks.ui.sections.config_sets"] = nil
            require("loomworks.ui.sections.config_sets")(tree, { mode = "daemon", view = view, ws = ws, lw = {} })
            local function find(pred)
                for _, n in ipairs(nodes) do if n.opts and pred(n) then return n.opts end end
            end
            return {
                set = function(name) return find(function(n) return n.opts.fold_key == "set:" .. name end) end,
                item = function(text)
                    return find(function(n) return type(n.label) == "string" and n.label:find(text, 1, true) end)
                end,
            }
        end

        it("edit: the dialog's projects, configurations and mappings come from the view's rows", function()
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {} }
            render(view).set("Dev").on_enter()
            assert.is_table(opened)
            assert.same({ "app", "lib" }, { opened.projects[1].key, opened.projects[2].key })
            assert.equals(APP, opened.projects[1])
            local app_cfgs = opened.available_configs[APP]
            assert.same({ "Debug", "Release" }, { app_cfgs[1].name, app_cfgs[2].name })
            assert.equals(APP.configurations[1], app_cfgs[1]._row)
            -- The set row's mapping as the project's configuration row.
            assert.equals(app_cfgs[1], opened.mappings[APP])
            -- A mapping to a configuration the view does not list keeps its name.
            assert.equals("Gone", opened.mappings[LIB].name)
            assert.is_nil(opened.mappings[LIB]._row)
        end)

        it("edit: accepting sends ConfigSets/1.update by the set's id, mappings key -> name", function()
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {} }
            render(view).set("Dev").on_enter()
            local m = {}
            m[APP] = opened.available_configs[APP][2]
            opened.on_accept({ name = "Dev2", mappings = m })
            assert.same({
                { method = "ConfigSets/1.update",
                    args = { config_set = { id = "cs:1" }, name = "Dev2", mappings = { app = "Release" } } },
            }, obs.requests)
        end)

        it("create (custom): the dialog lists the view's projects, nothing mapped", function()
            local view = { config_sets = {}, projects = { APP, LIB }, profiles = {} }
            -- (The generated templates are still the editor model's -- a
            -- transition the daemon cannot carry yet; none here.)
            ws = setmetatable({ root = "/w", _daemon_observer = obs,
                generate_default_config_sets = function() return {} end }, getmetatable(ws))
            render(view).item("Create configuration set").on_enter()
            assert.is_table(opened)
            assert.same({ APP, LIB }, opened.projects)
            assert.same({}, opened.mappings)
            assert.same({ "Debug" }, { opened.available_configs[LIB][1].name })
            local m = {}
            m[LIB] = opened.available_configs[LIB][1]
            opened.on_accept({ name = "New", mappings = m })
            assert.same({ { method = "ConfigSets/1.add", args = { name = "New", mappings = { lib = "Debug" } } } },
                obs.requests)
        end)
    end)
end)

describe("ConfigSets/1 dialog mappings in-process (WP-B)", function()
    -- The dialog's mappings are project rows -> configuration handles
    -- (`_row` the configuration's row); in-process each is the object the
    -- in-process view bound to it.
    local saved, calls
    local ss = require("loomworks.status_source")
    local WS, CS, PR, CFG = { root = "/w" }, {}, {}, {}
    local PRROW, CSROW, CROW = { key = "app" }, { name = "cs" }, { key = "Debug" }
    ss.bind(PRROW, PR); ss.bind(CSROW, CS); ss.bind(CROW, CFG)
    before_each(function()
        calls = {}
        saved = { package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] }
        package.loaded["loomworks.workspace_view"] = setmetatable({}, { __index = function(_, name)
            return function(...)
                calls[#calls + 1] = { name, ... }
                return true
            end
        end })
        package.loaded["loomworks"] = { runtime_mode = function() return "in-process" end }
    end)
    after_each(function()
        package.loaded["loomworks.workspace_view"], package.loaded["loomworks"] = saved[1], saved[2]
    end)
    local function run(method, params)
        local got
        model.call(WS, method, params, function(r) got = r end)
        return got
    end

    it("passes the bound objects", function()
        run("ConfigSets/1.update", { config_set = CSROW, name = "D2",
            mappings = { [PRROW] = { name = "Debug", _row = CROW } } })
        assert.same({ { "execute_edit_config_set", CS, "D2", { [PR] = CFG } } }, calls)
    end)

    it("refuses a configuration the view does not list (by its name), writing nothing", function()
        local r = run("ConfigSets/1.update", { config_set = CSROW, name = "D2",
            mappings = { [PRROW] = { name = "Gone" } } })
        assert.equals("refused", r.outcome)
        assert.equals("no configuration 'Gone' in project 'app'", r.message)
        assert.same({}, calls)
    end)
end)
