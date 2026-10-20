-- Deletion safety of the status page's orphan cleanup, stray-directory
-- deletion and project removal (spec §4.6, §5.7, §19.3): the orphaned
-- entries' cache state is `unknown` on disk before any tree is removed, an
-- entry is dropped only after its directory's removal is confirmed (a failed
-- removal keeps it), a directory a live configuration still references is
-- never removed, a directory that stopped being stray before the lock was
-- taken is kept, the locks are released and `on_done` is called whatever the
-- outcome (failed removal, rejected Future), and every mutation takes O.

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
            -- Another process now configures into it (cache written on disk).
            local other = load(root)
            local unit = other._profiles[1]:projects()[1]._config_unit
            unit.build_dir_value = stray
            other:_sync_build_dir_refs()
            other:_save_cache()
            local ok = wait_done(function(done)
                wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
            end)
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.is_true(ok)
        end)
    end)

    describe("stray directory deletion", function()
        it("keeps a directory that stopped being stray before the lock was taken", function()
            local stray = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(stray, "p")
            local n = ws._core._deps.normalize(stray)
            assert.same({ n }, ws:find_stray_build_dirs(), "test setup: one stray dir")
            local other = load(root)
            local unit = other._profiles[1]:projects()[1]._config_unit
            unit.build_dir_value = stray
            other:_sync_build_dir_refs()
            other:_save_cache()
            local ok = wait_done(function(done) wv.execute_delete_stray_dir(ws, n, done) end)
            assert.is_false(ok)
            assert.is_not_nil(uv.fs_stat(stray), "a directory that is no longer stray was removed")
            assert.is_true(locks_released(n))
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
