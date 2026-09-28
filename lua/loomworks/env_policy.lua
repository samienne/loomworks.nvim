--- loomworks/env_policy.lua — Environment denylist (spec §17.9).
---
--- Some environment variables make an unrelated program load or run code:
--- dynamic-loader injection, interpreter start-up hooks, command-interpreter
--- selection, version-control command hooks, build-tool injection. loomworks
--- refuses them from every environment source it composes (configuration,
--- compiler-family override, module environment block, tool environment,
--- launch environment) — even from a trusted working copy, because legitimate
--- uses are rare and the effect is invisible. The user's own process
--- environment is untouched (a child still inherits it). Names match
--- case-insensitively on every host; an entry ending in `_` or `*` is a prefix.

local M = {}

--- Exact names (upper-case).
M.NAMES = {
    LD_PRELOAD = true, LD_LIBRARY_PATH = true, LD_AUDIT = true,
    NODE_OPTIONS = true,
    PYTHONPATH = true, PYTHONHOME = true, PYTHONSTARTUP = true,
    BASH_ENV = true, ENV = true,
    COMSPEC = true, PATHEXT = true,
    GIT_SSH_COMMAND = true,
    CMAKE_TOOLCHAIN_FILE = true,
    CCACHE_PREFIX = true,
}

--- Name prefixes (upper-case): every name starting with one is denied.
M.PREFIXES = { "DYLD_", "NPM_CONFIG_", "GIT_CONFIG_" }

--- Human-readable list for messages and help.
M.DESCRIPTION = "LD_PRELOAD, LD_LIBRARY_PATH, LD_AUDIT, DYLD_*, NODE_OPTIONS, npm_config_*, "
    .. "PYTHONPATH, PYTHONHOME, PYTHONSTARTUP, BASH_ENV, ENV, ComSpec, PATHEXT, "
    .. "GIT_SSH_COMMAND, GIT_CONFIG_*, CMAKE_TOOLCHAIN_FILE, CCACHE_PREFIX"

--- Whether `name` is a denied environment variable (case-insensitive).
--- @param name any
--- @return boolean
function M.is_denied(name)
    if type(name) ~= "string" then return false end
    local up = name:upper()
    if M.NAMES[up] then return true end
    for _, p in ipairs(M.PREFIXES) do
        if up:sub(1, #p) == p then return true end
    end
    return false
end

M._warned = {}

--- Notify once per key (scheduled: may run in a fast event context).
local function warn_once(key, msg)
    if M._warned[key] then return end
    M._warned[key] = true
    vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
end

--- The process's own value for `name` (case-insensitive on Windows).
local function process_value(name)
    local v = os.getenv(name)
    if v ~= nil then return v end
    if package.config:sub(1, 1) == "\\" then
        local ok, all = pcall(vim.fn.environ)
        if ok and type(all) == "table" then
            local up = name:upper()
            for k, val in pairs(all) do
                if type(k) == "string" and k:upper() == up then return val end
            end
        end
    end
    return nil
end

--- Return a copy of `env` without denied names, plus the sorted list of names
--- dropped. `opts.label` names the source in the one-time warning; with
--- `opts.quiet_if_inherited`, a denied name whose value equals this process's
--- own (a captured tool environment, e.g. a developer-environment script's
--- full `set` output) is dropped silently — the child inherits the same value.
--- @param env table<string, any>|nil
--- @param opts? { label?: string, quiet_if_inherited?: boolean, silent?: boolean }
--- @return table<string, any>|nil env, string[] denied
function M.filter(env, opts)
    opts = opts or {}
    if type(env) ~= "table" then return env, {} end
    local out, denied, loud = {}, {}, {}
    for k, v in pairs(env) do
        if M.is_denied(k) then
            denied[#denied + 1] = k
            if not (opts.quiet_if_inherited and process_value(k) == v) then
                loud[#loud + 1] = k
            end
        else
            out[k] = v
        end
    end
    table.sort(denied)
    table.sort(loud)
    if #loud > 0 and not opts.silent then
        local label = opts.label or "environment"
        warn_once(label .. "|" .. table.concat(loud, ","), string.format(
            "loomworks: %s: refusing environment variable(s) %s — they make other programs "
                .. "load or run code (see `lw help trust`)", label, table.concat(loud, ", ")))
    end
    return out, denied
end

return M
