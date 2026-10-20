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

    -- Not an orphan, but the same crash rule (spec §4.6): a configured
    -- unit's cache entry is serialized from its BuildDir, so marking only the
    -- unit left the on-disk entry `built` while its tree was being removed.
    it("marks a configured unit's cache entry unknown on disk before removing its tree", function()
        local entry_state
        io_mod.rm_rf_async = function(d, cb)
            if not entry_state then
                local cache = vim.json.decode(read(root .. "/.nvim/loomworks.cache.json") or "{}")
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
        quiet(function() cli.cmd_configuration("add", root, "App", "Other", "variant:default") end)
        ws = assert(cli._load_workspace(root, false))
        ws._core._deps.notify = function(msg, level)
            if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
        end
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
                local cache = vim.json.decode(read(root .. "/.nvim/loomworks.cache.json") or "{}")
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
        local cache = vim.json.decode(read(root .. "/.nvim/loomworks.cache.json") or "{}")
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
-- it: a failed cleanup must not be announced as success.
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
        render(tree, { lw = lw })
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
