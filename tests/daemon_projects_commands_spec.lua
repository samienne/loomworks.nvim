-- loomworks.Projects/1 in the daemon (API.md §19, spec daemon.md §19.14 "As
-- interfaces"; step 5o part B3): candidates, add, declaration,
-- configuration_save / _remove, options_save, launch_save / _remove,
-- deploy_save, variable_save / _remove, type_config_set and expand_preview,
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
