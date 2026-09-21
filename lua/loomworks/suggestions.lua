--- loomworks/suggestions.lua — Extensible workspace suggestion framework.
---
--- A **suggestion** is advisory (headless §16.31): a `{ title, detail, remedy }`
--- triple that a provider derives from the resolved workspace. Suggestions are
--- distinct from **diagnostics** — they never gate a build, never fail
--- `--check`, and never change an exit status. The framework is the general
--- surface; individual providers register independently and `collect` aggregates
--- whatever is registered. The compact `N suggestions` line (spec/ui.md §1.1,
--- headless §16.18) and the full `lw health` report (§16.31) both read this.

local M = {}

--- @class loomworks.Suggestion
--- @field title string one-line summary
--- @field detail string why it fires
--- @field remedy string concrete action the user can take

--- Registered provider functions: `(workspace) -> loomworks.Suggestion[]`.
--- @type (fun(workspace: loomworks.Workspace): loomworks.Suggestion[])[]
M._providers = {}

--- Register a suggestion provider. A provider inspects the resolved workspace
--- and returns zero or more suggestions. It must be side-effect-free and must
--- not spawn external tools.
--- @param fn fun(workspace: loomworks.Workspace): loomworks.Suggestion[]
function M.register(fn)
    M._providers[#M._providers + 1] = fn
end

--- Run every registered provider against `workspace` and return the flattened
--- list of suggestions. A provider that errors is skipped (advisory surface —
--- a broken provider must never break the workspace).
--- @param workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.collect(workspace)
    local out = {}
    if not workspace then return out end
    for _, provider in ipairs(M._providers) do
        local ok, res = pcall(provider, workspace)
        if ok and type(res) == "table" then
            for _, s in ipairs(res) do out[#out + 1] = s end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Provider #1 — compiler cache (headless §16.31)
-- ---------------------------------------------------------------------------

--- The EXPLICIT `cache` values a configuration declares — in its own
--- `variables` block and any compiler-family `overrides`. Auto-generated
--- variant configs declare none. Ignores inherited/default resolution: only a
--- value the user actually wrote counts as an opt-out signal.
--- @param cfg loomworks.Configuration
--- @return (string|boolean)[]
local function config_explicit_cache(cfg)
    local vals = {}
    if type(cfg.variables) == "table" and cfg.variables.cache ~= nil then
        vals[#vals + 1] = cfg.variables.cache
    end
    if type(cfg._overrides) == "table" then
        for _, entries in pairs(cfg._overrides) do
            if type(entries) == "table" and entries.cache ~= nil then
                vals[#vals + 1] = entries.cache
            end
        end
    end
    return vals
end

--- Whether a project has explicitly opted out of compiler caching — it declares
--- at least one `cache = off` and NO explicit non-`off` cache value anywhere.
--- A project that declares no explicit `cache` at all (the common case, policy
--- defaults to `auto`) has NOT opted out and would benefit from a cache.
--- @param project loomworks.Project
--- @return boolean
local function project_opts_out(project)
    local cc = require("loomworks.compiler_cache")
    local saw_off = false
    for _, cfg in ipairs(project._configurations or {}) do
        if not cfg._removed then
            for _, v in ipairs(config_explicit_cache(cfg)) do
                if cc.normalize_policy(v) == "off" then
                    saw_off = true
                else
                    return false -- an explicit non-off cache signal → not opted out
                end
            end
        end
    end
    return saw_off
end

--- The launcher this platform's `auto` policy prefers to install — the same
--- preference the resolver uses (sccache on Windows, ccache elsewhere).
--- @return string
function M._preferred_install_tool()
    return vim.fn.has("win32") == 1 and "sccache" or "ccache"
end

--- Provider: suggest installing a compiler cache when the workspace has C/C++
--- projects and none is present on the toolchain path (headless §16.31). Does
--- not fire when a launcher is already present, nor when every C/C++ project
--- has pinned `cache` to `off`. Reads only resolved state + the PATH index; it
--- never spawns the cache tool.
--- @param workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.compiler_cache_provider(workspace)
    local cc = require("loomworks.compiler_cache")

    -- Any non-orphaned C/C++-caching project, and are they all opted out?
    local cpp_projects = {}
    for _, project in pairs(workspace._projects or {}) do
        if not project.orphaned and project._module and project._module:caches_cpp() then
            cpp_projects[#cpp_projects + 1] = project
        end
    end
    if #cpp_projects == 0 then return {} end

    -- Already have a cache installed → nothing to suggest.
    if cc.any_present() then return {} end

    -- Every C/C++ project explicitly turned caching off → user opted out.
    local all_off = true
    for _, project in ipairs(cpp_projects) do
        if not project_opts_out(project) then all_off = false break end
    end
    if all_off then return {} end

    local tool = M._preferred_install_tool()
    local remedy
    if tool == "sccache" then
        remedy = "Install sccache and put it on PATH (e.g. `scoop install sccache`, "
            .. "`cargo install sccache`, or a release binary)."
    else
        remedy = "Install ccache and put it on PATH (e.g. `apt install ccache`, "
            .. "`dnf install ccache`, or `brew install ccache`)."
    end

    return { {
        title = "No compiler cache found — install one to speed rebuilds",
        detail = "This workspace has C/C++ projects but no ccache/sccache on the "
            .. "toolchain path. A compiler cache reuses prior object files, so "
            .. "clean and switch-branch rebuilds finish far faster.",
        remedy = remedy,
    } }
end

M.register(M.compiler_cache_provider)

return M
