--- Tests for the qmlls LSP integration. Follows the pure-seam style of
--- lsp_spec.lua and clangd_restart_spec.lua: the integration is exercised
--- through its pure arg-builder and root_dir_factory so we never spawn a
--- real qmlls process. (The cmake module's qmlls lsp_configs entry is
--- loomworks' to test.)

-- Load lsp.lua FIRST so its bottom-of-module discover() doesn't try to
-- pcall(require, "...qmlls") at the exact moment we're mid-loading qmlls
-- ourselves. After lsp.lua is in place, requiring qmlls just runs the file
-- body and registers — no recursive discover() call.
require("loomworks.lsp")

package.loaded["loomworks.integrations.lsp.qmlls"] = nil
local qmlls = require("loomworks.integrations.lsp.qmlls")

--- A real on-disk directory, so the arg builder's existence check passes.
local function make_tmp_dir()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    return tmp
end

-- ---------------------------------------------------------------------------
-- qmlls integration — pure arg builder
-- ---------------------------------------------------------------------------

describe("qmlls _build_args_for_tests", function()
    it("injects -b <build_dir> + --no-cmake-calls when the dir exists", function()
        local dir = make_tmp_dir()
        local args = qmlls._build_args_for_tests({ build_dir = dir })
        -- base + "-b" + dir + suppress qmlls's own CMake rebuilds
        assert.same({ "qmlls", "-b", dir, "--no-cmake-calls" }, args)
    end)

    it("omits -b when the build dir does not exist on disk", function()
        local args = qmlls._build_args_for_tests({
            build_dir = "/definitely/not/a/real/dir/xyz",
        })
        assert.same({ "qmlls" }, args)
    end)

    it("appends -I <path> per import path, after -b/--no-cmake-calls", function()
        local dir = make_tmp_dir()
        local args = qmlls._build_args_for_tests({
            build_dir = dir,
            import_paths = { "/imp/one", "/imp/two" },
        })
        assert.same(
            { "qmlls", "-b", dir, "--no-cmake-calls", "-I", "/imp/one", "-I", "/imp/two" },
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
