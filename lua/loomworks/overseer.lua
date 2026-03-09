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

      for key, proj in pairs(active_set.projects) do
        if proj.orphaned then goto continue end

        local mod = modules.get(proj.type)
        if not mod or not mod.tasks then goto continue end

        local active_config = proj.configuration
        if not active_config then goto continue end

        -- Build project context for the module's tasks() function
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

--- Run all tasks of a given action for a profile.
--- Activates the profile first, then launches overseer tasks.
--- @param profile_key string
--- @param action string "configure" or "build"
function M.run_profile_action(profile_key, action)
  local ok, overseer = pcall(require, "overseer")
  if not ok then
    vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
    return
  end

  local loomworks = require("loomworks")
  local modules = require("loomworks.modules")
  local merge = require("loomworks.merge")

  -- Activate the profile
  loomworks.activate_profile(profile_key)

  local ws = loomworks.get_workspace()
  if not ws then return end

  local active_set = loomworks.get_active_configuration_set()
  if not active_set then return end

  local launched = 0

  for key, proj in pairs(active_set.projects) do
    if proj.orphaned then goto continue end

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
      if not lw_meta or lw_meta.action ~= action then goto next_task end

      local build_result = task_def.builder()
      -- Inject tracker component
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
      task:start()
      launched = launched + 1

      ::next_task::
    end

    ::continue::
  end

  if launched == 0 then
    vim.notify("loomworks: no " .. action .. " tasks found for profile", vim.log.levels.WARN)
  end
end

return M
