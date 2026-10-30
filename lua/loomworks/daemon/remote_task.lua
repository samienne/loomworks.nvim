--- loomworks/daemon/remote_task.lua — a task the editor OBSERVES in the
--- workspace daemon (spec §19.16): an operation another client started (e.g.
--- `lw build` in a terminal).
---
--- Display and matching data only (step 6b-α): in `daemon` mode the editor
--- holds no workspace model (spec §19.16 "End state"), so nothing is resolved
--- to domain objects. Its `start` meta carries semantic keys (§19.15), kept
--- for display, and from step 5o C2d the ids `profile_id` and `units[].id`
--- (API.md §4.2), kept as they came: a status-page row is matched to its
--- tasks by those, never by key. Runtime only — nothing is written to the
--- cache or the working copy.
---
--- A process that DOES hold a model of the workspace — `lw status` (spec
--- §16.18, §19.6) — resolves the task's keys to its own domain objects with
--- `RemoteTask:resolve(ws)` (once, at the wire boundary) and then
--- `attach_units`, so its Profiles rows show the daemon's task running.
--- TODO(A1b): in the editor `profile`, `profiles`, `units[].unit`,
--- `config_units`, `attach_units` / `detach_units` stay empty (it never
--- resolves); their editor readers go with A1b.

local M = {}

--- Output bytes kept per task in the editor (spec §19.16), then one
--- truncation notice.
M.OUTPUT_CAP_BYTES = 1024 * 1024

--- @class loomworks.RemoteTaskUnit
--- @field unit loomworks.ConfigUnit|nil the resolved configuration unit (`RemoteTask:resolve`; never in the editor)
--- @field project string the project key the daemon sent (display)
--- @field configuration string|nil the configuration-unit key the daemon sent (display)
--- @field id string|nil the unit's id the daemon sent (API.md §4.2 `units[].id`; step 5o C2d): what a
---   view's unit row (`unit_id`) is matched by

--- @class loomworks.RemoteTaskStep
--- @field id any opaque, stable within the task
--- @field kind string `build`, `deploy`, `probe` (an unknown kind is shown neutrally)
--- @field label string what the step does, for display
--- @field state string `pending`, `running`, `ok`, `failed`, `cancelled`, `skipped` (an unknown state: neutral)
--- @field error string|nil a failed step's failure line
--- @field project string|nil
--- @field configuration string|nil
--- @field target string|nil
--- @field phase string|nil a deploy step's `pre_build` / `post_build`

--- @class loomworks.RemoteTask
--- @field id integer the daemon's task id
--- @field name string
--- @field kind string the operation: "build", "test", "run", …
--- @field origin string|nil who started it: "cli" or "editor" (`meta.origin`, protocol 7)
--- @field owned boolean|nil the editor itself started it through a call (step 5k, §19.15 "The editor as
---   owner"): no origin marker, cancelled from the editor
--- @field cancelling boolean|nil the editor asked to cancel it (an owned task; its task-runner task ends CANCELED)
--- @field _runner loomworks.daemon.RunnerStrategy|nil its task in the editor's task runner (step 5k C1b)
--- @field profile loomworks.Profile|nil the resolved profile
--- @field profiles loomworks.Profile[] the profiles that count it as their active operation (the resolved
---   profile; for a workspace-wide task, every profile with one of its resolved units)
--- @field scope string|nil "all" for a workspace-wide task (no profile)
--- @field profile_name string|nil the profile key the daemon sent (display)
--- @field profile_id string|nil the profile's id the daemon sent (`meta.profile_id`, API.md §4.2; step 5o
---   C2d): what a view's profile row (`id`) is matched by
--- @field units loomworks.RemoteTaskUnit[]
--- @field action string "build", "configure", "clean" or "reset" — what its units report
--- while it runs (a test or a run builds: "build")
--- @field start_time number clock seconds (uv.hrtime based, like local tasks)
--- @field pct integer|nil last progress tick
--- @field steps loomworks.RemoteTaskStep[]|nil a target-scoped task's steps with their current states
---   (§19.15 "Steps of a task", step 5t): `start.meta.steps`, moved by `Tasks/1.step`
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

--- A task from its `start` meta (the boundary): display data and ids only.
--- @param id integer
--- @param meta table|nil { name, kind, profile, profile_id, scope, units = { { project, configuration, id } }, origin }
--- @param clock number
--- @return loomworks.RemoteTask
function M.new(id, meta, clock)
    meta = type(meta) == "table" and meta or {}
    local kind = type(meta.kind) == "string" and meta.kind or "build"
    local self = setmetatable({
        id = id, name = type(meta.name) == "string" and meta.name or ("task " .. tostring(id)),
        kind = kind, origin = type(meta.origin) == "string" and meta.origin or nil,
        action = (kind == "configure" or kind == "clean" or kind == "reset") and kind or "build",
        units = {}, profiles = {}, start_time = clock, finished = false,
        _chunks = {}, _bytes = 0, _truncated = false, _listeners = {},
    }, RemoteTask)
    self.profile_name = type(meta.profile) == "string" and meta.profile or nil
    self.profile_id = type(meta.profile_id) == "string" and meta.profile_id or nil
    self.steps = M.steps_of(meta.steps)
    self.scope = (meta.scope == "all" and not self.profile_name) and "all" or nil
    for _, u in ipairs(type(meta.units) == "table" and meta.units or {}) do
        if type(u) == "table" and type(u.project) == "string" then
            self.units[#self.units + 1] = { project = u.project,
                configuration = type(u.configuration) == "string" and u.configuration or nil,
                id = type(u.id) == "string" and u.id or nil }
        end
    end
    return self
end

--- A task's steps as the daemon sent them (`start.meta.steps`,
--- `TaskInfo.steps`; §19.15 "Steps of a task"), kept as display data: the
--- well-formed entries, copied; nil when it has none.
--- @param raw any
--- @return loomworks.RemoteTaskStep[]|nil
function M.steps_of(raw)
    if type(raw) ~= "table" or #raw == 0 then return nil end
    local out = {}
    for _, s in ipairs(raw) do
        if type(s) == "table" then
            out[#out + 1] = {
                id = s.id, kind = type(s.kind) == "string" and s.kind or "?",
                label = type(s.label) == "string" and s.label or tostring(s.kind or "step"),
                state = type(s.state) == "string" and s.state or "pending",
                error = type(s.error) == "string" and s.error or nil,
                project = type(s.project) == "string" and s.project or nil,
                configuration = type(s.configuration) == "string" and s.configuration or nil,
                target = type(s.target) == "string" and s.target or nil,
                phase = type(s.phase) == "string" and s.phase or nil,
            }
        end
    end
    return #out > 0 and out or nil
end

--- A task already running when the observer connected (spec §19.16,
--- "Joining late"): one entry of the `status` reply's `tasks` (§19.11). Its
--- start time is taken from `started_at` (wall clock), its percent from
--- `percent`; its output starts now.
--- @param entry table { task_id, name, kind, profile, units, origin, started_at, percent? }
--- @param clock number now, clock seconds
--- @param now_wall? number now, os.time() (default)
--- @return loomworks.RemoteTask|nil
function M.adopt(entry, clock, now_wall)
    if type(entry) ~= "table" or entry.task_id == nil then return nil end
    local started = clock
    local at = tonumber(entry.started_at)
    if at then started = clock - math.max(0, (now_wall or os.time()) - at) end
    local self = M.new(entry.task_id, entry, started)
    self.pct = tonumber(entry.percent)
    return self
end

--- The origin marker (spec/ui.md §1.9): `lw` for the CLI, `editor` for
--- another editor; nil when the daemon did not say.
--- @return string|nil
function RemoteTask:origin_label()
    if self.owned then return nil end
    if self.origin == "cli" then return "lw" end
    if self.origin == "editor" then return "editor" end
    return nil
end

--- Resolve the task's semantic keys against a model of the workspace (the
--- wire boundary; spec §19.16, §16.18): the profile among `ws`'s profiles,
--- each unit through that profile's project-in-profile to its ConfigUnit. A
--- task without a profile (`lw reset --all`, or a `Build/1` of units) resolves
--- its units among the workspace's configuration units, and every profile
--- with one of them counts it. A key that does not resolve stays a name for
--- display. Only a process that holds a model calls it (`lw status`); a
--- `daemon`-mode editor holds none (step 6b-α).
--- @param ws loomworks.Workspace
function RemoteTask:resolve(ws)
    local profile
    if self.profile_name then
        for _, p in ipairs(ws:get_profiles() or {}) do
            if p.key == self.profile_name and not p._removed then profile = p; break end
        end
    end
    self.profile = profile
    self.profiles = {}
    if profile then self.profiles[1] = profile end
    local by_units = not self.profile_name and #self.units > 0
    for _, u in ipairs(self.units) do
        local cfg, unit = u.configuration, nil
        if profile then
            for _, pp in ipairs(profile:projects()) do
                if pp:project_key() == u.project and cfg ~= nil and pp:config_key() == cfg then
                    unit = pp._config_unit
                    break
                end
            end
        elseif (self.scope == "all" or by_units) and cfg ~= nil then
            for _, cu in pairs(ws._config_units or {}) do
                local pk = cu._project and cu._project.key or cu._init_project_key
                if pk == u.project and cu:config_key() == cfg then unit = cu; break end
            end
        end
        u.unit = unit
    end
    if self.scope == "all" or by_units then
        local mine = {}
        for _, unit in ipairs(self:config_units()) do mine[unit] = true end
        for _, p in ipairs(ws:get_profiles() or {}) do
            if not p._removed then
                for _, pp in ipairs(p:projects()) do
                    if pp._config_unit and mine[pp._config_unit] then
                        self.profiles[#self.profiles + 1] = p
                        break
                    end
                end
            end
        end
    end
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

--- The unit ids its meta names (API.md §4.2 `units[].id`; a unit the daemon
--- has no id for is absent).
--- @return string[]
function RemoteTask:unit_ids()
    local out = {}
    for _, u in ipairs(self.units) do
        if u.id then out[#out + 1] = u.id end
    end
    return out
end

--- Whether its meta names the profile `profile_id` or one of the units
--- `unit_ids` (view row ids; step 5o C2d — never by key).
--- @param profile_id string|nil
--- @param unit_ids string[]|nil
--- @return boolean
function RemoteTask:names_ids(profile_id, unit_ids)
    if profile_id ~= nil and self.profile_id == profile_id then return true end
    local want = {}
    for _, id in ipairs(unit_ids or {}) do want[id] = true end
    for _, u in ipairs(self.units) do
        if u.id and want[u.id] then return true end
    end
    return false
end

--- Put the task's running state on the editor's objects: its resolved units
--- run it, its resolved profile has it as an active operation.
function RemoteTask:attach_units()
    for _, p in ipairs(self.profiles) do
        if p.add_remote_task then p:add_remote_task(self) end
    end
    for _, unit in ipairs(self:config_units()) do unit:begin_remote_task(self) end
end

--- Clear the running state this task put on the editor's objects.
function RemoteTask:detach_units()
    for _, unit in ipairs(self:config_units()) do unit:end_remote_task(self) end
    for _, p in ipairs(self.profiles) do
        if p.remove_remote_task then p:remove_remote_task(self) end
    end
end

--- A `Tasks/1.step` delta (§19.15 "Steps of a task"): step `index` (1-based)
--- is now `state` (`err`: a failed step's failure line). True when it
--- changed; an index outside its steps is ignored.
--- @param index integer|nil
--- @param state any
--- @param err any
--- @return boolean changed
function RemoteTask:set_step(index, state, err)
    local s = index and self.steps and self.steps[index]
    if not s or type(state) ~= "string" then return false end
    local e = type(err) == "string" and err or nil
    if s.state == state and s.error == e then return false end
    s.state, s.error = state, e
    return true
end

--- Adopt the step states of a `Tasks/1.list` entry (after a seq gap): its
--- steps replace the task's. True when anything changed.
--- @param raw table the entry's `steps`
--- @return boolean changed
function RemoteTask:adopt_steps(raw)
    local steps = M.steps_of(raw)
    if not steps then return false end
    local changed = not self.steps or #self.steps ~= #steps
    for i, s in ipairs(steps) do
        local old = self.steps and self.steps[i]
        if not old or old.state ~= s.state or old.error ~= s.error then changed = true end
    end
    self.steps = steps
    return changed
end

--- The current step — the running one — and its index, or nil (none
--- running: before the first, between two, after the last; or a step state
--- this editor does not know, shown neutrally).
--- @return loomworks.RemoteTaskStep|nil, integer|nil
function RemoteTask:current_step()
    for i, s in ipairs(self.steps or {}) do
        if s.state == "running" then return s, i end
    end
    return nil, nil
end

--- The current step for display (`dependency lib (1/3)`), or nil.
--- @return string|nil
function RemoteTask:step_text()
    local s, i = self:current_step()
    if not s then return nil end
    return string.format("%s (%d/%d)", s.label, i, #self.steps)
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
    -- Over a copy: a listener may unsubscribe while it is called.
    for _, fn in ipairs({ unpack(self._listeners) }) do pcall(fn, self, text) end
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
    -- Over a copy: a listener (the task runner's) unsubscribes on the end.
    for _, fn in ipairs({ unpack(self._listeners) }) do pcall(fn, self, nil) end
end

--- One line describing how it ended (fidget, the profile row, the output
--- view) — a local operation's end message (`built in 12s`), or why it
--- ended without `done`.
--- @return string
function RemoteTask:outcome()
    if self.end_reason then return self.end_reason end
    return require("loomworks.operation").task_outcome(self.kind, self.exit_code, self.duration, self.error)
end

M.RemoteTask = RemoteTask
return M
