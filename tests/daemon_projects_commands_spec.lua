-- loomworks.Projects/1 in the daemon (API.md §19, spec daemon.md §19.14 "As
-- interfaces"; step 5o part B3): candidates, add, declaration,
-- configuration_save / _remove, options_save, launch_save / _remove,
-- deploy_save, variable_save / _remove, type_config_set, expand_preview and
-- unit_options (step 5o C2d),
-- called over transport 11 against an in-process server with the build
-- service attached and a real `shell` workspace. References resolve to the
-- live objects at the boundary (an id, or a key with the project); the write
-- goes through loomworks.model_commands; a configuration rename takes the
-- workspace operation lock O, a launch rename does not.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local server_mod = require("loomworks.daemon.server")
local service = require("loomworks.daemon.service")
local client = require("loomworks.daemon.client")
local envscope = require("loomworks.daemon.envscope")
local trust = require("loomworks.trust")
local op_lock = require("loomworks.op_lock")
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")

client.TIMEOUT_MS = 30000

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return s
end

--- The decoded working copy (its signature stripped).
local function working_copy(root)
    local _, content = trust.verify("user", read(root .. "/.nvim/loomworks.user.json"))
    return vim.json.decode(content)
end

describe("loomworks.Projects/1 (step 5o part B3)", function()
    local root, srv, conn
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.shell_workspace({ profile = true, launch = { run = { command = "tool", args = { "-v" } } } })
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        service.attach(srv, cli._daemon_build_host())
        assert(srv:start())
        conn = assert(client.session(srv.address, {}))
    end)
    after_each(function()
        L.cleanup()
        if conn then pcall(conn.close, conn) end
        if srv and not srv.stopped then srv:stop("test end", 0) end
        pcall(function() require("loomworks")._core():shutdown() end)
        trust._set_key_path(nil)
    end)

    --- A Projects/1 call: its result (or error).
    local function call(method, args)
        local r, e
        conn:call("/projects", "loomworks.Projects", 1, method, args or {}, function(res, err) r, e = res, err end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return r ~= nil or e ~= nil end, 10), method .. " never answered")
        return r, e
    end

    --- Load the model (a snapshot) and give the live workspace.
    local function loaded()
        local done
        conn:call("/internal", "lw.internal.Snapshot", 1, "get", { scope = "config" }, function() done = true end,
            envscope.capture())
        assert.is_true(vim.wait(60000, function() return done end, 10))
        return assert(srv.service.ws)
    end

    local function id_of(obj) return srv.service.ids:id(obj) end
    local function project(ws, key)
        for _, p in pairs(ws._projects) do if p.key == (key or "app") then return p end end
    end
    local APP = { key = "app" }

    it("declaration gives the configurations and launches with their ids", function()
        local ws = loaded()
        local app = project(ws)
        local r, e = call("declaration", { project = { id = id_of(app) } })
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals(1, #r.launches)
        assert.same({ id = id_of(app._launches.run), key = "run", fields = { command = "tool", args = { "-v" } } },
            r.launches[1])
        local debug
        for _, c in ipairs(r.configurations) do if c.key == "Debug" then debug = c end end
        assert.equals(id_of(app:get_configuration("Debug")), debug.id)
        local names = {}
        for _, f in ipairs(r.type_config.fields) do names[#names + 1] = f.name end
        assert.is_truthy(vim.tbl_contains(names, "build_dir"), vim.inspect(names))
    end)

    it("configuration_save creates one, then renames it by id (id kept, sets follow)", function()
        local ws = loaded()
        local r = call("configuration_save", { project = APP, name = "Fast", fields = { options = { O = "2" } } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("Fast", r.configuration.key)
        local id = r.configuration.id
        assert.same({ O = "2" }, working_copy(root).projects.app.shell.configurations.Fast.options)
        r = call("configuration_save", { project = APP, configuration = { id = id }, name = "Faster",
            fields = { options = { O = "3" } } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ id = id, key = "Faster" }, r.configuration)
        assert.equals("Faster", project(ws):get_configuration("Faster").name)
        assert.is_nil(op_lock.read(root), "O left behind")
        r = call("configuration_remove", { project = APP, configuration = { key = "Faster" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(working_copy(root).projects.app.shell.configurations.Faster)
    end)

    it("a configuration rename is refused while another process holds O; nothing changes", function()
        loaded()
        local r = call("configuration_save", { project = APP, name = "Fast", fields = vim.empty_dict() })
        assert.equals("ok", r.outcome, vim.inspect(r))
        local before = read(root .. "/.nvim/loomworks.user.json")
        local h = L.hold(op_lock.path(root), "import")
        r = call("configuration_save", { project = APP, configuration = { id = r.configuration.id }, name = "Slow",
            fields = vim.empty_dict() })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.matches("pid " .. h.pid, r.message, 1, true)
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)

    it("launch_save renames by id (id kept) without O, and creates by name", function()
        local ws = loaded()
        local launch = project(ws)._launches.run
        local id = id_of(launch)
        L.hold(op_lock.path(root), "import")
        local r = call("launch_save", { project = APP, launch = { id = id }, name = "go",
            data = { command = "tool", args = { "-q" } } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ id = id, key = "go" }, r.launch)
        local decl = working_copy(root).projects.app.launch
        assert.is_nil(decl.run)
        assert.same({ "-q" }, decl.go.args)
        r = call("launch_save", { project = APP, name = "other", data = { command = "x" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("other", r.launch.key)
        r = call("launch_remove", { project = APP, launch = { key = "other" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_nil(working_copy(root).projects.app.launch.other)
    end)

    it("add declares a project; a launch id of another project is refused", function()
        local ws = loaded()
        vim.fn.mkdir(root .. "/lib", "p")
        local r = call("add", { key = "lib", type = "shell", path = "lib", mappings = vim.empty_dict() })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("lib", r.project.key)
        assert.equals(id_of(project(ws, "lib")), r.project.id)
        r = call("launch_remove", { project = { id = r.project.id }, launch = { id = id_of(project(ws)._launches.run) } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("launch configuration 'app:run' is not of project 'lib'", r.message)
        r = call("add", { key = "x", type = "nope" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
    end)

    it("add refuses a path outside the root (exit 2) and a missing directory", function()
        local ws = loaded()
        local r = call("add", { key = "out", type = "shell", path = "../elsewhere" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
        local outside = H.tmp() .. "/outside_add"
        vim.fn.mkdir(outside, "p")
        r = call("add", { key = "out", type = "shell", path = outside })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
        -- A missing path whose `..` leaves the root is outside, not missing.
        r = call("add", { key = "out", type = "shell", path = root .. "/../no_such_dir" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
        r = call("add", { key = "missing", type = "shell", path = "missing" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no directory 'missing'", r.message)
        -- No path: the directory named by the key.
        r = call("add", { key = "nokeydir", type = "shell" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.is_nil(project(ws, "out"))
        assert.is_nil(project(ws, "missing"))
        assert.is_nil(project(ws, "nokeydir"))
        -- An absolute path under the root is stored relative to it.
        vim.fn.mkdir(root .. "/libs/net", "p")
        r = call("add", { key = "net", type = "shell", path = root .. "/libs/net" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("libs/net", project(ws, "net").path)
    end)

    it("variables, options, deploy and type_config fields", function()
        local ws = loaded()
        local r = call("variable_save", { project = APP, name = "out", data = { type = "path", default = "bin" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        r = call("variable_save", { project = APP, variable = "out", name = "dest", data = { type = "path", default = "b" } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ dest = { type = "path", default = "b" } }, project(ws).variables)
        r = call("variable_remove", { project = APP, variable = "out" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("ok", call("variable_remove", { project = APP, variable = "dest" }).outcome)
        assert.equals("ok", call("options_save", { project = APP, options = { A = "1" } }).outcome)
        assert.same({ A = "1" }, working_copy(root).projects.app.shell.options)
        r = call("deploy_save", { project = APP, deploy = { ["${build_dir}/x"] = { project = "app", path = "x" } } })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.is_not_nil(project(ws).deploy["${build_dir}/x"])
        assert.equals("ok", call("deploy_save", { project = APP }).outcome)
        assert.is_nil(project(ws).deploy)
        r = call("type_config_set", { project = APP, field = "clangd", value = "my-clangd" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("my-clangd", working_copy(root).projects.app.shell.clangd)
        r = call("type_config_set", { project = APP, field = "configurations", value = "x" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
    end)

    it("candidates derives the key and path; a path outside the root is refused", function()
        loaded()
        vim.fn.mkdir(root .. "/libs/net", "p")
        local r, e = call("candidates", { path = "libs/net", type = "shell" })
        assert.is_nil(e, vim.inspect(e))
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("libs_net", r.key)
        assert.equals("libs/net", r.path)
        r = call("candidates", { path = root .. "/app" })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.equals("app", r.key)
        r = call("candidates", { path = "../elsewhere" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
    end)

    it("candidates and add { tool } detect a keyed module's toolchains off the model queue", function()
        local ws = loaded()
        vim.fn.mkdir(root .. "/libs/net", "p")
        -- The shell module as a keyed one whose toolchains the workspace has
        -- not detected: the synchronous detection must not run in the
        -- daemon; the async one is held open while other calls are served.
        local shell = require("loomworks.modules").get("shell")
        local saved = {}
        for _, k in ipairs({ "has_keyed_tools", "detect_tools", "detect_tools_async", "tool_key", "tool_label" }) do
            saved[k] = shell[k] or false
        end
        local sync_called, pending = false, {}
        shell.has_keyed_tools = true
        shell.detect_tools = function() sync_called = true; return {} end
        shell.detect_tools_async = function(cb) pending[#pending + 1] = cb end
        shell.tool_key = function(td) return td and td.id or nil end
        shell.tool_label = function(td) return td and ("kit " .. td.id) or nil end
        local ok, err = pcall(function()
            ws._tools_by_type.shell = nil
            local r
            conn:call("/projects", "loomworks.Projects", 1, "candidates", { path = "libs/net", type = "shell" },
                function(res, e) r = res or e end, envscope.capture())
            assert.is_true(vim.wait(30000, function() return #pending > 0 or sync_called or r ~= nil end, 10))
            assert.is_false(sync_called, "the daemon detected the toolchains synchronously")
            assert.equals(1, #pending)
            -- Meanwhile the daemon answers another client's call.
            local d = call("declaration", { project = APP })
            assert.equals("ok", d.outcome, vim.inspect(d))
            assert.is_nil(r)
            pending[1]({ { tool_data = { id = "k1" } } })
            assert.is_true(vim.wait(30000, function() return r ~= nil end, 10), "candidates never answered")
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.same({ { key = "k1", label = "kit k1" } }, r.tools)

            local a
            conn:call("/projects", "loomworks.Projects", 1, "add",
                { key = "net", type = "shell", path = "libs/net", tool = { key = "k1" } },
                function(res, e) a = res or e end, envscope.capture())
            assert.is_true(vim.wait(30000, function() return #pending > 1 or sync_called or a ~= nil end, 10))
            assert.is_false(sync_called, "add detected the toolchains synchronously")
            pending[2]({ { tool_data = { id = "k1" } } })
            assert.is_true(vim.wait(30000, function() return a ~= nil end, 10), "add never answered")
            assert.equals("ok", a.outcome, vim.inspect(a))
            assert.equals("net", a.project.key)
        end)
        for k, v in pairs(saved) do shell[k] = v ~= false and v or nil end
        assert(ok, err)
    end)

    it("candidates refuses a link inside the root that resolves outside it", function()
        loaded()
        local outside = H.tmp() .. "/outside"
        vim.fn.mkdir(outside, "p")
        local link = root .. "/escape"
        if vim.fn.has("win32") == 1 then
            vim.fn.system({ "cmd", "/c", "mklink", "/J", (link:gsub("/", "\\")), (outside:gsub("/", "\\")) })
        else
            vim.uv.fs_symlink(outside, link)
        end
        if vim.fn.isdirectory(link) ~= 1 then
            pending("could not create a junction/symlink")
            return
        end
        local r = call("candidates", { path = "escape" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
        r = call("candidates", { path = link })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(2, r.exit_code)
        r = call("candidates", { path = "missing" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no directory 'missing'", r.message)
    end)

    it("expand_preview expands under the profile named; an unresolved reference stays", function()
        loaded()
        local templates = { "${project_path}/x", "${no_such_var}" }
        local r = call("expand_preview", { project = APP, templates = templates })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no active profile; name a profile", r.message)
        r = call("expand_preview", { project = APP, profile = { key = "dev" }, templates = templates })
        assert.equals("ok", r.outcome, vim.inspect(r))
        assert.same({ "app/x", "${no_such_var}" }, r.values)
    end)

    it("unit_options reads a configured unit's build options by id; refused unconfigured, being deleted, without options or stale (5o C2d)",
        function()
        local ws = loaded()
        local unit = assert(ws._profiles[1]:projects()[1]._config_unit, "the profile's unit")
        local id = id_of(unit)
        local label = unit._project.key .. "/" .. unit:config_key()
        -- Not configured: refused.
        local saved_state = unit.state_value
        unit.state_value = nil
        local r = call("unit_options", { unit = { id = id } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("configuration unit " .. label .. " is not configured", r.message)
        -- Configured, but the module (shell) has no get_options: refused.
        unit.state_value = "configured"
        r = call("unit_options", { unit = { id = id } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("configuration unit " .. label .. " has no build options", r.message)
        -- A module with options: the tree, as ConfigUnit:options() gives it.
        local impl = unit._project._module.impl
        local tree = { { label = "Cache", children = {
            { key = "OPT", value = "ON", value_type = "bool", helpstring = "an option" },
            { key = "MODE", value = "a", value_type = "string", choices = { "a", "b" } } } } }
        local seen_dir
        impl.get_options = function(bd) seen_dir = bd; return tree end
        local ok, err = pcall(function()
            -- Being deleted (its build dir may be mid rm-rf): refused, the
            -- build dir not read.
            unit:mark_deleting(true)
            r = call("unit_options", { unit = { id = id } })
            unit:mark_deleting(false)
            assert.equals("refused", r.outcome, vim.inspect(r))
            assert.equals("configuration unit " .. label .. " is being deleted", r.message)
            assert.is_nil(seen_dir)
            r = call("unit_options", { unit = { id = id } })
            assert.equals("ok", r.outcome, vim.inspect(r))
            assert.same(tree, r.options)
            assert.equals(unit:build_dir(), seen_dir)
        end)
        impl.get_options = nil
        unit.state_value = saved_state
        assert(ok, err)
        -- A stale id: refused.
        r = call("unit_options", { unit = { id = "999.999" } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no configuration unit with id 999.999 (a stale reference)", r.message)
    end)

    it("unit_options reads through the module's get_options_async off the model queue: other requests answer meanwhile; its spawns run in the client's environment (spec §8)",
        function()
        local ws = loaded()
        local unit = assert(ws._profiles[1]:projects()[1]._config_unit, "the profile's unit")
        local id = id_of(unit)
        local label = unit._project.key .. "/" .. unit:config_key()
        local saved_state = unit.state_value
        unit.state_value = "configured"
        local impl = unit._project._module.impl
        local tree = { { label = "User options", children = { { key = "x", value = "1", value_type = "string" } } } }
        local pending
        impl.get_options = function() error("the daemon read the options synchronously") end
        impl.get_options_async = function(bd, config, cb, opts)
            pending = { bd = bd, config = config, cb = cb, opts = opts }
        end
        vim.env.LW_OPTS_PROBE = "client"
        local ok, err = pcall(function()
            local r1
            conn:call("/projects", "loomworks.Projects", 1, "unit_options", { unit = { id = id } },
                function(res, e) r1 = res or e end, envscope.capture())
            vim.env.LW_OPTS_PROBE = nil
            assert.is_true(vim.wait(5000, function() return pending ~= nil end, 10), "get_options_async never called: " .. vim.inspect(r1))
            assert.equals(unit:build_dir(), pending.bd)
            -- The read is pending: another model request answers meanwhile.
            local d = call("declaration", { project = APP })
            assert.equals("ok", d.outcome, vim.inspect(d))
            assert.is_nil(r1, "unit_options answered before its read finished")
            -- opts.system spawns in the client's environment.
            assert.is_function(pending.opts and pending.opts.system)
            local cmd = vim.fn.has("win32") == 1 and { "cmd.exe", "/d", "/c", "echo %LW_OPTS_PROBE%" }
                or { "sh", "-c", "echo $LW_OPTS_PROBE" }
            local res
            pending.opts.system(cmd, { text = true }, function(o) res = o end)
            assert.is_true(vim.wait(30000, function() return res ~= nil end, 10))
            assert.equals(0, res.code, vim.inspect(res))
            assert.equals("client", vim.trim(res.stdout))
            -- The read finishes: the reply carries its tree.
            pending.cb(tree)
            assert.is_true(vim.wait(60000, function() return r1 ~= nil end, 10), "unit_options never answered")
            assert.equals("ok", r1.outcome, vim.inspect(r1))
            assert.same(tree, r1.options)
            -- A read that finds nothing: refused.
            pending = nil
            local r2
            conn:call("/projects", "loomworks.Projects", 1, "unit_options", { unit = { id = id } },
                function(res2, e) r2 = res2 or e end, envscope.capture())
            assert.is_true(vim.wait(60000, function() return pending ~= nil end, 10))
            pending.cb(nil)
            assert.is_true(vim.wait(60000, function() return r2 ~= nil end, 10))
            assert.equals("refused", r2.outcome, vim.inspect(r2))
            assert.equals("configuration unit " .. label .. " has no build options", r2.message)
        end)
        vim.env.LW_OPTS_PROBE = nil
        impl.get_options, impl.get_options_async = nil, nil
        unit.state_value = saved_state
        assert(ok, err)
    end)

    describe("unit_options with a pending read", function()
        local ws, unit, impl, saved_state, pending, id
        before_each(function()
            ws = loaded()
            unit = assert(ws._profiles[1]:projects()[1]._config_unit, "the profile's unit")
            id = id_of(unit)
            saved_state = unit.state_value
            unit.state_value = "configured"
            impl = unit._project._module.impl
            pending = nil
            impl.get_options_async = function(_, _, cb) pending = cb end
        end)
        after_each(function()
            impl.get_options_async = nil
            unit.state_value = saved_state
        end)

        local function start()
            local box = {}
            conn:call("/projects", "loomworks.Projects", 1, "unit_options", { unit = { id = id } },
                function(res, e) box.r = res or e end, envscope.capture())
            assert.is_true(vim.wait(5000, function() return pending ~= nil end, 10), "get_options_async never called")
            return box
        end

        it("the later reply keeps the notes the segment gathered", function()
            local svc = srv.service
            local orig_live = svc.live
            svc.live = function(self, c, ...)
                local a, b, d = orig_live(self, c, ...)
                c.notes, c.note_roles = { "a note from the segment" }, { "warn" }
                return a, b, d
            end
            local ok, err = pcall(function()
                local box = start()
                svc.live = orig_live
                pending({ { label = "G", children = { { key = "k", value = "v", value_type = "string" } } } })
                assert.is_true(vim.wait(10000, function() return box.r ~= nil end, 10))
                assert.equals("ok", box.r.outcome, vim.inspect(box.r))
                assert.same({ "a note from the segment" }, box.r.notes)
                assert.same({ "warn" }, box.r.note_roles)
            end)
            svc.live = orig_live
            assert(ok, err)
        end)

        it("a client gone while the read is pending: the read's end sends nothing and raises nothing", function()
            start()
            local server_conns = {}
            for c in pairs(srv.conns) do server_conns[#server_conns + 1] = c end
            conn:close()
            conn = nil
            assert.is_true(vim.wait(10000, function()
                for _, c in ipairs(server_conns) do if not c.closed then return false end end
                return true
            end, 10), "the server never saw the client go")
            local sent = 0
            local orig_send = srv._send
            srv._send = function(self, c, msg, cb)
                for _, sc in ipairs(server_conns) do if sc == c then sent = sent + 1 end end
                return orig_send(self, c, msg, cb)
            end
            local ok, err = pcall(pending, { { label = "G", children = {} } })
            vim.wait(200)
            srv._send = orig_send
            assert(ok, err)
            assert.equals(0, sent)
        end)
    end)

    it("a stale id or an unknown key is refused and changes nothing", function()
        loaded()
        local before = read(root .. "/.nvim/loomworks.user.json")
        local r = call("options_save", { project = { id = "999.999" }, options = { A = "1" } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no project with id 999.999 (a stale reference)", r.message)
        r = call("configuration_remove", { project = APP, configuration = { id = "999.999" } })
        assert.equals("no configuration with id 999.999 (a stale reference)", r.message)
        r = call("launch_remove", { project = APP, launch = { key = "nope" } })
        assert.equals("no launch config 'nope' on project 'app'", r.message)
        r = call("declaration", { project = { key = "nope" } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no project 'nope'", r.message)
        assert.equals(before, read(root .. "/.nvim/loomworks.user.json"))
    end)
end)
