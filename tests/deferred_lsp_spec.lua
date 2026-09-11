--- Tests for the deferred-LSP-start gate and the owned-database completion
--- nudge in loomworks/lsp.lua (spec §9.7 / invariant 16).
---
--- The gate routes an integration's root_dir resolution through
--- `lsp.gated_root_dir(bufnr, on_dir, resolve)`; while the workspace is
--- initializing, a buffer UNDER the workspace root is queued (its `resolve`
--- withheld) and released on `tools_detected`, on init failure, or on a safety
--- timeout. Buffers OUTSIDE the root resolve immediately.
---
--- We drive the real events bus and override the loomworks singleton facade
--- (is_ready / workspace_root / get_workspace / get_projects) per test.

require("loomworks.lsp")
local lsp = require("loomworks.lsp")
local events = require("loomworks.events")
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
            is_ready = lw.is_ready,
            workspace_root = lw.workspace_root,
            get_workspace = lw.get_workspace,
            get_projects = lw.get_projects,
            timeout = lsp._gate_timeout_ms,
        }
        -- Default: workspace still initializing, root known.
        lw.is_ready = function() return false end
        lw.workspace_root = function() return ROOT end
    end)

    after_each(function()
        lsp._reset_gate()
        lw.is_ready = saved.is_ready
        lw.workspace_root = saved.workspace_root
        lw.get_workspace = saved.get_workspace
        lw.get_projects = saved.get_projects
        lsp._gate_timeout_ms = saved.timeout
    end)

    it("holds an under-root buffer while not ready, releases on tools_detected", function()
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        -- Held: resolve not called, one entry queued.
        assert.is_false(resolved)
        assert.equals(1, lsp._gate_queue_len())

        -- Ready signal releases the queue.
        events.emit("tools_detected")
        assert.is_true(resolved)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("resolves an outside-root buffer immediately (never held)", function()
        local buf = make_buf("/elsewhere/unrelated.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_true(resolved)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("resolves immediately once the workspace is ready", function()
        lw.is_ready = function() return true end
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_true(resolved)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("resolves immediately when there is no known workspace root", function()
        lw.workspace_root = function() return nil end
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        assert.is_true(resolved)
    end)

    it("drains the queue on init failure (workspace_changed with nil)", function()
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)
        assert.equals(1, lsp._gate_queue_len())

        events.emit("workspace_changed", nil)
        assert.is_true(resolved)
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("does NOT drain on a successful workspace_changed (waits for tools)", function()
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)

        events.emit("workspace_changed", { root = ROOT }) -- success payload
        assert.is_false(resolved)
        assert.equals(1, lsp._gate_queue_len())

        events.emit("tools_detected")
        assert.is_true(resolved)
    end)

    it("drains via the safety timeout when no readiness signal arrives", function()
        lsp._gate_timeout_ms = 20
        local buf = make_buf(ROOT .. "/src/main.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)
        assert.equals(1, lsp._gate_queue_len())

        assert.is_true(vim.wait(1000, function() return resolved end, 5),
            "safety timeout never drained the queue")
        assert.equals(0, lsp._gate_queue_len())
    end)

    it("drops invalid buffers on release", function()
        local buf = make_buf(ROOT .. "/src/gone.cpp")
        local resolved = false
        lsp.gated_root_dir(buf, function() end, function() resolved = true end)
        vim.api.nvim_buf_delete(buf, { force = true })

        events.emit("tools_detected")
        assert.is_false(resolved) -- resolver skipped for the dead buffer
        assert.equals(0, lsp._gate_queue_len())
    end)
end)

describe("loomworks.lsp owned-database completion nudge (§9.7)", function()
    local saved
    local recorded

    before_each(function()
        recorded = {}
        saved = {
            get_workspace = lw.get_workspace,
            get_projects = lw.get_projects,
        }
        lsp.register("dbtest", {
            server = "dbtest",
            on_owned_database_changed = function(root_dir)
                recorded[#recorded + 1] = root_dir
            end,
        })
    end)

    after_each(function()
        lw.get_workspace = saved.get_workspace
        lw.get_projects = saved.get_projects
    end)

    --- Fake project whose module emits a dbtest entry rooted at `root_dir`.
    local function fake_project(key, root_dir)
        return {
            key = key,
            _module = { impl = {
                lsp_configs = function()
                    return { { server = "dbtest", root_dir = root_dir } }
                end,
            } },
        }
    end

    --- Fake workspace whose active profile maps `key` → `build_dir`.
    local function fake_ws(key, build_dir)
        local profile = {
            project = function(_, k)
                if k ~= key then return nil end
                return { build_dir = function() return build_dir end }
            end,
        }
        return { get_active_profile = function() return profile end }
    end

    it("nudges the integration whose project maps to the changed build dir", function()
        local BD = "/bd/App/Debug"
        lw.get_workspace = function() return fake_ws("App", BD) end
        lw.get_projects = function() return { App = fake_project("App", "/root/App") } end

        lsp.on_owned_database_changed(BD)
        assert.same({ "/root/App" }, recorded)
    end)

    it("does not nudge for a build dir no active project maps to", function()
        local BD = "/bd/App/Debug"
        lw.get_workspace = function() return fake_ws("App", BD) end
        lw.get_projects = function() return { App = fake_project("App", "/root/App") } end

        lsp.on_owned_database_changed("/some/other/build")
        assert.same({}, recorded)
    end)

    it("is a no-op with no active profile / no workspace", function()
        lw.get_workspace = function() return nil end
        lsp.on_owned_database_changed("/bd/App/Debug") -- must not raise
        assert.same({}, recorded)
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
