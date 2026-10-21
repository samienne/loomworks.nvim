-- Deletion safety of the status page's orphan cleanup, stray-directory
-- deletion and project removal (spec §4.6, §5.7, §19.3): the orphaned
-- entries' cache state is `unknown` on disk before any tree is removed, an
-- entry is dropped only after its directory's removal is confirmed (a failed
-- removal keeps it), a directory a live configuration still references is
-- never removed (nor one that contains or lies inside a live build dir), a
-- directory that stopped being stray before the lock was taken is kept, the
-- locks are released and `on_done` reports the outcome (false on a failed
-- removal, a failed stray removal or an error), only dirs actually handed to
-- rm-rf are marked `unknown`, a removed orphan's owned LSP database is handed
-- to the owned-database cleanup, and every mutation takes O.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local bl = require("loomworks.build_lock")
local op_lock = require("loomworks.op_lock")
local wv = require("loomworks.workspace_view")
local L = require("tests.lock_helpers")
local uv = vim.uv or vim.loop

local function load(root) return assert(cli._load_workspace(root, false)) end

local function find_app(ws)
    for _, p in pairs(ws:get_projects()) do
        if p.key == "App" then return p end
    end
end

--- Add a cached build directory no profile references (an orphan), at `dir`
--- (default: a directory of its own).
local function add_orphan(ws, root, dir)
    dir = dir or (root .. "/.nvim/build/App/Release")
    vim.fn.mkdir(dir, "p")
    local cache = ws:_serialize_cache()
    cache.build_dirs = cache.build_dirs or {}
    cache.build_dirs["App/Release"] = {
        project_key = "App", config_key = "Release",
        type = "typescript", variant = "default", state = "built",
        build_dir = dir,
    }
    ws:remerge(nil, cache)
    assert.equals(1, #ws:get_orphaned_configs(), "test setup: one orphan")
    return dir
end

describe("view deletion safety", function()
    local io_mod = require("loomworks.io")
    local real_rm
    local root, built, ws, errs

    before_each(function()
        real_rm = io_mod.rm_rf_async
        root, built = L.make_ws()
        ws = load(root)
        ws._core._deps.on_lock_refused = nil
        errs = {}
        ws._core._deps.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
        end
    end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        L.cleanup()
        op_lock.release_all()
    end)

    local function wait_done(start)
        local done, ok, err = false, nil, nil
        start(function(o, e) done, ok, err = true, o, e end)
        assert.is_true(vim.wait(5000, function() return done end, 20), "on_done never called")
        return ok, err
    end

    local function locks_released(dir)
        return vim.wait(2000, function()
            return op_lock.read(root) == nil and (not dir or bl.read(dir) == nil)
        end, 20)
    end

    local function cleanup_now(done)
        local ctx = wv.compute_orphan_cleanup_context(ws)
        wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
    end

    --- Run `extra()` after every `_tracker:sync()` (what the deletion's
    --- re-check under the locks applies).
    local function on_sync(extra)
        assert.is_not_nil(ws._tracker, "test setup: the workspace has a file tracker")
        local real_sync = ws._tracker.sync
        ws._tracker.sync = function(t)
            real_sync(t)
            extra()
        end
    end

    local function count_rm()
        local removed = {}
        io_mod.rm_rf_async = function(d, cb)
            removed[#removed + 1] = d
            return real_rm(d, cb)
        end
        return removed
    end

    describe("orphan cleanup", function()
        it("marks the orphan's cache entry unknown on disk before removing its tree", function()
            local dir = add_orphan(ws, root)
            local on_disk
            io_mod.rm_rf_async = function(d, cb)
                if not on_disk then on_disk = L.read(root .. "/.nvim/loomworks.cache.json") or "" end
                return real_rm(d, cb)
            end
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.is_truthy(on_disk and on_disk:find('"unknown"', 1, true),
                "the orphan was not marked unknown on disk before the removal")
            assert.is_nil(uv.fs_stat(dir))
            assert.equals(0, #ws:get_orphaned_configs())
        end)

        it("keeps the entry (unknown), reports and releases the locks when the removal fails", function()
            local dir = add_orphan(ws, root)
            io_mod.rm_rf_async = function(_, cb) cb(false, "boom") end
            local ok = wait_done(cleanup_now)
            assert.is_false(ok, "a failed removal reported success")
            local orphans = ws:get_orphaned_configs()
            assert.equals(1, #orphans, "the orphan's entry was dropped although its tree is still there")
            assert.equals("unknown", orphans[1].build_dir_obj.state)
            assert.is_truthy(table.concat(errs, "\n"):find("boom", 1, true), table.concat(errs, "\n"))
            assert.is_true(locks_released(dir), "locks not released after a failed removal")
        end)

        it("never removes a directory a live configuration still references", function()
            add_orphan(ws, root, built)
            assert.equals(1, #ws:get_build_dir_refs(built), "test setup: the live unit references it")
            local removed = {}
            io_mod.rm_rf_async = function(d, cb)
                removed[#removed + 1] = d
                return real_rm(d, cb)
            end
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.same({}, removed, "a shared build directory was removed")
            assert.is_not_nil(uv.fs_stat(built))
            assert.equals(0, #ws:get_orphaned_configs(), "the orphan entry itself is dropped")
        end)

        it("calls on_done(false) and releases the locks when the deletion Future rejects", function()
            local dir = add_orphan(ws, root)
            io_mod.rm_rf_async = function() error("rm exploded") end
            local ok = wait_done(cleanup_now)
            assert.is_false(ok)
            assert.is_true(locks_released(dir), "locks not released after a rejected Future")
        end)

        it("keeps a stray directory that stopped being stray before the lock was taken", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local ctx = wv.compute_orphan_cleanup_context(ws)
            assert.equals(1, #ctx.stray_dirs, "test setup: one stray dir")
            -- Another process configured into it; applying that change (an
            -- external cache write reloads the workspace, so it is applied
            -- in place here) makes it live.
            on_sync(function()
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit.build_dir_value = stray
                ws:_sync_build_dir_refs()
            end)
            local ok = wait_done(function(done)
                wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
            end)
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.is_true(ok)
        end)

        it("deletes nothing when applying external changes unloaded the workspace", function()
            local dir = add_orphan(ws, root)
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local removed = count_rm()
            on_sync(function() ws._torn_down = true end)
            local ok = wait_done(cleanup_now)
            ws._torn_down = nil
            assert.is_false(ok)
            assert.same({}, removed, "a torn-down workspace removed directories")
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(dir))
        end)

        it("keeps an orphan another process re-adopted before the lock was taken", function()
            local dir = add_orphan(ws, root)
            local bd = ws:get_orphaned_configs()[1].build_dir_obj
            local removed = count_rm()
            on_sync(function()
                -- Another process now configures a live unit into the orphan.
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit._build_dir = bd
                unit.build_dir_value = dir
                ws:_sync_build_dir_refs()
            end)
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.same({}, removed, "a re-adopted build directory was removed")
            assert.is_not_nil(uv.fs_stat(dir))
            assert.equals("built", bd.state, "the re-adopted BuildDir's state was cleared")
            local present = false
            for _, b in ipairs(ws._build_dirs) do if b == bd then present = true end end
            assert.is_true(present, "the re-adopted BuildDir was dropped")
        end)

        it("calls on_done(false) and releases the locks when the re-check raises", function()
            local dir = add_orphan(ws, root)
            on_sync(function() error("sync exploded") end)
            local ok = wait_done(cleanup_now)
            assert.is_false(ok)
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_true(locks_released(dir))
        end)

        it("hands a removed orphan's module to the owned LSP database cleanup", function()
            add_orphan(ws, root)
            local deleted
            local real = ws._remove_owned_lsp_dbs
            ws._remove_owned_lsp_dbs = function(self, d)
                deleted = d
                return real(self, d)
            end
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.equals(1, #deleted)
            assert.is_not_nil(deleted[1].mod, "an orphan's owned LSP database is never considered")
        end)

        it("reports a failed stray removal and calls on_done(false)", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            io_mod.rm_rf_async = function(_, cb) cb(false, "stray boom") end
            local ok = wait_done(cleanup_now)
            assert.is_false(ok, "a failed stray removal reported success")
            assert.is_truthy(table.concat(errs, "\n"):find("stray boom", 1, true), table.concat(errs, "\n"))
            assert.is_true(locks_released(stray))
        end)

        -- #293: an orphan's dir comes from the cache (never trusted); one that
        -- contains or lies inside a live build dir is not "still referenced"
        -- by the exact-path refs check, so `_run_deletion` refuses it by
        -- directory overlap. The tree is kept; only the entry is dropped.
        it("never removes an orphan dir that contains a live build dir", function()
            local dir = add_orphan(ws, root, root .. "/.nvim/build/App")
            local removed = count_rm()
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.equals(0, #removed, "rm-rf was handed " .. table.concat(removed, ", "))
            assert.is_not_nil(uv.fs_stat(dir))
            assert.is_not_nil(uv.fs_stat(built))
            assert.equals(0, #ws:get_orphaned_configs())
        end)

        it("never removes an orphan dir lying inside a live build dir", function()
            local dir = add_orphan(ws, root, built .. "/sub")
            local removed = count_rm()
            local ok = wait_done(cleanup_now)
            assert.is_true(ok)
            assert.equals(0, #removed, "rm-rf was handed " .. table.concat(removed, ", "))
            assert.is_not_nil(uv.fs_stat(dir))
        end)
    end)

    describe("stray directory deletion", function()
        it("keeps a directory that stopped being stray before the lock was taken", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local n = ws._core._deps.normalize(stray)
            -- The scan reports the spelling under ws.root, which may differ
            -- from the test root's (8.3 short temp path on a Windows runner).
            local found = ws:find_stray_build_dirs()
            assert.equals(1, #found, "test setup: one stray dir")
            assert.equals(ws:_canonicalize_boundary_path(n), ws:_canonicalize_boundary_path(found[1]),
                "test setup: one stray dir")
            on_sync(function()
                local unit = ws._profiles[1]:projects()[1]._config_unit
                unit.build_dir_value = stray
                ws:_sync_build_dir_refs()
            end)
            local ok, err = wait_done(function(done) wv.execute_delete_stray_dir(ws, n, done) end)
            assert.is_false(ok)
            assert.equals("no longer a stray build directory", err)
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.is_true(locks_released(n))
        end)

        it("deletes nothing when applying external changes unloaded the workspace", function()
            local stray = ws._core._deps.normalize(root .. "/.nvim/build/App/Stray")
            vim.fn.mkdir(stray, "p")
            local removed = count_rm()
            on_sync(function() ws._torn_down = true end)
            local ok = wait_done(function(done) wv.execute_delete_stray_dir(ws, stray, done) end)
            ws._torn_down = nil
            assert.is_false(ok)
            assert.same({}, removed)
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(stray))
        end)

        it("calls on_done(false) and releases the locks when the re-check raises", function()
            local stray = ws._core._deps.normalize(root .. "/.nvim/build/App/Stray")
            vim.fn.mkdir(stray, "p")
            on_sync(function() error("sync exploded") end)
            local ok = wait_done(function(done) wv.execute_delete_stray_dir(ws, stray, done) end)
            assert.is_false(ok)
            assert.is_not_nil(uv.fs_stat(stray))
            assert.is_true(locks_released(stray))
        end)

        it("releases the locks after a failed removal", function()
            local stray = ws._core._deps.normalize(root .. "/.nvim/build/App/Stray")
            vim.fn.mkdir(stray, "p")
            io_mod.rm_rf_async = function(_, cb) cb(false, "boom") end
            local ok, err = wait_done(function(done) wv.execute_delete_stray_dir(ws, stray, done) end)
            assert.is_false(ok)
            assert.equals("boom", err)
            assert.is_true(locks_released(stray))
        end)
    end)

    describe("project removal without cached configurations", function()
        it("takes O: refused while another process holds it", function()
            local h = L.hold(op_lock.path(root), "publish")
            local app = find_app(ws)
            local ok = wait_done(function(done)
                wv.execute_remove_project(ws, app, { project_type = "typescript",
                    cached_configs = {}, downgrade_preview = {} }, done)
            end)
            assert.is_not_true(ok)
            assert.is_not_nil(find_app(ws), "the project was removed under another process's operation lock")
            assert.is_truthy(table.concat(errs, "\n"):find("workspace busy: publish", 1, true))
            assert.is_not_nil(h)
        end)

        it("holds O while it removes the project and releases it", function()
            local saw_o = false
            local real_remove = ws.remove_project
            ws.remove_project = function(self, p)
                saw_o = op_lock.read(root) ~= nil
                return real_remove(self, p)
            end
            local app = find_app(ws)
            local ok = wait_done(function(done)
                wv.execute_remove_project(ws, app, { project_type = "typescript",
                    cached_configs = {}, downgrade_preview = {} }, done)
            end)
            assert.is_true(ok)
            assert.is_true(saw_o, "O not held while the project was removed")
            assert.is_nil(find_app(ws))
            assert.is_true(locks_released())
        end)
    end)
end)

-- `_run_deletion`'s crash-safety marks (spec §4.6, §5.7), ported from master
-- (#298): a configured unit's entry is serialized from its BuildDir, and only
-- the dirs actually handed to rm-rf are marked `unknown`.
describe("deletion unknown marks", function()
    local io_mod = require("loomworks.io")
    local real_rm
    local root, built, ws

    before_each(function()
        real_rm = io_mod.rm_rf_async
        root, built = L.make_ws()
        ws = load(root)
        ws._core._deps.on_lock_refused = nil
        ws._core._deps.notify = function() end
    end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        L.cleanup()
        op_lock.release_all()
    end)

    -- Not an orphan, but the same crash rule: marking only the unit left the
    -- on-disk entry `built` while its tree was being removed.
    it("marks a configured unit's cache entry unknown on disk before removing its tree", function()
        local entry_state
        io_mod.rm_rf_async = function(d, cb)
            if not entry_state then
                local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
                entry_state = "<missing>"
                for _, e in pairs(cache.build_dirs or {}) do
                    if e.project_key == "App" and e.config_key == "Debug" then entry_state = e.state end
                end
            end
            return real_rm(d, cb)
        end
        local done = false
        ws._profiles[1]:reset(function() done = true end)
        assert.is_true(vim.wait(5000, function() return done end, 20), "reset never finished")
        assert.equals("unknown", entry_state,
            "the configured unit's entry was not unknown on disk before its removal")
        assert.is_nil(uv.fs_stat(built))
    end)

    -- A shared build dir that `_run_deletion` skips (another live unit still
    -- references it) is never handed to rm-rf, so its BuildDir must not be
    -- marked `unknown`: if another removal in the batch fails, nothing would
    -- restore it and the surviving unit would reload as `unknown` (blocked
    -- from configure/build). The dir that IS removed is still `unknown` on
    -- disk before its rm-rf starts.
    it("leaves a skipped shared dir's state alone when another removal in the batch fails", function()
        L.capture(function() cli.cmd_configuration("add", root, "App", "Other", "variant:default") end)
        ws = load(root)
        ws._core._deps.notify = function() end
        local orphan_dir = add_orphan(ws, root)
        local orphan = ws:get_orphaned_configs()[1]
        local unit_a = ws._profiles[1]:projects()[1]._config_unit
        local shared_bd = unit_a._build_dir
        assert.is_not_nil(shared_bd, "test setup: the live unit has a BuildDir")
        local project = unit_a._project
        local unit_b = ws:ensure_config_unit(project, project:get_configuration("Other"), nil)
        unit_b.build_dir_value = built
        unit_b.state_value = "built"
        unit_b._build_dir = shared_bd
        ws:_sync_build_dir_refs()
        assert.equals(2, #ws:get_build_dir_refs(ws._core._deps.normalize(built)), "test setup: dir is shared")
        ws:_save_cache()

        local removed_state, handed = nil, {}
        local norm_orphan = ws._core._deps.normalize(orphan_dir)
        io_mod.rm_rf_async = function(d, cb)
            handed[#handed + 1] = d
            if ws._core._deps.normalize(d) == norm_orphan then
                local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
                removed_state = "<missing>"
                for _, e in pairs(cache.build_dirs or {}) do
                    if e.project_key == "App" and e.config_key == "Release" then removed_state = e.state end
                end
            end
            cb(false, "boom")
        end
        local done = false
        ws:_run_deletion({
            { project_key = "App", config_key = "Other", build_dir = built, unit = unit_b },
            { project_key = "App", config_key = "Release", build_dir = orphan_dir,
              build_dir_obj = orphan.build_dir_obj },
        }, function() end, function() done = true end)
        assert.is_true(vim.wait(5000, function() return done end, 20), "deletion never finished")

        assert.equals(1, #handed, "only the unshared dir is handed to rm-rf")
        assert.equals("unknown", removed_state,
            "the removed dir's entry was not unknown on disk before its rm-rf")
        local cache = vim.json.decode(L.read(root .. "/.nvim/loomworks.cache.json") or "{}")
        local shared_state = "<missing>"
        for _, e in pairs(cache.build_dirs or {}) do
            if ws._core._deps.normalize(e.build_dir or "") == ws._core._deps.normalize(built) then
                shared_state = e.state
            end
        end
        assert.equals("built", shared_state,
            "the skipped shared dir was left unknown on disk after a failed batch")
        assert.equals("built", shared_bd.state)
    end)
end)

-- The status page's "Clean all" action reports the outcome `on_done` gives
-- it: a failed (or refused) cleanup must not be announced as success.
describe("orphaned section Clean all notification", function()
    local saved = {}
    local stubbed = { "loomworks", "loomworks.workspace_view", "loomworks.ui.dialog",
        "loomworks.ui.sections.orphaned" }
    local notes
    local real_notify

    before_each(function()
        for _, m in ipairs(stubbed) do saved[m] = package.loaded[m] end
        notes = {}
        real_notify = vim.notify
        vim.notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    end)
    after_each(function()
        for _, m in ipairs(stubbed) do package.loaded[m] = saved[m] end
        vim.notify = real_notify
    end)

    local function run_clean_all(cleanup_ok)
        local ws = { root = "/r" }
        local lw = {
            get_workspace = function() return ws end,
            get_orphaned_configs = function() return { { config_key = "App/Release" } } end,
        }
        package.loaded["loomworks"] = lw
        package.loaded["loomworks.workspace_view"] = {
            find_stray_build_dirs = function() return {} end,
            compute_orphan_cleanup_context = function()
                return { orphaned_configs = { {} }, stray_dirs = {}, lines = {}, highlights = {} }
            end,
            execute_orphan_cleanup = function(_, _, _, on_done) on_done(cleanup_ok) end,
        }
        package.loaded["loomworks.ui.dialog"] = {
            show = function(opts) opts.keys.y({ close = function() end }) end,
        }
        package.loaded["loomworks.ui.sections.orphaned"] = nil
        local render = require("loomworks.ui.sections.orphaned")
        local clean_all
        local tree = {
            leaf = function() end, blank = function() end,
            item = function(_, _, opts) if opts.on_enter then clean_all = opts.on_enter end end,
        }
        render(tree, {
            ws = ws, ref = function() return nil end,
            view = { orphaned = {
                configurations = { { key = "build/App/Release" } }, stray_dirs = {},
            } },
        })
        assert.is_not_nil(clean_all, "test setup: no Clean all action rendered")
        clean_all()
        return notes
    end

    it("reports success when the cleanup succeeded", function()
        local n = run_clean_all(true)
        assert.equals(1, #n)
        assert.equals(vim.log.levels.INFO, n[1].level)
        assert.is_truthy(n[1].msg:find("cleaned", 1, true))
    end)

    it("reports a failure when the cleanup failed", function()
        local n = run_clean_all(false)
        assert.equals(1, #n)
        assert.equals(vim.log.levels.WARN, n[1].level, n[1].msg)
        assert.is_falsy(n[1].msg:find("orphaned build dirs cleaned", 1, true), n[1].msg)
    end)
end)
