--- loomworks/modules/meson.lua — Meson build system module.
---
--- V1 scope:
--- * Detects meson projects (meson.build at project root)
--- * Default configurations: Debug, Release, RelWithDebInfo
---   (mapped to meson's buildtype=debug/release/debugoptimized)
--- * tasks(): `meson setup <dir> [--reconfigure]` + `meson compile -C <dir>`
--- * clean_tasks(): `meson compile -C <dir> --clean`
--- * parse_targets: `meson introspect <dir> --targets` (post-configure)
--- * get_options: `meson introspect <dir> --buildoptions` (post-configure)
--- * lsp_configs: emits a clangd entry using the build dir
---   (meson generates compile_commands.json automatically)
--- * Tools: non-keyed — single default tool (system meson). Machine file
---   support would land via a future kits mechanism.
---
--- Cross-compilation: user puts `machine_file` in the configuration's
--- type_config overrides; `tasks()` passes `--cross-file <path>` to setup.

local M = {}

local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1

M.id = "meson"
M.has_keyed_tools = false
M.has_options = true
M.languages = { "c++", "c" }

--- Map loomworks configuration name → meson buildtype.
--- Users who want something else can set `buildtype` in the config override.
local BUILDTYPE_BY_NAME = {
    Debug = "debug",
    Release = "release",
    RelWithDebInfo = "debugoptimized",
    MinSizeRel = "minsize",
}

-- ---------------------------------------------------------------------------
-- Detection + validation
-- ---------------------------------------------------------------------------

--- Detect whether a directory is a meson project.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/meson.build") then
        return { marker = "meson.build" }
    end
    return nil
end

--- Validate a meson project path.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}
    if not uv.fs_stat(path .. "/meson.build") then
        warnings[#warnings + 1] = "meson.build not found in " .. path
    end
    return { valid = true, warnings = warnings }
end

-- ---------------------------------------------------------------------------
-- Configuration discovery
-- ---------------------------------------------------------------------------

--- Return the default configurations for a meson project.
--- Fixed shape: Debug / Release / RelWithDebInfo. User can override or
--- add more via loomworks.json configurations block. Each default has
--- `variant = name` so it's concrete (buildable) — a config is abstract
--- when `module_config.variant` is nil (mixin-only).
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
function M.default_configurations(path, config)
    return {
        Debug          = { variant = "Debug",          buildtype = "debug" },
        Release        = { variant = "Release",        buildtype = "release" },
        RelWithDebInfo = { variant = "RelWithDebInfo", buildtype = "debugoptimized" },
    }
end

--- Normalize inherits to an array. Accepts string, array, or nil.
--- @param inherits string|string[]|nil
--- @return string[]
local function normalize_inherits(inherits)
    if not inherits then return {} end
    if type(inherits) == "string" then return { inherits } end
    return inherits
end

--- Resolve user overrides on top of defaults.
--- Mirrors cmake.resolve_configurations: user overrides win per-field,
--- user can add entirely new configurations. Inheritance propagates the
--- `variant` from the first base that has one; configs without a
--- variant-providing base remain abstract.
--- @param defaults table<string, table>
--- @param config table type_config from loomworks.json (may have .configurations)
--- @return table<string, table>
function M.resolve_configurations(defaults, config)
    local result = {}

    -- Start with defaults (carry variant + buildtype)
    for name, def in pairs(defaults) do
        result[name] = {
            variant = def.variant,
            buildtype = def.buildtype,
            is_default = true,
        }
    end

    -- Apply user overrides/additions
    if config and config.configurations then
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
                        -- Also inherit buildtype if child doesn't override
                        if base.buildtype and not override.buildtype then
                            cfg.buildtype = base.buildtype
                        end
                        break
                    end
                end
            end

            -- Defaults that the user overrode keep their variant-from-name;
            -- net-new user configs with no variant-providing base stay abstract.
            if not cfg.variant and cfg.is_default then
                cfg.variant = name
            end

            -- Copy through known module-specific fields
            if override.buildtype then cfg.buildtype = override.buildtype end
            if override.machine_file then cfg.machine_file = override.machine_file end
            if override.options then cfg.options = override.options end
            if override.variables then cfg.variables = override.variables end
            if override.role then cfg.role = override.role end

            cfg.is_user = true
        end
    end

    return result
end

--- Return module-level info for a project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    local defaults = M.default_configurations(path, config)
    local configurations = M.resolve_configurations(defaults, config)
    return { configurations = configurations }
end

--- Map a semantic variant type to a configuration name from available configs.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil
function M.map_variant(variant_type, available_configs)
    local function find(name)
        for _, c in ipairs(available_configs) do
            if c == name then return c end
        end
        return nil
    end
    if variant_type == "debug" then
        return find("Debug") or available_configs[1]
    elseif variant_type == "release" then
        return find("Release") or available_configs[1]
    elseif variant_type == "release_debug" then
        return find("RelWithDebInfo") or find("Release") or available_configs[1]
    end
    return available_configs[1]
end

-- ---------------------------------------------------------------------------
-- Tool detection
-- ---------------------------------------------------------------------------

--- Ask `python` where it installs scripts (both system and --user),
--- look for a `meson` / `meson.exe` executable in those directories,
--- and print the path to the first one found.
---
--- Uses sysconfig.get_path('scripts', scheme) with both the default
--- system scheme and the per-user scheme ('nt_user' on Windows,
--- 'posix_user' elsewhere). The user scheme is what `pip install --user`
--- targets on Windows — e.g.
--- `C:\Users\X\AppData\Roaming\Python\Python313\Scripts`, which
--- `site.USER_BASE` alone doesn't reach.
---
--- Exit code 0 and a single line of stdout on success; non-zero on miss.
local PY_FIND_MESON = [[
import os,sys,sysconfig
ds=[sysconfig.get_path('scripts')]
try:
    ds.append(sysconfig.get_path('scripts','nt_user' if os.name=='nt' else os.name+'_user'))
except Exception:
    pass
for d in ds:
    for n in ('meson','meson.exe'):
        p=os.path.join(d,n)
        if os.path.isfile(p):
            print(p); sys.exit(0)
sys.exit(1)
]]

--- Locate meson as a command prefix array.
--- Tries, in order:
---   1. `meson` on PATH (the standard install)
---   2. A `meson` / `meson.exe` script inside a Python interpreter's
---      system or user Scripts directory (pip install, with or without
---      --user). Canonical install channel, especially on Windows.
--- Returns `{ meson_path }` in both cases — meson scripts are
--- self-contained and need no wrapper args. Returns nil when neither
--- works. Per the graceful-degradation policy, callers should refuse
--- rather than guess further.
--- @return string[]|nil
local function find_meson()
    local p = vim.fn.exepath("meson")
    if p ~= "" then return { p } end

    for _, py in ipairs({ "python", "python3", "py" }) do
        local pp = vim.fn.exepath(py)
        if pp ~= "" then
            local out = vim.fn.system({ pp, "-c", PY_FIND_MESON })
            if vim.v.shell_error == 0 then
                local path = vim.trim(out or "")
                if path ~= "" and uv.fs_stat(path) then
                    return { path }
                end
            end
        end
    end
    return nil
end

--- Detect available tools (sync).
--- Non-keyed: returns a single entry with the resolved meson command array.
--- Returns empty if meson is not available by either path.
--- @return { tool_data: table }[]
function M.detect_tools()
    local meson = find_meson()
    if not meson then return {} end
    return { { tool_data = { meson = meson } } }
end

--- Detect available tools (async variant for consistency with interface).
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    callback(M.detect_tools())
end

--- Cache key suffix from tool_data. Non-keyed → nil.
--- @param tool_data table
--- @return string|nil
function M.tool_key(tool_data)
    return nil
end

--- Display label for tool. The resolved meson path lives in
--- tool_data.meson[1] for users who want to inspect where it came from.
--- @param tool_data table
--- @return string|nil
function M.tool_label(tool_data)
    local cmd = tool_data and tool_data.meson
    if type(cmd) == "table" and cmd[1] then return "meson" end
    -- Backwards compat: a stored string path from pre-array caches
    if type(cmd) == "string" and cmd ~= "" then return "meson" end
    return nil
end

--- Compare two meson tool_data objects. Always true (single default tool).
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    return true
end

-- ---------------------------------------------------------------------------
-- Task generation
-- ---------------------------------------------------------------------------

--- Resolve the meson command prefix from tool_data (array form).
--- Falls through to a fresh find_meson if tool_data is empty. Errors
--- out if neither form is available — per degradation policy, we
--- refuse rather than silently fail later.
--- Accepts legacy string form for backwards compatibility with caches
--- written before the array form landed.
--- @param tool_data table|nil
--- @return string[] command prefix (copy; safe to mutate)
local function resolve_meson(tool_data)
    local cmd = tool_data and tool_data.meson
    if type(cmd) == "table" and cmd[1] then
        return vim.list_extend({}, cmd)
    end
    if type(cmd) == "string" and cmd ~= "" then
        return { cmd }
    end
    local sys = find_meson()
    if sys then return vim.list_extend({}, sys) end
    error("meson: no meson binary available (not on PATH, and no python has it installed via pip)")
end

--- Expand ${ENV_VAR} / ${var} patterns in a string.
--- Used for option values, machine files, etc.
--- @param s string
--- @param ctx? table extra vars (workspace_root, project_path, ...)
--- @return string
local function expand_str(s, ctx)
    return (s:gsub("%${([^}]+)}", function(var)
        if ctx and ctx[var] ~= nil then return tostring(ctx[var]) end
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Build the list of `-Dkey=value` args from user options + inherited.
--- Mirrors cmake.resolve_options semantics (project-wide + inherited + config-specific).
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return string[] list of `-Dkey=value` args
local function build_option_args(project, active_config)
    local args = {}
    local type_config = project.type_config or {}
    local project_opts = type_config.options or {}
    local configs = project.configurations or {}
    local active = configs[active_config] or {}

    local opt_ctx = {
        workspace_root = project.workspace_root,
        project_path = project.path or project.name,
    }

    -- Apply project-wide, then config-specific (config wins)
    local merged = {}
    for k, v in pairs(project_opts) do merged[k] = v end
    if active.options then
        for k, v in pairs(active.options) do merged[k] = v end
    end
    for k, v in pairs(merged) do
        args[#args + 1] = "-D" .. k .. "=" .. expand_str(tostring(v), opt_ctx)
    end
    return args
end

--- Return overseer task templates for a project.
--- Produces:
---   * configure: `meson setup <build_dir> --buildtype=X [--cross-file=...] -Dkey=value ...`
---               or `meson setup <build_dir> --reconfigure ...` if already set up
---   * build:     `meson compile -C <build_dir>`
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local config_info = project.configurations and project.configurations[active_config] or nil
    local env = project.env or {}
    local meson_prefix = resolve_meson(project.tool_data)

    -- Resolve build dir (default formula; no resolve_build_dir override).
    -- project.cached_build_dir is provided by core when a cached entry exists,
    -- so rename paths are preserved.
    local build_dir = project.cached_build_dir
        or (project.workspace_root .. "/.nvim/build/" .. project.name .. "/" .. active_config)

    -- buildtype from config or name mapping
    local buildtype = (config_info and config_info.buildtype)
        or BUILDTYPE_BY_NAME[active_config]
        or "debug"

    -- Build the setup command: <meson_prefix> setup <dir> --buildtype=X [...]
    local configure_cmd = vim.list_extend({}, meson_prefix)
    local insert_at = #configure_cmd  -- index of last prefix token (for --reconfigure insertion)
    configure_cmd[#configure_cmd + 1] = "setup"
    configure_cmd[#configure_cmd + 1] = build_dir
    configure_cmd[#configure_cmd + 1] = "--buildtype=" .. buildtype

    -- Optional cross-compilation machine file
    if config_info and config_info.machine_file then
        local mf = expand_str(tostring(config_info.machine_file), {
            workspace_root = project.workspace_root,
            project_path = project.path or project.name,
        })
        configure_cmd[#configure_cmd + 1] = "--cross-file=" .. mf
    end

    -- User -D options (project-wide + config-specific)
    for _, opt in ipairs(build_option_args(project, active_config)) do
        configure_cmd[#configure_cmd + 1] = opt
    end

    -- Reconfigure if the build dir already exists (idempotent setup).
    -- Insert --reconfigure right after the `setup` subcommand so it works
    -- for both plain meson and `python -m mesonbuild` invocations.
    local reconfigure_cmd = vim.list_extend({}, configure_cmd)
    table.insert(reconfigure_cmd, insert_at + 2, "--reconfigure")

    local configuration_key = project.configuration_key or active_config
    local cached_tool_data = project.tool_data

    local tasks = {}

    tasks[#tasks + 1] = {
        name = project.name .. ": configure",
        builder = function()
            -- Pick reconfigure or first-time setup based on whether the dir exists
            local uv2 = vim.uv or vim.loop
            local cmd = (uv2.fs_stat(build_dir .. "/meson-info")
                    and reconfigure_cmd) or configure_cmd
            vim.fn.mkdir(build_dir, "p")
            return { cmd = cmd, cwd = abs_path, env = env }
        end,
        loomworks = {
            project_key = project.name,
            action = "configure",
            configuration_key = configuration_key,
            build_dir = build_dir,
            tool_data = cached_tool_data,
            module_info = {
                buildtype = buildtype,
                source_dir = project.path,
            },
        },
    }

    tasks[#tasks + 1] = {
        name = project.name .. ": build " .. active_config,
        builder = function()
            local cmd = vim.list_extend({}, meson_prefix)
            cmd[#cmd + 1] = "compile"
            cmd[#cmd + 1] = "-C"
            cmd[#cmd + 1] = build_dir
            return { cmd = cmd, cwd = abs_path, env = env }
        end,
        loomworks = {
            project_key = project.name,
            action = "build",
            configuration_key = configuration_key,
            build_dir = build_dir,
            tool_data = cached_tool_data,
        },
    }

    return tasks
end

--- Return overseer task templates for cleaning build artifacts.
--- Uses `meson compile -C <dir> --clean` which delegates to the underlying
--- backend (ninja by default). The build dir itself is preserved.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local env = project.env or {}
    local meson_prefix = resolve_meson(project.tool_data)
    local build_dir = project.cached_build_dir
        or (project.workspace_root .. "/.nvim/build/" .. project.name .. "/" .. active_config)
    local configuration_key = project.configuration_key or active_config

    return {
        {
            name = project.name .. ": clean",
            builder = function()
                local cmd = vim.list_extend({}, meson_prefix)
                cmd[#cmd + 1] = "compile"
                cmd[#cmd + 1] = "-C"
                cmd[#cmd + 1] = build_dir
                cmd[#cmd + 1] = "--clean"
                return { cmd = cmd, cwd = abs_path, env = env }
            end,
            loomworks = {
                project_key = project.name,
                action = "clean",
                configuration_key = configuration_key,
                build_dir = build_dir,
            },
        },
    }
end

--- Return progress parser tool name.
--- Meson compile uses ninja by default, which has a recognizable progress format.
--- @return string
function M.progress_parser()
    return "ninja"
end

-- ---------------------------------------------------------------------------
-- Introspection: parse_targets + get_options
-- ---------------------------------------------------------------------------

--- Run `meson introspect <subcommand>` and parse the JSON reply.
--- Returns nil on failure.
--- @param meson_prefix string[] resolved command prefix (e.g. {"meson"} or {"python","-m","mesonbuild"})
--- @param build_dir string
--- @param subcommand string e.g. "--targets", "--buildoptions"
--- @return any|nil
local function run_introspect(meson_prefix, build_dir, subcommand)
    local cmd = vim.list_extend({}, meson_prefix)
    cmd[#cmd + 1] = "introspect"
    cmd[#cmd + 1] = build_dir
    cmd[#cmd + 1] = subcommand
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return nil end
    local ok, data = pcall(vim.json.decode, out)
    if not ok then return nil end
    return data
end

--- Map meson target type string to the loomworks target kind.
--- Returns nil for target kinds we don't surface (custom, run targets, jars).
--- @param meson_type string
--- @return string|nil
local function target_kind(meson_type)
    if meson_type == "executable" then return "executable" end
    if meson_type == "static library" then return "static_library" end
    if meson_type == "shared library" then return "shared_library" end
    if meson_type == "shared module" then return "module_library" end
    return nil
end

--- Extract target list via `meson introspect --targets`.
--- @param ctx { build_dir?: string, project_path?: string }
--- @return table<string, { type: string, artifact?: string }>|nil
function M.parse_targets(ctx)
    local build_dir = ctx and ctx.build_dir
    if not build_dir then return nil end
    local meson_prefix = find_meson()
    if not meson_prefix then return nil end

    local raw = run_introspect(meson_prefix, build_dir, "--targets")
    if type(raw) ~= "table" then return nil end

    local normalize = build_dir:gsub("\\", "/")
    if normalize:sub(-1) ~= "/" then normalize = normalize .. "/" end

    local result = {}
    for _, t in ipairs(raw) do
        local kind = target_kind(t.type)
        if kind and t.name and t.build_by_default ~= false then
            local entry = { type = kind }
            local artifacts = t.filename
            if type(artifacts) == "table" and artifacts[1] then
                local abs = tostring(artifacts[1]):gsub("\\", "/")
                -- Strip build_dir prefix if present so artifact is relative
                if abs:sub(1, #normalize) == normalize then
                    entry.artifact = abs:sub(#normalize + 1)
                else
                    entry.artifact = abs
                end
            end
            result[t.name] = entry
        end
    end
    return next(result) and result or nil
end

--- Async companion for parse_targets — yields to the event loop.
--- @param ctx table
--- @param callback fun(targets: table|nil)
function M.parse_targets_async(ctx, callback)
    vim.schedule(function() callback(M.parse_targets(ctx)) end)
end

--- Map meson option type to loomworks option value_type.
--- @param meson_type string
--- @return string
local function option_value_type(meson_type)
    if meson_type == "boolean" then return "bool" end
    if meson_type == "string" then return "string" end
    if meson_type == "combo" then return "string" end
    if meson_type == "integer" then return "string" end
    if meson_type == "array" then return "string" end
    return "string"
end

--- Extract build options via `meson introspect --buildoptions`.
--- Groups by `section` (core, base, compiler, directory, user, test).
--- @param build_dir string
--- @param config table|nil unused
--- @return table|nil options tree
function M.get_options(build_dir, config)
    if not build_dir then return nil end
    local meson_prefix = find_meson()
    if not meson_prefix then return nil end

    local raw = run_introspect(meson_prefix, build_dir, "--buildoptions")
    if type(raw) ~= "table" then return nil end

    local SECTION_ORDER = { "user", "core", "base", "compiler", "directory", "test" }
    local SECTION_LABEL = {
        user = "User options",
        core = "Core options",
        base = "Base options",
        compiler = "Compiler options",
        directory = "Directories",
        test = "Test options",
    }

    local buckets = {}
    for _, opt in ipairs(raw) do
        if opt.name then
            local section = opt.section or "user"
            buckets[section] = buckets[section] or {}
            local value = opt.value
            if type(value) == "table" then
                value = table.concat(value, ",")
            elseif value ~= nil then
                value = tostring(value)
            end
            local entry = {
                key = opt.name,
                value = value or "",
                value_type = option_value_type(opt.type),
                helpstring = opt.description or nil,
            }
            if opt.type == "combo" and type(opt.choices) == "table" then
                entry.choices = opt.choices
            end
            buckets[section][#buckets[section] + 1] = entry
        end
    end

    local result = {}
    for _, section in ipairs(SECTION_ORDER) do
        local entries = buckets[section]
        if entries then
            table.sort(entries, function(a, b) return a.key < b.key end)
            result[#result + 1] = {
                label = SECTION_LABEL[section] or section,
                children = entries,
            }
            buckets[section] = nil
        end
    end
    -- Any unknown sections append last
    for section, entries in pairs(buckets) do
        table.sort(entries, function(a, b) return a.key < b.key end)
        result[#result + 1] = {
            label = SECTION_LABEL[section] or section,
            children = entries,
        }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- LSP integration
-- ---------------------------------------------------------------------------

--- Return LSP configs for this project.
--- Emits a single clangd entry rooted at the project source path. Meson
--- generates compile_commands.json at the build dir root automatically.
--- @param project loomworks.Project
--- @return table[]
function M.lsp_configs(project)
    local ws = project._workspace
    if not ws then return {} end
    local root_dir = ws.root .. "/" .. (project.path or project.key)

    local build_dir = project.cached and project.cached.build_dir or nil

    -- Binary override (project-level clangd) from type_config
    local tc = project.type_config or {}
    local binary = nil
    if type(tc.clangd) == "string" and tc.clangd ~= "" then
        binary = tc.clangd
    end

    return {
        {
            server = "clangd",
            binary = binary,
            compile_commands_dir = build_dir,
            root_dir = root_dir,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Staleness detection
-- ---------------------------------------------------------------------------

--- Check if project files have changed since last configure.
--- @param path string absolute project path
--- @param config table type_config
--- @param cached table<string, table> cached configurations
--- @return { needs_refresh: boolean, reasons: string[], notes: string[] }
function M.inspect(path, config, cached)
    local reasons = {}
    local check_files = {
        { file = "meson.build", label = "meson.build" },
        { file = "meson.options", label = "meson.options" },
        { file = "meson_options.txt", label = "meson_options.txt" },
    }

    for _, cached_config in pairs(cached) do
        if cached_config.last_configured then
            local configured_time = cached_config.last_configured
            for _, cf in ipairs(check_files) do
                local stat = uv.fs_stat(path .. "/" .. cf.file)
                if stat then
                    local t = os.date("!%Y-%m-%dT%H:%M:%SZ", stat.mtime.sec)
                    if t > configured_time then
                        reasons[#reasons + 1] = cf.label .. " modified since last configure"
                    end
                end
            end
            if #reasons > 0 then break end
        end
    end

    return { needs_refresh = #reasons > 0, reasons = reasons, notes = {} }
end

return M
