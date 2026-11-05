-- WP-B part 1 (6b-alpha, loomworks spec/core/daemon.md): the status page's remaining
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

--- The `daemon`-mode editor's workspace: none (it holds no model, step
--- 6b-alpha); `obs` is its observer. Returns nil, the `ws` the page passes.
local function trap_ws(obs)
    local observer = require("loomworks.daemon.observer")
    observer._current = obs
    observer._attached_root = obs and "/w" or nil
    return nil
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
        local SET = { id = "cs:1", name = "Dev", mappings = {
            { project = { id = "pr:1", key = "app" }, configuration = { id = "c:1", key = "Debug" }, missing = false },
            { project = { id = "pr:2", key = "lib" }, configuration = { id = "c:9", key = "Gone" }, missing = true } } }

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
            -- A mapping to a configuration the view does not list keeps its
            -- entry's reference.
            assert.same({ name = "Gone", id = "c:9" }, opened.mappings[LIB])
            assert.is_false(vim.tbl_contains(opened.available_configs[LIB], opened.mappings[LIB]))
        end)

        it("edit: accepting sends ConfigSets/1.update by the set's id, mappings by id", function()
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {} }
            render(view).set("Dev").on_enter()
            local m = {}
            m[APP] = opened.available_configs[APP][2]
            opened.on_accept({ name = "Dev2", mappings = m })
            assert.same({
                { method = "ConfigSets/1.update",
                    args = { config_set = { id = "cs:1" }, name = "Dev2",
                        mappings = { { project = { id = "pr:1" }, configuration = { id = "c:2" } } } } },
            }, obs.requests)
        end)

        it("edit: a source-missing mapping is kept by its entry's id", function()
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {} }
            render(view).set("Dev").on_enter()
            opened.on_accept({ name = "Dev", mappings = opened.mappings })
            assert.same({ { method = "ConfigSets/1.update", args = { config_set = { id = "cs:1" }, name = "Dev",
                mappings = { { project = { id = "pr:1" }, configuration = { id = "c:1" } },
                    { project = { id = "pr:2" }, configuration = { id = "c:9" } } } } } }, obs.requests)
        end)

        it("delete: the confirmation lists the profiles of the set by config_set_id", function()
            local shown
            local saved_dialog = package.loaded["loomworks.ui.dialog"]
            package.loaded["loomworks.ui.dialog"] = { show = function(o) shown = o end }
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {
                { id = "p:1", key = "mine", config_set = "Other", config_set_id = "cs:1" },
                { id = "p:2", key = "theirs", config_set = "Dev", config_set_id = "cs:7" },
                { id = "p:3", key = "lost", config_set = "Dev", orphaned_set = true } } }
            local opts = render(view).set("Dev")
            local ok, err = pcall(opts.on_delete)
            package.loaded["loomworks.ui.dialog"] = saved_dialog
            assert.is_true(ok, tostring(err))
            local text = table.concat(shown.lines, "\n")
            assert.is_truthy(text:find("    mine", 1, true), text)
            assert.is_nil(text:find("theirs", 1, true), text)
            assert.is_nil(text:find("lost", 1, true), text)
        end)

        it("create: the templates are ConfigSets/1.candidates' automatic sets; a pick adds { candidate }", function()
            local view = { config_sets = { SET }, projects = { APP, LIB }, profiles = {} }
            obs.answer = { outcome = "ok", sets = {
                { config_set = "cs:1", name = "Dev", auto = false },
                { name = "Release", auto = true, candidate = "auto:abc", mappings = {
                    { project = { id = "pr:1", key = "app" }, configuration = { id = "c:2", key = "Release" } } } } } }
            local saved_select, offered = vim.ui.select, nil
            vim.ui.select = function(items, o, cb)
                offered = {}
                for _, it in ipairs(items) do offered[#offered + 1] = o.format_item(it) end
                cb(items[1])
            end
            local ok, err = pcall(function() render(view).item("Create configuration set").on_enter() end)
            vim.ui.select = saved_select
            assert.is_true(ok, tostring(err))
            assert.same({ "Release (app → Release)", "Custom..." }, offered)
            assert.same({ { method = "ConfigSets/1.candidates", args = {} },
                { method = "ConfigSets/1.add", args = { candidate = "auto:abc" } } }, obs.requests)
        end)

        it("create (custom): the dialog lists the view's projects, nothing mapped", function()
            local view = { config_sets = {}, projects = { APP, LIB }, profiles = {} }
            -- (No automatic set: straight to the custom dialog.)
            obs.answer = { outcome = "ok", sets = {} }
            render(view).item("Create configuration set").on_enter()
            obs.answer = nil
            assert.is_table(opened)
            assert.same({ APP, LIB }, opened.projects)
            assert.same({}, opened.mappings)
            assert.same({ "Debug" }, { opened.available_configs[LIB][1].name })
            local m = {}
            m[LIB] = opened.available_configs[LIB][1]
            opened.on_accept({ name = "New", mappings = m })
            assert.same({ { method = "ConfigSets/1.candidates", args = {} }, { method = "ConfigSets/1.add",
                args = { name = "New", mappings = { { project = { id = "pr:2" }, configuration = { id = "c:3" } } } } } },
                obs.requests)
        end)
    end)

    describe("Debug Adapters section", function()
        local function render(records)
            obs.debug_adapters = function() return records end
            local tree, nodes = fake_tree()
            package.loaded["loomworks.ui.sections.debug"] = nil
            require("loomworks.ui.sections.debug")(tree, { lw = { get_workspace = function() return ws end } })
            local labels = {}
            for _, n in ipairs(nodes) do labels[#labels + 1] = n.label end
            return labels
        end

        it("lists the languages of the daemon's DebugConfig/1.adapters records, never the model's modules", function()
            local labels = render({
                { language = "typescript", adapter = "pwa-node", default = "pwa-node", known = { "pwa-node" } },
                { language = "c++", adapter = "cppdbg", default = "codelldb", known = { "codelldb", "cppdbg" },
                    overridden = true },
                { language = "rust", known = {} },
            })
            assert.equals("Debug Adapters", labels[1])
            assert.equals("c++  →  cppdbg", labels[2])
            assert.equals("typescript  →  pwa-node  (default)", labels[3])
            -- A language with neither an adapter nor a default is not shown.
            for _, l in ipairs(labels) do assert.is_nil(l:find("rust", 1, true), l) end
        end)

        it("no records: no section", function()
            assert.same({}, render({}))
        end)

        it("unavailable: the reason, from the daemon's state", function()
            obs.carried = false
            local labels = render(nil)
            assert.equals("Debug Adapters", labels[1])
            assert.truthy(labels[2]:find("^unavailable"), labels[2])
        end)
    end)
end)

describe("configuration set dialogs offer cmake presets (WP-B)", function()
    -- A preset configuration (`preset:<name>`, cmake) is a real
    -- configuration of its project: the view lists it under the project
    -- row's `presets`, not `configurations[]`. The dialogs offer it, and a
    -- mapping to it saves by the preset row's id.
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

    it("daemon: the view's presets are offered and a preset mapping is sent by its id", function()
        local obs = fake_obs()
        local ws = trap_ws(obs)
        local APP = { id = "pr:1", key = "App", configurations = { { id = "c:1", key = "Dev" } },
            presets = { { id = "c:2", name = "preset:dev", generator = "Ninja" } } }
        local SET = { id = "cs:1", name = "P", mappings = { { project = { id = "pr:1", key = "App" },
            configuration = { id = "c:2", key = "preset:dev" }, missing = false } } }
        local view = { config_sets = { SET }, projects = { APP }, profiles = {} }
        render({ mode = "daemon", view = view, ws = ws, lw = {} }).set("P").on_enter()
        assert.same({ "Dev", "preset:dev" }, names(opened.available_configs[APP]))
        -- The set's preset mapping is the offered preset choice.
        assert.equals(opened.available_configs[APP][2], opened.mappings[APP])
        opened.on_accept({ name = "P2", mappings = opened.mappings })
        assert.same({ { method = "ConfigSets/1.update",
            args = { config_set = { id = "cs:1" }, name = "P2",
                mappings = { { project = { id = "pr:1" }, configuration = { id = "c:2" } } } } } }, obs.requests)
    end)

    it("no view held: the dialogs refuse with a notice, nothing opened", function()
        local obs = fake_obs()
        local SET = { id = "cs:1", name = "P", mappings = {} }
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

describe("the profile row's + Add tool (protocol ids)", function()
    local saved_notify, saved_select, offered
    before_each(function()
        saved_notify, saved_select, offered = vim.notify, vim.ui.select, nil
        vim.notify = function() end
        vim.ui.select = function(items, o, cb)
            offered = {}
            for _, it in ipairs(items) do offered[#offered + 1] = o.format_item(it) end
            cb(items[1])
        end
    end)
    after_each(function() vim.notify, vim.ui.select = saved_notify, saved_select end)

    local function add_tool(ws, row)
        local tree, nodes = fake_tree()
        package.loaded["loomworks.ui.sections.profiles"] = nil
        require("loomworks.ui.sections.profiles")(tree, { mode = "daemon", ws = ws, lw = {},
            view = { profiles = { row }, projects = { { id = "pr:1", key = "app" } }, config_sets = {} } })
        for _, n in ipairs(nodes) do
            if n.label == "+ Add tool" then return n.opts end
        end
    end
    local function profile_row(extra)
        local row = { id = "p:1", key = "dev:gcc", label = "dev:gcc", status = "built", units = {},
            intent = "local", config_set = "dev", config_set_id = "cs:1",
            toolchain = { { key = "gcc", label = "GCC", resolved = true, languages = {} } } }
        for k, v in pairs(extra or {}) do row[k] = v end
        return row
    end

    it("daemon: asks tool_choices of the row's set by config_set_id, offers the module toolchains it lacks", function()
        local obs = fake_obs()
        obs.answer = { outcome = "ok", tools = {
            { module = "cmake", key = "gcc", label = "GCC" },
            { sdk = true, key = "ohos-1", label = "OHOS" },
            { module = "cmake", key = "ohos-clang", label = "OHOS clang", sdk_key = "ohos-1" },
            { module = "cmake", key = "clang", label = "Clang" } } }
        local opts = assert(add_tool(trap_ws(obs), profile_row()))
        opts.on_enter()
        assert.same({ "Clang", "OHOS clang" }, offered)
        assert.same({ method = "Profiles/1.tool_choices", args = { config_set = { id = "cs:1" } } }, obs.requests[1])
        assert.same({ method = "Profiles/1.add_tool", args = { profile = { id = "p:1" }, tool = "clang" } },
            obs.requests[2])
    end)

    it("is hidden for a profile whose set is orphaned", function()
        local obs = fake_obs()
        assert.is_nil(add_tool(trap_ws(obs), profile_row({ orphaned_set = true })))
    end)

end)

describe("the create-profile tool picker (protocol ids)", function()
    local saved_notify, saved_select, offered
    before_each(function()
        saved_notify, saved_select, offered = vim.notify, vim.ui.select, nil
        vim.notify = function() end
        vim.ui.select = function(items, o, cb)
            offered = {}
            for _, it in ipairs(items) do offered[#offered + 1] = o.format_item(it) end
            cb(items[1])
        end
    end)
    after_each(function()
        vim.notify, vim.ui.select = saved_notify, saved_select
        local observer = require("loomworks.daemon.observer")
        observer._current, observer._attached_root = nil, nil
    end)

    it("skips the SDKs' kit toolchains (sdk_key): the SDK's own entry stands for them", function()
        local obs = fake_obs()
        obs.answer = { outcome = "ok", tools = {
            { module = "cmake", key = "gcc", label = "GCC" },
            { sdk = true, key = "ohos-1", label = "OHOS" },
            { module = "cmake", key = "ohos-clang", label = "OHOS clang", sdk_key = "ohos-1" },
            { module = "cmake", key = "clang", label = "Clang" } } }
        require("loomworks.ui.actions")._create_profile_step2(trap_ws(obs), { id = "cs:1", name = "dev" }, false)
        assert.same({ "GCC", "OHOS", "Clang", "(no tool — incomplete profile)" }, offered)
        assert.same({ method = "Profiles/1.tool_choices", args = { config_set = { id = "cs:1" } } }, obs.requests[1])
        assert.equals("Profiles/1.create", obs.requests[2].method)
    end)
end)

describe("configuration rename effects (protocol ids)", function()
    -- The configuration editor's rename effects: the sets whose mapping
    -- names the renamed configuration (helpers.same_entity: its id; never
    -- its name) and the
    -- declaration's configurations inheriting it.
    local saved_dialog, saved_notify, opened
    before_each(function()
        opened = nil
        saved_dialog = package.loaded["loomworks.ui.config_editor_dialog"]
        package.loaded["loomworks.ui.config_editor_dialog"] = { open = function(o) opened = o end }
        saved_notify = vim.notify
        vim.notify = function() end
    end)
    after_each(function()
        package.loaded["loomworks.ui.config_editor_dialog"] = saved_dialog
        vim.notify = saved_notify
        local observer = require("loomworks.daemon.observer")
        observer._current, observer._attached_root = nil, nil
    end)

    local function open_editor(ctx, project_key, config_key)
        local tree, nodes = fake_tree()
        tree.width = 100
        function tree:_pad() return "" end
        package.loaded["loomworks.ui.sections.projects"] = nil
        require("loomworks.ui.sections.projects")(tree, ctx)
        local opts
        for _, n in ipairs(nodes) do
            if n.opts and n.opts.fold_key == "config:" .. project_key .. ":" .. config_key then opts = n.opts end
        end
        assert.is_table(opts, "the configuration row")
        opts.on_enter()
        assert.is_table(opened, "the configuration editor")
        return opened
    end

    it("daemon: lists the sets mapping the configuration by its id, and its inheritors", function()
        local obs = fake_obs()
        local function project_row(id, key, configurations)
            return { id = id, key = key, type = "cmake", path = key, intent = "local", launches = {}, deploy = {},
                variables = {}, type_config = { fields = {} }, configurations = configurations }
        end
        local APP = project_row("pr:1", "App", { { id = "c:1", key = "Debug", intent = "local", user = true },
            { id = "c:2", key = "Child", intent = "local", user = true } })
        local LIB = project_row("pr:2", "Lib", { { id = "c:3", key = "Debug", intent = "local", user = true } })
        local function mapping(p, c) return { project = { id = p.id, key = p.key },
            configuration = { id = c.id, key = c.key }, missing = false } end
        local view = { projects = { APP, LIB }, profiles = {}, config_sets = {
            { id = "cs:1", name = "Both", mappings = { mapping(APP, APP.configurations[1]),
                mapping(LIB, LIB.configurations[1]) } },
            { id = "cs:2", name = "LibOnly", mappings = { mapping(LIB, LIB.configurations[1]) } } } }
        obs.answer = { outcome = "ok", configurations = {
            { id = "c:1", key = "Debug", user = true, fields = {} },
            { id = "c:2", key = "Child", user = true, fields = { inherits = "Debug" } } } }
        trap_ws(obs)
        local o = open_editor({ mode = "daemon", view = view, lw = {} }, "App", "Debug")
        assert.same({ "Config set 'Both' mapping → Dbg", "Config 'Child' inherits → Dbg" }, o.rename_effects("Dbg"))
        -- No rename, no effects.
        assert.is_nil(o.rename_effects("Debug"))
        assert.is_nil(o.rename_effects(""))
    end)

end)

describe("status page actions in daemon mode with no model (A1a)", function()
    local obs, saved_notify, saved_get, saved_select
    before_each(function()
        obs = fake_obs()
        function obs:workspace_view() return self.view end
        function obs:tasks() return {} end
        function obs:_clock() return 0 end
        trap_ws(obs)
        saved_notify = vim.notify
        vim.notify = function() end
        -- The `daemon`-mode editor holds no model.
        local lw = require("loomworks")
        saved_get = lw.get_workspace
        lw.get_workspace = function() return nil end
        saved_select = vim.ui.select
        vim.ui.select = function() end
    end)
    after_each(function()
        vim.notify = saved_notify
        require("loomworks").get_workspace = saved_get
        vim.ui.select = saved_select
        local observer = require("loomworks.daemon.observer")
        observer._current, observer._attached_root = nil, nil
    end)

    local function methods()
        local out = {}
        for _, r in ipairs(obs.requests) do out[#out + 1] = r.method end
        return out
    end

    it("create profile asks the daemon's ConfigSets/1.candidates", function()
        obs.answer = { outcome = "ok", sets = {} }
        require("loomworks.ui.actions").create_profile({ view = { profiles = {} } })()
        assert.same({ "ConfigSets/1.candidates" }, methods())
    end)

    it("a project row offers P, publish and revert, each sent by the row", function()
        local prow = { id = "pr:1", key = "app", type = "cmake", intent = "local", configurations = {} }
        local nodes = {}
        local tree = setmetatable({}, { __index = function() return function() end end })
        function tree:node(label, opts) nodes[#nodes + 1] = { label = label, opts = opts } end
        package.loaded["loomworks.ui.sections.projects"] = nil
        require("loomworks.ui.sections.projects")(tree, { mode = "daemon", view = { projects = { prow } }, lw = {} })
        local opts
        for _, n in ipairs(nodes) do
            if n.opts and n.opts.fold_key == "project:app" then opts = n.opts end
        end
        assert.is_table(opts)
        assert.is_function(opts.on_publish)
        assert.is_function(opts.on_publish_now)
        assert.is_function(opts.on_revert_one)
        opts.on_publish()
        opts.on_publish_now()
        opts.on_revert_one()
        assert.same({ "Workspace/1.set_intent", "Workspace/1.publish_one", "Workspace/1.revert_one" }, methods())
        assert.same({ id = "pr:1" }, { id = obs.requests[1].args.item.id })
    end)

    describe("the project browser", function()
        local root, tree, saved_new
        before_each(function()
            root = vim.fs.normalize(vim.fn.tempname())
            vim.fn.mkdir(root, "p")
            local View = require("loomworks.ui.view")
            saved_new = View.new
            View.new = function(vopts)
                tree = vopts.widget
                return { open = function() end, close = function() end, refresh = function() end,
                    is_open = function() return true end }
            end
        end)
        after_each(function()
            require("loomworks.ui.view").new = saved_new
            vim.fn.delete(root, "rf")
        end)

        local function root_meta()
            local lines = tree:render()
            for i, l in ipairs(lines) do
                if l:find(root:match("([^/]+)$"), 1, true) and tree.line_meta[i] then return tree.line_meta[i] end
            end
            error(table.concat(lines, "\n"))
        end

        it("shows a directory's types as Projects/1.candidates detects them", function()
            obs.view = { projects = {} }
            obs.answer = { outcome = "ok", key = "app", path = ".", types = { { type = "cmake", marker = "CMakeLists.txt" } } }
            require("loomworks.ui.project_browser").open(root)
            assert.same({ "Projects/1.candidates" }, methods())
            assert.equals(root, obs.requests[1].args.path)
            assert.truthy(table.concat(tree:render(), "|"):find("[cmake: CMakeLists.txt]", 1, true))
        end)

        it("adds a project through Projects/1.candidates and Projects/1.add", function()
            obs.view = { projects = {} }
            obs.answer = { outcome = "ok", key = "app", path = "." }
            require("loomworks.ui.project_browser").open(root)
            obs.requests = {} -- (the root's detection)
            vim.ui.select = function(items, _, cb)
                for _, it in ipairs(items) do
                    if it.label == "Add as shell (custom)" then return cb(it) end
                end
            end
            local ok, err = pcall(function() root_meta().on_enter() end)
            assert(ok, err)
            assert.same({ "Projects/1.candidates", "Projects/1.add" }, methods())
        end)

        it("removes a project by its view row (Maintenance/1.execute_deletion)", function()
            obs.view = { projects = { { id = "pr:1", key = "app", type = "shell", path = "." } } }
            require("loomworks.ui.project_browser").open(root)
            obs.requests = {} -- (the root's detection)
            local meta = root_meta()
            assert.is_function(meta.on_delete)
            meta.on_delete()
            assert.same({ "Maintenance/1.execute_deletion" }, methods())
        end)
    end)
end)

describe("the Add project row in daemon mode with no model (A1a)", function()
    it("opens the project browser at the observed root", function()
        local observer = require("loomworks.daemon.observer")
        local obs = { root = "/ws/root", state = "connected" }
        observer._current = obs
        observer._attached_root = "/w"
        local lw = require("loomworks")
        local saved_get = lw.get_workspace
        lw.get_workspace = function() return nil end
        local saved_browser = package.loaded["loomworks.ui.project_browser"]
        local opened
        package.loaded["loomworks.ui.project_browser"] = { open = function(root) opened = root end }
        local add
        local tree = setmetatable({}, { __index = function() return function() end end })
        function tree:item(label, opts) if label == "▸ Add project" then add = opts end end
        package.loaded["loomworks.ui.sections.projects"] = nil
        local ok, err = pcall(function()
            require("loomworks.ui.sections.projects")(tree, { mode = "daemon", view = { projects = {} }, lw = {} })
            add.on_enter()
        end)
        lw.get_workspace = saved_get
        package.loaded["loomworks.ui.project_browser"] = saved_browser
        observer._current, observer._attached_root = nil, nil
        assert(ok, err)
        assert.equals("/ws/root", opened)
    end)
end)
