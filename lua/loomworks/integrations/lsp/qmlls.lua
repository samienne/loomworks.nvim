--- loomworks/integrations/lsp/qmlls.lua — QML language server integration.
---
--- Implements qmlls-specific wiring: cmd factory (injects `-b <build_dir>`
--- and `-I <import_path>` and an optional binary override), root_dir
--- factory, status extras, and active-set change detection for client
--- restart. qmlls resolves QML imports against the active profile's CMake
--- build directory, so a profile switch that moves the build dir must
--- restart the client.
---
--- Deliberately trimmed relative to clangd.lua: no OOM-adaptive `-j`
--- machinery, no log rotation, no `on_unexpected_exit`/`reset`. The generic
--- dispatcher tolerates their absence.
---
--- Self-registers with `loomworks.lsp` on load. Discovered automatically
--- by the registry scanning `lua/loomworks/integrations/lsp/*.lua` across
--- all runtime paths.

local uv = vim.uv or vim.loop
local normalize = vim.fs.normalize

-- Ensure `.qml` files reliably map to filetype `qml` even when the user's
-- setup doesn't already register it. qmlls only ever attaches to this
-- filetype, so the mapping is what makes the integration reachable.
vim.filetype.add({ extension = { qml = "qml" } })

local M = { server = "qmlls" }

--- Resolved qmlls command args keyed by normalized root_dir.
--- Populated by the cmd wrapper, read by get_resolved_cmd().
--- @type table<string, string[]>
local _resolved_cmd = {}

--- State tracking for detecting when qmlls needs restart on active_set_changed.
--- @type table<string, { binary: string|nil, build_dir: string|nil }>
local _client_state = {}

--- Expand ${ENV_VAR} patterns. Leaves unresolved refs unchanged.
--- @param s string
--- @return string
local function expand_env(s)
    return (s:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Resolve the qmlls binary from an entry (verifies existence).
--- @param entry table|nil qmlls entry with optional `binary` field
--- @return string|nil absolute path to qmlls binary
local function resolve_binary(entry)
    if not entry or not entry.binary then return nil end
    local expanded = expand_env(entry.binary)
    if uv.fs_stat(expanded) then return expanded end
    return nil
end

--- Resolve the build dir from an entry (verifies the directory exists).
--- @param entry table|nil
--- @return string|nil
local function resolve_build_dir(entry)
    if not entry or not entry.build_dir then return nil end
    local dir = entry.build_dir
    if not uv.fs_stat(dir) then return nil end
    return dir
end

--- Get the qmlls entry for a project by asking the core for this server.
--- @param project loomworks.Project
--- @return table|nil
local function entry_for(project)
    local lsp = require("loomworks.lsp")
    return lsp.entry_for_project(project, "qmlls")
end

--- Find the qmlls entry for a given root_dir by asking the core.
--- @param root_dir string|nil
--- @return loomworks.Project|nil project, table|nil entry
local function find_by_root(root_dir)
    if not root_dir then return nil, nil end
    local lsp = require("loomworks.lsp")
    return lsp.find_project_by_root("qmlls", root_dir)
end

-- ---------------------------------------------------------------------------
-- Arg building (pure — shared by cmd_factory and the test helper)
-- ---------------------------------------------------------------------------

--- Build the qmlls argv from a base cmd + an entry. Pure: no side effects,
--- no rpc. Injects the binary override (args[1]), `-b <build_dir>` when the
--- build dir exists on disk, and `-I <path>` for each extra import path.
--- Returns the argv plus a flag telling the caller whether a required
--- binary was missing (so cmd_factory can refuse to start).
--- @param base_cmd string[]
--- @param entry table|nil
--- @return string[] args, boolean required_binary_missing
local function build_args(base_cmd, entry)
    local args = vim.list_extend({}, base_cmd)

    local bin = resolve_binary(entry)
    if bin then
        args[1] = bin
    elseif entry and entry.binary and entry.binary_required then
        return args, true
    end

    local dir = resolve_build_dir(entry)
    if dir then
        args[#args + 1] = "-b"
        args[#args + 1] = dir
    end

    if entry and type(entry.import_paths) == "table" then
        for _, p in ipairs(entry.import_paths) do
            if type(p) == "string" then
                args[#args + 1] = "-I"
                args[#args + 1] = p
            end
        end
    end

    return args, false
end

--- Test-only handle on the pure arg builder. Exposed so we can assert the
--- argv shape (`-b`/`-I` injection) without spinning up a real qmlls
--- through cmd_factory.
--- @param entry table|nil
--- @param base_cmd? string[]
--- @return string[]
function M._build_args_for_tests(entry, base_cmd)
    return (build_args(base_cmd or { "qmlls" }, entry))
end

-- ---------------------------------------------------------------------------
-- Integration contract — consumed by loomworks.lsp
-- ---------------------------------------------------------------------------

--- Create a qmlls `cmd` function (for `vim.lsp.config` or lspconfig) that
--- injects `-b <build_dir>` / `-I <import_path>` and optionally overrides
--- the binary per project. Falls back to `base_cmd` when loomworks has no
--- data. Used by `build_config` and re-exported for users who prefer to
--- keep their own `vim.lsp.config` / `lspconfig` setup.
--- @param base_cmd string[] e.g. { "qmlls" }
--- @return fun(dispatchers: table, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.cmd_factory(base_cmd)
    return function(dispatchers, config)
        local _, entry = find_by_root(config.root_dir)
        local args, required_missing = build_args(base_cmd, entry)

        if required_missing then
            vim.schedule(function()
                vim.notify(
                    "loomworks.qmlls: required binary not found: " .. entry.binary
                    .. "\nlsp will not start for " .. (config.root_dir or "<unknown>"),
                    vim.log.levels.ERROR)
            end)
            error("loomworks.qmlls: binary_required and not found: " .. entry.binary)
        end

        if config.root_dir then
            _resolved_cmd[normalize(config.root_dir)] = vim.list_extend({}, args)
        end

        return vim.lsp.rpc.start(args, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

--- Create a `root_dir` function (for `vim.lsp.config` or lspconfig) that
--- uses the loomworks project's qmlls entry root_dir when the buffer's
--- project has one. Falls through to the provided fallback otherwise. Skips
--- excluded buffers (see `loomworks.lsp.excluded`) before any resolution.
--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
--- @return fun(bufnr: number, on_dir: fun(root: string))
function M.root_dir_factory(fallback)
    return function(bufnr, on_dir)
        if require("loomworks.lsp").excluded(bufnr) then return end
        local ok, lw = pcall(require, "loomworks")
        if ok then
            local project = lw.project_for_buf(bufnr)
            if project then
                local entry = entry_for(project)
                if entry and entry.root_dir then
                    on_dir(normalize(entry.root_dir))
                    return
                end
            end
        end
        if fallback then fallback(bufnr, on_dir) end
    end
end

--- Get resolved cmd args for a root_dir (used by status display).
--- @param root_dir string normalized root directory
--- @return string[]|nil
function M.get_resolved_cmd(root_dir)
    return _resolved_cmd[root_dir]
end

--- Default base cmd args when the user doesn't provide one.
local DEFAULT_CMD = { "qmlls" }
local DEFAULT_FILETYPES = { "qml" }
local DEFAULT_ROOT_MARKERS = { ".git", "CMakeLists.txt" }

--- Try to merge completion-plugin capabilities (cmp_nvim_lsp, blink.cmp)
--- into the base lsp capabilities. Zero-config convenience.
--- @return table
local function detect_capabilities()
    local caps = vim.lsp.protocol.make_client_capabilities()
    local ok_blink, blink = pcall(require, "blink.cmp")
    if ok_blink and blink.get_lsp_capabilities then
        return blink.get_lsp_capabilities(caps)
    end
    local ok_cmp, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
    if ok_cmp and cmp_nvim_lsp.default_capabilities then
        return vim.tbl_deep_extend("force", caps, cmp_nvim_lsp.default_capabilities())
    end
    return caps
end

--- Build the full `vim.lsp.config` payload. Called by `loomworks.lsp.setup_servers()`
--- when the user opts into loomworks-managed qmlls (the default).
---
--- User's `cmd` becomes the fallback base for buffers outside any workspace
--- project. Inside a workspace project, the profile's build dir wins.
--- User's `root_dir` (if a function) becomes the fallback for buffers
--- outside any workspace project. Defaults to `vim.fs.root(bufnr, root_markers)`.
--- Other user fields (`on_attach`, `capabilities`, `settings`, `on_exit`, …)
--- pass through unchanged.
--- @param user_cfg table|nil user-supplied overrides
--- @return table vim.lsp.config payload
function M.build_config(user_cfg)
    user_cfg = user_cfg or {}
    local base_cmd = user_cfg.cmd or DEFAULT_CMD
    local root_markers = user_cfg.root_markers or DEFAULT_ROOT_MARKERS
    local filetypes = user_cfg.filetypes or DEFAULT_FILETYPES

    local user_root_dir = type(user_cfg.root_dir) == "function"
        and user_cfg.root_dir or nil
    local root_dir_fallback = user_root_dir or function(bufnr, on_dir)
        local r = vim.fs.root(bufnr, root_markers)
        if r then on_dir(r) end
    end

    local config = vim.tbl_deep_extend("force", {}, user_cfg)
    config.cmd = M.cmd_factory(base_cmd)
    config.root_dir = M.root_dir_factory(root_dir_fallback)
    config.root_markers = root_markers
    config.filetypes = filetypes
    -- Wrap any user on_exit so loomworks' restart dispatcher gets every
    -- exit. The user callback still fires first inside the wrapper.
    config.on_exit = require("loomworks.lsp").wrap_on_exit("qmlls", user_cfg.on_exit)
    if not config.capabilities then
        config.capabilities = detect_capabilities()
    end
    return config
end

--- Should this integration be enabled by default when the user calls
--- `loomworks.setup({})` without an explicit `lsp` config? qmlls only ever
--- attaches to `qml` buffers, so auto-enabling is harmless for non-Qt users.
M.default_enable = true

--- Status-page extras for a qmlls entry.
--- @param entry table
--- @return table
function M.status_extras(entry)
    return {
        qmlls_build_dir = entry.build_dir,
        qmlls_bin = entry.binary,
        binary_required = entry.binary_required,
    }
end

-- ---------------------------------------------------------------------------
-- Auto-restart on profile/workspace changes
-- ---------------------------------------------------------------------------

--- @param root_dir string
--- @return vim.lsp.Client[]
local function find_clients(root_dir)
    local target = normalize(root_dir)
    local matches = {}
    for _, client in ipairs(vim.lsp.get_clients({ name = "qmlls" })) do
        if client.root_dir and normalize(client.root_dir) == target then
            matches[#matches + 1] = client
        end
    end
    return matches
end

local function restart_clients(clients)
    local lsp = require("loomworks.lsp")
    for _, client in ipairs(clients) do
        if client.root_dir then
            _resolved_cmd[normalize(client.root_dir)] = nil
        end
        -- Tell lsp.lua this exit is loomworks-initiated so the on_exit
        -- dispatcher skips the unexpected-death restart path.
        lsp.mark_managed_stop(client.id)
        client:stop()
    end
    vim.schedule(function() vim.lsp.enable("qmlls") end)
end

--- Detect qmlls state changes after a profile/active set change and restart
--- clients whose resolved build dir (or binary) moved.
function M.on_active_set_changed()
    local ok, lw = pcall(require, "loomworks")
    if not ok or not lw.get_workspace() then return end

    local new_state = {}
    for _, project in pairs(lw.get_projects()) do
        local entry = entry_for(project)
        if entry and entry.root_dir then
            local key = normalize(entry.root_dir)
            local new = {
                binary = resolve_binary(entry),
                build_dir = resolve_build_dir(entry),
            }
            new_state[key] = new

            local prev = _client_state[key]
            if prev and (prev.binary ~= new.binary
                    or prev.build_dir ~= new.build_dir) then
                local clients = find_clients(key)
                if #clients > 0 then
                    local parts = {}
                    if new.build_dir ~= prev.build_dir then
                        parts[#parts + 1] = "build_dir: " .. (new.build_dir or "none")
                    end
                    if new.binary ~= prev.binary then
                        parts[#parts + 1] = "binary: " .. (new.binary or "default")
                    end
                    vim.notify("loomworks: restarting qmlls for " .. project.key
                        .. (#parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""))
                    restart_clients(clients)
                end
            end
        end
    end
    _client_state = new_state
end

-- Self-register with the core LSP registry.
require("loomworks.lsp").register("qmlls", M)

return M
