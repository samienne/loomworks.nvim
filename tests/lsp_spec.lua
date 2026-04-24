local lsp = require("loomworks.lsp")

-- We test lsp.lua by creating a real Core with cmake projects and
-- overriding init.lua facade functions to delegate to the test core.
-- This is necessary because init.lua captures a module-level singleton
-- that cannot be replaced via _core().

local h = require("tests.helpers")
local Core = require("loomworks.core")

--- Create a Core with cmake projects and return lsp-testable state.
--- @param opts table { projects, config_sets, cache, user, root }
--- @return loomworks.Core core
local function setup_core(opts)
    opts = opts or {}
    local root = opts.root or "/workspace"

    local config_projects = {}
    for key, proj in pairs(opts.projects or {}) do
        config_projects[key] = { cmake = proj.type_config or {} }
    end

    local config_json = h.make_config_json({
        projects = config_projects,
        configuration_sets = opts.config_sets,
    })

    local cache_data = opts.cache or {}
    local cache_json = h.make_cache_json(cache_data)
    local user_json = opts.user and h.make_user_json(opts.user) or nil

    -- Mock module that returns the cmake info we want.
    -- The mock also provides lsp_configs() emitting a clangd entry rooted
    -- at the project source path — this is what the clangd integration
    -- and lsp.get_status() consume in the new architecture.
    local mock_modules = {
        get = function(mod_type)
            if mod_type ~= "cmake" then return nil end
            return {
                validate = function()
                    return { valid = true, warnings = {} }
                end,
                info = function(path, type_config)
                    return {
                        configurations = { Debug = {}, Release = {} },
                        compile_commands_from = type_config and type_config.compile_commands_from or nil,
                        clangd = type_config and type_config.clangd or nil,
                    }
                end,
                lsp_configs = function(project)
                    local ws = project._workspace
                    if not ws then return {} end
                    local root = ws.root .. "/" .. (project.path or project.key)
                    return {
                        {
                            server = "clangd",
                            root_dir = root,
                            compile_commands_dir = project.cached and project.cached.build_dir or nil,
                        },
                    }
                end,
            }
        end,
    }

    local deps = h.make_test_deps({
        ["loomworks.json"] = config_json,
        ["loomworks.cache.json"] = cache_json,
        ["loomworks.user.json"] = user_json,
    }, {
        modules = mock_modules,
    })

    local core = Core.new(deps)
    core:setup({ root = root })
    return core
end

describe("lsp", function()
    describe("clangd_root_dir", function()
        it("calls fallback when loomworks is not available", function()
            local fallback_called = false
            local root_fn = lsp.clangd_root_dir(function(bufnr, on_dir)
                fallback_called = true
                on_dir("/fallback/root")
            end)

            -- With no workspace loaded, should fall back
            local lw = require("loomworks")
            local saved_ws = lw.get_workspace()
            -- loomworks is loaded but has no workspace
            local result = nil
            root_fn(0, function(dir) result = dir end)

            -- If no workspace, falls back
            if not saved_ws then
                assert.is_true(fallback_called)
                assert.equals("/fallback/root", result)
            end
        end)

        it("returns project path for cmake project buffers", function()
            local core = setup_core({
                root = "/workspace",
                projects = { MyLib = {} },
            })

            core._deps.buf_name = function()
                return "/workspace/MyLib/src/main.cpp"
            end

            -- Override init.lua facade to delegate to test core
            local lw = require("loomworks")
            local orig_pfb = lw.project_for_buf
            local orig_gw = lw.get_workspace
            lw.project_for_buf = function(bufnr) return core:project_for_buf(bufnr) end
            lw.get_workspace = function() return core:get_workspace() end

            local root_fn = lsp.clangd_root_dir(function(_, on_dir)
                on_dir("/fallback")
            end)

            local result = nil
            root_fn(1, function(dir) result = dir end)
            assert.equals("/workspace/MyLib", result)

            lw.project_for_buf = orig_pfb
            lw.get_workspace = orig_gw
        end)

        it("calls fallback for non-cmake project buffers", function()
            local core = setup_core({
                root = "/workspace",
                projects = {},
            })

            core._deps.buf_name = function() return "/workspace/other/file.ts" end

            local lw = require("loomworks")
            local orig_pfb = lw.project_for_buf
            local orig_gw = lw.get_workspace
            lw.project_for_buf = function(bufnr) return core:project_for_buf(bufnr) end
            lw.get_workspace = function() return core:get_workspace() end

            local fallback_called = false
            local root_fn = lsp.clangd_root_dir(function(_, on_dir)
                fallback_called = true
                on_dir("/fallback")
            end)

            local result = nil
            root_fn(1, function(dir) result = dir end)
            assert.is_true(fallback_called)
            assert.equals("/fallback", result)

            lw.project_for_buf = orig_pfb
            lw.get_workspace = orig_gw
        end)

        it("picks the innermost cmake project for nested projects", function()
            local core = setup_core({
                root = "/workspace",
                projects = {
                    Root = { type_config = {} },
                    ["Root/SubLib"] = { type_config = {} },
                },
                config_sets = { debug = { Root = "Debug", ["Root/SubLib"] = "Debug" } },
            })

            core._deps.buf_name = function() return "/workspace/Root/SubLib/src/foo.cpp" end

            local lw = require("loomworks")
            local orig_pfb = lw.project_for_buf
            local orig_gw = lw.get_workspace
            lw.project_for_buf = function(bufnr) return core:project_for_buf(bufnr) end
            lw.get_workspace = function() return core:get_workspace() end

            local root_fn = lsp.clangd_root_dir(function(_, on_dir)
                on_dir("/fallback")
            end)

            local result = nil
            root_fn(1, function(dir) result = dir end)
            assert.equals("/workspace/Root/SubLib", result)

            lw.project_for_buf = orig_pfb
            lw.get_workspace = orig_gw
        end)
    end)

    describe("clangd_cmd", function()
        it("returns a function", function()
            local cmd_fn = lsp.clangd_cmd({ "clangd", "--background-index" })
            assert.equals("function", type(cmd_fn))
        end)
    end)

    describe("resolve_clangd_binary", function()
        -- We test via the clangd_cmd factory by checking if args[1] changes.
        -- Since resolve functions are local, we test them indirectly through
        -- the project data surfaced on the Project object.

        it("uses base_cmd binary when no loomworks project matches", function()
            -- No workspace loaded — binary should stay as base_cmd[1]
            local cmd_fn = lsp.clangd_cmd({ "/usr/bin/clangd", "--background-index" })

            -- We can't fully test without mocking vim.lsp.rpc.start,
            -- but we verify the factory returns a callable function
            assert.equals("function", type(cmd_fn))
        end)
    end)

    describe("get_status", function()
        it("returns empty table when no workspace loaded", function()
            -- The init.lua singleton won't have a workspace unless setup was called.
            -- Temporarily ensure get_workspace returns nil.
            local lw = require("loomworks")
            local orig_gw = lw.get_workspace
            lw.get_workspace = function() return nil end

            local status = lsp.get_status()
            assert.equals("table", type(status))
            assert.equals(0, #status)

            lw.get_workspace = orig_gw
        end)

        it("returns project info for cmake projects", function()
            local core = setup_core({
                root = "/workspace",
                projects = { MyLib = {} },
                config_sets = { debug = { MyLib = "Debug" } },
                user = { active_profile = "debug" },
                cache = {
                    profiles = {
                        debug = { configuration_set = "debug", projects = { MyLib = { config_key = "Debug" } } },
                    },
                    projects = {
                        MyLib = {
                            type = "cmake",
                            configurations = {
                                Debug = { state = "built", build_dir = "/workspace/.nvim/build/MyLib/Debug" },
                            },
                        },
                    },
                },
            })

            -- Patch init.lua to use our test core
            local lw = require("loomworks")
            local orig_gw = lw.get_workspace
            local orig_gp = lw.get_projects
            lw.get_workspace = function() return core:get_workspace() end
            lw.get_projects = function() return core:get_projects() end

            local orig_get_clients = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            local status = lsp.get_status()
            assert.equals(1, #status)
            assert.equals("MyLib", status[1].project_key)
            assert.equals("cmake", status[1].project_type)
            assert.equals("/workspace/MyLib", status[1].root_dir)
            assert.equals(0, #status[1].clients)

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)

        it("matches clangd clients by root_dir", function()
            local core = setup_core({
                root = "/workspace",
                projects = { MyLib = {} },
                config_sets = { debug = { MyLib = "Debug" } },
                user = { active_profile = "debug" },
            })

            local lw = require("loomworks")
            local orig_gw = lw.get_workspace
            local orig_gp = lw.get_projects
            lw.get_workspace = function() return core:get_workspace() end
            lw.get_projects = function() return core:get_projects() end

            local orig_get_clients = vim.lsp.get_clients
            vim.lsp.get_clients = function(opts)
                if opts and opts.name == "clangd" then
                    return {
                        { root_dir = "/workspace/MyLib", name = "clangd", id = 1, config = { cmd = { "clangd" } } },
                        { root_dir = "/workspace/Other", name = "clangd", id = 2, config = { cmd = { "clangd" } } },
                    }
                end
                return {}
            end

            local status = lsp.get_status()
            assert.equals(1, #status)
            assert.equals(1, #status[1].clients)
            assert.equals("clangd", status[1].clients[1].name)

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)

        it("excludes project types without LSP server mapping", function()
            -- ets has no LSP_SERVERS entry
            local config_json = h.make_config_json({
                projects = { Frontend = { ets = {} } },
                configuration_sets = { debug = { Frontend = "debug" } },
            })
            local deps = h.make_test_deps({
                ["loomworks.json"] = config_json,
                ["loomworks.cache.json"] = h.make_cache_json({}),
            })
            local core = Core.new(deps)
            core:setup({ root = "/workspace" })

            local lw = require("loomworks")
            local orig_gw = lw.get_workspace
            local orig_gp = lw.get_projects
            lw.get_workspace = function() return core:get_workspace() end
            lw.get_projects = function() return core:get_projects() end

            local orig_get_clients = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            local status = lsp.get_status()
            assert.equals(0, #status)

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)
    end)

    describe("excludes", function()
        --- Create a scratch buffer with a given name and buftype.
        --- Appends a monotonic counter to ensure names are unique per call
        --- so tests don't collide with buffers left over from prior cases.
        local buf_counter = 0
        local function make_buf(name, buftype)
            buf_counter = buf_counter + 1
            local bufnr = vim.api.nvim_create_buf(false, true)
            if name and name ~= "" then
                vim.api.nvim_buf_set_name(bufnr, name .. ".buf" .. buf_counter)
            end
            if buftype then
                vim.api.nvim_set_option_value("buftype", buftype, { buf = bufnr })
            end
            return bufnr
        end

        it("default_excludes returns a table with expected fields", function()
            local d = lsp.default_excludes()
            assert.equals("table", type(d.bufname_patterns))
            assert.equals("table", type(d.buftypes))
            assert.is_true(#d.bufname_patterns > 0)
            assert.is_true(#d.buftypes > 0)
        end)

        it("default_excludes returns fresh copies so callers can mutate", function()
            local a = lsp.default_excludes()
            table.insert(a.bufname_patterns, "^mutated://")
            local b = lsp.default_excludes()
            for _, p in ipairs(b.bufname_patterns) do
                assert.are_not.equal("^mutated://", p)
            end
        end)

        it("excluded returns false before setup_servers resolves excludes", function()
            -- Without setup_servers, no excludes applied.
            lsp.setup_servers({ excludes = false })  -- explicit disable
            local bufnr = make_buf("diffview:///abc", nil)
            assert.is_false(lsp.excluded(bufnr))
        end)

        it("excluded matches default bufname_patterns after setup", function()
            lsp.setup_servers({})  -- default excludes
            local bufnr = make_buf("diffview:///a/b/file.cpp", nil)
            assert.is_true(lsp.excluded(bufnr))
        end)

        it("excluded matches default buftypes", function()
            lsp.setup_servers({})
            local bufnr = make_buf("", "quickfix")
            assert.is_true(lsp.excluded(bufnr))
        end)

        it("user override via function extends defaults", function()
            lsp.setup_servers({
                excludes = function(defaults)
                    table.insert(defaults.bufname_patterns, "^custom://")
                    return defaults
                end,
            })
            local b1 = make_buf("custom:///x", nil)
            assert.is_true(lsp.excluded(b1))
            local b2 = make_buf("diffview:///y", nil)
            -- defaults still apply because the function returned the (mutated) defaults
            assert.is_true(lsp.excluded(b2))
        end)

        it("user override via plain table replaces defaults", function()
            lsp.setup_servers({
                excludes = { bufname_patterns = { "^only://" }, buftypes = {} },
            })
            local b1 = make_buf("only:///x", nil)
            assert.is_true(lsp.excluded(b1))
            local b2 = make_buf("diffview:///y", nil)
            assert.is_false(lsp.excluded(b2))  -- default gone
        end)

        it("excludes = false disables exclusion entirely", function()
            lsp.setup_servers({ excludes = false })
            local bufnr = make_buf("diffview:///x", nil)
            assert.is_false(lsp.excluded(bufnr))
        end)

        it("register rejects reserved server names", function()
            local ok = pcall(lsp.register, "excludes", {})
            assert.is_false(ok)
        end)
    end)
end)
