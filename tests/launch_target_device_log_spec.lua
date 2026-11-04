-- The device log's commands as a launch target builds them
-- (LaunchTarget:device_log_command / device_log_clear_command): the one
-- builder the editor's in-process log view (session_tracker) and the
-- workspace daemon's `Launch/1.device_log` (API.md §9.5, step 5n B3) share.

local LaunchTarget = require("loomworks.launch_target")

--- A target of a project whose module is `impl`, its unit's tool data `td`.
local function target(impl, td)
    return setmetatable({
        _project = { key = "app", _module = { impl = impl } },
        _config_unit = { _tool_data = td or { sdk = "x" } },
    }, LaunchTarget)
end

describe("LaunchTarget device log commands", function()
    it("device_log_command passes the pid only when the module asks for strict-pid filtering", function()
        local calls = {}
        local impl = {
            device_log = function(td, serial, opts)
                calls[#calls + 1] = { td = td, serial = serial, opts = opts }
                return { cmd = "hdc", args = { "-t", serial, "hilog" }, env = { A = "1" } }
            end,
        }
        local cmd, o = target(impl):device_log_command("SER1", 4242)
        assert.same({ name = "app: device log on SER1", cmd = "hdc", args = { "-t", "SER1", "hilog" },
            env = { A = "1" } }, cmd)
        assert.same({ level = "I", strict_pid = false }, o)
        assert.same({}, calls[1].opts)
        assert.same({ sdk = "x" }, calls[1].td)
        impl.device_log_options = function() return { level = "W", strict_pid = true } end
        cmd, o = target(impl):device_log_command("SER1", 4242)
        assert.same({ level = "W", strict_pid = true }, o)
        assert.same({ pid = 4242 }, calls[2].opts)
    end)

    it("device_log_command is nil without a module command", function()
        assert.is_nil(target({}):device_log_command("SER1", 1))
        assert.is_nil(target({ device_log = function() return nil end }):device_log_command("SER1", 1))
        assert.is_nil(setmetatable({}, LaunchTarget):device_log_command("SER1", 1))
    end)

    it("device_log_clear_command is the module's optional clear, nil without one", function()
        local impl = { device_log_clear = function(_, serial) return { cmd = "hdc", args = { serial, "-r" } } end }
        assert.same({ name = "app: clear device log on SER1", cmd = "hdc", args = { "SER1", "-r" } },
            target(impl):device_log_clear_command("SER1"))
        assert.is_nil(target({}):device_log_clear_command("SER1"))
        assert.is_nil(target({ device_log_clear = function() return {} end }):device_log_clear_command("SER1"))
    end)
end)
