--- loomworks/remote/devices.lua — devices reported by device runners and
--- device selection for remote execution (spec §18.3, §1.8).
---
--- Devices a runner lists join the workspace device registry
--- (`Workspace._devices`, serial → Device) with `provider` = the runner id; a
--- serial reported by both a module (§11) and a runner is one Device.
---
--- Selection order (first match wins): an explicit selection for this
--- operation → the profile's persisted serial → the sole online device. A
--- named serial that is not online is an error naming it (never substituted);
--- no device or several with nothing selected is an error listing what was
--- found. Nothing here prompts.

local M = {}

local spec_exec = require("loomworks.remote.spec_exec")

--- List a runner's devices (runs its `list_devices` spec under the query
--- timeout). Returns the parsed device records, or nil + err.
--- @param runner loomworks.Runner
--- @param opts? { backend?: table, timeouts?: table }
--- @return table[]|nil devices, string|nil err
function M.list(runner, opts)
    opts = opts or {}
    local t = spec_exec.timeouts(runner, opts.timeouts)
    local ok_spec, spec = pcall(runner.list_devices)
    if not ok_spec then return nil, "device runner '" .. runner.id .. "' list_devices failed: " .. tostring(spec) end
    local job, fail = spec_exec.run(spec, {
        label = "list devices (" .. runner.id .. ")", timeout = t.query, backend = opts.backend,
    })
    if fail then return nil, fail end
    local ok, parsed = pcall(runner.parse_devices, job.lines)
    if not ok or type(parsed) ~= "table" then
        return nil, "device runner '" .. runner.id .. "' could not parse the device list: " .. tostring(parsed)
    end
    local out = {}
    for _, d in ipairs(parsed) do
        if type(d) == "table" and type(d.serial) == "string" and d.serial ~= "" then
            out[#out + 1] = {
                serial = d.serial,
                display_name = type(d.display_name) == "string" and d.display_name or d.serial,
                state = d.state == "online" and "online" or "offline",
                properties = type(d.properties) == "table" and d.properties or {},
                provider = runner.id,
            }
        end
    end
    table.sort(out, function(a, b) return a.serial < b.serial end)
    return out
end

--- Merge a runner's listing into the workspace registry. Only devices this
--- runner reported before are marked offline when they vanish (a module's
--- devices are left alone).
--- @param ws loomworks.Workspace|nil
--- @param runner_id string
--- @param devices table[]
function M.merge(ws, runner_id, devices)
    if not ws or type(ws._devices) ~= "table" then return end
    local Device = require("loomworks.device")
    local seen = {}
    for _, d in ipairs(devices) do
        seen[d.serial] = true
        local existing = ws._devices[d.serial]
        if existing then
            existing:_update({ display_name = d.display_name, state = d.state, properties = d.properties })
        else
            ws._devices[d.serial] = Device.new(d)
        end
    end
    for serial, dev in pairs(ws._devices) do
        if not seen[serial] and dev.provider == runner_id then dev.state = "offline" end
    end
end

local function describe(devices)
    local parts = {}
    for _, d in ipairs(devices) do
        parts[#parts + 1] = d.serial .. " (" .. d.state .. (d.display_name ~= d.serial
            and (", " .. d.display_name) or "") .. ")"
    end
    return #parts > 0 and table.concat(parts, ", ") or "none"
end
M.describe = describe

--- Choose the device for an operation (spec §18.3).
--- @param devices table[] the runner's current listing
--- @param opts { explicit?: string, persisted?: string, runner_id?: string, profile_key?: string }
--- @return string|nil serial, string|nil err, string|nil source "explicit"|"persisted"|"sole"
function M.select(devices, opts)
    opts = opts or {}
    local rid = opts.runner_id or "?"
    local function find(serial)
        for _, d in ipairs(devices) do if d.serial == serial then return d end end
        return nil
    end
    for _, src in ipairs({ "explicit", "persisted" }) do
        local serial = opts[src]
        if serial and serial ~= "" then
            local d = find(serial)
            if d and d.state == "online" then return serial, nil, src end
            local what = src == "explicit" and "device" or
                ("the device persisted for profile '" .. tostring(opts.profile_key) .. "'")
            return nil, string.format("%s '%s' is %s (runner '%s' lists: %s)%s",
                what, serial, d and "offline" or "not attached", rid, describe(devices),
                src == "persisted" and ("\n  choose another with --device <serial>, or "
                    .. "`lw device select <serial>` / `lw device select --clear`") or "")
        end
    end
    local online = {}
    for _, d in ipairs(devices) do if d.state == "online" then online[#online + 1] = d end end
    if #online == 1 then return online[1].serial, nil, "sole" end
    if #online == 0 then
        return nil, string.format("no device online (runner '%s' lists: %s)", rid, describe(devices))
    end
    local serials = {}
    for _, d in ipairs(online) do serials[#serials + 1] = d.serial end
    return nil, string.format("%d devices online (%s) and none selected\n"
        .. "  choose one with --device <serial>, or persist it with `lw device select <serial> [profile]`",
        #online, table.concat(serials, ", "))
end

return M
