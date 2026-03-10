local M = {}

local io_mod = require("loomworks.io")

M.id = "cmake"

local uv = vim.uv or vim.loop

--- Read and parse a JSON file, returning nil on failure.
--- @param path string
--- @return table|nil
local function read_json_file(path)
  local data = io_mod.read_json(path)
  return data
end

--- Parse CMakePresets.json and CMakeUserPresets.json with inheritance.
--- Returns a list of configure presets with resolved fields.
--- @param project_path string absolute path to the project directory
--- @return table|nil presets
local function load_presets(project_path)
  local presets_path = project_path .. "/CMakePresets.json"
  if not uv.fs_stat(presets_path) then return nil end

  local presets_data = read_json_file(presets_path)
  if not presets_data then return nil end

  local all_configure = {}

  -- Index configure presets by name for inheritance
  local by_name = {}

  local function add_presets(data)
    if not data or not data.configurePresets then return end
    for _, preset in ipairs(data.configurePresets) do
      by_name[preset.name] = preset
      -- Only include non-hidden presets without conditions
      if not preset.hidden then
        all_configure[#all_configure + 1] = preset
      end
    end
  end

  add_presets(presets_data)

  -- Also load user presets
  local user_presets_path = project_path .. "/CMakeUserPresets.json"
  if uv.fs_stat(user_presets_path) then
    add_presets(read_json_file(user_presets_path))
  end

  --- Resolve inheritance for a preset (single level of inherits).
  --- @param preset table
  --- @return table resolved
  local function resolve(preset)
    if not preset.inherits then return preset end

    local parents = type(preset.inherits) == "string"
        and { preset.inherits }
        or preset.inherits

    -- Start from parent defaults, override with preset's own values
    local resolved = {}
    for _, parent_name in ipairs(parents) do
      local parent = by_name[parent_name]
      if parent then
        parent = resolve(parent) -- recursive resolve
        for k, v in pairs(parent) do
          if k ~= "name" and k ~= "hidden" and k ~= "inherits" then
            resolved[k] = v
          end
        end
      end
    end

    -- Preset's own values override
    for k, v in pairs(preset) do
      resolved[k] = v
    end

    return resolved
  end

  local result = {}
  for _, preset in ipairs(all_configure) do
    result[#result + 1] = resolve(preset)
  end

  return #result > 0 and result or nil
end

--- Extract configurations from CMakeLists.txt by looking for
--- CMAKE_CONFIGURATION_TYPES or common patterns.
--- @param project_path string
--- @return string[]
local function detect_configs_from_cmakelists(project_path)
  local cmakelists = project_path .. "/CMakeLists.txt"
  local content = io_mod.read_file(cmakelists)
  if not content then
    return { "Debug", "Release" }
  end

  -- Look for CMAKE_CONFIGURATION_TYPES
  local types = content:match("CMAKE_CONFIGURATION_TYPES%s+([^)]+)")
  if types then
    local configs = {}
    for config in types:gmatch("[%w]+") do
      -- Filter out CMake keywords
      if config ~= "set" and config ~= "CACHE" and config ~= "STRING" then
        configs[#configs + 1] = config
      end
    end
    if #configs > 0 then return configs end
  end

  return { "Debug", "Release" }
end

--- Check if the path+config is valid.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return loomworks.ModuleValidation
function M.validate(path, config)
  local warnings = {}

  if not uv.fs_stat(path .. "/CMakeLists.txt") then
    return { valid = false, warnings = { "CMakeLists.txt not found in " .. path } }
  end

  -- Check toolchain paths in config overrides
  if config.configurations then
    for name, cfg in pairs(config.configurations) do
      if cfg.toolchain then
        -- Absolute paths forbidden in loomworks.json
        if cfg.toolchain:match("^[A-Z]:[/\\]") or cfg.toolchain:match("^/[^$]") then
          warnings[#warnings + 1] = "configuration '" .. name .. "': absolute toolchain path is forbidden in loomworks.json"
        end
      end
    end
  end

  return { valid = true, warnings = warnings }
end

--- Return what the module knows about the project from its own files.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return loomworks.ModuleInfo
function M.info(path, config)
  local configurations = {}

  -- Try presets first
  local presets = load_presets(path)
  if presets then
    for _, preset in ipairs(presets) do
      local has_toolchain = preset.toolchainFile ~= nil
          or (preset.cacheVariables and preset.cacheVariables.CMAKE_TOOLCHAIN_FILE ~= nil)

      configurations[preset.name] = {
        generator = preset.generator,
        binary_dir = preset.binaryDir,
        toolchain_locked = has_toolchain,
        toolchain = has_toolchain
            and (preset.toolchainFile
              or (preset.cacheVariables and preset.cacheVariables.CMAKE_TOOLCHAIN_FILE))
            or nil,
        from_preset = true,
      }
    end
  else
    -- Auto-generate from CMakeLists.txt
    local detected = detect_configs_from_cmakelists(path)
    for _, name in ipairs(detected) do
      configurations[name] = {
        generator = nil, -- resolved at task time from user preference or system default
        toolchain_locked = false,
      }
    end
  end

  -- Apply overrides from loomworks.json
  if config.configurations then
    for name, override in pairs(config.configurations) do
      if not configurations[name] then
        configurations[name] = {}
      end
      local cfg = configurations[name]

      if override.toolchain then
        cfg.toolchain_locked = true
        cfg.toolchain = override.toolchain
      end
      if override.generator then
        cfg.generator = override.generator
      end
      if override.role then
        cfg.role = override.role
      end
    end
  end

  -- Targets: only available post-configure from CMake File API
  -- Look for .cmake/api/v1/reply in the build directory
  local result = {
    configurations = configurations,
    compile_commands_from = config.compile_commands_from,
  }

  return result
end

--- Known multi-config generators (one configure, multiple build --config).
local MULTI_CONFIG_GENERATORS = {
  ["Visual Studio"] = true,
  ["Ninja Multi-Config"] = true,
  ["Xcode"] = true,
}

--- Check if a generator string is multi-config.
--- @param generator string|nil
--- @return boolean
local function is_multi_config(generator)
  if not generator then return false end
  for prefix in pairs(MULTI_CONFIG_GENERATORS) do
    if generator:find(prefix, 1, true) then return true end
  end
  return false
end

--- Resolve the build directory for a project.
--- For preset-based configs, uses the preset's binaryDir.
--- Multi-config generators share one build dir per kit.
--- Single-config generators get per-config per-kit dirs.
--- @param project_name string
--- @param config_name string|nil only used for single-config
--- @param config_info loomworks.ConfigurationInfo|nil
--- @param workspace_root string
--- @param multi_config boolean
--- @param kit loomworks.CmakeKit|nil
--- @return string absolute build directory path
local function resolve_build_dir(project_name, config_name, config_info, workspace_root, multi_config, kit)
  if config_info and config_info.binary_dir then
    local dir = config_info.binary_dir
    dir = dir:gsub("${sourceDir}", workspace_root)
    dir = dir:gsub("${presetName}", config_name or "")
    return dir
  end

  local base = workspace_root .. "/.nvim/build/" .. project_name
  local kit_suffix = kit and kit.id or nil

  if multi_config then
    -- Multi-config: one dir per kit (Debug/Release selected at build time via --config)
    return kit_suffix and (base .. "/" .. kit_suffix) or base
  end
  -- Single-config: one dir per config per kit
  local config_part = config_name or "default"
  if kit_suffix then
    return base .. "/" .. kit_suffix .. "/" .. config_part
  end
  return base .. "/" .. config_part
end

--- Return overseer task templates for a project.
--- @param project loomworks.ModuleContext
--- @param active_config string active configuration name
--- @return table[] tasks
function M.tasks(project, active_config)
  local tasks = {}
  local abs_path = project.workspace_root .. "/" .. project.path
  local config_info = project.configurations and project.configurations[active_config] or nil
  local kit = project.tool
  local env = project.env or {}

  -- Resolve generator from kit or config override
  local generator = (config_info and config_info.generator)
      or (kit and kit.generator)
      or nil
  local multi_config = is_multi_config(generator)

  local build_dir = resolve_build_dir(project.name, active_config, config_info, project.workspace_root, multi_config, kit)

  -- Configure task
  local configure_cmd = { "cmake" }

  if config_info and config_info.from_preset then
    configure_cmd[#configure_cmd + 1] = "--preset"
    configure_cmd[#configure_cmd + 1] = active_config
  else
    if generator then
      configure_cmd[#configure_cmd + 1] = "-G"
      configure_cmd[#configure_cmd + 1] = generator
    end
    configure_cmd[#configure_cmd + 1] = "-S"
    configure_cmd[#configure_cmd + 1] = abs_path
    configure_cmd[#configure_cmd + 1] = "-B"
    configure_cmd[#configure_cmd + 1] = build_dir

    -- For Ninja kits with a specific compiler, set CMAKE_C/CXX_COMPILER
    if kit and kit.compiler_path and generator == "Ninja" then
      local compiler_path = kit.compiler_path
      -- Derive C compiler from C++ compiler path
      local c_path = compiler_path:gsub("clang%+%+", "clang"):gsub("g%+%+", "gcc")
      configure_cmd[#configure_cmd + 1] = "-DCMAKE_CXX_COMPILER=" .. compiler_path
      configure_cmd[#configure_cmd + 1] = "-DCMAKE_C_COMPILER=" .. c_path
    end
  end

  -- Toolchain file
  if config_info and config_info.toolchain then
    local tc = config_info.toolchain
    tc = tc:gsub("%${([^}]+)}", function(var)
      return os.getenv(var) or "${" .. var .. "}"
    end)
    configure_cmd[#configure_cmd + 1] = "-DCMAKE_TOOLCHAIN_FILE=" .. tc
  end

  -- For MSVC Ninja kits, wrap command with vcvarsall
  local wrap_vcvarsall = kit and kit.vcvarsall and generator == "Ninja"
  local function wrap_cmd(cmd)
    if wrap_vcvarsall then
      -- Call vcvarsall.bat to set up MSVC environment, then run the command
      local vcvars = kit.vcvarsall:gsub("/", "\\")
      local arch = kit.arch or "x64"
      return { "cmd", "/C", '"' .. vcvars .. '" ' .. arch .. " && " .. table.concat(cmd, " ") }
    end
    return cmd
  end

  -- Build the configuration key for cache tracking
  local configuration_key = project.configuration_key or active_config

  -- Serialize tool for cache storage (strip empty env, keep JSON-safe fields)
  local cached_tool = nil
  if kit then
    cached_tool = {
      id = kit.id,
      display = kit.display,
      generator = kit.generator,
      compiler_id = kit.compiler_id,
      compiler_path = kit.compiler_path,
      vcvarsall = kit.vcvarsall,
      arch = kit.arch,
      env = kit.env and next(kit.env) and kit.env or nil,
    }
  end

  tasks[#tasks + 1] = {
    name = project.name .. ": configure",
    builder = function()
      return {
        cmd = wrap_cmd(configure_cmd),
        cwd = abs_path,
        env = env,
      }
    end,
    loomworks = {
      project_key = project.name,
      action = "configure",
      configuration_key = configuration_key,
      build_dir = build_dir,
      tool = cached_tool,
      cmake = {
        multi_config = multi_config,
        generator = generator,
        compiler = kit and kit.compiler_id or nil,
        source_dir = project.path,
      },
    },
  }

  -- Build tasks
  if multi_config then
    local config_names = {}
    if project.configurations then
      for name, cinfo in pairs(project.configurations) do
        if not (cinfo.role == "compile_commands") then
          config_names[#config_names + 1] = name
        end
      end
    else
      config_names = { active_config }
    end
    table.sort(config_names)

    for _, config_name in ipairs(config_names) do
      -- For multi-config, the config key uses the specific variant
      local build_config_key = configuration_key
      if config_name ~= active_config then
        -- Replace variant portion if it differs from active
        local _, kit_id = require("loomworks.merge").parse_profile_key(configuration_key)
        if kit_id then
          build_config_key = config_name .. ":" .. kit_id
        else
          build_config_key = config_name
        end
      end

      tasks[#tasks + 1] = {
        name = project.name .. ": build " .. config_name,
        builder = function()
          return {
            cmd = wrap_cmd({ "cmake", "--build", build_dir, "--config", config_name }),
            cwd = abs_path,
            env = env,
          }
        end,
        loomworks = {
          project_key = project.name,
          action = "build",
          configuration_key = build_config_key,
          build_dir = build_dir,
          tool = cached_tool,
        },
      }
    end
  else
    tasks[#tasks + 1] = {
      name = project.name .. ": build " .. active_config,
      builder = function()
        return {
          cmd = wrap_cmd({ "cmake", "--build", build_dir }),
          cwd = abs_path,
          env = env,
        }
      end,
      loomworks = {
        project_key = project.name,
        action = "build",
        configuration_key = configuration_key,
        build_dir = build_dir,
        tool = cached_tool,
      },
    }
  end

  return tasks
end

--- Return the progress parser tool name for a project's active configuration.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return string|nil tool name for progress.get()
function M.progress_parser(project, active_config)
  local config_info = project.configurations and project.configurations[active_config] or nil
  local kit = project.tool
  local generator = (config_info and config_info.generator) or (kit and kit.generator) or nil

  if not generator then
    -- No generator specified — Ninja is common default, but can't be sure
    return nil
  end

  if generator:find("Ninja", 1, true) then
    return "ninja"
  end

  -- Future: "msbuild" for Visual Studio generators, "make" for Unix Makefiles
  return nil
end

--- Detect available tools (kits) for cmake projects.
--- @return loomworks.CachedTool[]
function M.detect_tools()
  local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
  if not ok then return {} end

  local kits = cmake_kits.detect()
  local tools = {}
  for _, kit in ipairs(kits) do
    tools[#tools + 1] = {
      id = kit.id,
      display = kit.display,
      generator = kit.generator,
      compiler_id = kit.compiler_id,
      compiler_path = kit.compiler_path,
      vcvarsall = kit.vcvarsall,
      arch = kit.arch,
      env = kit.env and next(kit.env) and kit.env or nil,
    }
  end
  return tools
end

--- Compare current config/files against cache.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @param cached table<string, loomworks.CachedConfig> cached configurations for this project
--- @return loomworks.ModuleInspection
function M.inspect(path, config, cached)
  local reasons = {}
  local notes = {}

  if not cached or not next(cached) then
    return { needs_refresh = false, reasons = {}, notes = { "never configured" } }
  end

  -- Check if CMakeLists.txt has been modified since last configure
  local cmakelists = path .. "/CMakeLists.txt"
  local stat = uv.fs_stat(cmakelists)
  if stat then
    for config_key, config_data in pairs(cached) do
      if type(config_data) == "table" and config_data.last_configured then
        local mtime = os.date("!%Y-%m-%dT%H:%M:%SZ", stat.mtime.sec)
        if mtime > config_data.last_configured then
          reasons[#reasons + 1] = "CMakeLists.txt modified since last configure of " .. config_key
        end
      end
    end
  end

  -- Check if presets changed
  local presets_stat = uv.fs_stat(path .. "/CMakePresets.json")
  if presets_stat then
    for config_key, config_data in pairs(cached) do
      if type(config_data) == "table" and config_data.last_configured then
        local mtime = os.date("!%Y-%m-%dT%H:%M:%SZ", presets_stat.mtime.sec)
        if mtime > config_data.last_configured then
          reasons[#reasons + 1] = "CMakePresets.json modified since last configure of " .. config_key
        end
      end
    end
  end

  return {
    needs_refresh = #reasons > 0,
    reasons = reasons,
    notes = notes,
  }
end

return M
