--- A profile-level operation with an invalid ProfileProject (core
--- state-lifecycle §5.4 "Invalid ProfileProjects"): every valid
--- ProfileProject runs; an invalid one (a tool compat error) is not run,
--- counts as finished and failed with its reason in the result message, the
--- Operation fails and a CLI invocation exits non-zero after the others ran.

_G.LOOMWORKS_CLI_NO_AUTORUN = true

local Core = require("loomworks.core")
local h = require("tests.helpers")
local overseer = require("loomworks.overseer")
local build_run = require("loomworks.build_run")
local cli = require("loomworks.cli")
local Operation = require("loomworks.operation")
local real_modules = require("loomworks.modules")

local REASON = "targets OpenHarmony but profile tool is HarmonyOS"

--- Shell projects `app` and `lib`, set + profile `dev` (app=Debug, lib=Debug).
local function make_ws()
    local root = (vim.fn.tempname():gsub("\\", "/"))
    for _, d in ipairs({ "app", "lib" }) do vim.fn.mkdir(root .. "/" .. d, "p") end
    local function proj(name)
        return { path = name, shell = {
            build_dir = "${workspace_root}/out/" .. name .. "/${variant}",
            configure_cmd = { "cfg-" .. name }, build_cmd = { "bld-" .. name },
            configurations = { Debug = vim.empty_dict() },
        } }
    end
    local files = {
        ["loomworks.json"] = h.make_config_json({
            projects = { app = proj("app"), lib = proj("lib") },
            configuration_sets = { dev = { app = "Debug", lib = "Debug" } },
        }),
        ["loomworks.user.json"] = h.make_user_json({
            profiles = { dev = { configuration_set = "dev" } },
            active_profile = "dev",
        }),
    }
    local deps = h.make_test_deps(files, {
        modules = { get = function(id) return id and real_modules.get(id) or nil end },
        cache = { save = function() return true end },
    })
    local core = Core.new(deps)
    core:setup({ root = root })
    core:remerge()
    local ws = core:get_workspace()
    local profile = ws._profiles[1]
    return ws, profile, root
end

--- Give the named projects' ProfileProjects a tool compat error.
local function mark_incompatible(profile, names)
    for _, pp in ipairs(profile:projects()) do
        if names[pp._project.key] then pp._tool_compat_error = REASON end
    end
end

local function with_ws(ws, fn)
    local loomworks = require("loomworks")
    local orig = loomworks.get_workspace
    loomworks.get_workspace = function() return ws end
    local ok, a, b, c = pcall(fn)
    loomworks.get_workspace = orig
    assert.is_true(ok, tostring(a))
    return a, b, c
end

local function step_projects(steps)
    local out = {}
    for _, s in ipairs(steps or {}) do
        local u = s.unit
        out[#out + 1] = (u and u._project and u._project.key or "?") .. ":" .. s.kind
    end
    return out
end

describe("profile-level operation with an invalid ProfileProject (§5.4)", function()
    local root
    after_each(function()
        if root then vim.fn.delete(root, "rf"); root = nil end
    end)

    it("the plan runs the valid projects and names the invalid one as refused", function()
        local ws, profile, r = make_ws()
        root = r
        mark_incompatible(profile, { lib = true })
        local steps, err, refused = with_ws(ws, function() return overseer.plan_profile_build(profile) end)
        assert.is_nil(err)
        assert.same({ "app:configure", "app:build" }, step_projects(steps))
        assert.equals(1, #refused)
        assert.truthy(refused[1]:find("lib/Debug", 1, true), refused[1])
        assert.truthy(refused[1]:find(REASON, 1, true), refused[1])
    end)

    it("build_run.plan hands the refusals on with the steps", function()
        local ws, profile, r = make_ws()
        root = r
        mark_incompatible(profile, { lib = true })
        local steps, err, refused = with_ws(ws, function() return build_run.plan(profile) end)
        assert.is_nil(err)
        assert.same({ "app:configure", "app:build" }, step_projects(steps))
        assert.equals(1, #refused)
        assert.truthy(build_run.refused_message(refused):find(REASON, 1, true))
    end)

    describe("headless lw build", function()
        local orig_spawn, orig_stderr, orig_exit, orig_write
        before_each(function()
            orig_spawn = cli._run_spec
            orig_stderr, orig_exit, orig_write = io.stderr, os.exit, io.write
        end)
        after_each(function()
            cli._run_spec = orig_spawn
            io.stderr, os.exit, io.write = orig_stderr, orig_exit, orig_write
        end)

        local function run(ws, profile)
            local spawned, err = {}, {}
            cli._run_spec = function(s) spawned[#spawned + 1] = s.cmd[1]; return 0 end
            io.write = function() end
            io.stderr = { write = function(_, s) err[#err + 1] = s end }
            local code
            os.exit = function(c) code = c or 0; error({ __exit = true }, 0) end
            local loomworks = require("loomworks")
            local orig = loomworks.get_workspace
            loomworks.get_workspace = function() return ws end
            local ok, e = pcall(cli._run_build_steps, profile, ws, {})
            loomworks.get_workspace = orig
            if not ok and not (type(e) == "table" and e.__exit) then error(e, 0) end
            return spawned, code, table.concat(err)
        end

        it("builds the valid projects, then exits non-zero naming the refused one", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { lib = true })
            local spawned, code, err = run(ws, profile)
            assert.same({ "cfg-app", "bld-app" }, spawned)
            assert.equals(1, code)
            assert.truthy(err:find("lib/Debug", 1, true), err)
            assert.truthy(err:find(REASON, 1, true), err)
        end)

        it("with every project refused, runs nothing and exits non-zero with the reasons", function()
            local ws, profile, r = make_ws()
            root = r
            mark_incompatible(profile, { app = true, lib = true })
            local spawned, code, err = run(ws, profile)
            assert.same({}, spawned)
            assert.equals(1, code)
            assert.truthy(err:find("app/Debug", 1, true), err)
            assert.truthy(err:find("lib/Debug", 1, true), err)
            assert.is_nil(err:find("nothing to build", 1, true), err)
        end)
    end)

    describe("editor in-process profile action", function()
        local loomworks = require("loomworks")
        local saved
        before_each(function()
            saved = { gw = loomworks.get_workspace, pd = loomworks.has_pending_deletions,
                co = loomworks.create_operation, ov = package.loaded["overseer"] }
        end)
        after_each(function()
            loomworks.get_workspace, loomworks.has_pending_deletions = saved.gw, saved.pd
            loomworks.create_operation = saved.co
            package.loaded["overseer"] = saved.ov
        end)

        for _, action in ipairs({ "build", "configure" }) do
            it(action .. " with every project refused runs nothing, fails, and records a failed operation", function()
                local ws, profile, r = make_ws()
                root = r
                mark_incompatible(profile, { app = true, lib = true })
                local created = {}
                package.loaded["overseer"] = { new_task = function() error("no task may start") end }
                loomworks.get_workspace = function() return ws end
                loomworks.has_pending_deletions = function() return false end
                loomworks.create_operation = function(p, a, u, t, o)
                    local op = ws:create_operation(p, a, u, t, o)
                    created[#created + 1] = op
                    return op
                end
                local rejected
                overseer.run_profile_action(profile, action):catch(function(e) rejected = e end)
                vim.wait(1000, function() return rejected ~= nil end, 10)
                assert.truthy(rejected, "the action fails")
                assert.truthy(tostring(rejected):find("app/Debug", 1, true), tostring(rejected))
                assert.truthy(tostring(rejected):find(REASON, 1, true), tostring(rejected))
                assert.equals(1, #created)
                assert.is_true(created[1].completed)
                assert.is_false(created[1].success)
                assert.truthy(created[1].message:find("lib/Debug", 1, true), created[1].message)
            end)
        end
    end)

    describe("Operation", function()
        local function fake_ws()
            return { _core = { _deps = { clock = function() return 0 end,
                events = { emit = function() end } } } }
        end

        it("a refused ProfileProject fails the operation, its reason in the message", function()
            local unit = { on_state_change = function() return function() end end }
            local op = Operation.new(fake_ws(), nil, "build", { unit }, { [unit] = "built" }, nil,
                { track_tasks = true, refused = { "lib/Debug not run: " .. REASON } })
            op:unit_finished(unit, true)
            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.truthy(op.message:find(REASON, 1, true), op.message)
        end)

        it("with no unit to run, completes failed on its first check", function()
            local op = Operation.new(fake_ws(), nil, "build", {}, {}, nil,
                { refused = { "lib/Debug not run: " .. REASON } })
            op:_check_completion()
            assert.is_true(op.completed)
            assert.is_false(op.success)
            assert.truthy(op.message:find(REASON, 1, true), op.message)
        end)
    end)
end)
