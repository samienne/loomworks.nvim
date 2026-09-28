--- loomworks/remote/runners.lua — device-runner registry (spec §18.2).
---
--- A device runner is supplied by an SDK provider through the optional hook
--- `device_runner(sdk) → Runner|nil`. This module obtains a provider's runner
--- for one SDK installation, validates its shape once, and answers which
--- runner serves a foreign artifact (the runner of the SDK that produced the
--- artifact's kit, when its `platforms` contain the kit's token). Core never
--- knows any runner by name.
---
--- Runner shape (spec §18.2) — identity and capabilities:
---   id string, platforms string[], staging_base string (absolute POSIX path),
---   archive boolean, digest string[]|nil, combined_output boolean|nil,
---   timeouts { query?, transfer? }|nil (seconds)
--- Required builders: list_devices, parse_devices, push, pull, exec,
--- parse_exit. Optional: parse_pid, terminate, crash_snapshot, crash_collect,
--- runtime_files, log_session.

local M = {}

--- @class loomworks.Runner
--- @field id string runner identity; becomes Device.provider
--- @field platforms string[] target-platform tokens this runner executes
--- @field staging_base string absolute device-side staging directory
--- @field archive boolean device unpacks one uncompressed tar archive
--- @field digest string[]|nil device argv prefix printing `<hex>  <path>` per file
--- @field combined_output boolean|nil connector merges stderr into stdout
--- @field timeouts { query?: number, transfer?: number }|nil seconds
--- @field list_devices fun(): table spec
--- @field parse_devices fun(lines: string[]): table[]
--- @field push fun(serial: string, local_path: string, remote: string): table
--- @field pull fun(serial: string, remote: string, local_path: string): table
--- @field exec fun(serial: string, request: table): table
--- @field parse_exit fun(line: string, nonce: string): integer|nil
--- @field parse_pid? fun(line: string, nonce: string): integer|nil
--- @field terminate? fun(serial: string, nonce: string, pid?: integer): table
--- @field crash_snapshot? fun(serial: string): table, fun(lines: string[]): table
--- @field crash_collect? fun(before: table, after: table): string[]
--- @field runtime_files? fun(tool: loomworks.Tool): { local: string, relative: string }[]
--- @field log_session? fun(serial: string, options: table, program: { path: string, name: string }): table|nil, string|nil

local REQUIRED = { "list_devices", "parse_devices", "push", "pull", "exec", "parse_exit" }
local OPTIONAL = { "parse_pid", "terminate", "crash_snapshot", "crash_collect",
    "runtime_files", "log_session" }

--- Validate a runner table's shape. Returns true or (false, reason).
--- @param r any
--- @return boolean ok, string|nil err
function M.validate(r)
    if type(r) ~= "table" then return false, "device runner is not a table" end
    if type(r.id) ~= "string" or r.id == "" then return false, "device runner has no id" end
    local label = "device runner '" .. r.id .. "'"
    if type(r.platforms) ~= "table" or #r.platforms == 0 then
        return false, label .. " declares no platforms"
    end
    for _, p in ipairs(r.platforms) do
        if type(p) ~= "string" or p == "" then return false, label .. " has an invalid platform token" end
    end
    local base = r.staging_base
    if type(base) ~= "string" or not base:match("^/") or base:find("[%z\r\n]")
        or base:gsub("/+$", "") == "" then
        return false, label .. " has an invalid staging_base (need an absolute device path other than /)"
    end
    for seg in base:gmatch("[^/]+") do
        if seg == ".." or seg == "." then
            return false, label .. " staging_base must not contain '.' or '..' segments"
        end
    end
    if r.digest ~= nil then
        if type(r.digest) ~= "table" or #r.digest == 0 then
            return false, label .. " digest must be an argv prefix (string[]) or nil"
        end
        for _, a in ipairs(r.digest) do
            if type(a) ~= "string" then return false, label .. " digest must be string[]" end
        end
    end
    if r.timeouts ~= nil and type(r.timeouts) ~= "table" then
        return false, label .. " timeouts must be a table"
    end
    for _, f in ipairs(REQUIRED) do
        if type(r[f]) ~= "function" then return false, label .. " lacks required builder " .. f end
    end
    for _, f in ipairs(OPTIONAL) do
        if r[f] ~= nil and type(r[f]) ~= "function" then
            return false, label .. " builder " .. f .. " must be a function"
        end
    end
    return true
end

--- Normalised staging base (no trailing slash).
--- @param runner loomworks.Runner
--- @return string
function M.staging_base(runner)
    return (runner.staging_base:gsub("/+$", ""))
end

--- Does `runner` serve target-platform `token`?
--- @param runner loomworks.Runner
--- @param token string|nil
--- @return boolean
function M.serves(runner, token)
    if not token then return false end
    for _, p in ipairs(runner.platforms or {}) do
        if p == token then return true end
    end
    return false
end

-- Per-SDK-object cache: a provider hook may probe the installation.
local cache = setmetatable({}, { __mode = "k" })

--- The device runner for one SDK installation, or nil (+ reason) when its
--- provider supplies none or the one it supplies is malformed.
--- @param sdk loomworks.SDK|nil
--- @return loomworks.Runner|nil runner, string|nil err
function M.for_sdk(sdk)
    if not sdk then return nil, "no SDK" end
    local hit = cache[sdk]
    if hit then return hit.runner, hit.err end
    local provider = sdk._provider
    local runner, err
    if not (sdk.is_resolved and sdk:is_resolved()) then
        err = "SDK '" .. tostring(sdk.key) .. "' is not resolved on this machine"
    elseif type(provider) ~= "table" or type(provider.device_runner) ~= "function" then
        err = "SDK '" .. tostring(sdk.key) .. "' provides no device runner"
    else
        local ok, r = pcall(provider.device_runner, sdk)
        if not ok then
            err = "device runner of SDK '" .. tostring(sdk.key) .. "' failed: " .. tostring(r)
        elseif r == nil then
            err = "SDK '" .. tostring(sdk.key) .. "' has no usable device connector"
        else
            local vok, verr = M.validate(r)
            if vok then runner = r else err = verr end
        end
    end
    cache[sdk] = { runner = runner, err = err }
    return runner, err
end

--- Forget cached runners (tests; an SDK re-declared in-process).
function M._reset() cache = setmetatable({}, { __mode = "k" }) end

--- The runner that serves a foreign artifact's platform: the runner of the
--- SDK that produced its kit, when it lists the kit's token (spec §18.1).
--- @param foreign table from remote.foreign.classify
--- @return loomworks.Runner|nil runner, string|nil err
function M.for_foreign(foreign)
    if not foreign or not foreign.platform then
        return nil, "no target platform to route by"
    end
    local runner, err = M.for_sdk(foreign.sdk)
    if not runner then return nil, err end
    if not M.serves(runner, foreign.platform) then
        return nil, "device runner '" .. runner.id .. "' does not serve " .. foreign.platform
    end
    return runner
end

--- Runners in scope for device commands (spec §16.34): the given profile's
--- SDK (or the SDKs that produced its tools) when one resolves, otherwise every
--- declared SDK whose provider supplies a device runner. Deduplicated by
--- runner id (first wins).
--- @param ws loomworks.Workspace
--- @param profile? loomworks.Profile
--- @return { runner: loomworks.Runner, sdk: loomworks.SDK }[]
function M.in_scope(ws, profile)
    local sdks, seen_sdk = {}, {}
    local function add_sdk(s)
        if s and not seen_sdk[s] then seen_sdk[s] = true; sdks[#sdks + 1] = s end
    end
    if profile then
        add_sdk(profile.sdk and profile:sdk() or profile._sdk)
        for _, pp in ipairs(profile.projects and profile:projects() or {}) do
            local unit = pp._config_unit
            local tool = unit and unit.tool_object and unit:tool_object()
            if tool and tool.sdk then add_sdk(tool:sdk()) end
        end
    end
    if #sdks == 0 then
        for _, s in ipairs((ws and ws.sdks and ws:sdks()) or {}) do add_sdk(s) end
    end
    local out, seen_id = {}, {}
    for _, s in ipairs(sdks) do
        local r = M.for_sdk(s)
        if r and not seen_id[r.id] then
            seen_id[r.id] = true
            out[#out + 1] = { runner = r, sdk = s }
        end
    end
    return out
end

return M
