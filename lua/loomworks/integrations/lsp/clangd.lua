--- loomworks/integrations/lsp/clangd.lua — clangd LSP integration.
---
--- Implements clangd-specific wiring: cmd factory (injects
--- --compile-commands-dir and binary override), root_dir factory,
--- status extras, and active-set change detection for client restart.
---
--- Self-registers with `loomworks.lsp` on load. Discovered automatically
--- by the registry scanning `lua/loomworks/integrations/lsp/*.lua` across
--- all runtime paths.

local uv = vim.uv or vim.loop
local normalize = vim.fs.normalize

local M = { server = "clangd" }

--- Resolved clangd command args keyed by normalized root_dir.
--- Populated by the cmd wrapper, read by get_resolved_cmd().
--- @type table<string, string[]>
local _resolved_cmd = {}

--- State tracking for detecting when clangd needs restart on active_set_changed.
--- @type table<string, { binary: string|nil, compile_commands_dir: string|nil }>
local _client_state = {}

--- OOM-adaptive `-j` state per normalized root_dir. `current_j` is the
--- value we append on the next start; nil means "don't touch clangd's
--- arg list" (the first run uses whatever cmd the user passed). On
--- the first OOM we seed `current_j = INITIAL_J` and halve on each
--- subsequent OOM. `retried_same_args` tracks the single retry granted
--- for a non-OOM unexpected exit (so a permanently crashing build
--- doesn't burn through the throttle window).
--- @type table<string, { current_j: integer|nil, retried_same_args: boolean }>
local _j_state = {}

--- Starting `-j` value when we enter adaptive mode after the first
--- OOM. Halved from there (12 → 6 → 3 → 1). Picked as a sensible
--- developer-machine compromise; if your specific workload needs a
--- different starting point, the trade-off in code-vs-flexibility
--- favours hardcoding for now.
local INITIAL_J = 12

--- How many rotated nvim LSP log snapshots to keep.
local LOG_KEEP = 5

--- Unconditional memory-friendly flag. Not exposed in user options
--- because it's a strict win and there's no realistic workload that
--- regrets it. Users who actually need it off can append
--- `--pch-storage=memory` via `extra_args` (LLVM cl::opt last-wins).
---
--- `--malloc-trim` would also be a win for Linux glibc users on
--- clangd 16+, but older builds reject unknown args outright. Modern
--- clangd users can add it via `extra_args`.
local ALWAYS_FLAGS = {
    "--pch-storage=disk",
}

--- Expand ${ENV_VAR} patterns. Leaves unresolved refs unchanged.
--- @param s string
--- @return string
local function expand_env(s)
    return (s:gsub("%${([^}]+)}", function(var)
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Resolve the clangd binary from an entry (verifies existence).
--- @param entry table|nil clangd entry with optional `binary` field
--- @return string|nil absolute path to clangd binary
local function resolve_binary(entry)
    if not entry or not entry.binary then return nil end
    local expanded = expand_env(entry.binary)
    if uv.fs_stat(expanded) then return expanded end
    return nil
end

--- Resolve compile_commands_dir from an entry (verifies the .json exists).
--- @param entry table|nil
--- @return string|nil
local function resolve_compile_commands_dir(entry)
    if not entry or not entry.compile_commands_dir then return nil end
    local dir = entry.compile_commands_dir
    if not uv.fs_stat(dir .. "/compile_commands.json") then return nil end
    return dir
end

--- Get the clangd entry for a project by asking the core for this server.
--- @param project loomworks.Project
--- @return table|nil
local function entry_for(project)
    local lsp = require("loomworks.lsp")
    return lsp.entry_for_project(project, "clangd")
end

-- ---------------------------------------------------------------------------
-- `-j` injection
-- ---------------------------------------------------------------------------

--- Append `-j <n>` to a copy of args. We deliberately don't parse or
--- strip any pre-existing `-j` the user might have passed: clangd uses
--- LLVM's `cl::opt` parser where the last occurrence of a single-value
--- option wins, so appending always overrides cleanly. The first start
--- never appends (no adaptive state yet), so the user's cmd reaches
--- clangd untouched until the first OOM kicks in.
--- @param args string[]
--- @param j integer
--- @return string[]
local function with_j(args, j)
    local out = vim.list_extend({}, args)
    out[#out + 1] = "-j" .. tostring(j)
    return out
end

-- ---------------------------------------------------------------------------
-- OOM detection
-- ---------------------------------------------------------------------------

--- Heuristic: did this exit look like an out-of-memory kill?
--- Linux: signal 9 (SIGKILL) is the canonical OOM-killer signature.
--- Windows: exit codes 0xC0000005 (access violation, often allocation
--- failure under heavy load) and 0xC0000017 (STATUS_NO_MEMORY).
--- Falsely-positive triggers (manual `kill -9`, unrelated access
--- violations) still result in a smaller `-j`, which is harmless — the
--- UI Reset action puts it back.
--- @param exit_code integer
--- @param signal integer
--- @return boolean
local function looks_like_oom(exit_code, signal)
    if signal == 9 then return true end
    if exit_code == 0xC0000005 or exit_code == 0xC0000017 then return true end
    return false
end

-- ---------------------------------------------------------------------------
-- nvim LSP log rotation
-- ---------------------------------------------------------------------------

--- Copy `src` → `dst`. Used by rotate_nvim_lsp_log to snapshot nvim's
--- live LSP log without renaming it (renames are racy on Windows when
--- nvim has the file handle open).
--- @param src string
--- @param dst string
--- @return boolean ok
local function copy_file(src, dst)
    local in_fd = io.open(src, "rb")
    if not in_fd then return false end
    local out_fd = io.open(dst, "wb")
    if not out_fd then in_fd:close() return false end
    local chunk
    repeat
        chunk = in_fd:read(64 * 1024)
        if chunk then out_fd:write(chunk) end
    until not chunk
    in_fd:close()
    out_fd:close()
    return true
end

--- Snapshot nvim's LSP log file into `<log>.1` and shift older
--- snapshots down (1 → 2 → … → LOG_KEEP). Keeps the live log intact
--- so nvim's open handle keeps writing into it; we just preserve a
--- copy from the moment of each clangd (re)start, giving the user a
--- postmortem they can reach for after a crash.
local function rotate_nvim_lsp_log()
    local ok_path, log_path = pcall(vim.lsp.log.get_filename)
    if not ok_path or type(log_path) ~= "string" then return end
    if not uv.fs_stat(log_path) then return end

    -- Drop the oldest, then bump every other snapshot up by one.
    local oldest = log_path .. "." .. LOG_KEEP
    if uv.fs_stat(oldest) then pcall(os.remove, oldest) end
    for i = LOG_KEEP - 1, 1, -1 do
        local src = log_path .. "." .. i
        local dst = log_path .. "." .. (i + 1)
        if uv.fs_stat(src) then pcall(os.rename, src, dst) end
    end
    copy_file(log_path, log_path .. ".1")
end

--- Find the clangd entry for a given root_dir by asking the core.
--- @param root_dir string|nil
--- @return loomworks.Project|nil project, table|nil entry
local function find_by_root(root_dir)
    if not root_dir then return nil, nil end
    local lsp = require("loomworks.lsp")
    return lsp.find_project_by_root("clangd", root_dir)
end

-- ---------------------------------------------------------------------------
-- Integration contract — consumed by loomworks.lsp
-- ---------------------------------------------------------------------------

--- Create a clangd `cmd` function (for `vim.lsp.config` or lspconfig)
--- that injects --compile-commands-dir and optionally overrides the
--- binary per project. Falls back to `base_cmd` when loomworks has no
--- data. Used by `build_config` and re-exported for users who prefer
--- to keep their own `vim.lsp.config` / `lspconfig` setup.
--- @param base_cmd string[] e.g. { "clangd", "--background-index" }
--- @return fun(dispatchers: table, config: vim.lsp.ClientConfig): vim.lsp.rpc.PublicClient
function M.cmd_factory(base_cmd)
    return function(dispatchers, config)
        local args = vim.list_extend({}, base_cmd)
        local _, entry = find_by_root(config.root_dir)

        local bin = resolve_binary(entry)
        if bin then
            args[1] = bin
        elseif entry and entry.binary and entry.binary_required then
            vim.schedule(function()
                vim.notify(
                    "loomworks.clangd: required binary not found: " .. entry.binary
                    .. "\nlsp will not start for " .. (config.root_dir or "<unknown>"),
                    vim.log.levels.ERROR)
            end)
            error("loomworks.clangd: binary_required and not found: " .. entry.binary)
        end

        local dir = resolve_compile_commands_dir(entry)
        if dir then args[#args + 1] = "--compile-commands-dir=" .. dir end

        -- Always-on (no user opt-out). See ALWAYS_FLAGS docstring.
        for _, f in ipairs(ALWAYS_FLAGS) do args[#args + 1] = f end

        -- User-configurable flags. Each emitted with an explicit
        -- value so the appended form wins any earlier occurrence
        -- in `base_cmd` via LLVM cl::opt last-wins, leaving the
        -- resolved cmd self-describing. Defaults applied in
        -- Workspace:get_lsp_options when keys are missing.
        local ok_lw, lw = pcall(require, "loomworks")
        local opts = ok_lw and lw.get_lsp_options
            and lw.get_lsp_options("clangd") or {
                clang_tidy = true,
                background_index = true,
                background_index_priority = "low",
                extra_args = {},
            }
        args[#args + 1] = "--clang-tidy=" .. tostring(opts.clang_tidy ~= false)
        args[#args + 1] = "--background-index=" .. tostring(opts.background_index ~= false)
        args[#args + 1] = "--background-index-priority="
            .. (opts.background_index_priority or "low")

        -- OOM-adaptive `-j` injection. State is created lazily on the
        -- first crash (in on_unexpected_exit); first run for a root has
        -- no state and reaches clangd with the user's pristine cmd.
        -- `current_j == nil` means "no adaptive value yet" — don't
        -- touch the cmd. After the first OOM, `current_j` is set and
        -- we append `-j N` (LLVM's option parser respects last-wins,
        -- so any user `-j` earlier in the line gets overridden cleanly).
        local root_key = config.root_dir and normalize(config.root_dir) or "?"
        local state = _j_state[root_key]
        if state and state.current_j then
            args = with_j(args, state.current_j)
        end

        -- User escape hatch: appended last so any flag the user puts
        -- here wins everything (including our own typed knobs). Skip
        -- non-string entries defensively in case validation missed.
        if opts.extra_args and type(opts.extra_args) == "table" then
            for _, a in ipairs(opts.extra_args) do
                if type(a) == "string" then args[#args + 1] = a end
            end
        end

        if config.root_dir then
            _resolved_cmd[normalize(config.root_dir)] = vim.list_extend({}, args)
        end

        -- Snapshot nvim's LSP log before spawning. The live log keeps
        -- collecting; previous content lives in `<log>.1` for crash
        -- forensics. Rotation happens on every start, not just after
        -- crashes, so the user always has a recent baseline available.
        rotate_nvim_lsp_log()

        return vim.lsp.rpc.start(args, dispatchers, {
            cwd = config.cmd_cwd,
            env = config.cmd_env,
            detached = config.detached,
        })
    end
end

--- Create a `root_dir` function (for `vim.lsp.config` or lspconfig)
--- that uses the loomworks project's clangd entry root_dir when the
--- buffer's project has one.
--- Falls through to the provided fallback otherwise. Skips excluded
--- buffers (see `loomworks.lsp.excluded`) before any resolution — this
--- is the primary gate that keeps LSP off non-file buffers (diffview,
--- fugitive, quickfix, ...).
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
-- `--clang-tidy` lives in ALWAYS_FLAGS now so it applies even when the
-- user overrides `cmd`. Keep this list minimal — anything we want
-- unconditionally goes in MEMORY_FLAGS or ALWAYS_FLAGS instead.
local DEFAULT_CMD = { "clangd", "--background-index",
    "--header-insertion=iwyu" }
local DEFAULT_FILETYPES = { "c", "cpp", "objc", "objcpp", "cuda" }
local DEFAULT_ROOT_MARKERS = { ".clangd", ".clang-tidy", "compile_commands.json",
    "compile_flags.txt", ".git" }

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
--- when the user opts into loomworks-managed clangd (the default).
---
--- User's `cmd` becomes the fallback base for buffers outside any workspace
--- project. Inside a workspace project, the profile's SDK clangd wins.
--- User's `root_dir` (if a function) becomes the fallback for buffers
--- outside any workspace project — lets users keep custom rules like
--- "skip diffview buffers". Defaults to `vim.fs.root(bufnr, root_markers)`.
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
    config.on_exit = require("loomworks.lsp").wrap_on_exit("clangd", user_cfg.on_exit)
    if not config.capabilities then
        config.capabilities = detect_capabilities()
    end
    return config
end

--- Should this integration be enabled by default when the user calls
--- `loomworks.setup({})` without an explicit `lsp` config? Clangd is the
--- flagship native-language server, so yes.
M.default_enable = true

--- Status-page extras for a clangd entry.
--- @param entry table
--- @return table
function M.status_extras(entry)
    return {
        compile_commands_dir = entry.compile_commands_dir,
        clangd_bin = entry.binary,
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
    for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
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
    vim.schedule(function() vim.lsp.enable("clangd") end)
end

--- Detect clangd state changes after a profile/active set change.
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
                compile_commands_dir = resolve_compile_commands_dir(entry),
            }
            new_state[key] = new

            local prev = _client_state[key]
            if prev and (prev.binary ~= new.binary
                    or prev.compile_commands_dir ~= new.compile_commands_dir) then
                local clients = find_clients(key)
                if #clients > 0 then
                    local parts = {}
                    if new.compile_commands_dir ~= prev.compile_commands_dir then
                        parts[#parts + 1] = "compile_commands: "
                            .. (new.compile_commands_dir or "none")
                    end
                    if new.binary ~= prev.binary then
                        parts[#parts + 1] = "binary: " .. (new.binary or "default")
                    end
                    vim.notify("loomworks: restarting clangd for " .. project.key
                        .. (#parts > 0 and " (" .. table.concat(parts, ", ") .. ")" or ""))
                    restart_clients(clients)
                end
            end
        end
    end
    _client_state = new_state
end

--- Restart all clangd clients when a workspace loads for the first time.
--- Pre-existing clients were started without loomworks awareness.
function M.on_workspace_changed()
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then return end
    vim.notify("loomworks: restarting " .. #clients .. " clangd client(s) for workspace integration")
    restart_clients(clients)
end

--- Restart every clangd client when a user option that affects the
--- cmd line changes. The new cmd is computed by `cmd_factory` on the
--- next start; we don't need to teach this function which option
--- changed. Throttled to one restart per nvim tick so a burst of
--- toggles (e.g. the user cycling priority through values) doesn't
--- thrash clangd processes.
--- @param payload { server: string, key: string, value: any }
function M.on_lsp_options_changed(payload)
    if not payload or payload.server ~= "clangd" then return end
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients == 0 then return end
    -- Coalesce bursts: defer until end-of-tick so multiple set calls
    -- in the same UI handler trigger a single restart.
    if M._restart_pending then return end
    M._restart_pending = true
    vim.schedule(function()
        M._restart_pending = false
        local current = vim.lsp.get_clients({ name = "clangd" })
        if #current > 0 then
            vim.notify("loomworks: restarting clangd for option change ("
                .. payload.key .. ")")
            restart_clients(current)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Restart policy + UI reset (consumed by loomworks.lsp generic dispatcher)
-- ---------------------------------------------------------------------------

--- Decide what to do when a clangd client dies unexpectedly. The
--- contract is documented on `loomworks.LspIntegration.on_unexpected_exit`.
--- @param info loomworks.LspExitInfo
--- @return loomworks.LspRestartDecision
function M.on_unexpected_exit(info)
    -- Lazy seed: first exit for this root creates the record. Without
    -- this, repeated crashes would keep going through whatever branch
    -- handles "no state" forever — defeating the non-OOM give-up rule.
    local state = _j_state[info.root_dir]
    if not state then
        state = { current_j = nil, retried_same_args = false }
        _j_state[info.root_dir] = state
    end

    if looks_like_oom(info.exit_code, info.signal) then
        local cur = state.current_j
        local next_j
        if cur == nil then
            -- Entering adaptive mode after the first OOM. Start at a
            -- developer-machine-friendly default and let subsequent
            -- crashes halve it. We don't bother inspecting the user's
            -- original `-j` (if any) because clangd treats the last
            -- `-j` on the line as authoritative.
            next_j = INITIAL_J
        elseif cur > 1 then
            next_j = math.max(1, math.floor(cur / 2))
        else
            -- Already at the floor; nothing more we can do via -j.
            return {
                restart = false,
                reason = "OOM at -j 1 — clangd needs more memory than fits",
            }
        end
        state.current_j = next_j
        state.retried_same_args = false
        return {
            restart = true,
            reason = "OOM detected, restarting with -j " .. next_j,
        }
    end

    -- Non-OOM crash. Allow exactly one retry with the same args so a
    -- transient fault recovers; if the second run dies too, give up
    -- until the user resets — repeated crashing on identical args is
    -- not something the restart loop can solve.
    if not state.retried_same_args then
        state.retried_same_args = true
        return { restart = true, reason = "clangd crashed, retrying once" }
    end
    return {
        restart = false,
        reason = "clangd keeps crashing on the same args",
    }
end

--- Clear adaptive state for a root. Called by the UI Reset action so
--- the user can recover from a permanent failure (give up) or an
--- over-aggressive `-j` step-down without restarting nvim. Also clears
--- the generic suppression / throttle flags on the lsp.lua side.
--- @param root_dir string normalized root directory
function M.reset(root_dir)
    _j_state[root_dir] = nil
    -- Force a fresh capture of `base_j` on the next cmd_factory call.
    _resolved_cmd[root_dir] = nil
    local lsp = require("loomworks.lsp")
    lsp.reset_attempts("clangd", root_dir)
    lsp.clear_suppression("clangd", root_dir)
    -- Kick a fresh attach if there's a live buffer waiting.
    vim.schedule(function() vim.lsp.enable("clangd") end)
end

--- UI label for the reset action.
M.reset_label = "Reset clangd -j"

-- Self-register with the core LSP registry.
require("loomworks.lsp").register("clangd", M)

return M
