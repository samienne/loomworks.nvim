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

return M
