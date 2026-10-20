-- Deletion safety of the status page's orphan cleanup (spec §4.6, §5.7,
-- spec/ui.md §1.6 "via `_run_deletion`"): the orphaned entries' cache state is
-- `unknown` on disk before any tree is removed, an entry is dropped only after
-- its directory's removal is confirmed (a failed removal keeps it and is
-- reported), a directory a live configuration still references is never
-- removed, `on_done` reports the outcome (false on a failed removal, a failed
-- stray removal or an error), and a removed orphan's owned LSP database is
-- handed to the owned-database cleanup.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local wv = require("loomworks.workspace_view")
local uv = vim.uv or vim.loop

local function quiet(fn)
    local rw, rs, rex = io.write, io.stderr, os.exit
    io.write = function() end
    io.stderr = { write = function() end }
    os.exit = function() error({ __exit = true }, 0) end
    pcall(fn)
    io.write, io.stderr, os.exit = rw, rs, rex
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- A workspace with a typescript App, an active `Dev` profile whose App/Debug
--- unit is built in `<root>/.nvim/build/App/Debug`. Returns root, that dir.
local function make_ws()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root .. "/App", "p")
    local f = assert(io.open(root .. "/loomworks.json", "w"))
    f:write(vim.json.encode({ projects = { App = { typescript = vim.empty_dict() } } })); f:close()
    quiet(function() cli.cmd_configuration("add", root, "App", "Debug", "variant:default") end)
    quiet(function() cli.cmd_cset("create", root, { "configuration-set", "create", "Dev", "App=Debug" }) end)
    quiet(function() cli.cmd_profile_create(root, { "profile", "create", "Dev", "--activate" }) end)
    local ws = assert(cli._load_workspace(root, false))
    local unit = ws._profiles[1]:projects()[1]._config_unit
    local dir = root .. "/.nvim/build/App/Debug"
    vim.fn.mkdir(dir, "p")
    unit.build_dir_value = dir
    unit.state_value = "built"
    ws:_sync_build_dir_refs()
    ws:_save_cache()
    return root, dir
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

describe("orphan cleanup deletion safety", function()
    local io_mod = require("loomworks.io")
    local real_rm
    local roots = {}
    local root, built, ws, errs

    before_each(function()
        real_rm = io_mod.rm_rf_async
        root, built = make_ws()
        roots[#roots + 1] = root
        ws = assert(cli._load_workspace(root, false))
        errs = {}
        ws._core._deps.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
        end
    end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        for _, r in ipairs(roots) do vim.fn.delete(r, "rf") end
        roots = {}
    end)

    local function wait_done(start)
        local done, ok = false, nil
        start(function(o) done, ok = true, o end)
        assert.is_true(vim.wait(5000, function() return done end, 20), "on_done never called")
        return ok
    end

    local function cleanup_now(done)
        local ctx = wv.compute_orphan_cleanup_context(ws)
        wv.execute_orphan_cleanup(ws, ctx.orphaned_configs, ctx.stray_dirs, done)
    end

    it("marks the orphan's cache entry unknown on disk before removing its tree", function()
        local dir = add_orphan(ws, root)
        local on_disk
        io_mod.rm_rf_async = function(d, cb)
            if not on_disk then on_disk = read(root .. "/.nvim/loomworks.cache.json") or "" end
            return real_rm(d, cb)
        end
        local ok = wait_done(cleanup_now)
        assert.is_truthy(on_disk and on_disk:find('"unknown"', 1, true),
            "the orphan was not marked unknown on disk before the removal")
        assert.is_nil(uv.fs_stat(dir))
        assert.equals(0, #ws:get_orphaned_configs())
        assert.is_true(ok)
    end)

    it("keeps the entry (unknown) and reports when the removal fails", function()
        add_orphan(ws, root)
        io_mod.rm_rf_async = function(_, cb) cb(false, "boom") end
        local ok = wait_done(cleanup_now)
        assert.is_false(ok, "a failed removal reported success")
        local orphans = ws:get_orphaned_configs()
        assert.equals(1, #orphans, "the orphan's entry was dropped although its tree is still there")
        assert.equals("unknown", orphans[1].build_dir_obj.state)
        assert.is_truthy(table.concat(errs, "\n"):find("boom", 1, true), table.concat(errs, "\n"))
    end)

    it("never removes a directory a live configuration still references", function()
        add_orphan(ws, root, built)
        assert.equals(1, #ws:get_build_dir_refs(ws._core._deps.normalize(built)), "test setup: the live unit references it")
        local removed = {}
        io_mod.rm_rf_async = function(d, cb)
            removed[#removed + 1] = d
            return real_rm(d, cb)
        end
        local ok = wait_done(cleanup_now)
        assert.same({}, removed, "a shared build directory was removed")
        assert.is_not_nil(uv.fs_stat(built))
        assert.equals(0, #ws:get_orphaned_configs(), "the orphan entry itself is dropped")
        assert.is_true(ok)
    end)

    it("calls on_done(false) when the deletion raises", function()
        local dir = add_orphan(ws, root)
        io_mod.rm_rf_async = function() error("rm exploded") end
        local ok = wait_done(cleanup_now)
        assert.is_false(ok)
        assert.is_not_nil(uv.fs_stat(dir))
    end)

    it("reports a failed stray removal and calls on_done(false)", function()
        local stray = root .. "/.nvim/build/App/Stray"
        vim.fn.mkdir(stray, "p")
        io_mod.rm_rf_async = function(_, cb) cb(false, "stray boom") end
        local ok = wait_done(cleanup_now)
        assert.is_false(ok, "a failed stray removal reported success")
        assert.is_truthy(table.concat(errs, "\n"):find("stray boom", 1, true), table.concat(errs, "\n"))
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
        assert.is_not_nil(deleted, "the orphan deletion never reached the owned LSP database cleanup")
        assert.equals(1, #deleted)
        assert.is_not_nil(deleted[1].mod, "an orphan's owned LSP database is never considered")
        assert.is_true(ok)
    end)
end)
