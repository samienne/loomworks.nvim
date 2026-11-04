-- The status page body renders the same lines, highlights and line actions
-- whatever source its state comes from (spec §19.13 "Two sources, one
-- shape"): these fixtures pin the page, every fold open, against recorded
-- output (tests/fixtures/status_golden/<name>.txt). The page reads the
-- fixture's view as the daemon's (a fake observer holds it; the view is
-- built by the daemon's view_state from a fixture model). Regenerate a
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

    -- The fixture's view held as the daemon's, by a fake observer.
    local observer, views = require("loomworks.daemon.observer"), require("loomworks.views")
    local n = 0
    local view = core:get_workspace():view_workspace({ id = function() n = n + 1; return "o" .. n end })
    local obs = { state = "connected", root = "/root" }
    function obs:workspace_view() return view end
    function obs:tasks() return {} end
    function obs:_clock() return 0 end
    -- The LSP configuration as `LspConfig/1` holds it (the daemon reads the
    -- same working copy).
    function obs:lsp_phase()
        return "loaded", { state = "loaded", options = { clangd = core:get_lsp_options("clangd") } }
    end
    -- (The editor is attached to it while the page renders.)
    local saved_obs = { observer._current, observer._attached_root }
    views.set(obs, "header", lw.view_header())
    -- The debug adapter records as `DebugConfig/1.adapters` answers them
    -- (the daemon builds them from the same working copy).
    local eo = require("loomworks.daemon.editor_ops")
    local orig_adapters = eo.debug_adapters
    eo.debug_adapters = function()
        return require("loomworks.debug_config").adapter_records(core:get_workspace())
    end

    observer._current, observer._attached_root = obs, "/root"
    local ok, text = pcall(function()
        local tree = Tree.new(require("loomworks.ui.status")._render_fn)
        tree.width = 100
        setmetatable(tree._folds, { __index = function() return true end })
        return render_text(tree)
    end)
    observer._current, observer._attached_root = saved_obs[1], saved_obs[2]
    views.clear(obs)
    eo.debug_adapters = orig_adapters
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

-- The refused-state hint (spec ui.md §1.4): the keys are refused while no
-- workspace is loaded (core §19.16 "Model writes"): the lw commands instead.
describe("status page refused-state hint", function()
    local function render(trust)
        local lw = require("loomworks")
        local saved = { lw.get_workspace, lw.view_header }
        lw.get_workspace = function() return nil end
        lw.view_header = function()
            return { state = "refused", root = "/root", error = "refused", trust = trust, version = "test" }
        end
        local ok, lines = pcall(function()
            local tree = Tree.new(require("loomworks.ui.status")._render_fn)
            tree.width = 100
            return (tree:render())
        end)
        lw.get_workspace, lw.view_header = saved[1], saved[2]
        assert(ok, lines)
        return lines[#lines]
    end

    it("names the lw commands", function()
        assert.equals("lw trust  ·  lw trust --discard", vim.trim(render("user")))
        assert.equals("lw nuke", vim.trim(render("cache")))
    end)
end)
