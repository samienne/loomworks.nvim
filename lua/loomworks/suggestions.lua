--- loomworks/suggestions.lua — Extensible workspace suggestion framework.
---
--- A **suggestion** is advisory (headless §16.31): a `{ title, detail, remedy }`
--- triple that a provider derives from the resolved workspace. Suggestions are
--- distinct from **diagnostics** — they never gate a build, never fail
--- `--check`, and never change an exit status. The framework is the general
--- surface; individual providers register independently and `collect` aggregates
--- whatever is registered. The compact `N suggestions` line (spec/ui.md §1.1,
--- headless §16.18) and the full `lw health` report (§16.31) both read this.
---
--- An item is one of two **kinds** (§16.31). An **actionable** item
--- (`kind == "suggestion"`, the default) is a nag with a remedy — it is what the
--- compact `N suggestions` count reports. An **informational** item
--- (`kind == "info"`) affirms a healthy state ("using sccache"); it appears in
--- the full `lw health` report but is deliberately excluded from the count, so a
--- positive note never inflates the nag total.

local M = {}

--- @class loomworks.Suggestion
--- @field title string one-line summary
--- @field detail string why it fires
--- @field remedy string|nil concrete action the user can take (nil for info items)
--- @field kind? "suggestion"|"info" actionable (default) vs informational

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
---
--- `workspace` may be nil (no workspace loaded here): the passive providers are
--- all workspace-scoped and each guards nil itself, so this returns `{}` — but
--- the guard lives in the providers, not here, so a future workspace-independent
--- passive provider would still run.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.collect(workspace)
    local out = {}
    run_providers(M._providers, workspace, out)
    return out
end

--- Run the passive providers AND the health-only providers (which may make a
--- network call) and return the flattened suggestions. Invoked ONLY by the
--- explicit `lw health` report (§16.31), never by a passive render.
---
--- `workspace` may be nil: the workspace-INDEPENDENT health providers (update
--- availability, channel override) ignore their argument and still run, so
--- `lw health` outside a workspace reports them. Workspace-scoped providers
--- guard nil themselves and simply contribute nothing (§16.31).
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.collect_health(workspace)
    local out = {}
    run_providers(M._providers, workspace, out)
    run_providers(M._health_providers, workspace, out)
    return out
end

--- Whether a suggestion is **actionable** — a nag that counts toward the compact
--- `N suggestions` line — as opposed to an informational item that only shows in
--- the full health report. Informational items carry `kind == "info"`.
--- @param s loomworks.Suggestion
--- @return boolean
local function is_actionable(s)
    return s.kind ~= "info"
end

--- Count of ACTIONABLE passive suggestions — exactly what the compact
--- `N suggestions` status line (spec/ui.md §1.1, headless §16.18) reports.
--- Informational items (`kind == "info"`, e.g. the affirmative "using sccache"
--- note) are excluded so a positive status never inflates the nag count.
--- @param workspace loomworks.Workspace|nil
--- @return integer
function M.count_actionable(workspace)
    local n = 0
    for _, s in ipairs(M.collect(workspace)) do
        if is_actionable(s) then n = n + 1 end
    end
    return n
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

--- Provider: report the workspace's compiler-cache state when it has C/C++
--- projects (headless §16.31). Two outcomes, both gated on at least one
--- non-orphaned C/C++-caching project that has NOT pinned `cache` to `off`:
---   * a launcher is present on the toolchain path → an INFORMATIONAL item
---     ("Compiler cache: using <tool>") affirming the healthy state — excluded
---     from the `N suggestions` count (`kind = "info"`);
---   * no launcher present → the ACTIONABLE "install one to speed rebuilds"
---     suggestion (the nag that the count reports).
--- Silent when there are no caching C/C++ projects, or when every such project
--- has pinned `cache` to `off` (the user opted out — neither nag nor affirm).
--- Reads only resolved state + the PATH index; it never spawns the cache tool.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.compiler_cache_provider(workspace)
    if not workspace then return {} end -- workspace-scoped: nothing without one
    local cc = require("loomworks.compiler_cache")

    -- Any non-orphaned C/C++-caching project?
    local cpp_projects = {}
    for _, project in pairs(workspace._projects or {}) do
        if not project.orphaned and project._module and project._module:caches_cpp() then
            cpp_projects[#cpp_projects + 1] = project
        end
    end
    if #cpp_projects == 0 then return {} end

    -- Every C/C++ project explicitly turned caching off → user opted out: neither
    -- nag to install one nor affirm the one that happens to be installed.
    local all_off = true
    for _, project in ipairs(cpp_projects) do
        if not project_opts_out(project) then all_off = false break end
    end
    if all_off then return {} end

    -- A launcher is present → affirmative, informational status (not counted).
    local present = cc.any_present()
    if present then
        local tool = present
        -- Prefer the active profile's resolved launcher (respects its policy and
        -- compiler family) when there is one; fall back to whatever is on PATH.
        local ap = workspace._active_profile
        if ap then
            local ok_c, status = pcall(function() return ap:compiler_cache_status() end)
            if ok_c and status and status.present and status.tool then
                tool = status.tool
            end
        end
        return { {
            kind = "info",
            title = "Compiler cache: using " .. tool,
            detail = tool .. " is on the toolchain path, so C/C++ rebuilds for this "
                .. "workspace reuse prior object files instead of recompiling them.",
        } }
    end

    -- No launcher present → actionable install suggestion (the nag).
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
        kind = "suggestion",
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
