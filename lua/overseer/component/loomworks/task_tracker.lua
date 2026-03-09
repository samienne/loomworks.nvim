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
      on_complete = function(_, _, status)
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
    }
  end,
}
