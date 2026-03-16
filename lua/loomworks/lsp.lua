--- loomworks/lsp.lua — LSP integration helpers.
--- Provides factory functions for clangd configuration that inject
--- project-specific compile_commands_dir and clangd binary overrides.

local M = {}

local uv = vim.uv or vim.loop

--- Expand ${ENV_VAR} patterns in a string.
--- @param s string
--- @return string
local function expand_env(s)
    return (s:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Find the loomworks project matching a root_dir path.
--- @param root_dir string|nil absolute path (clangd root)
--- @return loomworks.Project|nil project
--- @return loomworks.Workspace|nil workspace
local function find_project_by_root(root_dir)
    if not root_dir then return nil, nil end

    local ok, lw = pcall(require, "loomworks")
    if not ok then return nil, nil end

    local ws = lw.get_workspace()
    if not ws then return nil, nil end

    local normalize = vim.fs.normalize
    local target = normalize(root_dir)

    local projects = lw.get_projects()
    for _, project in pairs(projects) do
        if project.type == "cmake" and project.path then
            local project_abs = normalize(ws.root .. "/" .. project.path)
            if project_abs == target then
                return project, ws
            end
        end
    end

    return nil, nil
end

--- Resolve the compile_commands.json directory for a cmake project.
--- Handles compile_commands_from redirect (e.g. MSVC sourcing from Ninja companion).
--- @param root_dir string|nil clangd root dir (= project source path)
--- @return string|nil compile_commands_dir
local function resolve_compile_commands_dir(root_dir)
    local project, ws = find_project_by_root(root_dir)
    if not project or not ws then return nil end

    local build_dir = nil

    -- Check compile_commands_from redirect
    if project.cmake and project.cmake.compile_commands_from then
        local ref_config = project.cmake.compile_commands_from
        local ref_key = project:config_cache_key(ref_config)
        local ref_cached = project.cached_configurations and project.cached_configurations[ref_key]
        if ref_cached and ref_cached.build_dir then
            build_dir = ref_cached.build_dir
        end
    end

    -- Default: active configuration's build_dir
    if not build_dir and project.cached and project.cached.build_dir then
        build_dir = project.cached.build_dir
    end

    if not build_dir then return nil end

    -- Verify compile_commands.json actually exists
    local cc_path = build_dir .. "/compile_commands.json"
    if not uv.fs_stat(cc_path) then return nil end

    return build_dir
end

--- Resolve the clangd binary for a cmake project.
--- Resolution order: project cmake.clangd (env-expanded) > tool_data.clangd_path > nil
--- @param root_dir string|nil clangd root dir (= project source path)
--- @return string|nil clangd_path
local function resolve_clangd_binary(root_dir)
    local project = find_project_by_root(root_dir)
    if not project then return nil end

    -- 1. Project-level override from loomworks.json cmake.clangd
    if project.cmake and project.cmake.clangd then
        local expanded = expand_env(project.cmake.clangd)
        if uv.fs_stat(expanded) then
            return expanded
        end
    end

    -- 2. Kit auto-detected clangd_path
    if project.tool_data and project.tool_data.clangd_path then
        if uv.fs_stat(project.tool_data.clangd_path) then
            return project.tool_data.clangd_path
        end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Public factory functions
-- ---------------------------------------------------------------------------

--- Create a clangd cmd function that injects --compile-commands-dir and
--- optionally overrides the clangd binary per-project.
--- Falls back to the base command when loomworks has no data.
--- @param base_cmd string[] e.g. { "clangd", "--background-index", "-j=12" }
--- @return fun(dispatchers: table, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.clangd_cmd(base_cmd)
    return function(dispatchers, config)
        local args = vim.list_extend({}, base_cmd)

        -- Override binary if loomworks resolves a project-specific one
        local bin = resolve_clangd_binary(config.root_dir)
        if bin then
            args[1] = bin
        end

        -- Inject --compile-commands-dir if available
        local dir = resolve_compile_commands_dir(config.root_dir)
        if dir then
            args[#args + 1] = "--compile-commands-dir=" .. dir
        end

        return vim.lsp.rpc.start(args, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

--- Create a root_dir function that uses loomworks project detection for
--- cmake projects, falling back to the provided function otherwise.
--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
--- @return fun(bufnr: number, on_dir: fun(root: string))
function M.clangd_root_dir(fallback)
    return function(bufnr, on_dir)
        local ok, lw = pcall(require, "loomworks")
        if ok then
            local _, project = lw.project_for_buf(bufnr)
            if project and project.type == "cmake" then
                local ws = lw.get_workspace()
                if ws then
                    on_dir(vim.fs.normalize(ws.root .. "/" .. (project.path or project.key)))
                    return
                end
            end
        end

        if fallback then
            fallback(bufnr, on_dir)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status query
-- ---------------------------------------------------------------------------

--- Get the resolved LSP configuration for all cmake projects.
--- @return table<string, { root_dir: string, compile_commands_dir: string|nil, clangd_bin: string|nil, clients: number }>
function M.get_status()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return {} end

    local ws = lw.get_workspace()
    if not ws then return {} end

    local status = {}
    local projects = lw.get_projects()
    for key, project in pairs(projects) do
        if project.type == "cmake" and project.path then
            local project_abs = vim.fs.normalize(ws.root .. "/" .. project.path)
            local clients = vim.lsp.get_clients({ name = "clangd" })
            local n_clients = 0
            for _, c in ipairs(clients) do
                if c.root_dir and vim.fs.normalize(c.root_dir) == project_abs then
                    n_clients = n_clients + 1
                end
            end

            status[key] = {
                root_dir = project_abs,
                compile_commands_dir = resolve_compile_commands_dir(project_abs),
                clangd_bin = resolve_clangd_binary(project_abs),
                clients = n_clients,
            }
        end
    end

    return status
end

-- ---------------------------------------------------------------------------
-- Automatic clangd restart on profile/workspace changes
-- ---------------------------------------------------------------------------

--- State tracking for detecting when clangd needs restart.
--- @type table<string, { build_dir: string|nil, clangd_bin: string|nil }>
local _client_state = {}
local _listener_registered = false

--- Find LSP clients matching name and root_dir.
--- @param name string
--- @param root_dir string
--- @return vim.lsp.Client[]
local function find_lsp_clients(name, root_dir)
    local normalize = vim.fs.normalize
    local target = normalize(root_dir)
    local clients = vim.lsp.get_clients({ name = name })
    local matches = {}
    for _, client in ipairs(clients) do
        if client.root_dir and normalize(client.root_dir) == target then
            matches[#matches + 1] = client
        end
    end
    return matches
end

--- Stop clients and re-enable clangd so open buffers get re-attached.
--- @param clients vim.lsp.Client[]
local function restart_clients(clients)
    for _, client in ipairs(clients) do
        client:stop()
    end
    vim.schedule(function()
        vim.lsp.enable("clangd")
    end)
end

--- Check if any clangd clients need restarting after a profile change.
local function on_active_set_changed()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return end

    local ws = lw.get_workspace()
    if not ws then return end

    local projects = lw.get_projects()
    local new_state = {}

    for key, project in pairs(projects) do
        if project.type ~= "cmake" or not project.path then goto continue end

        local project_abs = vim.fs.normalize(ws.root .. "/" .. project.path)
        local build_dir = resolve_compile_commands_dir(project_abs)
        local clangd_bin = resolve_clangd_binary(project_abs)

        new_state[project_abs] = { build_dir = build_dir, clangd_bin = clangd_bin }

        -- Compare with previous state
        local prev = _client_state[project_abs]
        if prev and (prev.build_dir ~= build_dir or prev.clangd_bin ~= clangd_bin) then
            local clients = find_lsp_clients("clangd", project_abs)
            if #clients > 0 then
                local parts = {}
                if build_dir ~= prev.build_dir then
                    parts[#parts + 1] = "compile_commands: " .. (build_dir or "none")
                end
                if clangd_bin ~= prev.clangd_bin then
                    parts[#parts + 1] = "binary: " .. (clangd_bin or "default")
                end
                vim.notify(
                    "loomworks: restarting clangd for " .. key
                        .. (#parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or "")
                )
                restart_clients(clients)
            end
        end

        ::continue::
    end

    _client_state = new_state
end

--- Restart all clangd clients when a workspace is first loaded.
--- Pre-existing clients were started without loomworks awareness and need
--- to re-attach with correct root_dir and compile_commands_dir.
local function on_workspace_changed()
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then return end

    vim.notify("loomworks: restarting " .. #clients .. " clangd client(s) for workspace integration")
    restart_clients(clients)
end

--- Ensure event listeners are registered (idempotent).
local function ensure_listener()
    if _listener_registered then return end
    _listener_registered = true

    local ok, lw = pcall(require, "loomworks")
    if ok then
        lw.on("active_set_changed", function()
            vim.schedule(on_active_set_changed)
        end)
        lw.on("workspace_changed", function()
            vim.schedule(on_workspace_changed)
        end)
    end
end

-- Register listeners when this module loads (lazy: only if someone requires lsp.lua)
ensure_listener()

return M
