-- loomworks.deletion_plan and model_commands.execute_deletion (API.md §22
-- `Maintenance/1.execute_deletion`, step 5o part A2): every deletion target
-- is planned before any lock with a token of its lock and removal sets; a
-- confirmed token is compared again before any side effect and once more
-- under the workspace operation lock and the build-directory locks, so a
-- deletion never removes a directory the confirmation did not list.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local cli = require("loomworks.cli")
local bl = require("loomworks.build_lock")
local op_lock = require("loomworks.op_lock")
local dp = require("loomworks.deletion_plan")
local commands = require("loomworks.model_commands")
local reset_plan = require("loomworks.reset_plan")
local L = require("tests.lock_helpers")
local uv = vim.uv or vim.loop

local function load(root)
    local ws = assert(cli._load_workspace(root, false))
    ws._core._deps.on_lock_refused = nil
    return ws
end

local function find_app(ws)
    for _, p in pairs(ws:get_projects()) do
        if p.key == "App" then return p end
    end
end

local function mkstray(root, name)
    local dir = root .. "/.nvim/build/" .. name
    vim.fn.mkdir(dir, "p")
    return dir
end

--- Run a deletion to its end; the final outcome.
local function run(ws, target, plan)
    local final
    local r = commands.execute_deletion(ws, target, {
        plan = plan, yes = true, done = function(o) final = o end,
    })
    if r.outcome ~= "accepted" then return r end
    assert.is_true(vim.wait(10000, function() return final ~= nil end, 20), "never finished")
    return final
end

local function quiet(ws)
    local errs = {}
    ws._core._deps.notify = function(msg, level)
        if level == vim.log.levels.ERROR then errs[#errs + 1] = msg end
    end
    return errs
end

describe("deletion_plan.plan: the token", function()
    after_each(function() L.cleanup(); op_lock.release_all() end)

    it("is stable for an unchanged plan", function()
        local root = L.make_ws()
        local ws = load(root)
        local profile = ws._profiles[1]
        mkstray(root, "Old")
        for _, target in ipairs({ { profile = profile }, { unit = profile:projects()[1]._config_unit },
                { orphans = true }, { project = find_app(ws) } }) do
            local a, b = dp.plan(ws, target), dp.plan(ws, target)
            assert.is_nil(a.refusal)
            assert.equals(64, #a.token)
            assert.equals(a.token, b.token)
        end
    end)

    it("differs when a directory vanishes or appears", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local target = { profile = ws._profiles[1] }
        local before = dp.plan(ws, target)
        assert.same({ ws._core._deps.normalize(dir) }, before.removal_dirs)
        vim.fn.delete(dir, "rf")
        local gone = dp.plan(ws, target)
        assert.are_not.equal(before.token, gone.token)
        vim.fn.mkdir(dir, "p")
        assert.equals(before.token, dp.plan(ws, target).token)

        local orphans = dp.plan(ws, { orphans = true })
        mkstray(root, "New")
        local appeared = dp.plan(ws, { orphans = true })
        assert.are_not.equal(orphans.token, appeared.token)
        assert.equals(1, #appeared.strays)
    end)

    it("differs by target and from a reset token over the same directories", function()
        local root = L.make_ws()
        local ws = load(root)
        local p = dp.plan(ws, { profile = ws._profiles[1] })
        local u = dp.plan(ws, { unit = ws._profiles[1]:projects()[1]._config_unit })
        assert.same(p.lock_dirs, u.lock_dirs)
        assert.are_not.equal(p.token, u.token)
        assert.are_not.equal(p.token,
            reset_plan.token(p.scope_key, p.lock_dirs, p.removal_dirs, p.outside_dirs))
    end)
end)

describe("deletion_plan.plan: a stray directory", function()
    after_each(function() L.cleanup(); op_lock.release_all() end)

    it("is planned when it is in the current stray set", function()
        local root = L.make_ws()
        local ws = load(root)
        local dir = ws._core._deps.normalize(mkstray(root, "App/Stray"))
        local p = dp.plan(ws, { stray_dir = dir })
        assert.is_nil(p.refusal)
        -- The plan keeps the scan's spelling (long form), which may differ
        -- from the target's (8.3 short form on a CI runner's TEMP): compare
        -- canonical forms.
        local canon = function(d) return ws:_canonicalize_boundary_path(d) end
        assert.equals(1, #p.strays)
        assert.equals(canon(dir), canon(p.strays[1]))
        assert.equals(1, #p.lock_dirs)
        assert.equals(canon(dir), canon(p.lock_dirs[1]))
    end)

    it("is refused when not in the current stray set (a live build dir, a missing dir)", function()
        local root, built = L.make_ws()
        local ws = load(root)
        local live = dp.plan(ws, { stray_dir = built })
        assert.is_truthy(live.refusal and live.refusal:find("not a stray build directory", 1, true))
        local missing = dp.plan(ws, { stray_dir = root .. "/.nvim/build/Nope" })
        assert.is_truthy(missing.refusal and missing.refusal:find("not a stray build directory", 1, true))
    end)

    it("is refused outside the workspace", function()
        local root = L.make_ws()
        local ws = load(root)
        local p = dp.plan(ws, { stray_dir = L.tmpdir() })
        assert.is_truthy(p.refusal and p.refusal:find("outside workspace", 1, true))
        local r = commands.execute_deletion(ws, { stray_dir = root })
        assert.equals("refused", r.outcome)
    end)
end)

-- Step 5o C2d-2: the units whose build state a plan removes (the confirm's
-- `unit_ids`, API.md §22) — a matcher for the client's own tasks only.
describe("deletion_plan.units", function()
    after_each(function() L.cleanup(); op_lock.release_all() end)

    it("a project plan lists every unit of the project, also one no profile maps", function()
        local root = L.make_ws()
        local ws = load(root)
        local app = find_app(ws)
        local mapped = ws._profiles[1]:projects()[1]._config_unit
        local unmapped = ws:ensure_config_unit(app, app:ensure_configuration("Release"), mapped._tool)
        assert.are_not.equal(mapped, unmapped)
        local units = dp.units(dp.plan(ws, { project = app }))
        assert.equals(2, #units)
        assert.is_true(vim.tbl_contains(units, mapped))
        assert.is_true(vim.tbl_contains(units, unmapped))
        local c = commands.deletion_request(ws, { project = app })
        assert.equals("confirm", c.outcome)
        assert.equals(2, #c.units)
    end)

    it("a profile plan leaves out a unit it keeps (shared with another profile)", function()
        local root = L.make_ws()
        L.capture(function()
            cli.cmd_cset("create", root, { "configuration-set", "create", "Dev2", "App=Debug" })
            cli.cmd_profile_create(root, { "profile", "create", "Dev2" })
        end)
        local ws = load(root)
        assert.equals(2, #ws._profiles)
        local p = dp.plan(ws, { profile = ws._profiles[1] })
        assert.equals(1, #p.kept)
        assert.same({}, dp.units(p))
    end)

    it("a unit plan lists the unit; orphan and stray plans none", function()
        local root = L.make_ws()
        local ws = load(root)
        local unit = ws._profiles[1]:projects()[1]._config_unit
        assert.same({ unit }, dp.units(dp.plan(ws, { unit = unit })))
        local dir = ws._core._deps.normalize(mkstray(root, "App/Stray"))
        assert.same({}, dp.units(dp.plan(ws, { stray_dir = dir })))
        assert.same({}, dp.units(dp.plan(ws, { orphans = true })))
    end)
end)

describe("model_commands.execute_deletion", function()
    local io_mod = require("loomworks.io")
    local real_rm
    before_each(function() real_rm = io_mod.rm_rf_async end)
    after_each(function()
        io_mod.rm_rf_async = real_rm
        L.cleanup()
        op_lock.release_all()
    end)

    it("confirms with the listing and a token, locking and changing nothing", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local r = commands.execute_deletion(ws, { profile = ws._profiles[1] })
        assert.equals("confirm", r.outcome)
        assert.equals("Delete profile 'Dev':", r.lines[1])
        assert.is_truthy(table.concat(r.lines, "\n"):find("App / Debug", 1, true))
        assert.equals(dp.plan(ws, { profile = ws._profiles[1] }).token, r.plan)
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_nil(op_lock.read(root))
        assert.is_nil(bl.read(dir))
        assert.equals(1, #ws._profiles)
    end)

    it("refuses nothing to delete on standard output with exit 0", function()
        local root = L.make_ws()
        local ws = load(root)
        local r = commands.execute_deletion(ws, { orphans = true })
        assert.equals("refused", r.outcome)
        assert.equals(dp.NOTHING, r.message)
        assert.equals(0, r.exit_code)
        assert.equals("out", r.stream)
    end)

    it("refuses a changed plan before any side effect", function()
        local root = L.make_ws()
        local ws = load(root)
        local first = mkstray(root, "One")
        local token = commands.execute_deletion(ws, { orphans = true }).plan
        local second = mkstray(root, "Two")
        local removed = false
        io_mod.rm_rf_async = function(d, cb, o) removed = true; return real_rm(d, cb, o) end
        local r = commands.execute_deletion(ws, { orphans = true }, { plan = token, yes = true })
        assert.equals("refused", r.outcome)
        assert.equals(dp.CHANGED, r.message)
        assert.equals(1, r.exit_code)
        assert.is_false(removed)
        assert.is_not_nil(uv.fs_stat(first))
        assert.is_not_nil(uv.fs_stat(second))
    end)

    it("refuses a plan that changed between acceptance and the locks, removing nothing", function()
        local root = L.make_ws()
        local ws = load(root)
        quiet(ws)
        local first = mkstray(root, "One")
        local token = commands.execute_deletion(ws, { orphans = true }).plan
        local acc = commands.deletion_request(ws, { orphans = true }, token, true)
        assert.equals("accepted", acc.outcome)
        local second = mkstray(root, "Two") -- appears before the locks are taken
        local removed = false
        io_mod.rm_rf_async = function(d, cb, o) removed = true; return real_rm(d, cb, o) end
        local final
        commands.deletion_run(ws, acc.deletion, nil, function(o) final = o end)
        assert.is_true(vim.wait(5000, function() return final ~= nil end, 20))
        assert.equals("refused", final.outcome)
        assert.equals(dp.CHANGED, final.message)
        assert.is_false(removed)
        assert.is_not_nil(uv.fs_stat(first))
        assert.is_not_nil(uv.fs_stat(second))
        assert.is_true(vim.wait(2000, function() return op_lock.read(root) == nil end, 20), "O left behind")
    end)

    it("refuses a stray directory another process holds the build lock of", function()
        local root = L.make_ws()
        local ws = load(root)
        quiet(ws)
        local dir = mkstray(root, "App/Stray")
        local h = L.hold(bl.lock_path(dir), "configure")
        local r = run(ws, { stray_dir = dir })
        assert.equals("refused", r.outcome)
        assert.is_truthy(r.message:find("in use by lw configure (pid " .. h.pid, 1, true), r.message)
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_nil(op_lock.read(root), "O left behind")
    end)

    it("deletes a stray directory holding O and B, and releases both", function()
        local root = L.make_ws()
        local ws = load(root)
        local dir = mkstray(root, "App/Stray")
        local saw_o, saw_b = false, false
        io_mod.rm_rf_async = function(d, cb, o)
            saw_o = op_lock.read(root) ~= nil
            saw_b = bl.read(dir) ~= nil
            return real_rm(d, cb, o)
        end
        local token = commands.execute_deletion(ws, { stray_dir = dir }).plan
        local r = run(ws, { stray_dir = dir }, token)
        assert.equals("ok", r.outcome)
        assert.is_true(saw_o and saw_b, "O and B held during the removal")
        assert.is_nil(uv.fs_stat(dir))
        assert.is_true(vim.wait(2000, function()
            return op_lock.read(root) == nil and bl.read(dir) == nil
        end, 20), "locks not released")
    end)

    it("refuses a stray directory not in the current set and removes nothing", function()
        local root, built = L.make_ws()
        local ws = load(root)
        local r = commands.execute_deletion(ws, { stray_dir = built }, { yes = true })
        assert.equals("refused", r.outcome)
        assert.is_not_nil(uv.fs_stat(built))
    end)

    it("deletes a profile and the build directory only it uses", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local profile = ws._profiles[1]
        local token = commands.execute_deletion(ws, { profile = profile }).plan
        local r = run(ws, { profile = profile }, token)
        assert.equals("ok", r.outcome)
        assert.equals(0, #ws._profiles)
        assert.is_true(profile._removed)
        assert.is_nil(uv.fs_stat(dir))
        -- A stale profile is refused.
        assert.equals("refused", commands.execute_deletion(ws, { profile = profile }).outcome)
    end)

    it("removes a project after its build state", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        local app = find_app(ws)
        local c = commands.execute_deletion(ws, { project = app })
        assert.equals("confirm", c.outcome)
        local r = run(ws, { project = app }, c.plan)
        assert.equals("ok", r.outcome)
        assert.is_nil(find_app(ws))
        assert.is_nil(uv.fs_stat(dir))
    end)

    it("keeps a project, its cache entry and refuses when removing its build dir fails", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        quiet(ws)
        local app = find_app(ws)
        local function app_entries()
            local n = 0
            for _, e in pairs(ws:_serialize_cache().build_dirs or {}) do
                if e.project_key == "App" then n = n + 1 end
            end
            return n
        end
        assert.is_true(app_entries() > 0)
        io_mod.rm_rf_async = function(_, cb)
            if cb then cb(false, "access denied") end
            return require("loomworks.future").rejected("access denied")
        end
        local c = commands.execute_deletion(ws, { project = app })
        local r = run(ws, { project = app }, c.plan)
        assert.equals("refused", r.outcome)
        assert.equals(app, find_app(ws))
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_true(app_entries() > 0, "cache entry dropped")
        assert.is_true(vim.wait(2000, function() return op_lock.read(root) == nil end, 20), "O left behind")
        assert.is_nil(bl.read(dir), "B left behind")
    end)

    it("refuses with the error when the deletion throws synchronously, releasing every lock", function()
        local root, dir = L.make_ws()
        local ws = load(root)
        quiet(ws)
        local profile = ws._profiles[1]
        local token = commands.execute_deletion(ws, { profile = profile }).plan
        local removed = false
        io_mod.rm_rf_async = function(d, cb, o) removed = true; return real_rm(d, cb, o) end
        ws._save_user = function() error("save failed: disk full", 0) end
        local r = run(ws, { profile = profile }, token)
        assert.equals("refused", r.outcome)
        assert.is_truthy(tostring(r.message):find("save failed: disk full", 1, true), r.message)
        assert.is_false(removed)
        assert.is_not_nil(uv.fs_stat(dir))
        assert.is_nil(op_lock.read(root), "O left behind")
        assert.is_nil(bl.read(dir), "B left behind")
    end)

    it("deletes an orphaned build directory given as its object", function()
        local root = L.make_ws()
        local ws = load(root)
        local dir = root .. "/.nvim/build/App/Release"
        vim.fn.mkdir(dir, "p")
        local cache = ws:_serialize_cache()
        cache.build_dirs = cache.build_dirs or {}
        cache.build_dirs["App/Release"] = {
            project_key = "App", config_key = "Release", type = "typescript",
            variant = "default", state = "built", build_dir = dir,
        }
        ws:remerge(nil, cache)
        local bd = assert(ws:get_orphaned_configs()[1]).build_dir_obj
        local c = commands.execute_deletion(ws, { build_dir = bd })
        assert.equals("confirm", c.outcome)
        local r = run(ws, { build_dir = bd }, c.plan)
        assert.equals("ok", r.outcome)
        assert.is_nil(uv.fs_stat(dir))
        assert.equals(0, #ws:get_orphaned_configs())
        -- No longer an orphan: refused.
        assert.equals("refused", commands.execute_deletion(ws, { build_dir = bd }).outcome)
    end)
end)
