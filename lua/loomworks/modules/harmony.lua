local M = {}

M.id = "harmony"
M.has_keyed_tools = false
M.has_options = false
M.has_devices = true
M.languages = { "arkts" }

local uv = vim.uv or vim.loop

local is_win = vim.fn.has("win32") == 1

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

    return { valid = true, warnings = warnings }
end

--- Cache of files we've already complained about this session, so the
--- diagnostic notify fires at most once per file regardless of how
--- many times default_configurations gets hit during merge.
--- @type table<string, boolean>
local _reported_parse_failures = {}

--- Emit a one-time parse-failure notice. Intentionally visible (WARN)
--- so it shows up in `:messages` and notification plugins — this is
--- the single symptom that explains "my harmony project has no
--- configurations" without reading the full log.
--- @param file_path string
--- @param reason string
local function report_parse_failure(file_path, reason)
    if _reported_parse_failures[file_path] then return end
    _reported_parse_failures[file_path] = true
    vim.notify(
        "loomworks/harmony: could not parse " .. file_path .. " — " .. reason,
        vim.log.levels.WARN)
end

--- Parse a JSON5 file using Node.js (strips comments/trailing commas).
--- Returns `(data, err)` — `err` is nil on success, a short string
--- describing the failure otherwise. Surfacing the reason means the
--- caller can report it via the notify helper instead of swallowing
--- silently and leaving the project with no configurations.
--- @param file_path string absolute file path
--- @param node_path string|nil path to node executable
--- @return table|nil data, string|nil err
local function parse_json5(file_path, node_path)
    local node = node_path or vim.fn.exepath("node")
    if not node or node == "" then
        return nil, "no node binary (not on PATH and not in tool_data)"
    end

    if not uv.fs_stat(file_path) then
        return nil, "file not found on disk"
    end

    local escaped_path = file_path:gsub("\\", "/"):gsub("'", "\\'")
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
    if vim.v.shell_error ~= 0 then
        -- `result` holds stderr when shell_error != 0 in this path
        -- (node writes the parse error there). Trim noise.
        local snippet = (result or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if #snippet > 200 then snippet = snippet:sub(1, 200) .. "…" end
        return nil, string.format("node exited %d: %s",
            vim.v.shell_error, snippet ~= "" and snippet or "<no stderr>")
    end

    local ok, data = pcall(vim.json.decode, result)
    if not ok then
        return nil, "JSON decode error on node output"
    end
    return data, nil
end

--- Parse build-profile.json5 using Node.js (handles JSON5 syntax).
--- Surfaces the failure reason to the user via `report_parse_failure`
--- the first time a given file fails to parse so they can see why
--- configurations aren't being auto-generated.
--- @param project_path string absolute project path
--- @param node_path string|nil path to node executable
--- @return table|nil parsed data
local function parse_build_profile(project_path, node_path)
    local file_path = project_path .. "/build-profile.json5"
    local data, err = parse_json5(file_path, node_path)
    if not data and err then
        report_parse_failure(file_path, err)
    end
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

--- Extract module targets from build-profile.json5.
--- Returns a flat list of { module_name, target_name, apply_to_products }.
--- @param profile table parsed build-profile.json5
--- @return { module_name: string, target_name: string, apply_to_products: string[]|nil }[]
local function extract_targets(profile)
    local targets = {}
    if profile and profile.modules then
        for _, m in ipairs(profile.modules) do
            if m.targets then
                for _, t in ipairs(m.targets) do
                    if t.name then
                        targets[#targets + 1] = {
                            module_name = m.name or "entry",
                            target_name = t.name,
                            apply_to_products = t.applyToProducts,
                        }
                    end
                end
            end
            -- Module with no targets gets a synthetic "default" target
            if not m.targets or #m.targets == 0 then
                targets[#targets + 1] = {
                    module_name = m.name or "entry",
                    target_name = "default",
                    apply_to_products = nil, -- applies to all
                }
            end
        end
    end
    if #targets == 0 then
        targets[1] = { module_name = "entry", target_name = "default" }
    end
    return targets
end

--- Check if a target applies to a given product.
--- @param target table from extract_targets
--- @param product_name string
--- @return boolean
local function target_applies_to(target, product_name)
    if not target.apply_to_products then return true end
    for _, p in ipairs(target.apply_to_products) do
        if p == product_name then return true end
    end
    return false
end

--- Return the default configurations for this module.
--- Generates product × target × ABI combinations from build-profile.json5.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
--- Reported-empty cache: same spirit as `_reported_parse_failures`.
--- If the profile parses fine but yields no configs (e.g. no products
--- declared), we still want to tell the user exactly once.
--- @type table<string, boolean>
local _reported_empty = {}

function M.default_configurations(path, config)
    -- Honour a node path from tool_data (present once the SDK has
    -- been resolved); fall back to PATH-exepath for callers that
    -- invoke info() before tool resolution.
    local node_path = config and config.tool_data and config.tool_data.node
    local profile = parse_build_profile(path, node_path)

    if profile and profile.app and profile.app.products then
        local configs = {}
        local modules = extract_modules(profile)
        local targets = extract_targets(profile)

        for _, product in ipairs(profile.app.products) do
            if not product.name then goto next_product end

            local abi_filters = product.buildOption
                and product.buildOption.externalNativeOptions
                and product.buildOption.externalNativeOptions.abiFilters

            for _, target in ipairs(targets) do
                if not target_applies_to(target, product.name) then
                    goto next_target
                end

                if abi_filters and #abi_filters > 0 then
                    -- Native project: one config per ABI
                    for _, abi in ipairs(abi_filters) do
                        local name = product.name .. "-" .. target.target_name .. "-" .. abi
                        configs[name] = {
                            prefix = "auto",
                            variant = name,
                            product = product.name,
                            target = target.target_name,
                            abi = abi,
                            mode = "debug",
                            runtime_os = product.runtimeOS,
                            modules = modules,
                            module_name = target.module_name,
                        }
                    end
                else
                    -- Non-native project: no ABI suffix
                    local name = product.name .. "-" .. target.target_name
                    configs[name] = {
                        prefix = "auto",
                        variant = name,
                        product = product.name,
                        target = target.target_name,
                        mode = "debug",
                        runtime_os = product.runtimeOS,
                        modules = modules,
                        module_name = target.module_name,
                    }
                end

                ::next_target::
            end

            ::next_product::
        end
        if next(configs) then return configs end

        -- Parse succeeded but yielded nothing — no products, empty
        -- targets, or target/product filters didn't overlap. Tell
        -- the user once so a "phantom default config" doesn't look
        -- mysterious.
        if not _reported_empty[path] then
            _reported_empty[path] = true
            local n_products = (profile.app.products and #profile.app.products) or 0
            local n_targets = #extract_targets(profile)
            vim.notify(
                string.format(
                    "loomworks/harmony: %s: build-profile parsed OK but "
                    .. "produced 0 configurations (products=%d targets=%d) "
                    .. "— falling back to debug/release",
                    path, n_products, n_targets),
                vim.log.levels.WARN)
        end
    end

    -- Fallback: simple debug/release (prefix="auto" so the
    -- canonical keys become `auto:debug` / `auto:release`).
    return {
        debug   = { prefix = "auto", variant = "debug" },
        release = { prefix = "auto", variant = "release" },
    }
end

--- Module-level prefix for harmony auto-gens. Harmony uses `auto:`
--- (generic "auto-generated from project files") rather than a
--- module-specific prefix — if there's ever a second source inside
--- a harmony project it can pick its own prefix in the per-entry
--- `prefix` field.
M.default_config_prefix = "auto"

--- Return what the module knows about the project.
--- Mark configurations from user type_config as `is_user = true` so the UI
--- allows deleting them (cmake uses the same convention).
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    local Configuration = require("loomworks.configuration")
    local defaults = M.default_configurations(path, config)
    -- Canonicalise: auto-gens become `auto:product-target-abi`,
    -- user overrides (banned from containing ':') stand alone as
    -- bare-keyed user configs.
    return {
        configurations = Configuration.canonicalize(
            defaults, config and config.configurations, M.id),
    }
end

--- Resolve the build directory for a harmony configuration.
--- Native configurations (with ABI) return hvigor's cmake build dir.
--- Non-native configurations use the default .nvim/build/ formula.
--- @param project_name string project key (also used as path segment)
--- @param config_name string configuration name
--- @param config_info table|nil module_config from Configuration
--- @param workspace_root string absolute workspace root
--- @param tool_data table|nil tool data
--- @return string absolute build directory path
function M.resolve_build_dir(project_name, config_name, config_info, workspace_root, tool_data)
    local ci = config_info or {}
    local abi = ci.abi
    if not abi then
        return workspace_root .. "/.nvim/build/" .. project_name .. "/" .. config_name
    end
    local module_name = ci.module_name
        or (ci.modules and ci.modules[1])
        or "entry"
    local product = ci.product or "default"
    local target = ci.target or "default"
    local mode = ci.mode or "debug"
    -- hvigor layout: <project>/<module>/.cxx/<product>/<target>/<mode>/<abi>/
    return workspace_root .. "/" .. project_name .. "/"
        .. module_name .. "/.cxx/"
        .. product .. "/" .. target .. "/" .. mode .. "/" .. abi
end

--- Return LSP configs for this project.
--- Emits a clangd entry only for native configurations (ABI set). The
--- clangd root_dir is the hvigor build directory (since compile_commands.json
--- references source files by full path). Binary is the SDK-bundled clangd.
--- @param project loomworks.Project
--- @return loomworks.LspConfigEntry[]
function M.lsp_configs(project)
    -- Only emit clangd for configurations with native code (ABI set)
    local cached = project.cached
    if not cached then return {} end
    local mc = cached.module_config or {}
    local abi = mc.abi or (cached.abi)
    if not abi then return {} end

    local build_dir = cached.build_dir
    if not build_dir then return {} end

    -- Resolve SDK-bundled clangd. Required: stock PATH clangd cannot find
    -- the harmony platform headers, so we surface an error rather than
    -- silently falling back.
    local tool_data = project.tool_data or {}
    local binary = nil
    if tool_data.deveco_home then
        local clangd = tool_data.deveco_home
            .. "/sdk/default/openharmony/native/llvm/bin/clangd"
        if is_win then clangd = clangd .. ".exe" end
        if uv.fs_stat(clangd) then binary = clangd end
    end
    if not binary and tool_data.clangd and uv.fs_stat(tool_data.clangd) then
        binary = tool_data.clangd
    end

    return {
        {
            server = "clangd",
            binary = binary,
            binary_required = true,
            compile_commands_dir = build_dir,
            root_dir = build_dir,
        },
    }
end

--- Detect available tools.
--- Returns empty — tools are provided by SDK via kits_from_sdk().
--- @return { tool_data: table }[]
function M.detect_tools()
    return { { tool_data = {} } }
end

--- Detect available tools asynchronously.
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    callback(M.detect_tools())
end

--- Generate tools from SDK capabilities.
--- Called by core when an SDK provides capabilities for this module.
--- @param caps table opaque capability data from SDK query("harmony")
--- @param sdk loomworks.SDK
--- @return { tool_data: table }[]
function M.kits_from_sdk(caps, sdk)
    -- caps is expected to contain: deveco_home, node, hvigorw_js, ohpm, hdc, java
    if not caps or not caps.deveco_home then return {} end
    -- Tag with SDK identity so tool_key can derive a key
    local td = vim.deepcopy(caps)
    td.sdk_key = sdk.key
    td.sdk_display = sdk:display_name()
    return { { tool_data = td } }
end

--- Compare two harmony tool_data objects.
--- Match by sdk_key if present, otherwise always match.
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    if a.sdk_key and b.sdk_key then
        return a.sdk_key == b.sdk_key
    end
    return true
end

--- Cache key suffix from tool_data.
--- @param tool_data table
--- @return string|nil
function M.tool_key(tool_data)
    return tool_data.sdk_key
end

--- Display label for tool.
--- @param tool_data table
--- @return string|nil
function M.tool_label(tool_data)
    if tool_data.sdk_display then
        return tool_data.sdk_display
    end
    if tool_data.deveco_home then
        return "DevEco Studio"
    end
    return nil
end

--- Declare UI-editable fields in harmony's type_config.
--- The core UI renders an env-dict editor for `cmake_env`, which
--- forwards values as environment variables to hvigor's cmake.
--- @return table[]
function M.editable_type_config_fields()
    return {
        { name = "cmake_env", label = "Build environment", kind = "env_dict" },
    }
end

--- Map a semantic variant type to a configuration name from available configs.
--- Harmony configs are named <product>-<target>-<abi>, all with mode=debug
--- by default. For "debug", return the first available configuration.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil matching configuration name
function M.map_variant(variant_type, available_configs)
    if #available_configs == 1 then
        return available_configs[1]
    end

    -- All harmony configs default to mode=debug, so map "debug" to first
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
    local td = project.tool_data or {}
    local env = td.deveco_home and hvigor_env(td) or {}

    -- Merge cmake_env from type_config (user-defined env vars for cmake)
    -- Supports ${workspace_root} expansion
    local tc = project.type_config or {}
    if tc.cmake_env then
        for k, v in pairs(tc.cmake_env) do
            -- Expand ${workspace_root}
            v = v:gsub("%${workspace_root}", project.workspace_root)
            env[k] = v
        end
    end

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

    -- Resolve product, target, ABI, and modules from configuration
    local config_info = project.configurations and project.configurations[active_config]
    local product = config_info and config_info.product or "default"
    local target = config_info and config_info.target or "default"
    local abi = config_info and config_info.abi
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

--- Return progress parser tool name.
function M.progress_parser()
    return "hvigor"
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
    local profile = parse_build_profile(path)
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

    -- Verify build dir prediction against native_work_dir.txt
    local notes = {}
    for cache_key, cached_config in pairs(cached) do
        if cached_config.build_dir and cached_config.state then
            local nwd_path = cached_config.build_dir .. "/native_work_dir.txt"
            local fd = uv.fs_open(nwd_path, "r", 438)
            if fd then
                local stat = uv.fs_fstat(fd)
                if stat then
                    local data = uv.fs_read(fd, stat.size, 0)
                    if data then
                        local actual = data:gsub("%s+$", ""):gsub("\\", "/")
                        local expected = cached_config.build_dir:gsub("\\", "/")
                        if actual ~= expected then
                            notes[#notes + 1] = "build dir mismatch for "
                                .. cache_key .. ": expected " .. expected
                                .. " but hvigor used " .. actual
                        end
                    end
                end
                uv.fs_close(fd)
            end
        end
    end

    return { needs_refresh = #reasons > 0, reasons = reasons, notes = notes }
end

-- ---------------------------------------------------------------------------
-- Device interface
-- ---------------------------------------------------------------------------

--- Return device launch target descriptors for the active configuration.
--- Harmony always offers "Run on device" for buildable configurations.
--- @param project_ctx loomworks.ModuleContext
--- @param active_config string
--- @return table[]
function M.device_targets(project_ctx, active_config)
    return {
        { id = "run-device", label = "Run on device", requires_device = true },
    }
end

--- Enumerate connected devices via hdc.
--- @param tool_data table
--- @param callback fun(devices: { serial: string, display_name: string, state: string }[])
function M.list_devices(tool_data, callback)
    local hdc = tool_data and tool_data.hdc
    if not hdc then
        -- Fall back to hdc on PATH
        hdc = vim.fn.exepath("hdc")
        if hdc == "" then hdc = nil end
    end
    if not hdc then
        vim.notify("loomworks/harmony: hdc not found (tool_data or PATH)",
            vim.log.levels.WARN)
        callback({})
        return
    end
    vim.notify("loomworks/harmony: using hdc at " .. hdc, vim.log.levels.INFO)

    local devices = {}
    local called = false
    local function finish()
        if called then return end
        called = true
        callback(devices)
    end

    vim.fn.jobstart({ hdc, "list", "targets" }, {
        stdout_buffered = true,
        stderr_buffered = true,
        on_stdout = function(_, data)
            for _, line in ipairs(data or {}) do
                local serial = vim.trim(line)
                if serial ~= "" and serial ~= "[Empty]" then
                    devices[#devices + 1] = {
                        serial = serial,
                        display_name = serial,
                        state = "online",
                    }
                end
            end
        end,
        on_stderr = function(_, data)
            local msg = table.concat(data or {}, "\n")
            if msg and msg ~= "" and vim.trim(msg) ~= "" then
                vim.notify("loomworks/harmony: hdc stderr: " .. msg,
                    vim.log.levels.WARN)
            end
        end,
        on_exit = function(_, code)
            if code ~= 0 then
                vim.notify("loomworks/harmony: hdc list targets exited " .. code,
                    vim.log.levels.WARN)
            end
            finish()
        end,
    })
end

--- Detect hdc/hap-install failure from output.
--- hdc exits 0 even on errors, so we must parse output. Two failure
--- shapes occur in the wild:
---   * Older `[Fail]` / `[F]` markers — emitted by some hdc subcommands.
---   * `error: ...` lines (often with an accompanying `code:<N>`) —
---     emitted by `hdc install` and the bundle-manager when signing,
---     bundle layout, or device-side install validation rejects the HAP.
--- The latter is what DevEco surfaces verbatim ("Install Failed:
--- error: failed to install bundle. code:9568320 error: no signature
--- file."). We match the same family and aggregate adjacent context
--- lines so the caller surfaces the full reason rather than just the
--- first matching token in isolation.
--- @param lines string[]
--- @return string|nil error message if failure detected
local function check_hdc_output(lines)
    --- @param s string
    --- @return boolean
    local function is_failure(s)
        if s:match("%[Fail%]") or s:match("^%[F%]") then return true end
        -- Case-insensitive `error:` prefix. Trim leading whitespace
        -- because hdc occasionally pads with spaces.
        local stripped = s:gsub("^%s+", "")
        if stripped:lower():match("^error:") then return true end
        return false
    end

    local hits = {}
    for i, line in ipairs(lines) do
        local trimmed = vim.trim(line)
        if trimmed ~= "" and is_failure(trimmed) then
            hits[#hits + 1] = trimmed
            -- Pick up adjacent `code:<N>` and follow-up `error:` lines
            -- (hdc emits the cause across multiple lines).
            local j = i + 1
            while j <= #lines do
                local next_line = vim.trim(lines[j])
                if next_line == "" then break end
                local lower = next_line:lower()
                if lower:match("^code:") or lower:match("^error:") then
                    hits[#hits + 1] = next_line
                    j = j + 1
                else
                    break
                end
            end
            break
        end
    end

    if #hits == 0 then return nil end
    return table.concat(hits, " ")
end

--- Return command spec for installing a HAP on a device.
--- Normalizes path separators: hdc on Windows requires backslashes and
--- treats forward-slash paths as relative, producing doubled paths.
--- Includes check_output to detect failures (hdc exits 0 on errors).
--- @param tool_data table
--- @param device_serial string
--- @param artifact_path string absolute path to HAP file
--- @return { cmd: string, args: string[], check_output: function }
function M.device_install(tool_data, device_serial, artifact_path)
    local path = artifact_path
    if is_win then path = path:gsub("/", "\\") end
    return {
        cmd = tool_data.hdc,
        args = { "-t", device_serial, "install", path },
        check_output = check_hdc_output,
    }
end

--- Return command spec for stopping a running app on a device.
--- Uses `aa force-stop -b <bundle>` — terminates the app process
--- rather than relying on signals, matches DevEco's stop behaviour.
--- @param tool_data table
--- @param device_serial string
--- @param bundle_name string
--- @return { cmd: string, args: string[], check_output: function }
function M.device_stop(tool_data, device_serial, bundle_name)
    return {
        cmd = tool_data.hdc,
        args = {
            "-t", device_serial, "shell", "aa", "force-stop",
            "-b", bundle_name,
        },
        check_output = check_hdc_output,
    }
end

--- Return command spec for launching an app on a device.
--- @param tool_data table
--- @param device_serial string
--- @param launch_info { bundle_name: string, ability_name: string }
--- @return { cmd: string, args: string[], check_output: function }
function M.device_launch(tool_data, device_serial, launch_info)
    return {
        cmd = tool_data.hdc,
        args = {
            "-t", device_serial, "shell", "aa", "start",
            "-a", launch_info.ability_name,
            "-b", launch_info.bundle_name,
        },
        check_output = check_hdc_output,
    }
end

--- Resolve the PID of a running app on a device by bundle name.
--- Executes `hdc -t <serial> shell pidof <bundle>`. `hdc` exits 0 even
--- when pidof returns nothing, so the caller parses stdout for a
--- numeric PID.
--- @param tool_data table
--- @param device_serial string
--- @param bundle_name string
--- @return { cmd: string, args: string[] }
function M.device_pid(tool_data, device_serial, bundle_name)
    return {
        cmd = tool_data.hdc,
        args = { "-t", device_serial, "shell", "pidof", bundle_name },
    }
end

--- Return a command spec that flushes the device's hilog buffers
--- (`hdc -t <serial> shell hilog -r`). Used right before starting a
--- log stream for a fresh launch so the view doesn't mix in stale
--- entries from previous sessions or unrelated system chatter.
--- Best-effort: errors here are non-fatal.
--- @param tool_data table
--- @param device_serial string
--- @return { cmd: string, args: string[] }
function M.device_log_clear(tool_data, device_serial)
    return {
        cmd = tool_data.hdc,
        args = { "-t", device_serial, "shell", "hilog", "-r" },
    }
end

--- Allowed log level values (D=debug, I=info, W=warn, E=error,
--- F=fatal). Used by `loomworks.set_device_log_level` to validate
--- caller input before the value is forwarded to the client-side
--- soft filter. Hilog `-L` is no longer applied at the device because
--- it interacts badly with native logging in practice (see
--- spec/modules/harmony.md §6.1).
M.HILOG_LEVELS = { D = true, I = true, W = true, E = true, F = true }

--- Default soft-filter level when nothing is specified.
M.HILOG_DEFAULT_LEVEL = "I"

--- Allowed hilog `-t` (log type) values. Used to validate `opts.type`.
M.HILOG_TYPES = { app = true, init = true, core = true, kmsg = true }

--- Return command spec for streaming device logs.
---
--- Invokes `hdc shell hilog ...` rather than `hdc hilog ...`: the
--- top-level `hdc hilog` subcommand is a passthrough dumper that
--- ignores filter flags, whereas `shell hilog` lets us apply filters
--- on-device where they actually work.
---
--- Volume reduction comes from `-P <pid>` when the caller knows the
--- app's PID — that limits the stream to the app's own process across
--- all log types, matching DevEco Studio's "All logs of selected App"
--- behaviour. The hilog `-L` (level) flag is **not** applied at the
--- device: in practice it suppresses some native log paths whose
--- effective level isn't always what the caller expects, so we filter
--- by level only on the client side via the soft filter (see
--- spec/modules/harmony.md §6.1).
---
--- Optional filters:
---   * `opts.pid`   → `-P <pid>` (filter by process id)
---   * `opts.type`  → `-t <type>` (`app`/`init`/`core`/`kmsg`); only
---     applied when explicitly requested. Invalid types are silently
---     dropped rather than rejected so callers don't have to validate.
---   * `opts.tag`   → `-T <tag>` (filter by hilog tag)
---
--- @param tool_data table
--- @param device_serial string
--- @param opts? { pid?: number, type?: string, tag?: string }
--- @return { cmd: string, args: string[] }
function M.device_log(tool_data, device_serial, opts)
    opts = opts or {}
    local args = {
        "-t", device_serial,
        "shell", "hilog",
    }
    if opts.type and M.HILOG_TYPES[opts.type] then
        args[#args + 1] = "-t"
        args[#args + 1] = opts.type
    end
    if opts.pid then
        args[#args + 1] = "-P"
        args[#args + 1] = tostring(opts.pid)
    end
    if opts.tag and opts.tag ~= "" then
        args[#args + 1] = "-T"
        args[#args + 1] = opts.tag
    end
    return {
        cmd = tool_data.hdc,
        args = args,
    }
end

--- Resolve the path to the built HAP artifact.
--- Searches the hvigor output directory for the most recently built HAP.
--- @param project_ctx table { path, workspace_root, tool_data, build_dir, config_info, configuration_key }
--- @param active_config string
--- @return string|nil absolute path to HAP file
function M.resolve_artifact(project_ctx, active_config)
    local ci = project_ctx.config_info or {}
    local product = ci.product or "default"
    local target = ci.target or "default"
    local module_name = ci.module_name
        or (ci.modules and ci.modules[1])
        or "entry"

    local abs_path = project_ctx.workspace_root .. "/" .. project_ctx.path

    -- hvigor HAP output convention:
    -- <project>/<module>/build/<product>/outputs/<target>/<module>-<product>-signed.hap
    -- The exact filename varies, so glob for *.hap and pick the most recent.
    local output_dir = abs_path .. "/" .. module_name .. "/build/"
        .. product .. "/outputs/" .. target

    local stat = uv.fs_stat(output_dir)
    if not stat then return nil end

    local best_path, best_mtime = nil, 0
    local handle = uv.fs_scandir(output_dir)
    if handle then
        while true do
            local name, type = uv.fs_scandir_next(handle)
            if not name then break end
            if name:match("%.hap$") then
                local full = output_dir .. "/" .. name
                local s = uv.fs_stat(full)
                if s and s.mtime and s.mtime.sec > best_mtime then
                    best_mtime = s.mtime.sec
                    best_path = full
                end
            end
        end
    end

    return best_path
end

--- Extract launch metadata from project files.
--- Reads bundle name from app.json5, ability name from module.json5.
--- @param project_path string absolute project path
--- @param config_info table configuration info with product, target, module_name
--- @param tool_data table
--- @return { bundle_name: string, ability_name: string }|nil
function M.resolve_launch_info(project_path, config_info, tool_data)
    local ci = config_info or {}
    local module_name = ci.module_name
        or (ci.modules and ci.modules[1])
        or "entry"

    local node = tool_data and tool_data.node

    -- Parse AppScope/app.json5 for bundleName
    local app_path = project_path .. "/AppScope/app.json5"
    local app_data, app_err = parse_json5(app_path, node)
    if not app_data then
        if app_err then report_parse_failure(app_path, app_err) end
        return nil
    end
    if not app_data.app or not app_data.app.bundleName then return nil end
    local bundle_name = app_data.app.bundleName

    -- Parse <module>/src/main/module.json5 for ability name
    local module_path = project_path .. "/" .. module_name .. "/src/main/module.json5"
    local module_data, module_err = parse_json5(module_path, node)
    if not module_data then
        if module_err then report_parse_failure(module_path, module_err) end
        return nil
    end
    if not module_data.module then return nil end
    local abilities = module_data.module.abilities
    if not abilities or #abilities == 0 then
        return nil
    end
    local ability_name = abilities[1].name
    if not ability_name then return nil end

    return {
        bundle_name = bundle_name,
        ability_name = ability_name,
    }
end

return M
