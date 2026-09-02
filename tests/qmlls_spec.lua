--- Tests for the qmlls LSP integration and the cmake module's qmlls
--- lsp_configs entry. Follows the pure-seam style of lsp_spec.lua and
--- clangd_restart_spec.lua: the cmake side is exercised with a fake
--- project/workspace fixture (as in shell_spec.lua), and the integration
--- side is exercised through its pure arg-builder and root_dir_factory so
--- we never spawn a real qmlls process.

-- Load lsp.lua FIRST so its bottom-of-module discover() doesn't try to
-- pcall(require, "...qmlls") at the exact moment we're mid-loading qmlls
-- ourselves. After lsp.lua is in place, requiring qmlls just runs the file
-- body and registers — no recursive discover() call.
require("loomworks.lsp")

package.loaded["loomworks.modules.cmake"] = nil
local cmake = require("loomworks.modules.cmake")

package.loaded["loomworks.integrations.lsp.qmlls"] = nil
local qmlls = require("loomworks.integrations.lsp.qmlls")

local uv = vim.uv or vim.loop

--- A real on-disk directory, so resolve_build_dir's uv.fs_stat check passes.
local function make_tmp_dir()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    return tmp
end

-- ---------------------------------------------------------------------------
-- cmake M.lsp_configs — qmlls entry shape
-- ---------------------------------------------------------------------------

describe("cmake lsp_configs qmlls entry", function()
    --- Build a minimal fake Project + Workspace for cmake.lsp_configs.
    --- Mirrors shell_spec.lua's fake_project. The active profile carries a
    --- ProfileProject whose build_dir feeds both the clangd and qmlls entries.
    local function fake_project(opts)
        opts = opts or {}
        local build_dir = opts.build_dir
        local ws = {
            root = opts.ws_root or "/work",
            get_active_profile = function()
                if not build_dir then return nil end
                return {
                    project = function(_, _key)
                        return { build_dir = function() return build_dir end }
                    end,
                    tool_for = function() return nil end,
                }
            end,
        }
        return {
            key = opts.key or "myapp",
            path = opts.path or "myapp",
            type = "cmake",
            type_config = opts.type_config or {},
            tool_data = opts.tool_data,
            cached = opts.cached,
            _workspace = ws,
        }
    end

    it("emits a qmlls entry as the second config", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/.nvim/build/myapp/Debug",
        }))
        assert.equals(2, #cfgs)
        assert.equals("clangd", cfgs[1].server)
        assert.equals("qmlls", cfgs[2].server)
    end)

    it("carries the active profile build_dir and project root_dir", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/.nvim/build/myapp/Debug",
        }))
        local q = cfgs[2]
        assert.equals("/work/.nvim/build/myapp/Debug", q.build_dir)
        assert.equals("/work/myapp", q.root_dir)
        -- Same dir clangd routes compile_commands through.
        assert.equals(cfgs[1].compile_commands_dir, q.build_dir)
    end)

    it("type_config.qmlls flows into entry.binary; absent ⇒ nil", function()
        local with = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qmlls = "/opt/qt/bin/qmlls" },
        }))
        assert.equals("/opt/qt/bin/qmlls", with[2].binary)

        local without = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_nil(without[2].binary)
    end)

    it("type_config.qmlls_required flows into entry.binary_required", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qmlls = "/opt/qt/bin/qmlls", qmlls_required = true },
        }))
        assert.is_true(cfgs[2].binary_required)

        local dflt = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_false(dflt[2].binary_required)
    end)

    it("type_config.qml_import_paths flows into entry.import_paths", function()
        local cfgs = cmake.lsp_configs(fake_project({
            build_dir = "/work/out",
            type_config = { qml_import_paths = { "/a/qml", "/b/qml" } },
        }))
        assert.same({ "/a/qml", "/b/qml" }, cfgs[2].import_paths)

        local none = cmake.lsp_configs(fake_project({ build_dir = "/work/out" }))
        assert.is_nil(none[2].import_paths)
    end)
end)

-- ---------------------------------------------------------------------------
-- qmlls integration — pure arg builder
-- ---------------------------------------------------------------------------

describe("qmlls _build_args_for_tests", function()
    it("injects -b <build_dir> as two argv elements when the dir exists", function()
        local dir = make_tmp_dir()
        local args = qmlls._build_args_for_tests({ build_dir = dir })
        -- base + "-b" + dir
        assert.same({ "qmlls", "-b", dir }, args)
    end)

    it("omits -b when the build dir does not exist on disk", function()
        local args = qmlls._build_args_for_tests({
            build_dir = "/definitely/not/a/real/dir/xyz",
        })
        assert.same({ "qmlls" }, args)
    end)

    it("appends -I <path> per import path, after -b", function()
        local dir = make_tmp_dir()
        local args = qmlls._build_args_for_tests({
            build_dir = dir,
            import_paths = { "/imp/one", "/imp/two" },
        })
        assert.same(
            { "qmlls", "-b", dir, "-I", "/imp/one", "-I", "/imp/two" },
            args)
    end)

    it("overrides args[1] with a binary that exists on disk", function()
        -- Use this test file itself as a stand-in "binary" that fs_stat sees.
        local self_path = debug.getinfo(1, "S").source:sub(2)
        local args = qmlls._build_args_for_tests({ binary = self_path })
        assert.equals(self_path, args[1])
    end)

    it("does not override args[1] when the binary is missing", function()
        local args = qmlls._build_args_for_tests({ binary = "/no/such/qmlls" })
        assert.equals("qmlls", args[1])
    end)
end)

-- ---------------------------------------------------------------------------
-- qmlls integration — root_dir_factory
-- ---------------------------------------------------------------------------

describe("qmlls root_dir_factory", function()
    local lsp = require("loomworks.lsp")

    it("falls back when loomworks has no matching project", function()
        -- No workspace patched in; project_for_buf returns nil → fallback.
        local fallback_called = false
        local result = nil
        local root_fn = qmlls.root_dir_factory(function(_, on_dir)
            fallback_called = true
            on_dir("/fallback/root")
        end)
        root_fn(0, function(dir) result = dir end)
        assert.is_true(fallback_called)
        assert.equals("/fallback/root", result)
    end)

    it("resolves the entry root_dir for a matching project buffer", function()
        local lw = require("loomworks")
        local orig_pfb = lw.project_for_buf
        local orig_gw = lw.get_workspace
        -- entry_for asks lsp.entry_for_project which calls the module's
        -- lsp_configs; give the project a module whose impl emits a qmlls
        -- entry rooted at /work/myapp.
        local fake_project = {
            _module = {
                impl = {
                    lsp_configs = function()
                        return { { server = "qmlls", root_dir = "/work/myapp" } }
                    end,
                },
            },
        }
        lw.project_for_buf = function() return fake_project end
        lw.get_workspace = function() return {} end

        local result = nil
        local root_fn = qmlls.root_dir_factory(function(_, on_dir)
            on_dir("/should/not/be/used")
        end)
        root_fn(1, function(dir) result = dir end)
        assert.equals("/work/myapp", result)

        lw.project_for_buf = orig_pfb
        lw.get_workspace = orig_gw
    end)

    it("skips excluded buffers before any resolution", function()
        lsp.setup_servers({})  -- default excludes
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(bufnr, "diffview:///a/b/Main.qml")

        local called = false
        local root_fn = qmlls.root_dir_factory(function(_, on_dir)
            called = true
            on_dir("/anything")
        end)
        root_fn(bufnr, function() end)
        assert.is_false(called)  -- excluded before fallback runs
    end)
end)
