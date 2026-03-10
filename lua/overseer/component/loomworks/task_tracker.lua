---@type overseer.ComponentFileDefinition
return {
  desc = "Track loomworks task completion, cache updates, and build progress",
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
    tool = {
      desc = "Tool used for this task (cached for profile materialization)",
      type = "opaque",
      optional = true,
    },
    cmake = {
      desc = "CMake-specific metadata",
      type = "opaque",
      optional = true,
    },
    progress_tool = {
      desc = "Progress parser tool name (e.g. 'ninja')",
      type = "string",
      optional = true,
    },
  },
  constructor = function(params)
    local progress_parser = nil

    return {
      on_start = function(_, task)
        require("loomworks").register_running_task({
          task_id = task.id,
          project_key = params.project_key,
          action = params.action,
          configuration_key = params.configuration_key,
        })

        -- Resolve progress parser on start (lazy-load)
        if params.progress_tool then
          local progress = require("loomworks.progress")
          progress_parser = progress.get(params.progress_tool)
        end
      end,
      on_output_lines = function(_, task, lines)
        if not progress_parser then return end
        for i = #lines, 1, -1 do
          local update = progress_parser(lines[i])
          if update then
            require("loomworks").update_task_progress(task.id, update)
            return
          end
        end
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
          tool = params.tool,
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
