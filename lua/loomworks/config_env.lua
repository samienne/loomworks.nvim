--- loomworks/config_env.lua — Configuration environment (`env`) resolution.
---
--- A configuration may carry an `env` map (name → string) that loomworks sets
--- for its configure, build, clean and test tasks (spec §1.3.3). It follows the
--- configuration inheritance chain like `options`, and a compiler-family
--- `overrides.<family>.env` sub-block applies only for a matching compiler.
--- Values expand like option values (built-ins + resolved project variables,
--- then the process environment). The compiler-driver names reserved by
--- invariant 13 (`CC`, `CXX`, …) are stripped. Module-agnostic: every module
--- receives the result through `ModuleContext.env` / `.configuration_env`.

local M = {}

--- Merge a configuration's raw `env` across its inheritance chain for the
--- active compiler family. Bases are applied depth-first left-to-right, then
--- the configuration's own entries (later wins, per name). Within one level
--- the plain `env` is applied first and the matching
--- `overrides[family].env` on top — so a family entry wins within its level,
--- while a nearer level's plain value still shadows a farther level's family
--- entry (chain position dominates, as for variables, spec §1.3.1).
--- @param configuration loomworks.Configuration|nil
--- @param family string|nil active compiler family (`clang`/`gcc`/`msvc`)
--- @return table<string, string> raw (unexpanded) name → value
function M.merged(configuration, family)
    local out = {}
    if not configuration then return out end
    local visited = {}
    local function apply(c)
        if not c or visited[c] then return end
        visited[c] = true
        for _, base in ipairs(c._inherits or {}) do apply(base) end
        if type(c.env) == "table" then
            for k, v in pairs(c.env) do
                if type(k) == "string" and type(v) == "string" then out[k] = v end
            end
        end
        local fam = family and type(c._overrides) == "table" and c._overrides[family] or nil
        if type(fam) == "table" and type(fam.env) == "table" then
            for k, v in pairs(fam.env) do
                if type(k) == "string" and type(v) == "string" then out[k] = v end
            end
        end
    end
    apply(configuration)
    return out
end

--- The expansion context shared by resolved option values and the resolved
--- environment: the built-ins (`workspace_root`, `project_path`) plus the
--- project's resolved variables (compiler overrides and the active profile's
--- blank-fill values included), each variable value itself expanded against
--- the built-ins (two-pass, spec §1.3.1). A blank variable is left out.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param family string|nil active compiler family
--- @param profile loomworks.Profile|nil active profile (blank fill)
--- @param root string|nil workspace root
--- @return table<string, string>
function M.expansion_context(project, configuration, family, profile, root)
    local expand = require("loomworks.expand")
    local ctx = {
        workspace_root = root,
        project_path = project and (project.path or project.key) or nil,
    }
    if project and project.variables and next(project.variables) then
        local resolved = require("loomworks.variables").resolve(
            project, configuration, family, profile)
        for name, entry in pairs(resolved) do
            if entry.value ~= nil then
                ctx[name] = expand.expand_string(entry.value, ctx)
            end
        end
    end
    return ctx
end

--- One-shot warnings for stripped reserved names and a configuration `PATH`,
--- so a repeated build does not spam. Keyed by project/configuration/names.
M._warned = {}

--- Notify `msg` once per `key` (scheduled: resolution may run in a fast
--- event context).
--- @param key string
--- @param msg string
local function warn_once(key, msg)
    if M._warned[key] then return end
    M._warned[key] = true
    vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
end

--- Resolve a configuration's environment: merged across the chain for the
--- family, values expanded, reserved compiler-driver names stripped (and
--- warned about once — invariant 13; the editor also shows the inline
--- `⚠ ignored compiler override` diagnostic).
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param family string|nil active compiler family
--- @param profile loomworks.Profile|nil active profile
--- @param root string|nil workspace root
--- @return table<string, string> env, string[] stripped (sorted)
function M.resolve(project, configuration, family, profile, root)
    local raw = M.merged(configuration, family)
    local stripped = {}
    if not next(raw) then return {}, stripped end
    local reserved = require("loomworks.reserved_compiler")
    local expand = require("loomworks.expand")
    local ctx = M.expansion_context(project, configuration, family, profile, root)
    local env = {}
    local path_name
    for k, v in pairs(raw) do
        if reserved.is_reserved_env(k) then
            stripped[#stripped + 1] = k
        else
            env[k] = expand.expand_string(v, ctx)
            if reserved.is_path_env(k) then path_name = k end
        end
    end
    table.sort(stripped)
    local label = (project and project.key or "?") .. "/"
        .. (configuration and configuration.name or "?")
    if #stripped > 0 then
        -- A hand-edited file (the CLI and editor refuse these at set time).
        warn_once(label .. "|" .. table.concat(stripped, ","), string.format(
            "loomworks: %s: ignoring reserved compiler variable(s) %s in `env` "
                .. "— the compiler is chosen by the profile's tool",
            label, table.concat(stripped, ", ")))
    end
    if path_name then
        -- Allowed, but it replaces the tool's PATH wholesale (§1.3.3).
        warn_once(label .. "|PATH", string.format(
            "loomworks: %s: `env.%s` replaces the PATH the tool sets up (e.g. the "
                .. "MSVC developer environment) for every task of this configuration",
            label, path_name))
    end
    return env, stripped
end

--- Layer a resolved configuration environment on top of a tool environment
--- (a configuration value wins over a tool value of the same name). Returns a
--- fresh table; neither input is mutated. On a case-insensitive host
--- (Windows — the default for `case_insensitive`), "the same name" ignores
--- case: a configuration `Path` REPLACES the tool's `PATH` instead of both
--- reaching the process with an undefined winner.
--- @param tool_env table<string, string>|nil
--- @param config_env table<string, string>|nil
--- @param case_insensitive? boolean default: the host is Windows
--- @return table<string, string>
function M.compose(tool_env, config_env, case_insensitive)
    if case_insensitive == nil then case_insensitive = vim.fn.has("win32") == 1 end
    local out = {}
    for k, v in pairs(tool_env or {}) do out[k] = v end
    for k, v in pairs(config_env or {}) do
        if case_insensitive then
            local up = k:upper()
            for tk in pairs(out) do
                if tk ~= k and tk:upper() == up then out[tk] = nil end
            end
        end
        out[k] = v
    end
    return out
end

return M
