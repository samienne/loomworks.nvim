local M = {}

M.id = "harmony"
M.has_keyed_tools = false
M.has_options = false
M.languages = { "arkts" }

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

-- ---------------------------------------------------------------------------
-- DevEco Studio detection
-- ---------------------------------------------------------------------------

--- Find DevEco Studio installation path.
--- Priority: DEVECO_HOME env → .home marker → default path.
--- @return string|nil deveco_home
local function find_deveco_home()
    -- 1. Environment variable
    local env = os.getenv("DEVECO_HOME")
    if env and env ~= "" and uv.fs_stat(env) then
        return env:gsub("[/\\]+$", "")
    end

    -- 2. DevEco .home marker file in %LOCALAPPDATA%/Huawei/DevEcoStudio*/
    local local_app_data = os.getenv("LOCALAPPDATA")
    if local_app_data then
        local huawei_dir = local_app_data .. "/Huawei"
        local handle = uv.fs_scandir(huawei_dir)
        if handle then
            local best_name, best_home
            while true do
                local name, ftype = uv.fs_scandir_next(handle)
                if not name then break end
                if (ftype == "directory" or ftype == nil)
                    and name:match("^DevEcoStudio") then
                    if not best_name or name > best_name then
                        local home_file = huawei_dir .. "/" .. name .. "/.home"
                        local content = io_mod.read_file(home_file)
                        if content then
                            local home = content:match("^%s*(.-)%s*$"):gsub("\\", "/")
                            if home ~= "" and uv.fs_stat(home) then
                                best_name = name
                                best_home = home
                            end
                        end
                    end
                end
            end
            if best_home then return best_home end
        end
    end

    -- 3. Default path
    local default_path = "C:/Program Files/Huawei/DevEco Studio"
    if uv.fs_stat(default_path) then
        return default_path
    end

    return nil
end

local is_win = vim.fn.has("win32") == 1

--- Resolve a tool path, checking platform-specific extensions.
--- @param base string base path without extension
--- @param exts string[] extensions to try (e.g., {".exe", ""})
--- @return string|nil resolved path
local function resolve_tool(base, exts)
    for _, ext in ipairs(exts) do
        local p = base .. ext
        if uv.fs_stat(p) then return p end
    end
    return nil
end

--- Build tool_data from a DevEco Studio installation.
--- @param deveco_home string
--- @return table|nil tool_data
local function build_tool_data(deveco_home)
    local exe_exts = is_win and { ".exe", "" } or { "", ".exe" }
    local script_exts = is_win and { ".bat", ".cmd", "" } or { "", ".sh" }

    local hvigorw_js = deveco_home .. "/tools/hvigor/bin/hvigorw.js"
    local node = resolve_tool(deveco_home .. "/tools/node/node", exe_exts)
    local ohpm = resolve_tool(deveco_home .. "/tools/ohpm/bin/ohpm", script_exts)
    local hdc = resolve_tool(deveco_home .. "/sdk/default/openharmony/toolchains/hdc", exe_exts)
    local java = resolve_tool(deveco_home .. "/jbr/bin/java", exe_exts)

    -- Verify hvigorw.js and node exist (minimum requirement)
    if not uv.fs_stat(hvigorw_js) or not node then return nil end

    return {
        deveco_home = deveco_home,
        hvigorw_js = hvigorw_js,
        node = node,
        ohpm = ohpm,
        hdc = hdc,
        java = java,
    }
end

--- Cached DevEco detection result.
--- @type table|nil|false  nil = not checked, false = not found, table = tool_data
local _cached_tool_data = nil

--- Detect DevEco tools (cached).
--- @return table|nil tool_data
local function detect_deveco()
    if _cached_tool_data ~= nil then
        return _cached_tool_data or nil
    end
    local home = find_deveco_home()
    if home then
        _cached_tool_data = build_tool_data(home) or false
    else
        _cached_tool_data = false
    end
    return _cached_tool_data or nil
end

--- Build hvigor environment variables from tool_data.
--- @param tool_data table
--- @return table<string, string>
local function hvigor_env(tool_data)
    local sep = is_win and ";" or ":"
    local env = {}
    env.DEVECO_SDK_HOME = tool_data.deveco_home .. "/sdk"
    if tool_data.node then
        local node_dir = tool_data.node:gsub("[/\\][^/\\]+$", "")
        env.NODE_HOME = node_dir
    end
    -- Add DevEco's bundled Java to PATH (needed for HAP signing)
    if tool_data.java then
        local java_dir = tool_data.java:gsub("[/\\][^/\\]+$", "")
        local path = os.getenv("PATH") or ""
        env.PATH = java_dir .. sep .. path
    end
    return env
end

--- Wrap a script command for the platform.
--- On Windows: .bat/.cmd files need cmd /c with quoted paths.
--- On Unix: .sh files may need explicit shell invocation.
--- @param cmd string[] command array
--- @return string[]
local function wrap_script_cmd(cmd)
    if is_win and (cmd[1]:match("%.bat$") or cmd[1]:match("%.cmd$")) then
        local parts = {}
        for _, arg in ipairs(cmd) do
            if arg:match("%s") then
                parts[#parts + 1] = '"' .. arg .. '"'
            else
                parts[#parts + 1] = arg
            end
        end
        return { "cmd", "/c", table.concat(parts, " ") }
    end
    return cmd
end

-- ---------------------------------------------------------------------------
-- Module interface
-- ---------------------------------------------------------------------------

--- Detect whether a directory looks like a Harmony/OpenHarmony project.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/build-profile.json5") then
        return { marker = "build-profile.json5" }
    end
    return nil
end

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

    local td = detect_deveco()
    if not td then
        warnings[#warnings + 1] = "DevEco Studio not found (set DEVECO_HOME or install to default path)"
    end

    return { valid = true, warnings = warnings }
end

--- Parse build-profile.json5 using Node.js (handles JSON5 syntax).
--- @param project_path string absolute project path
--- @param node_path string|nil path to node executable
--- @return table|nil parsed data
local function parse_build_profile(project_path, node_path)
    local node = node_path or vim.fn.exepath("node")
    if not node or node == "" then return nil end

    local profile_path = project_path .. "/build-profile.json5"
    if not uv.fs_stat(profile_path) then return nil end

    -- Node.js require() doesn't support .json5 — strip comments/trailing
    -- commas and parse as standard JSON.
    local escaped_path = profile_path:gsub("\\", "/"):gsub("'", "\\'")
    local script = [[
const fs=require('fs');
let c=fs.readFileSync(']] .. escaped_path .. [[','utf8');
c=c.replace(/\/\/.*$/gm,'');
c=c.replace(/\/\*[\s\S]*?\*\//g,'');
c=c.replace(/,\s*([\]}])/g,'$1');
try{process.stdout.write(JSON.stringify(JSON.parse(c)))}
catch(e){process.stderr.write(e.message);process.exit(1)}
]]
    local result = vim.fn.system({ node, "-e", script })
    if vim.v.shell_error ~= 0 then return nil end

    local ok, data = pcall(vim.json.decode, result)
    if not ok then return nil end
    return data
end

--- Extract module names from build-profile.json5.
--- @param profile table parsed build-profile.json5
--- @return string[] module names (e.g., {"entry"})
local function extract_modules(profile)
    local modules = {}
    if profile and profile.modules then
        for _, m in ipairs(profile.modules) do
            if m.name then
                modules[#modules + 1] = m.name
            end
        end
    end
    if #modules == 0 then
        modules[1] = "entry"  -- fallback default
    end
    return modules
end

--- Return the default configurations for this module.
--- Auto-detects products from build-profile.json5.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
function M.default_configurations(path, config)
    local td = detect_deveco()
    local profile = parse_build_profile(path, td and td.node)

    if profile and profile.app and profile.app.products then
        local configs = {}
        local modules = extract_modules(profile)
        for _, product in ipairs(profile.app.products) do
            if product.name then
                configs[product.name] = {
                    variant = product.name,
                    product = product.name,
                    mode = "debug",
                    runtime_os = product.runtimeOS,
                    modules = modules,
                    abi_filters = product.buildOption
                        and product.buildOption.externalNativeOptions
                        and product.buildOption.externalNativeOptions.abiFilters,
                }
            end
        end
        if next(configs) then return configs end
    end

    -- Fallback: simple debug/release
    return { debug = { variant = "debug" }, release = { variant = "release" } }
end

--- Return what the module knows about the project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    local configurations = M.default_configurations(path, config)

    -- Merge user overrides/additions on top
    if config.configurations then
        for name, cfg in pairs(config.configurations) do
            configurations[name] = configurations[name] or {}
            for k, v in pairs(cfg) do
                configurations[name][k] = v
            end
        end
    end

    return { configurations = configurations }
end

--- Detect available tools (DevEco Studio).
--- @return { tool_data: table }[]
function M.detect_tools()
    local td = detect_deveco()
    if td then
        return { { tool_data = td } }
    end
    return { { tool_data = {} } }
end

--- Detect available tools asynchronously.
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    -- DevEco detection is filesystem-based, fast enough for sync
    callback(M.detect_tools())
end

--- Compare two eTS tool_data objects. Always match (single tool).
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    return true
end

--- Cache key suffix. nil = no suffix needed (single tool).
--- @param tool_data table
--- @return nil
function M.tool_key(tool_data)
    return nil
end

--- Display label for DevEco Studio tool.
--- @param tool_data table
--- @return string|nil
function M.tool_label(tool_data)
    if tool_data.deveco_home then
        return "DevEco Studio"
    end
    return nil
end

--- Map a semantic variant type to a configuration name from available configs.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil matching configuration name
function M.map_variant(variant_type, available_configs)
    if #available_configs == 1 then
        return available_configs[1]
    end

    -- Try exact match first
    for _, config in ipairs(available_configs) do
        if config:lower() == variant_type then
            return config
        end
    end

    -- For products like "default", "ohos": return first available
    if variant_type == "debug" then
        return available_configs[1]
    end

    return nil
end

--- Resolve common task context from project and tool_data.
--- @param project loomworks.ModuleContext
--- @return table ctx { abs_path, td, node, hvigorw_js, ohpm, env }
local function resolve_task_ctx(project)
    local abs_path = project.workspace_root .. "/" .. project.path
    local td = project.tool_data
    if not td or not td.deveco_home then
        td = detect_deveco() or {}
    end
    local env = td.deveco_home and hvigor_env(td) or {}
    return {
        abs_path = abs_path,
        td = td,
        node = td.node or vim.fn.exepath("node"),
        hvigorw_js = td.hvigorw_js,
        ohpm = td.ohpm or "ohpm",
        env = env,
    }
end

--- Build an hvigorw command array.
--- @param ctx table from resolve_task_ctx
--- @param args string[] hvigor arguments
--- @return string[]
local function hvigor_cmd(ctx, args)
    if ctx.hvigorw_js and ctx.node then
        local cmd = { ctx.node, ctx.hvigorw_js }
        vim.list_extend(cmd, args)
        return cmd
    end
    -- Fallback: use hvigorw script directly (needs wrapping on Windows)
    local cmd = { ctx.td.hvigorw_js or "hvigorw" }
    vim.list_extend(cmd, args)
    return wrap_script_cmd(cmd)
end

--- Return overseer task templates for a project.
--- Configure = ohpm install + hvigor sync.
--- Build = hvigor assembleHap.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local ctx = resolve_task_ctx(project)
    local configuration_key = project.configuration_key or active_config

    -- Resolve product and modules from configuration
    local config_info = project.configurations and project.configurations[active_config]
    local product = config_info and config_info.product or "default"
    local modules = config_info and config_info.modules or { "entry" }
    local module_param = modules[1]  -- primary module for build

    return {
        -- Configure step 1: ohpm install (dependency resolution)
        {
            name = project.name .. ": ohpm install",
            builder = function()
                return {
                    cmd = wrap_script_cmd({ ctx.ohpm, "install" }),
                    cwd = ctx.abs_path,
                    env = ctx.env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "configure",
                configuration_key = configuration_key,
            },
        },
        -- Configure step 2: hvigor sync (project structure resolution)
        {
            name = project.name .. ": sync",
            builder = function()
                return {
                    cmd = hvigor_cmd(ctx, {
                        "--sync",
                        "-p", "product=" .. product,
                        "--no-daemon" }),
                    cwd = ctx.abs_path,
                    env = ctx.env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "configure",
                configuration_key = configuration_key,
            },
        },
        -- Build: hvigor assembleHap
        {
            name = project.name .. ": build " .. active_config,
            builder = function()
                return {
                    cmd = hvigor_cmd(ctx, {
                        "--mode", "module",
                        "-p", "module=" .. module_param,
                        "-p", "product=" .. product,
                        "assembleHap",
                        "--no-daemon" }),
                    cwd = ctx.abs_path,
                    env = ctx.env,
                }
            end,
            loomworks = {
                project_key = project.name,
                action = "build",
                configuration_key = configuration_key,
            },
        },
    }
end

--- Return overseer task templates for cleaning build artifacts.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local ctx = resolve_task_ctx(project)
    local configuration_key = project.configuration_key or active_config

    return {
        {
            name = project.name .. ": clean",
            builder = function()
                return {
                    cmd = hvigor_cmd(ctx, { "clean", "--no-daemon" }),
                    cwd = ctx.abs_path,
                    env = ctx.env,
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

--- Return progress parser tool name. nil = no progress tracking.
function M.progress_parser()
    return nil
end

--- Check if project files have changed since last build.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @param cached table<string, table> cached configurations
--- @return { needs_refresh: boolean, reasons: string[], notes: string[] }
function M.inspect(path, config, cached)
    local reasons = {}

    -- Root-level files that trigger re-sync
    local check_files = {
        { file = "build-profile.json5", label = "build-profile.json5" },
        { file = "oh-package.json5", label = "oh-package.json5" },
        { file = "hvigorfile.ts", label = "hvigorfile.ts" },
    }

    -- Per-module files: detect modules from build-profile.json5
    local td = detect_deveco()
    local profile = parse_build_profile(path, td and td.node)
    local modules = extract_modules(profile)
    for _, mod_name in ipairs(modules) do
        check_files[#check_files + 1] = {
            file = mod_name .. "/build-profile.json5",
            label = mod_name .. "/build-profile.json5",
        }
        check_files[#check_files + 1] = {
            file = mod_name .. "/oh-package.json5",
            label = mod_name .. "/oh-package.json5",
        }
        check_files[#check_files + 1] = {
            file = mod_name .. "/src/main/module.json5",
            label = mod_name .. "/module.json5",
        }
    end

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
