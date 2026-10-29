--- loomworks/status_source.lua — where the status page's body reads
--- (daemon.md §19.13 "The workspace view"; step 5n part C1). The body —
--- Diagnostics, Suggestions, Profiles, Orphaned Build Dirs,
--- Configuration Sets, Projects and SDKs — renders only from one
--- `loomworks.view.Workspace/1` table this module gives, with the overlays
--- the view does not carry: build progress (API.md §14.4 "Progress is not
--- in the view").
---
--- One source per runtime mode (as loomworks/test_source.lua and
--- loomworks/lsp_source.lua):
---   * `daemon` mode: **only** the daemon's view as the observer holds it
---     (loomworks.views). Nothing of it is built in-process: while the view is
---     not held, `why` says why and each section is one `unavailable — <why>`
---     line. Progress comes from the tasks observed through `Tasks/1` (the
---     observer's remote and editor-owned tasks: their `start` meta names the
---     profile and units by id, matched to the rows' ids — never by key;
---     `progress` frames the percent, `start` the elapsed time). The
---     sections' actions go through loomworks/ui/model_calls.lua, which names
---     a row's entity by the row's id (step 5o C2), and match tasks to rows by
---     the same ids (C2d-2): no row reaches the editor's model.
---   * `in-process` mode (transition, until step 6b): the view built from the
---     editor's own model (Workspace:view_workspace), each row bound to the
---     object it describes; progress from the objects' task tracking.

local M = {}

--- The in-process view's rows, each bound to the domain object it describes
--- (`Workspace:view_workspace`'s `bind`; weak: a row lives as long as the
--- page that rendered it; all forgotten when a workspace is torn down,
--- M.forget). The status page's actions name an entity by its
--- row; in the `in-process` mode loomworks/ui/model_calls.lua finds the
--- object here (M.object_of).
local bound = setmetatable({}, { __mode = "k" })

--- Bind a row of an in-process read to the domain object it describes.
--- @param row table
--- @param obj table|nil
function M.bind(row, obj)
    if row ~= nil then bound[row] = obj end
end

--- Forget every row's binding (Workspace:teardown: a torn-down workspace's
--- objects are reached by no row of a page rendered before the swap).
function M.forget()
    for row in pairs(bound) do bound[row] = nil end
end

--- The domain object an in-process row was bound to, or nil (a daemon row:
--- never bound).
--- @param row table|nil
--- @return table|nil
function M.object_of(row)
    return row ~= nil and bound[row] or nil
end

--- @class loomworks.StatusBody
--- @field mode "daemon"|"in-process"
--- @field view loomworks.ViewWorkspace|nil nil in `daemon` mode while the view is not held
--- @field why string|nil why the view is not held (`daemon` mode)
--- @field loaded boolean whether the workspace is loaded where the view comes from
--- @field profile_progress fun(row: loomworks.ViewProfile): { pct: integer|nil, elapsed: number|nil }|nil
--- @field unit_progress fun(u: table): { progress: table|nil, elapsed: number|nil }|nil

--- Whether `ws` is in `daemon` mode, and its observer (nil when none is
--- attached any more).
--- @param ws loomworks.Workspace
--- @return boolean daemon, loomworks.daemon.Observer|nil obs
local function daemon_of(ws)
    return require("loomworks.daemon.editor_ops").daemon_of(ws)
end

-- ---------------------------------------------------------------------------
-- In-process
-- ---------------------------------------------------------------------------

--- @param ws loomworks.Workspace
--- @return loomworks.StatusBody
local function in_process(ws)
    local view = ws:view_workspace({ bind = M.bind })
    local refs = bound
    return {
        mode = "in-process", view = view, loaded = true,
        -- A busy profile's percent and elapsed time and a running unit's
        -- step progress: the rows' domain objects (their operations, units
        -- and observed tasks).
        profile_progress = function(row)
            local profile = refs[row]
            if not profile then return nil end
            return { pct = profile:operation_pct(), elapsed = profile:operation_elapsed() }
        end,
        unit_progress = function(u)
            local pp = refs[u]
            local unit = pp and pp._config_unit
            if not unit then return nil end
            return { progress = unit:progress(), elapsed = unit:elapsed() }
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Daemon
-- ---------------------------------------------------------------------------

--- Whether a task observed through `Tasks/1` runs the unit row `u`, by the
--- ids its `start` meta names (API.md §4.2; step 5o C2d-2 — never by key):
--- only when it lists the unit row's `unit_id`. A task naming only the
--- profile's id (a device log, install or launch, a test discovery) runs no
--- unit; a profile's build, configure and clean list their units.
--- @param task loomworks.RemoteTask
--- @param u table the view's unit row
--- @return boolean
local function runs_unit(task, u)
    return u.unit_id ~= nil and task:names_ids(nil, { u.unit_id })
end

--- The running task observed through `Tasks/1` of a profile row (its
--- `start` meta names the row's profile id), else one without a profile
--- (scoped to units, or `scope = "all"`, whose `start` meta lists its units
--- too) that runs one of the row's running units.
--- `u`: only a task running that unit row (runs_unit).
--- @param tasks loomworks.RemoteTask[]
--- @param row loomworks.ViewProfile
--- @param u? table
--- @return loomworks.RemoteTask|nil
local function task_of(tasks, row, u)
    if u then
        for _, t in ipairs(tasks) do
            if not t.finished and runs_unit(t, u) then return t end
        end
        return nil
    end
    for _, t in ipairs(tasks) do
        if not t.finished and row.id ~= nil and t.profile_id == row.id then return t end
    end
    for _, t in ipairs(tasks) do
        if not t.finished and t.profile_id == nil then
            for _, x in ipairs(row.units or {}) do
                if x.state == "configuring" or x.state == "building" or x.state == "deleting" then
                    if runs_unit(t, x) then return t end
                end
            end
        end
    end
    return nil
end

--- @param obs loomworks.daemon.Observer|nil
--- @return loomworks.StatusBody
local function daemon(obs)
    local view, why
    if obs then
        view, why = obs:workspace_view()
    else
        why = "not connected to the workspace daemon"
    end
    -- Loaded is the header view's (§19.13): an unloaded daemon's view has
    -- `published = false` and empty arrays, which mean nothing then.
    local header = obs and require("loomworks.views").daemon_state(obs, "header")
    local loaded = type(header) == "table" and header.state == "loaded"
    -- unit row -> its profile row (a unit's task is its profile's).
    local owner
    local function profile_of(u)
        if not owner then
            owner = setmetatable({}, { __mode = "k" })
            for _, row in ipairs(view and view.profiles or {}) do
                for _, x in ipairs(row.units or {}) do owner[x] = row end
            end
        end
        return owner[u]
    end
    local tasks = obs and obs:tasks() or {}
    local function clock() return obs and obs:_clock() or 0 end
    return {
        mode = "daemon", view = view, why = why, loaded = loaded,
        profile_progress = function(row)
            local t = task_of(tasks, row)
            if not t then return nil end
            return { pct = t.pct, elapsed = t:elapsed(clock()) }
        end,
        -- `Tasks/1` carries a task's percent, not a unit's step progress:
        -- a running unit shows its task's elapsed time.
        unit_progress = function(u)
            local row = profile_of(u)
            local t = row and task_of(tasks, row, u)
            if not t then return nil end
            return { elapsed = t:elapsed(clock()) }
        end,
    }
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

--- The status page's body source for `ws`.
--- @param ws loomworks.Workspace
--- @return loomworks.StatusBody
function M.read(ws)
    local is_daemon, obs = daemon_of(ws)
    if is_daemon then return daemon(obs) end
    return in_process(ws)
end

--- Whether the workspace has changes not published (the status buffer's
--- 'modified', which makes Vim refuse `:e` with E37). In `daemon` mode
--- publish and revert (`:w`, `:e!`) run in the daemon (step 5o C2a), as does
--- every other status-page write (C2c-2): the daemon's view's `modified`
--- while that view is held; while it is not (connecting, waiting for it,
--- lost, a daemon without it, not connected at all) it is not known, and the
--- editor's model's is the best knowledge (the same files; it does not block
--- `:qa` for a clean working copy). The flag can still lag the daemon
--- (another client's write): a plain `:e` in `daemon` mode therefore never
--- reverts (ui/status.lua `_on_revert`), only `:e!` does. In the
--- `in-process` mode the editor's model's.
--- @param ws loomworks.Workspace|nil
--- @return boolean
function M.modified(ws)
    if not ws then return false end
    local is_daemon, obs = daemon_of(ws)
    if is_daemon then
        local view = obs and obs:workspace_view() or nil
        if type(view) == "table" then return view.modified == true end
    end
    return ws:has_any_modified() and true or false
end

return M
