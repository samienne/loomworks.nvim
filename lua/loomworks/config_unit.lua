--- loomworks/config_unit.lua — ConfigUnit: atomic unit of configuration state.
--- Identity is the relative build_dir path (e.g., "build/App/Debug").
--- Owns the running/deleting state and provides a single derived state value.
--- Multiple profiles may reference the same ConfigUnit.

--- @class loomworks.ConfigUnit
--- @field id string relative build_dir path (identity, e.g., "build/App/Debug")
--- @field _workspace loomworks.Workspace
--- @field _init_project_key string|nil hint for project resolution
--- References (resolved during _apply):
--- @field _project loomworks.Project|nil
--- @field _tool loomworks.Tool|nil
--- @field _configuration loomworks.Configuration|nil
--- @field _build_dir loomworks.BuildDir|nil
--- First-class data fields (from cache, mutated at runtime):
--- @field state_value loomworks.Status|nil
--- @field build_dir_value string|nil
--- @field last_configured string|nil ISO 8601 timestamp
--- @field last_built string|nil ISO 8601 timestamp
--- @field module_info table|nil opaque module-specific cached data (e.g. cmake generator/compiler)
--- @field _config_key string|nil opaque cache key
--- @field _variant string|nil configuration variant name
--- @field _tool_key string|nil tool identifier
--- @field _tool_data table|nil module-specific tool data
--- Cached configuration snapshot (for stale detection):
--- @field _cached_options table|nil options snapshot from last configure
--- @field _cached_module_config table|nil module_config snapshot from last configure
--- Runtime state (never touched by _apply):
--- @field _task_id number|nil current overseer task ID
--- @field _last_task_id number|nil most recent overseer task ID
--- @field _action string|nil "configure" or "build" while running
--- @field _progress loomworks.ProgressUpdate|nil
--- @field _start_time number|nil clock() value when task started
--- @field _deleting boolean
--- @field _deleting_reason "deleting"|"cleaning"|nil
--- @field _listeners function[]
--- @field _removed boolean
--- @field targets table<string, loomworks.Target>|nil runtime-only
--- Test integration (runtime-only):
--- @field _test_tree table[]|nil cached merged test entries from all TestUnits
--- @field _test_results table[]|nil last parsed test results
--- @field _test_units loomworks.TestUnit[]|nil lazily created TestUnit array
--- @field _last_test_task_id number|nil most recent test overseer task ID
local ConfigUnit = {}
ConfigUnit.__index = ConfigUnit

--- Create a new ConfigUnit (shell only — call _apply(data) to resolve references).
--- @param workspace loomworks.Workspace
--- @param id string cache dict key (identity)
--- @param project_key? string hint for initial project resolution (before cache exists)
--- @return loomworks.ConfigUnit
function ConfigUnit.new(workspace, id, project_key)
    local self = setmetatable({}, ConfigUnit)
    self._workspace = workspace
    self.id = id
    self._init_project_key = project_key
    -- Runtime fields (never touched by _apply)
    self._task_id = nil
    self._last_task_id = nil
    self._action = nil
    self._progress = nil
    self._start_time = nil
    self._last_progress_notify = nil
    self._deleting = false
    self._deleting_reason = nil
    self._listeners = {}
    self._removed = false
    self.targets = nil
    -- Test integration
    self._test_tree = nil
    self._test_results = nil
    self._test_units = nil
    self._last_test_task_id = nil
    -- References (resolved during _apply)
    self._project = nil
    self._tool = nil
    self._configuration = nil
    self._build_dir = nil
    -- First-class data fields
    self.state_value = nil
    self.build_dir_value = nil
    self.last_configured = nil
    self.last_built = nil
    self.module_info = nil
    self._config_key = nil
    self._variant = nil
    self._tool_key = nil
    self._tool_data = nil
    self._cached_options = nil
    self._cached_module_config = nil
    return self
end

--- Get the tool/configuration compatibility error for this unit
--- when used by the workspace's active profile, if any. Looks up
--- the active profile's ProfileProject for this unit and returns
--- its `_tool_compat_error`. Returns nil when no active profile
--- references this unit, or when the active profile's tool is
--- compatible.
---
--- The compat error is stored per-(profile, configuration) on
--- ProfileProject — the same ConfigUnit can be valid in one
--- profile and invalid in another. Action gates that operate on a
--- ConfigUnit use this helper to check against the active profile
--- (which is what overseer will actually use).
--- @return string|nil reason
function ConfigUnit:tool_compat_error()
    local ws = self._workspace
    local active = ws and ws._active_profile or nil
    if not active then return nil end
    for _, pp in ipairs(active:projects()) do
        if pp._config_unit == self then
            return pp._tool_compat_error
        end
    end
    return nil
end

--- Refresh project, tool, and configuration references from pre-resolved data.
--- Preserves runtime state (_task_id, _action, _progress, _deleting, _listeners, targets).
--- Populates first-class fields from the cached input data (reads but does not store).
--- @param data? { cached?: loomworks.CachedConfig, project?: loomworks.Project, tool?: loomworks.Tool, configuration?: loomworks.Configuration, build_dir?: loomworks.BuildDir }
function ConfigUnit:_apply(data)
    if not data then
        self._project = nil
        self._tool = nil
        self._configuration = nil
        self._build_dir = nil
        self.state_value = nil
        self.build_dir_value = nil
        self.last_configured = nil
        self.last_built = nil
        self.module_info = nil
        self._config_key = nil
        self._variant = nil
        self._tool_key = nil
        self._tool_data = nil
        self._cached_options = nil
        self._cached_module_config = nil
        return
    end
    self._project = data.project
    self._tool = data.tool
    self._configuration = data.configuration
    if data.build_dir ~= nil then self._build_dir = data.build_dir end
    -- Populate first-class fields from cached data when available
    if data.cached then
        local c = data.cached
        self.state_value = c.state
        self.build_dir_value = c.build_dir
        self.last_configured = c.last_configured
        self.last_built = c.last_built
        self.module_info = c.module_info
        self._config_key = c.config_key
        self._variant = c.variant
        self._tool_key = c.tool_key
        self._tool_data = c.tool_data
        self._cached_options = c.options
        self._cached_module_config = c.module_config
    else
        -- Profile-resolved but no cache entry: unconfigured with known build_dir
        self.state_value = nil
        self.build_dir_value = data.build_dir_value
        self.last_configured = nil
        self.last_built = nil
        self.module_info = nil
        -- Derive fields from references if not previously set
        if not self._variant then
            self._variant = data.configuration and data.configuration.name or nil
        end
        if not self._tool_key then
            self._tool_key = data.tool and data.tool.key or nil
            self._tool_data = data.tool and data.tool.data or nil
        end
        -- Derive _config_key if not previously set
        if not self._config_key and self._variant then
            local merge_mod = require("loomworks.merge")
            self._config_key = merge_mod.build_config_key(self._variant, self._tool_key)
        end
        self._cached_options = nil
        self._cached_module_config = nil
    end
end

--- Serialize this ConfigUnit to a cache entry for persistence.
--- Produces cache-shaped table from first-class fields and references.
--- Includes a configuration snapshot so cache entries are self-describing.
--- The entry is written under the build_dir key by the caller (_serialize_cache).
--- @return table cache entry suitable for cache.build_dirs[id]
function ConfigUnit:serialize()
    local entry = {
        project_key = self._project and self._project.key or self._init_project_key,
        config_key = self._config_key,
        type = self._project and self._project.type or nil,
        variant = self._variant,
        tool_key = self._tool_key,
        tool_data = self._tool_data,
        build_dir = self.build_dir_value,
        state = self.state_value,
        last_configured = self.last_configured,
        last_built = self.last_built,
    }
    if self.module_info then entry.module_info = self.module_info end
    -- Configuration snapshot: inline definition data for self-describing entries
    if self._configuration and not self._configuration._removed then
        local cfg = self._configuration
        if cfg.options then entry.options = cfg.options end
        if cfg.module_config and next(cfg.module_config) then
            entry.module_config = cfg.module_config
        end
        if cfg.is_user then entry.is_user = true end
        if cfg.inherits_names and #cfg.inherits_names > 0 then
            entry.inherits = #cfg.inherits_names == 1
                and cfg.inherits_names[1] or cfg.inherits_names
        end
    end
    return entry
end

--- Get the variant name for this unit.
--- Prefers Configuration name, falls back to stored variant.
--- @return string|nil
function ConfigUnit:variant()
    if self._configuration and not self._configuration._removed then
        return self._configuration.name
    end
    return self._variant
end

--- Get the config key for this unit.
--- @return string|nil
function ConfigUnit:config_key()
    return self._config_key
end

--- Get the tool key for this unit.
--- @return string|nil
function ConfigUnit:tool_key()
    return self._tool_key
end

--- Get the tool data for this unit.
--- @return table|nil
function ConfigUnit:tool_data()
    return self._tool_data
end

function ConfigUnit:__tostring()
    if self._project then
        return "ConfigUnit(" .. self._project.key .. ", " .. self.id .. ")"
    elseif self._init_project_key then
        return "ConfigUnit(" .. self._init_project_key .. ", " .. self.id .. ")"
    end
    return "ConfigUnit(" .. self.id .. ")"
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- Get the derived state for this unit.
--- Priority: deleting > running > first-class field.
--- @return loomworks.ConfigUnitState
function ConfigUnit:state()
    if self._deleting then return "deleting" end
    if self._action then
        return self._action == "configure" and "configuring" or "building"
    end
    local state = self.state_value
    if not state then return "unconfigured" end
    -- Map cached status names to ConfigUnitState names
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

--- Get the build directory.
--- @return string|nil
function ConfigUnit:build_dir()
    return self.build_dir_value
end

--- Compose the run environment for this unit's built executables (§8.7):
--- prepend to `PATH` (1) the build tree's shared-library / module-library
--- output directories — so a DLL-dependent executable finds its siblings —
--- derived generically from parsed targets, and (2) any `runtime_path()`
--- directories the owning module supplies for the toolchain runtime (§8.4).
---
--- Windows only: on Linux/macOS shared libraries are resolved via the rpath the
--- build system bakes into the tree, so nothing is prepended. Directories are
--- added in a deterministic (sorted) order so `PATH` precedence is stable.
---
--- The single source of truth for the run environment. Both target launches
--- (`Target:resolve_run_spec`) and the test runner use it, so a DLL-dependent
--- executable resolves its siblings identically whether run or tested. Returns
--- nil when there is nothing to add (leave the process env inherited as-is).
--- @return table<string,string>|nil
function ConfigUnit:run_env()
    if vim.fn.has("win32") ~= 1 then return nil end

    local build_dir = self:build_dir()
    if not build_dir or build_dir == "" then return nil end

    local prefix, seen = {}, {}
    local function add(dir)
        if type(dir) == "string" and dir ~= "" and not seen[dir] then
            seen[dir] = true
            prefix[#prefix + 1] = dir
        end
    end

    -- (1) Toolchain runtime dirs (module-specific, e.g. compiler bin dir).
    local mod = self._project and self._project._module and self._project._module.impl
    if mod and mod.runtime_path then
        local ok, dirs = pcall(mod.runtime_path, {
            build_dir = build_dir,
            tool_data = self._tool_data,
            config_name = self.variant and self:variant() or nil,
        })
        if ok and type(dirs) == "table" then
            for _, d in ipairs(dirs) do add(d) end
        end
    end

    -- (2) Shared-library sibling output dirs (generic, from parse_targets).
    -- Sorted so PATH precedence is deterministic (parse output is unordered).
    local lib_dirs = {}
    for _, t in pairs(self.targets or {}) do
        if (t.type == "shared_library" or t.type == "module_library") and t.artifact then
            local full = (build_dir .. "/" .. t.artifact):gsub("\\", "/")
            local d = full:match("^(.*)/[^/]*$")
            if d then lib_dirs[#lib_dirs + 1] = d end
        end
    end
    table.sort(lib_dirs)
    for _, d in ipairs(lib_dirs) do add(d) end

    if #prefix == 0 then return nil end
    return require("loomworks.runenv").compose(prefix)
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

--- Check if this unit is stale: the Configuration's options or module_config
--- have changed since the last configure. Returns false when the unit has
--- never been configured (no cached snapshot to compare against).
--- @return boolean
function ConfigUnit:is_stale()
    if not self._configuration or self._configuration._removed then return false end
    -- No cached snapshot means never configured — not stale
    if not self._cached_options and not self._cached_module_config then return false end
    if not vim.deep_equal(self._cached_options or {}, self._configuration.options or {}) then
        return true
    end
    if not vim.deep_equal(self._cached_module_config or {}, self._configuration.module_config or {}) then
        return true
    end
    return false
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
--- Writes first-class fields directly — no remerge needed.
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

    -- Read variant from params > first-class field > configuration name
    local mat_variant = variant
        or self._variant
        or (self._configuration and self._configuration.name)
    -- Read tool from params > domain object > first-class field
    local tool_key = tool and tool.key or (self._tool and self._tool.key) or self._tool_key
    local tool_data = tool and tool.data or (self._tool and self._tool.data) or self._tool_data

    -- Resolve tool_data from detected tools if not already available
    if tool_key and not tool_data then
        local dt = ws._core._deps.merge.resolve_detected_tool(ws._tools_by_type, tool_key)
        if dt then
            tool_data = dt.tool_data
        end
    end

    -- Read project_key and config_key from domain objects / first-class fields
    local config_key = self._config_key
        or ws._core._deps.merge.build_config_key(mat_variant, tool_key)

    -- Write first-class fields only
    if not self._config_key then
        self._config_key = config_key
        self._variant = mat_variant
        self._tool_key = tool_key
        self._tool_data = tool_data
        ws:_save_cache()
    elseif self._variant ~= mat_variant and mat_variant then
        -- Repair stale variant
        self._variant = mat_variant
        ws:_save_cache()
    end
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
        unit = self,
        build_dir = self:build_dir(),
        disposition = has_ref and "reset" or "clean",
    } }

    local defined_in_config = self._project ~= nil and not self._project._removed

    return {
        items = items,
        defined_in_config = defined_in_config,
    }
end

--- Delete this config (plan + execute, no UI confirmation).
--- Creates a delete Operation to track progress.
--- @param on_done? function
--- Delete this config unit. Returns a Future.
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function ConfigUnit:delete(on_done)
    local plan = self:plan_deletion()

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

    return self._workspace:execute_deletion(plan, nil, on_done)
end

--- Clean this config: run module clean tasks and reset build state.
--- Returns a Future.
--- @param on_done? function legacy callback (deprecated)
--- @return loomworks.Future
function ConfigUnit:clean(on_done)
    local ws = self._workspace
    local items = { { unit = self } }

    ws:cancel_conflicting_operations({ self })

    self:mark_deleting(true, "cleaning")
    local refs = self:referencing_profiles()
    local profile = refs[1] or nil
    ws:create_operation(profile, "clean", { self }, { [self] = "configured" })

    ws:mark_cached_configs_cleaned(items)

    local running = ws:find_running_tasks_for_items(items)
    local task_ids = {}
    for task_id in pairs(running) do
        task_ids[#task_ids + 1] = task_id
    end

    local unit = self
    local f = ws:stop_tasks_then(task_ids):next(function()
        return require("loomworks.overseer").run_configuration_clean(unit)
    end):next(function()
        unit:mark_deleting(false)
        return true
    end)

    if on_done then
        f:next(function() on_done() end)
         :catch(function() on_done() end)
    end
    return f
end

--- Get build options by delegating to the module.
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function ConfigUnit:options()
    local bd = self:build_dir()
    if not bd then return nil end

    if not self._project then return nil end

    local impl = self._project._module and self._project._module.impl or nil
    if not impl or not impl.get_options then return nil end

    return impl.get_options(bd, self._project.type_config)
end

-- ---------------------------------------------------------------------------
-- Task tracking (called by overseer subscriptions and Core)
-- ---------------------------------------------------------------------------

--- Register a running task on this unit.
--- Disposes the previous completed task if any (keeps overseer list clean).
--- @param task_id number overseer task ID
--- @param action string "configure" or "build"
function ConfigUnit:register_task(task_id, action)
    local log = self._workspace and self._workspace._core and self._workspace._core._deps.log
    if log then log:debug("ConfigUnit[%s]: register task %d action=%s", self._config_key or "?", task_id, action) end
    -- Dispose previous completed task to avoid accumulation in overseer
    if self._last_task_id and self._last_task_id ~= task_id then
        local prev = self._workspace._core._deps.get_overseer_task(self._last_task_id)
        if prev and prev:is_complete() then
            prev:dispose()
        end
    end
    self._task_id = task_id
    self._last_task_id = task_id
    self._action = action
    self._progress = nil
    self._start_time = self._workspace._core._deps.clock()
    self:_notify()
end

--- Unregister the running task.
--- If the task ID matches, clears task state and fires listeners.
--- If the task was never registered (on_start didn't fire), still fires
--- listeners so that Operations observing this unit can see the state change
--- from record_task_result.
--- @param task_id number overseer task ID
function ConfigUnit:unregister_task(task_id)
    local log = self._workspace and self._workspace._core and self._workspace._core._deps.log
    if self._task_id == task_id then
        if log then log:debug("ConfigUnit[%s]: unregister task %d (matched)", self._config_key or "?", task_id) end
        self._task_id = nil
        self._action = nil
        self._progress = nil
        self._start_time = nil
    elseif self._task_id ~= nil then
        -- Different task is running — don't touch state, don't notify
        if log then log:warn("ConfigUnit[%s]: unregister task %d ignored (current task %d)",
            self._config_key or "?", task_id, self._task_id) end
        return
    else
        -- Task was never registered (on_start didn't fire)
        if log then log:debug("ConfigUnit[%s]: unregister task %d (never registered, notifying anyway)",
            self._config_key or "?", task_id) end
    end
    -- Notify even if task was never registered (on_start didn't fire).
    -- record_task_result already updated state_value; listeners need to
    -- observe the change so Operations can complete.
    self:_notify()
end

--- Minimum interval between progress notifications (seconds).
local PROGRESS_THROTTLE = 0.2

--- Update progress for the running task.
--- Throttled: notifies at most every PROGRESS_THROTTLE seconds to avoid
--- excessive UI refreshes from fast-updating output.
--- @param task_id number
--- @param progress loomworks.ProgressUpdate
function ConfigUnit:update_progress(task_id, progress)
    if self._task_id ~= task_id then return end
    self._progress = progress
    local now = self._workspace._core._deps.clock()
    if self._last_progress_notify and (now - self._last_progress_notify) < PROGRESS_THROTTLE then
        return
    end
    self._last_progress_notify = now
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

-- ---------------------------------------------------------------------------
-- Test integration
-- ---------------------------------------------------------------------------

--- Get the module implementation for this unit's project.
--- @return table|nil module implementation table
function ConfigUnit:_module_impl()
    if not self._project then return nil end
    return self._project._module and self._project._module.impl or nil
end

--- Get or create the TestUnit array for this configuration.
--- Created lazily by calling the module's create_test_unit factory.
--- @return loomworks.TestUnit[]
function ConfigUnit:test_units()
    if self._test_units then return self._test_units end

    local impl = self:_module_impl()
    if not impl or not impl.create_test_unit then
        self._test_units = {}
        return self._test_units
    end

    local tu = impl.create_test_unit(self)
    self._test_units = tu and { tu } or {}
    return self._test_units
end

--- Discover tests for this configuration. Returns cached results if
--- available, or runs discovery synchronously. Delegates to TestUnits.
--- Discovery is passive — it never triggers configure/build.
--- @return table[]|nil TestTree entries
function ConfigUnit:discover_tests()
    if self._test_tree then return self._test_tree end

    local units = self:test_units()
    if #units == 0 then return nil end

    local all_entries = {}
    for _, tu in ipairs(units) do
        local entries = tu:discover()
        if entries then
            for _, e in ipairs(entries) do
                all_entries[#all_entries + 1] = e
            end
        end
    end

    if #all_entries == 0 then return nil end
    self._test_tree = all_entries
    return self._test_tree
end

--- Discover tests asynchronously. Delegates to TestUnits.
--- @param callback fun(entries: table[]|nil)
function ConfigUnit:discover_tests_async(callback)
    if self._test_tree then
        callback(self._test_tree)
        return
    end

    local units = self:test_units()
    if #units == 0 then
        callback(nil)
        return
    end

    local all_entries = {}
    local pending = #units
    for _, tu in ipairs(units) do
        tu:discover_async(function(entries)
            if entries then
                for _, e in ipairs(entries) do
                    all_entries[#all_entries + 1] = e
                end
            end
            pending = pending - 1
            if pending == 0 then
                if #all_entries == 0 then
                    callback(nil)
                else
                    self._test_tree = all_entries
                    callback(all_entries)
                end
            end
        end)
    end
end

--- Invalidate cached test data (called after build/configure completes).
function ConfigUnit:invalidate_tests()
    self._test_tree = nil
    self._test_results = nil
    self._test_units = nil
end

--- Merge test results into the cached test tree.
--- @param results table[]|nil TestResult entries
function ConfigUnit:_apply_test_results(results)
    if not results then return end
    self._test_results = results

    if not self._test_tree then return end
    local by_id = {}
    for _, r in ipairs(results) do
        by_id[r.test_id] = r
    end
    for _, entry in ipairs(self._test_tree) do
        local r = by_id[entry.id]
        if r then
            entry.status = r.status
            entry.message = r.message
            entry.duration = r.duration
        end
    end
end

--- Find the TestUnit that owns a given test_id.
--- @param test_id string
--- @return loomworks.TestUnit|nil
function ConfigUnit:_find_test_unit(test_id)
    for _, tu in ipairs(self:test_units()) do
        local entries = tu:entries()
        if entries then
            for _, e in ipairs(entries) do
                if e.id == test_id then return tu end
            end
        end
    end
    -- Fallback: return first TestUnit
    local units = self:test_units()
    return units[1]
end

--- Run a single test. Handles the full prerequisite chain:
--- configure if needed → build if needed → run test.
--- @param test_id string test identifier from discover_tests
--- @param opts? table { strategy?: "run"|"dap", gtest_filter?: string }
--- @return loomworks.Future
function ConfigUnit:run_test(test_id, opts)
    opts = opts or {}
    local overseer_mod = require("loomworks.overseer")

    local unit = self
    return overseer_mod.run_configuration_action(self, "build"):next(function()
        return unit:_launch_test(test_id, opts)
    end)
end

--- Run all tests. Handles the full prerequisite chain.
--- @param opts? table { filter?: string, strategy?: "run"|"dap" }
--- @return loomworks.Future
function ConfigUnit:run_tests(opts)
    opts = opts or {}
    local overseer_mod = require("loomworks.overseer")

    local unit = self
    return overseer_mod.run_configuration_action(self, "build"):next(function()
        return unit:_launch_test_all(opts)
    end)
end

--- Launch a single test task via overseer (after prerequisites are met).
--- @param test_id string
--- @param opts table
--- @return loomworks.Future
function ConfigUnit:_launch_test(test_id, opts)
    local future_mod = require("loomworks.future")
    local tu = self:_find_test_unit(test_id)
    if not tu then
        return future_mod.rejected("no test unit for " .. test_id)
    end

    local test_cmd = tu:test_command(test_id, opts)
    if not test_cmd then
        return future_mod.rejected("test unit cannot build command for " .. test_id)
    end

    return self:_run_test_task(
        "test: " .. (test_id:match("^test:(.+)$") or test_id),
        test_cmd, tu
    )
end

--- Launch all tests task via overseer (after prerequisites are met).
--- @param opts table
--- @return loomworks.Future
function ConfigUnit:_launch_test_all(opts)
    local future_mod = require("loomworks.future")
    local units = self:test_units()
    if #units == 0 then
        return future_mod.rejected("no test units")
    end

    local tu = units[1]
    local test_cmd = tu:test_command_all(opts)
    if not test_cmd then
        return future_mod.rejected("test unit cannot build command")
    end

    return self:_run_test_task("test: all", test_cmd, tu)
end

--- Run a test task via overseer and parse results on completion.
--- @param name string display name for the task
--- @param test_cmd table { cmd, env, cwd, output_path }
--- @param tu loomworks.TestUnit the test unit for result parsing
--- @return loomworks.Future
function ConfigUnit:_run_test_task(name, test_cmd, tu)
    local future_mod = require("loomworks.future")
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        return future_mod.rejected("overseer.nvim not found")
    end

    local f = future_mod.Future.new()
    local unit = self
    local project_name = self._project and self._project.key or "?"

    -- Dispose previous test task
    if self._last_test_task_id then
        local prev = self._workspace._core._deps.get_overseer_task(self._last_test_task_id)
        if prev and prev:is_complete() then
            prev:dispose()
        end
    end

    local task = overseer.new_task({
        name = project_name .. ": " .. name,
        cmd = test_cmd.cmd,
        cwd = test_cmd.cwd,
        env = test_cmd.env,
        components = { "default" },
    })

    self._last_test_task_id = task.id

    task:subscribe("on_complete", function(_, status)
        vim.schedule(function()
            if test_cmd.output_path then
                local results = tu:parse_results(test_cmd.output_path)
                unit:_apply_test_results(results)
            end

            local events = unit._workspace._core._deps.events
            events.emit("test_results_changed", unit)

            if status == "SUCCESS" then
                f:_resolve(true)
            else
                f:_reject("test failed")
            end
        end)
    end)

    task:start()
    overseer.open({ enter = false })

    return f
end

return ConfigUnit
