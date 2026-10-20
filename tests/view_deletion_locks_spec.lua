-- The status page's own deletions (project removal, orphan cleanup, stray
-- directory deletion) take the workspace operation lock O and the build
-- locks B of the directories they remove, like every other deletion path
-- (spec §19.3, §16.6): refused fail-fast while another process holds either,
-- held while the removal runs, released after.

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

--- Add a cached build directory no profile references (an orphan).
local function add_orphan(ws, root)
    local dir = root .. "/.nvim/build/App/Release"
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

-- Each case: setup(ws, root, built_dir) -> dir to be deleted;
-- run(ws, dir, done) starts the view deletion and calls done(ok, err) at the end.
local cases = {
    {
        name = "project removal",
        setup = function(_, _, built) return built end,
        run = function(ws, _, done)
            local app = find_app(ws)
            local ctx = wv.compute_remove_context(ws, app)
            wv.execute_remove_project(ws, app, ctx, done)
        end,
        intact = function(ws) assert.is_not_nil(find_app(ws), "project removed anyway") end,
    },
    {
        name = "orphan cleanup (orphaned configuration)",
        setup = function(ws, root) return add_orphan(ws, root) end,
        run = function(ws, _, done)
            local ctx = wv.compute_orphan_cleanup_context(ws)
            wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
        end,
        intact = function(ws) assert.equals(1, #ws:get_orphaned_configs(), "orphan dropped anyway") end,
    },
    {
        name = "orphan cleanup (stray directory)",
        setup = function(_, root)
            local dir = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(dir, "p")
            return dir
        end,
        run = function(ws, _, done)
            local ctx = wv.compute_orphan_cleanup_context(ws)
            assert.equals(1, #ctx.stray_dirs, "test setup: one stray dir")
            wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
        end,
    },
    {
        name = "stray directory deletion",
        setup = function(_, root)
            local dir = root .. "/.nvim/build/App/Stray"
            vim.fn.mkdir(dir, "p")
            return dir
        end,
        run = function(ws, dir, done)
            wv.execute_delete_stray_dir(ws, ws._core._deps.normalize(dir), done)
        end,
    },
}

for _, case in ipairs(cases) do
    describe("view deletion takes O and B (§19.3): " .. case.name, function()
        local io_mod = require("loomworks.io")
        local real_rm
        before_each(function() real_rm = io_mod.rm_rf_async end)
        after_each(function()
            io_mod.rm_rf_async = real_rm
            L.cleanup()
            op_lock.release_all()
        end)

        local function start(hold)
            local root, built = L.make_ws()
            local ws = load(root)
            local dir = case.setup(ws, root, built)
            ws._core._deps.on_lock_refused = nil
            local errs = {}
            ws._core._deps.notify = function(msg, level)
                if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
            end
            local h = hold and hold(root, dir) or nil
            local removed = false
            io_mod.rm_rf_async = function(d, cb)
                removed = true
                return real_rm(d, cb)
            end
            local done, ok, err = false, nil, nil
            case.run(ws, dir, function(o, e) done, ok, err = true, o, e end)
            assert.is_true(vim.wait(5000, function() return done end, 20), "never finished")
            return { root = root, ws = ws, dir = dir, h = h, errs = table.concat(errs, "\n"),
                removed = removed, ok = ok, err = err }
        end

        it("is refused while another process holds the directory's build lock", function()
            local r = start(function(_, dir) return L.hold(bl.lock_path(dir), "configure") end)
            assert.is_false(r.removed, "the directory was removed under another process's lock")
            assert.is_not_nil(uv.fs_stat(r.dir))
            assert.is_truthy(r.errs:find("cannot delete: ", 1, true), r.errs)
            assert.is_truthy(r.errs:find("in use by lw configure (pid " .. r.h.pid, 1, true), r.errs)
            assert.is_not_true(r.ok)
            assert.is_nil(op_lock.read(r.root), "O left behind")
            if case.intact then case.intact(r.ws) end
        end)

        it("is refused while another process holds the operation lock", function()
            local r = start(function(root) return L.hold(op_lock.path(root), "publish") end)
            assert.is_false(r.removed, "the directory was removed under another process's operation lock")
            assert.is_not_nil(uv.fs_stat(r.dir))
            assert.is_truthy(r.errs:find("workspace busy: publish", 1, true), r.errs)
            assert.is_not_true(r.ok)
            assert.is_nil(bl.read(r.dir), "no build lock left behind")
            if case.intact then case.intact(r.ws) end
        end)

        it("holds O and B while it removes and releases both", function()
            local root, built = L.make_ws()
            local ws = load(root)
            local dir = case.setup(ws, root, built)
            local saw_o, saw_b = false, false
            io_mod.rm_rf_async = function(d, cb)
                saw_o = op_lock.read(root) ~= nil
                saw_b = bl.read(dir) ~= nil
                return real_rm(d, cb)
            end
            local done = false
            case.run(ws, dir, function() done = true end)
            assert.is_true(vim.wait(5000, function() return done end, 20))
            assert.is_true(saw_o, "O held during the deletion")
            assert.is_true(saw_b, "B held during the deletion")
            assert.is_nil(uv.fs_stat(dir), "the directory was not removed")
            assert.is_true(vim.wait(2000, function()
                return op_lock.read(root) == nil and bl.read(dir) == nil
            end, 20), "locks not released")
        end)
    end)
end
