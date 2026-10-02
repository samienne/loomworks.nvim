--- loomworks/daemon/remote_task.lua — a task the editor OBSERVES in the
--- workspace daemon (spec §19.16): a build another client started (e.g.
--- `lw build` in a terminal).
---
--- Its `start` meta carries semantic keys (§19.15). They are resolved ONCE,
--- here at the wire boundary, to the editor's own domain objects: the profile
--- among the workspace's profiles, each unit through that profile's
--- project-in-profile to its ConfigUnit. A key that does not resolve is kept
--- as a name for display only — nothing is created or hydrated for it.
--- Domain logic afterwards only follows the references.

local M = {}

--- Output bytes kept per task in the editor (spec §19.16), then one
--- truncation notice.
M.OUTPUT_CAP_BYTES = 1024 * 1024

--- @class loomworks.RemoteTaskUnit
--- @field unit loomworks.ConfigUnit|nil the resolved configuration unit
--- @field project string the project key the daemon sent (display)
--- @field configuration string|nil the configuration-unit key the daemon sent (display)

--- @class loomworks.RemoteTask
--- @field id integer the daemon's task id
--- @field name string
--- @field kind string "build"
--- @field profile loomworks.Profile|nil the resolved profile
--- @field profile_name string|nil the profile key the daemon sent (display)
--- @field units loomworks.RemoteTaskUnit[]
--- @field action string "build" — what its units report while it runs
--- @field start_time number clock seconds
--- @field pct integer|nil last progress tick
--- @field finished boolean
--- @field exit_code integer|nil
--- @field error string|nil
--- @field end_reason string|nil why it ended without `done` (disconnect)
--- @field _chunks string[] kept output
--- @field _bytes integer
--- @field _truncated boolean
--- @field _listeners fun(task: loomworks.RemoteTask, text: string|nil)[] output followers
local RemoteTask = {}
RemoteTask.__index = RemoteTask

--- Resolve a task's `start` meta against the workspace (the boundary).
--- @param ws loomworks.Workspace
--- @param id integer
--- @param meta table|nil { name, kind, profile, units = { { project, configuration } } }
--- @param clock number
--- @return loomworks.RemoteTask
function M.new(ws, id, meta, clock)
    meta = type(meta) == "table" and meta or {}
    local self = setmetatable({
        id = id, name = type(meta.name) == "string" and meta.name or ("task " .. tostring(id)),
        kind = type(meta.kind) == "string" and meta.kind or "build",
        action = "build", units = {}, start_time = clock, finished = false,
        _chunks = {}, _bytes = 0, _truncated = false, _listeners = {},
    }, RemoteTask)
    self.profile_name = type(meta.profile) == "string" and meta.profile or nil
    local profile
    if self.profile_name and ws then
        for _, p in ipairs(ws:get_profiles() or {}) do
            if p.key == self.profile_name and not p._removed then profile = p; break end
        end
    end
    self.profile = profile
    for _, u in ipairs(type(meta.units) == "table" and meta.units or {}) do
        if type(u) == "table" and type(u.project) == "string" then
            local cfg = type(u.configuration) == "string" and u.configuration or nil
            local unit
            if profile then
                for _, pp in ipairs(profile:projects()) do
                    if pp:project_key() == u.project and cfg ~= nil and pp:config_key() == cfg then
                        unit = pp._config_unit
                        break
                    end
                end
            end
            self.units[#self.units + 1] = { unit = unit, project = u.project, configuration = cfg }
        end
    end
    return self
end

--- The resolved configuration units of this task.
--- @return loomworks.ConfigUnit[]
function RemoteTask:config_units()
    local out = {}
    for _, u in ipairs(self.units) do
        if u.unit then out[#out + 1] = u.unit end
    end
    return out
end

--- Mark the resolved units as running this task.
function RemoteTask:attach_units()
    for _, unit in ipairs(self:config_units()) do unit:begin_remote_task(self) end
end

--- Clear the marks this task put on its units.
function RemoteTask:detach_units()
    for _, unit in ipairs(self:config_units()) do unit:end_remote_task(self) end
end

--- Append output (a line or raw bytes), within the cap.
--- @param text string
function RemoteTask:append(text)
    if type(text) ~= "string" or text == "" or self._truncated then return end
    if self._bytes + #text > M.OUTPUT_CAP_BYTES then
        self._truncated = true
        text = "[loomworks: output kept in the editor truncated after "
            .. math.floor(self._bytes / 1024) .. " KiB]\n"
    else
        self._bytes = self._bytes + #text
    end
    self._chunks[#self._chunks + 1] = text
    for _, fn in ipairs(self._listeners) do pcall(fn, self, text) end
end

--- The kept output.
--- @return string
function RemoteTask:output()
    return table.concat(self._chunks)
end

--- Follow new output (`fn(task, text)`; `text` nil once the task ended).
--- Returns the unsubscribe function.
--- @param fn fun(task: loomworks.RemoteTask, text: string|nil)
--- @return fun()
function RemoteTask:follow(fn)
    self._listeners[#self._listeners + 1] = fn
    return function()
        for i, f in ipairs(self._listeners) do
            if f == fn then table.remove(self._listeners, i); return end
        end
    end
end

--- End the task (idempotent).
--- @param exit_code integer|nil
--- @param err string|nil
--- @param reason string|nil why it ended without `done`
function RemoteTask:finish(exit_code, err, reason)
    if self.finished then return end
    self.finished = true
    self.exit_code, self.error, self.end_reason = exit_code, err, reason
    self:detach_units()
    for _, fn in ipairs(self._listeners) do pcall(fn, self, nil) end
end

--- One line describing how it ended (fidget, notifications).
--- @return string
function RemoteTask:outcome()
    if self.end_reason then return self.end_reason end
    if self.exit_code == 0 then return "done" end
    return "failed" .. (self.error and (": " .. self.error) or (" (exit " .. tostring(self.exit_code) .. ")"))
end

M.RemoteTask = RemoteTask
return M
