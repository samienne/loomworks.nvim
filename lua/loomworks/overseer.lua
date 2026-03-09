local M = {}

--- Register loomworks as an overseer template provider.
--- Generates tasks dynamically from the active configuration set.
--- Task completion tracking is handled by the file-based overseer component
--- at lua/overseer/component/loomworks/task_tracker.lua
function M.register()
  local ok, overseer = pcall(require, "overseer")
  if not ok then
    vim.notify("loomworks: overseer.nvim not found, task integration disabled", vim.log.levels.WARN)
    return
  end

  local modules = require("loomworks.modules")

  overseer.register_template({
    name = "loomworks",
    generator = function(search_opts, callback)
      local loomworks = require("loomworks")
      local ws = loomworks.get_workspace()
      if not ws then
        callback({})
        return
      end

      local active_set = loomworks.get_active_configuration_set()
      if not active_set then
        callback({})
        return
      end

      local templates = {}

      local projects = loomworks.get_projects()
      for key, proj in pairs(projects) do
        if proj.orphaned then goto continue end

        local mod = modules.get(proj.type)
        if not mod or not mod.tasks then goto continue end

        local active_config = proj.configuration
        if not active_config then goto continue end

        local project_ctx = proj:to_module_context(ws.root)

        local mod_tasks = mod.tasks(project_ctx, active_config)
        for _, task in ipairs(mod_tasks) do
          -- Wrap builder to inject the tracker component
          local lw_meta = task.loomworks
          if lw_meta then
            local original_builder = task.builder
            task.builder = function(params)
              local result = original_builder(params)
              -- Add tracker component
              result.components = result.components or { "default" }
              result.components[#result.components + 1] = {
                "loomworks.task_tracker",
                project_key = lw_meta.project_key,
                action = lw_meta.action,
                configuration_key = lw_meta.configuration_key,
                build_dir = lw_meta.build_dir,
                cmake = lw_meta.cmake,
              }
              return result
            end
            task.loomworks = nil -- clean up, not needed by overseer
          end

          templates[#templates + 1] = task
        end

        ::continue::
      end

      callback(templates)
    end,
    condition = {
      callback = function()
        local loomworks = require("loomworks")
        return loomworks.get_workspace() ~= nil
      end,
    },
  })
end

--- Collect task definitions for a profile, grouped by action.
--- Does not change the active profile.
--- @param profile_key string
--- @return table|nil task_defs_by_action { configure = {...}, build = {...} }
local function collect_profile_tasks(profile_key)
  local loomworks = require("loomworks")
  local modules = require("loomworks.modules")
  local merge = require("loomworks.merge")

  local ws = loomworks.get_workspace()
  if not ws then return nil end

  local projects = merge.resolve_profile_projects(ws, profile_key)
  if not projects then return nil end

  local by_action = { configure = {}, build = {} }

  for key, proj in pairs(projects) do
    local mod = modules.get(proj.type)
    if not mod or not mod.tasks then goto continue end

    local active_config = proj.configuration
    if not active_config then goto continue end

    local project_ctx = {
      name = key,
      path = proj.path or key,
      type = proj.type,
      configuration = active_config,
      configuration_key = proj.configuration_key,
      configurations = proj.configurations,
      kit = proj.kit,
      workspace_root = ws.root,
      env = proj.kit and proj.kit.env or {},
    }

    local mod_tasks = mod.tasks(project_ctx, active_config)
    for _, task_def in ipairs(mod_tasks) do
      local lw_meta = task_def.loomworks
      if lw_meta and by_action[lw_meta.action] then
        by_action[lw_meta.action][#by_action[lw_meta.action] + 1] = task_def
      end
    end

    ::continue::
  end

  return by_action
end

--- Launch a list of task definitions via overseer.
--- @param overseer table overseer module
--- @param task_defs table[] task definitions with .builder and .loomworks
--- @param on_all_done? function called when all launched tasks complete, with boolean all_succeeded
--- @return number launched count of tasks started
local function launch_tasks(overseer, task_defs, on_all_done)
  local launched = 0
  local remaining = 0
  local all_ok = true

  for _, task_def in ipairs(task_defs) do
    local lw_meta = task_def.loomworks
    if not lw_meta then goto next_task end

    local build_result = task_def.builder()
    build_result.components = build_result.components or { "default" }
    build_result.components[#build_result.components + 1] = {
      "loomworks.task_tracker",
      project_key = lw_meta.project_key,
      action = lw_meta.action,
      configuration_key = lw_meta.configuration_key,
      build_dir = lw_meta.build_dir,
      cmake = lw_meta.cmake,
    }

    build_result.name = task_def.name
    local task = overseer.new_task(build_result)

    if on_all_done then
      remaining = remaining + 1
      task:subscribe("on_complete", function(_, status)
        if status ~= "SUCCESS" then all_ok = false end
        remaining = remaining - 1
        if remaining == 0 then
          vim.schedule(function() on_all_done(all_ok) end)
        end
      end)
    end

    task:start()
    launched = launched + 1

    ::next_task::
  end

  -- If nothing was launched but callback expected, fire it immediately
  if launched == 0 and on_all_done then
    vim.schedule(function() on_all_done(true) end)
  end

  return launched
end

--- Check which projects in the active set need configuring.
--- @return table[] task_defs configure tasks for unconfigured projects only
local function filter_unconfigured_tasks(all_tasks)
  local loomworks = require("loomworks")
  local ws = loomworks.get_workspace()
  if not ws then return all_tasks.configure end

  local needs_configure = {}
  for _, task_def in ipairs(all_tasks.configure) do
    local lw_meta = task_def.loomworks
    if not lw_meta then goto next end

    -- Check if this project+config is already configured
    local cached_proj = ws.cache.projects and ws.cache.projects[lw_meta.project_key]
    local cached_config = cached_proj
        and cached_proj.configurations
        and cached_proj.configurations[lw_meta.configuration_key]
    local state = cached_config and cached_config.state

    if not state or state == "unconfigured" or state == "failed_configure" then
      needs_configure[#needs_configure + 1] = task_def
    end

    ::next::
  end

  return needs_configure
end

--- Run all tasks of a given action for a profile.
--- Activates the profile first, then launches overseer tasks.
--- If building and some projects are unconfigured, configures them first.
--- @param profile_key string
--- @param action string "configure" or "build"
function M.run_profile_action(profile_key, action)
  local ok, overseer = pcall(require, "overseer")
  if not ok then
    vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
    return
  end

  local loomworks = require("loomworks")

  local function do_action()
    -- Re-collect tasks after potential deletion completed (cache may have changed)
    local all_tasks = collect_profile_tasks(profile_key)
    if not all_tasks then return end

    if action == "configure" then
      local launched = launch_tasks(overseer, all_tasks.configure)
      if launched == 0 then
        vim.notify("loomworks: no configure tasks found for profile", vim.log.levels.WARN)
      end
      return
    end

    if action == "build" then
      local needs_configure = filter_unconfigured_tasks(all_tasks)

      if #needs_configure > 0 then
        vim.notify("loomworks: configuring " .. #needs_configure .. " project(s) before build", vim.log.levels.INFO)
        launch_tasks(overseer, needs_configure, function(all_succeeded)
          if not all_succeeded then
            vim.notify("loomworks: configure failed, skipping build", vim.log.levels.ERROR)
            return
          end
          local build_launched = launch_tasks(overseer, all_tasks.build)
          if build_launched == 0 then
            vim.notify("loomworks: no build tasks found for profile", vim.log.levels.WARN)
          end
        end)
      else
        local launched = launch_tasks(overseer, all_tasks.build)
        if launched == 0 then
          vim.notify("loomworks: no build tasks found for profile", vim.log.levels.WARN)
        end
      end
      return
    end

    vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
  end

  -- Wait for pending deletions before starting
  if loomworks.has_pending_deletions() then
    vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
    loomworks.after_deletions(do_action)
  else
    do_action()
  end
end

return M
