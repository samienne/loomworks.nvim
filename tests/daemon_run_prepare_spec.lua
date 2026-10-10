--- Unit tests of the daemon's `lw run` handling (spec §19.15 "Run"): the
--- cross-kit decline in Service:_accept, and the `--prefix` refusal of a
--- device target in the runner's preparation (before any deploy, as the
--- in-process `_run_launch_target_impl`).

local service = require("loomworks.daemon.service")
local runner = require("loomworks.daemon.runner")
local build_run = require("loomworks.build_run")
local run_prep = require("loomworks.run_prep")

local function stub(tbl, key, fn)
    local orig = tbl[key]
    tbl[key] = fn
    return function() tbl[key] = orig end
end

describe("daemon run preparation (§19.15 Run)", function()
    local restores
    before_each(function() restores = {} end)
    after_each(function()
        for i = #restores, 1, -1 do restores[i]() end
    end)
    local function with(tbl, key, fn) restores[#restores + 1] = stub(tbl, key, fn) end

    it("declines a run of a profile whose kit builds for another platform, before any task", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        with(run_prep, "kit_platform", function(p) return p == profile and "ohos-arm64" or nil end)
        local created = false
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() created = true end },
        }, service.Service)
        local reply
        svc:_accept({ op = "run", conn = { closed = false }, args = {}, interactive = false,
            reply = function(f) reply = f end })
        assert.is_false(created)
        assert.are.same({ outcome = "declined", reason = "profile 'ohos-debug' builds for ohos-arm64; "
            .. "device runs stay in this process" }, reply)
    end)

    it("does not decline a build of that profile (only a run is a device run)", function()
        local profile = { key = "ohos-debug" }
        with(build_run, "resolve_target", function() return profile end)
        local asked = false
        with(run_prep, "kit_platform", function() asked = true; return "ohos-arm64" end)
        local svc = setmetatable({
            live = function() return { root = "/ws" } end,
            tasks = { create = function() error("stop here") end },
        }, service.Service)
        assert.has_error(function()
            svc:_accept({ op = "build", conn = { closed = false }, args = {}, reply = function() end })
        end)
        assert.is_false(asked)
    end)

    --- Run the runner's preparation (`--no-build`: no lock, straight to it)
    --- for a launch target `lt`; returns the task's `done` record.
    local function prepare(lt, args)
        with(run_prep, "select", function() return lt end)
        with(run_prep, "validity_error", function() return nil end)
        with(run_prep, "foreign_of", function() return nil end)
        with(run_prep, "resolve_spec", function()
            return { name = "app", cmd = "/bin/app", args = {}, cwd = "/ws" }
        end)
        with(run_prep, "env_overrides", function() return {} end)
        local ws = { root = "/ws" }
        local done
        local task = {
            start = function() end, line = function() end,
            done = function(_, code, err, fields) done = { code = code, err = err, fields = fields } end,
        }
        local profile = { key = "dbg", projects = function() return {} end }
        runner.run({ ws = ws }, { op = "run", task = task, ws = ws, profile = profile, env = {},
            args = vim.tbl_extend("force", { no_build = true }, args) })
        return done
    end

    it("--prefix refuses a device target with the in-process message, before deploy", function()
        local deployed = false
        local lt = {
            requires_device = function() return true end,
            display_name = function() return "phone-app" end,
            deploy_sync = function() deployed = true; return true end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(1, done.code)
        assert.are.equal("--prefix cannot wrap a device target ('phone-app') — a local wrapper does not "
            .. "apply to on-device execution.", done.err)
        assert.is_false(deployed)
    end)

    it("--prefix with a local target prepares the launch", function()
        local lt = {
            requires_device = function() return false end,
            display_name = function() return "app" end,
        }
        local done = prepare(lt, { prefix = true })
        assert.are.equal(0, done.code)
        assert.are.equal("/bin/app", done.fields.launch.cmd)
    end)
end)
