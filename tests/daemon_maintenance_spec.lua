-- loomworks.Maintenance/1.execute_deletion in the workspace daemon (API.md
-- §22; step 5o part B5), over the loopback transport on the conformance
-- runner's `shell` fixture: the confirmation's plan token, a changed plan
-- refused before anything is removed, the stray-directory refusals, a
-- confirmed deletion removing the directory and its cached state, and a
-- cancel stopping the deletion between entries.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
_G.LW_CONFORMANCE_LIB = true
local uv = vim.uv or vim.loop
local H = require("tests.daemon_helpers")
local L = require("tests.lock_helpers")
local trust = require("loomworks.trust")
local dp = require("loomworks.deletion_plan")
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
