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
            -- The set row's mapping as the project's offered configuration.
            assert.equals(app_cfgs[1], opened.mappings[APP])
            -- A mapping to a configuration the view does not list keeps its name.
            assert.equals("Gone", opened.mappings[LIB].name)
            assert.is_false(vim.tbl_contains(opened.available_configs[LIB], opened.mappings[LIB]))
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
    -- The dialog's mappings are project rows -> configuration choices
    -- (`{ name }`); in-process the project is the object the in-process view
    -- bound to its row and the configuration is resolved in it by name, as
    -- the daemon resolves a mapping.
    local saved, calls
    local ss = require("loomworks.status_source")
    local WS, CS, CFG = { root = "/w" }, {}, {}
    -- The project resolves a mapping's configuration by name, as the
    -- daemon's mapping does (Project:get_configuration).
    local PR = { key = "app", get_configuration = function(_, n) if n == "Debug" then return CFG end end }
    local PRROW, CSROW = { key = "app" }, { name = "cs" }
    ss.bind(PRROW, PR); ss.bind(CSROW, CS)
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
            mappings = { [PRROW] = { name = "Debug" } } })
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

describe("configuration set dialogs offer cmake presets (WP-B)", function()
    -- A preset configuration (`preset:<name>`, cmake) is a real
    -- configuration of its project: the view lists it under the project
    -- row's `presets`, not `configurations[]`. The dialogs offer it, and a
    -- mapping to it saves in both modes (the daemon resolves it by name).
    local saved_editor, saved_select, saved_notify, opened, notes
    before_each(function()
        opened, notes = nil, {}
        saved_editor = package.loaded["loomworks.ui.config_set_editor"]
        package.loaded["loomworks.ui.config_set_editor"] = { open = function(o) opened = o end }
        saved_select = vim.ui.select
        vim.ui.select = function(items, _, cb) cb(items[#items]) end -- "Custom..."
        saved_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)
    after_each(function()
        package.loaded["loomworks.ui.config_set_editor"] = saved_editor
        vim.ui.select = saved_select
        vim.notify = saved_notify
    end)

    local function render(ctx)
        local tree, nodes = fake_tree()
        package.loaded["loomworks.ui.sections.config_sets"] = nil
        require("loomworks.ui.sections.config_sets")(tree, ctx)
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
    local function names(choices)
        local out = {}
        for _, c in ipairs(choices or {}) do out[#out + 1] = c.name end
        return out
    end

    it("daemon: the view's presets are offered and a preset mapping is sent by its name", function()
        local obs = fake_obs()
        local ws = trap_ws(obs)
        local APP = { id = "pr:1", key = "App", configurations = { { id = "c:1", key = "Dev" } },
            presets = { { name = "preset:dev", generator = "Ninja" } } }
        local SET = { id = "cs:1", name = "P", mappings = { App = "preset:dev" }, missing = {} }
        local view = { config_sets = { SET }, projects = { APP }, profiles = {} }
        render({ mode = "daemon", view = view, ws = ws, lw = {} }).set("P").on_enter()
        assert.same({ "Dev", "preset:dev" }, names(opened.available_configs[APP]))
        -- The set's preset mapping is the offered preset choice.
        assert.equals(opened.available_configs[APP][2], opened.mappings[APP])
        opened.on_accept({ name = "P2", mappings = opened.mappings })
        assert.same({ { method = "ConfigSets/1.update",
            args = { config_set = { id = "cs:1" }, name = "P2", mappings = { App = "preset:dev" } } } }, obs.requests)
    end)

    describe("in-process, a real cmake workspace with a preset", function()
        _G.LOOMWORKS_CLI_NO_AUTORUN = true
        local cli = require("loomworks.cli")
        local ss = require("loomworks.status_source")
        local root, ws

        local function find_set(name)
            for _, cs in pairs(ws._config_sets) do if cs.name == name and not cs._removed then return cs end end
        end
        local function app_project()
            for _, p in pairs(ws._projects) do if p.key == "App" then return p end end
        end
        local function app_row(view)
            for _, p in ipairs(view.projects) do if p.key == "App" then return p end end
        end
        local function page()
            local view = ws:view_workspace({ bind = ss.bind })
            return render({ mode = "in-process", view = view, ws = ws, lw = {} }), view
        end

        before_each(function()
            root = vim.fn.tempname():gsub("\\", "/")
            vim.fn.mkdir(root .. "/App", "p")
            io.open(root .. "/App/CMakeLists.txt", "w"):close()
            local f = assert(io.open(root .. "/App/CMakePresets.json", "w"))
            f:write(vim.json.encode({ version = 3, configurePresets = { { name = "dev", generator = "Ninja",
                binaryDir = "${sourceDir}/build/dev", cacheVariables = { CMAKE_BUILD_TYPE = "Debug" } } } }))
            f:close()
            f = assert(io.open(root .. "/loomworks.json", "w"))
            f:write(vim.json.encode({ projects = { App = { cmake = vim.empty_dict() } },
                configuration_sets = { P = { App = "preset:dev" } } }))
            f:close()
            ws = assert(cli._load_workspace(root, false))
        end)

        it("create offers the preset; saving a set mapped to it adds the set", function()
            local p, view = page()
            p.item("Create configuration set").on_enter()
            assert.is_table(opened)
            local app = app_row(view)
            local choices = opened.available_configs[app]
            assert.is_truthy(vim.tbl_contains(names(choices), "preset:dev"), vim.inspect(names(choices)))
            local preset
            for _, c in ipairs(choices) do if c.name == "preset:dev" then preset = c end end
            opened.on_accept({ name = "New", mappings = { [app] = preset } })
            for _, n in ipairs(notes) do assert.is_true(n.level < vim.log.levels.WARN, n.msg) end
            local cs = assert(find_set("New"))
            assert.equals("preset:dev", cs:configuration(app_project()).name)
        end)

        it("edit of a set mapped to the preset shows it and saves it (a rename)", function()
            local p, view = page()
            p.set("P").on_enter()
            local app = app_row(view)
            assert.equals("preset:dev", opened.mappings[app].name)
            assert.is_truthy(vim.tbl_contains(opened.available_configs[app], opened.mappings[app]))
            opened.on_accept({ name = "P2", mappings = opened.mappings })
            for _, n in ipairs(notes) do assert.is_true(n.level < vim.log.levels.WARN, n.msg) end
            local cs = assert(find_set("P2"))
            assert.equals("preset:dev", cs:configuration(app_project()).name)
        end)

        it("a removed or unknown configuration is refused as the daemon refuses it", function()
            local model = require("loomworks.ui.model_calls")
            local _, view = page()
            local app = app_row(view)
            local got
            model.call(ws, "ConfigSets/1.add", { name = "X", mappings = { [app] = { name = "Gone" } } },
                function(r) got = r end)
            assert.same({ outcome = "refused", message = "no configuration 'Gone' in project 'App'" }, got)
            -- A removed configuration, even with a row bound to it.
            local cfg = app_project():get_configuration("preset:dev")
            cfg._removed = true
            model.call(ws, "ConfigSets/1.add", { name = "X", mappings = { [app] = { name = "preset:dev" } } },
                function(r) got = r end)
            assert.same({ outcome = "refused", message = "no configuration 'preset:dev' in project 'App'" }, got)
            local CROW = {}
            ss.bind(CROW, cfg)
            model.call(ws, "ConfigSets/1.add", { name = "X",
                mappings = { [app] = { name = "preset:dev", _row = CROW } } }, function(r) got = r end)
            assert.same({ outcome = "refused", message = "no configuration 'preset:dev' in project 'App'" }, got)
            assert.is_nil(find_set("X"))
        end)
    end)

    it("no view held: the dialogs refuse with a notice, nothing opened", function()
        local obs = fake_obs()
        local SET = { id = "cs:1", name = "P", mappings = {}, missing = {} }
        local view = { config_sets = { SET }, projects = { { id = "pr:1", key = "App", configurations = {} } },
            profiles = {} }
        local ctx = { mode = "daemon", view = view, ws = trap_ws(obs), lw = {} }
        local p = render(ctx)
        ctx.view = nil
        p.set("P").on_enter()
        p.item("Create configuration set").on_enter()
        assert.is_nil(opened)
        assert.is_true(#notes >= 1)
        assert.is_truthy(notes[1].msg:find("workspace view", 1, true), notes[1].msg)
    end)
end)
