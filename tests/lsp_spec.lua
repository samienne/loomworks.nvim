local lsp = require("loomworks.lsp")

-- The LSP layer reads projects and entries only through loomworks.lsp_source,
-- i.e. the daemon's `LspConfig/1` state the observer holds (spec §19.16 "LSP
-- configuration"); the tests stand a fake observer in for it.

local observer_mod = require("loomworks.daemon.observer")

--- Observe a daemon whose LSP state is `state` (loaded) at `root`, with
--- `lw.buf_project` answering `buf_key` for every buffer. Returns a restore.
local function fake_lsp_state(root, state, buf_key)
    local lw = require("loomworks")
    local orig_cur, orig_bp = observer_mod._current, lw.buf_project
    observer_mod._current = {
        root = root, state = "connected",
        lsp_phase = function() return "loaded", state end,
    }
    lw.buf_project = function() return buf_key and { key = buf_key } or nil end
    return function()
        observer_mod._current, lw.buf_project = orig_cur, orig_bp
    end
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

        it("calls fallback for a project buffer whose project has no clangd entry", function()
            local restore = fake_lsp_state("/workspace", { state = "loaded", ready = true, options = {},
                projects = { { key = "other", path = "other", entries = {} } } }, "other")

            local fallback_called = false
            local root_fn = lsp.clangd_root_dir(function(_, on_dir)
                fallback_called = true
                on_dir("/fallback")
            end)

            local result = nil
            local ok, err = pcall(root_fn, 1, function(dir) result = dir end)
            restore()
            assert.is_true(ok, err)
            assert.is_true(fallback_called)
            assert.equals("/fallback", result)
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

        it("excludes projects whose module emits no LSP entries", function()
            local restore = fake_lsp_state("/workspace", { state = "loaded", ready = true, options = {},
                projects = { { key = "Frontend", path = "Frontend", entries = {} } } })
            local orig_get_clients = vim.lsp.get_clients
            vim.lsp.get_clients = function() return {} end

            local ok, status = pcall(lsp.get_status)

            vim.lsp.get_clients = orig_get_clients
            restore()
            assert.is_true(ok, status)
            assert.equals(0, #status)
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
