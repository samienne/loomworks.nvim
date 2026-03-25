--- loomworks/config_unit.lua — ConfigUnit: atomic unit of configuration state.
--- Identity is the cache dict key (e.g., "App/Debug:ninja-gcc").
--- Owns the running/deleting state and provides a single derived state value.
--- Multiple profiles may reference the same ConfigUnit.

local cache_mod = require("loomworks.cache")

--- @class loomworks.ConfigUnit
--- @field id string cache dict key (identity)
--- @field _tool? loomworks.Tool direct reference to Tool domain object
--- @field _configuration? loomworks.Configuration direct reference to Configuration domain object
--- @field _workspace loomworks.Workspace
--- @field _task_id number|nil current overseer task ID
--- @field _last_task_id number|nil most recent overseer task ID (persists after completion)
--- @field _action string|nil "configure" or "build" while a task is running
--- @field _progress loomworks.ProgressUpdate|nil
--- @field _start_time number|nil clock() value when task started
--- @field _deleting boolean
--- @field _deleting_reason "deleting"|"cleaning"|nil
--- @field _listeners function[]
--- @field _removed boolean
--- @field _project loomworks.Project|nil direct reference to project object
--- @field targets? table<string, loomworks.CachedTarget> runtime-only, from parse_file_api
local ConfigUnit = {}
ConfigUnit.__index = ConfigUnit

--- @alias loomworks.ConfigUnitState
--- | "unconfigured"
--- | "configuring"
--- | "configured"
--- | "building"
--- | "built"
--- | "configure_failed"
--- | "build_failed"
--- | "deleting"
--- | "unknown"

--- Create a new ConfigUnit.
--- @param workspace loomworks.Workspace
--- @param id string cache dict key (identity)
--- @param project_key? string hint for initial project resolution (before cache exists)
--- @return loomworks.ConfigUnit
function ConfigUnit.new(workspace, id, project_key)
    local self = setmetatable({}, ConfigUnit)
    self._workspace = workspace
    self.id = id
    self._init_project_key = project_key
    self._task_id = nil
    self._last_task_id = nil
    self._action = nil
    self._progress = nil
    self._start_time = nil
    self._deleting = false
    self._deleting_reason = nil
    self._listeners = {}
    self._removed = false
    self.targets = nil
    self:_update()
    return self
end

--- Refresh project, tool, and configuration references from cache/registries.
--- Preserves runtime state (_task_id, _action, _progress, _deleting, _listeners, targets).
function ConfigUnit:_update()
    if not self._workspace then
        self._project = nil
        self._cached = nil
        self._tool = nil
        self._configuration = nil
        return
    end

    -- Resolve direct cache reference (id IS the cache dict key)
    local cache = self._workspace.cache
    if cache and cache.configurations then
        self._cached = cache.configurations[self.id]
    else
        self._cached = nil
    end

    -- Resolve direct project reference: prefer cache, fall back to constructor hint
    local cached = self._cached
    local project_key = cached and cached.project_key or self._init_project_key
    self._project = project_key and self._workspace._projects[project_key] or nil

    -- Resolve Tool domain object from workspace registry
    self._tool = nil
    if cached and cached.tool_key then
        if self._workspace.find_tool then
            self._tool = self._workspace:find_tool(cached.type or (self._project and self._project.type), cached.tool_key)
        end
    end

    -- Resolve Configuration domain object from project registry
    self._configuration = nil
    local variant = cached and cached.variant or nil
    if variant and self._project and self._project._configurations then
        self._configuration = self._project._configurations[variant]
    end
end

function ConfigUnit:__tostring()
    if self._project then
        return "ConfigUnit(" .. self._project.key .. ", " .. self.id .. ")"
    elseif self._cached then
        return "ConfigUnit(" .. self._cached.project_key .. ", " .. self.id .. ")"
    end
    return "ConfigUnit(" .. self.id .. ")"
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Get the derived state for this unit.
--- Priority: deleting > running > cached.
--- @return loomworks.ConfigUnitState
function ConfigUnit:state()
    if self._deleting then return "deleting" end
    if self._action then
        return self._action == "configure" and "configuring" or "building"
    end
    local cached = self:cached_state()
    if not cached or not cached.state then return "unconfigured" end
    -- Map cached status names to ConfigUnitState names
    local state = cached.state
    if state == "failed_configure" then return "configure_failed" end
    if state == "failed_build" then return "build_failed" end
    if state == "unknown" then return "unknown" end
    return state
end

--- Check if a task is currently running on this unit.
--- @return boolean
function ConfigUnit:is_running()
    return self._action ~= nil
end

--- Get the running action name, if any.
--- @return string|nil "configure" or "build"
function ConfigUnit:running_action()
    return self._action
end

--- Check if this unit is being deleted/cleaned.
--- @return boolean
function ConfigUnit:is_deleting()
    return self._deleting
end

--- Get cached state (direct reference resolved during _update).
--- @return loomworks.CachedConfig|nil
function ConfigUnit:cached_state()
    return self._cached
end

--- Get the build directory from cache.
--- @return string|nil
function ConfigUnit:build_dir()
    local cached = self:cached_state()
    return cached and cached.build_dir
end

--- Get the Tool domain object for this unit.
--- Falls back to cache data when no domain object is available.
--- @return loomworks.Tool|nil
function ConfigUnit:resolve_tool()
    return self._tool
end

--- Get the Tool domain object for this unit.
--- @return loomworks.Tool|nil
function ConfigUnit:tool_object()
    return self._tool
end

--- Get the Configuration domain object for this unit.
--- @return loomworks.Configuration|nil
function ConfigUnit:configuration()
    return self._configuration
end

--- Get the Project domain object for this unit.
--- @return loomworks.Project|nil
function ConfigUnit:project()
    return self._project
end

--- Get the current progress update, if any.
--- @return loomworks.ProgressUpdate|nil
function ConfigUnit:progress()
    return self._progress
end

--- Get elapsed seconds since the running task started.
--- @return number|nil seconds
function ConfigUnit:elapsed()
    if not self._start_time then return nil end
    return self._workspace._core._deps.clock() - self._start_time
end

-- ---------------------------------------------------------------------------
-- Config-level actions
-- ---------------------------------------------------------------------------

--- Find all profiles that reference this ConfigUnit.
--- @return loomworks.Profile[]
function ConfigUnit:referencing_profiles()
    if not self._workspace then return {} end
    local result = {}
    for _, profile in pairs(self._workspace._profiles) do
        for _, pp in ipairs(profile:projects()) do
            if pp._config_unit == self then
                result[#result + 1] = profile
                break
            end
        end
    end
    table.sort(result, function(a, b) return a.key < b.key end)
    return result
end

--- Set targets from raw parse data, wrapping each in a Target object.
--- @param raw table<string, { type: string, dependencies?: string[], artifact?: string }>|nil
function ConfigUnit:set_targets(raw)
    if not raw then
        self.targets = nil
        return
    end
    local Target = require("loomworks.target")
    self.targets = {}
    for id, data in pairs(raw) do
        self.targets[id] = Target.new(self, id, data)
    end
end

--- Materialize a skeleton cache entry for this configuration.
--- Used for configuration-level build/configure actions.
--- @param variant? string configuration variant name
--- @param tool? loomworks.ToolRef tool reference { key, data }
function ConfigUnit:materialize(variant, tool)
    local ws = self._workspace

    -- Wait for tool detection to complete before materializing
    if ws._tool_state == "scanning" then
        ws._tool_waiters[#ws._tool_waiters + 1] = function()
            self:materialize(variant, tool)
        end
        return
    end

    if not self._project then return end

    -- Read variant from params > cached > configuration name
    local mat_variant = variant
        or (self._cached and self._cached.variant)
        or (self._configuration and self._configuration.name)
    -- Read tool from params > domain object > cached
    local tool_key = tool and tool.key or (self._tool and self._tool.key) or (self._cached and self._cached.tool_key)
    local tool_data = tool and tool.data or (self._tool and self._tool.data) or (self._cached and self._cached.tool_data)

    -- Resolve tool_data from detected tools if not already available
    if tool_key and not tool_data then
        local dt = ws._core._deps.merge.resolve_detected_tool(ws._tools_by_type, tool_key)
        if dt then
            tool_data = dt.tool_data
        end
    end

    -- Read project_key and config_key from domain objects / cache
    local project_key = self._project.key
    local config_key = self._cached and self._cached.config_key
        or ws._core._deps.merge.build_config_key(mat_variant, tool_key)

    -- Write directly to flat cache (id IS the cache dict key)
    ws.cache.configurations = ws.cache.configurations or {}
    local existing = ws.cache.configurations[self.id]
    if not existing then
        ws.cache.configurations[self.id] = {
            project_key = project_key,
            config_key = config_key,
            type = self._project.type,
            variant = mat_variant,
            tool_key = tool_key,
            tool_data = tool_data,
        }

        ws:_save_cache()
        ws:remerge()
    elseif existing.variant ~= mat_variant and mat_variant then
        -- Repair stale variant in cache
        existing.variant = mat_variant
        ws:_save_cache()
    end
end

--- Materialize a pinned profile for this configuration.
--- Creates the config skeleton and a pinned profile entry in cache.
--- @param variant? string configuration variant name
--- @param tool? loomworks.ToolRef tool reference { key, data }
--- @return loomworks.Profile|nil
function ConfigUnit:materialize_pinned(variant, tool)
    local ws = self._workspace

    -- Wait for tool detection to complete before materializing
    if ws._tool_state == "scanning" then
        ws._tool_waiters[#ws._tool_waiters + 1] = function()
            self:materialize_pinned(variant, tool)
        end
        return nil
    end

    if not self._project then return nil end

    -- Read project_key and config_key from domain objects / cache
    local project_key = self._project.key
    local cached = self._cached
    local config_key = cached and cached.config_key

    -- Ensure config skeleton exists (may update self._cached)
    self:materialize(variant, tool)
    cached = self._cached

    -- config_key may now be available from the newly-created cache entry
    if not config_key and cached then
        config_key = cached.config_key
    end
    if not config_key then return nil end

    local ak = ws._core._deps.merge.pinned_key(project_key, config_key)

    -- Check if pinned profile already exists
    ws.cache.profiles = ws.cache.profiles or {}
    if ws.cache.profiles[ak] then return ws._profiles[ak] end

    -- Read tool info from domain object or cache
    local tool_obj = self._tool
    local tool_key = tool_obj and tool_obj.key or (cached and cached.tool_key)
    local tool_data = tool_obj and tool_obj.data or (cached and cached.tool_data)
    local tool_label = tool_obj and tool_obj.label or nil
    local tool_mod_type = tool_obj and tool_obj.mod_type or nil

    -- If no mod_type from Tool object, try to determine from detected tools
    if tool_key and not tool_mod_type then
        local _, mt = ws._core._deps.merge.resolve_detected_tool(ws._tools_by_type, tool_key)
        tool_mod_type = mt
    end

    local mat_variant = cached and cached.variant or variant

    local tools = nil
    if tool_key and tool_mod_type then
        tools = {
            [tool_mod_type] = {
                key = tool_key,
                data = tool_data,
                label = tool_label,
            },
        }
    end
    ws.cache.profiles[ak] = {
        mappings = { [project_key] = mat_variant },
        tools = tools,
        configurations = { self.id },
    }

    ws:_save_cache()
    ws:remerge()
    return ws._profiles[ak]
end

--- Plan a deletion for this config.
--- If any profile references it, disposition = "reset" (clear state, keep
--- skeleton). Otherwise "clean" (remove entirely).
--- @return loomworks.DeletionPlan
function ConfigUnit:plan_deletion()
    local ws = self._workspace
    if not ws then
        return { items = {}, defined_in_config = false }
    end

    local has_ref = #self:referencing_profiles() > 0
    local cached = self._cached
    local project_key = self._project and self._project.key or (cached and cached.project_key)
    local config_key = cached and cached.config_key

    local items = { {
        project_key = project_key,
        config_key = config_key,
        build_dir = self:build_dir(),
        disposition = has_ref and "reset" or "clean",
    } }

    local defined_in_config = self._project ~= nil and not self._project._removed

    return {
        items = items,
        project_key = project_key,
        config_key = config_key,
        defined_in_config = defined_in_config,
    }
end

--- Delete this config (plan + execute, no UI confirmation).
--- Creates a delete Operation to track progress.
--- @param on_done? function
function ConfigUnit:delete(on_done)
    local plan = self:plan_deletion()

    -- Create Operation (profile is optional — use first referencing profile if available)
    local units = {}
    local target_states = {}
    for _, item in ipairs(plan.items) do
        if item.disposition ~= "keep" and item.unit then
            units[#units + 1] = item.unit
            target_states[item.unit] = "unconfigured"
        end
    end
    if #units > 0 then
        local refs = self:referencing_profiles()
        local profile = refs[1] or nil
        self._workspace:create_operation(profile, "delete", units, target_states)
    end

    self._workspace:execute_deletion(plan, nil, on_done)
end

--- Clean this config: run module clean tasks and reset build state.
--- Does NOT remove the build directory.
--- Creates a clean Operation to track progress.
--- @param on_done? function
function ConfigUnit:clean(on_done)
    local ws = self._workspace

    local cached = self._cached
    local project_key = self._project and self._project.key or (cached and cached.project_key)
    local config_key = cached and cached.config_key
    local items = { { project_key = project_key, config_key = config_key } }

    -- Cancel conflicting operations
    ws:cancel_conflicting_operations({ self })

    -- Mark as cleaning and create Operation synchronously so that
    -- has_pending_deletions() returns true immediately.
    self:mark_deleting(true, "cleaning")
    local refs = self:referencing_profiles()
    local profile = refs[1] or nil
    ws:create_operation(profile, "clean", { self }, { [self] = "configured" })

    -- Crash-safe: set cache to "configured" before async clean tasks.
    ws:mark_cached_configs_cleaned(items)

    -- Stop running tasks, then run module clean tasks
    local running = ws:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    ws:stop_tasks_then(task_ids, function()
        require("loomworks.overseer").run_configuration_clean(self, function()
            self:mark_deleting(false)
            if on_done then on_done() end
        end)
    end)
end

--- Get build options by delegating to the module.
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function ConfigUnit:options()
    local bd = self:build_dir()
    if not bd then return nil end

    if not self._project then return nil end

    local mod = self._workspace._core._deps.modules.get(self._project.type)
    if not mod or not mod.get_options then return nil end

    return mod.get_options(bd, self._project.type_config)
end

-- ---------------------------------------------------------------------------
-- Task tracking (called by overseer subscriptions and Core)
-- ---------------------------------------------------------------------------

--- Register a running task on this unit.
--- @param task_id number overseer task ID
--- @param action string "configure" or "build"
function ConfigUnit:register_task(task_id, action)
    self._task_id = task_id
    self._last_task_id = task_id
    self._action = action
    self._progress = nil
    self._start_time = self._workspace._core._deps.clock()
    self:_notify()
end

--- Unregister the running task.
--- @param task_id number overseer task ID (must match current)
function ConfigUnit:unregister_task(task_id)
    if self._task_id ~= task_id then return end
    self._task_id = nil
    self._action = nil
    self._progress = nil
    self._start_time = nil
    self:_notify()
end

--- Update progress for the running task.
--- @param task_id number
--- @param progress loomworks.ProgressUpdate
function ConfigUnit:update_progress(task_id, progress)
    if self._task_id ~= task_id then return end
    self._progress = progress
    self:_notify()
end

--- Get the most recent overseer task ID (running or completed).
--- @return number|nil
function ConfigUnit:last_task_id()
    return self._last_task_id
end

--- Open the output of the most recent overseer task in a Snacks.win float.
--- @param win_opts? table Snacks.win overrides from plugin config
--- @param on_close? fun() called when the window is closed
--- @return boolean opened true if a task was found and opened
function ConfigUnit:open_task_output(win_opts, on_close)
    if not self._last_task_id then return false end
    local task = self._workspace._core._deps.get_overseer_task(self._last_task_id)
    if not task then return false end
    local bufnr = task:get_bufnr()
    if not bufnr then return false end

    local Snacks = require("snacks")
    local config = vim.tbl_deep_extend("force", {
        position = "float",
        buf = bufnr,
        enter = true,
        width = 0.9,
        height = 0.85,
        border = "rounded",
        title = " " .. (task.name or "Task") .. " ",
        title_pos = "center",
        keys = { q = "close" },
        wo = {
            number = false,
            relativenumber = false,
            signcolumn = "no",
            wrap = false,
        },
    }, win_opts or {})

    if on_close then
        local orig_on_close = config.on_close
        config.on_close = function(self_win)
            if orig_on_close then orig_on_close(self_win) end
            on_close()
        end
    end

    local win = Snacks.win(config)

    -- Scroll to end
    if win.win and vim.api.nvim_win_is_valid(win.win) then
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        if line_count > 0 then
            vim.api.nvim_win_set_cursor(win.win, { line_count, 0 })
        end
    end

    return true
end

--- Mark this unit as deleting/cleaning (or clear the flag).
--- @param flag boolean
--- @param reason? "deleting"|"cleaning" defaults to "deleting"
function ConfigUnit:mark_deleting(flag, reason)
    self._deleting = flag
    self._deleting_reason = flag and (reason or "deleting") or nil
    self:_notify()
end

--- Get the reason this unit is being deleted/cleaned.
--- @return "deleting"|"cleaning"|nil
function ConfigUnit:deleting_reason()
    return self._deleting_reason
end

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

--- Subscribe to state changes on this unit.
--- The callback receives the unit as its argument.
--- Returns an unsubscribe function.
--- @param fn fun(unit: loomworks.ConfigUnit)
--- @return fun() unsubscribe
function ConfigUnit:on_state_change(fn)
    self._listeners[#self._listeners + 1] = fn
    return function()
        for i, listener in ipairs(self._listeners) do
            if listener == fn then
                table.remove(self._listeners, i)
                return
            end
        end
    end
end

--- Fire all listeners.
function ConfigUnit:_notify()
    for _, fn in ipairs(self._listeners) do
        fn(self)
    end
end

return ConfigUnit
