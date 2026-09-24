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

--- True when a kit builds with the MSVC ABI (cl.exe or clang-cl), for which
--- the compiler cache needs `/Z7` debug info to hit (§5d). Delegates to the
--- shared `cpp_compilers.is_msvc_style` — the single clang-cl/MSVC-ABI signal
--- both the `/Z7` path and the launcher-preference resolver use.
--- @param kit table|nil tool_data
--- @return boolean
local function is_msvc_style(kit)
    return require("loomworks.cpp_compilers").is_msvc_style(kit)
end

--- A CMake cache key that selects a compiler launcher —
--- `CMAKE_<LANG>_COMPILER_LAUNCHER`. Deliberately NOT reserved (§5b reserves
--- only `..._COMPILER`); the compiler-cache feature owns it *conditionally*
--- (§5d / §4f): when core resolved a launcher, the feature's value wins over a
--- user-set one (with a diagnostic); when it did not, a user launcher passes
--- through untouched.
--- @param key any
--- @return boolean
local function is_launcher_option(key)
    return type(key) == "string" and key:match("^CMAKE_.+_COMPILER_LAUNCHER$") ~= nil
end

--- Memoized `cmake --version` probe. Returns `{ major, minor }` or nil.
--- Keyed by the resolved cmake executable so a repeated configure pays it once.
--- Consulted only on the MSVC `/Z7` path and for a full reconfigure (§5d:
--- `--fresh` needs >= 3.24), so a plain build never runs it.
M._cmake_version_cache = {}
--- @param cmake_cmd string
--- @return { major: integer, minor: integer }|nil
local function cmake_version(cmake_cmd)
    local cached = M._cmake_version_cache[cmake_cmd]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local out
    local ok, res = pcall(function()
        return vim.fn.system({ cmake_cmd, "--version" })
    end)
    if ok and type(res) == "string" then out = res end
    local major, minor
    if out then major, minor = out:match("cmake version (%d+)%.(%d+)") end
    local v = (major and minor)
        and { major = tonumber(major), minor = tonumber(minor) } or false
    M._cmake_version_cache[cmake_cmd] = v
    return v ~= false and v or nil
end

--- Whether the resolved cmake is at least `major.minor`. Absent version ⇒
--- treated as older (the conservative answer for every caller).
--- @param cmake_cmd string
--- @param major integer
--- @param minor integer
--- @return boolean
local function cmake_at_least(cmake_cmd, major, minor)
    local v = cmake_version(cmake_cmd)
    if not v then return false end
    return v.major > major or (v.major == major and v.minor >= minor)
end

--- Whether the resolved cmake is >= 3.25 (introduced
--- `CMAKE_MSVC_DEBUG_INFORMATION_FORMAT`).
--- @param cmake_cmd string
--- @return boolean
local function cmake_at_least_325(cmake_cmd)
    return cmake_at_least(cmake_cmd, 3, 25)
end

--- The ONLY cache keys whose change the module applies with an in-place
--- reconfigure (§5d whitelist, core §5.1 "in place only where certain"). They
--- are consulted solely to initialize each target's `<LANG>_COMPILER_LAUNCHER`
--- property when the target is created — and targets are re-created on every
--- configure run — while taking no part in compiler detection or any other
--- first-configure-only computation, so re-passing (or `-U`-retracting) them
--- in place is exactly what a fresh configure would do. Every other change
--- (including the MSVC debug-info keys, whose CMP0141 effect is baked into the
--- flag cache defaults at first configure) takes the full reconfigure.
local IN_PLACE_KEYS = {
    CMAKE_C_COMPILER_LAUNCHER = true,
    CMAKE_CXX_COMPILER_LAUNCHER = true,
}

--- Configure-state entries (relative to the build dir) that `cmake --fresh`
--- discards; removed by core via `pre_configure_reset` below CMake 3.24.
local FRESH_RESET_ENTRIES = { "CMakeCache.txt", "CMakeFiles" }

--- Collect the `-D` cache entries a configure argv passes: name → value
--- (a `-DNAME:TYPE=VALUE` records NAME). Handles both the joined `-DNAME=V`
--- and the split `-D NAME=V` spellings (SDK `extra_args` may use either).
--- @param argv string[]
--- @return table<string, string>
local function passed_d_options(argv)
    local out = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        local body
        if a == "-D" then
            body = argv[i + 1]
            i = i + 1
        elseif type(a) == "string" and a:sub(1, 2) == "-D" then
            body = a:sub(3)
        end
        if type(body) == "string" then
            local lhs, val = body:match("^([^=]+)=(.*)$")
            if lhs then
                local name = lhs:match("^([^:]+)") or lhs
                out[name] = val
            end
        end
        i = i + 1
    end
    return out
end

--- Classify this configure against the unit's previous configure (§5d "Full
--- reconfigure by default; in place only for the launcher keys", core §5.1):
---   * `"none"`     — never configured: a plain first configure;
---   * `"full"`     — any changed configure input: a `-D` added, changed or
---                    removed outside `IN_PLACE_KEYS`, a generator change, a
---                    changed configuration environment (core's
---                    `configure_env` record vs `configuration_env`), or a
---                    configured unit with no `passed_options` record (it
---                    cannot be classified with certainty);
---   * `"in_place"` — nothing changed, or only `IN_PLACE_KEYS` changed; the
---                    second return lists those that disappeared (to `-U`).
--- `allow_in_place = false` (the preset path) turns every change into a full
--- reconfigure, so a per-key `-U` can never clobber a preset's own value.
--- @param project loomworks.ModuleContext
--- @param passed table<string, string> the `-D`s this configure passes
--- @param generator string|nil generator this configure uses
--- @param allow_in_place boolean
--- @return "none"|"full"|"in_place" kind, string[] retract
local function classify_reconfigure(project, passed, generator, allow_in_place)
    local rec = project.recorded_module_info
    local configured = rec ~= nil or project.recorded_options ~= nil
        or project.recorded_cache_launcher ~= nil
    if not configured then return "none", {} end
    if type(rec) ~= "table" or type(rec.passed_options) ~= "table" then
        return "full", {}
    end
    if type(rec.generator) == "string" and generator and rec.generator ~= generator then
        -- CMake refuses a generator change in place.
        return "full", {}
    end
    -- An absent record means "no configuration environment" — which is what
    -- a configure before the record existed actually ran with.
    if not vim.deep_equal(rec.configure_env or {}, project.configuration_env or {}) then
        return "full", {}
    end
    local prev = rec.passed_options
    local retract = {}
    local keys = {}
    for k in pairs(prev) do keys[k] = true end
    for k in pairs(passed) do keys[k] = true end
    for key in pairs(keys) do
        if prev[key] ~= passed[key] then
            if not (allow_in_place and IN_PLACE_KEYS[key]) then return "full", {} end
            if passed[key] == nil then retract[#retract + 1] = key end
        end
    end
    table.sort(retract)
    return "in_place", retract
end

--- One-shot non-blocking warnings (§5d preset / launcher-conflict), deduped so
--- a repeated build does not spam. Keyed by an arbitrary string.
M._warned = {}
--- @param key string
--- @param msg string
local function warn_once(key, msg)
    if M._warned[key] then return end
    M._warned[key] = true
    vim.schedule(function()
        vim.notify("loomworks: " .. msg, vim.log.levels.WARN)
    end)
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
--- (§12). loomworks now OWNS the clangd compilation database for EVERY
--- cmake generator, so the default is `true` regardless of generator.
--- `false` is the per-configuration escape hatch a user sets to fall back
--- to the build dir's native database — only meaningful for an emitting
--- generator (see `generator_emits_compile_commands`). The `generator`
--- argument is retained for call-site symmetry and future policy.
--- @param generator string|nil
--- @return boolean
local function compile_commands_generated_default(generator)
    return true
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
    -- flag (§12) unless the user/preset already set it explicitly. loomworks
    -- owns the database for every generator, so the default is `true`; only
    -- an explicit `false` (the escape hatch) survives here to fall back to a
    -- native database. The flag is module-specific data — it lands in the
    -- Configuration's `module_config`.
    for _, cfg in pairs(configurations) do
        if cfg.compile_commands_generated == nil then
            cfg.compile_commands_generated =
                compile_commands_generated_default(cfg.generator)
        end
    end
    for _, cfg in pairs(preset_configurations) do
        if cfg.compile_commands_generated == nil then
            cfg.compile_commands_generated =
                compile_commands_generated_default(cfg.generator)
        end
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

--- Whether a CMake generator implements `CMAKE_<LANG>_COMPILER_LAUNCHER`.
--- CMake honors the launcher only for the Ninja and Makefile generator
--- families (`Ninja`, `Ninja Multi-Config`, `Unix Makefiles`, `NMake
--- Makefiles`, `MinGW Makefiles`, `MSYS Makefiles`, `Watcom WMake`, …); the
--- Visual Studio and Xcode (and other IDE) generators ignore it (§5d). An
--- unresolved (nil) generator is treated as supporting it — nothing to say.
--- @param generator string|nil
--- @return boolean
local function generator_supports_launcher(generator)
    if type(generator) ~= "string" or generator == "" then return true end
    return generator:match("^Ninja") ~= nil
        or generator:match("Makefiles$") ~= nil
        or generator == "Watcom WMake"
end

--- Why the compiler-cache launcher cannot be applied to a configuration, or
--- nil when it can (§5d non-goals). Shared by `M.cache_launcher_applicable`
--- (core's staleness + status/health) and `M.tasks` (which then injects no
--- launcher and records "none") so the two can never disagree.
--- @param from_preset boolean
--- @param generator string|nil resolved generator
--- @return string|nil reason short noun phrase (status: `not applied (<reason>)`)
--- @return string|nil hint one sentence: how to get caching (health)
local function launcher_not_applicable(from_preset, generator)
    if from_preset then
        return "preset", "A CMake preset owns its cache variables: set "
            .. "CMAKE_<LANG>_COMPILER_LAUNCHER in the preset's cacheVariables to cache it."
    end
    if not generator_supports_launcher(generator) then
        return generator .. " generator", "CMake applies a compiler launcher only with a "
            .. "Ninja or Makefile generator; select a Ninja or Makefile tool for this "
            .. "profile to enable compiler caching."
    end
    return nil, nil
end

--- Whether a compiler-cache launcher can be applied to a configuration
--- (module interface §8 optional hook; consulted by core's launcher staleness
--- and by the profile's cache status / health). Not applicable — so `M.tasks`
--- injects nothing and records `"none"`, and core expects that marker instead
--- of reconfiguring on every build — for a preset (configured by
--- `cmake --preset`, which owns its cache variables) and for a generator that
--- ignores `CMAKE_<LANG>_COMPILER_LAUNCHER` (Visual Studio, Xcode; §5d). The
--- generator is the configuration's own (`module_config.generator`), else the
--- tool's, exactly as `M.tasks` resolves it.
--- @param ctx { configuration: loomworks.Configuration|nil, tool_data: table|nil }
--- @return boolean applicable
--- @return string|nil reason when not applicable (e.g. "preset", "Xcode generator")
--- @return string|nil hint when not applicable
function M.cache_launcher_applicable(ctx)
    local cfg = ctx and ctx.configuration
    local mc = cfg and cfg.module_config
    local generator = (mc and mc.generator)
        or (ctx and ctx.tool_data and ctx.tool_data.generator) or nil
    local reason, hint = launcher_not_applicable(cfg and cfg.from_preset or false, generator)
    if reason then return false, reason, hint end
    return true
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

    -- Compiler-cache launcher (§5d). Core resolved a launcher from the
    -- effective `cache` policy + compiler family (or nil for policy `off`,
    -- `auto` on an MSVC-style compiler, or launcher not found); the module
    -- applies it (not on a preset or a VS/Xcode generator, below). Resolve the user options once,
    -- up front, so the non-preset branch can decide launcher OWNERSHIP: a
    -- user-set `CMAKE_<LANG>_COMPILER_LAUNCHER` is not reserved (§5b/§4f), so
    -- when the feature resolved a launcher it WINS over the user's (with a
    -- diagnostic) and when it did not, the user's launcher passes through.
    local cache_launcher = project.compiler_cache and project.compiler_cache.path or nil
    local resolved_opts = M.resolve_options(
        project.type_config or {}, project.configurations or {}, active_config)
    local user_launcher_keys = {}
    local user_debug_format_conflict = false
    for k, v in pairs(resolved_opts) do
        if is_launcher_option(k) then
            user_launcher_keys[#user_launcher_keys + 1] = k
        elseif k == "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT"
                or k == "CMAKE_POLICY_DEFAULT_CMP0141" then
            -- A user-pinned debug format or CMP0141 policy default wins: the
            -- module injects neither key (§5d).
            user_debug_format_conflict = true
        elseif type(v) == "string" and (v:find("/Zi", 1, true) or v:find("/ZI", 1, true)) then
            user_debug_format_conflict = true
        end
    end
    table.sort(user_launcher_keys)

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

        -- Preset non-goal (§5d): the preset owns its cache variables (a
        -- launcher included), so the compiler-cache launcher is not injected
        -- here. Warn (once)
        -- and direct the user to set CMAKE_<LANG>_COMPILER_LAUNCHER in the
        -- preset's own cacheVariables. cache_launcher is left nil below so the
        -- module records "no launcher applied" ("none") for this configuration;
        -- `M.cache_launcher_applicable` reports the same to core's staleness
        -- check so the recorded "none" is not mistaken for a launcher change.
        if cache_launcher then
            warn_once("preset:" .. project.name .. ":" .. active_config,
                "compiler cache not applied to preset configuration "
                .. project.name .. "/" .. active_config
                .. "; set CMAKE_<LANG>_COMPILER_LAUNCHER in the preset's cacheVariables.")
        end
        cache_launcher = nil
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

        -- Generator non-goal (§5d): CMake honors CMAKE_<LANG>_COMPILER_LAUNCHER
        -- only for Ninja and Makefile generators — Visual Studio / Xcode ignore
        -- it. Inject nothing (nor the MSVC debug-info keys, which only serve a
        -- launcher), warn once, and record "none"; `M.cache_launcher_applicable`
        -- reports the same to core so the unit is not launcher-stale and
        -- status/health say "not applied".
        if cache_launcher and not generator_supports_launcher(generator) then
            warn_once("generator:" .. project.name .. ":" .. active_config,
                "compiler cache not applied to " .. project.name .. "/" .. active_config
                .. " under the " .. tostring(generator) .. " generator: CMake honors "
                .. "CMAKE_<LANG>_COMPILER_LAUNCHER only for Ninja and Makefile generators.")
            cache_launcher = nil
        end

        -- Compiler-cache launcher (§5d): apply the core-resolved launcher via
        -- CMake's own CMAKE_<LANG>_COMPILER_LAUNCHER cache variables (per the
        -- C/CXX languages CMake enables). A user launcher option, if any, is
        -- dropped from emission below (own-launcher wins, §4f).
        if cache_launcher then
            configure_cmd[#configure_cmd + 1] = "-DCMAKE_C_COMPILER_LAUNCHER=" .. cache_launcher
            configure_cmd[#configure_cmd + 1] = "-DCMAKE_CXX_COMPILER_LAUNCHER=" .. cache_launcher

            if #user_launcher_keys > 0 then
                warn_once("launcher:" .. project.name .. ":" .. active_config,
                    "compiler cache owns the compiler launcher for "
                    .. project.name .. "/" .. active_config
                    .. "; ignoring user-set " .. table.concat(user_launcher_keys, ", ")
                    .. ". Set `cache` to off to keep your own launcher.")
            end

            -- MSVC debug-info format: a compile that writes debug info to a
            -- shared .pdb (/Zi|/ZI) is FAILED by sccache and compiled uncached
            -- by ccache. Switch to embedded (/Z7) — only for MSVC/clang-cl,
            -- single-config, cmake >= 3.25, and only when the user has not
            -- pinned a conflicting value (§5d). The format variable only takes
            -- effect under policy CMP0141=NEW, which a project with an older
            -- cmake_minimum_required leaves unset — so the policy default is
            -- injected alongside (it does not override an explicit
            -- cmake_policy(SET CMP0141 OLD); the post-configure scan reports
            -- the resulting /Zi compiles).
            if is_msvc_style(kit) and not multi_config then
                local cache_tool = project.compiler_cache.tool or "the cache"
                local effect = cache_tool == "sccache" and "fail" or "miss"
                if user_debug_format_conflict then
                    warn_once("z7conflict:" .. project.name .. ":" .. active_config,
                        "compiler cache active but a conflicting MSVC debug format is set for "
                        .. project.name .. "/" .. active_config
                        .. "; " .. cache_tool .. " will " .. effect
                        .. " /Zi compiles until it is 'Embedded' (/Z7).")
                elseif cmake_at_least_325(cmake_cmd) then
                    configure_cmd[#configure_cmd + 1] =
                        "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded"
                    configure_cmd[#configure_cmd + 1] =
                        "-DCMAKE_POLICY_DEFAULT_CMP0141=NEW"
                else
                    warn_once("z7old:" .. project.name .. ":" .. active_config,
                        "compiler cache active but cmake < 3.25 cannot set embedded MSVC "
                        .. "debug info; caching may " .. (effect == "fail"
                            and "fail /Zi compiles" or "be ineffective") .. " for "
                        .. project.name .. "/" .. active_config)
                end
            end
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
    do
        -- resolved_opts was resolved once up front (for launcher ownership).
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
                elseif cache_launcher and is_launcher_option(k) then
                    -- The compiler-cache feature owns the launcher (§4f/§5d);
                    -- the user's launcher option is dropped (warned above).
                    -- When no cache is resolved, this branch is skipped and the
                    -- user launcher passes through the else below.
                else
                    local expanded = expand.expand_string(v, opt_ctx)
                    configure_cmd[#configure_cmd + 1] = "-D" .. k .. "=" .. expanded
                end
            end
        end
    end
    table.sort(stripped_opts)

    -- Faithful reconfigure (§5d "Full reconfigure by default", core §5.1).
    -- CMake keeps configure state across reconfigures and computes much of it
    -- only at the first configure, so any changed configure input is applied
    -- by a FULL reconfigure (`--fresh`, or a core-run reset of CMakeCache.txt
    -- + CMakeFiles below 3.24) — except a change confined to the launcher
    -- keys (`IN_PLACE_KEYS`), applied in place: re-passed, or retracted with
    -- `-U<key>` when it disappeared. Record every `-D` this configure passes
    -- (on the preset path: the appended user options) so the next configure
    -- can classify its change; the preset path never takes the in-place
    -- route, so a `-U` can never clobber a preset's own cache value.
    local passed_options = passed_d_options(configure_cmd)
    local pre_configure_reset
    local kind, retract = classify_reconfigure(project, passed_options, generator, not from_preset)
    if kind == "full" then
        if cmake_at_least(cmake_cmd, 3, 24) then
            table.insert(configure_cmd, 2, "--fresh")
        else
            pre_configure_reset = vim.deepcopy(FRESH_RESET_ENTRIES)
        end
    elseif kind == "in_place" and #retract > 0 then
        -- Right after `-B <build_dir>`, ahead of every `-D`.
        local at = #configure_cmd + 1
        for i, a in ipairs(configure_cmd) do
            if a == "-B" then at = i + 2 break end
        end
        for j, key in ipairs(retract) do
            table.insert(configure_cmd, at + j - 1, "-U" .. key)
        end
    end

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
            -- Full reconfigure below CMake 3.24 (§5d): core removes these
            -- configure-state entries from build_dir before the configure.
            pre_configure_reset = pre_configure_reset,
            module_info = {
                multi_config = multi_config,
                generator = generator,
                compiler = kit and kit.compiler_id or nil,
                source_dir = project.path,
                -- Resolved compiler-cache launcher path this configure applied,
                -- or the explicit sentinel "none" (policy off / `auto` on an
                -- MSVC-style compiler / launcher not found / preset / a VS or
                -- Xcode generator). Recorded — never nil for a feature configure — so
                -- `ConfigUnit:is_stale()` distinguishes "configured under the
                -- feature with no cache" (→ "none", install-after-configure
                -- fires when a cache later appears) from a legacy/never-recorded
                -- unit (nil, never retroactively invalidated). (§5d / §11.)
                cache_launcher = cache_launcher or "none",
                -- Every `-D` this configure passed (name → value; on the
                -- preset path the appended user options), so the next
                -- configure can classify its change (§5d full vs in-place).
                passed_options = passed_options,
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

--- Build the shared parse plan from the file-api codemodel (§8.4): resolve the
--- reply dir, source root, the selected configuration, the project-owned target
--- name set, an id→name map (so dependency resolution is O(1) per edge, not a
--- scan of every target), and the ordered list of project-owned target refs to
--- read. Returns nil when there is no usable codemodel reply (never configured).
--- Pure over already-parsed JSON — the per-target detail reads happen in the
--- caller so the async path can slice them.
--- @param ctx { build_dir: string, project_path?: string, config_name?: string }
--- @return { reply_dir: string, source_root: string|nil, config_data: table, project_names: table<string, boolean>, id_to_name: table<string, string>, refs: table[] }|nil
local function parse_targets_plan(ctx)
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

    -- Collect project-owned target names (for filtering dependencies).
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

    -- id → project-owned target name, built once (first occurrence wins) so
    -- dependency resolution is a single map lookup per edge instead of an
    -- inner scan over every target (was O(targets^2)).
    local id_to_name = {}
    local refs = {}
    for _, tref in ipairs(config_data.targets) do
        if tref.id and project_names[tref.name] and id_to_name[tref.id] == nil then
            id_to_name[tref.id] = tref.name
        end
        if project_names[tref.name] and tref.jsonFile then
            refs[#refs + 1] = tref
        end
    end

    return {
        build_dir = build_dir,
        reply_dir = reply_dir,
        source_root = source_root,
        config_data = config_data,
        project_names = project_names,
        id_to_name = id_to_name,
        refs = refs,
    }
end

--- Read and process one project-owned target ref against the plan, producing
--- its `(name, record)`. nil when the target detail is missing or has an
--- unmapped type (UTILITY, ALIAS, …). Dependency names resolve through the
--- plan's `id_to_name` map (O(1) per edge). Shared by the sync and async paths
--- so both emit byte-identical records.
--- @param plan table from `parse_targets_plan`
--- @param tgt_ref table a project-owned target ref (has `jsonFile`)
--- @return string|nil name
--- @return loomworks.CachedTarget|nil record
local function parse_targets_ref(plan, tgt_ref)
    local source_root = plan.source_root
    local id_to_name = plan.id_to_name

    local tgt_detail = read_json_file(plan.reply_dir .. "/" .. tgt_ref.jsonFile)
    if not tgt_detail then return nil end

    local target_type = TARGET_TYPE_MAP[tgt_detail.type]
    if not target_type then return nil end -- skip UTILITY, ALIAS, etc.

    -- Extract link dependencies (only project-owned ones), resolved via the map.
    local deps
    if tgt_detail.dependencies then
        for _, dep in ipairs(tgt_detail.dependencies) do
            if dep.id then
                local name = id_to_name[dep.id]
                if name then
                    deps = deps or {}
                    deps[#deps + 1] = name
                end
            end
        end
        if deps then table.sort(deps) end
    end

    -- Extract primary output artifact path, normalized relative to build_dir.
    local build_dir = plan.build_dir
    local artifact
    if tgt_detail.artifacts and tgt_detail.artifacts[1] then
        local raw = tgt_detail.artifacts[1].path
        if raw then
            local normalized = raw:gsub("\\", "/")
            local build_prefix = build_dir:gsub("\\", "/"):gsub("/?$", "/")
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
                            abs = source_root .. "/" .. src.path
                        end
                        sources[#sources + 1] = abs:gsub("\\", "/")
                    end
                end
            end
        end
    end

    return tgt_ref.name, {
        type = target_type,
        dependencies = deps,
        artifact = artifact,
        sources = sources,
    }
end

--- Parse the cmake file-api reply to extract project-owned targets
--- (synchronous). Kept for the CLI and tests; byte-identical to the async path
--- (shared plan + per-ref helpers).
--- @param ctx { build_dir: string, project_path?: string, config_name?: string }
--- @return table<string, loomworks.CachedTarget>|nil targets
function M.parse_targets(ctx)
    local plan = parse_targets_plan(ctx)
    if not plan then return nil end

    local targets = {}
    for _, tref in ipairs(plan.refs) do
        local name, record = parse_targets_ref(plan, tref)
        if name then targets[name] = record end
    end

    return next(targets) and targets or nil
end

--- Per-slice time budget (nanoseconds) for the incremental target parse.
local PT_SLICE_BUDGET_NS = 5 * 1e6 -- ~5ms
--- Minimum target refs read per scheduled turn (progress guarantee even if the
--- budget is already spent when the turn begins).
local PT_REFS_PER_STEP = 8

--- Async, genuinely-incremental parse of the file-api reply. Builds the plan on
--- the next tick, then reads/decodes the per-target detail JSONs in bounded,
--- time-boxed batches across `vim.schedule` turns (each target detail is a disk
--- read + JSON decode), so a project with many targets never parses in one
--- synchronous burst. Output is identical to `parse_targets`.
--- @param ctx { build_dir: string, project_path?: string, config_name?: string }
--- @param callback fun(targets: table<string, loomworks.CachedTarget>|nil)
function M.parse_targets_async(ctx, callback)
    vim.schedule(function()
        local plan = parse_targets_plan(ctx)
        if not plan then callback(nil); return end

        local targets = {}
        local i = 0
        local function step()
            local start = uv.hrtime()
            local n = 0
            while i < #plan.refs do
                i = i + 1
                local name, record = parse_targets_ref(plan, plan.refs[i])
                if name then targets[name] = record end
                n = n + 1
                -- Yield once we've made at least minimal progress and spent the
                -- slice budget, so a large target set is decoded across turns.
                if n >= PT_REFS_PER_STEP and (uv.hrtime() - start) >= PT_SLICE_BUDGET_NS then
                    break
                end
            end
            if i >= #plan.refs then
                callback(next(targets) and targets or nil)
            else
                vim.schedule(step)
            end
        end
        step()
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

--- Normalize a path for comparison: forward slashes, no trailing slash.
--- @param p string
--- @return string
local function norm_path(p)
    return (p:gsub("\\", "/"):gsub("/+$", ""))
end

--- Directory portion of a (already source-resolved) path.
--- @param p string
--- @return string
local function dir_of(p)
    return (norm_path(p):gsub("/[^/]*$", ""))
end

--- Header file extensions used by the Tier-1 attribution scan (§12.3).
local HEADER_EXTS = {
    h = true, hh = true, hpp = true, hxx = true, ["h++"] = true,
    inl = true, ipp = true, tcc = true, cuh = true,
}

--- Whether a path names a C/C++ header by extension.
--- @param path string
--- @return boolean
local function is_header(path)
    local ext = path:match("%.([%w+]+)$")
    return ext ~= nil and HEADER_EXTS[ext:lower()] == true
end

--- Map cmake language token ("C"/"CXX"/…) → compiler path from a parsed
--- toolchains-v1 reply. The token matches the one compileGroups carry.
--- @param toolchains table|nil
--- @return table<string, string>
local function compiler_map(toolchains)
    local m = {}
    if toolchains and toolchains.toolchains then
        for _, tc in ipairs(toolchains.toolchains) do
            local lang = tc.language
            local cpath = tc.compiler and tc.compiler.path
            if type(lang) == "string" and type(cpath) == "string" and cpath ~= "" then
                m[lang] = cpath
            end
        end
    end
    return m
end

--- Build the argv prefix (compiler + flags, no source file) for a
--- compileGroup, in the compiler's native syntax. Shared by compiled-source
--- and header entries (§12) so both render identical flags. Returns a fresh
--- table each call (the caller appends the file and keeps it).
--- @param cg table compileGroup
--- @param compiler string compiler path / bare name (argv[0])
--- @return string[]
local function cg_argv_prefix(cg, compiler)
    local msvc = compiler_is_msvc(compiler)
    local args = { compiler }
    for _, f in ipairs(cg.compileCommandFragments or {}) do
        if type(f.fragment) == "string" then
            for _, tok in ipairs(tokenize_fragment(f.fragment)) do
                for _, ex in ipairs(expand_token(tok)) do
                    args[#args + 1] = ex
                end
            end
        end
    end
    for _, inc in ipairs(cg.includes or {}) do
        local p = inc.path
        if type(p) == "string" then
            if msvc then
                args[#args + 1] = inc.isSystem and "/external:I" or "/I"
                args[#args + 1] = p
            elseif inc.isSystem then
                args[#args + 1] = "-isystem"
                args[#args + 1] = p
            else
                args[#args + 1] = "-I" .. p
            end
        end
    end
    for _, d in ipairs(cg.defines or {}) do
        local def = d.define
        if type(def) == "string" then
            args[#args + 1] = (msvc and "/D" or "-D") .. def
        end
    end
    return args
end

--- Assemble a single `compile_commands.json` entry from a prebuilt argv prefix
--- (compiler + flags, from `cg_argv_prefix`) and a resolved file path. Clones
--- the prefix so a per-group prefix can be reused across its sources. This is
--- the one place an entry's shape is produced, so the full-DB generator
--- (compiled sources §12.2, headers §12.3) and the per-file query
--- (`compile_command_for` §12.6) cannot drift.
--- @param prefix string[] argv prefix (not mutated)
--- @param abs string resolved absolute file path (the entry's `file`)
--- @param build_dir string the entry's `directory`
--- @return { directory: string, file: string, arguments: string[] }
local function render_cc_entry_with_prefix(prefix, abs, build_dir)
    local args = vim.list_extend({}, prefix)
    args[#args + 1] = abs
    return { directory = build_dir, file = abs, arguments = args }
end

--- Render one entry for a single file from a compileGroup + compiler, building
--- the argv prefix on the spot. Used by the per-file query for compiled TUs;
--- the compiled-source generator instead builds each group's prefix once and
--- calls `render_cc_entry_with_prefix` directly. Header entries use
--- `render_header_entry` (which adds a language-forcing flag) — NOT this.
--- @param cg table compileGroup
--- @param compiler string compiler path / bare name (argv[0])
--- @param abs string resolved absolute file path
--- @param build_dir string the entry's `directory`
--- @return { directory: string, file: string, arguments: string[] }
local function render_cc_entry(cg, compiler, abs, build_dir)
    return render_cc_entry_with_prefix(cg_argv_prefix(cg, compiler), abs, build_dir)
end

--- The language-forcing argv token(s) for a header entry (§12.3), in the
--- compiler's flag style. clangd infers a `.h` (and other ambiguous
--- extensions) as C and then silently drops C++-only flags (e.g. MSVC
--- `/std:c++17`), so a header attributed to a C++ compileGroup must carry an
--- explicit language override. MSVC drivers use the single `/TP` (C++) / `/TC`
--- (C) token; GNU-style drivers use the two-token `-x c++` / `-x c` form.
--- @param msvc boolean whether the compiler drives with MSVC (`/`) syntax
--- @param language string compileGroup language token ("CXX" / "C")
--- @return string[] one or two argv tokens to force the language
local function header_language_argv(msvc, language)
    local cxx = language == "CXX"
    if msvc then
        return { cxx and "/TP" or "/TC" }
    end
    return { "-x", cxx and "c++" or "c" }
end

--- Exposed for unit tests (pure flag-token helper, §12.3).
M._header_language_argv = header_language_argv

--- Render one `compile_commands.json` entry for a HEADER file (§12.3). Like
--- `render_cc_entry` but inserts the language-forcing flag(s)
--- (`header_language_argv`) right after the compiler (argv[1] position), before
--- the include/define flags and the input file, so clangd parses the header in
--- the chosen compileGroup's language rather than guessing from the extension.
--- The one place a header entry is shaped, so the full-DB header generator
--- (§12.3) and the per-file query (§12.6) cannot drift. Compiled TUs keep their
--- real extension and never pass through here.
--- @param cg table compileGroup (its `language` selects C vs C++)
--- @param compiler string compiler path / bare name (argv[0])
--- @param abs string resolved absolute header path
--- @param build_dir string the entry's `directory`
--- @return { directory: string, file: string, arguments: string[] }
local function render_header_entry(cg, compiler, abs, build_dir)
    local prefix = cg_argv_prefix(cg, compiler)
    local lang = header_language_argv(compiler_is_msvc(compiler), cg.language)
    -- Insert after the compiler (argv[1]), preserving lang-token order.
    for i, tok in ipairs(lang) do
        table.insert(prefix, i + 1, tok)
    end
    return render_cc_entry_with_prefix(prefix, abs, build_dir)
end

--- Incremental stream-writer for `compile_commands.json` (§12.2). Writes the
--- array entry-by-entry so the whole database is never encoded in one
--- `vim.json.encode` call: `[`, then each entry encoded on its own,
--- comma-separated, then `]`. The bytes go to a temporary file; the caller
--- finalizes with `cc_writer_finish`, which atomically renames it into place —
--- so clangd never observes a half-written database and the PREVIOUS database
--- stays readable until the new one is complete. Kept as an object (not a
--- single call) so the async generator can drive it in batches across
--- scheduled turns without holding the UI thread.
--- @class loomworks.cmake.CcWriter
--- @field fd integer open file descriptor for the temp file
--- @field tmp string temp file path
--- @field out_file string final target path
--- @field offset integer bytes written so far
--- @field count integer entries written so far
--- @field started boolean whether the opening `[` has been emitted
--- @field ok boolean cleared on any write/encode failure

--- Open the temp file and return a writer, or nil + err.
--- @param out_file string absolute target path
--- @return loomworks.cmake.CcWriter|nil writer, string|nil err
local function cc_writer_open(out_file)
    local tmp = out_file .. ".tmp"
    local fd, err = uv.fs_open(tmp, "w", 438)
    if not fd then return nil, "open tmp: " .. (err or "unknown") end
    return {
        fd = fd, tmp = tmp, out_file = out_file,
        offset = 0, count = 0, started = false, ok = true,
    }
end

--- @param w loomworks.cmake.CcWriter
--- @param s string
local function cc_writer_raw(w, s)
    if not w.ok then return end
    local n, werr = uv.fs_write(w.fd, s, w.offset)
    if werr or not n then w.ok = false; return end
    w.offset = w.offset + #s
end

--- Append one entry to the stream.
--- @param w loomworks.cmake.CcWriter
--- @param entry table
local function cc_writer_put(w, entry)
    if not w.ok then return end
    if not w.started then cc_writer_raw(w, "["); w.started = true end
    cc_writer_raw(w, w.count == 0 and "\n  " or ",\n  ")
    local eok, enc = pcall(vim.json.encode, entry)
    if not eok then w.ok = false; return end
    cc_writer_raw(w, enc)
    w.count = w.count + 1
end

--- Rename `tmp` → `out_file` atomically, retrying a locked destination
--- (Windows EACCES/EPERM while another handle is open) WITHOUT blocking: a
--- short `uv.new_timer` delay between a few attempts, never `uv.sleep`.
--- @param tmp string
--- @param out_file string
--- @param cb fun(ok: boolean, err: string|nil)
local function async_rename(tmp, out_file, cb)
    -- Preserve the previous database as `.bak` (best-effort) before swapping.
    if uv.fs_stat(out_file) then pcall(uv.fs_rename, out_file, out_file .. ".bak") end
    local attempts = 0
    local function try()
        local rok, rerr, code = uv.fs_rename(tmp, out_file)
        if rok then cb(true); return end
        if code ~= "EACCES" and code ~= "EPERM" then
            cb(false, "rename: " .. (rerr or "unknown")); return
        end
        attempts = attempts + 1
        if attempts >= 5 then
            cb(false, "rename failed after retries (file locked?)"); return
        end
        local timer = uv.new_timer()
        timer:start(50, 0, function()
            timer:stop(); timer:close()
            vim.schedule(try)
        end)
    end
    try()
end

--- Close the writer and atomically publish the temp file. Async because the
--- rename may retry on a non-blocking timer (Windows lock contention).
--- @param w loomworks.cmake.CcWriter
--- @param cb fun(ok: boolean, err: string|nil)
local function cc_writer_finish(w, cb)
    if w.ok then
        if w.count == 0 then cc_writer_raw(w, "[]\n")
        else cc_writer_raw(w, "\n]\n") end
    end
    uv.fs_fsync(w.fd)
    uv.fs_close(w.fd)
    if not w.ok then pcall(uv.fs_unlink, w.tmp); cb(false, "write failed"); return end
    async_rename(w.tmp, w.out_file, cb)
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

--- Collapse `.`/`..` segments in a forward-slashed path, preserving a
--- leading drive (`C:/`) or POSIX root (`/`). A leading `..` that would
--- escape the root is clamped (dropped). Used to resolve out-of-tree
--- artifact paths — a project that hardcodes its output directory yields
--- a `../../bin/app`-style path relative to the build dir (§4.6).
--- @param p string forward-slashed path
--- @return string
local function collapse_path(p)
    local root = ""
    local drive = p:match("^(%a:/)")
    if drive then
        root = drive
        p = p:sub(#drive + 1)
    elseif p:sub(1, 1) == "/" then
        root = "/"
        p = p:sub(2)
    end
    local out = {}
    for seg in p:gmatch("[^/]+") do
        if seg == "." then
            -- current dir: skip
        elseif seg == ".." then
            if #out > 0 and out[#out] ~= ".." then
                out[#out] = nil
            elseif root == "" then
                -- relative path with no rooted prefix: keep the ..
                out[#out + 1] = ".."
            end
            -- rooted path: a leading .. is clamped (dropped)
        else
            out[#out + 1] = seg
        end
    end
    return root .. table.concat(out, "/")
end

--- Resolve a file-api artifact path to an absolute, display-cased path.
--- Absolute inputs (drive or POSIX root) are returned as-is with slashes
--- normalized; relative inputs (including `..` for hardcoded out-of-tree
--- outputs) resolve against `build_dir` and collapse (§4.6).
--- @param raw string artifact path from the file-api target detail
--- @param build_dir string absolute build directory
--- @return string absolute path (display casing preserved)
local function resolve_artifact_path(raw, build_dir)
    local p = raw:gsub("\\", "/")
    if p:match("^%a:/") or p:sub(1, 1) == "/" then
        return collapse_path(p)
    end
    local prefix = build_dir:gsub("\\", "/"):gsub("/+$", "")
    return collapse_path(prefix .. "/" .. p)
end

--- Resolve the absolute on-disk output artifacts a build of this config
--- unit produces (cmake.md §4.6) — the module's optional `resolve_artifacts`
--- core capability (module-interface §8.4). Reads the codemodel-v2 reply for
--- `ctx.build_dir`, selects the variant's configuration, walks the
--- project-owned targets (the §4.3 filter shared with `parse_targets`), and
--- collects EVERY entry of each target's `artifacts[]` — a single target can
--- emit several files (an executable plus its `.pdb`, a shared library plus
--- its import lib). Each artifact is resolved to an absolute path in display
--- (original) casing; the compare-normalized form is derived by core.
--- Returns `nil` when no codemodel reply exists (never configured) — the
--- resolved artifact set is unknown until configure and is never guessed.
--- @param ctx { build_dir: string, config_name?: string }
--- @return string[]|nil absolute artifact paths, or nil when unknown/none
function M.resolve_artifacts(ctx)
    local build_dir = ctx and ctx.build_dir
    if not build_dir then return nil end
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local config_data = select_codemodel_config(codemodel, ctx.config_name)
    if not config_data or not config_data.targets then return nil end

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"

    -- Project-owned target filter (§4.3), identical to parse_targets.
    local project_names = {}
    if config_data.projects then
        for _, proj in ipairs(config_data.projects) do
            if proj.targetIndexes then
                for _, idx in ipairs(proj.targetIndexes) do
                    local tgt = config_data.targets[idx + 1] -- 0-based → 1-based
                    if tgt then project_names[tgt.name] = true end
                end
            end
        end
    else
        for _, tgt in ipairs(config_data.targets) do
            project_names[tgt.name] = true
        end
    end

    local artifacts = {}
    local seen = {}
    for _, tgt_ref in ipairs(config_data.targets) do
        if project_names[tgt_ref.name] and tgt_ref.jsonFile then
            local detail = read_json_file(reply_dir .. "/" .. tgt_ref.jsonFile)
            -- Only project-owned buildable targets (skip UTILITY/ALIAS, and
            -- object/interface libraries which list no artifacts).
            if detail and TARGET_TYPE_MAP[detail.type] and detail.artifacts then
                for _, art in ipairs(detail.artifacts) do
                    if art.path then
                        local abs = resolve_artifact_path(art.path, build_dir)
                        local key = abs:lower()
                        if not seen[key] then
                            seen[key] = true
                            artifacts[#artifacts + 1] = abs
                        end
                    end
                end
            end
        end
    end

    return next(artifacts) and artifacts or nil
end

--- Post-configure compiler-cache compatibility scan (core §8
--- `cache_compat_scan`, cmake §5d). After a configure that applied a launcher
--- to an MSVC-style kit, scan every target's compile flags — the same file-api
--- codemodel `compileCommandFragments` the owned compile_commands (§12.2) is
--- reconstructed from, so it covers every generator and never decodes the
--- native `compile_commands.json` — for PDB-writing debug flags (/Zi, /ZI,
--- -Zi, -ZI). The `/Z7` request only changes CMake's DEFAULT flags; a target
--- (typically a FetchContent / add_subdirectory dependency) that adds /Zi
--- itself is what this finds. ALL targets are scanned, not just
--- project-owned ones — dependencies are the point. One finding per target:
--- severity "error" for sccache (fails those compiles), "warning" for ccache
--- (compiles them uncached). A gcc/clang kit's launchers never fail an
--- uncacheable compile, so it reports clean without reading anything.
--- Advisory; spawns nothing.
--- Also reports a /Zi-style token in the configuration environment's `CL` /
--- `_CL_` (group "environment", §5d) — flags no compile command shows.
--- @param ctx { build_dir: string, tool_data?: table, compiler_cache?: { tool: string, path: string }, config_name?: string, variant?: string, configuration_env?: table<string, string> }
--- @return { scanned: boolean, reason?: string, findings: table[] }
function M.cache_compat_scan(ctx)
    local cpp = require("loomworks.cpp_compilers")
    if not (ctx and cpp.is_msvc_style(ctx.tool_data)) then
        return { scanned = true, findings = {} }
    end
    -- `CL` / `_CL_` in the configuration environment reach every compile but
    -- no compile-command data shows them (§5d / §5a): checked separately.
    local tool = ctx.compiler_cache and ctx.compiler_cache.tool
    local env_findings = cpp.pdb_env_findings(ctx.configuration_env, tool)
    local build_dir = ctx.build_dir
    local codemodel = build_dir and find_file_api_reply(build_dir, "codemodel", 2) or nil
    if not codemodel or not codemodel.configurations then
        return { scanned = false, findings = env_findings,
            reason = "no CMake file-api codemodel reply for this build" }
    end
    local cfg = select_codemodel_config(codemodel, ctx.variant or ctx.config_name)
    if not cfg or not cfg.targets then
        return { scanned = false, findings = env_findings,
            reason = "the CMake codemodel reply lists no targets for this configuration" }
    end

    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    local source_root = codemodel.paths and codemodel.paths.source or nil
    local acc = {}
    for _, tref in ipairs(cfg.targets) do
        local detail = tref.jsonFile and read_json_file(reply_dir .. "/" .. tref.jsonFile)
        if detail and detail.compileGroups then
            local sources = detail.sources or {}
            for _, cg in ipairs(detail.compileGroups) do
                local tokens = {}
                for _, f in ipairs(cg.compileCommandFragments or {}) do
                    if type(f.fragment) == "string" then
                        for _, tok in ipairs(tokenize_fragment(f.fragment)) do
                            for _, ex in ipairs(expand_token(tok)) do tokens[#tokens + 1] = ex end
                        end
                    end
                end
                local flag = cpp.pdb_debug_flag(tokens)
                if flag then
                    for _, si in ipairs(cg.sourceIndexes or {}) do
                        local src = sources[si + 1] -- 0-based
                        local abs = src and type(src.path) == "string"
                            and abs_source_path(src.path, source_root) or nil
                        cpp.pdb_scan_add(acc, detail.name or tref.name or "?", flag, abs)
                    end
                end
            end
        end
    end
    local findings = cpp.pdb_scan_findings(acc, tool)
    vim.list_extend(findings, env_findings)
    return { scanned = true, findings = findings }
end

--- Iterate every compiled source of the selected configuration's targets,
--- invoking `fn(cg, compiler, abs)` once per source (each compileGroup ×
--- its sourceIndexes), resolving the per-language compiler with the same
--- file-api → kit → cl.exe fallback the generator uses. `compiler_by_lang`
--- keys off cmake's own language token ("C", "CXX", …) — the same token
--- compileGroups carry, so no canonicalization is needed. Shared by
--- `_build_cc_entries` (full DB) and `compile_command_for` (per-file query)
--- so both select the identical compileGroup, compiler, and resolved path
--- for any given source — the entries cannot drift (§12.6).
--- @param codemodel table parsed codemodel-v2 reply
--- @param target_details table<string, table> jsonFile → parsed target detail
--- @param toolchains table|nil parsed toolchains-v1 reply
--- @param source_root string|nil codemodel.paths.source
--- @param variant string|nil active configuration name to select
--- @param opts { compiler?: string } fallback compiler when a language
---        has no toolchain entry
--- @param fn fun(cg: table, compiler: string, abs: string)
local function for_each_compiled_source(codemodel, target_details, toolchains, source_root, variant, opts, fn)
    local compiler_by_lang = compiler_map(toolchains)
    local cfg = select_codemodel_config(codemodel, variant)
    if not cfg or not cfg.targets then return end

    for _, tref in ipairs(cfg.targets) do
        local detail = tref.jsonFile and target_details[tref.jsonFile]
        if detail and detail.compileGroups then
            local sources = detail.sources or {}
            for _, cg in ipairs(detail.compileGroups) do
                -- Fallback chain: file-api toolchain → kit compiler → cl.exe.
                local compiler = compiler_by_lang[cg.language] or opts.compiler or "cl.exe"
                for _, si in ipairs(cg.sourceIndexes or {}) do
                    local src = sources[si + 1] -- file-api indexes are 0-based
                    if src and type(src.path) == "string" then
                        fn(cg, compiler, abs_source_path(src.path, source_root))
                    end
                end
            end
        end
    end
end

--- Create incremental compiled-source-entry state (§12.2). Mirrors
--- `for_each_compiled_source`'s iteration exactly (targets → compileGroups →
--- sourceIndexes, same compiler fallback and prefix caching) so the async
--- generator can build entries a bounded number of targets per turn without
--- drifting from the synchronous result.
--- @return table state ({ entries } is the accumulated result)
local function cc_entries_new(codemodel, target_details, toolchains, source_root, variant, build_dir, opts)
    opts = opts or {}
    local st = {
        entries = {},
        prefix_cache = {},
        compiler_by_lang = compiler_map(toolchains),
        cfg = select_codemodel_config(codemodel, variant),
        target_details = target_details,
        source_root = source_root,
        build_dir = build_dir,
        opts = opts,
        ti = 0,
        done = false,
    }
    if not st.cfg or not st.cfg.targets then st.done = true end
    return st
end

--- Advance the compiled-source-entry build by up to `max_targets` targets
--- (nil = all remaining). Returns true when the whole target list is consumed.
--- @param st table from `cc_entries_new`
--- @param max_targets integer|nil
--- @return boolean done
local function cc_entries_step(st, max_targets)
    if st.done then return true end
    local cfg = st.cfg
    local processed = 0
    while st.ti < #cfg.targets and (not max_targets or processed < max_targets) do
        st.ti = st.ti + 1
        local tref = cfg.targets[st.ti]
        local detail = tref.jsonFile and st.target_details[tref.jsonFile]
        if detail and detail.compileGroups then
            local sources = detail.sources or {}
            for _, cg in ipairs(detail.compileGroups) do
                -- Fallback chain: file-api toolchain → kit compiler → cl.exe.
                local compiler = st.compiler_by_lang[cg.language] or st.opts.compiler or "cl.exe"
                local prefix = st.prefix_cache[cg]
                if not prefix then
                    prefix = cg_argv_prefix(cg, compiler)
                    st.prefix_cache[cg] = prefix
                end
                for _, si in ipairs(cg.sourceIndexes or {}) do
                    local src = sources[si + 1] -- file-api indexes are 0-based
                    if src and type(src.path) == "string" then
                        st.entries[#st.entries + 1] = render_cc_entry_with_prefix(
                            prefix, abs_source_path(src.path, st.source_root), st.build_dir)
                    end
                end
            end
        end
        processed = processed + 1
    end
    if st.ti >= #cfg.targets then st.done = true end
    return st.done
end

--- Build the `compile_commands.json` entry list from already-parsed
--- file-api data. Pure (no cmake invocation) so it can be unit-tested
--- against fixture JSON. One entry per source across every target's
--- compileGroups. Byte-identical to the async generator (shared stepper).
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
    local st = cc_entries_new(codemodel, target_details, toolchains, source_root, variant, build_dir, opts)
    while not cc_entries_step(st, nil) do end
    return st.entries
end

--- Build the Tier-1 header-attribution index (§12.3) from parsed file-api
--- data. Pure — no disk access. For the selected configuration it records,
--- per project-owned target with compileGroups: its display `name`, its
--- compileGroup keyed by language, its primary language, its source-directory
--- set, its total source count (tie-break weight), and `sample_by_lang` (one
--- representative *compiled* source per language, for provenance reporting in
--- §12.6). It also records a dir → owning-targets map (for nearest-ancestor
--- tie-breaks) and a listed-header → target map (headers named directly in a
--- target's `sources`). `source_dirs` is the de-duplicated list of every target
--- source directory, sorted longest-first so the first ancestor match is the
--- nearest one.
--- @param codemodel table
--- @param target_details table<string, table>
--- @param source_root string|nil
--- @param variant string|nil
--- @return { targets: table, dir_owners: table, source_dirs: string[], listed: table }
--- Create incremental header-attribution-index state (§12.3). The per-target
--- body matches the synchronous build exactly; the final longest-first sort of
--- `source_dirs` runs once when the last target is consumed. Lets the async
--- generator build the index a bounded number of targets per turn.
--- @return table state ({ index } is the accumulated result)
local function attr_index_new(codemodel, target_details, source_root, variant)
    local st = {
        index = { targets = {}, dir_owners = {}, source_dirs = {}, listed = {} },
        cfg = select_codemodel_config(codemodel, variant),
        target_details = target_details,
        source_root = source_root,
        dir_seen = {},
        ti = 0,
        done = false,
    }
    if not st.cfg or not st.cfg.targets then st.done = true end
    return st
end

--- Advance the header-attribution index by up to `max_targets` targets
--- (nil = all remaining). Sorts `source_dirs` and returns true when done.
--- @param st table from `attr_index_new`
--- @param max_targets integer|nil
--- @return boolean done
local function attr_index_step(st, max_targets)
    if st.done then return true end
    local index = st.index
    local cfg = st.cfg
    local source_root = st.source_root
    local processed = 0
    while st.ti < #cfg.targets and (not max_targets or processed < max_targets) do
        st.ti = st.ti + 1
        local tref = cfg.targets[st.ti]
        local detail = tref.jsonFile and st.target_details[tref.jsonFile]
        if detail and detail.compileGroups then
            local id = detail.id or detail.name or tostring(tref.jsonFile)
            local sources = detail.sources or {}

            local groups_by_lang, primary_lang = {}, nil
            -- One representative compiled (non-header) source per language, for
            -- the §12.6 provenance `source` field. Cheap: first non-header
            -- source index of the first group in that language wins.
            local sample_by_lang = {}
            for _, cg in ipairs(detail.compileGroups) do
                if cg.language and not groups_by_lang[cg.language] then
                    groups_by_lang[cg.language] = cg
                    primary_lang = primary_lang or cg.language
                end
                if cg.language and not sample_by_lang[cg.language] then
                    for _, si in ipairs(cg.sourceIndexes or {}) do
                        local src = sources[si + 1] -- file-api indexes are 0-based
                        if src and type(src.path) == "string"
                            and not is_header(src.path) then
                            sample_by_lang[cg.language] =
                                abs_source_path(src.path, source_root)
                            break
                        end
                    end
                end
            end

            local source_dirs = {} -- normlower → display dir
            for _, src in ipairs(sources) do
                if type(src.path) == "string" then
                    local abs = abs_source_path(src.path, source_root)
                    if is_header(abs) then
                        local key = norm_path(abs):lower()
                        if not index.listed[key] then
                            index.listed[key] = { id = id, path = norm_path(abs) }
                        end
                    else
                        local d = dir_of(abs)
                        source_dirs[d:lower()] = d
                    end
                end
            end

            index.targets[id] = {
                id = id,
                name = detail.name or id,
                groups_by_lang = groups_by_lang,
                primary_lang = primary_lang,
                source_count = #sources,
                source_dirs = source_dirs,
                sample_by_lang = sample_by_lang,
            }
            for dl, d in pairs(source_dirs) do
                local rec = index.dir_owners[dl]
                if not rec then
                    rec = { disp = d, owners = {} }
                    index.dir_owners[dl] = rec
                end
                rec.owners[#rec.owners + 1] = id
                if not st.dir_seen[dl] then
                    st.dir_seen[dl] = true
                    index.source_dirs[#index.source_dirs + 1] = dl
                end
            end
        end
        processed = processed + 1
    end

    if st.ti >= #cfg.targets then
        -- Longest directory first → first ancestor hit is the nearest ancestor.
        table.sort(index.source_dirs, function(a, b)
            if #a ~= #b then return #a > #b end
            return a < b
        end)
        st.done = true
    end
    return st.done
end

function M._target_attribution_index(codemodel, target_details, source_root, variant)
    local st = attr_index_new(codemodel, target_details, source_root, variant)
    while not attr_index_step(st, nil) do end
    return st.index
end

--- Attribute a single file path to a target id (§12.3): a listed path uses its
--- listing target; otherwise the target whose source directory is the nearest
--- ancestor (longest prefix on path boundaries), breaking ties by most sources
--- then lexically-first id. Also returns how the match was made — `"listed"` or
--- `"directory"` — for provenance reporting (§12.6). nil when unattributable.
--- @param index table from `_target_attribution_index`
--- @param path string file path (header or otherwise)
--- @return string|nil target id
--- @return "listed"|"directory"|nil via how the match was made (nil when unattributed)
local function attribute_header(index, path)
    local pl = norm_path(path):lower()
    local listed = index.listed[pl]
    if listed then return listed.id, "listed" end
    for _, dl in ipairs(index.source_dirs) do -- longest first
        if pl == dl or pl:sub(1, #dl + 1) == dl .. "/" then
            local rec = index.dir_owners[dl]
            local best
            for _, oid in ipairs(rec.owners) do
                local t = index.targets[oid]
                if not best then
                    best = t
                elseif t.source_count > best.source_count then
                    best = t
                elseif t.source_count == best.source_count and t.id < best.id then
                    best = t
                end
            end
            if best then return best.id, "directory" end
            return nil
        end
    end
    return nil
end

--- Enumerate candidate header files by a bounded directory listing of the
--- targets' source directories (§12.3). This is a filesystem dir listing,
--- NOT an include-scan or compiler run — Tier-1. Skips build/vendor/hidden
--- dirs and bounds recursion depth. Listed headers (which may live outside a
--- scanned subtree) are always included. `opts.scandir(dir) → {{name,type},…}`
--- is injectable for tests. Returns absolute (display) header paths.
--- @param index table
--- @param opts? { scandir?: fun(dir: string): table[] }
--- @return string[]
local HEADER_WALK_SKIP =
    { build = true, _deps = true, cmakefiles = true, node_modules = true }
local HEADER_WALK_MAX_DEPTH = 16

--- Directory listing for the header walk (`opts.scandir` injectable for tests).
--- @param st table walk state
--- @param dir string
--- @return { name: string, type: string|nil }[]
local function header_walk_list(st, dir)
    if st.scandir then return st.scandir(dir) or {} end
    local handle = uv.fs_scandir(dir)
    if not handle then return {} end
    local res = {}
    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then break end
        res[#res + 1] = { name = name, type = ftype }
    end
    return res
end

--- Create header-walk state (§12.3). The recursive scan is turned into an
--- explicit work-stack of directories so the async generator can pop a bounded
--- number per scheduled turn instead of descending the whole tree in one
--- synchronous pass. Seeded with the targets' source directories at depth 0.
--- @param index table from `_target_attribution_index`
--- @param opts? { scandir?: fun(dir: string): table[] }
--- @return table walk state
local function header_walk_new(index, opts)
    opts = opts or {}
    local st = { index = index, scandir = opts.scandir, out = {}, seen = {}, stack = {} }
    for _, dl in ipairs(index.source_dirs) do
        local rec = index.dir_owners[dl]
        if rec then st.stack[#st.stack + 1] = { dir = rec.disp, depth = 0 } end
    end
    return st
end

--- Advance the header walk by popping at most `max_dirs` directories from the
--- work-stack (§12.3). Visits the same directory set the recursive walk did —
--- same SKIP list, depth bound, and `seen` dedupe — so the discovered header
--- set is identical regardless of traversal order. Returns true when the stack
--- is exhausted.
--- @param st table walk state from `header_walk_new`
--- @param max_dirs integer directories to process this slice
--- @return boolean done
local function header_walk_step(st, max_dirs)
    local processed = 0
    while #st.stack > 0 and processed < max_dirs do
        local node = table.remove(st.stack) -- LIFO; order is irrelevant to the set
        processed = processed + 1
        if node.depth <= HEADER_WALK_MAX_DEPTH then
            local dl = norm_path(node.dir):lower()
            if not st.seen[dl] then
                st.seen[dl] = true
                for _, e in ipairs(header_walk_list(st, node.dir)) do
                    local full = norm_path(node.dir) .. "/" .. e.name
                    if e.type == "directory" then
                        local base = e.name:lower()
                        if base:sub(1, 1) ~= "." and not HEADER_WALK_SKIP[base] then
                            st.stack[#st.stack + 1] = { dir = full, depth = node.depth + 1 }
                        end
                    elseif e.type == "file" or e.type == nil then
                        if is_header(e.name) then
                            local k = full:lower()
                            if not st.out[k] then st.out[k] = full end
                        end
                    end
                end
            end
        end
    end
    return #st.stack == 0
end

--- Finalize the walk: fold in listed headers (which may live outside a scanned
--- subtree) and return the de-duplicated absolute (display) header paths.
--- @param st table walk state
--- @return string[]
local function header_walk_result(st)
    for _, listed in pairs(st.index.listed) do
        local k = norm_path(listed.path):lower()
        if not st.out[k] then st.out[k] = listed.path end
    end
    local arr = {}
    for _, p in pairs(st.out) do arr[#arr + 1] = p end
    return arr
end

-- Header candidate enumeration (§12.3) is driven directly by the async
-- generator via `header_walk_new` / `header_walk_step` / `header_walk_result`
-- (bounded slices). A synchronous whole-tree pass is intentionally not exposed
-- here — the UI path must never walk the tree in one go (§12.2).

--- Select the compileGroup used to render a header attributed to target `t`
--- (§12.3): the target's C++ group when present, else its C group, else its
--- primary language group. nil when the target has no usable group. Shared by
--- the header generator and the per-file query so both render identical flags.
--- @param t table target record from `_target_attribution_index`
--- @return table|nil compileGroup
--- Pick the compileGroup used for a header attributed to target `t` (§12.3).
--- Target-level choice, independent of the header's extension: prefer the
--- target's C++ group (safe superset for clangd; `.h` in C++ is common), else
--- C, else the target's primary language group. nil when the target has none.
local function header_group(t)
    local g = t.groups_by_lang
    return g.CXX or g.C or (t.primary_lang and g[t.primary_lang]) or nil
end

--- Create incremental header-entry state (§12.3). Sorts the header candidates
--- once up front (deterministic order), then attributes/renders them in
--- batches. Byte-identical to the one-shot build (shared stepper).
--- @return table state ({ entries } is the accumulated result)
local function header_entries_new(index, compiler_by_lang, header_paths, build_dir, opts)
    opts = opts or {}
    compiler_by_lang = compiler_by_lang or {}
    local sorted = {}
    for _, p in ipairs(header_paths) do sorted[#sorted + 1] = p end
    table.sort(sorted, function(a, b)
        return norm_path(a):lower() < norm_path(b):lower()
    end)
    return {
        index = index,
        compiler_by_lang = compiler_by_lang,
        build_dir = build_dir,
        opts = opts,
        sorted = sorted,
        entries = {},
        emitted = {},
        hi = 0,
        done = (#sorted == 0),
    }
end

--- Advance header-entry rendering by up to `max_headers` headers (nil = all
--- remaining). The per-header attribution (`attribute_header`) is the hot loop
--- on a large tree, so the generator slices it. Returns true when done.
--- @param st table from `header_entries_new`
--- @param max_headers integer|nil
--- @return boolean done
local function header_entries_step(st, max_headers)
    if st.done then return true end
    local index = st.index
    local processed = 0
    while st.hi < #st.sorted and (not max_headers or processed < max_headers) do
        st.hi = st.hi + 1
        local path = st.sorted[st.hi]
        local disp = norm_path(path)
        local key = disp:lower()
        if not st.emitted[key] then
            local id = attribute_header(index, path)
            local t = id and index.targets[id]
            if t then
                local cg = header_group(t)
                if cg then
                    local compiler = st.compiler_by_lang[cg.language]
                        or st.opts.compiler or "cl.exe"
                    st.entries[#st.entries + 1] =
                        render_header_entry(cg, compiler, disp, st.build_dir)
                    st.emitted[key] = true
                end
            end
        end
        processed = processed + 1
    end
    if st.hi >= #st.sorted then st.done = true end
    return st.done
end

--- Build `compile_commands.json` entries for headers (§12.3). Pure. Each header
--- is attributed to a target (`attribute_header`) and rendered with that
--- target's `header_group` compileGroup. Deterministic order, each header at
--- most once; unattributable headers omitted. Byte-identical to the async
--- generator (shared stepper).
--- @param index table from `_target_attribution_index`
--- @param compiler_by_lang table<string, string> language token → compiler
--- @param header_paths string[] candidate header paths
--- @param build_dir string each entry's `directory`
--- @param opts? { compiler?: string } fallback compiler
--- @return table[] entries
function M._build_header_entries(index, compiler_by_lang, header_paths, build_dir, opts)
    local st = header_entries_new(index, compiler_by_lang, header_paths, build_dir, opts)
    while not header_entries_step(st, nil) do end
    return st.entries
end

--- Per-slice time budget (nanoseconds) for the async generator. Each scheduled
--- turn runs bounded work until this elapses, then yields with `vim.schedule`.
local CC_SLICE_BUDGET_NS = 5 * 1e6 -- ~5ms
--- Directories popped from the header work-stack per inner loop iteration.
local CC_WALK_DIRS_PER_STEP = 24
--- Entries encoded+written per inner loop iteration of the write phase.
local CC_WRITE_BATCH = 64
--- Targets processed per inner loop iteration of the entries/index build.
local CC_ENTRIES_TARGETS_PER_STEP = 16
--- Headers attributed+rendered per inner loop iteration of the headers phase.
local CC_HEADERS_PER_STEP = 128

--- Reconstruct a `compile_commands.json` from the cmake file-api and write it
--- into `out_dir` (§12), ASYNCHRONOUSLY and YIELDING (spec §12.2). The heavy
--- reconstruction — reading the per-target file-api replies, the Tier-1 header
--- directory walk (§12.3), and the entry-by-entry stream — is sliced across
--- scheduled turns (time-boxed to `CC_SLICE_BUDGET_NS`) so a large project
--- never freezes the UI mid-generation. The stream is written to a temp file
--- and atomically renamed on completion, so clangd never observes a
--- half-written database and the previous one stays readable until the swap.
--- The project build directory is never written to.
---
--- `done(changed, count)` fires exactly once when the run settles: `changed`
--- is true iff the database was actually (re)written; `count` is the entry
--- count on success, nil when there was no codemodel reply (never configured).
--- @param build_dir string absolute build directory (holds the file-api reply)
--- @param out_dir string loomworks-owned directory to write into
--- @param opts? { variant?: string, config_name?: string, compiler?: string, scandir?: fun(dir: string): table[] }
--- @param done? fun(changed: boolean, count: integer|nil)
function M.generate_compile_commands_async(build_dir, out_dir, opts, done)
    opts = opts or {}
    done = done or function() end

    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then
        vim.schedule(function() done(false, nil) end)
        return
    end

    local variant = opts.variant or opts.config_name
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
    local cfg = select_codemodel_config(codemodel, variant)
    local jsonfiles = {}
    if cfg and cfg.targets then
        for _, tref in ipairs(cfg.targets) do
            if tref.jsonFile then jsonfiles[#jsonfiles + 1] = tref.jsonFile end
        end
    end

    -- Per-phase batch sizes, overridable by tests via `M._cc_slice_params`
    -- (e.g. force batch=1 to exercise cross-turn accumulation) — nil = default.
    local sp = M._cc_slice_params or {}
    local ENT_STEP = sp.entries or CC_ENTRIES_TARGETS_PER_STEP
    local HDR_STEP = sp.headers or CC_HEADERS_PER_STEP

    -- Mutable state carried across slices.
    local target_details = {}
    local toolchains, source_root, entries, index, walk_st, writer
    local ent_st, attr_st          -- incremental entries + attribution-index builders
    local hdr_st, hdr_prepped      -- incremental header-entry builder + its one-time prep
    local ti, wi = 0, 0
    local phase = "read" -- read → entries → walk → headers → write → (finish)

    local function finish_ok(count)
        done(count ~= nil, count)
    end

    local function slice()
        local start = uv.hrtime()
        -- `stop` suppresses the reschedule when the run has handed off to the
        -- async finish (rename) or has otherwise settled inside this slice.
        local stop = false
        -- Guard the whole slice: a throw in any phase must still settle `done`
        -- (and never leave the single-flight registry stuck for this out_dir).
        local ok, err = pcall(function()
        while (uv.hrtime() - start) < CC_SLICE_BUDGET_NS do
            if phase == "read" then
                -- (b) Per-target JSON reads — a few per slice (disk-bound).
                ti = ti + 1
                if ti > #jsonfiles then
                    toolchains = find_file_api_reply(build_dir, "toolchains", 1)
                    source_root = codemodel.paths and codemodel.paths.source or nil
                    phase = "entries"
                else
                    local jf = jsonfiles[ti]
                    if not target_details[jf] then
                        local d = read_json_file(reply_dir .. "/" .. jf)
                        if d then target_details[jf] = d end
                    end
                end
            elseif phase == "entries" then
                -- Compiled-source entries + the header-attribution index, built
                -- a bounded batch of targets per turn (§12.2) — both were
                -- previously one synchronous burst over every target/source.
                if not ent_st then
                    ent_st = cc_entries_new(
                        codemodel, target_details, toolchains, source_root, variant, build_dir, opts)
                    attr_st = attr_index_new(
                        codemodel, target_details, source_root, variant)
                end
                if not cc_entries_step(ent_st, ENT_STEP) then
                    -- entries not finished; keep going next iteration
                elseif not attr_index_step(attr_st, ENT_STEP) then
                    -- entries done, index still building
                else
                    entries = ent_st.entries
                    index = attr_st.index
                    walk_st = header_walk_new(index, opts)
                    phase = "walk"
                end
            elseif phase == "walk" then
                -- (a) The Tier-1 header directory walk — bounded dirs per turn.
                if header_walk_step(walk_st, CC_WALK_DIRS_PER_STEP) then
                    phase = "headers"
                end
            elseif phase == "headers" then
                -- Attribute discovered headers (excluding compiled sources) and
                -- append their entries — the per-header attribution is sliced a
                -- bounded batch per turn (§12.2) — then open the stream.
                if not hdr_prepped then
                    local compiler_by_lang = compiler_map(toolchains)
                    local compiled = {}
                    for _, e in ipairs(entries) do compiled[norm_path(e.file):lower()] = true end
                    local headers = {}
                    for _, p in ipairs(header_walk_result(walk_st)) do
                        if not compiled[norm_path(p):lower()] then headers[#headers + 1] = p end
                    end
                    hdr_st = header_entries_new(index, compiler_by_lang, headers, build_dir, opts)
                    hdr_prepped = true
                elseif not header_entries_step(hdr_st, HDR_STEP) then
                    -- header entries still building
                else
                    vim.list_extend(entries, hdr_st.entries)
                    io_mod.ensure_dir(out_dir)
                    local w, werr = cc_writer_open(out_dir .. "/compile_commands.json")
                    if not w then
                        require("loomworks.log").default():warn(
                            "cmake: compile_commands write failed: %s", werr or "?")
                        stop = true
                        done(false, nil)
                        return
                    end
                    writer = w
                    phase = "write"
                end
            elseif phase == "write" then
                -- (c) The streaming write — encode+write entries in batches.
                local n = 0
                while wi < #entries and n < CC_WRITE_BATCH
                    and (uv.hrtime() - start) < CC_SLICE_BUDGET_NS do
                    wi = wi + 1
                    cc_writer_put(writer, entries[wi])
                    n = n + 1
                end
                if wi >= #entries then
                    local total = #entries
                    stop = true
                    -- Atomic publish (async rename). Only on a clean swap is the
                    -- database considered (re)written (changed = true).
                    cc_writer_finish(writer, function(okk)
                        finish_ok(okk and total or nil)
                    end)
                    return -- finish is asynchronous; do not re-schedule
                end
            end
        end
        end)
        if not ok then
            -- A phase threw: log, clean up any open temp handle, and settle as
            -- "no change" so `refresh_generated_cc` clears the single-flight slot.
            require("loomworks.log").default():warn(
                "cmake: compile_commands generation error: %s", tostring(err))
            if writer then
                pcall(uv.fs_close, writer.fd)
                pcall(uv.fs_unlink, writer.tmp)
            end
            done(false, nil)
            return
        end
        if not stop then vim.schedule(slice) end
    end

    -- Start on the next tick so the caller is never blocked, even for the
    -- first slice (§12.2 — reconstruction never runs inline).
    vim.schedule(slice)
end

--- Synchronous convenience over `generate_compile_commands_async`: drives the
--- async generator to completion via `vim.wait` and returns the entry count
--- (nil when there was no codemodel reply). Not used on the runtime UI path —
--- there generation flows through the async seam (`refresh_generated_cc`). Kept
--- for direct callers/tests that want a one-shot synchronous result; the output
--- is byte-identical to the async path (same helpers).
--- @param build_dir string absolute build directory (holds the file-api reply)
--- @param out_dir string loomworks-owned directory to write into
--- @param opts? { variant?: string, config_name?: string, compiler?: string, scandir?: fun(dir: string): table[] }
--- @return integer|nil count of entries written, nil when no codemodel reply
function M.generate_compile_commands(build_dir, out_dir, opts)
    local result, finished = nil, false
    M.generate_compile_commands_async(build_dir, out_dir, opts, function(_, count)
        result = count
        finished = true
    end)
    vim.wait(30000, function() return finished end, 5)
    return result
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

--- In-flight generation registry for single-flight per out_dir (§12.2). Keyed
--- by the normalized (lowercased) out_dir. Each record collects every caller's
--- `done` and a `dirty` flag set when a fresh trigger lands mid-run.
--- @type table<string, { dirty: boolean, dones: fun(changed: boolean)[] }>
local _cc_in_progress = {}

--- Whether the reply index is newer than the generated file (or the file is
--- absent) — the cheap synchronous freshness gate (§12.4). Returns nil when
--- there is no reply index at all (never configured / no work possible).
--- @param build_dir string
--- @param out_dir string
--- @return boolean|nil stale (nil ⇒ no reply index)
local function cc_is_stale(build_dir, out_dir)
    local reply_mtime = file_api_index_mtime(build_dir)
    if not reply_mtime then return nil end
    local out_stat = uv.fs_stat(out_dir .. "/compile_commands.json")
    local out_mtime = out_stat and out_stat.mtime and out_stat.mtime.sec or nil
    if out_mtime and reply_mtime <= out_mtime then return false end
    return true
end

--- Freshness-gated regeneration of the owned database (§12.4). The mtime GUARD
--- is cheap and SYNCHRONOUS (a couple of stats + one small dir scan); only when
--- it decides to rebuild is the heavy reconstruction dispatched — and that runs
--- ASYNCHRONOUSLY and SINGLE-FLIGHT per out_dir (§12.2), never blocking the UI.
---
--- `done(changed)` is invoked once when the request settles: false when the DB
--- was already fresh (or there is nothing to generate), true iff it was
--- actually (re)written. Overlapping requests for the same out_dir coalesce
--- onto the in-flight run (their `done`s all fire on settle) and mark it dirty;
--- on settle a dirty run re-checks the guard and regenerates exactly once more
--- if still stale.
---
--- Return value is advisory — whether a regen was needed/scheduled (true) vs
--- the DB was fresh / no reply index (false). Callers must not treat it as
--- "regenerated now"; that is what `done(changed)` reports.
--- @param build_dir string
--- @param out_dir string
--- @param opts? { variant?: string, config_name?: string, compiler?: string, scandir?: fun(dir: string): table[] }
--- @param done? fun(changed: boolean)
--- @return boolean scheduled whether a regeneration was needed and scheduled
function M.refresh_generated_cc(build_dir, out_dir, opts, done)
    done = done or function() end
    local stale = cc_is_stale(build_dir, out_dir)
    if not stale then
        -- Fresh, or no reply index: nothing to (re)write. Report on the next
        -- tick so callers observe a uniform async completion contract.
        vim.schedule(function() done(false) end)
        return false
    end

    local key = norm_path(out_dir):lower()
    local rec = _cc_in_progress[key]
    if rec then
        -- Already generating this out_dir: coalesce. Append our `done`, and
        -- mark dirty so the run re-checks freshness on settle (§12.2).
        rec.dirty = true
        rec.dones[#rec.dones + 1] = done
        return true
    end

    rec = { dirty = false, dones = { done } }
    _cc_in_progress[key] = rec
    local any_changed = false

    local function settle()
        _cc_in_progress[key] = nil
        for _, d in ipairs(rec.dones) do pcall(d, any_changed) end
    end

    local function run()
        M.generate_compile_commands_async(build_dir, out_dir, opts, function(changed)
            if changed then any_changed = true end
            -- A trigger landed mid-run: re-run the mtime guard and regenerate
            -- exactly once more, only if still stale. `dirty` is consumed here
            -- (one-shot) so a still-stale guard can never loop.
            if rec.dirty then
                rec.dirty = false
                if cc_is_stale(build_dir, out_dir) == true then
                    run()
                    return
                end
            end
            settle()
        end)
    end
    run()
    return true
end

--- §12.4 trigger entry point (core §8.4 optional module hook). Regenerate the
--- owned clangd database for a build dir if stale — asynchronous and
--- non-blocking (§8.4). Core calls this after a successful configure/build and
--- on a reply-dir watch signal. `ctx`: `build_dir`, `workspace_root`, and
--- optionally `variant` / `compiler`. `done(changed)` forwards the completion
--- signal so core can re-resolve LSP wiring when the DB was newly written.
--- @param ctx { build_dir: string, workspace_root: string, variant?: string, compiler?: string }
--- @param done? fun(changed: boolean)
function M.refresh_lsp_database(ctx, done)
    done = done or function() end
    if type(ctx) ~= "table" then vim.schedule(function() done(false) end); return end
    local build_dir, ws_root = ctx.build_dir, ctx.workspace_root
    if type(build_dir) ~= "string" or type(ws_root) ~= "string" then
        vim.schedule(function() done(false) end)
        return
    end
    local out_dir = generated_cc_dir(ws_root, build_dir)
    M.refresh_generated_cc(build_dir, out_dir, {
        variant = ctx.variant,
        compiler = ctx.compiler,
    }, done)
end

--- §12.4 (core §8.4 optional module hook). The file-api reply directory
--- whose changes should re-trigger `refresh_lsp_database`, or nil when the
--- build dir has no reply directory yet. `ctx`: `build_dir`.
--- @param ctx { build_dir: string }
--- @return string|nil
function M.lsp_database_watch_path(ctx)
    if type(ctx) ~= "table" or type(ctx.build_dir) ~= "string" then return nil end
    local reply = ctx.build_dir .. "/.cmake/api/v1/reply"
    if not uv.fs_stat(reply) then return nil end
    return reply
end

--- §12.6 (core §8.4 optional hook). Redetermine the compile command the owned
--- clangd database uses (or would use) for `file` under `ctx.build_dir`,
--- WITHOUT decoding the generated `compile_commands.json` — it reads the same
--- file-api replies §12.2/§12.3 build the database from and renders the entry
--- through the shared `render_cc_entry`, so the command bytes are byte-for-byte
--- the DB entry for that file. The own-vs-borrowed decision is made strictly on
--- whether the file has its own compiled entry, never on file type:
---   * the file has its own compiled entry (a source in a compileGroup) → that
---     target's own compileGroup, selected by source index (its exact flags);
---     `origin = { kind = "own" }`;
---   * the file has NO compiled entry (a header, or any other file) → borrowed
---     via `attribute_header` (§12.3), rendered with that target's compileGroup
---     chosen at the target level by `header_group`; `origin = { kind =
---     "attributed", target, via, source }`;
---   * anything no target claims (outside every source tree and not listed)
---     → nil (unattributable).
--- The additive `origin` is attached AFTER `render_cc_entry`, so that shared
--- renderer and the full-DB generator (§12.2/§12.3) stay origin-free — a
--- generated DB entry never carries `origin`.
--- @param ctx { build_dir: string, workspace_root?: string, variant?: string, compiler?: string }
--- @param file string absolute source or header path
--- @return { directory: string, file: string, arguments: string[], origin: loomworks.CompileCommandOrigin }|nil
function M.compile_command_for(ctx, file)
    if type(ctx) ~= "table" or type(ctx.build_dir) ~= "string" then return nil end
    if type(file) ~= "string" or file == "" then return nil end

    local build_dir = ctx.build_dir
    local codemodel = find_file_api_reply(build_dir, "codemodel", 2)
    if not codemodel or not codemodel.configurations then return nil end

    local variant = ctx.variant
    local reply_dir = build_dir .. "/.cmake/api/v1/reply"
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
    local opts = { compiler = ctx.compiler }
    local target_norm = norm_path(file):lower()

    -- Compiled TU: the same scan _build_cc_entries walks. The first source
    -- whose resolved path matches wins, rendered from its own compileGroup;
    -- the entry uses the file-api's own resolved path (not the caller's) so it
    -- is byte-identical to the generated entry.
    local match
    for_each_compiled_source(codemodel, target_details, toolchains, source_root, variant, opts,
        function(cg, compiler, abs)
            if not match and norm_path(abs):lower() == target_norm then
                match = render_cc_entry(cg, compiler, abs, build_dir)
            end
        end)
    if match then
        -- Own entry: exact per-file command. Provenance is attached here, not
        -- in render_cc_entry, so the generator stays origin-free.
        match.origin = { kind = "own" }
        return match
    end

    -- No compiled entry (a header, or any other non-compiled file): borrow the
    -- command via attribution (§12.3). The gate is entry-presence, not a header
    -- test — a header listed in CMakeLists appears in the target's `sources` but
    -- in no compileGroup, so it lands here too. A file no target claims → nil.
    local index = M._target_attribution_index(codemodel, target_details, source_root, variant)
    local id, via = attribute_header(index, file)
    local t = id and index.targets[id]
    if not t then return nil end
    local cg = header_group(t)
    if not cg then return nil end
    local compiler = compiler_map(toolchains)[cg.language] or ctx.compiler or "cl.exe"
    local entry = render_header_entry(cg, compiler, norm_path(file), build_dir)
    -- Provenance attached after render_cc_entry so the shared renderer / the
    -- full-DB generator never emit `origin`.
    entry.origin = {
        kind = "attributed",
        target = t.name or id,
        via = via,
        source = t.sample_by_lang and t.sample_by_lang[cg.language] or nil,
    }
    return entry
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

    -- §12: loomworks owns the clangd database for EVERY cmake generator.
    -- Point clangd at our generated directory unless the active configuration
    -- opts out with `compile_commands_generated = false` (the escape hatch),
    -- or a `compile_commands_from` redirect (from_redirect) already resolved
    -- build_dir to another configuration's database (which owns its own).
    local clangd_cc_dir = build_dir
    if build_dir and not from_redirect then
        local active_cfg = active_pp and active_pp.configuration and active_pp:configuration()
        local cfg_mc = active_cfg and active_cfg.module_config or nil

        -- Generated unless the config explicitly turned it off.
        local generated = not (cfg_mc and cfg_mc.compile_commands_generated == false)

        if generated then
            local out_dir = generated_cc_dir(ws.root, build_dir)
            local variant = active_cfg
                and (cfg_mc and cfg_mc.variant or active_cfg.base_name) or nil
            -- Resolve the compiler from tool_data, falling back to the active
            -- profile's tool (SDK-only profiles resolve tools lazily).
            local compiler = nil
            do
                local td = project.tool_data
                if (not td or not td.compiler_path) and active_profile and active_profile.tool_for then
                    local tref = active_profile:tool_for(project.type)
                    td = tref and tref.data or td
                end
                compiler = td and td.compiler_path or nil
            end
            -- SCHEDULE the mtime-gated (thrash-proof) regeneration through the
            -- shared seam also used by the task-completion and reply-dir-watch
            -- triggers, then return the generated dir immediately (§12.4).
            -- Generation is async + single-flight, so this never blocks LSP
            -- wiring; the previous database (if any) stays readable meanwhile.
            M.refresh_generated_cc(build_dir, out_dir, {
                variant = variant,
                compiler = compiler,
            })
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
