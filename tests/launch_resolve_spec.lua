-- Phase 1 of the CLI launch-targets work (spec §16.17): the pure resolvers
-- that both the editor executors and the headless runner share. These spawn
-- no tasks — they only turn a launch target into a {cmd,args,cwd,env} spec.

local Target = require("loomworks.target")
local LaunchTarget = require("loomworks.launch_target")

--- Minimal ConfigUnit stub: only what resolve_run_spec touches.
local function stub_unit(build_dir, project_key)
    return {
        build_dir = function() return build_dir end,
        _project = { key = project_key },
    }
end

describe("Target:resolve_run_spec", function()
    it("returns cmd/cwd/name for an executable with an artifact", function()
        local t = Target.new(stub_unit("/b", "app"), "app",
            { type = "executable", artifact = "src/app/app.exe" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(err)
        assert.equals("/b/src/app/app.exe", spec.cmd)
        assert.equals("/b", spec.cwd)
        assert.equals("app: run app", spec.name)
    end)

    it("errors for a non-executable target", function()
        local t = Target.new(stub_unit("/b", "app"), "lib",
            { type = "static_library", artifact = "libx.a" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("not an executable"))
    end)

    it("errors when the executable has no built artifact", function()
        local t = Target.new(stub_unit("/b", "app"), "app", { type = "executable" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no built artifact"))
    end)

    it("errors when there is no build directory", function()
        local t = Target.new(stub_unit(nil, "app"), "app",
            { type = "executable", artifact = "app.exe" })
        local spec, err = t:resolve_run_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no build directory"))
    end)
end)

describe("LaunchTarget:resolve_launch_spec", function()
    -- Construct a LaunchTarget instance directly, bypassing descriptor
    -- resolution — the dispatcher only reads _launch_config / _target.
    local function lt(fields)
        return setmetatable(fields, LaunchTarget)
    end

    it("dispatches to an executable build target and forwards extra_args", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return { cmd = "/b/app.exe", cwd = "/b", name = "app: run app" }
            end,
        }
        local spec = lt({ _target = target }):resolve_launch_spec({ extra_args = { "a", "b" } })
        assert.equals("/b/app.exe", spec.cmd)
        assert.equals("/b", spec.cwd)
        assert.same({ "a", "b" }, spec.args)
        assert.equals("app: run app", spec.name)
    end)

    it("dispatches to a command config, declared args before extra_args", function()
        local self = lt({ _project = { key = "app" }, _launch_name = "gui", _launch_config = {} })
        -- Stub the expansion seam so no full workspace/expand context is needed.
        self.resolve_command_spec = function()
            return { cmd = "prog", args = { "--flag" }, cwd = "/w", env = { X = "1" } }
        end
        local spec = self:resolve_launch_spec({ extra_args = { "in.txt" } })
        assert.same({ "--flag", "in.txt" }, spec.args)
        assert.equals("app: gui", spec.name)
        assert.same({ X = "1" }, spec.env)
    end)

    it("works with no extra_args (editor path)", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return { cmd = "/b/app.exe", cwd = "/b", name = "app: run app" }
            end,
        }
        local spec = lt({ _target = target }):resolve_launch_spec()
        assert.same({}, spec.args)
    end)

    it("errors for a target that is neither command nor executable", function()
        local spec, err = lt({}):resolve_launch_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("neither"))
    end)

    it("propagates a target resolution error", function()
        local target = {
            is_executable = function() return true end,
            resolve_run_spec = function()
                return nil, "no build directory for target 'app'"
            end,
        }
        local spec, err = lt({ _target = target }):resolve_launch_spec()
        assert.is_nil(spec)
        assert.is_truthy(err:find("no build directory"))
    end)
end)
