---@type overseer.ComponentFileDefinition
return {
  desc = "Track loomworks task completion and update cache",
  params = {
    project_key = {
      desc = "Project key in loomworks config",
      type = "string",
    },
    action = {
      desc = "Task action: configure or build",
      type = "string",
    },
    configuration_key = {
      desc = "Configuration key for cache",
      type = "string",
    },
    build_dir = {
      desc = "Build directory path",
      type = "string",
      optional = true,
    },
    cmake = {
      desc = "CMake-specific metadata",
      type = "opaque",
      optional = true,
    },
  },
  constructor = function(params)
    return {
      on_start = function(_, task)
        require("loomworks").register_running_task({
          task_id = task.id,
          project_key = params.project_key,
          action = params.action,
          configuration_key = params.configuration_key,
        })
      end,
      on_complete = function(_, task, status)
        require("loomworks").unregister_running_task(task.id)

        if status == "CANCELED" then return end

        local success = status == "SUCCESS"
        require("loomworks").record_task_result({
          project_key = params.project_key,
          action = params.action,
          configuration_key = params.configuration_key,
          build_dir = params.build_dir,
          cmake = params.cmake,
          success = success,
        })
      end,
      on_dispose = function(_, task)
        require("loomworks").unregister_running_task(task.id)
      end,
    }
  end,
}
