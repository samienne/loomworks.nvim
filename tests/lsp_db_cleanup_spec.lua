--- Owned LSP database cleanup (spec §4.6 "Owned LSP database cleanup", §8.4
--- `lsp_database_root` / `lsp_database_dir`, ui §1.11 check 4): a build
--- directory's module-owned database mirror under `.nvim/cache/<area>/` is
--- removed with it — only after the build dir's deletion succeeded, never while
--- another build dir maps to it, never outside the area, never through a link —
--- and nuke removes the whole area (aborting entirely on a linked area).
--- Fixtures are real scratch directories; assertions are about what survives.

local workspace = require("loomworks.workspace")
local merge = require("loomworks.merge")
local cache_mod = require("loomworks.cache")
local io_mod = require("loomworks.io")
local cleanup = require("loomworks.lsp_db_cleanup")
local cmake = require("loomworks.modules.cmake")
local h = require("tests.helpers")

local uv = vim.uv or vim.loop
local IS_WIN = vim.fn.has("win32") == 1

local function norm(p)
    p = (p or ""):gsub("\\", "/"):gsub("/+$", "")
    return IS_WIN and p:lower() or p
end

local function touch(p, text)
    vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
    local f = assert(io.open(p, "w")); f:write(text or "x"); f:close()
end

local function exists(p) return uv.fs_lstat(p) ~= nil end

--- Link `path` -> directory `target` (a junction on Windows: no privilege needed).
local function dir_link(target, path)
    local ok = uv.fs_symlink(target, path, IS_WIN and { junction = true } or nil)
    return ok == true
end

local function new_tmp()
    local t = (vim.fn.tempname():gsub("\\", "/"))
    vim.fn.mkdir(t, "p")
    -- Resolve so the root has its real on-disk form (8.3 / case on Windows).
    return (uv.fs_realpath(t):gsub("\\", "/"))
end

-- =========================================================================
-- Path checks (rules 3–5)
-- =========================================================================

describe("lsp_db_cleanup.check_mirror", function()
    local root
    before_each(function()
        root = new_tmp()
        touch(root .. "/.nvim/cache/cc/App/Debug/compile_commands.json")
        touch(root .. "/.nvim/cache/cc2/App/Debug/compile_commands.json")
        touch(root .. "/precious/keep.txt")
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    it("approves a mirror strictly inside the area", function()
        local st, path, area = cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/App/Debug", norm)
        assert.equals("ok", st, tostring(path))
        assert.equals(norm(root .. "/.nvim/cache/cc/App/Debug"), norm(path))
        assert.equals(root .. "/.nvim/cache/cc", area)
    end)

    it("nil / empty inputs mean nothing to remove", function()
        assert.equals("absent", (cleanup.check_mirror(root, "cc", nil, norm)))
        assert.equals("absent", (cleanup.check_mirror(root, "cc", "", norm)))
        assert.equals("absent", (cleanup.check_mirror(root, nil, root .. "/.nvim/cache/cc/App", norm)))
        assert.equals("absent", (cleanup.check_mirror(nil, "cc", root .. "/.nvim/cache/cc/App", norm)))
        assert.equals("absent", (cleanup.check_mirror("", "cc", root .. "/.nvim/cache/cc/App", norm)))
    end)

    it("a missing mirror is absent, not an error", function()
        assert.equals("absent", (cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/Nope/Debug", norm)))
    end)

    it("refuses '..' segments, even ones resolving back inside", function()
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/../../../precious", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/App/../App/Debug", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/./App", norm)))
    end)

    it("refuses a prefix collision (cc vs cc2) and the area itself", function()
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc2/App/Debug", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/precious", norm)))
    end)

    it("refuses an invalid area segment", function()
        for _, seg in ipairs({ ".", "..", "a/b", "a\\b", "c:" }) do
            assert.is_nil((cleanup.check_mirror(root, seg, root .. "/.nvim/cache/cc/App", norm)), seg)
        end
    end)

    it("refuses segments Win32 would trim (trailing dot / space) on Windows", function()
        if not IS_WIN then pending("Windows path semantics") return end
        -- "App/.. " is opened as "App/.." by Win32 — i.e. the area itself.
        for _, tail in ipairs({ "App/.. ", "App/. ", "App.", "App ", "App/Debug.", "App/Debug " }) do
            assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/" .. tail, norm)), tail)
        end
        for _, seg in ipairs({ "cc.", "cc " }) do
            assert.is_nil((cleanup.check_mirror(root, seg, root .. "/.nvim/cache/" .. seg .. "/App", norm)), seg)
            assert.is_nil((cleanup.check_area(root, seg, norm)), seg)
        end
        assert.is_true(exists(root .. "/.nvim/cache/cc/App/Debug/compile_commands.json"))
    end)

    it("refuses a mirror whose realpath leaves the area (even inside .nvim)", function()
        local real_fn = uv.fs_realpath
        local mirror = root .. "/.nvim/cache/cc/App/Debug"
        uv.fs_realpath = function(p)
            if norm(p) == norm(mirror) then return root .. "/.nvim/cache/cc2/App/Debug" end
            return real_fn(p)
        end
        local ok, st = pcall(cleanup.check_mirror, root, "cc", mirror, norm)
        uv.fs_realpath = real_fn
        assert.is_true(ok, tostring(st))
        assert.is_nil(st)
    end)

    it("refuses a link inside the mirror path", function()
        vim.fn.delete(root .. "/.nvim/cache/cc/App", "rf")
        vim.fn.mkdir(root .. "/precious/Debug", "p")
        if not dir_link(root .. "/precious", root .. "/.nvim/cache/cc/App") then
            pending("cannot create a directory link here") return
        end
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/App/Debug", norm)))
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/App", norm)))
    end)

    it("refuses a linked area / cache dir", function()
        local elsewhere = new_tmp()
        touch(elsewhere .. "/App/Debug/compile_commands.json")
        vim.fn.delete(root .. "/.nvim/cache/cc", "rf")
        if not dir_link(elsewhere, root .. "/.nvim/cache/cc") then
            vim.fn.delete(elsewhere, "rf")
            pending("cannot create a directory link here") return
        end
        assert.is_nil((cleanup.check_mirror(root, "cc", root .. "/.nvim/cache/cc/App/Debug", norm)))
        assert.is_nil((cleanup.check_area(root, "cc", norm)))
        uv.fs_unlink(root .. "/.nvim/cache/cc"); uv.fs_rmdir(root .. "/.nvim/cache/cc")
        vim.fn.delete(elsewhere, "rf")
    end)
end)

describe("cmake lsp_database_dir", function()
    it("mirrors the build dir tail under .nvim/cache/cc", function()
        assert.equals("cc", cmake.lsp_database_root)
        assert.equals("C:/ws/.nvim/cache/cc/App/ninja/Debug",
            cmake.lsp_database_dir({ workspace_root = "C:/ws", build_dir = "C:/ws/.nvim/build/App/ninja/Debug" }))
        assert.is_nil(cmake.lsp_database_dir({ workspace_root = "C:/ws" }))
        assert.is_nil(cmake.lsp_database_dir({ workspace_root = "", build_dir = "C:/ws/b" }))
        assert.is_nil(cmake.lsp_database_dir(nil))
    end)
end)

-- =========================================================================
-- Workspace deletion paths
-- =========================================================================

local function wait(pred) return vim.wait(20000, pred, 10) end

--- A workspace rooted at a real scratch dir. `mod` is the cmake-like mock
--- module (declares the owned-database interface by default).
local function make_ws(root, build_dirs, mod_overrides)
    local mod = {
        has_keyed_tools = true,
        map_variant = function(variant_type, available)
            for _, name in ipairs(available) do
                if name:lower() == variant_type then return name end
            end
        end,
        tool_key = function(td) return td.id end,
        tool_label = function(td) return td.display end,
        detect_tools_async = function(cb) cb({}) end,
        info = function() return { configurations = { Debug = {}, Release = {} } } end,
        lsp_database_root = "cc",
        lsp_database_dir = cmake.lsp_database_dir,
    }
    for k, v in pairs(mod_overrides or {}) do mod[k] = v end
    local data = workspace.assemble(root, h.make_config_json({ projects = { App = { cmake = {} } } }),
        nil, h.make_cache_json({ build_dirs = build_dirs }), { trust = h.trust_all })
    assert(data, "assemble failed")
    local notes = {}
    local core = {
        _deps = {
            merge = merge, cache = cache_mod,
            events = { emit = function() end },
            user = { save = function() return true end },
            io = {
                write_json = function() return true end,
                ensure_dir = function() return true end,
                rm_rf_async = io_mod.rm_rf_async,
            },
            normalize = norm,
            modules = { get = function(id) if id == "cmake" then return mod end end },
            notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end,
            schedule = function(fn) fn() end,
        },
    }
    local ws = workspace.Workspace.new(core, data)
    ws:_cleanup_orphaned_skeletons(data.cache)
    ws:remerge(data.config, data.cache, data.user)
    return ws, notes
end

--- A live ConfigUnit for App/<variant> pointing at `bd_path` (and at the
--- cached BuildDir for that path when there is one).
local function add_unit(ws, variant, bd_path)
    local proj
    for _, p in pairs(ws._projects) do if p.key == "App" then proj = p end end
    assert(proj, "no App project")
    local cfg = proj:ensure_configuration(variant)
    local unit = ws:ensure_config_unit(proj, cfg, nil)
    unit.build_dir_value = bd_path
    unit.state_value = "configured"
    for _, b in pairs(ws._build_dirs) do
        if norm(b.path) == norm(bd_path) then unit._build_dir = b end
    end
    ws:_sync_build_dir_refs()
    return unit
end

local function entry(variant, build_dir)
    return {
        project_key = "App", config_key = variant .. ":ninja",
        type = "cmake", variant = variant, tool_key = "ninja",
        state = "configured", build_dir = build_dir,
    }
end

local function run_deletion(ws, items)
    local done = false
    ws:_run_deletion(items, function(eff) ws:reset_cached_configs(eff) end, function() done = true end)
    assert.is_true(wait(function() return done end), "deletion did not complete")
end

describe("owned LSP database removed with its build directory", function()
    local root, bd_debug, bd_release, cc_debug, cc_release
    before_each(function()
        root = new_tmp()
        touch(root .. "/loomworks.json", "{}")
        bd_debug = root .. "/.nvim/build/App/ninja/Debug"
        bd_release = root .. "/.nvim/build/App/ninja/Release"
        cc_debug = root .. "/.nvim/cache/cc/App/ninja/Debug"
        cc_release = root .. "/.nvim/cache/cc/App/ninja/Release"
        touch(bd_debug .. "/CMakeCache.txt")
        touch(bd_release .. "/CMakeCache.txt")
        touch(cc_debug .. "/compile_commands.json")
        touch(cc_release .. "/compile_commands.json")
        touch(root .. "/.nvim/cache/lw-0.1.0-x")  -- unrelated cache content
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    local UNIT_DEBUG, UNIT_RELEASE
    local function two_unit_ws(overrides)
        local ws = make_ws(root, {
            ["build/App/ninja/Debug"] = entry("Debug", bd_debug),
            ["build/App/ninja/Release"] = entry("Release", bd_release),
        }, overrides)
        UNIT_DEBUG = add_unit(ws, "Debug", bd_debug)
        UNIT_RELEASE = add_unit(ws, "Release", bd_release)
        assert.are_not.equal(UNIT_DEBUG, UNIT_RELEASE)
        return ws
    end

    it("delete/reset of a unit removes its mirror (and empty ancestors), nothing else", function()
        local ws = two_unit_ws()
        local unit = UNIT_DEBUG
        assert.is_not_nil(unit)
        run_deletion(ws, { { unit = unit, build_dir = bd_debug, disposition = "reset" } })
        assert.is_true(wait(function() return not exists(cc_debug) end), "mirror should be removed")
        assert.is_false(exists(bd_debug))
        assert.is_true(exists(cc_release .. "/compile_commands.json"))
        assert.is_true(exists(bd_release .. "/CMakeCache.txt"))
        assert.is_true(exists(root .. "/.nvim/cache/cc"))
        assert.is_true(exists(root .. "/.nvim/cache/lw-0.1.0-x"))
    end)

    it("prunes emptied ancestors up to (not including) the area", function()
        local ws = two_unit_ws()
        local d = UNIT_DEBUG
        local r = UNIT_RELEASE
        run_deletion(ws, {
            { unit = d, build_dir = bd_debug, disposition = "reset" },
            { unit = r, build_dir = bd_release, disposition = "reset" },
        })
        assert.is_true(wait(function() return not exists(root .. "/.nvim/cache/cc/App") end))
        assert.is_true(exists(root .. "/.nvim/cache/cc"))
    end)

    it("keeps the mirror when the build dir deletion fails", function()
        local ws = two_unit_ws()
        ws._core._deps.io.rm_rf_async = function(dir, cb)
            if norm(dir) == norm(bd_debug) then cb(false, "locked") else io_mod.rm_rf_async(dir, cb) end
        end
        local unit = UNIT_DEBUG
        run_deletion(ws, { { unit = unit, build_dir = bd_debug, disposition = "reset" } })
        vim.wait(200)
        assert.is_true(exists(cc_debug .. "/compile_commands.json"))
    end)

    it("keeps the mirror of a build dir skipped as still referenced", function()
        -- Both units share one build dir; deleting only one skips the rm-rf.
        local shared_cc = root .. "/.nvim/cache/cc/App/ninja/Shared"
        local shared = root .. "/.nvim/build/App/ninja/Shared"
        touch(shared .. "/CMakeCache.txt")
        touch(shared_cc .. "/compile_commands.json")
        local ws = make_ws(root, {
            ["build/App/ninja/Debug"] = entry("Debug", shared),
            ["build/App/ninja/Release"] = entry("Release", shared),
        })
        local unit = add_unit(ws, "Debug", shared)
        add_unit(ws, "Release", shared)
        assert.equals(2, #ws:get_build_dir_refs(norm(shared)))
        run_deletion(ws, { { unit = unit, build_dir = shared, disposition = "reset" } })
        vim.wait(200)
        assert.is_true(exists(shared .. "/CMakeCache.txt"))
        assert.is_true(exists(shared_cc .. "/compile_commands.json"))
    end)

    it("keeps a mirror another remaining build dir maps to", function()
        local ws = two_unit_ws({
            lsp_database_dir = function() return root .. "/.nvim/cache/cc/App/ninja/Debug" end,
        })
        local unit = UNIT_DEBUG
        run_deletion(ws, { { unit = unit, build_dir = bd_debug, disposition = "reset" } })
        vim.wait(200)
        assert.is_false(exists(bd_debug))
        assert.is_true(exists(cc_debug .. "/compile_commands.json"))
    end)

    it("keeps a mirror that contains a remaining build dir's mirror", function()
        -- Out-of-tree style mapping: Debug's mirror is an ANCESTOR of Release's,
        -- so removing it would take Release's live database with it.
        local outer = root .. "/.nvim/cache/cc/App/ninja"
        touch(outer .. "/compile_commands.json")
        local ws = two_unit_ws({
            lsp_database_dir = function(ctx)
                if norm(ctx.build_dir) == norm(bd_debug) then return outer end
                return cc_release
            end,
        })
        run_deletion(ws, { { unit = UNIT_DEBUG, build_dir = bd_debug, disposition = "reset" } })
        vim.wait(200)
        assert.is_false(exists(bd_debug))
        assert.is_true(exists(outer .. "/compile_commands.json"))
        assert.is_true(exists(cc_release .. "/compile_commands.json"))
    end)

    it("removes a mirror nested inside a remaining build dir's mirror", function()
        local outer = root .. "/.nvim/cache/cc/App/ninja"
        touch(outer .. "/compile_commands.json")
        local ws = two_unit_ws({
            lsp_database_dir = function(ctx)
                if norm(ctx.build_dir) == norm(bd_debug) then return cc_debug end
                return outer
            end,
        })
        run_deletion(ws, { { unit = UNIT_DEBUG, build_dir = bd_debug, disposition = "reset" } })
        assert.is_true(wait(function() return not exists(cc_debug) end), "inner mirror should be removed")
        assert.is_true(exists(outer .. "/compile_commands.json"))
    end)

    it("refuses a module mirror escaping the area", function()
        local ws = two_unit_ws({
            lsp_database_dir = function(ctx)
                if norm(ctx.build_dir) == norm(bd_debug) then
                    return root .. "/.nvim/cache/cc/../../build/App/ninja/Release"
                end
            end,
        })
        local unit = UNIT_DEBUG
        run_deletion(ws, { { unit = unit, build_dir = bd_debug, disposition = "reset" } })
        vim.wait(200)
        assert.is_true(exists(bd_release .. "/CMakeCache.txt"))
        assert.is_true(exists(cc_debug .. "/compile_commands.json"))
    end)

    it("a module without the interface, or a nil build dir, removes nothing", function()
        local ws = two_unit_ws({ lsp_database_root = false, lsp_database_dir = false })  -- false: pairs() skips nil
        local unit = UNIT_DEBUG
        run_deletion(ws, {
            { unit = unit, build_dir = bd_debug, disposition = "reset" },
            { unit = UNIT_RELEASE, build_dir = nil, disposition = "reset" },
        })
        vim.wait(200)
        assert.is_false(exists(bd_debug))
        assert.is_true(exists(cc_debug .. "/compile_commands.json"))
        assert.is_true(exists(cc_release .. "/compile_commands.json"))
    end)

    it("orphan deletion removes the orphan's mirror", function()
        local ws = make_ws(root, { ["build/App/ninja/Debug"] = entry("Debug", bd_debug) })
        -- Make the Debug dir an orphan: no unit references it.
        local bd
        for _, b in ipairs(ws._build_dirs) do if norm(b.path) == norm(bd_debug) then bd = b end end
        assert.is_not_nil(bd)
        for _, u in pairs(ws._config_units) do if u._build_dir == bd then u._build_dir = nil; u.build_dir_value = nil end end
        local done = false
        ws:delete_orphaned_build_dir(bd.rel_path):next(function() done = true end)
        assert.is_true(wait(function() return done end))
        assert.is_false(exists(bd_debug))
        assert.is_false(exists(cc_debug))
        assert.is_true(exists(cc_release .. "/compile_commands.json"))
    end)
end)

-- =========================================================================
-- Nuke
-- =========================================================================

describe("nuke removes owned LSP database areas", function()
    local Core = require("loomworks.core")
    local root
    local function make_core(notes)
        return Core.new({
            notify = function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end,
            normalize = norm,
            modules = {
                list = function() return { "cmake", "other" } end,
                get = function(id)
                    if id == "cmake" then return { lsp_database_root = "cc" } end
                    return { id = "other" }
                end,
            },
        })
    end

    before_each(function()
        root = new_tmp()
        touch(root .. "/loomworks.json", "{}")
        touch(root .. "/.nvim/build/App/Debug/CMakeCache.txt")
        touch(root .. "/.nvim/cache/cc/App/Debug/compile_commands.json")
        touch(root .. "/.nvim/cache/cc2/keep.json")
        touch(root .. "/.nvim/cache/lw-0.1.0-x")
    end)
    after_each(function() vim.fn.delete(root, "rf") end)

    it("removes .nvim/cache/cc and nothing else under .nvim/cache", function()
        local notes = {}
        local core = make_core(notes)
        assert.is_not_nil(core:_nuke_files(root))
        assert.is_false(exists(root .. "/.nvim/cache/cc"))
        assert.is_false(exists(root .. "/.nvim/build"))
        assert.is_true(exists(root .. "/.nvim/cache/cc2/keep.json"))
        assert.is_true(exists(root .. "/.nvim/cache/lw-0.1.0-x"))
    end)

    it("lists only areas present on disk", function()
        local core = make_core({})
        assert.equals(1, #core:_nuke_lsp_db_areas(norm(root)))
        vim.fn.delete(root .. "/.nvim/cache/cc", "rf")
        assert.equals(0, #core:_nuke_lsp_db_areas(norm(root)))
    end)

    it("aborts entirely (deletes nothing) when the area is a link", function()
        local elsewhere = new_tmp()
        touch(elsewhere .. "/precious.txt")
        vim.fn.delete(root .. "/.nvim/cache/cc", "rf")
        if not dir_link(elsewhere, root .. "/.nvim/cache/cc") then
            vim.fn.delete(elsewhere, "rf")
            pending("cannot create a directory link here") return
        end
        local notes = {}
        local core = make_core(notes)
        assert.is_nil(core:_nuke_files(root))
        assert.is_true(exists(elsewhere .. "/precious.txt"))
        assert.is_true(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
        local found = false
        for _, n in ipairs(notes) do if n.msg:find("aborting nuke") then found = true end end
        assert.is_true(found)
        uv.fs_unlink(root .. "/.nvim/cache/cc"); uv.fs_rmdir(root .. "/.nvim/cache/cc")
        vim.fn.delete(elsewhere, "rf")
    end)

    it("aborts when .nvim/cache itself is a link", function()
        local elsewhere = new_tmp()
        touch(elsewhere .. "/cc/precious.txt")
        vim.fn.delete(root .. "/.nvim/cache", "rf")
        if not dir_link(elsewhere, root .. "/.nvim/cache") then
            vim.fn.delete(elsewhere, "rf")
            pending("cannot create a directory link here") return
        end
        local core = make_core({})
        assert.is_nil(core:_nuke_files(root))
        assert.is_true(exists(elsewhere .. "/cc/precious.txt"))
        assert.is_true(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
        uv.fs_unlink(root .. "/.nvim/cache"); uv.fs_rmdir(root .. "/.nvim/cache")
        vim.fn.delete(elsewhere, "rf")
    end)

    it("aborts on a module declaring an invalid area name", function()
        local core = Core.new({
            notify = function() end, normalize = norm,
            modules = {
                list = function() return { "bad" } end,
                get = function() return { lsp_database_root = "../build" } end,
            },
        })
        assert.is_nil(core:_nuke_files(root))
        assert.is_true(exists(root .. "/.nvim/build/App/Debug/CMakeCache.txt"))
    end)
end)
