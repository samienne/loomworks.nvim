--- loomworks/init.lua — Public API facade.
--- Creates a singleton Core instance and delegates all calls to it.

local M = {}

M._version = "0.0.1-dev"

local Core = require("loomworks.core")
local events = require("loomworks.events")

--- The singleton core instance. Created at module load time.
--- @type loomworks.Core
local core = Core.new()

--- Auto-load mode. Default: "auto".
--- @type string|false
local auto_load_mode = "auto"

--- Task output window config (Snacks.win overrides).
--- @type table
local task_output_win = {}

--- Access the underlying core instance (for advanced use / testing).
--- @return loomworks.Core
function M._core()
    return core
end

--- Emit an event. Used by components that bypass Core (e.g. task_tracker).
--- @param event string
--- @param data any
function M._emit(event, data)
    events.emit(event, data)
end

-- ---------------------------------------------------------------------------
-- Setup & workspace
-- ---------------------------------------------------------------------------

--- Set up default keymaps.
--- @param opts? { keys?: boolean|table }
local function setup_keymaps(opts)
    if opts and opts.keys == false then return end

    local map = vim.keymap.set
    -- Workspace
    map("n", "<leader>ww", function() M.toggle() end, { desc = "Loomworks info" })
    map("n", "<leader>wb", function() M.build_target() end, { desc = "Build default target" })
    map("n", "<leader>wB", function() M.build_profile() end, { desc = "Build active profile" })
    map("n", "<leader>wr", function() M.debug_target() end, { desc = "Debug target" })
    map("n", "<leader>wR", function() M.launch_target() end, { desc = "Launch target" })
    map("n", "<leader>ws", function() M.pick_profile() end, { desc = "Select profile" })
    map("n", "<F5>", function() M.debug_target() end, { desc = "Debug target" })
    map("n", "<S-F5>", function() M.stop_target() end, { desc = "Stop launch" })
    -- Tests
    local loomtest = require("loomtest")
    map("n", "<leader>tt", function() loomtest.debug_nearest() end, { desc = "Debug nearest test" })
    map("n", "<leader>tT", function() loomtest.run_nearest() end, { desc = "Run nearest test" })
    map("n", "<leader>tf", function() loomtest.debug_file() end, { desc = "Debug file tests" })
    map("n", "<leader>tF", function() loomtest.run_file() end, { desc = "Run file tests" })
end

--- Initialize loomworks.
--- Registers keymaps and fidget integration. Workspace loading is handled
--- separately by auto_load when a file is opened, or by calling load()
--- explicitly.
--- @param opts? { root?: string, auto_load?: string|false, task_output_win?: table, keys?: boolean }
function M.setup(opts)
    if opts and opts.auto_load ~= nil then
        auto_load_mode = opts.auto_load
    end
    if opts and opts.task_output_win then
        task_output_win = opts.task_output_win
    end

    -- Configure log level
    if opts and opts.log_level then
        local log = require("loomworks.log")
        local levels = { error = log.ERROR, warn = log.WARN, info = log.INFO, debug = log.DEBUG }
        local level = levels[opts.log_level] or opts.log_level
        core._deps.log:set_level(level)
    end

    setup_keymaps(opts)

    -- Optional fidget.nvim integration for progress notifications (registers listeners, fast)
    require("loomworks.fidget").setup()

    -- Load workspace if root is specified (auto_load passes root explicitly)
    if opts and opts.root then
        core:setup(opts)
    end
end

--- Get the current auto-load mode.
--- @return string|false
function M._auto_load_mode()
    return auto_load_mode
end

--- Get the merged active configuration set.
--- @return loomworks.ActiveSet|nil
function M.get_active_configuration_set()
    return core:get_active_configuration_set()
end

--- Get the active workspace.
--- @return loomworks.Workspace|nil
function M.get_workspace()
    return core:get_workspace()
end

--- Get the last setup error (e.g., cache version mismatch).
--- @return { root: string, message: string }|nil
function M.get_setup_error()
    return core:get_setup_error()
end

--- Get the task output window config (Snacks.win overrides).
--- @return table
function M.get_task_output_win()
    return task_output_win
end

--- Register an event listener.
--- @param event string
--- @param fn function
function M.on(event, fn)
    events.on(event, fn)
end

-- ---------------------------------------------------------------------------
-- Object factories
-- ---------------------------------------------------------------------------

--- Get the active Profile object.
--- @return loomworks.Profile|nil
function M.get_active_profile()
    return core:get_active_profile()
end

--- Get all Profile objects as a dict.
--- @return table<string, loomworks.Profile>
function M.get_profiles()
    return core:get_profiles()
end

--- Get tool entries for the configuration sets UI.
--- @return table<string, loomworks.ToolEntry[]> set_name -> entries
function M.get_tool_entries()
    return core:get_tool_entries()
end

--- Get all Project objects from the active set as a dict.
--- @return table<string, loomworks.Project>
function M.get_projects()
    return core:get_projects()
end

--- Get all ConfigurationSet objects.
--- @return table<string, loomworks.ConfigurationSet>
function M.get_config_sets()
    return core:get_config_sets()
end

-- ---------------------------------------------------------------------------
-- Profile management
-- ---------------------------------------------------------------------------

--- Re-scan tools from all modules and remerge.
function M.rescan_tools()
    core:rescan_tools()
end

--- Force-reload loomworks.json from disk and remerge.
--- Use after programmatic writes to avoid waiting for file watcher.
function M.reload_config()
    core:reload_config()
end

--- Nuke the cache: delete .nvim/build/ and loomworks.cache.json, then reload.
--- Caller must confirm with the user before calling this.
--- @param root string workspace root to nuke
function M.nuke_cache(root)
    core:nuke_cache(root)
end

--- Delete user.json and reload the workspace.
--- @param root string
function M.delete_user_prefs(root)
    core:delete_user_prefs(root)
end

--- Get detected tools organized by module type.
--- @return table<string, loomworks.DetectedTool[]>
function M.get_tools_by_type()
    return core:get_tools_by_type()
end

-- ---------------------------------------------------------------------------
-- Running task tracking
-- ---------------------------------------------------------------------------

--- Check if any tasks are currently running.
--- @return boolean
function M.has_running_tasks()
    return core:has_running_tasks()
end

-- ---------------------------------------------------------------------------
-- Task results
-- ---------------------------------------------------------------------------

--- Record a task result and update the cache.
--- @param result loomworks.TaskResult
function M.record_task_result(result)
    core:record_task_result(result)
end

-- ---------------------------------------------------------------------------
-- Deletion
-- ---------------------------------------------------------------------------

--- Check if any items are currently being deleted.
--- @return boolean
function M.has_pending_deletions()
    return core:has_pending_deletions()
end

--- Wait for all pending deletions to finish, then call fn.
--- @param fn function
function M.after_deletions(fn)
    core:after_deletions(fn)
end

--- Execute a deletion plan.
--- @param plan loomworks.DeletionPlan
--- @param opts? { deactivate_profile?: loomworks.Profile }
--- @param on_done? function
function M.execute_deletion(plan, opts, on_done)
    core:execute_deletion(plan, opts, on_done)
end

--- Create an Operation for a profile action.
--- @param profile loomworks.Profile
--- @param action string
--- @param units loomworks.ConfigUnit[]
--- @param target_states table<loomworks.ConfigUnit, loomworks.ConfigUnitState>
--- @return loomworks.Operation
function M.create_operation(profile, action, units, target_states)
    return core:create_operation(profile, action, units, target_states)
end

--- Find running task IDs that match a list of project+config items.
--- @param items loomworks.DeletionItem[]
--- @return table<number, loomworks.RunningTaskInfo>
function M.find_running_tasks_for_items(items)
    return core:find_running_tasks_for_items(items)
end

--- Get orphaned cached configs (configs with state not referenced by any profile).
--- @return loomworks.OrphanedConfig[]
function M.get_orphaned_configs()
    return core:get_orphaned_configs()
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--- Find the project containing a buffer's file.
--- @param bufnr number
--- @return loomworks.Project|nil
function M.project_for_buf(bufnr)
    return core:project_for_buf(bufnr)
end

--- Get status info for the buffer's project, suitable for statusline/winbar.
--- @param bufnr? number defaults to current buffer
--- @return loomworks.BufStatus|nil
function M.buf_status(bufnr)
    bufnr = bufnr or 0
    local active_set = core:get_active_configuration_set()
    if not active_set then return nil end

    local project = core:project_for_buf(bufnr)
    if not project then return nil end

    local profile = core:get_active_profile()
    local set_name = profile and (profile._config_set_ref and profile._config_set_ref.name or profile._configuration_set_name) or nil

    local status
    if profile and project.configuration then
        local pp = profile:project(project.key)
        if pp then
            status = pp:status()
        end
    end

    return {
        profile_key = active_set.name,
        set_name = set_name,
        tool_key = project._tool and project._tool.key or nil,
        project = project.key,
        configuration = project.configuration,
        status = status,
    }
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

--- Create a new workspace (loomworks.json) at the given root.
--- @param root string workspace root directory
--- @param name? string workspace name
--- @return boolean ok, string|nil err
function M.create_workspace(root, name)
    return require("loomworks.workspace").create_workspace_config(root, name)
end

--- Open the project browser for adding projects.
function M.open_project_browser()
    local ws = core:get_workspace()
    if not ws then
        vim.notify("loomworks: no workspace loaded", vim.log.levels.WARN)
        return
    end
    require("loomworks.ui.project_browser").open(ws.root)
end

--- Open the workspace status page.
--- @param win_overrides? table Snacks.win config overrides
function M.open(win_overrides)
    require("loomworks.ui.status").open(win_overrides)
end

function M.toggle()
    require("loomworks.ui.status").toggle()
end

--- Build the active profile's default target.
--- Shows a picker if no default is set or the target is stale.
function M.build_target()
    local profile = M.get_active_profile()
    if not profile then
        vim.notify("loomworks: no active profile", vim.log.levels.WARN)
        return
    end

    local function do_build(target)
        local fidget = require("loomworks.fidget")
        local handle = fidget.start_action("Building " .. target:display_name())
        fidget.report(handle, "building...")
        target:build()
            :next(function() fidget.finish(handle, "built") end)
            :catch(function(err) fidget.fail(handle, err) end)
    end

    local launch_target = profile:default_target()

    -- Valid default target: build it
    if launch_target and launch_target:is_valid() then
        do_build(launch_target)
        return
    end

    -- Stale target: notify and show picker
    if launch_target and not launch_target:is_valid() then
        vim.notify("loomworks: target '" .. launch_target:display_name()
            .. "' no longer available", vim.log.levels.WARN)
        profile:clear_default_target()
    end

    -- No default or stale: show picker
    M._pick_target(profile, function(project, target_id)
        if project and target_id then
            profile:set_default_target(project, target_id)
            local new_target = profile:default_target()
            if new_target then do_build(new_target) end
        end
    end)
end

--- Build the full active profile (all targets).
function M.build_profile()
    local profile = M.get_active_profile()
    if not profile then
        vim.notify("loomworks: no active profile", vim.log.levels.WARN)
        return
    end
    profile:build()
end

--- Show a picker for selecting the active profile.
--- Lists all profiles with status, marks the active one.
--- Includes "None" to deactivate when a profile is active.
function M.pick_profile()
    local all = M.get_profiles()
    if not all or not next(all) then
        vim.notify("loomworks: no profiles available", vim.log.levels.WARN)
        return
    end

    local active = M.get_active_profile()

    -- Sort profiles alphabetically
    local sorted = {}
    for _, profile in pairs(all) do
        sorted[#sorted + 1] = profile
    end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    -- Build picker items
    local items = {}
    for _, profile in ipairs(sorted) do
        local status_label = profile:status()
        local marker = profile == active and "● " or "  "
        items[#items + 1] = {
            label = marker .. profile.key .. " (" .. status_label .. ")",
            profile = profile,
        }
    end

    -- Add "None" option if a profile is active
    if active then
        items[#items + 1] = {
            label = "  None (deactivate)",
            profile = nil,
        }
    end

    vim.ui.select(items, {
        prompt = "Select profile:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end
        if choice.profile then
            choice.profile:activate()
        elseif active then
            active:deactivate()
        end
    end)
end

--- Show a picker for selecting a default target from the active profile.
--- Includes "None" to clear and optionally "Default: X" if loomworks.json
--- defines a default that the user has overridden.
--- @param profile loomworks.Profile
--- @param on_select fun(project: loomworks.Project|nil, target_id: string|nil)
function M._pick_target(profile, on_select)
    local ws = M.get_workspace()
    local items = {}

    -- "None" option to clear the default target
    items[#items + 1] = {
        label = "None (clear target)",
        action = "clear",
    }

    -- "Default" option if the profile's config defines a default and user has overridden
    if ws then
        local user_has_override = profile:has_default_target_override()
        local config_default = nil -- default targets from shared config (not supported after pinned removal)
        if user_has_override and config_default then
            items[#items + 1] = {
                label = "Default (" .. config_default.project .. ": " .. config_default.target .. ")",
                action = "reset_to_default",
            }
        end
    end

    -- Collect launch configs from loomworks.json projects
    if ws then
        for _, pp in ipairs(profile:projects()) do
            local project = pp._project
            if not project then goto next_pp end
            if project.launch then
                for launch_name, _ in pairs(project.launch) do
                    items[#items + 1] = {
                        label = project.key .. " [launch: " .. launch_name .. "]",
                        project = project,
                        launch_name = launch_name,
                        action = "launch",
                    }
                end
            end
            ::next_pp::
        end
    end

    -- Collect executable targets from all projects in the profile
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        if unit and unit.targets then
            local project = pp._project
            if project then
                for target_id, target in pairs(unit.targets) do
                    if target:is_executable() then
                        items[#items + 1] = {
                            label = project.key .. ": " .. target:display_name(),
                            project = project,
                            target_id = target_id,
                            action = "select",
                        }
                    end
                end
            end
        end
    end

    vim.ui.select(items, {
        prompt = "Select default target:",
        format_item = function(item) return item.label end,
    }, function(choice)
        if not choice then return end -- cancelled
        if choice.action == "clear" then
            profile:clear_default_target()
        elseif choice.action == "reset_to_default" then
            profile:clear_default_target()
        elseif choice.action == "launch" then
            profile:set_default_target(choice.project, nil, choice.launch_name)
            on_select(nil, nil) -- signal that default was set, trigger re-resolve
        elseif choice.action == "select" then
            on_select(choice.project, choice.target_id)
        end
    end)
end

--- Resolve the default target and start a run via session_tracker.
--- @param mode "launch"|"debug"
local function resolve_and_start(mode)
    local profile = M.get_active_profile()
    if not profile then
        vim.notify("loomworks: no active profile", vim.log.levels.WARN)
        return
    end

    local tracker = require("loomworks.session_tracker")
    local launch_target = profile:default_target()

    if launch_target and launch_target:is_valid() and launch_target:is_launchable() then
        tracker.start(launch_target, mode)
        return
    end

    -- Stale target
    if launch_target and not launch_target:is_valid() then
        vim.notify("loomworks: target '" .. launch_target:display_name()
            .. "' no longer available", vim.log.levels.WARN)
        profile:clear_default_target()
    end

    -- No default or stale: show picker, then start the selection
    M._pick_target(profile, function(project, target_id)
        if project and target_id then
            profile:set_default_target(project, target_id)
        end
        local new_target = profile:default_target()
        if new_target and new_target:is_launchable() then
            tracker.start(new_target, mode)
        end
    end)
end

function M.launch_target()
    resolve_and_start("launch")
end

function M.debug_target()
    resolve_and_start("debug")
end

--- Stop the active launch or debug session.
function M.stop_target()
    require("loomworks.session_tracker").stop()
end

return M
