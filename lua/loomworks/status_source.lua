--- loomworks/status_source.lua — where the status page's body reads
--- (daemon.md §19.13 "The workspace view"; step 5n part C1). The body —
--- Diagnostics, Suggestions, Profiles, Orphaned Build Dirs,
--- Configuration Sets, Projects and SDKs — renders only from one
--- `loomworks.view.Workspace/1` table this module gives, with the overlays
--- the view does not carry: build progress (API.md §14.4 "Progress is not in
--- the view") and, for the sections' actions, the row's model object.
---
--- One source per runtime mode (as loomworks/test_source.lua and
--- loomworks/lsp_source.lua):
---   * `daemon` mode: **only** the daemon's view as the observer holds it
---     (loomworks.views). Nothing of it is built in-process: while the view is
---     not held, `why` says why and each section is one `unavailable — <why>`
---     line. Progress comes from the tasks observed through `Tasks/1` (the
---     observer's remote and editor-owned tasks: their `start` meta names the
---     profile and units, `progress` frames the percent, `start` the elapsed
---     time). The sections' actions go through
---     loomworks/ui/model_calls.lua, which names a row's entity by the row's
---     id (step 5o C2a: Workspace/1, Profiles/1, ConfigSets/1).
---     *(Transition, until step 5o parts C2b and C2c.)* The actions not routed
---     yet still write the editor's in-process model (§19.16 "Transition"):
---     `ref` gives a row the model object its keys name.
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
--- @field ref fun(row: table): table|nil the model object of a row, for the actions
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
        ref = M.object_of,
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

--- *(Transition, until step 5o parts C2c-2 and C2d.)* The in-process model
--- objects the daemon view's rows name, for the sections' actions not routed
--- through the daemon yet (Maintenance/1, the project row's removal, and
--- the profile's builds, which name the profile by key), which still write or
--- read the editor's model (§19.16 "Transition"); the routed ones send the
--- row's id instead. The daemon's ids name nothing
--- here ("Two sources, one shape"): a row names its object by the keys it
--- shows (a profile's or project's key, a set's name, a configuration's
--- or launch's key, an orphaned entry's cache key). A row whose object
--- the editor's model does not have gets none: its actions are absent until
--- the model catches up (its file change arrives).
--- @param ws loomworks.Workspace
--- @param view loomworks.ViewWorkspace
--- @return table<table, table>
local function model_refs(ws, view)
    local refs = setmetatable({}, { __mode = "k" })
    local by = {}
    for _, p in pairs(ws:get_profiles() or {}) do by[p.key] = p end
    for _, row in ipairs(view.profiles or {}) do
        local p = by[row.key]
        if p then
            refs[row] = p
            local pps = {}
            for _, pp in ipairs(p:projects()) do pps[pp:project_key()] = pp end
            for _, u in ipairs(row.units or {}) do refs[u] = u.project and pps[u.project] or nil end
        end
    end
    by = {}
    for _, cs in pairs(ws:get_config_sets() or {}) do by[cs.name] = cs end
    for _, row in ipairs(view.config_sets or {}) do refs[row] = by[row.name] end
    by = {}
    for _, proj in pairs(ws:get_projects() or {}) do by[proj.key] = proj end
    for _, row in ipairs(view.projects or {}) do
        local proj = by[row.key]
        if proj then
            refs[row] = proj
            for _, c in ipairs(row.configurations or {}) do refs[c] = proj:get_configuration(c.key) end
            local launches = {}
            for _, launch in ipairs(proj:launch_configs()) do launches[launch.name] = launch end
            for _, l in ipairs(row.launches or {}) do refs[l] = launches[l.key] end
        end
    end
    by = {}
    for _, o in ipairs(ws:get_orphaned_configs() or {}) do by[o.build_dir_key or o.config_key] = o end
    for _, row in ipairs(view.orphaned and view.orphaned.configurations or {}) do refs[row] = by[row.key] end
    return refs
end

--- Whether a task observed through `Tasks/1` runs the unit `u` (a view's
--- unit row) of profile row `row`. A task of the row's profile runs it when
--- it runs its project (a profile maps one configuration per project); any
--- other task only when it runs that project's same configuration unit.
--- *(Transition, until step 5o parts C2b and C2c.)* The view's unit row names its
--- configuration, while a task's `start` meta names the configuration-unit
--- key; the row's unit key comes from the editor's model (`ref`, its
--- project-in-profile), and a row the model lacks matches no such task.
--- @param task loomworks.RemoteTask
--- @param row loomworks.ViewProfile
--- @param u table the view's unit row
--- @param ref fun(row: table): table|nil
--- @return boolean
local function runs_unit(task, row, u, ref)
    if task.profile_name == row.key then
        for _, tu in ipairs(task.units or {}) do
            if tu.project == u.project then return true end
        end
        return false
    end
    local pp = ref(u)
    local unit = pp and pp._config_unit
    if not unit then return false end
    for _, tu in ipairs(task.units or {}) do
        if tu.project == u.project
            and (tu.unit == unit or (tu.unit == nil and tu.configuration == unit:config_key())) then
            return true
        end
    end
    return false
end

--- The running task observed through `Tasks/1` of a profile row (its
--- `start` meta names the profile), else one without a profile (scoped to
--- units, or `scope = "all"`, whose `start` meta lists its units too) that
--- runs one of the row's running units — as the editor's model counts a
--- remote task as its units' profiles' operation (daemon/remote_task.lua).
--- `u`: only a task running that unit row.
--- @param tasks loomworks.RemoteTask[]
--- @param row loomworks.ViewProfile
--- @param ref fun(row: table): table|nil
--- @param u? table
--- @return loomworks.RemoteTask|nil
local function task_of(tasks, row, ref, u)
    for _, t in ipairs(tasks) do
        if not t.finished and t.profile_name == row.key and (u == nil or runs_unit(t, row, u, ref)) then
            return t
        end
    end
    for _, t in ipairs(tasks) do
        if not t.finished and t.profile_name == nil then
            if u then
                if runs_unit(t, row, u, ref) then return t end
            else
                for _, x in ipairs(row.units or {}) do
                    if x.state == "configuring" or x.state == "building" or x.state == "deleting" then
                        if runs_unit(t, row, x, ref) then return t end
                    end
                end
            end
        end
    end
    return nil
end

--- @param ws loomworks.Workspace
--- @param obs loomworks.daemon.Observer|nil
--- @return loomworks.StatusBody
local function daemon(ws, obs)
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
    local refs
    local function ref(row)
        if not view then return nil end
        refs = refs or model_refs(ws, view)
        return refs[row]
    end
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
        mode = "daemon", view = view, why = why, loaded = loaded, ref = ref,
        profile_progress = function(row)
            local t = task_of(tasks, row, ref)
            if not t then return nil end
            return { pct = t.pct, elapsed = t:elapsed(clock()) }
        end,
        -- `Tasks/1` carries a task's percent, not a unit's step progress:
        -- a running unit shows its task's elapsed time.
        unit_progress = function(u)
            local row = profile_of(u)
            local t = row and task_of(tasks, row, ref, u)
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
    if is_daemon then return daemon(ws, obs) end
    return in_process(ws)
end

--- Whether the workspace has changes not published (the status buffer's
--- 'modified', which makes Vim refuse `:e` with E37). In `daemon` mode
--- publish and revert (`:w`, `:e!`) run in the daemon (step 5o C2a): the
--- daemon's view's `modified` while that view is held and knows the
--- editor's own writes; otherwise — the view not held (connecting, waiting
--- for it, lost, a daemon without it, not connected at all), or an
--- in-process write (Maintenance/1 until C2c-2) whose
--- freshness `get` is not answered yet (Observer:workspace_view_stale) — it
--- is not known, and the editor's model's is the best knowledge (the same
--- files; it does not block `:qa` for a clean working copy). The flag can
--- still lag the daemon (another client's write): a plain `:e` in `daemon`
--- mode therefore never reverts (ui/status.lua `_on_revert`), only `:e!`
--- does. In the `in-process` mode the editor's model's.
--- @param ws loomworks.Workspace|nil
--- @return boolean
function M.modified(ws)
    if not ws then return false end
    local editor = ws:has_any_modified() and true or false
    local is_daemon, obs = daemon_of(ws)
    if is_daemon then
        local view = obs and obs:workspace_view() or nil
        if type(view) ~= "table" then return editor end
        if view.modified == true then return true end
        return obs:workspace_view_stale() and editor
    end
    return editor
end

return M
