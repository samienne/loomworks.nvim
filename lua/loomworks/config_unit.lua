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
--- @field _core loomworks.Core
--- @field _task_id number|nil current overseer task ID
--- @field _action string|nil "configure" or "build" while a task is running
--- @field _progress loomworks.ProgressUpdate|nil
--- @field _start_time number|nil clock() value when task started
--- @field _deleting boolean
--- @field _queued_action string|nil action to run after deletion completes
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
--- @param core loomworks.Core
--- @param project_key string
--- @param config_key string
--- @return loomworks.ConfigUnit
function ConfigUnit.new(core, project_key, config_key)
    local self = setmetatable({}, ConfigUnit)
    self._core = core
    self.project_key = project_key
    self.config_key = config_key
    self._task_id = nil
    self._action = nil
    self._progress = nil
    self._start_time = nil
    self._deleting = false
    self._queued_action = nil
    self._listeners = {}
    self._removed = false
    self.targets = nil
    self:_update()
    return self
end

--- Refresh variant, tool, and project reference from cache/registries.
--- Preserves runtime state (_task_id, _action, _progress, _deleting, _listeners, targets).
function ConfigUnit:_update()
    -- Resolve direct project reference
    self._project = self._core._projects[self.project_key]

    local cached = self:cached_state()
    self.variant = cached and cached.variant or nil
    self.tool = nil
    if cached and cached.tool_key then
        self.tool = {
            key = cached.tool_key,
            data = cached.tool_data,
        }
    end
    -- Fallback: for non-keyed modules, config_key IS the variant
    if not self.variant then
        if self._project and not self._core:module_has_keyed_tools(self._project.type) then
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
    local ws = self._core:get_workspace()
    if not ws or not ws.cache.configurations then return nil end
    local ck = cache_mod.config_cache_key(self.project_key, self.config_key)
    return ws.cache.configurations[ck]
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
    local dt, mod_type = self._core._deps.merge.resolve_detected_tool(
        self._core._tools_by_type, self.tool.key)
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
    return self._core._deps.clock() - self._start_time
end

-- ---------------------------------------------------------------------------
-- Config-level actions
-- ---------------------------------------------------------------------------

--- Find all profiles that reference this (project_key, config_key) pair.
--- @return loomworks.Profile[]
function ConfigUnit:referencing_profiles()
    local result = {}
    for _, profile in pairs(self._core._profiles) do
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

--- Build a specific target for this configuration.
--- Delegates to the module's build_target_task via overseer.
--- Falls back to full build if the module doesn't support target builds.
--- @param target_id string opaque target identifier
function ConfigUnit:build_target(target_id)
    if not self._project then return end
    local modules = require("loomworks.modules")
    local mod = modules.get(self._project.type)
    if not mod then return end

    -- If module supports target-specific builds, use it
    if mod.build_target_task then
        local ws = self._core:get_workspace()
        if not ws then return end
        local project_ctx = self._project:to_module_context(ws.root)
        project_ctx.configuration = self.variant
        project_ctx.configuration_key = self.config_key
        project_ctx.tool_data = self.tool and self.tool.data or nil
        project_ctx.env = project_ctx.tool_data and project_ctx.tool_data.env or {}

        local task_def = mod.build_target_task(project_ctx, target_id)
        if task_def then
            require("loomworks.overseer").launch_single_task(task_def, self)
            return
        end
    end

    -- Fallback: full build via existing action
    require("loomworks.overseer").run_configuration_action(self, "build")
end

--- Materialize a skeleton cache entry for this configuration.
--- Used for configuration-level build/configure actions.
--- @param variant? string configuration variant name (uses self.variant if nil)
--- @param tool? loomworks.ToolRef tool reference (uses self.tool if nil)
function ConfigUnit:materialize(variant, tool)
    local core = self._core
    if not core._workspace then return end

    -- Wait for tool detection to complete before materializing
    if core._tool_state == "scanning" then
        core._tool_waiters[#core._tool_waiters + 1] = function()
            self:materialize(variant, tool)
        end
        return
    end

    local ws = core._workspace
    local project_config = ws.config.projects[self.project_key]
    if not project_config then return end

    -- Update fields from caller data
    if variant then self.variant = variant end
    if tool then self.tool = tool end

    -- Resolve tool_data from detected tools if not already available
    local tool_key = self.tool and self.tool.key or nil
    local tool_data = self.tool and self.tool.data or nil
    if tool_key and not tool_data then
        local dt = core._deps.merge.resolve_detected_tool(core._tools_by_type, tool_key)
        if dt then
            tool_data = dt.tool_data
            self.tool.data = tool_data
        end
    end

    -- Write directly to flat cache
    local cache_key = cache_mod.config_cache_key(self.project_key, self.config_key)
    ws.cache.configurations = ws.cache.configurations or {}
    if not ws.cache.configurations[cache_key] then
        ws.cache.configurations[cache_key] = {
            project_key = self.project_key,
            config_key = self.config_key,
            type = project_config.type,
            variant = self.variant,
            tool_key = tool_key,
            tool_data = tool_data,
        }

        core:_save_cache()
        core:remerge()
    end
end

--- Materialize a pinned profile for this configuration.
--- Creates the config skeleton and a pinned profile entry in cache.
--- @param variant? string configuration variant name (uses self.variant if nil)
--- @param tool? loomworks.ToolRef tool reference (uses self.tool if nil)
--- @return loomworks.Profile|nil
function ConfigUnit:materialize_pinned(variant, tool)
    local core = self._core
    if not core._workspace then return nil end

    -- Wait for tool detection to complete before materializing
    if core._tool_state == "scanning" then
        core._tool_waiters[#core._tool_waiters + 1] = function()
            self:materialize_pinned(variant, tool)
        end
        return nil
    end

    local ws = core._workspace
    local project_config = ws.config.projects[self.project_key]
    if not project_config then return nil end

    local ak = core._deps.merge.pinned_key(self.project_key, self.config_key)

    -- Ensure config skeleton exists
    self:materialize(variant, tool)

    -- Check if pinned profile already exists
    ws.cache.profiles = ws.cache.profiles or {}
    if ws.cache.profiles[ak] then return core._profiles[ak] end

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

    core:_save_cache()
    core:remerge()
    return core._profiles[ak]
end

--- Plan a deletion for this config.
--- If any profile references it, disposition = "reset" (clear state, keep
--- skeleton). Otherwise "clean" (remove entirely).
--- @return loomworks.DeletionPlan
function ConfigUnit:plan_deletion()
    local core = self._core
    if not core:get_workspace() then
        return { items = {}, project_key = self.project_key, config_key = self.config_key, defined_in_config = false }
    end

    local ws = core:get_workspace()
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
--- @param on_done? function
function ConfigUnit:delete(on_done)
    local plan = self:plan_deletion()
    self._core:execute_deletion(plan, nil, on_done)
end

--- Clean this config: delete build dir and reset to unconfigured.
--- @param on_done? function
function ConfigUnit:clean(on_done)
    if not self._core:get_workspace() then
        if on_done then on_done() end
        return
    end

    local items = { {
        project_key = self.project_key,
        config_key = self.config_key,
        build_dir = self:build_dir(),
    } }
    self._core:_run_deletion(items, function(effective_items)
        self._core:reset_cached_configs(effective_items)
    end, on_done)
end

--- Get build options by delegating to the module.
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function ConfigUnit:options()
    local bd = self:build_dir()
    if not bd then return nil end

    local ws = self._core:get_workspace()
    if not ws then return nil end
    local proj_cfg = ws.config.projects[self.project_key]
    if not proj_cfg then return nil end

    local mod = self._core._deps.modules.get(proj_cfg.type)
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
    self._action = action
    self._progress = nil
    self._start_time = self._core._deps.clock()
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

--- Mark this unit as deleting/cleaning (or clear the flag).
--- @param flag boolean
function ConfigUnit:mark_deleting(flag)
    self._deleting = flag
    if not flag then
        self._queued_action = nil
    end
    self:_notify()
end

--- Queue an action to run after the current deletion completes.
--- Only valid while the unit is deleting. Replaces any previously queued action.
--- @param action string "configure" or "build"
function ConfigUnit:queue_action(action)
    if not self._deleting then return end
    self._queued_action = action
    self:_notify()
end

--- Get the queued action, if any.
--- @return string|nil "configure" or "build"
function ConfigUnit:queued_action()
    return self._queued_action
end

--- Pop the queued action (retrieve and clear).
--- @return string|nil "configure" or "build"
function ConfigUnit:pop_queued_action()
    local action = self._queued_action
    self._queued_action = nil
    return action
end

-- ---------------------------------------------------------------------------
-- Listeners
-- ---------------------------------------------------------------------------

--- Subscribe to state changes on this unit.
--- The callback receives the unit as its argument.
--- @param fn fun(unit: loomworks.ConfigUnit)
function ConfigUnit:on_state_change(fn)
    self._listeners[#self._listeners + 1] = fn
end

--- Fire all listeners.
function ConfigUnit:_notify()
    for _, fn in ipairs(self._listeners) do
        fn(self)
    end
end

return ConfigUnit
