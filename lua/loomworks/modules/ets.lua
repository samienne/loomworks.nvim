local M = {}

M.id = "ets"

local uv = vim.uv or vim.loop

--- Check if the path+config is valid.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
  local warnings = {}

  if not uv.fs_stat(path .. "/build-profile.json5") then
    warnings[#warnings + 1] = "build-profile.json5 not found in " .. path
  end

  if not uv.fs_stat(path .. "/oh-package.json5") then
    warnings[#warnings + 1] = "oh-package.json5 not found in " .. path
  end

  return { valid = true, warnings = warnings }
end

--- Return what the module knows about the project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
  -- Shim: report basic configurations if specified in loomworks.json
  local configurations = {}

  if config.configurations then
    for name, cfg in pairs(config.configurations) do
      configurations[name] = cfg
    end
  else
    -- Default ETS configurations
    configurations["debug"] = {}
    configurations["release"] = {}
  end

  return { configurations = configurations }
end

function M.detect_tools()
  return {}
end

function M.tasks(project, active_config)
  return {}
end

function M.inspect(path, config, cached)
  return { needs_refresh = false, reasons = {}, notes = {} }
end

return M
