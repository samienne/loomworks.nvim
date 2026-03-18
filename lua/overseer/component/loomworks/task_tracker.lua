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
        variant = {
            desc = "Configuration variant name",
            type = "string",
            optional = true,
        },
        tool = {
            desc = "Bundled tool reference (key, data, label, mod_type)",
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
                local lw = require("loomworks")
                local unit = lw.get_config_unit(params.project_key, params.configuration_key)
                unit:register_task(task.id, params.action)
                lw._emit("task_started", {
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
                        local lw = require("loomworks")
                        local unit = lw.get_config_unit(params.project_key, params.configuration_key)
                        unit:update_progress(task.id, update)
                        lw._emit("task_progress", {
                            task_id = task.id,
                            project_key = params.project_key,
                            action = params.action,
                            configuration_key = params.configuration_key,
                            progress = update,
                        })
                        return
                    end
                end
            end,
            on_complete = function(_, task, status)
                local lw = require("loomworks")
                local unit = lw.get_config_unit(params.project_key, params.configuration_key)

                -- Record result first (updates cache state), then unregister
                -- (clears running flag). This order ensures that when
                -- unregister fires ConfigUnit listeners, the cache already
                -- reflects the final state — so Operations see "built" rather
                -- than the stale pre-completion state.
                if status ~= "CANCELED" then
                    local success = status == "SUCCESS"
                    lw.record_task_result({
                        project_key = params.project_key,
                        action = params.action,
                        configuration_key = params.configuration_key,
                        variant = params.variant,
                        tool = params.tool,
                        build_dir = params.build_dir,
                        cmake = params.cmake,
                        success = success,
                    })
                end

                unit:unregister_task(task.id)
                lw._emit("task_stopped", {
                    task_id = task.id,
                    project_key = params.project_key,
                    configuration_key = params.configuration_key,
                })
            end,
            on_dispose = function(_, task)
                local lw = require("loomworks")
                local unit = lw.get_config_unit(params.project_key, params.configuration_key)
                unit:unregister_task(task.id)
                lw._emit("task_stopped", {
                    task_id = task.id,
                    project_key = params.project_key,
                    configuration_key = params.configuration_key,
                })
            end,
        }
    end,
}
