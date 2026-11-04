-- loomworks.Maintenance/1.execute_deletion in the workspace daemon (API.md
-- §22; step 5o part B5), over the loopback transport on the conformance
-- runner's `shell` fixture: the confirmation's plan token, a changed plan
-- refused before anything is removed, the stray-directory refusals, a
-- confirmed deletion removing the directory and its cached state, and a
-- cancel stopping the deletion between entries; and Maintenance/1.nuke
-- (part B6): its locks and the daemon's own tasks refused before the
-- listing and again under the locks, its plan token, a failed area check
-- removing nothing, and a cancel ending `nuke stopped: <reason>`.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local uv = vim.uv or vim.loop
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")
local trust = require("loomworks.trust")
local dp = require("loomworks.deletion_plan")
local maint = require("loomworks.daemon.maintenance")
local runner = dofile(H.REPO .. "/scripts/conformance.lua")

--- A loopback daemon on a fresh `shell` fixture, handshaken.
local function session()
    local key = (vim.fn.tempname():gsub("\\", "/")) .. "/trust.key"
    vim.fn.mkdir(vim.fn.fnamemodify(key, ":h"), "p")
    trust._set_key_path(key)
    local root = runner.fixture("shell", key)
    trust._set_key_path(key)
    local d = runner.loopback_driver(root)
    local s = { d = d, root = root, env = runner.wire_env(uv.os_environ()), inbox = {}, req = 0 }
    function s.send(f) assert(d.send(f)) end
    function s.wait(pred, ms)
        local deadline = uv.now() + (ms or 30000)
        while true do
            for i, f in ipairs(s.inbox) do
                if pred(f) then table.remove(s.inbox, i); return f end
            end
            local left = deadline - uv.now()
            assert(left > 0, "timed out waiting for a frame")
            local f = d.recv(math.min(left, 50))
            if f then s.inbox[#s.inbox + 1] = f end
        end
    end
    function s.call(object, iface, method, args, env)
        s.req = s.req + 1
        local id = s.req
        s.send({ kind = "call", req_id = id, object = object, iface = iface, v = 1, method = method,
            args = args or vim.empty_dict(), env = env })
        local f = s.wait(function(m) return m.req_id == id end)
        assert.equals("ok", f.kind, vim.inspect(f))
        return f.result
    end
    function s.delete(args) return s.call("/maintenance", "loomworks.Maintenance", "execute_deletion", args, s.env) end
    function s.nuke(args)
        return s.call("/maintenance", "loomworks.Maintenance", "nuke", args or vim.empty_dict(), s.env)
    end
    function s.done(task_id, ms)
        local lines = {}
        while true do
            local f = s.wait(function(m)
                return m.kind == "task" and m.task_id == task_id and (m.phase == "line" or m.phase == "done")
            end, ms)
            if f.phase == "done" then return f, lines end
            lines[#lines + 1] = f.stream .. ": " .. f.text
        end
    end
    function s.build()
        local r = s.call("/build", "loomworks.Build", "build", { profile = { key = "dev" } }, s.env)
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 120000)
        assert.equals(0, f.exit_code)
    end
    function s.service() return d.server.service end
    function s.ws() return s.service().ws end
    function s.unit()
        for _, p in pairs(s.ws()._profiles) do
            if p.key == "dev" and not p._removed then return p:projects()[1]._config_unit end
        end
    end
    function s.id(obj) return s.service().ids:id(obj) end
    s.send({ kind = "hello", protocol = 11, client = "editor", lw_version = require("loomworks.daemon.version").identity() })
    s.wait(function(m) return m.kind == "welcome" end)
    function s.close()
        pcall(d.close)
        trust._set_key_path(nil)
    end
    return s
end

local function exists(p) return uv.fs_stat(p) ~= nil end

--- A stray build directory (no cache entry references it) with a file.
local function stray(root, name)
    local dir = root .. "/.nvim/build/" .. name
    vim.fn.mkdir(dir .. "/sub", "p")
    local f = assert(io.open(dir .. "/sub/f.txt", "w")); f:write("x"); f:close()
    return dir
end

describe("Maintenance/1.execute_deletion in the workspace daemon (API.md §22)", function()
    local s
    after_each(function()
        L.cleanup()
        if s then s.close(); s = nil end
    end)

    it("a confirmed unit deletion removes its build directory and clears its cached state", function()
        s = session()
        s.build()
        local unit = s.unit()
        local bd = unit:build_dir()
        assert.is_true(exists(bd))
        local target = { unit = { id = s.id(unit) } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        assert.is_true(#c.lines > 0)
        assert.is_true(exists(bd), "a confirm removes nothing")
        local r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local start = s.wait(function(m) return m.kind == "task" and m.task_id == r.task_id and m.phase == "start" end)
        assert.equals("delete", start.meta.kind)
        assert.equals("execute_deletion", start.meta.method)
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.equals("out: DELETE OK: " .. start.meta.name, lines[#lines], vim.inspect(lines))
        assert.is_false(exists(bd))
        -- Its cached state cleared, in the model and on disk.
        local u = s.unit()
        assert.is_true(u.state_value == nil or u.state_value == "unconfigured", tostring(u.state_value))
        local fh = assert(io.open(s.root .. "/.nvim/loomworks.cache.json", "rb"))
        local text = fh:read("*a"); fh:close()
        assert.is_nil(text:find('"built"', 1, true), text)
        -- Nothing left: the same target is now nothing to delete (stdout).
        local again = s.delete({ target = { unit = { id = s.id(s.unit()) } } })
        assert.equals("refused", again.outcome, vim.inspect(again))
        assert.equals(dp.NOTHING, again.message)
        assert.equals(0, again.exit_code)
        assert.equals("out", again.stream)
    end)

    it("a unit named { project, configuration } is the unit its id names; an unknown one is refused", function()
        s = session()
        s.build()
        local bd = s.unit():build_dir()
        local r = s.delete({ target = { unit = { project = "app", configuration = "Nope" } } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals("no configuration unit 'app/Nope'", r.message)
        local by_id = s.delete({ target = { unit = { id = s.id(s.unit()) } } })
        local target = { unit = { project = "app", configuration = "Debug" } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        assert.equals(by_id.plan, c.plan)
        r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.is_false(exists(bd))
    end)

    it("a stale plan token is refused before anything is removed", function()
        s = session()
        s.build()
        local unit = s.unit()
        local bd = unit:build_dir()
        local target = { unit = { id = s.id(unit) } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        -- A new stray directory does not change this plan; another token does.
        local r = s.delete({ target = target, yes = true, plan = c.plan .. "x" })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(dp.CHANGED, r.message)
        assert.equals(1, r.exit_code)
        assert.is_true(exists(bd))
        -- The listed directory vanished: changed, never "nothing to delete".
        vim.fn.delete(bd, "rf")
        r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(dp.CHANGED, r.message)
    end)

    it("a stray dir outside the workspace, not in the stray set, or a stale id is refused", function()
        s = session()
        s.build()
        local outside = (vim.fn.tempname():gsub("\\", "/")) .. "/build"
        vim.fn.mkdir(outside, "p")
        local r = s.delete({ target = { stray_dir = outside }, yes = true })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.truthy(r.message:find("path outside workspace: ", 1, true), r.message)
        assert.is_true(exists(outside))
        -- Under the workspace but no stray build directory (a project dir).
        local inside = s.root .. "/.nvim/build/not-there"
        r = s.delete({ target = { stray_dir = inside }, yes = true })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.truthy(r.message:find("not a stray build directory: ", 1, true), r.message)
        -- The live build directory itself is no stray.
        local bd = s.unit():build_dir()
        r = s.delete({ target = { stray_dir = bd }, yes = true })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.is_true(exists(bd))
        r = s.delete({ target = { build_dir = { id = "nope" } } })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.truthy(r.message:find("stale reference", 1, true), r.message)
    end)

    it("a listed stray directory is removed once confirmed", function()
        s = session()
        s.build()
        local dir = stray(s.root, "old")
        local c = s.delete({ target = { stray_dir = dir } })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local r = s.delete({ target = { stray_dir = dir }, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, tostring(f.error))
        assert.is_false(exists(dir))
        assert.is_true(exists(s.unit():build_dir()))
    end)

    it("an orphaned build directory is named by its id from view.Workspace/1 and removed", function()
        s = session()
        s.build()
        local ws = s.ws()
        local dir = s.root .. "/.nvim/build/gone/Debug"
        vim.fn.mkdir(dir, "p")
        local cache = ws:_serialize_cache()
        cache.build_dirs = cache.build_dirs or {}
        cache.build_dirs["gone/Debug"] = { project_key = "gone", config_key = "Debug", type = "shell",
            variant = "Debug", state = "built", build_dir = dir }
        ws:remerge(nil, cache)
        ws:_save_cache()
        local v = s.call("/views", "loomworks.view.Workspace", "get", nil, s.env)
        local row
        for _, o in ipairs(v.orphaned.configurations) do
            if o.key == "gone/Debug" or (o.build_dir and o.build_dir:find("gone", 1, true)) then row = o end
        end
        assert.is_not_nil(row, vim.inspect(v.orphaned))
        assert.is_string(row.id, vim.inspect(row))
        local target = { build_dir = { id = row.id } }
        -- The row's key names the same directory; an unknown key is refused.
        local nk = s.delete({ target = { build_dir = { key = "nope/Debug" } } })
        assert.equals("refused", nk.outcome, vim.inspect(nk))
        assert.equals("no build directory 'nope/Debug'", nk.message)
        local by_key = s.delete({ target = { build_dir = { key = row.key } } })
        assert.equals("confirm", by_key.outcome, vim.inspect(by_key))
        target = { build_dir = { key = row.key } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, tostring(f.error))
        assert.is_false(exists(dir))
        assert.is_true(exists(s.unit():build_dir()))
    end)

    it("a cancel stops the deletion between entries; what was not removed stays", function()
        s = session()
        s.build()
        local a, b = stray(s.root, "a"), stray(s.root, "b")
        -- Hold every removal until the cancel arrived, then let the real
        -- removal run (its stop predicate sees the cancel).
        local io_mod = s.ws()._core._deps.io
        local orig = io_mod.rm_rf_async
        local held = {}
        io_mod.rm_rf_async = function(...) held[#held + 1] = { ... } end
        local ok, err = pcall(function()
            local c = s.delete({ target = { orphans = true } })
            assert.equals("confirm", c.outcome, vim.inspect(c))
            local r = s.delete({ target = { orphans = true }, yes = true, plan = c.plan })
            assert.equals("accepted", r.outcome, vim.inspect(r))
            assert.is_true(vim.wait(10000, function() return #held > 0 end, 10), "no removal started")
            local cr = s.call("/tasks", "loomworks.Tasks", "cancel", { task_id = r.task_id })
            assert.equals("ok", cr.outcome, vim.inspect(cr))
            local run
            assert.is_true(vim.wait(10000, function()
                for x in pairs(s.service().runs) do if x.op == "delete" then run = x end end
                return run ~= nil and run.cancelled
            end, 10))
            io_mod.rm_rf_async = orig
            for _, args in ipairs(held) do orig(unpack(args)) end
            local f = s.done(r.task_id, 60000)
            assert.equals(130, f.exit_code)
            assert.truthy(tostring(f.error):find("delete stopped: ", 1, true), tostring(f.error))
            assert.is_true(exists(a) and exists(b), "nothing removed after the cancel")
        end)
        io_mod.rm_rf_async = orig
        assert(ok, err)
    end)

    it("a project whose build directory is not removed is kept and the task ends refused", function()
        s = session()
        s.build()
        local bd = s.unit():build_dir()
        local io_mod = s.ws()._core._deps.io
        local orig = io_mod.rm_rf_async
        io_mod.rm_rf_async = function(_, cb)
            vim.schedule(function() cb(false, "simulated removal failure") end)
        end
        local ok, err = pcall(function()
            local target = { project = { key = "app" } }
            local c = s.delete({ target = target })
            assert.equals("confirm", c.outcome, vim.inspect(c))
            local r = s.delete({ target = target, yes = true, plan = c.plan })
            assert.equals("accepted", r.outcome, vim.inspect(r))
            local f = s.done(r.task_id, 60000)
            assert.equals(1, f.exit_code, tostring(f.error))
            assert.is_true(exists(bd))
            local kept
            for _, p in pairs(s.ws()._projects) do
                if p.key == "app" and not p._removed then kept = p end
            end
            assert.is_not_nil(kept, "the project's declaration goes only after its build state did")
        end)
        io_mod.rm_rf_async = orig
        assert(ok, err)
    end)

    it("a build directory another process holds names its holder and removes nothing", function()
        s = session()
        s.build()
        local unit = s.unit()
        local bd = unit:build_dir()
        local target = { unit = { id = s.id(unit) } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local h = L.hold(require("loomworks.build_lock").lock_path(bd), "build")
        local r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(1, f.exit_code, tostring(f.error))
        assert.truthy(tostring(f.error):find("cannot delete: ", 1, true), tostring(f.error))
        assert.truthy(tostring(f.error):find("pid " .. h.pid, 1, true), tostring(f.error))
        assert.is_true(exists(bd))
        assert.equals("built", s.unit().state_value)
    end)

    -- Step 5o C2d-2: the confirm's `unit_ids` (API.md §22), the ids a client
    -- stops its own tasks by before `yes`.
    it("a project deletion's confirm lists every unit of the project by id, also one no profile maps", function()
        s = session()
        s.build()
        local unit = s.unit()
        local app = unit._project
        local unmapped = s.ws():ensure_config_unit(app, app:ensure_configuration("Release"), unit._tool)
        assert.are_not.equal(unit, unmapped)
        local c = s.delete({ target = { project = { id = s.id(app) } } })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        assert.equals(2, #c.unit_ids, vim.inspect(c.unit_ids))
        assert.is_true(vim.tbl_contains(c.unit_ids, s.id(unit)))
        assert.is_true(vim.tbl_contains(c.unit_ids, s.id(unmapped)))
        for _, id in ipairs(c.unit_ids) do
            local found = s.service().ids:find(id, s.ws()._config_units)
            assert.is_true(found == unit or found == unmapped, id)
        end
        local by_unit = s.delete({ target = { unit = { id = s.id(unit) } } })
        assert.same({ s.id(unit) }, by_unit.unit_ids)
        local orphans = s.delete({ target = { orphans = true } })
        if orphans.outcome == "confirm" then assert.same({}, orphans.unit_ids or {}) end
        -- A stale project id is refused, with no ids.
        local stale = s.delete({ target = { project = { id = "999:1" } } })
        assert.equals("refused", stale.outcome, vim.inspect(stale))
        assert.is_nil(stale.unit_ids)
    end)

    it("a confirmed profile deletion removes its build directories", function()
        s = session()
        s.build()
        local bd = s.unit():build_dir()
        local target = { profile = { key = "dev" } }
        local c = s.delete({ target = target })
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local r = s.delete({ target = target, yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.is_false(exists(bd))
    end)
end)

describe("Maintenance/1.nuke in the workspace daemon (API.md §22, part B6)", function()
    local s
    local IS_WIN = vim.fn.has("win32") == 1
    after_each(function()
        L.cleanup()
        if s then
            pcall(function()
                local core = s.service().host.core()
                core._nuke_begin, core._nuke_move_aside = nil, nil
            end)
            s.close(); s = nil
        end
    end)

    --- A workspace with build state in `.nvim`: a build (its build directory
    --- is `out/`, outside `.nvim`), a tree under `.nvim/build` and the cache.
    local function prepared()
        s = session()
        s.build()
        local x = stray(s.root, "x")
        return x, s.root .. "/.nvim/loomworks.cache.json"
    end

    --- Wrap the core's `_nuke_begin`: `fn(n)` runs before its n-th call (the
    --- first is the request's check, the second the task's).
    local function on_begin(fn)
        local core = s.service().host.core()
        local orig = getmetatable(core).__index._nuke_begin
        local n = 0
        core._nuke_begin = function(self, ...)
            n = n + 1
            fn(n)
            return orig(self, ...)
        end
    end

    local function nuke_run()
        for run in pairs(s.service().runs) do if run.op == "nuke" then return run end end
    end

    it("confirms with the listing and a plan token, then removes the build state and reloads", function()
        local x, cache = prepared()
        local bd = s.unit():build_dir()
        assert.is_true(exists(bd), "built: " .. tostring(bd))
        -- The shell template puts the unit's build directory at <root>/out/Debug,
        -- outside `.nvim`: nuke removes only `.nvim/build`, so it must neither
        -- list nor remove it.
        -- Compared by real path: the root and the build dir may be spelled
        -- differently (Windows 8.3 short names in TEMP).
        local uv = vim.uv or vim.loop
        local real_bd = vim.fs.normalize(assert(uv.fs_realpath(bd)))
        local real_root = vim.fs.normalize(assert(uv.fs_realpath(s.root)))
        assert.equals(real_root .. "/out/Debug", real_bd, tostring(bd))
        local bd_files = vim.fn.readdir(bd)
        -- A file of the workspace outside `.nvim`.
        vim.fn.mkdir(s.root .. "/keep", "p")
        local kf = assert(io.open(s.root .. "/keep/f.txt", "w")); kf:write("x"); kf:close()
        local before = s.ws()
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        assert.equals(maint.NUKE_HEADER, c.lines[1])
        assert.truthy(table.concat(c.lines, "\n"):find("/.nvim/build/", 1, true), vim.inspect(c.lines))
        assert.falsy(table.concat(c.lines, "\n"):find("/out/Debug", 1, true), vim.inspect(c.lines))
        assert.is_string(c.plan)
        assert.is_true(exists(x) and exists(cache), "a confirm removes nothing")
        local r = s.nuke({ yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local start = s.wait(function(m) return m.kind == "task" and m.task_id == r.task_id and m.phase == "start" end)
        assert.equals("nuke", start.meta.kind)
        assert.equals("nuke", start.meta.method)
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.is_false(exists(x))
        assert.is_false(exists(s.root .. "/.nvim/build"))
        -- Outside `.nvim` nothing is touched: not even the unit's build
        -- directory, which keeps its contents (only the cache forgets it).
        assert.is_true(exists(bd), "the unit's build directory outside .nvim is kept: " .. tostring(bd))
        assert.same(bd_files, vim.fn.readdir(bd), "its contents are untouched")
        assert.is_true(exists(s.root .. "/keep/f.txt"), "a file outside .nvim is kept")
        assert.is_true(exists(s.root .. "/loomworks.json"))
        -- Loaded again: a new model, its cache claims nothing built.
        assert.is_not_nil(s.ws())
        assert.are_not.equal(before, s.ws())
        assert.is_true(s.unit().state_value == nil or s.unit().state_value == "unconfigured",
            tostring(s.unit().state_value))
        local fh = io.open(cache, "rb")
        if fh then
            local text = fh:read("*a"); fh:close()
            assert.is_nil(text:find('"built"', 1, true), text)
        end
        assert.is_nil(nuke_run(), "the run is done")
    end)

    it("yes without a plan prints the listing first", function()
        local x = prepared()
        local r = s.nuke({ yes = true })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.equals("out: " .. maint.NUKE_HEADER, lines[1], vim.inspect(lines))
        assert.is_false(exists(x))
    end)

    it("a build-directory lock another process holds is refused at the confirmation, naming the holder", function()
        local x, cache = prepared()
        local h = L.hold(require("loomworks.build_lock").lock_path(x), "build")
        for _, args in ipairs({ vim.empty_dict(), { yes = true } }) do
            local r = s.nuke(args)
            assert.equals("refused", r.outcome, vim.inspect(r))
            assert.equals(1, r.exit_code)
            assert.truthy(r.message:find("cannot nuke: ", 1, true), r.message)
            assert.truthy(r.message:find("pid " .. h.pid, 1, true), r.message)
        end
        assert.is_true(exists(x) and exists(cache))
    end)

    it("a lock taken after the call is refused under the locks, naming the holder, with nothing removed", function()
        local x, cache = prepared()
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local h
        on_begin(function(n)
            if n == 2 then h = L.hold(require("loomworks.build_lock").lock_path(x), "build") end
        end)
        local r = s.nuke({ yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(1, f.exit_code, tostring(f.error))
        assert.truthy(tostring(f.error):find("cannot nuke: ", 1, true), tostring(f.error))
        assert.truthy(tostring(f.error):find("pid " .. h.pid, 1, true), tostring(f.error))
        assert.is_true(exists(x) and exists(cache))
        assert.is_not_nil(s.ws(), "the model was never unloaded")
    end)

    it("is refused while a task of the daemon runs, listing it", function()
        local x, cache = prepared()
        local t = s.service().tasks:create({ closed = true })
        t:start({ name = "fake build", kind = "build" })
        local ok, err = pcall(function()
            for _, args in ipairs({ vim.empty_dict(), { yes = true } }) do
                local r = s.nuke(args)
                assert.equals("refused", r.outcome, vim.inspect(r))
                assert.truthy(r.message:find("build fake build (task " .. tostring(t.id) .. ")", 1, true), r.message)
            end
            assert.is_true(exists(x) and exists(cache))
        end)
        t:done(0)
        assert(ok, err)
        -- Once it ended the nuke confirms.
        assert.equals("confirm", s.nuke().outcome)
    end)

    it("a changed plan is refused before anything is removed, at the call and under the locks", function()
        local x, cache = prepared()
        local area = s.root .. "/.nvim/cache/cc"
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        -- A new owned database area changes the plan.
        vim.fn.mkdir(area .. "/App", "p")
        local r = s.nuke({ yes = true, plan = c.plan })
        assert.equals("refused", r.outcome, vim.inspect(r))
        assert.equals(dp.CHANGED, r.message)
        assert.is_true(exists(x) and exists(cache) and exists(area))
        -- Under the locks: the area goes away between the call and the task.
        local c2 = s.nuke()
        assert.equals("confirm", c2.outcome, vim.inspect(c2))
        on_begin(function(n) if n == 2 then vim.fn.delete(area, "rf") end end)
        local r2 = s.nuke({ yes = true, plan = c2.plan })
        assert.equals("accepted", r2.outcome, vim.inspect(r2))
        local f = s.done(r2.task_id, 60000)
        assert.equals(1, f.exit_code)
        assert.equals(dp.CHANGED, f.error)
        assert.is_true(exists(x) and exists(cache))
        -- Its locks were released: a nuke confirms again.
        s.service().host.core()._nuke_begin = nil
        assert.equals("confirm", s.nuke().outcome)
    end)

    it("a failed owned-database area check aborts the whole nuke before anything is removed", function()
        local x, cache = prepared()
        local elsewhere = (vim.fn.tempname():gsub("\\", "/"))
        vim.fn.mkdir(elsewhere, "p")
        local precious = assert(io.open(elsewhere .. "/precious.txt", "w")); precious:write("x"); precious:close()
        local area = s.root .. "/.nvim/cache/cc"
        vim.fn.mkdir(s.root .. "/.nvim/cache", "p")
        local function link() return uv.fs_symlink(elsewhere, area, IS_WIN and { junction = true } or nil) == true end
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local linked
        on_begin(function(n) if n == 2 then linked = link() end end)
        local r = s.nuke({ yes = true })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        if not linked then pending("cannot create a directory link here") return end
        assert.equals(1, f.exit_code)
        assert.truthy(tostring(f.error):find("owned LSP database area", 1, true), tostring(f.error))
        assert.is_true(exists(x) and exists(cache) and exists(elsewhere .. "/precious.txt"))
        -- At the call, too.
        s.service().host.core()._nuke_begin = nil
        local again = s.nuke()
        assert.equals("refused", again.outcome, vim.inspect(again))
        assert.truthy(again.message:find("owned LSP database area", 1, true), again.message)
        if not uv.fs_unlink(area) then uv.fs_rmdir(area) end
        assert.is_true(exists(elsewhere .. "/precious.txt"))
        vim.fn.delete(elsewhere, "rf")
    end)

    it("a cancel ends it nuke stopped: <reason>, nothing removed and its locks released", function()
        local x, cache = prepared()
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        on_begin(function(n)
            if n == 2 then nuke_run().cancel("cancelled by the client that started it", 130) end
        end)
        local r = s.nuke({ yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(130, f.exit_code)
        assert.equals("nuke stopped: cancelled by the client that started it", f.error)
        assert.is_true(exists(x) and exists(cache))
        s.service().host.core()._nuke_begin = nil
        assert.equals("confirm", s.nuke().outcome)
    end)

    it("a cancel once the removal started is ignored: the nuke runs to its end and succeeds", function()
        local x, cache = prepared()
        local io_mod = s.service().host.core()._deps.io
        local orig = io_mod.rm_rf_async
        local cancelled = false
        io_mod.rm_rf_async = function(...)
            local run = nuke_run()
            if run and not cancelled then
                cancelled = true
                run.cancel("cancelled by the client that started it", 130)
            end
            return orig(...)
        end
        local ok, err = pcall(function()
            local r = s.nuke({ yes = true })
            assert.equals("accepted", r.outcome, vim.inspect(r))
            local f, lines = s.done(r.task_id, 60000)
            assert.is_true(cancelled, "a cancel arrived during the removal")
            assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
            assert.is_nil(f.error)
            for _, l in ipairs(lines) do assert.is_nil(l:find("nuke stopped", 1, true), l) end
        end)
        io_mod.rm_rf_async = orig
        assert(ok, err)
        assert.is_false(exists(x))
        assert.is_false(exists(s.root .. "/.nvim/build"))
        local fh = io.open(cache, "rb")
        if fh then
            local text = fh:read("*a"); fh:close()
            assert.is_nil(text:find('"built"', 1, true), text)
        end
        assert.is_not_nil(s.ws(), "loaded again")
        assert.is_nil(nuke_run(), "the run is done")
    end)

    it("is served while the workspace load is refused (an invalid build cache), and the workspace then loads", function()
        local x, cache = prepared()
        -- Copied from another machine (a signature this key did not make),
        -- found by the next load.
        s.service():_unload()
        local fh = assert(io.open(cache, "rb"))
        local text = fh:read("*a"); fh:close()
        local sig = assert(trust.split(text), "the cache is signed")
        local at = assert(text:find(sig, 1, true))
        fh = assert(io.open(cache, "wb"))
        fh:write(text:sub(1, at - 1) .. string.rep("0", 64) .. text:sub(at + 64)); fh:close()
        local function state() return s.call("/workspace", "loomworks.Workspace", "header").state end
        -- Another request loads it: refused.
        local d = s.delete({ target = { orphans = true } })
        assert.equals("refused", d.outcome, vim.inspect(d))
        assert.equals("refused", state())
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        assert.equals(maint.NUKE_HEADER, c.lines[1])
        assert.is_string(c.plan)
        assert.is_true(exists(x) and exists(cache), "a confirm removes nothing")
        local r = s.nuke({ yes = true, plan = c.plan })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f, lines = s.done(r.task_id, 60000)
        assert.equals(0, f.exit_code, vim.inspect(lines) .. " " .. tostring(f.error))
        assert.is_false(exists(x))
        assert.is_false(exists(s.root .. "/.nvim/build"))
        assert.is_true(exists(s.root .. "/loomworks.json"))
        local now = io.open(cache, "rb")
        if now then
            local t = now:read("*a"); now:close()
            assert.are_not.equal(text:sub(at + 64), t:sub(at + 64))
        end
        assert.are_not.equal("refused", state())
        assert.is_not_nil(s.ws(), "the workspace loads")
        assert.is_nil(nuke_run(), "the run is done")
    end)

    it("a late save of the old model does not recreate the cache after the nuke", function()
        local x, cache = prepared()
        local before = s.ws()
        local r = s.nuke({ yes = true })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        assert.equals(0, (s.done(r.task_id, 60000)).exit_code)
        assert.is_false(exists(x))
        assert.is_not_nil(before._no_write, "the old model writes nothing")
        os.remove(cache)
        -- Even one that missed its teardown.
        local torn = before._torn_down
        before._torn_down = nil
        local ok, saved = pcall(before._save_cache, before)
        before._torn_down = torn
        assert.is_true(ok, tostring(saved))
        assert.is_false(saved)
        assert.is_false(exists(cache), "the old model's save recreated the cache")
    end)

    it("a removal that fails midway is reported, its locks released and the workspace loaded again", function()
        local x, cache = prepared()
        local core = s.service().host.core()
        core._nuke_move_aside = function() return nil, "EBUSY: resource busy or locked" end
        local r = s.nuke({ yes = true })
        assert.equals("accepted", r.outcome, vim.inspect(r))
        local f = s.done(r.task_id, 60000)
        assert.equals(1, f.exit_code, tostring(f.error))
        assert.truthy(tostring(f.error):find("cannot nuke: could not move .nvim/build aside", 1, true),
            tostring(f.error))
        -- The caches went first; the tree is left as it is.
        assert.is_false(exists(cache) and (function()
            local h = io.open(cache, "rb"); local t = h:read("*a"); h:close()
            return t:find('"built"', 1, true) ~= nil
        end)(), "no cache claims a built tree")
        assert.is_true(exists(x), "the tree was left")
        assert.is_not_nil(s.ws(), "loaded again")
        assert.is_nil(nuke_run(), "the run is done")
        -- Its locks were released: a nuke confirms and then succeeds.
        core._nuke_move_aside = nil
        local c = s.nuke()
        assert.equals("confirm", c.outcome, vim.inspect(c))
        local r2 = s.nuke({ yes = true, plan = c.plan })
        assert.equals("accepted", r2.outcome, vim.inspect(r2))
        assert.equals(0, (s.done(r2.task_id, 60000)).exit_code)
        assert.is_false(exists(x))
    end)

    it("is refused while a deletion of the daemon is still removing after its task ended", function()
        local x, cache = prepared()
        local svc = s.service()
        local t = svc.tasks:create({ closed = true })
        t:start({ name = "orphans", kind = "delete" })
        t:done(1, "timed out")
        local run = { op = "delete", task = t, deleting = true, deletion_settled = false, finished = true,
            released = false, ctx = { ws = svc.ws }, cancel = function() end }
        svc.runs[run] = true
        local ok, err = pcall(function()
            for _, args in ipairs({ vim.empty_dict(), { yes = true } }) do
                local r = s.nuke(args)
                assert.equals("refused", r.outcome, vim.inspect(r))
                assert.truthy(r.message:find("delete still removing (task " .. tostring(t.id) .. ")", 1, true),
                    r.message)
            end
            assert.is_true(exists(x) and exists(cache))
        end)
        svc.runs[run] = nil
        assert(ok, err)
        assert.equals("confirm", s.nuke().outcome)
    end)
end)
