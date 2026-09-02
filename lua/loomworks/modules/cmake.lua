local M = {}

local io_mod = require("loomworks.io")
local reserved_compiler = require("loomworks.reserved_compiler")

--- Filter reserved compiler-driver vars out of a task env. The profile's
--- tool owns the compiler (spec §15 / cmake.md §5b); a hand-edited config/env
--- carrying CC/CXX/… is dropped so the tool's compiler always wins. Returns a
--- fresh env table plus the sorted list of stripped names (for a diagnostic).
--- @param env table<string, string>|nil
--- @return table<string, string> filtered, string[] stripped
local function strip_reserved_env(env)
    local filtered = {}
    local stripped = {}
    for k, v in pairs(env or {}) do
        if reserved_compiler.is_reserved_env(k) then
            stripped[#stripped + 1] = k
        else
            filtered[k] = v
        end
    end
    table.sort(stripped)
    return filtered, stripped
end

M.id = "cmake"
M.api_version = 1
M.has_keyed_tools = true
M.has_options = true
-- CMake's default `project(name)` call enables both C and CXX, so
-- almost every cmake project's compileGroups carry "c" plus "c++"
-- even when no `.c` files exist. Declare both as the static default
-- so configurations and SDK-derived kits don't trip the
-- "build also uses c" diagnostic for the empty-LANGUAGES case.
-- Projects that override `Configuration.languages` (e.g. drop "c"
-- when they explicitly `project(... LANGUAGES CXX)`) still win.
M.languages = { "c", "c++" }

local uv = vim.uv or vim.loop

--- Deterministic 32-bit hash of a command's joined argv (pure Lua djb2).
--- Used to give each wrapped command its own .bat filename. Arithmetic
--- only (no bitwise ops) so it runs identically under Neovim's LuaJIT and
--- the standalone CLI, without `vim.fn.sha256` or the `bit` library. The
--- product stays well under 2^53, so double precision holds it exactly.
--- @param cmd string[]
--- @return string hex 8-char hash
local function hash_argv(cmd)
    local s = table.concat(cmd, "\0")
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967291
    end
    return string.format("%08x", h)
end

--- Write a .bat file for MSVC+Ninja builds into the build directory.
--- Using a .bat file instead of inline cmd /C avoids issues with
--- Git Bash environment inheritance and quoting on Windows.
--- The filename is `loomworks_<tag>_<hash>.bat`, where <tag> is a caller
--- supplied action label (configure/build/clean) and <hash> is a content
--- hash of the command's argv. INVARIANT: two distinct wrapped commands
--- never share a bat filename. Both task builders (configure + build) are
--- materialized before any task runs, and build_target_task wraps a
--- `--target` build into the SAME build_dir as the plain build — so a
--- fixed name (or a tag-only name) would let one command's .bat clobber
--- another's, and the configure task would end up executing the build
--- command ("could not load cache"). The content hash makes the name a
--- pure function of the command, so distinct commands stay distinct even
--- when their tags coincide.
--- @param build_dir string absolute path to the build directory
--- @param vcvarsall string path to vcvarsall.bat
--- @param arch string architecture (e.g., "x64")
--- @param cmd string[] command to run after vcvarsall
--- @param tag string|nil short action label for the filename (e.g. "build")
--- @return string bat_path
local function write_vcvarsall_bat(build_dir, vcvarsall, arch, cmd, tag)
    -- Sanitize inline (sanitize_path_component is defined further down);
    -- tags are literals today, but keep the name filesystem-safe anyway.
    local safe_tag = (tag or "cmd"):gsub("[^%w_%-]", "_")
    local bat_path = build_dir
        .. "/loomworks_" .. safe_tag .. "_" .. hash_argv(cmd) .. ".bat"
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
--- @param tag string|nil short action label for the .bat filename
--- @return string[]
local function wrap_cmd(cmd, kit, generator, build_dir, tag)
    if kit and kit.vcvarsall and generator == "Ninja" and build_dir then
        local bat_path = write_vcvarsall_bat(
            build_dir, kit.vcvarsall, kit.arch or "x64", cmd, tag)
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

--- Read a single preset `cacheVariables` entry as a string, tolerating both
--- CMakePresets forms: a bare string, or an object `{ type = "STRING",
--- value = "…" }` (the form CMake's own GUI and templates emit). Returns nil
--- when the key is absent or its value is not a usable string.
--- @param cache_vars table|nil  a preset's `cacheVariables`
--- @param key string
--- @return string|nil
local function cache_var(cache_vars, key)
    local v = cache_vars and cache_vars[key]
    if type(v) == "table" then v = v.value end
    if type(v) == "string" then return v end
    return nil
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

    -- Warn (non-blocking) when a configuration inherits from a preset. A
    -- preset is a self-contained unit invoked via `cmake --preset`; an
    -- inheriting config is built through the manual `-G/-S/-B/-D...` path
    -- (from_preset = false), so it silently drops the preset's cacheVariables
    -- and binaryDir. Only the canonical `preset:<name>` inherits form resolves
    -- to a preset (get_configuration matches on the canonical name), so that
    -- is the only form worth catching.
    if config.configurations then
        local presets = load_presets(path)
        if presets and next(presets) then
            local Configuration = require("loomworks.configuration")
            local preset_names = {}
            for _, p in ipairs(presets) do preset_names[p.name] = true end
            for name, cfg in pairs(config.configurations) do
                local inherits = cfg.inherits
                if type(inherits) == "string" then inherits = { inherits } end
                if type(inherits) == "table" then
                    for _, base in ipairs(inherits) do
                        local prefix, base_name = Configuration.split_canonical(base)
                        if prefix == "preset" and preset_names[base_name] then
                            warnings[#warnings + 1] = "configuration '" .. name
                                .. "': inherits from preset '" .. base_name
                                .. "'; presets are self-contained and the "
                                .. "inheriting configuration drops the preset's "
                                .. "cacheVariables/binaryDir. Add a derived preset "
                                .. "in CMakeUserPresets.json, or inherit from a "
                                .. "variant:* configuration instead."
                        end
                    end
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
        -- All cmake built-in variants go under the `variant:` tier —
        -- Debug, Release, RelWithDebInfo, MinSizeRel. Custom configs
        -- declared with `CMAKE_CONFIGURATION_TYPES` in CMakeLists.txt
        -- also end up here.
        defaults[name] = { prefix = "variant", variant = name }
    end
    return defaults
end

--- Module-level prefix for cmake's compile-mode built-in variants
--- (matches meson; used by callers that go through
--- `default_configurations` directly).
M.default_config_prefix = "variant"

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
    local Configuration = require("loomworks.configuration")
    local result = Configuration.canonicalize(
        defaults, config and config.configurations, M.id)

    -- Second pass: propagate variant/toolchain/generator from the
    -- first base in a user config's `inherits` chain that supplies
    -- each field. Keeps user configs like
    --   { inherits = "variant:Debug", options = {...} }
    -- concrete after the canonicalise step turns their base into
    -- the prefixed form.
    for _, cfg in pairs(result) do
        if cfg.inherits and type(cfg.inherits) == "string" then
            cfg.inherits = { cfg.inherits }
        end
        if cfg.is_user and cfg.inherits then
            for _, base_name in ipairs(cfg.inherits) do
                local base = result[base_name]
                if base then
                    -- Values taken from a base are marked derived so they are
                    -- not serialized as if declared here
                    -- (Configuration._derived).
                    if not cfg.variant and base.variant then
                        cfg.variant = base.variant
                        cfg._derived = cfg._derived or {}
                        cfg._derived.variant = true
                    end
                    if not cfg.toolchain and base.toolchain then
                        cfg.toolchain = base.toolchain
                        cfg.toolchain_locked = base.toolchain_locked
                        cfg._derived = cfg._derived or {}
                        cfg._derived.toolchain = true
                        cfg._derived.toolchain_locked = true
                    end
                    if not cfg.generator and base.generator then
                        cfg.generator = base.generator
                        cfg._derived = cfg._derived or {}
                        cfg._derived.generator = true
                    end
                end
            end
        end
        -- User overrides that declare their own toolchain lock it in
        if cfg.toolchain and cfg.toolchain_locked == nil then
            cfg.toolchain_locked = true
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

--- Whether a cmake generator emits `compile_commands.json` on its own.
--- Only the Ninja and Makefile generators do; Visual Studio and Xcode
--- never do (§12). Matches cmake's own generator naming case-sensitively.
--- A nil / unknown generator is treated as non-emitting-unknown by the
--- caller, never as emitting.
--- @param generator string|nil
--- @return boolean
function M.generator_emits_compile_commands(generator)
    if type(generator) ~= "string" then return false end
    return generator:find("Ninja", 1, true) ~= nil
        or generator:find("Makefiles", 1, true) ~= nil
end

--- Default value of a configuration's `compile_commands_generated` flag
--- for a given (possibly nil) generator. `true` means loomworks must
--- reconstruct compile_commands.json itself. An unknown generator yields
--- `false` — we never generate blindly when we can't confirm the
--- generator doesn't emit the database on its own.
--- @param generator string|nil
--- @return boolean
local function compile_commands_generated_default(generator)
    if type(generator) ~= "string" or generator == "" then return false end
    return not M.generator_emits_compile_commands(generator)
end

--- Return what the module knows about the project from its own files.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return loomworks.ModuleInfo
function M.info(path, config)
    local Configuration = require("loomworks.configuration")
    -- Detect preset configurations — these become canonical
    -- `preset:<name>` entries in the configuration registry.
    local preset_configurations = {}
    local presets = load_presets(path)
    if presets then
        for _, preset in ipairs(presets) do
            -- cacheVariables entries may be strings or `{type,value}` objects —
            -- read every one through cache_var so a table never reaches a string
            -- op downstream (variant → --config / module_config, toolchain → gsub).
            local toolchain = preset.toolchainFile
                    or cache_var(preset.cacheVariables, "CMAKE_TOOLCHAIN_FILE")

            local canonical = Configuration.canonical("preset", preset.name)
            preset_configurations[canonical] = {
                prefix = "preset",
                base_name = preset.name,
                -- A single-config preset's build type IS its variant. Other
                -- cacheVariables are applied by cmake itself via `--preset` —
                -- we never re-pass them. nil when absent (multi-config presets
                -- select their variant at build time; don't guess one).
                variant = cache_var(preset.cacheVariables, "CMAKE_BUILD_TYPE"),
                generator = preset.generator,
                binary_dir = preset.binaryDir,
                toolchain_locked = toolchain ~= nil,
                toolchain = toolchain,
                from_preset = true,
                is_default = true,  -- auto-gens from CMakePresets.json
            }
        end
    end

    -- Build loomworks-managed configurations: defaults + user overrides
    local defaults = M.default_configurations(path, config)
    local configurations = M.resolve_configurations(defaults, config)

    -- Stamp each configuration with the default `compile_commands_generated`
    -- flag (§12), computed from whatever generator the configuration itself
    -- knows about (a user/preset override). Plain `variant:*` configs get
    -- their generator from the profile's kit at build time, so their
    -- info-time default is false; lsp_configs recomputes the effective flag
    -- from the active kit's generator. The flag is module-specific data —
    -- it lands in the Configuration's `module_config`.
    for _, cfg in pairs(configurations) do
        cfg.compile_commands_generated =
            compile_commands_generated_default(cfg.generator)
    end
    for _, cfg in pairs(preset_configurations) do
        cfg.compile_commands_generated =
            compile_commands_generated_default(cfg.generator)
    end

    local module_info = nil
    if config.compile_commands_from or config.clangd then
        module_info = {
            compile_commands_from = config.compile_commands_from,
            clangd = config.clangd,
        }
    end
    return {
        configurations = configurations,
        preset_configurations = preset_configurations,
        module_info = module_info,
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

--- Resolve the `--config <variant>` value for a multi-config build / clean /
--- target invocation, or nil when none should be passed. Never returns a
--- canonical `preset:<name>`: a preset with no mined CMAKE_BUILD_TYPE has no
--- single variant to select for a multi-config generator, so we omit `--config`
--- and let cmake build the generator's default configuration.
--- KNOWN LIMITATION: choosing a variant for a multi-config preset that declares
--- no build type is not solved here.
--- @param config_info table|nil
--- @param active_config string
--- @return string|nil
local function multi_config_variant(config_info, active_config)
    if config_info and config_info.from_preset and not config_info.variant then
        return nil
    end
    return (config_info and config_info.variant) or active_config
end

--- Sanitize a string for use as a directory name.
--- Replaces characters that are invalid in Windows paths (: * ? " < > |).
--- Note: this function is NOT injective — "a:b" and "a_b" produce the same
--- output. Input validation (project keys, config names) prevents collisions
--- by rejecting names that would sanitize identically.
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
    -- Build-dir segment: when more than one tool is in the effective
    -- set (multi-language profile), use the sorted joined keys so a
    -- profile with different rust+cmake combos doesn't collide. With
    -- a single tool, fall back to the kit id — identical to the
    -- legacy single-tool naming so existing cache entries still hit.
    local kit_suffix = nil
    if kit then
        if kit._effective_keys and #kit._effective_keys > 1 then
            kit_suffix = table.concat(kit._effective_keys, "+")
        elseif kit.id then
            kit_suffix = kit.id
        end
    end

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

--- Compute the expected build directory for a project configuration.
--- Public interface for external code (ConfigUnit build_dir resolution).
--- @param project_name string project key
--- @param config_name string|nil configuration name
--- @param config_info loomworks.ConfigurationInfo|nil
--- @param workspace_root string absolute workspace root path
--- @param tool_data table|nil module-specific tool data (cmake kit)
--- @return string absolute build directory path
function M.resolve_build_dir(project_name, config_name, config_info, workspace_root, tool_data)
    local generator = (config_info and config_info.generator)
            or (tool_data and tool_data.generator)
            or nil
    local multi_config = is_multi_config(generator)
    return resolve_build_dir(project_name, config_name, config_info, workspace_root, multi_config, tool_data)
end

--- Return overseer task templates for a project.
--- @param project loomworks.ModuleContext
--- @param active_config string active configuration name
--- @return table[] tasks
function M.tasks(project, active_config)
    local tasks = {}
    local abs_path = project.workspace_root .. "/" .. project.path
    local config_info = project.configurations and project.configurations[active_config] or nil
    local from_preset = config_info and config_info.from_preset or false
    local kit = project.tool_data
    local env, stripped_env = strip_reserved_env(project.env)

    -- Resolve generator from kit or config override
    local generator = (config_info and config_info.generator)
            or (kit and kit.generator)
            or nil

    -- Generator is required — no fallback to platform default
    if not generator and not from_preset then
        error("cmake: no generator specified for " .. project.name .. "/" .. active_config
            .. ". Select a tool/SDK with a generator in the profile.")
    end

    -- A preset configures into cmake's own binaryDir; loomworks builds
    -- `<build_dir>` separately and must know that path. If the preset omits
    -- binaryDir we can't know where cmake configured, so refuse rather than
    -- build a mismatched, unconfigured directory.
    if from_preset and not (config_info and config_info.binary_dir) then
        error("cmake: preset '" .. (config_info.base_name or active_config)
            .. "' does not declare binaryDir; loomworks cannot locate its build "
            .. "directory. Add binaryDir to the preset in CMakePresets.json.")
    end

    local multi_config = is_multi_config(generator)

    local build_dir
    if project.cached_build_dir then
        -- Prefer cached path (preserves old build dir after config rename)
        build_dir = project.cached_build_dir
    else
        build_dir = resolve_build_dir(project.name, active_config, config_info, project.workspace_root, multi_config, kit)
        -- Avoid colliding with existing dirs from other configs
        if not config_info or not config_info.binary_dir then
            local uv = vim.uv or vim.loop
            if uv.fs_stat(build_dir) then
                local base = build_dir
                local n = 2
                while uv.fs_stat(base .. "-" .. n) do
                    n = n + 1
                end
                build_dir = base .. "-" .. n
            end
        end
    end

    -- Configure task
    local cmake_cmd = (kit and kit.cmake_path) or "cmake"
    local configure_cmd = { cmake_cmd }

    if from_preset then
        -- cmake wants the bare preset name (`dev`), not our canonical
        -- `preset:dev` key. cmake reads CMakePresets.json and applies the
        -- preset's generator, binaryDir, toolchain and cacheVariables itself,
        -- so we pass ONLY `--preset <name>` here — none of the manual
        -- -G/-S/-B/-DCMAKE_BUILD_TYPE/-DCMAKE_TOOLCHAIN_FILE flags. (User-declared
        -- project `options` are still appended below as `-D…` augmentation,
        -- which cmake accepts alongside --preset.)
        configure_cmd[#configure_cmd + 1] = "--preset"
        configure_cmd[#configure_cmd + 1] = config_info.base_name or active_config
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
            -- Derive the C compiler from the C++ compiler path (g++ → gcc,
            -- clang++ → clang).
            local c_path = compiler_path:gsub("clang%+%+", "clang"):gsub("g%+%+", "gcc")
            if compiler_path:match("clang%-cl") then
                c_path = compiler_path -- clang-cl is both the C and the C++ driver
            end
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

    -- Manual toolchain / SDK args. Skipped entirely for a preset: cmake applies
    -- the preset's toolchain via `--preset`, and re-passing -DCMAKE_TOOLCHAIN_FILE
    -- here would (a) be redundant and (b) append an UNEXPANDED `${sourceDir}/…`
    -- (only `${ENV}` is expanded below), overriding the preset's resolved path.
    if not from_preset then
        -- Toolchain file: kit.toolchain (from SDK) or config_info.toolchain (from user)
        local toolchain = (kit and kit.toolchain) or (config_info and config_info.toolchain)
        if toolchain then
            local tc = toolchain
            tc = tc:gsub("%${([^}]+)}", function(var)
                return os.getenv(var) or "${" .. var .. "}"
            end)
            configure_cmd[#configure_cmd + 1] = "-DCMAKE_TOOLCHAIN_FILE=" .. tc
        end

        -- SDK-provided extra cmake args (e.g., -DCMAKE_TOOLCHAIN_FILE=<path>)
        if kit and kit.extra_args then
            vim.list_extend(configure_cmd, kit.extra_args)
        end
    end

    -- User-defined options (project-wide + inherited + config-specific)
    -- Appended after managed flags so user values can override.
    -- Option values support ${variable} expansion (same as toolchain paths):
    -- built-in variables (workspace_root, project_path) + environment variables.
    -- Always resolve — options may come from inherited base configs even if
    -- the active config and project-wide level have no direct options.
    -- Reserved CMAKE_<LANG>_COMPILER options are skipped so the tool's
    -- compiler (managed -DCMAKE_C/CXX_COMPILER above, never touched here)
    -- always wins; skipped keys feed the config's inline diagnostic.
    local stripped_opts = {}
    local type_config = project.type_config or {}
    do
        local resolved_opts = M.resolve_options(
            type_config, project.configurations or {}, active_config)
        if next(resolved_opts) then
            local opt_ctx = {
                workspace_root = project.workspace_root,
                project_path = project.path or project.name,
            }
            local expand = require("loomworks.expand")
            -- Fold user-declared project variables into the expansion context
            -- (spec §5c / core §1.3.1). Values are resolved upstream with the
            -- active compiler family already applied (overseer's
            -- resolve_project_variables), so a compiler-conditional flag such
            -- as `${warn_flags}` lands on the `-D` line without editing
            -- project files. Two-pass: a variable value may itself reference a
            -- built-in variable, expanded against the built-ins above.
            if project.resolved_variables then
                for name, entry in pairs(project.resolved_variables) do
                    opt_ctx[name] = expand.expand_string(entry.value, opt_ctx)
                end
            end
            for k, v in pairs(resolved_opts) do
                if reserved_compiler.is_reserved_option(k) then
                    stripped_opts[#stripped_opts + 1] = k
                else
                    local expanded = expand.expand_string(v, opt_ctx)
                    configure_cmd[#configure_cmd + 1] = "-D" .. k .. "=" .. expanded
                end
            end
        end
    end
    table.sort(stripped_opts)

    -- Closure to wrap commands with vcvarsall for this project's kit+generator.
    -- `tag` labels the generated .bat (configure/build) so the two builders
    -- write distinct files instead of clobbering a shared name.
    local function wrap(cmd, tag)
        return wrap_cmd(cmd, kit, generator, build_dir, tag)
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
            -- toolchains-v1 gives per-language compiler paths, used to
            -- reconstruct compile_commands.json for non-emitting generators
            -- (Visual Studio / Xcode). See §12.
            for _, marker in ipairs({ "codemodel-v2", "cache-v2", "toolchains-v1" }) do
                local query_file = query_dir .. "/" .. marker
                if not uv.fs_stat(query_file) then
                    local fd = uv.fs_open(query_file, "w", 420) -- 0644
                    if fd then uv.fs_close(fd) end
                end
            end
            return {
                cmd = wrap(configure_cmd, "configure"),
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
            -- Reserved compiler keys dropped from this build (hand-edited
            -- file). Present only when non-empty; surfaces as an inline
            -- diagnostic. The tool's compiler is used regardless.
            stripped_compiler_keys = (#stripped_opts > 0 or #stripped_env > 0)
                and { options = stripped_opts, env = stripped_env } or nil,
            module_info = {
                multi_config = multi_config,
                generator = generator,
                compiler = kit and kit.compiler_id or nil,
                source_dir = project.path,
            },
        },
    }

    -- Build tasks — always build only the active configuration.
    -- Multi-config generators (Visual Studio, Ninja Multi-Config) only
    -- understand the underlying variant name (Debug, Release, ...) at
    -- the `--config` flag, not the user's configuration key. A user-
    -- declared config like `debug-with-addon` that inherits Debug must
    -- be passed as `--config Debug`, otherwise msbuild rejects the
    -- combination ("This project doesn't contain the Configuration
    -- and Platform combination of debug-with-addon|x64..."). The task
    -- name still uses `active_config` so the user sees their chosen
    -- identity in the overseer task list and cache. A preset with no
    -- mined build type yields nil here → `--config` is omitted.
    if multi_config then
        local build_variant = multi_config_variant(config_info, active_config)
        local build_cmd = { cmake_cmd, "--build", build_dir }
        if build_variant then
            build_cmd[#build_cmd + 1] = "--config"
            build_cmd[#build_cmd + 1] = build_variant
        end
        tasks[#tasks + 1] = {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = wrap(build_cmd, "build"),
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
                    cmd = wrap({ cmake_cmd, "--build", build_dir }, "build"),
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
    local env = strip_reserved_env(project.env)

    local generator = (config_info and config_info.generator)
            or (kit and kit.generator)
            or nil
    local multi_config = is_multi_config(generator)

    local build_dir = project.cached_build_dir
            or resolve_build_dir(project.name, active_config, config_info, project.workspace_root, multi_config, kit)
    local configuration_key = project.configuration_key or active_config

    local function wrap(cmd, tag)
        return wrap_cmd(cmd, kit, generator, build_dir, tag)
    end

    local cmake_cmd = (kit and kit.cmake_path) or "cmake"
    local clean_cmd = { cmake_cmd, "--build", build_dir, "--target", "clean" }
    if multi_config then
        -- Multi-config: --config takes the underlying variant, not the
        -- user's configuration key. See M.tasks for the rationale. nil for a
        -- preset without a mined build type → omit --config.
        local build_variant = multi_config_variant(config_info, active_config)
        if build_variant then
            clean_cmd[#clean_cmd + 1] = "--config"
            clean_cmd[#clean_cmd + 1] = build_variant
        end
    end

    return {
        {
            name = project.name .. ": clean " .. active_config,
            builder = function()
                return {
                    cmd = wrap(clean_cmd, "clean"),
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
    local env = strip_reserved_env(project.env)

    local generator = (config_info and config_info.generator)
            or (kit and kit.generator)
            or nil
    local multi_config = is_multi_config(generator)

    local build_dir = project.cached_build_dir
            or resolve_build_dir(
                project.name, active_config, config_info, project.workspace_root, multi_config, kit)

    local cmake_cmd = (kit and kit.cmake_path) or "cmake"
    local cmd = { cmake_cmd, "--build", build_dir, "--target", target_id }
    if multi_config then
        -- Multi-config: --config takes the underlying variant, not the
        -- user's configuration key. See M.tasks for the rationale. nil for a
        -- preset without a mined build type → omit --config.
        local build_variant = multi_config_variant(config_info, active_config)
        if build_variant then
            cmd[#cmd + 1] = "--config"
            cmd[#cmd + 1] = build_variant
        end
    end

    return {
        name = project.name .. ": build " .. target_id,
        builder = function()
            return {
                cmd = wrap_cmd(cmd, kit, generator, build_dir, "build"),
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
--- Clear the cmake_kits detection cache.
--- Called by core's rescan_tools() before a fresh scan.
function M.invalidate_tools()
    local ok, cmake_kits = pcall(require, "loomworks.cmake_kits")
    if ok then cmake_kits.clear_cache() end
end

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

--- Generate cross-compilation kits from SDK capabilities.
--- Called by core when an SDK provides capabilities for cmake.
--- @param caps table opaque data from sdk:query("cmake")
--- @param sdk loomworks.SDK
--- @return { tool_data: table }[]
function M.kits_from_sdk(caps, sdk)
    if not caps then return {} end
    local kits = {}
    local cmake_path = caps.cmake_path

    -- Single-compiler SDKs (no platforms[] / archs[] cross product):
    -- the C/C++ compiler provider hands us one compiler binary and
    -- we produce exactly one kit. Distinguished from platform SDKs
    -- by `compiler_path` being set without `platforms` or
    -- `toolchain_file`. No cross-compile machinery — just CC/CXX
    -- env passthrough so cmake picks the right compiler at configure
    -- time, plus any sibling clangd for LSP. compiler_path is the
    -- C++ driver (the load-bearing field).
    if not caps.platforms and not caps.toolchain_file and caps.compiler_path then
        local env = {}
        if caps.cc_path then env.CC = caps.cc_path end
        env.CXX = caps.compiler_path
        return { { tool_data = {
            id = sdk.key,
            display = sdk:display_name(),
            generator = caps.generator or "Ninja",
            compiler_id = caps.compiler_id,
            compiler_path = caps.compiler_path,
            compiler_version = caps.compiler_version,
            clangd_path = caps.clangd_path,
            env = next(env) and env or nil,
            sdk_key = sdk.key,
        } } }
    end

    -- Support multi-platform SDKs (e.g., multi-arch / cross-compile)
    local platforms = caps.platforms
    if not platforms and caps.toolchain_file then
        -- Legacy single-platform format
        platforms = { {
            name = sdk:display_name(),
            toolchain_file = caps.toolchain_file,
            archs = caps.archs or {},
            arch_args = caps.arch_args or {},
        } }
    end
    if not platforms then return {} end

    for _, platform in ipairs(platforms) do
        local platform_name = platform.name
        for _, arch in ipairs(platform.archs or {}) do
            local extra_args = {}
            if platform.arch_args and platform.arch_args[arch] then
                vim.list_extend(extra_args, platform.arch_args[arch])
            end
            local id_parts = { sdk:sdk_type(), platform_name:lower():gsub("%s+", "-"), arch }
            kits[#kits + 1] = { tool_data = {
                id = table.concat(id_parts, "-"),
                display = platform_name .. " " .. (sdk:sdk_version() or "") .. " " .. arch,
                generator = "Ninja",
                toolchain = platform.toolchain_file,
                cmake_path = cmake_path,
                clangd_path = caps.clangd_path,
                clangd_required = caps.clangd_required or false,
                extra_args = extra_args,
                sdk_key = sdk.key,
                -- Explicit kit identity fields. The profile-level
                -- Toolchain row reads these to render the canonical
                -- `<platform> <version> <arch>` label without parsing
                -- `id` or `display`.
                platform = platform_name,
                arch = arch,
                sdk_version = sdk:sdk_version(),
            } }
        end
    end
    return kits
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
--- @param ctx { build_dir: string, project_path?: string, config_name?: string }
--- @return table<string, loomworks.CachedTarget>|nil targets
function M.parse_targets(ctx)
    local build_dir = ctx.build_dir
    local config_name = ctx.config_name
    if not build_dir then return nil end
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"

    -- Source root from codemodel (absolute path to project source dir)
    local source_root = codemodel.paths and codemodel.paths.source or nil

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
                -- Case-insensitive comparison on Windows (cmake may emit
                -- different casing than the build_dir we computed)
                local norm_lower = normalized:lower()
                local prefix_lower = build_prefix:lower()
                if norm_lower:sub(1, #prefix_lower) == prefix_lower then
                    artifact = normalized:sub(#build_prefix + 1)
                else
                    artifact = normalized
                end
            end
        end

        -- Extract source file paths (for test source location mapping)
        local sources
        if tgt_detail.sources and source_root then
            for _, src in ipairs(tgt_detail.sources) do
                if src.path then
                    local ext = src.path:match("%.([^%.]+)$")
                    if ext then
                        ext = ext:lower()
                        if ext == "cpp" or ext == "cc" or ext == "cxx" or ext == "c" then
                            sources = sources or {}
                            local abs
                            if src.path:match("^[A-Za-z]:") or src.path:match("^/") then
                                abs = src.path
                            else
                                -- Relative to codemodel source root
                                abs = source_root .. "/" .. src.path
                            end
                            sources[#sources + 1] = abs:gsub("\\", "/")
                        end
                    end
                end
            end
        end

        targets[tgt_ref.name] = {
            type = target_type,
            dependencies = deps,
            artifact = artifact,
            sources = sources,
        }

        ::continue::
    end

    return next(targets) and targets or nil
end

--- Async wrapper for parse_targets. Yields to the event loop before
--- parsing to avoid blocking during batch scanning on init.
--- @param ctx { build_dir: string, project_path?: string, config_name?: string }
--- @param callback fun(targets: table<string, loomworks.CachedTarget>|nil)
function M.parse_targets_async(ctx, callback)
    vim.schedule(function()
        callback(M.parse_targets(ctx))
    end)
end

--- Map cmake's language tokens (the `language` field on per-target
--- compileGroups in the file-api reply) to the canonical strings we
--- match against `Configuration.languages` and `Tool.languages`.
--- Languages cmake exposes that don't have an entry here pass
--- through lowercased verbatim, so a new toolchain that introduces
--- a novel language gets surfaced rather than silently dropped.
local CMAKE_LANG_CANONICAL = {
    C      = "c",
    CXX    = "c++",
    Rust   = "rust",
    Fortran = "fortran",
    ASM    = "asm",
    ["ASM-ATT"]   = "asm",
    ["ASM-MASM"]  = "asm",
    ["ASM_NASM"]  = "asm",
    OBJC   = "objective-c",
    OBJCXX = "objective-c++",
    CUDA   = "cuda",
    Swift  = "swift",
    HIP    = "hip",
    ISPC   = "ispc",
    CSharp = "c#",
    Java   = "java",
}

--- Toolchain runtime directories for launching built executables.
--- cmake tool_data carries `compiler_path` (the compiler executable); its
--- directory holds the runtime DLLs for gcc/clang toolchains. Core adds the
--- build tree's own shared-library dirs generically.
--- @param ctx { tool_data?: table }
--- @return string[]|nil
function M.runtime_path(ctx)
    local td = ctx and ctx.tool_data
    local cp = type(td) == "table" and td.compiler_path or nil
    if type(cp) == "string" and cp ~= "" then
        local dir = cp:gsub("\\", "/"):match("^(.*)/[^/]*$")
        if dir and dir ~= "" then return { dir } end
    end
    return nil
end

--- Detect the set of languages a cmake configuration actually enabled.
--- Walks every target's compileGroups in the file-api codemodel reply,
--- unions the `language` fields, and normalizes to canonical strings. The
--- configuration must have been successfully configured at least once
--- (file-api reply must exist on disk).
--- @param ctx { build_dir: string, config_name?: string }
--- @return string[]|nil canonical language list, or nil when no reply exists
function M.detect_languages(ctx)
    local build_dir = ctx.build_dir
    if not build_dir then return nil end
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    local config_name = ctx.config_name

    -- Match the configuration (multi-config generators) or take the
    -- first (single-config generators).
    local cfg
    if config_name then
        for _, c in ipairs(codemodel.configurations) do
            if c.name == config_name then cfg = c break end
        end
    end
    cfg = cfg or codemodel.configurations[1]
    if not cfg or not cfg.targets then return nil end

    local seen, list = {}, {}
    for _, tgt_ref in ipairs(cfg.targets) do
        if tgt_ref.jsonFile then
            local detail = read_json_file(reply_dir .. "/" .. tgt_ref.jsonFile)
            if detail and detail.compileGroups then
                for _, cg in ipairs(detail.compileGroups) do
                    local lang = cg.language
                    if type(lang) == "string" and lang ~= "" then
                        local canon = CMAKE_LANG_CANONICAL[lang] or lang:lower()
                        if not seen[canon] then
                            seen[canon] = true
                            list[#list + 1] = canon
                        end
                    end
                end
            end
        end
    end
    -- Filter to languages loomworks tracks (module-declared + debug
    -- adapter mappings). Drops noise like `rc` (Windows resource
    -- compiler), `asm`, `ispc`, etc. that cmake enables behind the
    -- scenes but loomworks has no routing concept for. Without this,
    -- the language-drift diagnostic in workspace.lua fires on
    -- spurious differences the user can't act on.
    list = require("loomworks.languages").filter(list)
    table.sort(list)
    return #list > 0 and list or nil
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

-- ============= Generated compile_commands.json (§12) =============

--- Whether a compiler drives with MSVC (`/`-prefixed) flag syntax.
--- True for the `cl` and `clang-cl` drivers (matched on basename,
--- case-insensitively, with an optional `.exe`), false otherwise (gcc,
--- clang, …). Determines `/I` vs `-I`, `/D` vs `-D`, etc.
--- @param compiler string compiler path or bare name
--- @return boolean
local function compiler_is_msvc(compiler)
    if type(compiler) ~= "string" then return false end
    local base = compiler:gsub("\\", "/"):match("[^/]+$") or compiler
    base = base:lower():gsub("%.exe$", "")
    return base == "cl" or base == "clang-cl"
end

--- Split a single compileCommandFragment into argv tokens, honouring
--- double quotes (a fragment can carry several flags, e.g.
--- `-DFOO=1 -DBAR="a b"`). Backslashes are left verbatim — Windows paths
--- in fragments are literal. Quotes group whitespace; they are stripped
--- from the emitted token.
--- @param fragment string
--- @return string[]
local function tokenize_fragment(fragment)
    local tokens = {}
    local cur, has = {}, false
    local i, n = 1, #fragment
    while i <= n do
        local c = fragment:sub(i, i)
        if c == '"' then
            has = true
            i = i + 1
            while i <= n do
                local d = fragment:sub(i, i)
                if d == '"' then break end
                cur[#cur + 1] = d
                i = i + 1
            end
        elseif c == " " or c == "\t" then
            if has then
                tokens[#tokens + 1] = table.concat(cur)
                cur, has = {}, false
            end
        else
            has = true
            cur[#cur + 1] = c
        end
        i = i + 1
    end
    if has then tokens[#tokens + 1] = table.concat(cur) end
    return tokens
end

--- Expand a single fragment token, inlining a `@response-file` when it
--- names a file that exists on disk (tokenizing its contents). A `@` token
--- whose file is absent is kept verbatim. Non-`@` tokens pass through as a
--- single-element list. Response files are rare from the file-api (the
--- codemodel usually gives logical fragments) but are handled defensively.
--- @param token string
--- @return string[]
local function expand_token(token)
    if token:sub(1, 1) ~= "@" then return { token } end
    local rsp = token:sub(2)
    if not uv.fs_stat(rsp) then return { token } end
    local content = io_mod.read_file(rsp)
    if not content then return { token } end
    return tokenize_fragment(content)
end

--- Resolve a file-api source path to an absolute, forward-slash path.
--- Absolute paths (drive-letter or POSIX root) pass through; relative
--- paths are resolved against the codemodel source root.
--- @param path string
--- @param source_root string|nil
--- @return string
local function abs_source_path(path, source_root)
    local p = path:gsub("\\", "/")
    if p:match("^%a:/") or p:match("^/") then return p end
    if source_root and source_root ~= "" then
        return (source_root:gsub("\\", "/"):gsub("/$", "")) .. "/" .. p
    end
    return p
end

--- Select the codemodel configuration matching `variant` (multi-config
--- generators name one per build type), else the first. Mirrors
--- `parse_targets` / `detect_languages`.
--- @param codemodel table
--- @param variant string|nil
--- @return table|nil
local function select_codemodel_config(codemodel, variant)
    local configs = codemodel.configurations
    if not configs then return nil end
    if variant then
        for _, c in ipairs(configs) do
            if c.name == variant then return c end
        end
    end
    return configs[1]
end

--- Build the `compile_commands.json` entry list from already-parsed
--- file-api data. Pure (no cmake invocation) so it can be unit-tested
--- against fixture JSON. One entry per source across every target's
--- compileGroups.
--- @param codemodel table parsed codemodel-v2 reply
--- @param target_details table<string, table> jsonFile → parsed target detail
--- @param toolchains table|nil parsed toolchains-v1 reply
--- @param source_root string|nil codemodel.paths.source
--- @param variant string|nil active configuration name to select
--- @param build_dir string used as each entry's `directory`
--- @param opts? { compiler?: string } fallback compiler when a language
---        has no toolchain entry
--- @return table[] entries
function M._build_cc_entries(codemodel, target_details, toolchains, source_root, variant, build_dir, opts)
    opts = opts or {}
    local entries = {}

    -- Per-language compiler paths keyed by cmake's own language token
    -- ("C", "CXX", …) — the same token compileGroups carry, so no
    -- canonicalization is needed to match them up.
    local compiler_by_lang = {}
    if toolchains and toolchains.toolchains then
        for _, tc in ipairs(toolchains.toolchains) do
            local lang = tc.language
            local cpath = tc.compiler and tc.compiler.path
            if type(lang) == "string" and type(cpath) == "string" and cpath ~= "" then
                compiler_by_lang[lang] = cpath
            end
        end
    end

    local cfg = select_codemodel_config(codemodel, variant)
    if not cfg or not cfg.targets then return entries end

    for _, tref in ipairs(cfg.targets) do
        local detail = tref.jsonFile and target_details[tref.jsonFile]
        if detail and detail.compileGroups then
            local sources = detail.sources or {}
            for _, cg in ipairs(detail.compileGroups) do
                local lang = cg.language
                -- Fallback chain: file-api toolchain → kit compiler → cl.exe
                -- (this gap-fill feature targets MSVC/VS generators).
                local compiler = compiler_by_lang[lang] or opts.compiler or "cl.exe"
                local msvc = compiler_is_msvc(compiler)

                -- Fragment tokens (compile flags), in file-api order.
                local frag_tokens = {}
                for _, f in ipairs(cg.compileCommandFragments or {}) do
                    if type(f.fragment) == "string" then
                        for _, tok in ipairs(tokenize_fragment(f.fragment)) do
                            for _, ex in ipairs(expand_token(tok)) do
                                frag_tokens[#frag_tokens + 1] = ex
                            end
                        end
                    end
                end

                -- Include flags in the compiler's native syntax.
                local inc_tokens = {}
                for _, inc in ipairs(cg.includes or {}) do
                    local p = inc.path
                    if type(p) == "string" then
                        if msvc then
                            inc_tokens[#inc_tokens + 1] = inc.isSystem and "/external:I" or "/I"
                            inc_tokens[#inc_tokens + 1] = p
                        elseif inc.isSystem then
                            inc_tokens[#inc_tokens + 1] = "-isystem"
                            inc_tokens[#inc_tokens + 1] = p
                        else
                            inc_tokens[#inc_tokens + 1] = "-I" .. p
                        end
                    end
                end

                -- Define flags in the compiler's native syntax.
                local def_tokens = {}
                for _, d in ipairs(cg.defines or {}) do
                    local def = d.define
                    if type(def) == "string" then
                        def_tokens[#def_tokens + 1] = (msvc and "/D" or "-D") .. def
                    end
                end

                for _, si in ipairs(cg.sourceIndexes or {}) do
                    local src = sources[si + 1] -- file-api indexes are 0-based
                    if src and type(src.path) == "string" then
                        local abs = abs_source_path(src.path, source_root)
                        local args = { compiler }
                        vim.list_extend(args, frag_tokens)
                        vim.list_extend(args, inc_tokens)
                        vim.list_extend(args, def_tokens)
                        args[#args + 1] = abs
                        entries[#entries + 1] = {
                            directory = build_dir,
                            file = abs,
                            arguments = args,
                        }
                    end
                end
            end
        end
    end

    return entries
end

--- Reconstruct a `compile_commands.json` from the cmake file-api and write
--- it into `out_dir` (§12). Reads the codemodel + toolchains replies under
--- `build_dir`, builds one entry per source, and writes the array. The
--- project build directory is never written to.
--- @param build_dir string absolute build directory (holds the file-api reply)
--- @param out_dir string loomworks-owned directory to write into
--- @param opts? { variant?: string, config_name?: string, compiler?: string }
--- @return integer|nil count of entries written, nil when no codemodel reply
function M.generate_compile_commands(build_dir, out_dir, opts)
    opts = opts or {}
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local variant = opts.variant or opts.config_name
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"

    -- Read the target detail files for the selected configuration, keyed by
    -- jsonFile so _build_cc_entries can look them up while it re-selects.
    local cfg = select_codemodel_config(codemodel, variant)
    local target_details = {}
    if cfg and cfg.targets then
        for _, tref in ipairs(cfg.targets) do
            if tref.jsonFile and not target_details[tref.jsonFile] then
                local d = read_json_file(reply_dir .. "/" .. tref.jsonFile)
                if d then target_details[tref.jsonFile] = d end
            end
        end
    end

    local toolchains = find_file_api_reply(build_dir, "toolchains", 1)
    local source_root = codemodel.paths and codemodel.paths.source or nil

    local entries = M._build_cc_entries(
        codemodel, target_details, toolchains, source_root, variant, build_dir, opts)

    io_mod.ensure_dir(out_dir)
    local out_file = out_dir .. "/compile_commands.json"
    if #entries == 0 then
        -- Preserve a valid (empty) JSON array — the JSON encoder can't tell
        -- an empty Lua table from an object, and clangd needs an array.
        local ok = io_mod.write_file_atomic(out_file, "[]\n")
        return ok and 0 or nil
    end
    local ok = io_mod.write_json(out_file, entries)
    return ok and #entries or nil
end

--- Most-recent mtime (seconds) of the file-api reply index under
--- `build_dir`. The index is rewritten on every configure, so it is the
--- cheapest freshness anchor for the generated database. nil when no reply
--- directory / index exists.
--- @param build_dir string
--- @return integer|nil
local function file_api_index_mtime(build_dir)
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    local handle = uv.fs_scandir(reply_dir)
    if not handle then return nil end
    local latest
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        if (ftype == "file" or ftype == nil) and name:match("^index%-.*%.json$") then
            local st = uv.fs_stat(reply_dir .. "/" .. name)
            if st and st.mtime and (not latest or st.mtime.sec > latest) then
                latest = st.mtime.sec
            end
        end
    end
    return latest
end

--- Loomworks-owned directory holding the generated compile_commands.json
--- for a given build directory. Mirrors the build dir's subpath under
--- `.nvim/build/` into `.nvim/cache/cc/` so it is collision-free by
--- construction (build dirs are already unique per project/kit/config) and
--- never writes into the project build tree. A build dir outside the
--- standard `.nvim/build/` root falls back to a sanitized copy of its path.
--- @param workspace_root string
--- @param build_dir string
--- @return string
local function generated_cc_dir(workspace_root, build_dir)
    local root = workspace_root:gsub("\\", "/"):gsub("/$", "")
    local nb = root .. "/.nvim/build/"
    local bd = build_dir:gsub("\\", "/")
    local tail
    if bd:sub(1, #nb):lower() == nb:lower() then
        tail = bd:sub(#nb + 1)
    else
        tail = bd:gsub("^%a:", ""):gsub("^/+", "")
    end
    -- Keep '/' (directory separators); scrub only path-illegal characters.
    tail = tail:gsub('[:<>"|?*]', "_")
    return root .. "/.nvim/cache/cc/" .. tail
end

-- ========================== Test integration ==========================

--- Create a CTestUnit for test discovery and execution.
--- @param config_unit loomworks.ConfigUnit
--- @return loomworks.CTestUnit|nil
function M.create_test_unit(config_unit)
    if not config_unit:build_dir() then return nil end
    local CTestUnit = require("loomworks.test_units.ctest")
    return CTestUnit.new(config_unit)
end

--- Return LSP configs for this project.
--- Emits two entries, both rooted at the project source path and both
--- keyed to the active configuration's build dir (or the build dir
--- referenced by `compile_commands_from` if set):
---   1. clangd — `compile_commands_dir` = the build dir.
---   2. qmlls  — `build_dir` = the same build dir, so qmlls resolves QML
---      imports against the profile's CMake build tree. Emitted
---      unconditionally (no QML detection); it stays inert on non-QML
---      projects because no `.qml` buffers exist to attach to.
--- @param project loomworks.Project
--- @return loomworks.LspConfigEntry[]
function M.lsp_configs(project)
    local ws = project._workspace
    if not ws then return {} end
    local root_dir = ws.root .. "/" .. (project.path or project.key)

    -- Compile commands dir, in order:
    --   1. `compile_commands_from` redirect to a different configuration
    --   2. Active profile's ProfileProject for this project (→ ConfigUnit build_dir)
    --   3. `project.cached.build_dir` fallback (legacy active-config summary)
    local tc = project.type_config or {}
    local build_dir = nil
    -- Whether build_dir came from a `compile_commands_from` redirect (a
    -- different configuration's build dir). Generation (§12) is skipped in
    -- that case — the redirect target owns its own database.
    local from_redirect = false
    if tc.compile_commands_from then
        local ref_cfg = project.get_configuration and project:get_configuration(tc.compile_commands_from)
        if ref_cfg and project.config_units_for_configuration then
            local ref_units = project:config_units_for_configuration(ref_cfg)
            for _, ref_unit in ipairs(ref_units) do
                local bd = ref_unit:build_dir()
                if bd then build_dir = bd; from_redirect = true; break end
            end
        end
    end
    -- Active profile's ProfileProject for this project, captured for both
    -- build_dir resolution and the §12 generated-database decision below.
    local active_pp = nil
    local active_profile = ws.get_active_profile and ws:get_active_profile()
    if active_profile then
        active_pp = active_profile:project(project.key)
    end
    if not build_dir and active_pp then
        build_dir = active_pp:build_dir()
    end
    if not build_dir and project.cached then
        build_dir = project.cached.build_dir
    end

    -- Binary: type_config.clangd (env-expanded) wins, else active tool's
    -- clangd_path. binary_required is set when the active tool (e.g. an SDK
    -- kit) declares its clangd as non-optional.
    --
    -- Resolve the active tool freshly from the active profile rather than
    -- relying on project.tool_data — for SDK-only profiles the latter is nil
    -- (SDK tools are resolved lazily via Profile:tool_for()).
    local binary = nil
    local binary_required = false
    if type(tc.clangd) == "string" and tc.clangd ~= "" then
        binary = tc.clangd
    else
        local tool_data = project.tool_data
        if (not tool_data or not tool_data.clangd_path)
                and ws.get_active_profile then
            local active_profile = ws:get_active_profile()
            if active_profile and active_profile.tool_for then
                local tref = active_profile:tool_for(project.type)
                tool_data = tref and tref.data or tool_data
            end
        end
        if tool_data and tool_data.clangd_path then
            binary = tool_data.clangd_path
            binary_required = tool_data.clangd_required == true
        end
    end

    -- qmlls binary: type_config.qmlls wins (env-expanded by the integration,
    -- as with clangd), else nil so the integration falls back to `qmlls` on
    -- PATH. There is no tool-provided qmlls path in this cut, so
    -- binary_required only comes from an explicit type_config.qmlls_required.
    -- Optional type_config.qml_import_paths (a list) becomes extra `-I` import
    -- paths for qmlls.
    local qmlls_binary = nil
    if type(tc.qmlls) == "string" and tc.qmlls ~= "" then
        qmlls_binary = tc.qmlls
    end
    local qmlls_required = tc.qmlls_required == true
    local import_paths = nil
    if type(tc.qml_import_paths) == "table" then
        import_paths = tc.qml_import_paths
    end

    -- §12: for a configuration whose generator does not emit
    -- compile_commands.json (Visual Studio / Xcode), point clangd at a
    -- loomworks-generated database instead of the (empty) build dir.
    -- The effective decision uses the active config's own generator when it
    -- has one, else the active kit's generator; an explicit config-level
    -- `compile_commands_generated = true` (future user override / preset)
    -- also forces generation.
    local clangd_cc_dir = build_dir
    if build_dir and not from_redirect then
        local active_cfg = active_pp and active_pp.configuration and active_pp:configuration()
        local cfg_mc = active_cfg and active_cfg.module_config or nil

        -- Active kit's generator (the usual source for an MSVC profile).
        local tool_gen = nil
        do
            local td = project.tool_data
            if (not td or not td.generator) and active_profile and active_profile.tool_for then
                local tref = active_profile:tool_for(project.type)
                td = tref and tref.data or td
            end
            tool_gen = td and td.generator or nil
        end

        local generated
        if cfg_mc and cfg_mc.compile_commands_generated == true then
            generated = true
        else
            local gen = (cfg_mc and cfg_mc.generator) or tool_gen
            generated = compile_commands_generated_default(gen)
        end

        if generated then
            local out_dir = generated_cc_dir(ws.root, build_dir)
            -- Regenerate only when the file-api reply is newer than the
            -- generated file (or it doesn't exist yet) — this is our own
            -- artifact's freshness vs the reply, not source-file staleness.
            local reply_mtime = file_api_index_mtime(build_dir)
            if reply_mtime then
                local out_stat = uv.fs_stat(out_dir .. "/compile_commands.json")
                local out_mtime = out_stat and out_stat.mtime and out_stat.mtime.sec or nil
                if not out_mtime or reply_mtime > out_mtime then
                    local variant = active_cfg
                        and (cfg_mc and cfg_mc.variant or active_cfg.base_name) or nil
                    local compiler = nil
                    do
                        local td = project.tool_data
                        if (not td or not td.compiler_path) and active_profile and active_profile.tool_for then
                            local tref = active_profile:tool_for(project.type)
                            td = tref and tref.data or td
                        end
                        compiler = td and td.compiler_path or nil
                    end
                    pcall(M.generate_compile_commands, build_dir, out_dir, {
                        variant = variant,
                        compiler = compiler,
                    })
                end
            end
            clangd_cc_dir = out_dir
        end
    end

    return {
        {
            server = "clangd",
            binary = binary,
            binary_required = binary_required,
            compile_commands_dir = clangd_cc_dir,
            root_dir = root_dir,
        },
        {
            server = "qmlls",
            binary = qmlls_binary,          -- nil ⇒ integration uses "qmlls" on PATH
            binary_required = qmlls_required,
            build_dir = build_dir,          -- same dir as clangd's compile_commands_dir
            import_paths = import_paths,    -- optional list, may be nil
            root_dir = root_dir,
        },
    }
end

return M
