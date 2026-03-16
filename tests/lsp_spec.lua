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

    -- Mock module that returns the cmake info we want
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
            assert.equals(0, vim.tbl_count(status))

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
            assert.equals("table", type(status))
            assert.is_not_nil(status["MyLib"])
            assert.equals("/workspace/MyLib", status["MyLib"].root_dir)
            -- compile_commands_dir is nil because fs_stat won't find the file in tests
            assert.is_nil(status["MyLib"].compile_commands_dir)
            -- clangd_bin is nil because no override configured and fs_stat won't find it
            assert.is_nil(status["MyLib"].clangd_bin)
            assert.equals(0, status["MyLib"].clients)

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)

        it("counts matching clangd clients", function()
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
            vim.lsp.get_clients = function()
                return {
                    { root_dir = "/workspace/MyLib", name = "clangd" },
                    { root_dir = "/workspace/Other", name = "clangd" },
                }
            end

            local status = lsp.get_status()
            assert.equals(1, status["MyLib"].clients)

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)

        it("excludes non-cmake projects", function()
            -- Create a workspace with an ets project (not cmake)
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
            assert.equals(0, vim.tbl_count(status))

            vim.lsp.get_clients = orig_get_clients
            lw.get_workspace = orig_gw
            lw.get_projects = orig_gp
        end)
    end)
end)
