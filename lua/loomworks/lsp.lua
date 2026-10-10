--- loomworks/lsp.lua — LSP dispatch layer.
---
--- Core has no knowledge of specific LSP servers. Server-specific wiring
--- lives in `lua/loomworks/integrations/lsp/<server>.lua`. On load, this
--- module scans every runtime path for those files and requires each one;
--- each integration self-registers via `M.register(name, integration)`.
---
--- The integration contract (all fields except `server` optional):
---
---   @class loomworks.LspIntegration
---   @field server string                                        -- must match entry.server
---   @field build_config? fun(user_cfg: table|nil): table        -- vim.lsp.config payload for setup_servers
---   @field default_enable? boolean                              -- install on `setup({})` with no explicit lsp opt
---   @field cmd_factory? fun(base_cmd: string[]): function       -- cmd function (used by build_config + lspconfig users)
---   @field root_dir_factory? fun(fallback?): function           -- root_dir function (used by build_config + lspconfig users)
---   @field get_resolved_cmd? fun(root_dir: string): string[]|nil
---   @field status_extras? fun(entry: table): table              -- fields for status page
---   @field withhold_reason? fun(entry: table): string|nil       -- §9.8: nil → may start; "unconfigured"/"no_db" → withhold (no client)
---   @field on_active_set_changed? fun()                         -- wired by lsp.lua
---   @field on_workspace_changed? fun()                          -- wired by lsp.lua
---   @field reconcile_on_attach? fun(client: vim.lsp.Client)     -- wired by lsp.lua (LspAttach); fix stale cmd from a startup race
---   @field on_owned_database_changed? fun(root_dir: string)     -- wired by lsp.lua (§9.7 nudge); reconcile-if-needed when an owned DB appears
---   @field on_lsp_options_changed? fun(payload: { server: string, key: string, value: any })
---                                                               -- wired by lsp.lua; fires after Workspace:set_lsp_option
---   @field on_unexpected_exit? fun(info: loomworks.LspExitInfo): loomworks.LspRestartDecision
---                                                               -- called when a managed client dies unexpectedly
---   @field reset? fun(root_dir: string)                          -- clear adaptive state for a root (UI "Reset" action)
---   @field reset_label? string                                  -- UI label for the reset action ("Reset clangd -j", …)
---   @field health_inventory? fun(ctx: loomworks.InventoryContext): loomworks.InventoryDeclaration[]
---                                                               -- re-export of the host-neutral companion
---                                                               -- `integrations/inventory/<server>.lua` (§9.3, §16.33)
---
--- @class loomworks.LspExitInfo
--- @field server string
--- @field root_dir string                                       -- normalized
--- @field exit_code number                                      -- process exit code
--- @field signal number                                         -- terminating signal (0 if none)
--- @field attempt integer                                       -- 1-based count of consecutive unexpected exits
--- @field args string[]                                         -- cmd args last used to start the client
---
--- @class loomworks.LspRestartDecision
--- @field restart boolean                                       -- if false, lsp.lua suppresses and notifies
--- @field args? string[]                                        -- override args for the next start (server still re-enables itself)
--- @field reason? string                                        -- short human message for notifications
---
--- Core routes by `entry.server` only — no server-specific branches.

local M = {}

-- Pre-register in package.loaded so integrations can require us during our
-- own discover() call without triggering a re-entrant load.
package.loaded["loomworks.lsp"] = M

local normalize = vim.fs.normalize

--- Case-folding path normalizer for prefix/equality comparisons that must hold
--- on a case-insensitive filesystem (Windows). Lowercases only on win32; the
--- filesystem-visible casing is preserved for display elsewhere.
local _is_win = vim.fn.has("win32") == 1
--- @param p string
--- @return string
local function norm_cmp(p)
    local n = normalize(p)
    return _is_win and n:lower() or n
end

--- @type table<string, loomworks.LspIntegration>
local _integrations = {}

-- ---------------------------------------------------------------------------
-- Buffer exclusion (applies to every integration uniformly)
-- ---------------------------------------------------------------------------

--- Default exclusion patterns. No language server handles these buffer
--- types well — they're backed by non-file URIs or are scratch/UI buffers.
--- @type { bufname_patterns: string[], buftypes: string[] }
local DEFAULT_EXCLUDES = {
    bufname_patterns = {
        "^diffview://",
        "^fugitive://",
        "^octo://",
        "^gitsigns://",
        "^term://",
    },
    buftypes = {
        "help", "quickfix", "prompt", "nofile", "terminal",
    },
}

--- Resolved excludes applied to every integration. `false` = skip
--- exclusion entirely. Set by `setup_servers()`.
--- @type { bufname_patterns: string[], buftypes: string[] }|false|nil
local _excludes = nil

--- Return a fresh deep copy of the default exclusion table so callers
--- can mutate it without affecting future calls.
--- @return { bufname_patterns: string[], buftypes: string[] }
function M.default_excludes()
    return vim.deepcopy(DEFAULT_EXCLUDES)
end

--- Resolve the user's excludes opt into a final table (or false).
--- @param opt table|function|false|nil
--- @return { bufname_patterns: string[], buftypes: string[] }|false
local function resolve_excludes(opt)
    if opt == false then return false end
    if opt == nil then return vim.deepcopy(DEFAULT_EXCLUDES) end
    if type(opt) == "function" then
        local result = opt(vim.deepcopy(DEFAULT_EXCLUDES))
        return result or false
    end
    if type(opt) == "table" then
        -- User-supplied table wholesale replaces defaults (missing fields
        -- default to empty lists so the check doesn't error).
        return {
            bufname_patterns = opt.bufname_patterns or {},
            buftypes = opt.buftypes or {},
        }
    end
    return vim.deepcopy(DEFAULT_EXCLUDES)
end

--- Check whether a buffer should be excluded from LSP attachment.
--- Consults the excludes resolved by `setup_servers()`.
--- @param bufnr integer
--- @return boolean
function M.excluded(bufnr)
    if _excludes == false or _excludes == nil then return false end
    local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
    for _, bt in ipairs(_excludes.buftypes or {}) do
        if buftype == bt then return true end
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    for _, pattern in ipairs(_excludes.bufname_patterns or {}) do
        if name:match(pattern) then return true end
    end
    return false
end

--- Wire a single LspAttach autocmd that detaches excluded buffers from
--- any managed integration. Idempotent — only registers once.
local _exclude_autocmd_registered = false
local function ensure_exclude_autocmd()
    if _exclude_autocmd_registered then return end
    _exclude_autocmd_registered = true
    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("loomworks.lsp.excludes", { clear = true }),
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            local integration = client and _integrations[client.name]
            if not integration then return end
            if M.excluded(args.buf) then
                vim.lsp.buf_detach_client(args.buf, client.id)
                return
            end
            -- Let the integration reconcile a client that may have started
            -- before loomworks finished loading (stale cmd — startup race).
            if integration.reconcile_on_attach then
                vim.schedule(function() integration.reconcile_on_attach(client) end)
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

-- Reserved `lsp_opts` keys that must not collide with integration names.
local RESERVED_SERVER_NAMES = { excludes = true }

--- Register an LSP integration. Called by each integration file on load.
--- @param server string
--- @param integration loomworks.LspIntegration
function M.register(server, integration)
    assert(not RESERVED_SERVER_NAMES[server],
        "loomworks.lsp: server name '" .. server .. "' is reserved")
    _integrations[server] = integration
end

--- Retrieve a registered integration.
--- @param server string
--- @return loomworks.LspIntegration|nil
function M.integration(server)
    return _integrations[server]
end

-- ---------------------------------------------------------------------------
-- Shared helpers for integrations (server-agnostic)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- lsp_configs() memoization (profile-switch hot path)
-- ---------------------------------------------------------------------------
--
-- On `active_set_changed`, every registered integration's
-- `on_active_set_changed` iterates every project and calls `entry_for_project`
-- → `entries_for` → `module.lsp_configs`. With N projects and K integrations
-- that recomputes `lsp_configs` N×K times per switch — and `lsp_configs` walks
-- the active profile, config units and tools each time. A no-op switch pays
-- the full cost for nothing; clangd and qmlls each pay it for the same project
-- on the same tick.
--
-- We memoize `entries_for` on a CONTENT key that captures everything that
-- determines the output: workspace + project identity, the active profile's
-- resolved config unit (build_dir, config_key, build state), the active tool
-- identity, the project's lsp-affecting `type_config`, and a generation counter
-- bumped when workspace-level lsp options change. A cache HIT returns the prior
-- entries WITHOUT calling `module.lsp_configs` again — so the second
-- integration on a tick is free, and a no-op switch is free. The key changes
-- the moment any determinant does, so a REAL switch recomputes exactly the
-- projects that actually moved.
--
-- Correctness note: the early return-on-hit is structured so that, were
-- `lsp_configs` to later carry an idempotent, mtime-guarded side effect (e.g.
-- generating compile_commands.json — as it does on another branch), a hit skips
-- the whole function, side effect included. Build state is part of the key, so
-- a configure/build that would change what the side effect emits also changes
-- the key and forces a recompute.

--- @type table<string, { key: string, entries: table[] }> project.key → memo
local _configs_memo = {}
--- Bumped on `lsp_options_changed` so every content key changes.
local _configs_generation = 0

--- Compute the content key for a project's `lsp_configs` output. Returns nil
--- when the project has no workspace (uncacheable — recompute every time).
--- Every component is an identity/value read; none touch the filesystem.
--- @param project loomworks.Project
--- @return string|nil
local function configs_memo_key(project)
    local ws = project._workspace
    if not ws then return nil end

    local parts = {
        "g", tostring(_configs_generation),
        "w", ws.root or "",
        "p", project.key or "",
    }

    local active = ws.get_active_profile and ws:get_active_profile() or nil
    parts[#parts + 1] = "prof"
    parts[#parts + 1] = active and active.key or ""
    if active and active.project then
        local pp = active:project(project.key)
        if pp then
            parts[#parts + 1] = "bd"
            parts[#parts + 1] = pp:build_dir() or ""
            parts[#parts + 1] = "ck"
            parts[#parts + 1] = pp:config_key() or ""
            parts[#parts + 1] = "st"
            parts[#parts + 1] = pp:status() or ""
            local tool = pp.tool_object and pp:tool_object() or nil
            parts[#parts + 1] = "tk"
            parts[#parts + 1] = tool and (tool.key or tostring(tool)) or ""
        end
    end

    -- Fallback determinants used by module.lsp_configs when there is no active
    -- profile (legacy active-config summary + the project's own tool_data
    -- clangd path). Cheap value reads; keep them in the key so the no-active
    -- path invalidates correctly too.
    parts[#parts + 1] = "cbd"
    parts[#parts + 1] = (project.cached and project.cached.build_dir) or ""
    parts[#parts + 1] = "tdc"
    parts[#parts + 1] = (project.tool_data and project.tool_data.clangd_path) or ""

    -- "Configured on this machine" of every unit of the project (spec §9.1):
    -- a module may redirect its database to a unit other than the active one,
    -- so any unit's configure/reset/delete must invalidate the memo.
    parts[#parts + 1] = "ch"
    if project.config_units and ws._config_units then
        for _, unit in ipairs(project:config_units()) do
            if unit.configured_here then
                parts[#parts + 1] = (unit.id or "?") .. "=" .. (unit:configured_here() and "1" or "0")
            end
        end
    end

    -- Per-project lsp overrides (clangd/qmlls binaries, qml_import_paths,
    -- compile_commands_from, *_required). vim.inspect sorts keys, so the
    -- serialization is stable across calls.
    parts[#parts + 1] = "tc"
    parts[#parts + 1] = project.type_config and vim.inspect(project.type_config) or ""

    return table.concat(parts, "\30")
end

--- Drop the whole memo (workspace swap — old projects are gone).
local function clear_configs_memo()
    _configs_memo = {}
end

--- Invalidate every key by advancing the generation. Cheaper than clearing and
--- lets each project recompute lazily on its next `entries_for`.
local function bump_configs_generation()
    _configs_generation = _configs_generation + 1
end

--- Fill in `db_state` (spec §8.4) on entries whose module omitted it, derived
--- from the project's active ConfigUnit: "ready" when it is configured on this
--- machine, "unconfigured" otherwise (no active profile / no unit included).
--- A project without a workspace (never the case at runtime) is left alone.
--- @param project loomworks.Project
--- @param entries table[]
local function derive_db_state(project, entries)
    local ws = project._workspace
    if not ws then return end
    local ready = nil
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.db_state == nil then
            if ready == nil then
                local profile = ws.get_active_profile and ws:get_active_profile() or nil
                local pp = profile and profile.project and profile:project(project.key) or nil
                ready = pp ~= nil and pp.configured_here ~= nil and pp:configured_here() == true
            end
            e.db_state = ready and "ready" or "unconfigured"
        end
    end
end

--- Return all lsp_configs() entries emitted by a project's module.
--- Content-memoized: a cache hit skips `module.lsp_configs` entirely.
--- Entries always carry `db_state` when the project has a workspace.
--- @param project loomworks.Project
--- @return table[]
local function entries_for(project)
    local mod = project._module and project._module.impl or nil
    if not mod or not mod.lsp_configs then return {} end

    local key = configs_memo_key(project)
    if key then
        local cached = _configs_memo[project.key]
        if cached and cached.key == key then
            return cached.entries
        end
    end

    local ok, entries = pcall(mod.lsp_configs, project)
    if not ok or type(entries) ~= "table" then return {} end
    derive_db_state(project, entries)

    if key then
        _configs_memo[project.key] = { key = key, entries = entries }
    end
    return entries
end

--- Return the first lsp_configs entry a project's module emits for a
--- given server, or nil.
--- @param project loomworks.Project
--- @param server string
--- @return table|nil
function M.entry_for_project(project, server)
    if not project then return nil end
    for _, e in ipairs(entries_for(project)) do
        if e.server == server then return e end
    end
    return nil
end

--- Locate the loomworks project for a (server, root_dir) pair.
--- @param server string
--- @param root_dir string|nil
--- @return loomworks.Project|nil, table|nil entry
function M.find_project_by_root(server, root_dir)
    if not root_dir then return nil, nil end
    local ok, lw = pcall(require, "loomworks")
    if not ok then return nil, nil end
    if not lw.get_workspace() then return nil, nil end

    local target = normalize(root_dir)
    for _, project in pairs(lw.get_projects()) do
        local entry = M.entry_for_project(project, server)
        if entry and entry.root_dir and normalize(entry.root_dir) == target then
            return project, entry
        end
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Auto-restart on unexpected client exit (generic; integrations decide policy)
-- ---------------------------------------------------------------------------

--- Throttle constants. Capped at 4 unexpected exits per 5-minute sliding
--- window. When the cap is hit, subsequent attempts are deferred until
--- the oldest timestamp falls out of the window. There is no give-up:
--- `:LspStop` is the user's hard kill (sets a per-root suppression flag
--- that lasts until the next manual `:LspStart` / attach).
local THROTTLE_COUNT = 4
local THROTTLE_WINDOW_MS = 5 * 60 * 1000

--- @type table<integer, true> client_id → set when we initiated the stop ourselves
local _managed_stop_ids = {}

--- @type table<integer, { server: string, root_dir: string }> recorded at LspAttach
local _client_records = {}

--- @type table<string, true> "<server>:<root_dir>" → true while user has stopped this LSP
local _suppressed = {}

--- @type table<string, integer[]> "<server>:<root_dir>" → attempt timestamps (vim.uv.now ms)
local _attempts = {}

--- @type table<string, integer[]> deferred-attempt count (for throttle test)
--- @diagnostic disable-next-line: unused-local
local _pending = {}

--- Compose the throttle key.
--- @param server string
--- @param root_dir string
--- @return string
local function attempt_key(server, root_dir)
    return server .. ":" .. normalize(root_dir or "")
end

--- Mark a client as being stopped by loomworks itself. The on_exit
--- handler then knows the exit isn't an "unexpected death" and won't
--- trigger the restart policy. Integrations call this before invoking
--- `client:stop()` from their own paths (e.g. active_set_changed).
--- @param client_id integer
function M.mark_managed_stop(client_id)
    if client_id then _managed_stop_ids[client_id] = true end
end

--- Set or clear the user-suppression flag for a (server, root) pair.
--- Called by the on_exit handler when it detects a clean external stop
--- (signal 0/SIGTERM, exit 0). Cleared on the next successful LspAttach
--- for that pair so a manual `:LspStart` un-suppresses naturally.
--- @param server string
--- @param root_dir string
--- @param value boolean
local function set_suppressed(server, root_dir, value)
    _suppressed[attempt_key(server, root_dir)] = value or nil
end

--- Test whether auto-restart is currently suppressed for a (server, root)
--- pair (i.e. the user ran `:LspStop`). Public so the UI reset action
--- can clear it.
--- @param server string
--- @param root_dir string
--- @return boolean
function M.is_suppressed(server, root_dir)
    return _suppressed[attempt_key(server, root_dir)] == true
end

--- Clear suppression for a (server, root) pair — used by the UI Reset
--- action so the user can recover from a stop without invoking
--- `:LspStart` themselves.
--- @param server string
--- @param root_dir string
function M.clear_suppression(server, root_dir)
    set_suppressed(server, root_dir, false)
end

--- Throttle gate. Returns `true, 0` when an attempt may proceed now;
--- returns `false, wait_ms` when the caller should defer.
--- @param server string
--- @param root_dir string
--- @return boolean, integer
local function throttle_check(server, root_dir)
    local key = attempt_key(server, root_dir)
    local now = (vim.uv or vim.loop).now()
    local kept = {}
    for _, ts in ipairs(_attempts[key] or {}) do
        if now - ts < THROTTLE_WINDOW_MS then kept[#kept + 1] = ts end
    end
    _attempts[key] = kept
    if #kept >= THROTTLE_COUNT then
        return false, THROTTLE_WINDOW_MS - (now - kept[1]) + 100
    end
    return true, 0
end

--- Record an attempt for throttle accounting. Caller has already
--- consulted `throttle_check`; this just stamps a fresh timestamp.
--- @param server string
--- @param root_dir string
local function throttle_record(server, root_dir)
    local key = attempt_key(server, root_dir)
    _attempts[key] = _attempts[key] or {}
    _attempts[key][#_attempts[key] + 1] = (vim.uv or vim.loop).now()
end

--- @param server string
--- @param root_dir string
--- @return integer how many unexpected exits have happened within the current window
local function attempt_count(server, root_dir)
    local key = attempt_key(server, root_dir)
    return #(_attempts[key] or {})
end

--- Reset per-root attempt accounting. Called by the UI Reset action so
--- the user can recover from throttling without waiting out the window,
--- and called automatically once a client has been alive long enough
--- to count as "recovered."
--- @param server string
--- @param root_dir string
function M.reset_attempts(server, root_dir)
    _attempts[attempt_key(server, root_dir)] = nil
end

--- Wrap a user-provided on_exit so loomworks gets to inspect every exit
--- and dispatch to the integration's restart policy. Integrations call
--- this from inside `build_config()`; user_on_exit (if present in the
--- merged user_cfg) still runs first so user-side cleanup isn't dropped.
--- @param server string
--- @param user_on_exit function|nil
--- @return function
function M.wrap_on_exit(server, user_on_exit)
    return function(code, signal, client_id)
        if user_on_exit then pcall(user_on_exit, code, signal, client_id) end

        local managed = _managed_stop_ids[client_id]
        _managed_stop_ids[client_id] = nil

        local record = _client_records[client_id]
        _client_records[client_id] = nil
        local root_dir = record and record.root_dir or nil
        if not root_dir then return end

        -- We initiated this stop (mark_managed_stop). Don't react.
        if managed then return end

        -- Clean external stop (`:LspStop`, normal shutdown). Suppress
        -- auto-restart until the user re-attaches.
        local clean = code == 0 and (signal == 0 or signal == 15)
        if clean then
            set_suppressed(server, root_dir, true)
            return
        end

        -- Unexpected death — dispatch to the integration's policy.
        local integration = _integrations[server]
        if not integration or not integration.on_unexpected_exit then return end

        local args = integration.get_resolved_cmd
            and integration.get_resolved_cmd(root_dir) or nil
        local decision = integration.on_unexpected_exit({
            server = server,
            root_dir = root_dir,
            exit_code = code,
            signal = signal,
            attempt = attempt_count(server, root_dir) + 1,
            args = args or {},
        }) or { restart = true }

        if not decision.restart then
            vim.schedule(function()
                vim.notify("loomworks.lsp: " .. server .. " stopped restarting"
                    .. (decision.reason and (" (" .. decision.reason .. ")") or ""),
                    vim.log.levels.WARN)
            end)
            return
        end

        local function do_restart()
            throttle_record(server, root_dir)
            -- We don't programmatically push the new args back into
            -- vim.lsp.config — the integration's cmd_factory closure
            -- reads its own per-root state and injects them at the
            -- next start. Just re-enable the server so nvim spawns it.
            vim.lsp.enable(server)
            if decision.reason then
                vim.notify("loomworks.lsp: restarting " .. server
                    .. " (" .. decision.reason .. ")", vim.log.levels.INFO)
            end
        end

        local ok, wait_ms = throttle_check(server, root_dir)
        if ok then
            vim.schedule(do_restart)
        else
            vim.notify("loomworks.lsp: " .. server
                .. " hit restart throttle, waiting "
                .. math.ceil(wait_ms / 1000) .. "s",
                vim.log.levels.WARN)
            vim.defer_fn(do_restart, wait_ms)
        end
    end
end

--- Record the (server, root_dir) of every managed client on attach so
--- the on_exit dispatcher (which receives only `client_id`) can look up
--- what died. Also clears the suppression flag for the pair — a fresh
--- attach means the user re-enabled it.
local _restart_autocmd_registered = false
local function ensure_restart_autocmd()
    if _restart_autocmd_registered then return end
    _restart_autocmd_registered = true
    vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("loomworks.lsp.restart", { clear = true }),
        callback = function(args)
            local client = vim.lsp.get_client_by_id(args.data.client_id)
            if not client or not _integrations[client.name] then return end
            _client_records[client.id] = {
                server = client.name,
                root_dir = client.root_dir or "",
            }
            set_suppressed(client.name, client.root_dir or "", false)
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Generic factory dispatch (for user config)
-- ---------------------------------------------------------------------------

--- Create a cmd function for lspconfig — delegates to the integration.
--- @param server string
--- @param base_cmd string[]
--- @return function
function M.cmd(server, base_cmd)
    local i = _integrations[server]
    assert(i and i.cmd_factory,
        "loomworks.lsp: no cmd_factory for server '" .. server .. "'")
    return i.cmd_factory(base_cmd)
end

--- Create a root_dir function for lspconfig — delegates to the integration.
--- @param server string
--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
--- @return function
function M.root_dir(server, fallback)
    local i = _integrations[server]
    assert(i and i.root_dir_factory,
        "loomworks.lsp: no root_dir_factory for server '" .. server .. "'")
    return i.root_dir_factory(fallback)
end

-- ---------------------------------------------------------------------------
-- Deferred server start until workspace-ready (spec §9.7 / invariant 16)
-- ---------------------------------------------------------------------------
--
-- Neovim starts a client for a buffer only once the server's `root_dir`
-- function invokes its async `on_dir` callback. loomworks owns that function
-- for the servers it installs, so it can WITHHOLD the callback for a buffer
-- under the workspace root while the workspace is still initializing AND the
-- active profile's owned compilation database is being generated, then release
-- it once that database is ready (spec §9.7) — so the server starts exactly
-- once with the resolved binary + a populated compile_commands_dir instead of
-- starting against a default config and being restarted moments later.

--- Held root_dir requests, queued while the workspace is initializing.
--- @type { bufnr: integer, on_dir: fun(root: string), resolve: fun(bufnr: integer, on_dir: fun(root: string)), server?: string }[]
local _gate_queue = {}

--- Per-buffer LSP status (spec §9.8), per managed server.
--- @type table<integer, table<string, loomworks.LspBufState>>
local _buf_state = {}
--- Forward declaration — defined with the §9.8 machinery below.
local set_buf_state
--- Safety-timeout handle, armed when the first buffer is queued.
--- @type uv.uv_timer_t|nil
local _gate_timer = nil
--- Bounded safety timeout (ms). Overridable in tests via `M._gate_timeout_ms`.
local GATE_TIMEOUT_MS = 5000

--- The configured workspace root (known even during init), or nil.
--- @return string|nil
local function workspace_root()
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw.workspace_root) ~= "function" then return nil end
    return lw.workspace_root()
end

--- Whether a buffer's file lives under `root` (boundary-aware prefix check).
--- @param bufnr integer
--- @param root string
--- @return boolean
local function buf_under_root(bufnr, root)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if not name or name == "" then return false end
    local p, r = norm_cmp(name), norm_cmp(root):gsub("/+$", "")
    return p == r or p:sub(1, #r + 1) == r .. "/"
end

--- Whether a LOADED workspace exists AND its owned LSP databases are ready.
--- Distinct from `lsp_ready()` alone: before any workspace is loaded (the first
--- setup with no root, or before auto-load runs on session restore) `lsp_ready()`
--- reports ready-to-resolve, but a buffer belonging to a loomworks workspace must
--- still be HELD — so readiness here requires a live workspace object.
--- @return boolean
local function workspace_loaded_and_ready()
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw.get_workspace) ~= "function" then return true end
    if not lw.get_workspace() then return false end
    return type(lw.lsp_ready) == "function" and lw.lsp_ready() == true
end

--- Whether a workspace load is pending: a root is configured but no live
--- workspace object exists yet and readiness is not reported (Core reports
--- ready-to-resolve when nothing is pending, §9.7).
--- @return boolean
local function workspace_pending()
    local ok, lw = pcall(require, "loomworks")
    if not ok or type(lw.lsp_ready) ~= "function" then return false end
    return lw.lsp_ready() ~= true
end

--- Detect the loomworks workspace root a buffer belongs to by walking up from
--- its path for a workspace marker. Lets the gate hold a session-restored buffer
--- whose clangd resolves BEFORE auto-load has told loomworks the root (§9.7).
--- Returns nil when the buffer is not inside any loomworks workspace.
--- @param bufnr integer
--- @return string|nil
local function detect_workspace_root(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if not name or name == "" then return nil end
    local uv = vim.uv
    for cur in vim.fs.parents(name) do
        -- The §9.7 markers — the same two that make a directory a workspace
        -- root for auto-load (root_finder). A cache file alone is not one.
        if uv.fs_stat(cur .. "/loomworks.json")
            or uv.fs_stat(cur .. "/.nvim/loomworks.user.json") then
            return cur
        end
    end
    return nil
end

--- Disarm and close the safety timer (idempotent).
local function gate_disarm_timer()
    if _gate_timer then
        _gate_timer:stop()
        if not _gate_timer:is_closing() then _gate_timer:close() end
        _gate_timer = nil
    end
end

--- Release every queued buffer by running its resolver. For a managed server
--- (§9.8) the resolver decides start / withhold / fallback; for a plain gated
--- resolver it is the integration's own routing. Drops entries whose buffer is
--- gone. Used both on the ready signal and on the terminal drains.
local function gate_release()
    gate_disarm_timer()
    local pending = _gate_queue
    _gate_queue = {}
    for _, e in ipairs(pending) do
        if vim.api.nvim_buf_is_valid(e.bufnr) then
            pcall(e.resolve, e.bufnr, e.on_dir)
        end
    end
end

--- Arm the safety timeout (once). If no readiness/failure signal arrives, the
--- queue drains through each buffer's resolver so a buffer never stays in the
--- hold (§9.7). A managed resolver never starts a database-less server for a
--- buffer under the workspace root — it withholds instead (§9.8).
local function gate_arm_timer()
    if _gate_timer then return end
    _gate_timer = vim.uv.new_timer()
    local ms = M._gate_timeout_ms or GATE_TIMEOUT_MS
    _gate_timer:start(ms, 0, function()
        vim.schedule(gate_release)
    end)
end

--- Reset gate state on a workspace swap/reload: drain any held buffers (so
--- none hang across the reload) and clear the timer.
local function gate_reset()
    gate_release()
end

--- Route an integration's `root_dir` resolution through the readiness gate
--- (§9.7). `resolve(bufnr, on_dir)` is the integration's existing resolution
--- logic (routed → project entry, else fallback). Behavior:
---   * workspace ready, OR no known workspace root → resolve now;
---   * buffer NOT under the workspace root → resolve now (never held);
---   * under-root AND not-ready → queue; do not call on_dir yet.
--- Excluded buffers are handled by the integration BEFORE calling this, so they
--- always take the immediate fall-through.
--- @param bufnr integer
--- @param on_dir fun(root: string)
--- @param resolve fun(bufnr: integer, on_dir: fun(root: string))
--- @param server? string managed server name — records the per-buffer `held` status (§9.8)
function M.gated_root_dir(bufnr, on_dir, resolve, server)
    -- Ready: a workspace is loaded and its owned databases are in place.
    if workspace_loaded_and_ready() then
        return resolve(bufnr, on_dir)
    end
    -- Not ready. Hold only if this buffer belongs to a loomworks workspace — the
    -- configured (pending/loaded) root, else one detected from the buffer's own
    -- path (session-restored buffers resolve before auto-load sets the root).
    local root = workspace_root() or detect_workspace_root(bufnr)
    if not root or not buf_under_root(bufnr, root) then
        return resolve(bufnr, on_dir)
    end
    _gate_queue[#_gate_queue + 1] = { bufnr = bufnr, on_dir = on_dir, resolve = resolve, server = server }
    if server then set_buf_state(bufnr, server, "held") end
    gate_arm_timer()
end

--- Test seam: current number of held buffers.
--- @return integer
function M._gate_queue_len() return #_gate_queue end

--- Test seam: reset gate state (drain + clear timer).
function M._reset_gate() gate_reset() end

-- ---------------------------------------------------------------------------
-- Withheld servers for buffers without a usable database (spec §9.8)
-- ---------------------------------------------------------------------------
--
-- For an integration that implements `withhold_reason(entry)`, the root_dir
-- resolution of every buffer under the workspace root goes through
-- `managed_root_dir`: the buffer is routed to its project's entry (or, outside
-- every project, to the workspace entry — the first usable entry in project-key
-- order) and the server is started ONLY when the integration says the entry
-- can back it. Otherwise the buffer joins the withheld set: `on_dir` is not
-- called, no client exists. `reevaluate()` re-runs the decision on every change
-- that can flip it (profile switch, configure/reset/delete, owned DB written,
-- workspace swap): newly usable buffers get their attach re-run, clients whose
-- buffers became withheld are stopped through the managed-stop path.

--- Buffers currently withheld (or parked `held` after the gate), per server.
--- @type table<integer, table<string, true>>
local _withheld = {}
--- Root of a workspace whose initialization failed (`workspace_changed` with no
--- workspace). Buffers under it are withheld with `withheld_error` until a
--- later load succeeds.
--- @type string|nil
local _ws_failed_root = nil

--- Record (or clear) the root of a workspace whose initialization failed.
--- @param root string|nil
function M._set_failed_root(root)
    _ws_failed_root = root
end

--- Severity order for aggregating a buffer's per-server statuses.
local STATE_RANK = {
    none = 0, ok = 1, held = 2,
    withheld_no_db = 3, withheld_unconfigured = 4, withheld_error = 5,
}

--- Record a buffer's status for one server; redraws statuslines on change.
--- @param bufnr integer
--- @param server string
--- @param status loomworks.LspBufState
set_buf_state = function(bufnr, server, status)
    local t = _buf_state[bufnr]
    if not t then
        t = {}
        _buf_state[bufnr] = t
    end
    if t[server] == status then return end
    t[server] = status
    vim.schedule(function()
        local ok_ev, events = pcall(require, "loomworks.events")
        if ok_ev then
            pcall(events.emit, "lsp_buf_state_changed",
                { bufnr = bufnr, server = server, state = status })
        end
        pcall(vim.cmd, "redrawstatus")
    end)
end

--- The buffer's per-buffer LSP status (spec §9.8): the most severe status over
--- every managed server routed for it; `none` when loomworks has no opinion.
--- @param bufnr? integer defaults to the current buffer
--- @return loomworks.LspBufState
function M.buf_state(bufnr)
    if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    local t = _buf_state[bufnr]
    if not t then return "none" end
    local best, rank = "none", 0
    for _, st in pairs(t) do
        local r = STATE_RANK[st] or 0
        if r > rank then best, rank = st, r end
    end
    return best
end

--- Ask an integration whether `entry` must be withheld. nil → may start.
--- @param integration loomworks.LspIntegration|nil
--- @param entry table
--- @return string|nil reason
--- Per-pass memo (entry table → reason) so one re-evaluation over many
--- buffers stats each entry's database once. Only set during `reevaluate_now`.
--- @type table<table, string|false>|nil
local _reason_memo = nil

local function withhold_reason(integration, entry)
    if not integration or not integration.withhold_reason then return nil end
    if _reason_memo and _reason_memo[entry] ~= nil then
        return _reason_memo[entry] or nil
    end
    local ok, reason = pcall(integration.withhold_reason, entry)
    if not ok then reason = nil end
    if _reason_memo then _reason_memo[entry] = reason or false end
    return reason
end

--- The workspace entry for a buffer under the root that belongs to no project
--- (spec §9.8 *Decision*): the first usable entry over the projects in key
--- order. Returns (entry) when one is usable, (nil, reason) when entries exist
--- but none is usable, (nil, nil) when no project emits an entry.
--- @param lw table loomworks facade
--- @param server string
--- @return table|nil entry, string|nil reason
local function workspace_entry(lw, server)
    local integration = _integrations[server]
    local projects = {}
    local all = type(lw.get_projects) == "function" and lw.get_projects() or {}
    for _, p in pairs(all) do projects[#projects + 1] = p end
    table.sort(projects, function(a, b) return (a.key or "") < (b.key or "") end)
    local any, any_unconfigured = false, false
    for _, project in ipairs(projects) do
        local entry = M.entry_for_project(project, server)
        if entry and entry.root_dir then
            any = true
            local reason = withhold_reason(integration, entry)
            if not reason then return entry, nil end
            if reason == "unconfigured" then any_unconfigured = true end
        end
    end
    if not any then return nil, nil end
    return nil, any_unconfigured and "unconfigured" or "no_db"
end

--- Decide what a managed server should do for a buffer right now (§9.8).
--- Returns the status and, for `ok`, the entry whose root the client uses.
--- `none` means "take the fallback path" (outside the workspace root, or no
--- entry for the server).
--- @param server string
--- @param bufnr integer
--- @return loomworks.LspBufState status, table|nil entry
local function decide(server, bufnr)
    local ok, lw = pcall(require, "loomworks")
    if not ok then return "none", nil end
    local ws = type(lw.get_workspace) == "function" and lw.get_workspace() or nil

    if not ws then
        if _ws_failed_root and buf_under_root(bufnr, _ws_failed_root) then
            return "withheld_error", nil
        end
        -- A workspace is being loaded for this buffer's root (setup pending,
        -- not yet ready): no live workspace object yet, never start (§9.7
        -- safety timeout) — it is resolved when that load lands or fails.
        -- Anything else — a workspace marker on disk that nobody is loading,
        -- or a workspace that was shut down — takes the fallback: no loaded
        -- workspace means the user's stock server (§9.8).
        local root = workspace_root()
        if root and buf_under_root(bufnr, root) and workspace_pending() then
            return "held", nil
        end
        return "none", nil
    end

    local integration = _integrations[server]
    local project = type(lw.project_for_buf) == "function" and lw.project_for_buf(bufnr) or nil
    if project then
        local entry = M.entry_for_project(project, server)
        if not entry or not entry.root_dir then return "none", nil end
        local reason = withhold_reason(integration, entry)
        if reason then return "withheld_" .. reason, nil end
        return "ok", entry
    end

    -- Not in any project: only buffers under the workspace root are routed.
    local root = ws.root or workspace_root()
    if not root or not buf_under_root(bufnr, root) then return "none", nil end

    local entry, reason = workspace_entry(lw, server)
    if entry then return "ok", entry end
    if reason then return "withheld_" .. reason, nil end
    return "none", nil
end

--- @param bufnr integer
--- @param server string
local function mark_withheld(bufnr, server)
    local t = _withheld[bufnr]
    if not t then
        t = {}
        _withheld[bufnr] = t
    end
    t[server] = true
end

--- @param bufnr integer
--- @param server string
local function clear_withheld(bufnr, server)
    local t = _withheld[bufnr]
    if not t then return end
    t[server] = nil
    if not next(t) then _withheld[bufnr] = nil end
end

--- Resolve a managed server's root for a buffer (after the gate): start on the
--- routed entry, withhold, or take the fallback.
--- @param server string
--- @param bufnr integer
--- @param on_dir fun(root: string)
--- @param fallback? fun(bufnr: integer, on_dir: fun(root: string))
local function resolve_managed(server, bufnr, on_dir, fallback)
    local status, entry = decide(server, bufnr)
    set_buf_state(bufnr, server, status)
    if status == "ok" and entry then
        clear_withheld(bufnr, server)
        on_dir(normalize(entry.root_dir))
    elseif status == "none" then
        clear_withheld(bufnr, server)
        if fallback then fallback(bufnr, on_dir) end
    else
        mark_withheld(bufnr, server)
    end
end

--- root_dir resolution for a server whose integration implements
--- `withhold_reason` (spec §9.7 hold + §9.8 decision). Excluded buffers never
--- get the server and are never held.
--- @param server string
--- @param bufnr integer
--- @param on_dir fun(root: string)
--- @param fallback? fun(bufnr: integer, on_dir: fun(root: string)) stock resolution for buffers outside the workspace
function M.managed_root_dir(server, bufnr, on_dir, fallback)
    if M.excluded(bufnr) then return end
    M.gated_root_dir(bufnr, on_dir, function(b, od)
        resolve_managed(server, b, od, fallback)
    end, server)
end

--- Start ONE managed server for one buffer the way Neovim's `vim.lsp.enable`
--- auto-attach does (Neovim 0.11+): filetype check, `root_dir` (so the gate +
--- §9.8 decision run again), then `vim.lsp.start` with the config's
--- `reuse_client` — an existing client for the same root is reused, never
--- duplicated. Only `server` is touched: re-running the `FileType` autocmd
--- would also re-resolve (and possibly detach or start) every OTHER enabled
--- config for the buffer.
---
--- Requires the server to be enabled through `vim.lsp.config` +
--- `vim.lsp.enable` (the §9.4 default path, or a user config built on it).
--- Anything else (a legacy lspconfig `setup{}`, a manual `vim.lsp.start`) is
--- not re-attached: the buffer gets its server on its next attach (reopen).
--- @param server string
--- @param bufnr integer
--- @return boolean started whether an attach was attempted
local function start_enabled_server(server, bufnr)
    if not (vim.lsp.config and vim.lsp.is_enabled) then return false end
    if not vim.lsp.is_enabled(server) then return false end
    local cfg = vim.lsp.config[server]
    if not cfg then return false end
    local bt = vim.bo[bufnr].buftype
    if bt ~= "" and bt ~= "help" then return false end
    if type(cfg.filetypes) == "table"
        and not vim.tbl_contains(cfg.filetypes, vim.bo[bufnr].filetype) then
        return false
    end
    cfg = vim.deepcopy(cfg)
    cfg.name = cfg.name or server
    local function start()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.lsp.start(cfg, {
            bufnr = bufnr,
            reuse_client = cfg.reuse_client,
            _root_markers = cfg.root_markers,
        })
    end
    if type(cfg.root_dir) == "function" then
        cfg.root_dir(bufnr, function(root)
            cfg.root_dir = root
            vim.schedule(start)
        end)
    else
        start()
    end
    return true
end

--- Re-run the attach of the given managed servers for one buffer, so a
--- withheld buffer whose entry became usable gets its server started without
--- being reopened. The attach goes through `root_dir` again (and so through
--- the gate + decision). Replaceable in tests.
--- @param bufnr integer
--- @param servers table<string, true>
function M._retrigger_attach(bufnr, servers)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    for server in pairs(servers or {}) do
        pcall(start_enabled_server, server, bufnr)
    end
end

--- One re-evaluation pass over withheld buffers and running managed clients.
--- Collects the (buffer → servers) attaches to re-run into `retrigger`.
--- @param retrigger table<integer, table<string, true>>
local function reevaluate_pass(retrigger)
    -- 1. Withheld buffers whose entry became usable (or that left the
    --    workspace): re-run their attach.
    for bufnr, servers in pairs(_withheld) do
        if not vim.api.nvim_buf_is_valid(bufnr) then
            _withheld[bufnr] = nil
            _buf_state[bufnr] = nil
        else
            for server in pairs(servers) do
                local status = decide(server, bufnr)
                set_buf_state(bufnr, server, status)
                if status == "ok" or status == "none" then
                    servers[server] = nil
                    retrigger[bufnr] = retrigger[bufnr] or {}
                    retrigger[bufnr][server] = true
                end
            end
            if not next(servers) then _withheld[bufnr] = nil end
        end
    end

    -- 2. Running clients whose buffers became withheld or now route to another
    --    entry: stop (managed — no auto-restart, no suppression) or detach.
    for server, integration in pairs(_integrations) do
        if integration.withhold_reason then
            for _, client in ipairs(vim.lsp.get_clients({ name = server })) do
                local croot = client.root_dir and norm_cmp(client.root_dir) or nil
                local keep, moved = 0, {}
                for bufnr in pairs(client.attached_buffers or {}) do
                    if vim.api.nvim_buf_is_valid(bufnr) then
                        local status, entry = decide(server, bufnr)
                        if status == "none"
                            or (status == "ok" and entry and croot
                                and norm_cmp(entry.root_dir) == croot) then
                            keep = keep + 1
                        else
                            moved[#moved + 1] = { bufnr = bufnr, status = status }
                        end
                    end
                end
                if #moved > 0 then
                    if keep == 0 then
                        M.mark_managed_stop(client.id)
                        client:stop()
                    else
                        for _, m in ipairs(moved) do
                            pcall(vim.lsp.buf_detach_client, m.bufnr, client.id)
                        end
                    end
                    for _, m in ipairs(moved) do
                        set_buf_state(m.bufnr, server, m.status)
                        if m.status == "ok" then
                            retrigger[m.bufnr] = retrigger[m.bufnr] or {}
                            retrigger[m.bufnr][server] = true
                        else
                            mark_withheld(m.bufnr, server)
                        end
                    end
                end
            end
        end
    end
end

--- Re-evaluate every withheld buffer and every running managed client now.
local function reevaluate_now()
    local retrigger = {}
    _reason_memo = setmetatable({}, { __mode = "k" })
    local ok, err = pcall(reevaluate_pass, retrigger)
    _reason_memo = nil
    if not ok then error(err) end
    -- Outside the pass: the re-run attach resolves against live state.
    for bufnr, servers in pairs(retrigger) do M._retrigger_attach(bufnr, servers) end
end

local _reeval_pending = false

--- Schedule a re-evaluation of the withheld decision (§9.8). Coalesced: any
--- number of calls within one tick run it once.
function M.reevaluate()
    if _reeval_pending then return end
    _reeval_pending = true
    vim.schedule(function()
        _reeval_pending = false
        reevaluate_now()
    end)
end

--- Test seam: synchronous re-evaluation.
function M._reevaluate_now() reevaluate_now() end

--- Test seam: clear all §9.8 state.
function M._reset_withheld()
    _withheld = {}
    _buf_state = {}
    _ws_failed_root = nil
end

-- Drop per-buffer state when a buffer goes away.
vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("loomworks.lsp.bufstate", { clear = true }),
    callback = function(args)
        _withheld[args.buf] = nil
        _buf_state[args.buf] = nil
    end,
})

-- ---------------------------------------------------------------------------
-- Completion nudge — targeted re-resolution when an owned DB appears (§9.7)
-- ---------------------------------------------------------------------------

--- A module reported that its owned LSP compilation database for `build_dir`
--- was newly (re)written (module §8.4 `refresh_lsp_database`'s `done`). Find the
--- live clients whose active project maps to that build dir and ask each server
--- integration to reconcile if needed — so a client that started before the
--- database existed (absent→present) picks up the now-resolvable directory
--- without the user reopening the buffer. Generic: no module-type checks. The
--- integration hook (`on_owned_database_changed(root_dir)`) is idempotent — a
--- client already carrying the correct directory is never restarted.
--- @param build_dir string absolute build directory whose owned DB changed
function M.on_owned_database_changed(build_dir)
    if type(build_dir) ~= "string" or build_dir == "" then return end
    -- A database appearing can make withheld buffers startable (§9.8).
    M.reevaluate()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return end
    local ws = lw.get_workspace and lw.get_workspace()
    if not ws then return end
    local profile = ws.get_active_profile and ws:get_active_profile()
    if not profile then return end

    local target = norm_cmp(build_dir)
    for _, project in pairs(lw.get_projects()) do
        -- Active build dir for this project, via the generic Profile API
        -- (ProfileProject:build_dir) — the same dir clangd was pointed at.
        local pp = profile.project and profile:project(project.key)
        local bd = pp and pp.build_dir and pp:build_dir()
        if bd and norm_cmp(bd) == target then
            for server, integration in pairs(_integrations) do
                if integration.on_owned_database_changed then
                    local entry = M.entry_for_project(project, server)
                    if entry and entry.root_dir then
                        pcall(integration.on_owned_database_changed, entry.root_dir)
                    end
                end
            end
        end
    end
end

--- Get resolved cmd args for a root_dir from the relevant integration.
--- @param server string
--- @param root_dir string normalized root directory
--- @return string[]|nil
function M.resolved_cmd(server, root_dir)
    local i = _integrations[server]
    if i and i.get_resolved_cmd then return i.get_resolved_cmd(root_dir) end
    return nil
end

-- ---------------------------------------------------------------------------
-- Back-compat aliases for existing user configs
-- ---------------------------------------------------------------------------

--- @param base_cmd string[]
function M.clangd_cmd(base_cmd) return M.cmd("clangd", base_cmd) end

--- @param fallback? fun(bufnr: number, on_dir: fun(root: string))
function M.clangd_root_dir(fallback) return M.root_dir("clangd", fallback) end

--- @param root_dir string
function M.get_resolved_cmd(root_dir) return M.resolved_cmd("clangd", root_dir) end

-- ---------------------------------------------------------------------------
-- Status query (server-agnostic)
-- ---------------------------------------------------------------------------

--- Get the resolved LSP status for all loomworks projects.
--- Returns info per project: matched clients with their cmd args per server.
--- @return table[] list of { project_key, project_type, root_dir, clients, extra }
function M.get_status()
    local ok, lw = pcall(require, "loomworks")
    if not ok then return {} end

    local ws = lw.get_workspace()
    if not ws then return {} end

    local sorted = {}
    for _, p in pairs(lw.get_projects()) do sorted[#sorted + 1] = p end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    local results = {}
    for _, project in ipairs(sorted) do
        if not project.path then goto continue end

        local entries = entries_for(project)
        if #entries == 0 then goto continue end

        -- Primary display root_dir: project source path (matches most flows)
        local project_abs = normalize(ws.root .. "/" .. project.path)

        local matched_clients = {}
        local extra = {}
        for _, entry in ipairs(entries) do
            local server = entry.server
            local entry_root = entry.root_dir and normalize(entry.root_dir) or project_abs

            for _, client in ipairs(vim.lsp.get_clients({ name = server })) do
                if client.root_dir and normalize(client.root_dir) == entry_root then
                    matched_clients[#matched_clients + 1] = {
                        name = client.name,
                        id = client.id,
                        cmd = client.config and client.config.cmd or nil,
                    }
                end
            end

            local integration = _integrations[server]
            if integration and integration.status_extras then
                local e = integration.status_extras(entry) or {}
                for k, v in pairs(e) do extra[k] = v end
            end
        end

        -- resolved_cmd lookup for the first entry's server (display only).
        local resolved_cmd = nil
        if #matched_clients > 0 and entries[1].root_dir then
            resolved_cmd = M.resolved_cmd(entries[1].server, normalize(entries[1].root_dir))
        end

        results[#results + 1] = {
            project_key = project.key,
            project_type = project.type,
            root_dir = project_abs,
            clients = matched_clients,
            resolved_cmd = resolved_cmd,
            extra = extra,
        }

        ::continue::
    end

    return results
end

-- ---------------------------------------------------------------------------
-- Server setup — vim.lsp.config + vim.lsp.enable per integration
-- ---------------------------------------------------------------------------

--- Tracks integrations we installed via vim.lsp.config so we can detect
--- later overrides (a cmd stomp by user init would silently disable
--- loomworks' SDK-clangd routing). Key: server name, value: cmd function.
--- @type table<string, function>
local _installed_cmd = {}

--- Install a server's vim.lsp.config payload and enable it.
--- Requires the integration to expose `build_config(user_cfg)`.
--- @param server string
--- @param user_cfg table|nil
--- @return boolean ok
local function install_server(server, user_cfg)
    local integration = _integrations[server]
    if not integration or not integration.build_config then
        return false
    end
    local cfg = integration.build_config(user_cfg)
    vim.lsp.config(server, cfg)
    vim.lsp.enable(server)
    _installed_cmd[server] = cfg.cmd
    return true
end

--- Set up servers based on the user's `loomworks.setup({ lsp = ... })`.
---
--- `lsp_opts` shape:
---   - `false` → skip entirely; no servers installed, wrapping disabled for
---     anyone who started clients themselves. (Handled by caller.)
---   - `nil` or `{}` → install all integrations with `default_enable = true`
---     using their own defaults.
---   - `{ clangd = { cmd = ..., on_attach = ... } }` → install clangd with
---     user overrides merged into the integration's defaults.
---   - `{ clangd = false }` → skip clangd specifically.
---   - `{ clangd = true }` → install clangd with integration defaults
---     (same as an empty table).
---
--- @param lsp_opts table|nil
function M.setup_servers(lsp_opts)
    lsp_opts = lsp_opts or {}

    _excludes = resolve_excludes(lsp_opts.excludes)
    if _excludes ~= false then
        ensure_exclude_autocmd()
    end
    -- Restart machinery needs to know when integrations' clients attach
    -- so on_exit dispatch can look up the dead client's (server, root).
    ensure_restart_autocmd()

    for server, integration in pairs(_integrations) do
        local user_cfg = lsp_opts[server]
        local enable
        if user_cfg == false then
            enable = false
        elseif user_cfg == true or user_cfg == nil then
            enable = integration.default_enable == true
            if user_cfg == true then enable = true end
            user_cfg = nil
        else
            -- table: user provided a config → enable
            enable = true
        end
        if enable then
            install_server(server, type(user_cfg) == "table" and user_cfg or nil)
        end
    end

    -- Footgun check: warn at VimEnter if someone later overrode our cmd
    -- (e.g. a user's vim.lsp.config call after loomworks.setup). Silent
    -- failure here would cost hours of debugging.
    vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
            for server, installed in pairs(_installed_cmd) do
                local current = vim.lsp.config[server]
                if current and current.cmd ~= installed then
                    vim.notify(
                        "loomworks.lsp: " .. server .. " cmd was overridden after"
                        .. " loomworks.setup — profile-aware routing disabled."
                        .. " Move your vim.lsp.config call before loomworks.setup,"
                        .. " or pass { lsp = { " .. server .. " = { cmd = ... } } }"
                        .. " to loomworks.setup.",
                        vim.log.levels.WARN)
                end
            end
        end,
    })
end

-- ---------------------------------------------------------------------------
-- Discovery — scan every runtime path for integration files
-- ---------------------------------------------------------------------------

--- @type string[]  integration module names ever loaded (for listener re-wiring)
local _discovered_modules = {}

local function discover()
    local files = vim.api.nvim_get_runtime_file(
        "lua/loomworks/integrations/lsp/*.lua", true)
    local seen = {}
    for _, path in ipairs(files) do
        local mod_name = path:match("lua[/\\](.-)%.lua$")
        if mod_name then
            mod_name = mod_name:gsub("[/\\]", ".")
            if not seen[mod_name] then
                seen[mod_name] = true
                local ok, err = pcall(require, mod_name)
                if not ok then
                    vim.schedule(function()
                        vim.notify(
                            "loomworks.lsp: failed to load " .. mod_name .. ": " .. tostring(err),
                            vim.log.levels.WARN)
                    end)
                else
                    _discovered_modules[#_discovered_modules + 1] = mod_name
                end
            end
        end
    end
end

--- Wire integration listeners to the loomworks event bus. Idempotent.
local _listeners_wired = false
local function wire_listeners()
    if _listeners_wired then return end
    _listeners_wired = true
    local ok, lw = pcall(require, "loomworks")
    if not ok then return end
    -- Deferred-start gate (§9.7): a new init cycle must NOT drain the queue.
    -- `workspace_initializing` fires on the normal initial `core:setup`; draining
    -- here released buffers before the workspace was ready (they start ungated).
    -- Held buffers wait for this cycle's `lsp_ready` (or the safety timeout);
    -- readiness is queried dynamically, so no gate-side reset is needed.
    -- Deferred-start gate (§9.7): the active profile's owned LSP databases
    -- being ready is the RELEASE signal — the resolved binary and the
    -- compile_commands_dir (with compile_commands.json already on disk for
    -- configured units) are in place, so held buffers resolve now and each
    -- server starts once, correct, with no follow-up restart.
    lw.on("lsp_ready", function()
        gate_release()
        M.reevaluate()
    end)
    lw.on("active_set_changed", function()
        for _, int in pairs(_integrations) do
            if int.on_active_set_changed then
                vim.schedule(int.on_active_set_changed)
            end
        end
        -- Profile switch, configure completed, reset/delete: the withheld
        -- decision may flip either way (§9.8).
        M.reevaluate()
    end)
    lw.on("task_stopped", function()
        M.reevaluate()
    end)
    lw.on("workspace_changed", function(ws)
        -- Deferred-start gate (§9.7): a nil payload means init FAILED — end the
        -- hold. Managed servers withhold buffers under the failed root
        -- (`withheld_error`, §9.8) instead of starting on the fallback; plain
        -- gated resolvers resolve as before. A successful load does NOT release
        -- here; the gate waits for lsp_ready.
        if ws == nil then
            M._set_failed_root(workspace_root())
            gate_release()
        else
            M._set_failed_root(nil)
        end
        M.reevaluate()
        -- Blow the lsp_configs memo first — the old workspace's projects (and
        -- any project.key reuse) must not survive into the new one. Runs before
        -- the integration callbacks below, which are deferred via vim.schedule.
        clear_configs_memo()
        for _, int in pairs(_integrations) do
            if int.on_workspace_changed then
                vim.schedule(int.on_workspace_changed)
            end
        end
    end)
    lw.on("workspace_closed", function()
        -- The workspace was shut down (cwd swap / reload) with no successor:
        -- nothing is failed or pending any more. Drain the hold and
        -- re-evaluate, so buffers parked `held` or withheld under the closed
        -- workspace fall back to the stock server instead of staying withheld
        -- (§9.7 / §9.8). Running clients are left to the re-evaluation.
        M._set_failed_root(nil)
        gate_release()
        M.reevaluate()
        clear_configs_memo()
    end)
    lw.on("lsp_options_changed", function(payload)
        -- lsp options can feed lsp_configs output; invalidate every memo key.
        bump_configs_generation()
        for _, int in pairs(_integrations) do
            if int.on_lsp_options_changed then
                vim.schedule(function() int.on_lsp_options_changed(payload) end)
            end
        end
    end)
end

discover()
wire_listeners()

return M
