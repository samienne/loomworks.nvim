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

--- Registered **passive** provider functions: `(workspace) -> Suggestion[]`.
--- These are side-effect-free and MUST NOT spawn tools or touch the network —
--- they run on every passive status render (the `N suggestions` count).
--- @type (fun(workspace: loomworks.Workspace): loomworks.Suggestion[])[]
M._providers = {}

--- Registered **health-only** provider functions: `(workspace) -> Suggestion[]`.
--- These may perform a NETWORK fetch or other expensive/one-shot work and run
--- ONLY on an explicit `lw health` (`collect_health`), never on the passive
--- status count (`collect`). See the no-passive-network constraint (§16.31).
--- @type (fun(workspace: loomworks.Workspace): loomworks.Suggestion[])[]
M._health_providers = {}

--- Register a **passive** suggestion provider. A provider inspects the resolved
--- workspace and returns zero or more suggestions. It must be side-effect-free
--- and must not spawn external tools or make network calls — it runs on every
--- passive status render.
--- @param fn fun(workspace: loomworks.Workspace): loomworks.Suggestion[]
function M.register(fn)
    M._providers[#M._providers + 1] = fn
end

--- Register a **health-only** suggestion provider — one permitted to make a
--- network call or other expensive check. It runs ONLY when `lw health` is
--- invoked (`collect_health`), and is deliberately excluded from the passive
--- `collect` the status count uses, so a status render never hits the network
--- (§16.31).
--- @param fn fun(workspace: loomworks.Workspace): loomworks.Suggestion[]
function M.register_health(fn)
    M._health_providers[#M._health_providers + 1] = fn
end

--- Run `list` of providers against `workspace`, appending their suggestions to
--- `out`. A provider that errors is skipped (advisory surface — a broken or
--- offline provider must never break the workspace).
--- @param list (fun(workspace: loomworks.Workspace): loomworks.Suggestion[])[]
--- @param workspace loomworks.Workspace
--- @param out loomworks.Suggestion[]
local function run_providers(list, workspace, out)
    for _, provider in ipairs(list) do
        local ok, res = pcall(provider, workspace)
        if ok and type(res) == "table" then
            for _, s in ipairs(res) do out[#out + 1] = s end
        end
    end
end

--- Run the **passive** providers only and return the flattened suggestions.
--- This is what the compact `N suggestions` line (rendered frequently) reads,
--- so it never touches the network. `lw health` uses `collect_health` instead.
--- @param workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.collect(workspace)
    local out = {}
    if not workspace then return out end
    run_providers(M._providers, workspace, out)
    return out
end

--- Run the passive providers AND the health-only providers (which may make a
--- network call) and return the flattened suggestions. Invoked ONLY by the
--- explicit `lw health` report (§16.31), never by a passive render.
--- @param workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.collect_health(workspace)
    local out = {}
    if not workspace then return out end
    run_providers(M._providers, workspace, out)
    run_providers(M._health_providers, workspace, out)
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

-- ---------------------------------------------------------------------------
-- Provider #2 — update availability (HEALTH-ONLY, headless §16.31)
--
-- These providers make a NETWORK call (GitHub releases API / manifest peek), so
-- they are registered with `register_health`, NOT `register`: they run only on
-- an explicit `lw health` and never on the passive `N suggestions` count. Any
-- offline / API failure yields nothing — a failed check is silent, not noise.
-- ---------------------------------------------------------------------------

--- The version of the running `lw` release, or nil when there is no comparable
--- version — a development/fused source, or the in-editor plugin (which is not
--- self-updated through `lw`). The standalone host publishes the active release
--- root as `_G.__loomworks_luaroot` (…/lua-<version>); the version is its tail.
--- @return string|nil
function M._current_release_version()
    local luaroot = _G.__loomworks_luaroot
    if type(luaroot) ~= "string" then return nil end
    return luaroot:match("lua%-(.+)$")
end

--- Health provider: a newer release is available on the resolved update channel.
--- HEALTH-ONLY — it performs a network fetch (`resolve_newest_version`). Silent
--- (returns `{}`) when: this is not a versioned release source, the channel is
--- unknown, the check fails (offline / API error), or we are already up to date.
--- @param _workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.update_check_provider(_workspace)
    local ok, update = pcall(require, "boot.update")
    if not ok then return {} end
    local current = M._current_release_version()
    if not current then return {} end -- dev/fused/editor: nothing to compare

    local channel = update.resolve_channel({})
    if not channel then return {} end -- unknown channel → stay silent

    local newest, err = update.resolve_newest_version({})
    if not newest or err then return {} end -- offline / API failure: silent

    local paths = require("boot.paths")
    if not paths.version_gt(newest, current) then return {} end -- up to date

    return { {
        title = "Update available",
        detail = current .. " → " .. newest .. " on the " .. channel .. " channel",
        remedy = "run `lw self-update`",
    } }
end

--- Health provider: a `release-url` override is superseding a non-default update
--- channel — the state a user hits when they set `--channel`/`channel` but a
--- mirror override quietly wins (§16.29). Deterministic and network-free, but
--- HEALTH-ONLY: it surfaces the "channel ignored" state in the health view
--- rather than adding to the passive count. Reuses `update.url_override` /
--- `update.resolve_channel` — no duplicated precedence logic.
--- @param _workspace loomworks.Workspace
--- @return loomworks.Suggestion[]
function M.channel_override_provider(_workspace)
    local ok, update = pcall(require, "boot.update")
    if not ok then return {} end
    local override = update.url_override and update.url_override({})
    if not override then return {} end -- default origin: channel is honored
    local channel = update.resolve_channel({})
    -- Only worth flagging when a NON-default channel is being overridden — a
    -- default (stable) channel under an override is the mirror's ordinary use.
    if not channel or channel == update.DEFAULT_CHANNEL then return {} end

    return { {
        title = "Update channel overridden by release-url",
        detail = "channel is set to '" .. channel .. "' but a release-url override ("
            .. override .. ") supersedes it — self-update follows the override, not the "
            .. channel .. " channel.",
        remedy = "unset release-url / LOOMWORKS_RELEASE_URL to follow the '" .. channel
            .. "' channel, or set the channel back to '" .. update.DEFAULT_CHANNEL
            .. "' to silence this.",
    } }
end

M.register_health(M.update_check_provider)
M.register_health(M.channel_override_provider)

return M
