--- loomworks/config_unit.lua — ConfigUnit: atomic unit of configuration state.
--- A ConfigUnit represents a unique (project_key, config_key) combination.
--- It owns the running/deleting state for that combination and provides
--- a single derived state value. Multiple profiles may reference the same
--- ConfigUnit; state changes are visible to all of them.

local cache_mod = require("loomworks.cache")

--- @class loomworks.ConfigUnit
--- @field project_key string
--- @field config_key string
--- @field variant? string configuration variant name (from cache data)
--- @field tool? loomworks.ToolRef bundled tool reference (from cache data)
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
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function ConfigUnit.new(workspace, project_key, config_key)
    local self = setmetatable({}, ConfigUnit)
    self._workspace = workspace
    self.project_key = project_key
    self.config_key = config_key
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

--- Refresh variant, tool, and project reference from cache/registries.
--- Preserves runtime state (_task_id, _action, _progress, _deleting, _listeners, targets).
function ConfigUnit:_update()
    if not self._workspace then
        self._project = nil
        self.variant = nil
        self.tool = nil
        return
    end
    -- Resolve direct project reference
    self._project = self._workspace._projects[self.project_key]

    local cached = self:cached_state()
    self.variant = cached and cached.variant or nil
    self.tool = nil
    if cached and cached.tool_key then
        self.tool = {
            key = cached.tool_key,
            data = cached.tool_data,
        }
    end
    -- Authoritative: resolve variant from a ProfileProject that references
    -- this config_key. PP.variant is always correct (comes from profile
    -- mappings), and takes priority over potentially stale cached variant.
    for _, pp in pairs(self._workspace._profile_projects) do
        if pp.project_key == self.project_key and pp.config_key == self.config_key then
            self.variant = pp.variant
            if pp._profile and pp._profile.tool then
                self.tool = {
                    key = pp._profile.tool.key,
                    data = pp._profile.tool.data,
                }
            end
            break
        end
    end
    -- Fallback: derive variant from config_key only when the project's module
    -- has no keyed tools. For keyed modules, the variant must come from cache
    -- or ProfileProject; callers (e.g. sections/projects.lua) set it
    -- explicitly for uncached entries.
    if not self.variant then
        local has_keyed = self.tool ~= nil
        if not has_keyed and self._project then
            local type_tools = self._workspace._tools_by_type[self._project.type]
            if type_tools then
                for _, dt in ipairs(type_tools) do
                    if dt.tool_key then has_keyed = true; break end
                end
            end
        end
        if not has_keyed then
            self.variant = self.config_key
        end
    end
end

function ConfigUnit:__tostring()
    return "ConfigUnit(" .. self.project_key .. ", " .. self.config_key .. ")"
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

--- Get cached state from the workspace cache.
--- @return loomworks.CachedConfig|nil
function ConfigUnit:cached_state()
    if not self._workspace then return nil end
    if not self._workspace.cache or not self._workspace.cache.configurations then return nil end
    local ck = cache_mod.config_cache_key(self.project_key, self.config_key)
    return self._workspace.cache.configurations[ck]
end

--- Get the build directory from cache.
--- @return string|nil
function ConfigUnit:build_dir()
    local cached = self:cached_state()
    return cached and cached.build_dir
end

--- Resolve the detected tool, enriching self.tool with label and mod_type.
--- @return loomworks.ToolRef|nil
function ConfigUnit:resolve_tool()
    if not self.tool or not self.tool.key then return self.tool end
    if self.tool.label then return self.tool end  -- already resolved
    local dt, mod_type = self._workspace._core._deps.merge.resolve_detected_tool(
        self._workspace._tools_by_type, self.tool.key)
    if dt then
        self.tool.label = dt.tool_label
        self.tool.mod_type = mod_type
        self.tool.data = dt.tool_data
    end
    return self.tool
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

--- Find all profiles that reference this (project_key, config_key) pair.
--- @return loomworks.Profile[]
function ConfigUnit:referencing_profiles()
    if not self._workspace then return {} end
    local result = {}
    for _, profile in pairs(self._workspace._profiles) do
        for _, pp in ipairs(profile:projects()) do
            if pp.project_key == self.project_key and pp.config_key == self.config_key then
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
--- @param variant? string configuration variant name (uses self.variant if nil)
--- @param tool? loomworks.ToolRef tool reference (uses self.tool if nil)
function ConfigUnit:materialize(variant, tool)
    local ws = self._workspace

    -- Wait for tool detection to complete before materializing
    if ws._tool_state == "scanning" then
        ws._tool_waiters[#ws._tool_waiters + 1] = function()
            self:materialize(variant, tool)
        end
        return
    end

    local project_config = ws.config.projects[self.project_key]
    if not project_config then return end

    -- Update fields from caller data
    if variant then self.variant = variant end
    if tool then self.tool = tool end

    -- Resolve tool_data from detected tools if not already available
    local tool_key = self.tool and self.tool.key or nil
    local tool_data = self.tool and self.tool.data or nil
    if tool_key and not tool_data then
        local dt = ws._core._deps.merge.resolve_detected_tool(ws._tools_by_type, tool_key)
        if dt then
            tool_data = dt.tool_data
            self.tool.data = tool_data
        end
    end

    -- Write directly to flat cache
    local cache_key = cache_mod.config_cache_key(self.project_key, self.config_key)
    ws.cache.configurations = ws.cache.configurations or {}
    local existing = ws.cache.configurations[cache_key]
    if not existing then
        ws.cache.configurations[cache_key] = {
            project_key = self.project_key,
            config_key = self.config_key,
            type = project_config.type,
            variant = self.variant,
            tool_key = tool_key,
            tool_data = tool_data,
        }

        ws:_save_cache()
        ws:remerge()
    elseif existing.variant ~= self.variant and self.variant then
        -- Repair stale variant in cache
        existing.variant = self.variant
        ws:_save_cache()
    end
end

--- Materialize a pinned profile for this configuration.
--- Creates the config skeleton and a pinned profile entry in cache.
--- @param variant? string configuration variant name (uses self.variant if nil)
--- @param tool? loomworks.ToolRef tool reference (uses self.tool if nil)
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

    local project_config = ws.config.projects[self.project_key]
    if not project_config then return nil end

    local ak = ws._core._deps.merge.pinned_key(self.project_key, self.config_key)

    -- Ensure config skeleton exists
    self:materialize(variant, tool)

    -- Check if pinned profile already exists
    ws.cache.profiles = ws.cache.profiles or {}
    if ws.cache.profiles[ak] then return ws._profiles[ak] end

    -- Use self.variant and self.tool (set by materialize or caller)
    self:resolve_tool()
    local tool_key = self.tool and self.tool.key or nil
    local tool_data = self.tool and self.tool.data or nil
    local tool_label = self.tool and self.tool.label or nil
    local tool_mod_type = self.tool and self.tool.mod_type or nil

    local cache_key = cache_mod.config_cache_key(self.project_key, self.config_key)
    ws.cache.profiles[ak] = {
        mappings = { [self.project_key] = self.variant },
        tool_key = tool_key,
        tool_data = tool_data,
        tool_label = tool_label,
        tool_mod_type = tool_mod_type,
        configurations = { cache_key },
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

    local items = { {
        project_key = self.project_key,
        config_key = self.config_key,
        build_dir = self:build_dir(),
        disposition = has_ref and "reset" or "clean",
    } }

    local defined_in_config = ws.config.projects[self.project_key] ~= nil

    return {
        items = items,
        project_key = self.project_key,
        config_key = self.config_key,
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
        if item.disposition ~= "keep" then
            local unit = self._workspace:get_config_unit(item.project_key, item.config_key)
            units[#units + 1] = unit
            target_states[unit] = "unconfigured"
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

    local items = { { project_key = self.project_key, config_key = self.config_key } }

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

    local proj_cfg = self._workspace.config.projects[self.project_key]
    if not proj_cfg then return nil end

    local mod = self._workspace._core._deps.modules.get(proj_cfg.type)
    if not mod or not mod.get_options then return nil end

    return mod.get_options(bd, proj_cfg.type_config)
end

-- ---------------------------------------------------------------------------
-- Task tracking (called by task_tracker component and Core)
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
