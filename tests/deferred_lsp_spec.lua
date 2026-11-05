--- Tests for the deferred-LSP-start gate and the owned-database completion
--- nudge in loomworks/lsp.lua (spec §9.7 / invariant 16).
---
--- The gate routes an integration's root_dir resolution through
--- `lsp.gated_root_dir(bufnr, on_dir, resolve)`; while the workspace is
--- initializing (and the active profile's owned LSP databases are being
--- generated), a buffer UNDER the workspace root is queued (its `resolve`
--- withheld) and released on the daemon's `ready` (tests/daemon_lsp_editor_spec),
--- when the workspace closes, or on a safety timeout. Buffers OUTSIDE the
--- root resolve immediately.
---
--- We drive the real events bus and override the loomworks singleton facade
--- (workspace_root / get_workspace / get_projects) per test.

require("loomworks.lsp")
local lsp = require("loomworks.lsp")
local events = require("loomworks")
local lw = require("loomworks")

--- Make a scratch buffer with a unique absolute name so `buf_under_root` sees
--- a path (buffer names must be unique within a session — E95 otherwise).
--- @param name string absolute file path (a unique suffix is appended)
--- @return integer bufnr
local _buf_seq = 0
local function make_buf(name)
    _buf_seq = _buf_seq + 1
    local b = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(b, name .. "." .. _buf_seq .. ".cpp")
    return b
end

describe("loomworks.lsp deferred-start gate (§9.7)", function()
    local saved
    local ROOT = vim.fs.normalize(vim.fn.tempname())

    before_each(function()
        lsp._reset_gate()
        saved = {
            workspace_root = lw.workspace_root,
            get_workspace = lw.get_workspace,
            get_projects = lw.get_projects,
            timeout = lsp._gate_timeout_ms,
        }
        -- Default: a workspace root is known, nothing loaded yet.
        lw.workspace_root = function() return ROOT end
    end)

    after_each(function()
        lsp._reset_gate()
        lw.workspace_root = saved.workspace_root
        lw.get_workspace = saved.get_workspace
        lw.get_projects = saved.get_projects
        lsp._gate_timeout_ms = saved.timeout
    end)

    it("resolves an outside-root buffer immediately (never held)", function()
        local buf = make_buf("/elsewhere/unrelated.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_true(resolved)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("holds a buffer detected inside a loomworks workspace before setup(root)", function()
        -- Session-restored buffers can resolve root_dir BEFORE auto-load tells
        -- loomworks the root: no loaded workspace, workspace_root() nil. The gate
        -- must still hold a buffer whose path sits under a loomworks marker.
        lw.get_workspace = function() return nil end
        lw.workspace_root = function() return nil end
        local dir = vim.fs.normalize(vim.fn.tempname())
        vim.fn.mkdir(dir .. "/.nvim", "p")
        local f = assert(io.open(dir .. "/.nvim/loomworks.user.json", "w"))
        f:write("{}"); f:close()

        local buf = make_buf(dir .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_false(resolved, "buffer inside a detected loomworks workspace must be held")
        assert.equals(1, lsp._gate_queue_len())

        events._emit("workspace_closed")
        assert.is_true(resolved)
        pcall(vim.fn.delete, dir, "rf")
    end)

    it("resolves immediately when there is no known workspace root", function()
        lw.workspace_root = function() return nil end
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_true(resolved)
    end)

    it("drains via the safety timeout when no readiness signal arrives", function()
        lsp._gate_timeout_ms = 20
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)
        assert.equals(1, lsp._gate_queue_len())

        assert.is_true(vim.wait(10000, function() return resolved end, 5),
            "safety timeout never drained the queue")
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("drops invalid buffers on release", function()
        local buf = make_buf(ROOT .. "/src/gone.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)
        vim.api.nvim_buf_delete(buf, { force = true })

        events._emit("workspace_closed")
        assert.is_false(resolved) -- resolver skipped for the dead buffer
        assert.equals(0, lsp._gate_queue_len())
    end)
end)

-- ---------------------------------------------------------------------------
-- clangd nudge idempotency — the decision reuses _needs_restart_for_dir, the
-- same check reconcile_on_attach uses: a client whose recorded cmd lacks the
-- resolvable dir is restarted; one already carrying it is not.
-- ---------------------------------------------------------------------------

describe("clangd owned-database nudge idempotency", function()
    package.loaded["loomworks.integrations.lsp.clangd"] = nil
    local clangd = require("loomworks.integrations.lsp.clangd")
    local DIR = "/work/cache/cc"

    it("restarts a client whose cmd lacks the now-resolvable dir", function()
        -- resolved cmd has no --compile-commands-dir, desired is set.
        assert.is_true(clangd._needs_restart_for_dir({ "clangd", "--background-index" }, DIR))
    end)

    it("does not restart a client already carrying the correct dir", function()
        assert.is_false(clangd._needs_restart_for_dir(
            { "clangd", "--compile-commands-dir=" .. DIR }, DIR))
    end)

    it("on_owned_database_changed is a safe no-op when nothing matches", function()
        -- No workspace wired → find_by_root yields nothing → no restart, no raise.
        clangd.on_owned_database_changed("/work/App")
    end)
end)
