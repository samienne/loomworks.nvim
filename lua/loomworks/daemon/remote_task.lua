--- loomworks/daemon/remote_task.lua — a task the editor OBSERVES in the
--- workspace daemon (spec §19.16): an operation another client started (e.g.
--- `lw build` in a terminal).
---
--- It puts the same RUNTIME state on the editor's objects as a local operation
--- of its kind: its resolved units report `building` (or `configuring`), and
--- its resolved profile counts as having an active operation. Runtime only —
--- nothing is written to the cache or the working copy, and nothing blocks an
--- editor operation (the cross-process build-directory locks do).
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
--- @field kind string the operation: "build", "test", "run", …
--- @field origin string|nil who started it: "cli" or "editor" (`meta.origin`, protocol 7)
--- @field profile loomworks.Profile|nil the resolved profile
--- @field profile_name string|nil the profile key the daemon sent (display)
--- @field units loomworks.RemoteTaskUnit[]
--- @field action string "build" or "configure" — what its units report while it runs
--- @field start_time number clock seconds (uv.hrtime based, like local tasks)
--- @field pct integer|nil last progress tick
--- @field finished boolean
--- @field exit_code integer|nil
--- @field error string|nil
--- @field end_reason string|nil why it ended without `done` (disconnect)
--- @field cleared boolean|nil it was cleared by teardown, not ended: no end result is recorded
--- @field duration number|nil seconds it ran, once finished
--- @field _chunks string[] kept output
--- @field _bytes integer
--- @field _truncated boolean
--- @field _listeners fun(task: loomworks.RemoteTask, text: string|nil)[] output followers
local RemoteTask = {}
RemoteTask.__index = RemoteTask

--- Resolve a task's `start` meta against the workspace (the boundary).
--- @param ws loomworks.Workspace
--- @param id integer
--- @param meta table|nil { name, kind, profile, units = { { project, configuration } }, origin }
--- @param clock number
--- @return loomworks.RemoteTask
function M.new(ws, id, meta, clock)
    meta = type(meta) == "table" and meta or {}
    local kind = type(meta.kind) == "string" and meta.kind or "build"
    local self = setmetatable({
        id = id, name = type(meta.name) == "string" and meta.name or ("task " .. tostring(id)),
        kind = kind, origin = type(meta.origin) == "string" and meta.origin or nil,
        action = kind == "configure" and "configure" or "build",
        units = {}, start_time = clock, finished = false,
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

--- A task already running when the observer connected (spec §19.16,
--- "Joining late"): one entry of the `status` reply's `tasks` (§19.11). Its
--- start time is taken from `started_at` (wall clock), its percent from
--- `percent`; its output starts now.
--- @param ws loomworks.Workspace
--- @param entry table { task_id, name, kind, profile, units, origin, started_at, percent? }
--- @param clock number now, clock seconds
--- @param now_wall? number now, os.time() (default)
--- @return loomworks.RemoteTask|nil
function M.adopt(ws, entry, clock, now_wall)
    if type(entry) ~= "table" or entry.task_id == nil then return nil end
    local started = clock
    local at = tonumber(entry.started_at)
    if at then started = clock - math.max(0, (now_wall or os.time()) - at) end
    local self = M.new(ws, entry.task_id, entry, started)
    self.pct = tonumber(entry.percent)
    return self
end

--- The origin marker (spec/ui.md §1.9): `lw` for the CLI, `editor` for
--- another editor; nil when the daemon did not say.
--- @return string|nil
function RemoteTask:origin_label()
    if self.origin == "cli" then return "lw" end
    if self.origin == "editor" then return "editor" end
    return nil
end

--- Seconds since it started.
--- @param clock number now, clock seconds
--- @return number
function RemoteTask:elapsed(clock)
    return math.max(0, clock - (self.start_time or clock))
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

--- Put the task's running state on the editor's objects: its resolved units
--- run it, its resolved profile has it as an active operation.
function RemoteTask:attach_units()
    if self.profile and self.profile.add_remote_task then self.profile:add_remote_task(self) end
    for _, unit in ipairs(self:config_units()) do unit:begin_remote_task(self) end
end

--- Clear the running state this task put on the editor's objects.
function RemoteTask:detach_units()
    for _, unit in ipairs(self:config_units()) do unit:end_remote_task(self) end
    if self.profile and self.profile.remove_remote_task then self.profile:remove_remote_task(self) end
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
--- @param clock? number now, clock seconds (for the end message's duration)
function RemoteTask:finish(exit_code, err, reason, clock)
    if self.finished then return end
    self.finished = true
    self.exit_code, self.error, self.end_reason = exit_code, err, reason
    if clock then self.duration = self:elapsed(clock) end
    self:detach_units()
    for _, fn in ipairs(self._listeners) do pcall(fn, self, nil) end
end

--- Verbs of the end message by kind: success, failure (as a local
--- operation's, loomworks.Operation).
local VERBS = {
    build = { "built", "build failed" },
    configure = { "configured", "configure failed" },
    test = { "tested", "test failed" },
    run = { "prepared", "run failed" },
}

--- One line describing how it ended (fidget, the profile row, the output
--- view) — a local operation's end message (`built in 12s`), or why it
--- ended without `done`.
--- @return string
function RemoteTask:outcome()
    if self.end_reason then return self.end_reason end
    local v = VERBS[self.kind] or { "done", "failed" }
    local ok = self.exit_code == 0
    local msg = ok and v[1] or v[2]
    if self.duration then
        msg = msg .. " in " .. require("loomworks.operation").format_duration(self.duration)
    end
    if not ok then
        msg = msg .. (self.error and (": " .. self.error) or (" (exit " .. tostring(self.exit_code) .. ")"))
    end
    return msg
end

M.RemoteTask = RemoteTask
return M
