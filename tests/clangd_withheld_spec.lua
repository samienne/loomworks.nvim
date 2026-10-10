--- Withheld language servers for buffers without a usable compilation
--- database (spec §9.1, §9.8, invariant 16a; clangd spec §3.1; ui.md §3–§4).
---
--- A real Core drives a workspace whose mock module emits clangd-shaped
--- entries the way a module predating `db_state` would — pointing straight at
--- the active unit's build directory, configured or not — so core's derived
--- `db_state` is what keeps a stale database there away from the server. The
--- server is a test-only name wired to the REAL clangd `withhold_reason`, with
--- an in-process fake language server as its cmd, so starting / stopping real
--- Neovim LSP clients is observable without a clangd binary.

local lsp = require("loomworks.lsp")
local clangd = require("loomworks.integrations.lsp.clangd")
local events = require("loomworks.events")
local lw = require("loomworks")
local h = require("tests.helpers")
local Core = require("loomworks.core")

local SERVER = "clangd_withheld_t"
lsp.register(SERVER, { server = SERVER, withhold_reason = clangd.withhold_reason })

local function mkfile(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(content or "[]")
    f:close()
end

--- In-process fake language server (no external binary).
local function fake_cmd(dispatchers)
    local closing = false
    local id = 0
    local srv = {}
    function srv.request(method, _, callback)
        id = id + 1
        if method == "initialize" then
            callback(nil, { capabilities = {} })
        elseif method == "shutdown" then
            callback(nil, vim.NIL)
        end
        return true, id
    end
    function srv.notify(method)
        if method == "exit" and not closing then
            closing = true
            vim.schedule(function() dispatchers.on_exit(0, 15) end)
        end
        return true
    end
    function srv.is_closing() return closing end
    function srv.terminate() closing = true end
    return srv
end

local function clients()
    return vim.lsp.get_clients({ name = SERVER })
end

local _seq = 0
local function open_buf(path)
    _seq = _seq + 1
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, (path:gsub("%.cpp$", "_" .. _seq .. ".cpp")))
    vim.fn.bufload(b)
    return b
end

describe("withheld clangd (§9.8)", function()
    local ROOT, core, saved, fallback_hits

    --- Core whose single cmake-ish project App is mapped by two config sets.
    --- `configured` → the Debug unit is recorded configured on this machine.
    local function setup_core(configured)
        local cache = nil
        if configured then
            cache = {
                build_dirs = {
                    ["build/App/Debug"] = {
                        project_key = "App", config_key = "Debug", variant = "Debug",
                        type = "cmake", state = "configured",
                    },
                },
            }
        end
        --- A module predating db_state: points at the active build dir
        --- regardless of whether it was configured here.
        local lsp_configs = function(project)
            local ws = project._workspace
            local profile = ws:get_active_profile()
            local pp = profile and profile:project(project.key)
            return { {
                server = SERVER,
                root_dir = ws.root .. "/" .. (project.path or project.key),
                compile_commands_dir = pp and pp:build_dir() or nil,
            } }
        end
        local deps = h.make_test_deps({
            ["loomworks.json"] = h.make_config_json({
                projects = { App = { cmake = { configurations = { Debug = {}, Release = {} } } } },
                configuration_sets = { debug = { App = "Debug" }, release = { App = "Release" } },
            }),
            ["loomworks.cache.json"] = h.make_cache_json(cache or {}),
            ["loomworks.user.json"] = h.make_user_json({
                active_profile = "debug",
                profiles = {
                    debug = { configuration_set = "debug" },
                    release = { configuration_set = "release" },
                },
            }),
        })
        local base_get = deps.modules.get
        deps.modules.get = function(mod_type)
            local m = base_get(mod_type)
            if m and mod_type == "cmake" then m.lsp_configs = lsp_configs end
            return m
        end
        deps.buf_name = function(b) return vim.api.nvim_buf_get_name(b) end
        local c = Core.new(deps)
        c:setup({ root = ROOT })
        return c
    end

    --- The active unit for App.
    local function active_unit()
        local pp = core:get_workspace():get_active_profile():project("App")
        return pp._config_unit, pp
    end

    --- Put a STALE compile_commands.json in the active unit's build dir (and
    --- in <root>/build, where a stock clangd would look on its own).
    local function plant_stale_dbs()
        local _, pp = active_unit()
        mkfile(pp:build_dir() .. "/compile_commands.json")
        mkfile(ROOT .. "/build/compile_commands.json")
    end

    before_each(function()
        ROOT = vim.fs.normalize(vim.fn.tempname())
        vim.fn.mkdir(ROOT .. "/App/src", "p")
        lsp._reset_gate()
        lsp._reset_withheld()
        fallback_hits = 0
        saved = {
            get_workspace = lw.get_workspace, get_projects = lw.get_projects,
            project_for_buf = lw.project_for_buf, workspace_root = lw.workspace_root,
            lsp_ready = lw.lsp_ready,
        }
        lw.get_workspace = function() return core and core:get_workspace() end
        lw.get_projects = function() return core and core:get_projects() or {} end
        lw.project_for_buf = function(b) return core and core:project_for_buf(b) end
        lw.workspace_root = function() return ROOT end
        lw.lsp_ready = function() return true end

        vim.lsp.config(SERVER, {
            cmd = fake_cmd,
            filetypes = { "cpp" },
            root_dir = function(b, on_dir)
                lsp.managed_root_dir(SERVER, b, on_dir, function(_, od)
                    fallback_hits = fallback_hits + 1
                    od(ROOT)
                end)
            end,
        })
        vim.lsp.enable(SERVER)
    end)

    after_each(function()
        vim.lsp.enable(SERVER, false)
        vim.wait(1000, function() return #clients() == 0 end, 10)
        for k, v in pairs(saved) do lw[k] = v end
        lsp._reset_gate()
        lsp._reset_withheld()
        core = nil
        pcall(vim.fn.delete, ROOT, "rf")
    end)

    it("unconfigured active unit with a stale DB on disk: no client, withheld_unconfigured", function()
        core = setup_core(false)
        plant_stale_dbs()
        local unit = active_unit()
        assert.is_false(unit:configured_here())

        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(200, function() return #clients() > 0 end, 10)

        assert.equals(0, #clients())
        assert.equals("withheld_unconfigured", lsp.buf_state(b))
        assert.equals("withheld_unconfigured", lw.lsp_buf_state(b))
        assert.equals(0, fallback_hits, "a withheld project buffer must not take the fallback")

        -- The entry carries the derived state and the clangd hook refuses it.
        local entry = lsp.entry_for_project(core:get_workspace():get_active_profile():project("App")._project, SERVER)
        assert.equals("unconfigured", entry.db_state)
        assert.equals("unconfigured", clangd.withhold_reason(entry))
    end)

    it("starts the client once the unit is configured here (no reopen)", function()
        core = setup_core(false)
        plant_stale_dbs()
        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())

        -- Configure completes: signed-cache state becomes configured (the
        -- database the module points at is now this machine's own).
        local unit = active_unit()
        unit.state_value = "configured"
        events.emit("active_set_changed")

        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10),
            "client never started after configure")
        assert.equals("ok", lsp.buf_state(b))
        assert.is_true(vim.lsp.buf_is_attached(b, clients()[1].id))
    end)

    it("re-attach starts only the withheld server, not every enabled config", function()
        local OTHER = "clangd_withheld_other_t"
        local other_calls = 0
        vim.lsp.config(OTHER, {
            cmd = fake_cmd,
            filetypes = { "cpp" },
            root_dir = function(_, on_dir)
                other_calls = other_calls + 1
                on_dir(ROOT)
            end,
        })
        vim.lsp.enable(OTHER)
        core = setup_core(false)
        plant_stale_dbs()
        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        assert.equals(1, other_calls)

        active_unit().state_value = "configured"
        events.emit("active_set_changed")
        local ok = vim.wait(2000, function() return #clients() > 0 end, 10)
        vim.lsp.enable(OTHER, false)
        vim.wait(1000, function() return #vim.lsp.get_clients({ name = OTHER }) == 0 end, 10)
        assert.is_true(ok, "client never started after configure")
        assert.equals(1, other_calls, "an unrelated enabled config must not be re-resolved")
    end)

    it("does not start a server that was never enabled via vim.lsp.enable", function()
        core = setup_core(false)
        plant_stale_dbs()
        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        vim.lsp.enable(SERVER, false)
        active_unit().state_value = "configured"
        lsp._reevaluate_now()
        vim.wait(200, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        -- The status still reflects the decision, even with nothing to start.
        assert.equals("ok", lsp.buf_state(b))
    end)

    it("stops the client when the active unit stops being configured here", function()
        core = setup_core(true)
        local _, pp = active_unit()
        assert.is_true(pp:configured_here())
        mkfile(pp:build_dir() .. "/compile_commands.json")

        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10))
        assert.equals("ok", lsp.buf_state(b))

        -- Switch to the profile whose unit was never configured here.
        local ws = core:get_workspace()
        local release
        for _, cs in pairs(ws._config_sets) do
            if cs.name == "release" then release = cs end
        end
        release:activate()
        assert.is_false(ws:get_active_profile():project("App"):configured_here())
        events.emit("active_set_changed")

        assert.is_true(vim.wait(2000, function() return #clients() == 0 end, 10),
            "client was not stopped after switching to an unconfigured profile")
        assert.equals("withheld_unconfigured", lsp.buf_state(b))

        -- And back: it starts again by itself.
        local debug
        for _, cs in pairs(ws._config_sets) do
            if cs.name == "debug" then debug = cs end
        end
        debug:activate()
        events.emit("active_set_changed")
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10),
            "client did not restart after switching back")
        assert.equals("ok", lsp.buf_state(b))
    end)

    it("configured here but no database: withheld_no_db, starts when it appears", function()
        core = setup_core(true)
        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        assert.equals("withheld_no_db", lsp.buf_state(b))

        local _, pp = active_unit()
        mkfile(pp:build_dir() .. "/compile_commands.json")
        lsp.on_owned_database_changed(pp:build_dir())
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10))
        assert.equals("ok", lsp.buf_state(b))
    end)

    it("withholds a buffer under the root outside every project (no stale <root>/build)", function()
        core = setup_core(false)
        plant_stale_dbs()
        local b = open_buf(ROOT .. "/tools/gen.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        assert.equals(0, fallback_hits)
        assert.equals("withheld_unconfigured", lsp.buf_state(b))

        -- Once the project's unit is configured, the buffer uses the
        -- workspace entry: App's client and database.
        active_unit().state_value = "configured"
        events.emit("active_set_changed")
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10))
        assert.equals("ok", lsp.buf_state(b))
        assert.equals(vim.fs.normalize(ROOT .. "/App"):lower(),
            vim.fs.normalize(clients()[1].root_dir):lower())
    end)

    it("withholds buffers under a workspace that failed to initialize", function()
        core = nil -- no live workspace
        lw.lsp_ready = function() return false end
        local b = open_buf(ROOT .. "/App/src/main.cpp")
        vim.bo[b].filetype = "cpp"
        assert.equals("held", lsp.buf_state(b))

        events.emit("workspace_changed", nil)
        vim.wait(100, function() return #clients() > 0 end, 10)
        assert.equals(0, #clients())
        assert.equals(0, fallback_hits)
        assert.equals("withheld_error", lsp.buf_state(b))
    end)
end)

describe("withheld clangd: no workspace loaded for the buffer's root (§9.7)", function()
    local saved, fallback_hits, OTHER, PENDING

    before_each(function()
        OTHER = vim.fs.normalize(vim.fn.tempname())
        PENDING = vim.fs.normalize(vim.fn.tempname())
        -- OTHER is a loomworks workspace on disk that nobody loaded.
        mkfile(OTHER .. "/loomworks.json", "{}")
        vim.fn.mkdir(OTHER .. "/src", "p")
        lsp._reset_gate()
        lsp._reset_withheld()
        fallback_hits = 0
        saved = {
            get_workspace = lw.get_workspace, workspace_root = lw.workspace_root,
            lsp_ready = lw.lsp_ready, project_for_buf = lw.project_for_buf,
            timeout = lsp._gate_timeout_ms,
        }
        lw.get_workspace = function() return nil end
        lw.project_for_buf = function() return nil end
        lw.workspace_root = function() return nil end
        lw.lsp_ready = function() return true end
        lsp._gate_timeout_ms = 30
        vim.lsp.config(SERVER, {
            cmd = fake_cmd,
            filetypes = { "cpp" },
            root_dir = function(b, on_dir)
                lsp.managed_root_dir(SERVER, b, on_dir, function(_, od)
                    fallback_hits = fallback_hits + 1
                    od(OTHER)
                end)
            end,
        })
        vim.lsp.enable(SERVER)
    end)

    after_each(function()
        vim.lsp.enable(SERVER, false)
        vim.wait(1000, function() return #clients() == 0 end, 10)
        for k, v in pairs(saved) do
            if k == "timeout" then lsp._gate_timeout_ms = v else lw[k] = v end
        end
        lsp._reset_gate()
        lsp._reset_withheld()
        pcall(vim.fn.delete, OTHER, "rf")
        pcall(vim.fn.delete, PENDING, "rf")
    end)

    it("an unloaded workspace's buffer falls back to stock clangd after the hold", function()
        local b = open_buf(OTHER .. "/src/x.cpp")
        vim.bo[b].filetype = "cpp"
        assert.equals("held", lsp.buf_state(b))
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10),
            "stock clangd must start once the hold times out")
        assert.equals(1, fallback_hits)
        assert.equals("none", lsp.buf_state(b))
    end)

    it("a buffer outside the workspace being loaded is not held at all", function()
        -- Another workspace (PENDING) is initializing; the buffer lives in OTHER.
        lw.workspace_root = function() return PENDING end
        lw.lsp_ready = function() return false end
        local b = open_buf(OTHER .. "/src/y.cpp")
        vim.bo[b].filetype = "cpp"
        assert.is_true(vim.wait(1000, function() return #clients() > 0 end, 10))
        assert.equals(1, fallback_hits)
        assert.equals("none", lsp.buf_state(b))
    end)

    it("a cache-only directory is not a workspace marker (spec §9.7)", function()
        local dir = vim.fs.normalize(vim.fn.tempname())
        mkfile(dir .. "/.nvim/loomworks.cache.json", "{}")
        local b = open_buf(dir .. "/z.cpp")
        local got
        lsp.managed_root_dir(SERVER, b, function(r) got = r end, function(_, od) od(dir) end)
        pcall(vim.fn.delete, dir, "rf")
        assert.equals(dir, got)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("workspace_closed releases buffers parked under the closed workspace", function()
        -- Workspace at OTHER was initializing past the safety timeout: parked held.
        lw.workspace_root = function() return OTHER end
        lw.lsp_ready = function() return false end
        local b = open_buf(OTHER .. "/src/w.cpp")
        vim.bo[b].filetype = "cpp"
        vim.wait(200, function() return false end, 10)
        assert.equals(0, #clients())
        assert.equals("held", lsp.buf_state(b))

        -- Shut down (cwd swap / reload): no workspace, nothing pending.
        lw.workspace_root = function() return nil end
        lw.lsp_ready = function() return true end
        events.emit("workspace_closed")
        assert.is_true(vim.wait(2000, function() return #clients() > 0 end, 10),
            "a closed workspace must not leave buffers held")
        assert.equals("none", lsp.buf_state(b))
    end)
end)

describe("withheld clangd: outside any workspace", function()
    it("leaves stock clangd routing unchanged (fallback, status none)", function()
        local saved = { get_workspace = lw.get_workspace, workspace_root = lw.workspace_root }
        lw.get_workspace = function() return nil end
        lw.workspace_root = function() return nil end
        lsp._reset_gate()

        local dir = vim.fs.normalize(vim.fn.tempname())
        local b = open_buf(dir .. "/plain/main.cpp")
        local got
        local root_fn = clangd.root_dir_factory(function(_, on_dir) on_dir("/stock/root") end)
        root_fn(b, function(r) got = r end)

        for k, v in pairs(saved) do lw[k] = v end
        assert.equals("/stock/root", got)
        assert.equals("none", lsp.buf_state(b))
    end)
end)

describe("clangd withhold_reason / db_state", function()
    local DB = vim.fs.normalize(vim.fn.tempname())
    mkfile(DB .. "/compile_commands.json")

    it("withholds unconfigured entries even when a directory is set", function()
        assert.equals("unconfigured",
            clangd.withhold_reason({ db_state = "unconfigured", compile_commands_dir = DB }))
        local extras = clangd.status_extras({ db_state = "unconfigured", compile_commands_dir = DB })
        assert.is_nil(extras.compile_commands_dir)
        assert.equals("unconfigured", extras.withheld)
        assert.is_truthy(extras.withheld_label:find("clangd withheld", 1, true))
    end)

    it("withholds a configured entry without a database", function()
        assert.equals("no_db", clangd.withhold_reason({ db_state = "ready" }))
        assert.equals("no_db", clangd.withhold_reason({ db_state = "ready", compile_commands_dir = DB .. "/nope" }))
    end)

    it("allows a configured entry with a database", function()
        assert.is_nil(clangd.withhold_reason({ db_state = "ready", compile_commands_dir = DB }))
        assert.is_nil(clangd.status_extras({ db_state = "ready", compile_commands_dir = DB }).withheld)
    end)
end)

-- ---------------------------------------------------------------------------
-- lualine: loomworks_lsp component + red unconfigured marker (ui.md §3–§4)
-- ---------------------------------------------------------------------------

package.preload["lualine.component"] = function()
    local Base = {}
    Base.__index = Base
    function Base:extend()
        local cls = setmetatable({}, { __index = self })
        cls.__index = cls
        cls.super = self
        return cls
    end
    function Base:init(options) self.options = options end
    function Base:create_hl(color, hint)
        return { name = "lualine_c_loomworks_" .. hint, fn = color }
    end
    function Base:format_hl(token) return "%#" .. token.name .. "#" end
    function Base:get_default_hl() return "%#lualine_c_normal#" end
    return Base
end

local function component(name, opts)
    package.loaded["lualine.components." .. name] = nil
    local cls = require("lualine.components." .. name)
    local c = setmetatable({}, cls)
    c:init(opts or {})
    return c
end

describe("lualine loomworks_lsp component", function()
    local saved
    before_each(function() saved = package.loaded["loomworks"] end)
    after_each(function() package.loaded["loomworks"] = saved end)

    local function with_state(state)
        package.loaded["loomworks"] = { lsp_buf_state = function() return state end }
    end

    it("renders every withheld state as plain text (no raw %# / %* escapes)", function()
        local c = component("loomworks_lsp")
        with_state("withheld_unconfigured")
        assert.equals("(unconfigured)", c:update_status())
        with_state("withheld_no_db")
        assert.equals("(no db)", c:update_status())
        with_state("withheld_error")
        assert.equals("(ws error)", c:update_status())
    end)

    it("colours through lualine's color option: DiagnosticError fg, section bg", function()
        local c = component("loomworks_lsp")
        assert.equals("function", type(c.options.color))
        local hl = vim.api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
        local col = c.options.color()
        if hl.fg then
            assert.same({ fg = string.format("#%06x", hl.fg) }, col)
        else
            assert.is_nil(col)
        end
        -- A user colour wins.
        local u = component("loomworks_lsp", { color = { fg = "#123456" } })
        assert.same({ fg = "#123456" }, u.options.color)
    end)

    it("renders nothing for none / held / ok and without loomworks", function()
        local c = component("loomworks_lsp")
        for _, st in ipairs({ "none", "held", "ok" }) do
            with_state(st)
            assert.equals("", c:update_status())
        end
        package.loaded["loomworks"] = nil
        assert.equals("", c:update_status())
    end)
end)

describe("lualine loomworks component status markers", function()
    it("marks unconfigured red and mixed amber", function()
        local c = component("loomworks")
        assert.is_truthy(c:_status_marker("unconfigured"):find("%#lualine_c_loomworks_DiagnosticError#", 1, true))
        assert.is_truthy(c:_status_marker("mixed"):find("%#lualine_c_loomworks_DiagnosticWarn#", 1, true))
        assert.is_truthy(c:_status_marker("configured"):find("%#lualine_c_loomworks_Comment#", 1, true))
    end)
end)
