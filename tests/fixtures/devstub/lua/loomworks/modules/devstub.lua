--- tests/fixtures/devstub — a harness-only module with devices (spec §19.19
--- step 5n part B2). It ships only in the test tree: the conformance runner
--- puts `tests/fixtures/devstub` on the runtime path of the daemons it
--- starts for the `devices` fixture (and registers it in-process for the
--- loopback transport); no release bundle contains it.
---
--- It is the `shell` module (configure/build/clean commands, build_dir
--- template) under the id `devstub`, plus the module device interface
--- (spec §11.4) over a fake device:
---
---   list_devices      the devices `LW_TEST_DEVICES` names in the CALLER's
---                     environment (read when called: the daemon calls it
---                     inside the scan's model segment), as
---                     `<serial>[=<name>][:offline]` separated by commas;
---                     unset: `SER1=Stub Phone,SER2=Stub Tablet:offline`.
---                     `LW_TEST_SCAN_SLEEP` ms delays the answer ("hang":
---                     never answers)
---   device_targets    one device target `app` per project
---   resolve_artifact  `<build dir>/app.hap`
---   resolve_launch_info  `{ bundle_name = "com.example.app" }`
---   device_install / device_launch / device_pid / device_stop
---                     `nvim -l <fixture>/device.lua <op> <serial> <arg>`,
---                     which prints `<op> <serial> <arg>` (the pid probe:
---                     `LW_TEST_DEVICE_PID`, default 4242), appends that line
---                     to the file `LW_TEST_DEVICE_LOG` names, sleeps
---                     `LW_TEST_DEVICE_SLEEP` ms and exits 1 when
---                     `LW_TEST_DEVICE_FAIL` names the op — all of ITS
---                     environment (the caller's, plus `LW_TEST_DEVICE_OP`
---                     from the command's own variables).

local shell = require("loomworks.modules.shell")

local M = setmetatable({}, { __index = shell })

M.id = "devstub"
M.api_version = shell.api_version
M.has_devices = true

--- The fixture directory (this file's `../../../..`).
local function fixture_dir()
    local src = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
    return (src:gsub("/lua/loomworks/modules/devstub%.lua$", ""))
end

--- The device script's command for `op`.
local function command(op, serial, arg)
    return {
        cmd = (vim.v.progpath:gsub("\\", "/")),
        args = { "--headless", "-u", "NONE", "-l", fixture_dir() .. "/device.lua", op, serial, arg or "-" },
        env = { LW_TEST_DEVICE_OP = op },
    }
end

--- @param _ table tool_data
--- @param cb fun(devices: table[])
function M.list_devices(_, cb)
    local spec = os.getenv("LW_TEST_DEVICES") or "SER1=Stub Phone,SER2=Stub Tablet:offline"
    local devices = {}
    for item in spec:gmatch("[^,]+") do
        local state = item:match(":offline$") and "offline" or "online"
        item = item:gsub(":offline$", "")
        local serial, name = item:match("^([^=]+)=(.+)$")
        devices[#devices + 1] = { serial = serial or item, display_name = name or item, state = state }
    end
    local sleep = os.getenv("LW_TEST_SCAN_SLEEP")
    if sleep == "hang" then return end
    local ms = tonumber(sleep or "")
    if ms then vim.defer_fn(function() cb(devices) end, ms) else cb(devices) end
end

function M.device_targets(project_ctx, _)
    return { { id = "app", label = project_ctx.name .. " app" } }
end

function M.resolve_artifact(project_ctx, _)
    return (project_ctx.build_dir or "?") .. "/app.hap"
end

function M.resolve_launch_info()
    return { bundle_name = "com.example.app" }
end

function M.device_install(_, serial, artifact) return command("install", serial, artifact) end
function M.device_launch(_, serial, info) return command("launch", serial, info.bundle_name) end
function M.device_pid(_, serial, bundle) return command("pid", serial, bundle) end
function M.device_stop(_, serial, bundle) return command("stop", serial, bundle) end

return M
