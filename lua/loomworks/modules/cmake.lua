local M = {}

local io_mod = require("loomworks.io")

M.id = "cmake"
M.has_keyed_tools = true
M.has_options = true

local uv = vim.uv or vim.loop

--- Wrap a command with vcvarsall.bat for MSVC Ninja builds.
--- @param cmd string[] command array
--- @param kit table|nil tool data with optional vcvarsall/arch
--- @param generator string|nil cmake generator name
--- @return string[]
--- Write a .bat file for MSVC+Ninja builds into the build directory.
--- Using a .bat file instead of inline cmd /C avoids issues with
--- Git Bash environment inheritance and quoting on Windows.
--- @param build_dir string absolute path to the build directory
--- @param vcvarsall string path to vcvarsall.bat
--- @param arch string architecture (e.g., "x64")
--- @param cmd string[] command to run after vcvarsall
--- @return string bat_path
local function write_vcvarsall_bat(build_dir, vcvarsall, arch, cmd)
    local bat_path = build_dir .. "/loomworks_build.bat"
    local f = io.open(bat_path, "w")
    if not f then return nil end
    f:write("@echo off\r\n")
    f:write('call "' .. vcvarsall:gsub("/", "\\") .. '" ' .. arch .. "\r\n")
    f:write("if errorlevel 1 exit /b 1\r\n")
    -- Quote each argument that contains spaces
    local parts = {}
    for _, c in ipairs(cmd) do
        if c:find(" ") then
            parts[#parts + 1] = '"' .. c .. '"'
        else
            parts[#parts + 1] = c
        end
    end
    f:write(table.concat(parts, " ") .. "\r\n")
    f:close()
    return bat_path
end

--- Wrap a command for MSVC+Ninja builds on Windows.
--- Uses a .bat file in the build dir to ensure clean cmd.exe environment
--- regardless of Neovim's shell setting (e.g., Git Bash).
--- On non-Windows or non-MSVC kits, returns the command unchanged.
--- @param cmd string[] command array
--- @param kit table|nil tool data with optional vcvarsall/arch
--- @param generator string|nil cmake generator name
--- @param build_dir string|nil build directory for .bat file placement
--- @return string[]
local function wrap_cmd(cmd, kit, generator, build_dir)
    if kit and kit.vcvarsall and generator == "Ninja" and build_dir then
        local bat_path = write_vcvarsall_bat(
            build_dir, kit.vcvarsall, kit.arch or "x64", cmd)
        if bat_path then
            return { "cmd", "/C", bat_path }
        end
    end
    return cmd
end

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

--- Detect whether a directory looks like a cmake project.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/CMakeLists.txt") then
        return { marker = "CMakeLists.txt" }
    end
    return nil
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

--- Return the default configurations for this module.
--- These are always available even if no presets or CMakeLists.txt detection.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, { variant: string }> name → { variant }
function M.default_configurations(path, config)
    local detected = detect_configs_from_cmakelists(path)
    local defaults = {}
    for _, name in ipairs(detected) do
        defaults[name] = { variant = name }
    end
    return defaults
end

--- Normalize inherits to an array. Accepts string, array, or nil.
--- @param inherits string|string[]|nil
--- @return string[]
local function normalize_inherits(inherits)
    if not inherits then return {} end
    if type(inherits) == "string" then return { inherits } end
    return inherits
end

--- Resolve user-defined configurations from loomworks.json, merging with
--- defaults. User configs can extend defaults (add options) or define new
--- ones with inheritance. Supports multi-inheritance (array of base names).
--- @param defaults table<string, table> default configurations
--- @param config table type_config from loomworks.json
--- @return table<string, table> merged configurations
function M.resolve_configurations(defaults, config)
    local result = {}

    -- Start with defaults
    for name, def in pairs(defaults) do
        result[name] = {
            variant = def.variant,
            is_default = true,
        }
    end

    -- Apply user overrides/additions from loomworks.json
    if config.configurations then
        for name, override in pairs(config.configurations) do
            if not result[name] then
                result[name] = {}
            end
            local cfg = result[name]

            -- Inheritance: variant from first base that has one
            local bases = normalize_inherits(override.inherits)
            if #bases > 0 then
                cfg.inherits = bases
                for _, base_name in ipairs(bases) do
                    local base = result[base_name]
                    if base and base.variant then
                        cfg.variant = base.variant
                        break
                    end
                end
            end

            -- Defaults get variant from their name; custom configs without
            -- a variant-providing base remain abstract (no variant)
            if not cfg.variant and cfg.is_default then
                cfg.variant = name
            end

            -- Toolchain/generator overrides (existing behavior)
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

            -- Options
            if override.options then
                cfg.options = override.options
            end

            -- Mark as user-defined if it's not a default being extended
            if not cfg.is_default then
                cfg.is_user = true
            end
        end
    end

    -- Ensure default configs have a variant (user configs without a
    -- variant-providing base are abstract mixins — no variant)
    for name, cfg in pairs(result) do
        if not cfg.variant and cfg.is_default then
            cfg.variant = name
        end
    end

    return result
end

--- Resolve all options for a configuration, applying merge order:
--- project-wide → inherited chain → config-specific.
--- @param config table type_config from loomworks.json
--- @param configurations table<string, table> resolved configurations
--- @param config_name string
--- @return table<string, string> merged options
function M.resolve_options(config, configurations, config_name)
    local options = {}

    -- 1. Project-wide options
    if config.options then
        for k, v in pairs(config.options) do
            options[k] = v
        end
    end

    -- 2. Walk inheritance chain (bases first, left-to-right, depth-first)
    local function apply_inherited(name, visited)
        if visited[name] then return end -- circular guard
        visited[name] = true
        local cfg = configurations[name]
        if not cfg then return end
        local bases = normalize_inherits(cfg.inherits)
        for _, base_name in ipairs(bases) do
            apply_inherited(base_name, visited)
        end
        if cfg.options then
            for k, v in pairs(cfg.options) do
                options[k] = v
            end
        end
    end

    apply_inherited(config_name, {})

    return options
end

--- Like resolve_options but tracks the source of each value.
--- @param config table type_config from loomworks.json
--- @param configurations table<string, table> resolved configurations
--- @param config_name string
--- @return table<string, { value: string, source: string }> key → { value, source }
function M.resolve_options_with_sources(config, configurations, config_name)
    local result = {}

    -- 1. Project-wide options
    if config.options then
        for k, v in pairs(config.options) do
            result[k] = { value = v, source = "project" }
        end
    end

    -- 2. Walk inheritance chain (bases first, left-to-right, depth-first)
    local function apply_inherited(name, visited)
        if visited[name] then return end
        visited[name] = true
        local cfg = configurations[name]
        if not cfg then return end
        local bases = normalize_inherits(cfg.inherits)
        for _, base_name in ipairs(bases) do
            apply_inherited(base_name, visited)
        end
        if cfg.options then
            for k, v in pairs(cfg.options) do
                result[k] = { value = v, source = name }
            end
        end
    end

    apply_inherited(config_name, {})

    return result
end

--- Find the source config that provides the variant for a configuration.
--- Walks the inheritance chain depth-first to find the first config with
--- a variant defined as a default (is_default) or explicitly set.
--- @param configurations table<string, table> resolved configurations
--- @param config_name string
--- @return string|nil source config name that provides the variant
function M.resolve_variant_source(configurations, config_name)
    local function find_source(name, visited)
        if visited[name] then return nil end
        visited[name] = true
        local cfg = configurations[name]
        if not cfg then return nil end
        -- Defaults define their own variant
        if cfg.is_default and cfg.variant then return name end
        -- Walk bases to find who provides the variant
        local bases = normalize_inherits(cfg.inherits)
        for _, base_name in ipairs(bases) do
            local source = find_source(base_name, visited)
            if source then return source end
        end
        return nil
    end
    return find_source(config_name, {})
end

--- Return what the module knows about the project from its own files.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return loomworks.ModuleInfo
function M.info(path, config)
    -- Detect preset configurations (separate from loomworks-managed)
    local preset_configurations = {}
    local presets = load_presets(path)
    if presets then
        for _, preset in ipairs(presets) do
            local has_toolchain = preset.toolchainFile ~= nil
                    or (preset.cacheVariables and preset.cacheVariables.CMAKE_TOOLCHAIN_FILE ~= nil)

            preset_configurations[preset.name] = {
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
    end

    -- Build loomworks-managed configurations: defaults + user overrides
    local defaults = M.default_configurations(path, config)
    local configurations = M.resolve_configurations(defaults, config)

    return {
        configurations = configurations,
        preset_configurations = preset_configurations,
        compile_commands_from = config.compile_commands_from,
        clangd = config.clangd,
    }
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
--- Sanitize a string for use as a directory name.
--- Replaces characters that are invalid in Windows paths (: * ? " < > |).
--- @param name string
--- @return string
local function sanitize_path_component(name)
    return name:gsub('[:<>"|?*]', "_")
end

local function resolve_build_dir(project_name, config_name, config_info, workspace_root, multi_config, kit)
    if config_info and config_info.binary_dir then
        local dir = config_info.binary_dir
        dir = dir:gsub("${sourceDir}", workspace_root)
        dir = dir:gsub("${presetName}", config_name or "")
        return dir
    end

    local base = workspace_root .. "/.nvim/build/" .. sanitize_path_component(project_name)
    local kit_suffix = kit and kit.id or nil

    if multi_config then
        -- Multi-config: one dir per kit (Debug/Release selected at build time via --config)
        return kit_suffix and (base .. "/" .. sanitize_path_component(kit_suffix)) or base
    end
    -- Single-config: one dir per config per kit
    local config_part = sanitize_path_component(config_name or "default")
    if kit_suffix then
        return base .. "/" .. sanitize_path_component(kit_suffix) .. "/" .. config_part
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
    local kit = project.tool_data
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

        -- Single-config generators support compile_commands.json generation
        if not multi_config then
            configure_cmd[#configure_cmd + 1] = "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
        end

        -- Set CMAKE_BUILD_TYPE for single-config generators from variant
        if not multi_config then
            local variant = config_info and config_info.variant or active_config
            configure_cmd[#configure_cmd + 1] = "-DCMAKE_BUILD_TYPE=" .. variant
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

    -- User-defined options (project-wide + inherited + config-specific)
    -- Appended after managed flags so user values can override.
    local type_config = project.type_config or {}
    if type_config.options or (type_config.configurations and
            type_config.configurations[active_config] and
            type_config.configurations[active_config].options) then
        local resolved_opts = M.resolve_options(
            type_config, project.configurations or {}, active_config)
        for k, v in pairs(resolved_opts) do
            configure_cmd[#configure_cmd + 1] = "-D" .. k .. "=" .. v
        end
    end

    -- Closure to wrap commands with vcvarsall for this project's kit+generator
    local function wrap(cmd)
        return wrap_cmd(cmd, kit, generator, build_dir)
    end

    -- Build the configuration key for cache tracking
    local configuration_key = project.configuration_key or active_config

    -- tool_data is stored as-is in cache (opaque to core)
    local cached_tool_data = kit

    tasks[#tasks + 1] = {
        name = project.name .. ": configure",
        builder = function()
            -- Ensure file-api query markers exist so cmake writes reply data
            local query_dir = build_dir .. "/.cmake/api/v1/query"
            vim.fn.mkdir(query_dir, "p")
            for _, marker in ipairs({ "codemodel-v2", "cache-v2" }) do
                local query_file = query_dir .. "/" .. marker
                if not uv.fs_stat(query_file) then
                    local fd = uv.fs_open(query_file, "w", 420) -- 0644
                    if fd then uv.fs_close(fd) end
                end
            end
            return {
                cmd = wrap(configure_cmd),
                cwd = abs_path,
                env = env,
            }
        end,
        loomworks = {
            project_key = project.name,
            action = "configure",
            configuration_key = configuration_key,
            build_dir = build_dir,
            tool_data = cached_tool_data,
            cmake = {
                multi_config = multi_config,
                generator = generator,
                compiler = kit and kit.compiler_id or nil,
                source_dir = project.path,
            },
        },
    }

    -- Build tasks — always build only the active configuration
    if multi_config then
        tasks[#tasks + 1] = {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = wrap({ "cmake", "--build", build_dir, "--config", active_config }),
                    cwd = abs_path,
                    env = env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
                build_dir = build_dir,
                tool_data = cached_tool_data,
            },
        }
    else
        tasks[#tasks + 1] = {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = wrap({ "cmake", "--build", build_dir }),
                    cwd = abs_path,
                    env = env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
                build_dir = build_dir,
                tool_data = cached_tool_data,
            },
        }
    end

    return tasks
end

--- Return overseer task templates for cleaning build artifacts.
--- Uses `cmake --build <dir> --target clean` which delegates to the
--- underlying build tool (ninja -t clean, make clean, etc.).
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local config_info = project.configurations and project.configurations[active_config] or nil
    local kit = project.tool_data
    local env = project.env or {}

    local generator = (config_info and config_info.generator)
            or (kit and kit.generator)
            or nil
    local multi_config = is_multi_config(generator)

    local build_dir = resolve_build_dir(project.name, active_config, config_info, project.workspace_root, multi_config, kit)
    local configuration_key = project.configuration_key or active_config

    local function wrap(cmd)
        return wrap_cmd(cmd, kit, generator, build_dir)
    end

    local clean_cmd = { "cmake", "--build", build_dir, "--target", "clean" }
    if multi_config then
        clean_cmd[#clean_cmd + 1] = "--config"
        clean_cmd[#clean_cmd + 1] = active_config
    end

    return {
        {
            name = project.name .. ": clean " .. active_config,
            builder = function()
                return {
                    cmd = wrap(clean_cmd),
                    cwd = abs_path,
                    env = env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "clean",
                configuration_key = configuration_key,
            },
        },
    }
end

--- Generate an overseer task for building a specific cmake target.
--- @param project loomworks.ModuleContext
--- @param target_id string cmake target name
--- @return table task_def overseer-compatible task definition
function M.build_target_task(project, target_id)
    local abs_path = project.workspace_root .. "/" .. project.path
    local active_config = project.configuration
    local config_info = project.configurations and project.configurations[active_config] or nil
    local kit = project.tool_data
    local env = project.env or {}

    local generator = (config_info and config_info.generator)
            or (kit and kit.generator)
            or nil
    local multi_config = is_multi_config(generator)

    local build_dir = resolve_build_dir(
        project.name, active_config, config_info, project.workspace_root, multi_config, kit)

    local cmd = { "cmake", "--build", build_dir, "--target", target_id }
    if multi_config then
        cmd[#cmd + 1] = "--config"
        cmd[#cmd + 1] = active_config
    end

    return {
        name = project.name .. ": build " .. target_id,
        builder = function()
            return {
                cmd = wrap_cmd(cmd, kit, generator, build_dir),
                cwd = abs_path,
                env = env,
            }
        end,
        loomworks = {
            project_key = project.name,
            action = "build",
            configuration_key = project.configuration_key,
            build_dir = build_dir,
            tool_data = kit,
        },
    }
end

--- Return the progress parser tool name for a project's active configuration.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return string|nil tool name for progress.get()
function M.progress_parser(project, active_config)
    local config_info = project.configurations and project.configurations[active_config] or nil
    local kit = project.tool_data
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
--- @return { tool_data: table }[]
function M.detect_tools()
    local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
    if not ok then return {} end

    local kits = cmake_kits.detect()
    local tools = {}
    for _, kit in ipairs(kits) do
        tools[#tools + 1] = {
            tool_data = {
                id = kit.id,
                display = kit.display,
                generator = kit.generator,
                compiler_id = kit.compiler_id,
                compiler_path = kit.compiler_path,
                compiler_version = kit.compiler_version,
                clangd_path = kit.clangd_path,
                vcvarsall = kit.vcvarsall,
                arch = kit.arch,
                env = kit.env and next(kit.env) and kit.env or nil,
            },
        }
    end
    return tools
end

--- Detect available tools (kits) asynchronously.
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
    if not ok then
        callback({})
        return
    end

    cmake_kits.detect_async(function(kits)
        local tools = {}
        for _, kit in ipairs(kits) do
            tools[#tools + 1] = {
                tool_data = {
                    id = kit.id,
                    display = kit.display,
                    generator = kit.generator,
                    compiler_id = kit.compiler_id,
                    compiler_path = kit.compiler_path,
                    compiler_version = kit.compiler_version,
                    clangd_path = kit.clangd_path,
                    vcvarsall = kit.vcvarsall,
                    arch = kit.arch,
                    env = kit.env and next(kit.env) and kit.env or nil,
                },
            }
        end
        callback(tools)
    end)
end

--- Map a semantic variant type to a configuration name from available configs.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil matching configuration name
function M.map_variant(variant_type, available_configs)
    if #available_configs == 1 then
        return available_configs[1]
    end

    local targets = {
        debug = { "debug" },
        release = { "release" },
        release_debug = { "relwithdebinfo" },
    }

    local candidates = targets[variant_type]
    if not candidates then return nil end

    for _, target in ipairs(candidates) do
        for _, config in ipairs(available_configs) do
            if config:lower() == target then
                return config
            end
        end
    end
    return nil
end

--- Compare two cmake tool_data objects for identity.
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    return a.compiler_path == b.compiler_path
            and a.generator == b.generator
            and (a.vcvarsall or "") == (b.vcvarsall or "")
            and (a.arch or "") == (b.arch or "")
end

--- Derive a cache key suffix from tool_data.
--- @param tool_data table
--- @return string
function M.tool_key(tool_data)
    return tool_data.id
end

--- Display label for a cmake tool.
--- @param tool_data table
--- @return string
function M.tool_label(tool_data)
    return tool_data.display
end

--- Cache entry types that are user-facing (not internal/computed).
local USER_CACHE_TYPES = {
    BOOL = "bool",
    STRING = "string",
    PATH = "path",
    FILEPATH = "filepath",
}

--- Find the file-api reply directory and locate a reply file by kind.
--- @param build_dir string
--- @param kind string e.g. "cache"
--- @param major number e.g. 2
--- @return table|nil parsed JSON data
local function find_file_api_reply(build_dir, kind, major)
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    if not uv.fs_stat(reply_dir) then return nil end

    -- Find the index file
    local index_file
    local handle = uv.fs_scandir(reply_dir)
    if not handle then return nil end
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if (ftype == "file" or ftype == nil) and name:match("^index%-.*%.json$") then
            if not index_file or name > index_file then
                index_file = name
            end
        end
    end
    if not index_file then return nil end

    local index = read_json_file(reply_dir .. "/" .. index_file)
    if not index then return nil end

    -- Search reply and objects for the requested kind
    local json_file
    if index.reply then
        for _, key in ipairs({ "stateless-query", "client-loomworks" }) do
            local responses = index.reply[key]
            if responses then
                for _, r in ipairs(responses) do
                    if r.kind == kind and r.version and r.version.major == major then
                        json_file = r.jsonFile
                        break
                    end
                end
                if json_file then break end
            end
        end
    end
    if not json_file and index.objects then
        for _, obj in ipairs(index.objects) do
            if obj.kind == kind and obj.version and obj.version.major == major then
                json_file = obj.jsonFile
                break
            end
        end
    end
    if not json_file then return nil end

    return read_json_file(reply_dir .. "/" .. json_file)
end

--- Map cmake target type strings to our normalized type names.
local TARGET_TYPE_MAP = {
    EXECUTABLE = "executable",
    STATIC_LIBRARY = "static_library",
    SHARED_LIBRARY = "shared_library",
    MODULE_LIBRARY = "module_library",
    OBJECT_LIBRARY = "object_library",
    INTERFACE_LIBRARY = "interface_library",
}

--- Parse the cmake file-api reply to extract project-owned targets.
--- @param build_dir string absolute path to the build directory
--- @param config_name? string configuration name (for multi-config generators)
--- @return table<string, loomworks.CachedTarget>|nil targets
function M.parse_file_api(build_dir, config_name)
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"

    -- Select the right configuration (first for single-config, matched for multi-config)
    local config_data
    if config_name then
        for _, cfg in ipairs(codemodel.configurations) do
            if cfg.name == config_name then
                config_data = cfg
                break
            end
        end
    end
    if not config_data then
        config_data = codemodel.configurations[1]
    end
    if not config_data or not config_data.targets then return nil end

    -- Collect project-owned target names (for filtering dependencies)
    -- Also read each target's detail file for type and dependencies
    local project_names = {}
    if config_data.projects then
        for _, proj in ipairs(config_data.projects) do
            if proj.targetIndexes then
                for _, idx in ipairs(proj.targetIndexes) do
                    local tgt = config_data.targets[idx + 1] -- 0-based → 1-based
                    if tgt then
                        project_names[tgt.name] = true
                    end
                end
            end
        end
    else
        -- Fallback: treat all targets as project-owned
        for _, tgt in ipairs(config_data.targets) do
            project_names[tgt.name] = true
        end
    end

    -- Parse each target's detail file
    local targets = {}
    for _, tgt_ref in ipairs(config_data.targets) do
        if not project_names[tgt_ref.name] then goto continue end
        if not tgt_ref.jsonFile then goto continue end

        local tgt_detail = read_json_file(reply_dir .. "/" .. tgt_ref.jsonFile)
        if not tgt_detail then goto continue end

        local target_type = TARGET_TYPE_MAP[tgt_detail.type]
        if not target_type then goto continue end -- skip UTILITY, ALIAS, etc.

        -- Extract link dependencies (only project-owned ones)
        local deps
        if tgt_detail.dependencies then
            for _, dep in ipairs(tgt_detail.dependencies) do
                if dep.id then
                    -- Resolve dependency name from the target list
                    for _, other in ipairs(config_data.targets) do
                        if other.id == dep.id and project_names[other.name] then
                            deps = deps or {}
                            deps[#deps + 1] = other.name
                            break
                        end
                    end
                end
            end
            if deps then table.sort(deps) end
        end

        -- Extract primary output artifact path, normalized to be relative to build_dir
        local artifact
        if tgt_detail.artifacts and tgt_detail.artifacts[1] then
            local raw = tgt_detail.artifacts[1].path
            if raw then
                -- cmake may emit absolute or relative paths; normalize to relative
                local normalized = raw:gsub("\\", "/")
                local build_prefix = build_dir:gsub("\\", "/"):gsub("/?$", "/")
                if normalized:sub(1, #build_prefix) == build_prefix then
                    artifact = normalized:sub(#build_prefix + 1)
                else
                    artifact = normalized
                end
            end
        end

        targets[tgt_ref.name] = {
            type = target_type,
            dependencies = deps,
            artifact = artifact,
        }

        ::continue::
    end

    return next(targets) and targets or nil
end

--- Async wrapper for parse_file_api. Yields to the event loop before
--- parsing to avoid blocking during batch scanning on init.
--- @param build_dir string
--- @param config_name? string
--- @param callback fun(targets: table<string, loomworks.CachedTarget>|nil)
function M.parse_file_api_async(build_dir, config_name, callback)
    vim.schedule(function()
        callback(M.parse_file_api(build_dir, config_name))
    end)
end

--- Collect flat options from file-api cache-v2 reply.
--- @param build_dir string
--- @return loomworks.Option[]|nil
local function collect_options_from_file_api(build_dir)
    local cache_data = find_file_api_reply(build_dir, "cache", 2)
    if not cache_data or not cache_data.entries then return nil end

    local options = {}
    for _, entry in ipairs(cache_data.entries) do
        local mapped_type = USER_CACHE_TYPES[entry.type]
        if mapped_type then
            local helpstring, choices
            if entry.properties then
                for _, prop in ipairs(entry.properties) do
                    if prop.name == "HELPSTRING" and prop.value ~= ""
                            and prop.value ~= "Value Computed by CMake" then
                        helpstring = prop.value
                    elseif prop.name == "STRINGS" and type(prop.value) == "table"
                            and #prop.value > 0 then
                        choices = prop.value
                    end
                end
            end
            options[#options + 1] = {
                key = entry.name,
                value_type = mapped_type,
                value = entry.value,
                helpstring = helpstring,
                choices = choices,
            }
        end
    end
    return #options > 0 and options or nil
end

--- Collect flat options from CMakeCache.txt (fallback, no choices support).
--- @param build_dir string
--- @return loomworks.Option[]|nil
local function collect_options_from_cache_txt(build_dir)
    local cache_path = build_dir .. "/CMakeCache.txt"
    local content = io_mod.read_file(cache_path)
    if not content then return nil end

    local options = {}
    local helpstring

    for line in content:gmatch("[^\r\n]+") do
        if line:match("^//") then
            helpstring = line:sub(3)
        elseif not line:match("^#") and not line:match("^%s*$") then
            local name, type_str, value = line:match("^([^:]+):(%u+)=(.*)")
            if name and type_str then
                local mapped_type = USER_CACHE_TYPES[type_str]
                if mapped_type then
                    options[#options + 1] = {
                        key = name,
                        value_type = mapped_type,
                        value = value,
                        helpstring = helpstring ~= "Value Computed by CMake" and helpstring or nil,
                    }
                end
                helpstring = nil
            end
        end
    end

    return #options > 0 and options or nil
end

--- Build an option tree from flat options using user-defined grouping config.
--- @param flat_options loomworks.Option[]
--- @param option_groups? table prefix → group path from loomworks.json
--- @return (loomworks.OptionGroup | loomworks.Option)[]
local function build_option_tree(flat_options, option_groups)
    -- Sort all options by key
    table.sort(flat_options, function(a, b) return a.key < b.key end)

    -- Separate CMAKE_ options from project options
    local project_opts = {}
    local cmake_opts = {}
    for _, opt in ipairs(flat_options) do
        if opt.key:match("^CMAKE_") then
            cmake_opts[#cmake_opts + 1] = opt
        else
            project_opts[#project_opts + 1] = opt
        end
    end

    local tree = {}

    if option_groups and next(option_groups) then
        -- Apply user-defined grouping: prefix → group path
        -- Build a sorted list of prefixes (longest first for greedy matching)
        local prefixes = {}
        for prefix in pairs(option_groups) do
            prefixes[#prefixes + 1] = prefix
        end
        table.sort(prefixes, function(a, b) return #a > #b end)

        -- Group project options by matching prefix
        local grouped = {} -- group_key → { path, options[] }
        local ungrouped = {}

        for _, opt in ipairs(project_opts) do
            local matched = false
            for _, prefix in ipairs(prefixes) do
                if opt.key:sub(1, #prefix) == prefix then
                    local group_key = prefix
                    if not grouped[group_key] then
                        local path = option_groups[prefix]
                        if type(path) == "string" then path = { path } end
                        grouped[group_key] = { path = path, options = {} }
                    end
                    grouped[group_key].options[#grouped[group_key].options + 1] = opt
                    matched = true
                    break
                end
            end
            if not matched then
                ungrouped[#ungrouped + 1] = opt
            end
        end

        -- Build nested groups from paths
        -- Collect all group entries, sort by path for consistent ordering
        local group_entries = {}
        for _, entry in pairs(grouped) do
            group_entries[#group_entries + 1] = entry
        end
        table.sort(group_entries, function(a, b)
            return table.concat(a.path, "/") < table.concat(b.path, "/")
        end)

        -- Insert groups into tree, creating nested structure from paths
        local function ensure_path(root, path)
            local current = root
            for _, segment in ipairs(path) do
                -- Find existing group at this level
                local found
                for _, child in ipairs(current) do
                    if child.children and child.label == segment then
                        found = child
                        break
                    end
                end
                if not found then
                    found = { label = segment, children = {} }
                    current[#current + 1] = found
                end
                current = found.children
            end
            return current
        end

        for _, entry in ipairs(group_entries) do
            local target = ensure_path(tree, entry.path)
            for _, opt in ipairs(entry.options) do
                target[#target + 1] = opt
            end
        end

        -- Add ungrouped project options
        if #ungrouped > 0 then
            local other = { label = "Other", children = ungrouped }
            tree[#tree + 1] = other
        end
    else
        -- No user grouping: project options flat (or in a single group if many)
        if #project_opts > 0 then
            tree[#tree + 1] = { label = "Project Options", children = project_opts }
        end
    end

    -- Add CMAKE_ options as a separate group
    if #cmake_opts > 0 then
        tree[#tree + 1] = { label = "CMake Options", children = cmake_opts }
    end

    return tree
end

--- Return user-facing build options as a tree of groups and options.
--- @param build_dir string absolute path to the build directory
--- @param config? table type_config from loomworks.json (cmake block)
--- @return (loomworks.OptionGroup | loomworks.Option)[]|nil
function M.get_options(build_dir, config)
    local flat = collect_options_from_file_api(build_dir)
            or collect_options_from_cache_txt(build_dir)
    if not flat then return nil end

    local option_groups = config and config.option_groups or nil
    return build_option_tree(flat, option_groups)
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
