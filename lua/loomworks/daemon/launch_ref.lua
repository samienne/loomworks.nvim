--- loomworks/daemon/launch_ref.lua — a launch target as the `daemon`-mode
--- editor knows it (spec §19.16 "Public API", step 6b-α): one record of
--- `Launch/1.targets` (API.md §9.6) of a profile row of `view.Workspace/1`.
---
--- The editor holds no model in `daemon` mode, so its run, debug and build
--- of a launch target (the facade's pickers, the session tracker, editor_ops'
--- `Launch/1` and `Devices/1` calls) name the target by these ids and names,
--- never by a LaunchTarget. Built once from the reply and the view rows it
--- was taken with (the boundary); its program, once started, is tracked here
--- as LaunchTarget tracks an in-process one.

local M = {}

--- @class loomworks.daemon.LaunchRef
--- @field profile_id string the profile row's id (what a call's `profile` names)
--- @field profile_key string the profile's key (display)
--- @field project_id string|nil the project's id (`project`; a device target is addressed by its profile)
--- @field project_key string the project's key (display)
--- @field kind "launch"|"target"|"device"
--- @field name string what a reference names (the launch's name, the build target's or device target's id)
--- @field label string its display name
--- @field description string|nil a launch configuration's description
--- @field default boolean whether it is the profile's default target
--- @field artifact_block { profile?: string, path?: string }|nil its project's unit row's `artifact_block` (§5.9): the build question asked before the call
--- @field unit_id string|nil its project's unit row's id (an owned call records it, so a clean of that row pre-empts it)
--- @field _launch_task_id integer|nil the task-runner task of its started program
local LaunchRef = {}
LaunchRef.__index = LaunchRef

--- A launch target from its `Launch/1.targets` record `record` of the
--- profile row `profile` (view.Workspace/1). `project` is the project's view
--- row (by the record's project id), when the view lists it.
--- The profile's unit row of the target's project (its `artifact_block`
--- and `unit_id`) is joined by the project's key: the view's unit rows carry
--- no project id (BACKLOG "Clean and deletion leftovers").
--- @param profile table a `profiles[]` row (`id`, `key`, `units`)
--- @param record table a `Launch/1.targets` record
--- @param project table|nil the project's `projects[]` row
--- @return loomworks.daemon.LaunchRef
function M.new(profile, record, project)
    local proj = type(record.project) == "table" and record.project or {}
    local self = setmetatable({
        profile_id = profile.id, profile_key = profile.key,
        project_id = proj.id, project_key = tostring(proj.key or "?"),
        kind = record.kind, name = record.name,
        label = tostring(record.label or record.name or "?"),
        description = record.description, default = record.default == true,
    }, LaunchRef)
    for _, u in ipairs(profile.units or {}) do
        if u.project == proj.key then
            self.artifact_block, self.unit_id = u.artifact_block, u.unit_id
            break
        end
    end
    return self
end

--- `cb(language)` with the language whose debug adapter is checked before a
--- debug (§8.9.6): a launch configuration's first `debug` language, else its
--- project module's primary language, as the project's declaration
--- (`Projects/1.declaration`, API.md: its `launches[]` and
--- `module.languages`) reports them. `cb(nil)` — unchecked here, the
--- debugger checks the prepared adapter — for a device target, while the
--- call is not carried, or when it fails (never notified: the debug goes on).
--- @param cb fun(language: string|nil)
function LaunchRef:debug_language(cb)
    if self.kind == "device" or self.project_id == nil then return cb(nil) end
    local obs = require("loomworks.daemon.editor_ops").carrier("Projects/1.declaration", nil)
    if not obs then return cb(nil) end
    obs:request("Projects/1.declaration", { project = { id = self.project_id } }, function(r)
        local res = r.outcome == "ok" and type(r.result) == "table" and r.result or nil
        if not (res and res.outcome == "ok") then return cb(nil) end
        if self.kind == "launch" then
            -- (The record names the launch configuration by name; the
            -- declaration lists it by that key: the boundary.)
            for _, l in ipairs(type(res.launches) == "table" and res.launches or {}) do
                if type(l) == "table" and l.key == self.name and type(l.fields) == "table" then
                    local d = l.fields.debug
                    if type(d) == "table" and type(d[1]) == "string" then return cb(d[1]) end
                end
            end
        end
        local langs = type(res.module) == "table" and res.module.languages or nil
        cb(type(langs) == "table" and type(langs[1]) == "string" and langs[1] or nil)
    end)
end

--- Whether `x` is a LaunchRef (the session tracker's `daemon`-mode target).
--- @param x any
--- @return boolean
function M.is(x)
    return getmetatable(x) == LaunchRef
end

--- `<project>: <label>`, as LaunchTarget:display_name.
--- @return string
function LaunchRef:display_name()
    return self.project_key .. ": " .. self.label
end

--- A device target of spec §11 (launched through `Devices/1`).
--- @return boolean
function LaunchRef:requires_device()
    return self.kind == "device"
end

--- The `Launch/1` address of the target (API.md §9.1, §9.4): by the
--- profile's id and, for a launch configuration or build target, the
--- project's id, its name and kind; a device target by its profile alone (it
--- is reached only as its profile's default target, API.md §15).
--- @return table
function LaunchRef:args()
    local a = { interactive = false, profile = { id = self.profile_id } }
    if self.kind ~= "device" then
        a.project = { id = self.project_id }
        a.target, a.kind = self.name, self.kind
    end
    return a
end

--- Start the program the daemon prepared (`Launch/1.prepare_run`'s
--- `launch`) in the task runner, disposing of the previous finished one.
--- @param spec { name: string, cmd: string, args?: string[], cwd?: string, env?: table }
function LaunchRef:launch_resolved(spec)
    if self._launch_task_id then
        local ok = pcall(require, "overseer")
        if ok then
            local prev = require("overseer.task_list").get(self._launch_task_id)
            if prev and prev:is_complete() then prev:dispose() end
        end
    end
    self._launch_task_id = require("loomworks.overseer").launch_run_task({
        name = spec.name, cmd = spec.cmd, args = spec.args, cwd = spec.cwd, env = spec.env,
    })
end

--- Whether its started program still runs.
--- @return boolean
function LaunchRef:is_running()
    if not self._launch_task_id then return false end
    if not pcall(require, "overseer") then return false end
    local task = require("overseer.task_list").get(self._launch_task_id)
    return task ~= nil and not task:is_complete()
end

--- Stop its started program.
function LaunchRef:stop()
    if not self._launch_task_id then return end
    if pcall(require, "overseer") then
        local task = require("overseer.task_list").get(self._launch_task_id)
        if task and not task:is_complete() then task:stop() end
    end
    self._launch_task_id = nil
end

M.LaunchRef = LaunchRef
return M
