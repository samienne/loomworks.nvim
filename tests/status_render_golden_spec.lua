-- The status page body renders the same lines, highlights and line actions
-- whatever source its state comes from (spec §19.13 "Two sources, one
-- shape"): these fixtures pin the in-process page, every fold open, against
-- recorded output (tests/fixtures/status_golden/<name>.txt). Regenerate a
-- recording only for an intended change of the page:
--   LOOMWORKS_UPDATE_GOLDEN=1 make test-file FILE=tests/status_render_golden_spec.lua

local Core = require("loomworks.core")
local Tree = require("loomworks.ui.tree")
local h = require("tests.helpers")

local GOLDEN_DIR = "tests/fixtures/status_golden/"

--- The page must not depend on the machine: the toolchain search path (a
--- compiler-cache launcher on PATH shows as the profile's `Cache:` row and
--- drives the "no compiler cache" health suggestion) is stubbed empty while a
--- fixture loads, builds its view and renders.
local function without_path(fn)
    local cc = require("loomworks.cpp_compilers")
    local saved = cc.lookup_path
    cc.lookup_path = function() return nil end
    local ok, res = pcall(fn)
    cc.lookup_path = saved
    if not ok then error(res, 0) end
    return res
end

--- A stub module: keyed tools for cmake, resolved options with sources, test
--- targets; the real shell module for `shell` (its editable fields).
local function modules_dep(tools)
    local real = require("loomworks.modules")
    return {
        get = function(mod_type)
            if not mod_type then return nil end
            if mod_type == "shell" then return real.get("shell") end
            return {
                -- `tools`: the detected tools of a keyed-tool module.
                detect_tools_async = tools and function(callback)
                    local out = {}
                    for _, td in ipairs(tools) do out[#out + 1] = { tool_data = td } end
                    callback(out)
                end or nil,
                tool_key = tools and function(td) return td.id end or nil,
                tool_label = tools and function(td) return td.display or td.id end or nil,
                validate = tools and function() return { valid = true, warnings = {} } end or nil,
                id = mod_type,
                api_version = 1,
                has_keyed_tools = (mod_type == "cmake"),
                tools_match = function(a, b)
                    if a == nil and b == nil then return true end
                    if a == nil or b == nil then return false end
                    return vim.deep_equal(a, b)
                end,
                info = function(_, type_config)
                    local configs = {}
                    if type_config and type_config.configurations then
                        for name, data in pairs(type_config.configurations) do
                            configs[name] = vim.tbl_extend("force", { is_user = true }, data)
                        end
                    end
                    return { configurations = configs }
                end,
            }
        end,
    }
end

local FIXTURES = {
    cmake = {
        config = {
            projects = {
                App = {
                    cmake = { description = "The application.\n\nIt does things.", configurations = {
                        Base = { options = { WARN = "ON" } },
                        Debug = { variant = "Debug", inherits = "Base", options = { OPT = "1" } },
                        -- One dependent of Base only: Configuration:dependents()
                        -- has no fixed order.
                        Release = { variant = "Release", inherits = { "Gone" } },
                    } },
                    launch = {
                        run = { command = "app", args = { "--x", "1" }, description = "Run it" },
                        tgt = { target = "app" },
                    },
                    deploy = {
                        ["${workspace_root}/out/"] = {
                            { project = "Lib", target = "lib", pre_build = true },
                            { project = "Lib", path = "x.dat", configuration = "Debug" },
                        },
                    },
                    variables = { home = { type = "path", default = "/h" } },
                },
                Lib = { cmake = { configurations = { Debug = { variant = "Debug" } } } },
            },
            configuration_sets = {
                debug = { App = "Debug", Lib = "Debug" },
                release = { App = "Release", Lib = "Nope" },
            },
        },
        user = {
            active_profile = "debug",
            profiles = {
                debug = { configuration_set = "debug", description = "Day to day" },
                release = { configuration_set = "release" },
                ghost = { configuration_set = "vanished" },
            },
        },
        cache = {
            configurations = {
                ["App/Debug"] = { project_key = "App", config_key = "Debug", variant = "Debug",
                    type = "cmake", state = "built", build_dir = "/root/build/App/Debug" },
                ["Old/Debug"] = { project_key = "Old", config_key = "Debug", variant = "Debug",
                    type = "cmake", state = "configured", build_dir = "/root/build/Old/Debug" },
            },
        },
    },
    shell = {
        config = {
            projects = {
                Tool = { shell = {
                    configure = { "sh", "configure.sh" },
                    build = { "make" },
                    build_dir = "${workspace_root}/out",
                    env = { CC = "gcc" },
                } },
            },
            configuration_sets = { only = { Tool = "variant:default" } },
        },
        user = {
            active_profile = "only",
            profiles = { only = { configuration_set = "only" } },
        },
    },
    empty = {
        config = { projects = {} },
    },
    tools = {
        tools = { { id = "ninja-gcc-12", display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12",
            generator = "Ninja" } },
        config = {
            projects = { App = { cmake = { configurations = { Debug = { variant = "Debug" } } } } },
            configuration_sets = { debug = { App = "Debug" } },
        },
        user = {
            active_profile = "debug:ninja-gcc-12",
            profiles = {
                ["debug:ninja-gcc-12"] = {
                    configuration_set = "debug",
                    tools = { cmake = { key = "ninja-gcc-12", data = { id = "ninja-gcc-12",
                        display = "Ninja + GCC 12", compiler_path = "/usr/bin/gcc-12", generator = "Ninja" } } },
                },
            },
        },
        cache = {
            build_dirs = {
                ["build/App/ninja-gcc-12/Debug"] = {
                    project_key = "App", config_key = "Debug:ninja-gcc-12", variant = "Debug",
                    type = "cmake", state = "built", tool_key = "ninja-gcc-12",
                    tool_data = { id = "ninja-gcc-12", display = "Ninja + GCC 12",
                        compiler_path = "/usr/bin/gcc-12", generator = "Ninja" },
                },
            },
        },
    },
}

--- The page as text: each line, then its highlights and its widget's keys.
local function render_text(tree)
    local lines, hls, meta = tree:render()
    local by_line = {}
    for _, hl in ipairs(hls) do
        by_line[hl.line] = by_line[hl.line] or {}
        table.insert(by_line[hl.line], string.format("%d-%d %s", hl.col_start, hl.col_end, hl.hl_group))
    end
    local out = {}
    for i, l in ipairs(lines) do
        out[#out + 1] = string.format("%3d|%s", i, l)
        if by_line[i] then out[#out + 1] = "   hl " .. table.concat(by_line[i], "; ") end
        local w = meta[i]
        if w then
            local keys = {}
            for k, v in pairs(w) do
                keys[#keys + 1] = type(v) == "function" and (k .. "()") or (k .. "=" .. tostring(v))
            end
            table.sort(keys)
            out[#out + 1] = "   w  " .. table.concat(keys, " ")
        end
        if tree.line_hover[i] then
            local hv = tree.line_hover[i]()
            out[#out + 1] = "   K  " .. (type(hv) == "table" and table.concat(hv, "\\n") or tostring(hv))
        end
    end
    return table.concat(out, "\n") .. "\n"
end

--- Render the status page of `fixture` with every fold open.
local function render_fixture_impl(name)
    local fx = FIXTURES[name]
    local files = { ["loomworks.json"] = h.make_config_json(fx.config) }
    if fx.user then files["loomworks.user.json"] = h.make_user_json(fx.user) end
    if fx.cache then files["loomworks.cache.json"] = h.make_cache_json(fx.cache) end
    local notes = {}
    local core = Core.new(h.make_test_deps(files, { modules = modules_dep(fx.tools),
        notify = function(msg) notes[#notes + 1] = msg end }))
    core:setup({ root = "/root" })
    assert(core:get_workspace(), table.concat(notes, "; ") .. " " .. tostring(core._state))

    local lw = require("loomworks")
    local saved = {}
    local function patch(k, fn) saved[k] = lw[k]; lw[k] = fn end
    for k, v in pairs(lw) do
        if type(v) == "function" and k:match("^get_") and type(core[k]) == "function" then
            patch(k, function(...) return core[k](core, ...) end)
        end
    end
    -- The running version is not page state under test.
    patch("view_header", function()
        local hv = core:view_header()
        hv.version = "test"
        return hv
    end)
    if core.view_workspace then patch("view_workspace", function() return core:view_workspace() end) end
    patch("daemon_runtime_line", function() return nil end)

    local ok, text = pcall(function()
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        tree.width = 100
        setmetatable(tree._folds, { __index = function() return true end })
        return render_text(tree)
    end)
    for k, v in pairs(saved) do lw[k] = v end
    assert(ok, text)
    return text
end

local function render_fixture(name)
    return without_path(function() return render_fixture_impl(name) end)
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a"); f:close()
    -- A checkout may have turned the recording's line ends into CRLF.
    return (s:gsub("\r\n", "\n"))
end

--- A loaded test Core of fixture `name`.
local function fixture_core(name)
    local fx = FIXTURES[name]
    local files = { ["loomworks.json"] = h.make_config_json(fx.config) }
    if fx.user then files["loomworks.user.json"] = h.make_user_json(fx.user) end
    if fx.cache then files["loomworks.cache.json"] = h.make_cache_json(fx.cache) end
    local core = Core.new(h.make_test_deps(files, { modules = modules_dep(fx.tools) }))
    core:setup({ root = "/root" })
    return core
end

describe("view_state.workspace (loomworks.view.Workspace/1)", function()
    --- Every value plain data: no functions, no objects (metatables other than
    --- the JSON empty-object marker).
    local function plain(v, path)
        if type(v) == "function" then error("function at " .. path) end
        if type(v) ~= "table" then return end
        local mt = getmetatable(v)
        if mt and mt ~= vim._empty_dict_mt then error("object at " .. path) end
        for k, x in pairs(v) do plain(x, path .. "." .. tostring(k)) end
    end

    it("is plain data, with ids only from the caller's id function", function()
        local ws = fixture_core("cmake"):get_workspace()
        local bound = 0
        local v = ws:view_workspace({ bind = function() bound = bound + 1 end })
        plain(v, "view")
        assert.is_true(bound > 0)
        assert.is_nil(v.profiles[1].id)
        assert.is_nil(v.projects[1].id)
        local ids = ws:view_workspace({ id = function(o) return "id:" .. tostring(o.key or o.name) end })
        plain(ids, "view")
        assert.equals("id:" .. ids.profiles[1].key, ids.profiles[1].id)
        assert.equals("id:" .. ids.config_sets[1].name, ids.config_sets[1].id)
        assert.equals("id:" .. ids.projects[1].key, ids.projects[1].id)
    end)

    it("carries intent, removed_upstream and the device shape", function()
        local v = fixture_core("tools"):get_workspace():view_workspace()
        local p = v.profiles[1]
        assert.equals("debug:ninja-gcc-12", p.key)
        assert.is_false(p.removed_upstream)
        assert.equals(p.key, p.label)
        assert.is_nil(p.device) -- no device-capable module
        assert.is_nil(p.device_capable)
        assert.equals(1, #p.tools)
        assert.equals("cmake", p.tools[1].module)
        assert.equals("ninja-gcc-12", p.tools[1].key)
        assert.same({ { project = { key = "App" }, configuration = { key = "Debug" }, missing = false } },
            v.config_sets[1].mappings)
        local cfg = v.projects[1].configurations[1]
        assert.equals("Debug", cfg.key)
        assert.equals("Debug", cfg.label)
        assert.is_false(cfg.removed_upstream)
        assert.equals("built", p.units[1].state)
    end)

    it("carries no progress and no publish state of a launch; the last result is state", function()
        local ws = fixture_core("cmake"):get_workspace()
        local profile = ws:get_active_profile()
        local v = ws:view_workspace()
        local p
        for _, row in ipairs(v.profiles) do if row.key == profile.key then p = row end end
        assert.is_nil(p.last_result)
        for _, k in ipairs({ "pct", "elapsed", "message" }) do assert.is_nil(p[k], k) end
        for _, u in ipairs(p.units) do
            assert.is_nil(u.progress)
            assert.is_nil(u.elapsed)
        end
        local proj = v.projects[1]
        assert.is_true(#proj.launches > 0)
        for _, l in ipairs(proj.launches) do
            for _, k in ipairs({ "name", "modified", "intent", "removed_upstream" }) do assert.is_nil(l[k], k) end
        end
        for _, c in ipairs(proj.configurations) do
            assert.is_nil(c.object)
            assert.is_nil(c.name)
        end
        profile:set_last_result("failed", "build failed in 3s")
        v = ws:view_workspace()
        for _, row in ipairs(v.profiles) do if row.key == profile.key then p = row end end
        assert.same({ status = "failed", message = "build failed in 3s" }, p.last_result)
    end)
end)

describe("view_state.workspace against the view.Workspace/1 schema", function()
    local documents = require("loomworks.proto.documents")
    local set = documents.set()
    for _, name in ipairs({ "cmake", "shell", "empty", "tools" }) do
        it("the " .. name .. " fixture's view is a valid /$defs/Workspace", function()
            local n = 0
            local v = without_path(function()
                return fixture_core(name):get_workspace():view_workspace({
                    id = function() n = n + 1; return "o" .. n end })
            end)
            local ok, err = set:validate("interfaces/loomworks/view.Workspace.1.json", "/$defs/Workspace", v)
            assert.is_true(ok, err)
        end)
    end
end)

describe("status page rendering (golden)", function()
    for _, name in ipairs({ "cmake", "shell", "empty", "tools" }) do
        it("renders the " .. name .. " fixture as recorded", function()
            local text = render_fixture(name)
            local path = GOLDEN_DIR .. name .. ".txt"
            if os.getenv("LOOMWORKS_UPDATE_GOLDEN") == "1" then
                vim.fn.mkdir(GOLDEN_DIR, "p")
                local f = assert(io.open(path, "wb")); f:write(text); f:close()
            end
            local out_dir = os.getenv("LOOMWORKS_GOLDEN_OUT")
            if out_dir then
                local f = assert(io.open(out_dir .. "/" .. name .. ".txt", "wb")); f:write(text); f:close()
            end
            local want = read(path)
            assert.is_not_nil(want, "no recording: " .. path)
            assert.equals(want, text)
        end)
    end
end)

-- The refused-state hint (spec ui.md §1.4): the keys in the `in-process`
-- mode; in `daemon` mode, where those keys are refused while no workspace is
-- loaded (core §19.16 "Model writes"), the lw commands instead.
describe("status page refused-state hint", function()
    local function render(mode, trust)
        local lw = require("loomworks")
        local saved = { lw.get_workspace, lw.view_header, lw.runtime_mode }
        lw.get_workspace = function() return nil end
        lw.view_header = function()
            return { state = "refused", root = "/root", error = "refused", trust = trust, version = "test" }
        end
        lw.runtime_mode = function() return mode end
        local ok, lines = pcall(function()
            local tree = Tree.new(require("loomworks.ui.status")._render_fn)
            tree.width = 100
            return (tree:render())
        end)
        lw.get_workspace, lw.view_header, lw.runtime_mode = saved[1], saved[2], saved[3]
        assert(ok, lines)
        return lines[#lines]
    end

    it("names the keys in the in-process mode", function()
        assert.matches("[T] review & trust  [U] discard working copy", render("in-process", "user"), 1, true)
        assert.matches("[<C-n>] reset build cache", render("in-process", "cache"), 1, true)
    end)

    it("names the lw commands in daemon mode", function()
        assert.equals("lw trust  ·  lw trust --discard", vim.trim(render("daemon", "user")))
        assert.equals("lw nuke", vim.trim(render("daemon", "cache")))
    end)
end)
