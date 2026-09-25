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

local health_cache = require("loomworks.health_cache")

--- Wall-clock epoch seconds. Injectable so tests drive the local-tier
--- `computed_at` and the network-tier TTL deterministically. Must be a
--- persist-across-process clock (NOT the monotonic `deps.clock`, which resets
--- each `lw` invocation) so a ~day-long TTL survives separate CLI runs.
--- @type fun(): integer
M._clock = function() return os.time() end

--- Time-to-live for the cached NETWORK tier (§16.31). Within this window,
--- back-to-back `lw health` runs reuse the cached update-availability result
--- instead of re-hitting the API. ~24h.
--- @type integer
M.NETWORK_TTL = 24 * 60 * 60

--- @class loomworks.Suggestion
--- @field title string one-line summary
--- @field detail string|nil why it fires (optional — terse items carry only a title)
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

--- Run the **passive**/local providers and return their flattened suggestions.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
local function run_local(workspace)
    local out = {}
    run_providers(M._providers, workspace, out)
    return out
end

--- Run the **health-only**/network providers and return their flattened
--- suggestions.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
local function run_network(workspace)
    local out = {}
    run_providers(M._health_providers, workspace, out)
    return out
end

--- The caching backing for a workspace — its `.nvim/` root and an io dependency
--- — or nil when there is nothing to cache against (a nil workspace, or the bare
--- table stubs the framework tests pass). Without a backing, `collect` /
--- `collect_health` run providers live and never persist a cache (§16.31).
--- @param workspace any
--- @return {root: string, io: table}|nil
local function cache_env(workspace)
    if type(workspace) ~= "table" then return nil end
    local root = workspace.root
    local core = workspace._core
    if type(root) ~= "string" or type(core) ~= "table" or type(core._deps) ~= "table" then
        return nil
    end
    local io_dep = core._deps.io
    if type(io_dep) ~= "table" then return nil end
    return { root = root, io = io_dep }
end

--- Append `items` to `out`.
--- @param out loomworks.Suggestion[]
--- @param items loomworks.Suggestion[]|nil
local function append(out, items)
    for _, s in ipairs(items or {}) do out[#out + 1] = s end
end

--- The environment inventory's actionable items (§16.33) for a cached
--- inventory tier, re-derived against the CURRENT workspace — nothing when the
--- tier is absent or was recorded for another environment. Never probes; a
--- failure contributes nothing (advisory).
--- @param workspace loomworks.Workspace|nil
--- @param tier table|nil
--- @return loomworks.Suggestion[]
local function inventory_items(workspace, tier)
    if not tier then return {} end
    local ok, items = pcall(function()
        return require("loomworks.inventory").cached_suggestions(workspace, tier)
    end)
    return ok and items or {}
end

--- Run the **passive** providers and return the flattened suggestions. This is
--- what the compact `N suggestions` line (rendered frequently) reads, so it
--- NEVER touches the network. `lw health` uses `collect_health` instead.
---
--- Cached two-tier model (§16.31): with a workspace backing, the local tier is
--- read from the on-disk health cache and recomputed only when it is absent or
--- its cheap invalidation key (`_local_key`) no longer matches the current
--- inputs — a lazy compute-on-first-`lw status` that stays cheap on every later
--- render. The cached NETWORK tier's items (if any, from a prior `lw health`)
--- are included informationally, however old — unless they were recorded for a
--- different running version (`_network_key`: after a self-update they describe
--- a bundle/host no longer running, so they are dropped) — but the network tier
--- is NEVER computed here. The environment inventory's missing-required items
--- are re-derived from the cached inventory tier when its environment key still
--- matches (§16.33) — never probed here. Without a workspace backing (nil
--- workspace, or a future workspace-independent passive provider), the passive
--- providers run live and nothing is cached.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.collect(workspace)
    local env = cache_env(workspace)
    if not env then
        return run_local(workspace)
    end

    local data = health_cache.read(env.io, env.root)
    local key = M._local_key(workspace)
    local tier = data.local_tier
    if not tier or tier.key ~= key then
        tier = { items = run_local(workspace), computed_at = M._clock(), key = key }
        data.local_tier = tier
        health_cache.write(env.io, env.root, data)
    end

    local out = {}
    append(out, tier.items)
    -- Cached network items are informational context for the count (however
    -- old) as long as they describe what is running now; the network tier is
    -- refreshed only by `collect_health`, never here.
    local net = data.network_tier
    if net and net.key == M._network_key() then append(out, net.items) end
    append(out, inventory_items(workspace, data.inventory_tier))
    return out
end

--- Run the passive providers AND the health-only providers (which may make a
--- network call) and return the flattened suggestions. Invoked ONLY by the
--- explicit `lw health` report (§16.31), never by a passive render.
---
--- Full refresh over the cached two-tier model (§16.31): the LOCAL tier is
--- always recomputed; the NETWORK tier is recomputed when it is absent, older
--- than `NETWORK_TTL`, recorded for another running version (`_network_key`), or
--- `opts.force` is set, and otherwise reused (so back-to-back health runs don't
--- hammer the API). The cache is then rewritten.
---
--- `workspace` may be nil: the workspace-INDEPENDENT health providers (update
--- availability, channel override) ignore their argument and still run, so
--- `lw health` outside a workspace reports them. Workspace-scoped providers
--- guard nil themselves and simply contribute nothing (§16.31). Without a
--- workspace backing there is nowhere to key or store a cache, so both tiers run
--- live (no TTL throttle is possible).
---
--- `opts.inventory` is a freshly probed inventory tier (`inventory.probe_tier`,
--- the caller's explicit health run): it replaces the cached inventory tier and
--- its missing-required items are reported. Without it, a cached tier whose
--- environment key matches is reported as `collect` would.
--- @param workspace loomworks.Workspace|nil
--- @param opts? { force?: boolean, inventory?: table } force a network-tier refresh (ignore TTL); a fresh inventory tier
--- @return loomworks.Suggestion[]
function M.collect_health(workspace, opts)
    opts = opts or {}
    local env = cache_env(workspace)
    if not env then
        local out = {}
        append(out, run_local(workspace))
        append(out, run_network(workspace))
        append(out, inventory_items(workspace, opts.inventory))
        return out
    end

    local data = health_cache.read(env.io, env.root)
    local now = M._clock()

    -- Local tier: always recomputed on an explicit health run. The key is taken
    -- BEFORE the providers run, like `collect`: a provider may refresh
    -- in-memory state its inputs derive from (a re-scanned compatibility
    -- record, not persisted here), and the key must match what the next
    -- process — which reads the persisted state — computes.
    local key = M._local_key(workspace)
    local local_items = run_local(workspace)
    data.local_tier = { items = local_items, computed_at = now, key = key }

    -- Network tier: refresh when forced, absent, past its TTL, or recorded for
    -- another running version (e.g. before a self-update); else reuse.
    local net = data.network_tier
    local net_key = M._network_key()
    local fresh = net and net.computed_at and (now - net.computed_at) < M.NETWORK_TTL
        and net.key == net_key
    if opts.force or not fresh then
        net = { items = run_network(workspace), computed_at = now, key = net_key }
        data.network_tier = net
    end

    -- Inventory tier: replaced by a fresh probe when the caller ran one.
    if opts.inventory then data.inventory_tier = opts.inventory end

    health_cache.write(env.io, env.root, data)

    local out = {}
    append(out, local_items)
    append(out, net and net.items)
    append(out, inventory_items(workspace, data.inventory_tier))
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

--- Cheap invalidation fingerprint for the LOCAL suggestion tier (§16.31): a
--- stable digest of exactly the inputs the passive providers read — the platform,
--- each non-orphaned project's key + module + whether it caches C/C++ + the
--- EXPLICIT `cache` values on its configurations (the opt-out signal), the
--- active profile's key, and every profile's identity + resolved tool keys +
--- mapped configurations + per-project `cache` fill values (the compiler-cache
--- provider follows the active profile's effective policy, or every profile's
--- when none is active), and the recorded post-configure compatibility
--- results with each such unit's CURRENT module stamp of the scanned compile
--- data (the one filesystem read: a stat / directory listing per
--- cache-enabled unit, core §8 `cache_compat_stamp`). It intentionally does NOT
--- include any toolchain-PATH probe result: computing the key must stay cheap,
--- so a launcher appearing/disappearing on PATH without a
--- config change is picked up by the next `lw health` (which always recomputes
--- the local tier), not by an ever-changing passive key. Overridable so tests
--- can drive invalidation deterministically.
--- @param workspace loomworks.Workspace|nil
--- @return string
function M._local_key(workspace)
    local parts = { "win=" .. tostring(vim.fn.has("win32")) }

    if type(workspace) == "table" then
        -- Projects, deterministically ordered by key.
        local projects = {}
        for _, project in pairs(workspace._projects or {}) do
            projects[#projects + 1] = project
        end
        table.sort(projects, function(a, b) return (a.key or "") < (b.key or "") end)
        for _, project in ipairs(projects) do
            if not project.orphaned then
                local mod = project._module
                local caches = mod and mod.caches_cpp and mod:caches_cpp() or false
                local cvals = {}
                for _, cfg in ipairs(project._configurations or {}) do
                    if not cfg._removed then
                        for _, v in ipairs(config_explicit_cache(cfg)) do
                            cvals[#cvals + 1] = tostring(v)
                        end
                    end
                end
                table.sort(cvals)
                parts[#parts + 1] = table.concat({
                    "p", project.key or "?", mod and mod.id or "?",
                    tostring(caches), table.concat(cvals, ","),
                }, "|")
            end
        end

        -- Every profile's identity + resolved tool selection + mapped
        -- configurations + `cache` fills (they change a profile's effective
        -- cache policy): the provider follows the active profile's, and with
        -- no active profile evaluates every profile.
        local ap = workspace._active_profile
        parts[#parts + 1] = "active|" .. tostring(ap and ap.key or "")
        local profiles = {}
        for _, p in pairs(workspace._profiles or {}) do profiles[#profiles + 1] = p end
        table.sort(profiles, function(a, b) return (a.key or "") < (b.key or "") end)
        if ap and not vim.tbl_contains(profiles, ap) then profiles[#profiles + 1] = ap end
        for _, p in ipairs(profiles) do
            local tkeys = {}
            for _, k in ipairs(p._tool_keys or {}) do tkeys[#tkeys + 1] = k end
            table.sort(tkeys)
            parts[#parts + 1] = "profile|" .. (p.key or "") .. "|" .. table.concat(tkeys, ",")
            local mapped = {}
            for _, pp in ipairs(p.projects and p:projects() or {}) do
                local pkey = pp.project_key and pp:project_key() or "?"
                local fills = p._profile_variables and p._profile_variables[pkey]
                mapped[#mapped + 1] = pkey .. "=" .. tostring(pp.variant_name and pp:variant_name())
                    .. ":" .. tostring(fills and fills.cache or "")
            end
            table.sort(mapped)
            parts[#parts + 1] = "mapped|" .. table.concat(mapped, ",")
        end

        -- Recorded post-configure cache-compatibility results (§16.31): a new
        -- configure that finds (or clears) /Zi compiles must refresh the
        -- cached local tier — and so must the build tool re-running the
        -- generator by itself (no lw configure), which only the module's
        -- CURRENT stamp of the compile data shows (core §8
        -- `cache_compat_stamp`: one stat / directory listing per unit with a
        -- record — only units that applied a compiler cache). The records are
        -- read as recorded here, never re-scanned: the provider re-scans when
        -- the tier is recomputed.
        for _, r in ipairs(M._compat_units(workspace)) do
            local rec = r.compat
            local fparts = {}
            for _, f in ipairs(rec.findings or {}) do
                fparts[#fparts + 1] = table.concat({
                    tostring(f.severity), tostring(f.flag), tostring(f.group), tostring(f.units),
                }, ":")
            end
            parts[#parts + 1] = table.concat({
                "compat", tostring(r.unit.id or r.unit._config_key), tostring(rec.tool),
                tostring(rec.scanned), tostring(rec.reason or ""), table.concat(fparts, ","),
                tostring(r.unit.cache_compat_stamp and r.unit:cache_compat_stamp() or ""),
            }, "|")
        end
    end

    return vim.fn.sha256(table.concat(parts, "\n")):sub(1, 16)
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

--- The platform-customary launcher to suggest installing when none is present
--- (sccache on Windows, ccache elsewhere). This is only an install
--- recommendation — NOT the `auto` resolver's preference, which is ccache
--- (sccache as fallback) for gcc/clang on every platform and no launcher for
--- MSVC-style compilers (§1.3.2).
--- @return string
function M._preferred_install_tool()
    return vim.fn.has("win32") == 1 and "sccache" or "ccache"
end

--- Install remedy for a launcher: one short line pointing at `lw help cache`
--- (per-platform install commands live there). `opt_in` adds that an
--- MSVC-style compiler also needs an explicit `cache=<tool>` (§1.3.2).
--- @param tool string
--- @param opt_in? boolean
--- @return string
local function install_remedy(tool, opt_in)
    return "install " .. tool .. (opt_in and ", then opt in" or "") .. " — lw help cache"
end

--- The active profile's compiler-cache status (`Profile:compiler_cache_status`),
--- or nil when there is no active profile / it has no C/C++-caching project /
--- the query throws (advisory: never break the provider).
--- @param workspace loomworks.Workspace
--- @return table|nil
local function active_cache_status(workspace)
    local ap = workspace._active_profile
    if not ap then return nil end
    local ok_c, status = pcall(function() return ap:compiler_cache_status() end)
    if ok_c and type(status) == "table" then return status end
    return nil
end

--- Every profile's compiler-cache status (profiles with a C/C++-caching
--- project only), sorted by profile key — the no-active-profile basis.
--- @param workspace loomworks.Workspace
--- @return { profile: loomworks.Profile, status: table }[]
local function all_cache_statuses(workspace)
    local out = {}
    for _, p in pairs(workspace._profiles or {}) do
        local ok_c, status = pcall(function() return p:compiler_cache_status() end)
        if ok_c and type(status) == "table" then out[#out + 1] = { profile = p, status = status } end
    end
    table.sort(out, function(a, b) return (a.profile.key or "") < (b.profile.key or "") end)
    return out
end

--- One terse item per outcome (headless §16.31). The explanations — why `auto`
--- is off for MSVC-style compilers, how to opt in, /Z7 + the /Zi scan,
--- install commands, not-applied cases — live in `lw help cache`.
local function info(title) return { { kind = "info", title = title } } end
local function nag(title, remedy) return { { kind = "suggestion", title = title, remedy = remedy } } end

--- The outcome for ONE profile's resolved status (the active profile's, so
--- health always agrees with its Cache row), or nil to fall through to the
--- "is a launcher on PATH?" outcomes.
--- @param status table `Profile:compiler_cache_status()`
--- @return loomworks.Suggestion[]|nil
local function status_outcome(status)
    if status.policy == "off" then return {} end
    if status.applicable == false then
        return info("Compiler cache not applied (" .. (status.not_applied_reason or "not supported")
            .. ") — lw help cache")
    end
    if status.present and status.tool then return info("Compiler cache: using " .. status.tool) end
    if status.policy ~= "auto" then
        return nag("cache=" .. status.policy .. " set but " .. status.policy .. " not found",
            install_remedy(status.policy))
    end
    return nil
end

--- How many compiles the scan says the applied launcher will FAIL (error-
--- severity compat findings), as a phrase — "3 compiles" / "every compile" —
--- or nil when none. Used only to qualify the affirmative "using <tool>" line
--- so it does not sit, unqualified, above the "<tool> will fail …" item. Reads
--- the same records `cache_compat_provider` reports (`M._compat_records`,
--- resolved at call time): the active profile's units, or — with no active
--- profile — every profile's. `profiles`, when given, narrows the count to the
--- units of those profiles (the ones a no-active-profile "using <tool>
--- (<profiles>)" line names), so another profile's failures never qualify it.
--- @param workspace loomworks.Workspace
--- @param profiles? loomworks.Profile[]
--- @return string|nil
local function failing_compiles_phrase(workspace, profiles)
    local cc = require("loomworks.compiler_cache")
    local ok, records = pcall(M._compat_records, workspace)
    if not ok or type(records) ~= "table" then return nil end
    local only
    if profiles then
        only = {}
        for _, p in ipairs(profiles) do
            local ok_p, pps = pcall(function() return p:projects() end)
            if ok_p and type(pps) == "table" then
                for _, pp in ipairs(pps) do
                    if pp._config_unit then only[pp._config_unit] = true end
                end
            end
        end
    end
    local units, every = 0, false
    for _, r in ipairs(records) do
        if (not only or only[r.unit]) and cc.compat_severity(r.compat) == "error" then
            for _, f in ipairs(r.compat.findings or {}) do
                if f.units == nil then every = true else units = units + f.units end
            end
        end
    end
    if every then return "every compile" end
    if units > 0 then return string.format("%d compile%s", units, units == 1 and "" or "s") end
    return nil
end

--- Provider: report the workspace's compiler-cache state when it has C/C++
--- projects (headless §16.31). Every item is ONE terse line; `lw help cache`
--- holds the explanations. Gated on at least one non-orphaned C/C++-caching
--- project that has NOT pinned `cache` to `off` (else silent).
---
--- **Active profile with a C/C++ configuration** — follows THAT profile's
--- resolved status (`Profile:compiler_cache_status`, its Cache row):
---   * policy `off` → silent;
---   * not applicable (module hook, §8) → INFO "Compiler cache not applied
---     (<reason>) — lw help cache";
---   * launcher resolved → INFO "Compiler cache: using <tool>" — qualified
---     "— but it will fail N compiles (lw help cache)" when the scan recorded
---     compiles the launcher fails (the finding itself follows below);
---   * explicit `cache=<tool>` not found → ACTIONABLE "cache=<tool> set but
---     <tool> not found" (remedy: install it — lw help cache);
---   * `auto` on an MSVC-style compiler with a launcher on PATH → INFO "<tool>
---     available — not enabled for MSVC-style (lw help cache)";
---   * otherwise → ACTIONABLE "No compiler cache found" (remedy: install the
---     platform-customary tool — plus "then opt in" for MSVC-style).
---
--- **No active profile** — never claims a cache is in use unless some profile
--- would use it: every profile with a C/C++ project is evaluated through the
--- same resolver:
---   * every such profile resolves `off` → silent;
---   * some resolve a launcher → INFO "Compiler cache: using <tool> (<profiles>)"
---     — qualified "— but it will fail N compiles (lw help cache)" when the
---     scan recorded compiles that launcher fails in THOSE profiles' units;
---   * else an explicit `cache=<tool>` not found → ACTIONABLE (names the profile);
---   * else a launcher on PATH → INFO "<tool> available — not enabled[ for
---     MSVC-style] (lw help cache)" (no profiles at all: "<tool> available");
---   * else → the ACTIONABLE install suggestion.
--- Post-configure compatibility findings are `cache_compat_provider`'s. Reads
--- only resolved state + the PATH index; it never spawns the cache tool.
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

    local present = cc.any_present()
    local tool = present or M._preferred_install_tool()

    local status = active_cache_status(workspace)
    if status then
        local out = status_outcome(status)
        if out and out[1] and out[1].kind == "info" and status.present and status.tool
            and status.applicable ~= false then
            local failing = failing_compiles_phrase(workspace)
            if failing then
                out[1].title = out[1].title .. " — but it will fail " .. failing
                    .. " (lw help cache)"
            end
        end
        if out then return out end
        if present and status.msvc_auto_off then
            return info(present .. " available — not enabled for MSVC-style (lw help cache)")
        end
        return nag("No compiler cache found", install_remedy(tool, status.msvc_auto_off))
    end

    -- No active C/C++ profile: evaluate every profile through the same resolver.
    local statuses = all_cache_statuses(workspace)
    local considered, any_msvc = {}, false
    for _, e in ipairs(statuses) do
        if e.status.policy ~= "off" then
            considered[#considered + 1] = e
            if e.status.msvc_auto_off then any_msvc = true end
        end
    end
    if #statuses > 0 and #considered == 0 then return {} end -- every profile opted out

    -- Some profile would use a launcher → name the tool(s) and the profiles.
    local by_tool, tools = {}, {}
    for _, e in ipairs(considered) do
        local st = e.status
        if st.applicable ~= false and st.present and st.tool then
            if not by_tool[st.tool] then by_tool[st.tool] = {}; tools[#tools + 1] = st.tool end
            table.insert(by_tool[st.tool], e.profile)
        end
    end
    if #tools > 0 then
        table.sort(tools)
        local parts, any_failing = {}, false
        for _, t in ipairs(tools) do
            local keys = {}
            for _, p in ipairs(by_tool[t]) do keys[#keys + 1] = p.key end
            local part = t .. " (" .. table.concat(keys, ", ") .. ")"
            local failing = failing_compiles_phrase(workspace, by_tool[t])
            if failing then
                part = part .. " — but it will fail " .. failing
                any_failing = true
            end
            parts[#parts + 1] = part
        end
        return info("Compiler cache: using " .. table.concat(parts, "; ")
            .. (any_failing and " (lw help cache)" or ""))
    end

    -- An explicit policy naming a launcher that is not found.
    for _, e in ipairs(considered) do
        local st = e.status
        if st.applicable ~= false and st.policy ~= "auto" and not st.present then
            return nag("cache=" .. st.policy .. " set but " .. st.policy .. " not found (profile "
                .. e.profile.key .. ")", install_remedy(st.policy))
        end
    end

    if present then
        if #considered == 0 then return info(present .. " available (lw help cache)") end
        return info(present .. " available — not enabled" .. (any_msvc and " for MSVC-style" or "")
            .. " (lw help cache)")
    end
    return nag("No compiler cache found", install_remedy(tool, any_msvc))
end

M.register(M.compiler_cache_provider)

--- The configured units carrying a recorded post-configure compatibility result
--- (`module_info.cache_compat`), AS RECORDED: the active profile's units, in
--- profile order — or, with NO active profile (a CI / scripted checkout), every
--- profile's units, profiles sorted by key, like the other no-active-profile
--- logic here. A unit shared by several profiles (same project + configuration)
--- is listed once.
--- @param workspace loomworks.Workspace|nil
--- @return { unit: loomworks.ConfigUnit, compat: table }[]
local function compat_units(workspace)
    local out = {}
    if type(workspace) ~= "table" then return out end
    local profiles
    if workspace._active_profile then
        profiles = { workspace._active_profile }
    else
        profiles = {}
        for _, p in pairs(workspace._profiles or {}) do profiles[#profiles + 1] = p end
        table.sort(profiles, function(a, b) return (a.key or "") < (b.key or "") end)
    end
    local seen = {}
    for _, p in ipairs(profiles) do
        if type(p.projects) == "function" then
            for _, pp in ipairs(p:projects()) do
                local u = pp._config_unit
                local compat = u and u.module_info and u.module_info.cache_compat
                if type(compat) == "table" and not seen[u] then
                    seen[u] = true
                    out[#out + 1] = { unit = u, compat = compat }
                end
            end
        end
    end
    return out
end
M._compat_units = compat_units -- also read by `_local_key`

--- `compat_units`, each record first brought up to date with the build's
--- CURRENT compile data (`ConfigUnit:refresh_cache_compat`): the build tool
--- can re-run the generator by itself (no lw configure) and add or remove the
--- flags a recorded scan found, so a record whose module stamp changed is
--- re-scanned — locally, from existing post-configure metadata, spawning
--- nothing (§16.31 "always refreshes the local checks"). The refresh is
--- in-memory only: health never writes the build cache; the next build's
--- result recording persists it.
--- @param workspace loomworks.Workspace|nil
--- @return { unit: loomworks.ConfigUnit, compat: table }[]
local function compat_records(workspace)
    local out = {}
    for _, r in ipairs(compat_units(workspace)) do
        local rec = r.compat
        if type(r.unit.refresh_cache_compat) == "function" then
            rec = r.unit:refresh_cache_compat()
        end
        if type(rec) == "table" then out[#out + 1] = { unit = r.unit, compat = rec } end
    end
    return out
end
M._compat_records = compat_records -- also read by `failing_compiles_phrase`

--- Provider: post-configure compiler-cache compatibility results (headless
--- §16.31, core §8 `cache_compat_scan`) for the active profile's units (every
--- profile's, deduplicated per unit, when none is active) — read from the
--- record core stored at configure, re-scanned first when the module's stamp
--- of the compile data changed since (`compat_records`):
---   * findings → one ACTIONABLE item per configuration: the applied launcher
---     will fail (severity "error") / cannot cache ("warning") some compiles;
---     detail lists the groups (flag + unit counts); remedy is one short line
---     (switch them to /Z7, or `cache` off — `lw help cache` explains);
---   * a scan skipped for lack of compile-command data → an INFORMATIONAL item
---     saying so (detail: why), so a clean report is never mistaken for a
---     verified one.
--- Advisory only (never gates, never changes the policy).
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.Suggestion[]
function M.cache_compat_provider(workspace)
    if not workspace then return {} end
    local cc = require("loomworks.compiler_cache")
    local items = {}
    for _, r in ipairs(compat_records(workspace)) do
        local u, rec = r.unit, r.compat
        local pkey = u._project and u._project.key or "<project>"
        local cname = u._configuration and u._configuration.name or u._variant or "<configuration>"
        local label = pkey .. "/" .. cname
        local severity = cc.compat_severity(rec)
        if rec.scanned == false then
            items[#items + 1] = {
                kind = "info",
                title = "Compiler-cache check skipped for " .. label .. " — lw help cache",
                detail = tostring(rec.reason or "no compile-command data"),
            }
        elseif severity then
            -- An environment finding (units = nil, §8) reaches every compile.
            local units, every = 0, false
            for _, f in ipairs(rec.findings or {}) do
                if f.units == nil then every = true else units = units + f.units end
            end
            items[#items + 1] = {
                kind = "suggestion",
                title = every
                    and string.format("%s %s every compile in %s", tostring(rec.tool),
                        severity == "error" and "will fail" or "cannot cache", label)
                    or string.format("%s %s %d compile%s in %s", tostring(rec.tool),
                        severity == "error" and "will fail" or "cannot cache",
                        units, units == 1 and "" or "s", label),
                -- The findings themselves (where: one line per group, with
                -- the flag); the how-to-fix explanation is `lw help cache`.
                detail = table.concat(cc.compat_group_lines(rec), "\n  "),
                -- Fix + the cache-off command for the mechanism that enabled
                -- the cache (profile fill / family override / configuration).
                remedy = cc.compat_remedy(rec, pkey, cname),
            }
        end
    end
    return items
end

M.register(M.cache_compat_provider)

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

--- Facts about the running standalone `lw` host binary (§16.32), or nil when
--- this is not the standalone host (the editor / nvim-hosted fallback — there is
--- no lw binary to update). Network-free and cheap; a seam tests replace.
---
--- `self_update` is false on a host released before host self-update existed:
--- its bootstrap has no `boot.host_update`, so `lw self-update` cannot replace it
--- and it needs one manual reinstall. `dev_build` uses the shared predicate
--- (`host_update.dev_build`) — on such an old host, whose bootstrap lacks it, the
--- predicate's fused-system-Lua test is applied directly (a bare-luvi source run
--- reads the source tree as its bundle, so that test covers it too).
--- @return { release_version?: string, self_update: boolean, dev_build: boolean, pinned: boolean, exe?: string, fused_system_lua: boolean }|nil
function M._host_facts()
    local ok_l, luvi = pcall(require, "luvi")
    if not ok_l or type(luvi) ~= "table" or type(luvi.bundle) ~= "table" then return nil end
    local fused = luvi.bundle.readfile("loomworks/cli.lua") ~= nil
    local ok_v, verify = pcall(require, "boot.verify")
    local ok_h, hu = pcall(require, "boot.host_update")
    local facts = {
        release_version = ok_v and type(verify) == "table" and verify.RELEASE_VERSION or nil,
        self_update = ok_h and type(hu) == "table" and type(hu.decide) == "function",
        pinned = os.getenv("LOOMWORKS_PINNED") ~= nil,
        fused_system_lua = fused,
    }
    if facts.self_update then
        facts.exe = hu.exe_path()
        facts.dev_build = hu.dev_build({ exe = facts.exe, fused_system_lua = fused }) ~= nil
    else
        facts.dev_build = fused
    end
    return facts
end

--- The lw binary (host) staleness item, or nil. Upgrade-only (§16.32): a host
--- self-update would replace — per the same `host_update.decide` it uses — gets
--- "run `lw self-update`"; a host too old to self-update gets "reinstall once".
--- Never for a dev build, a pinned host (lw.pin owns its version) or a host at
--- or newer than `newest`.
--- @param facts table|nil `_host_facts()` result
--- @param newest string newest release on the effective channel
--- @return loomworks.Suggestion|nil
local function host_item(facts, newest)
    if not facts or facts.dev_build or facts.pinned then return nil end
    if not facts.self_update then
        local exe = (facts.exe or ""):gsub("\\", "/"):lower()
        if exe:find("/.nvim/cache/", 1, true) then return nil end -- pinned launcher cache
        return {
            title = "lw binary predates self-update — reinstall once (see README)",
            remedy = "install the current lw binary as in the README's \"Installing lw\"; "
                .. "`lw self-update` keeps it current from then on",
        }
    end
    local hu = require("boot.host_update")
    local action = hu.decide({
        exe = facts.exe,
        running_version = facts.release_version,
        target_version = newest,
        pinned = facts.pinned,
        fused_system_lua = facts.fused_system_lua,
    })
    if action ~= "swap" then return nil end
    return {
        title = "lw binary " .. (facts.release_version or "(unknown release)")
            .. " is older than " .. newest,
        remedy = "run `lw self-update` — lw help self-update",
    }
end

--- Fingerprint of what the network tier's items describe: the running bundle,
--- the running host binary and the effective channel. Cached network items
--- recorded under another key (e.g. before a self-update) are stale. Cheap and
--- network-free — safe on the passive path.
--- @return string
function M._network_key()
    local channel = "?"
    local ok, update = pcall(require, "boot.update")
    if ok and type(update) == "table" and type(update.resolve_channel) == "function" then
        local okc, c = pcall(update.resolve_channel, {})
        if okc and c then channel = c end
    end
    local okf, facts = pcall(M._host_facts)
    local hostv = "-"
    if okf and facts then
        hostv = facts.release_version
            or (facts.dev_build and "dev") or (facts.self_update and "unknown") or "pre"
    end
    return table.concat({ M._current_release_version() or "-", hostv, channel }, "|")
end

--- Health provider: a newer release is available on the resolved update channel
--- — for the bundle ("Update available") and/or the lw binary itself (a host
--- left stale by an unwritable install dir, `--no-host`, or a host from before
--- self-update, §16.32). One item when both are stale: `lw self-update` updates
--- both — except a pre-self-update host, which it cannot replace.
--- HEALTH-ONLY — it performs a network fetch (`resolve_newest_version`). Silent
--- (returns `{}`) when: this is not a versioned release source, the channel is
--- unknown, the check fails (offline / API error), or everything is up to date.
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
    local okf, facts = pcall(M._host_facts)
    facts = okf and facts or nil
    local okh, host = pcall(host_item, facts, newest)
    host = okh and host or nil

    local out = {}
    if paths.version_gt(newest, current) then
        -- A pinned context (a repo's lw.pin — the launcher sets LOOMWORKS_PINNED
        -- and runs the bundle from `.nvim/cache/lua-<ver>`) takes its version
        -- from the pin, which `lw self-update` never changes: point at
        -- `lw update`, which moves the pin.
        local luaroot = (_G.__loomworks_luaroot or ""):gsub("\\", "/")
        local pinned = (facts and facts.pinned) or luaroot:find("/%.nvim/cache/lua%-") ~= nil
        out[1] = {
            title = "Update available",
            detail = current .. " → " .. newest .. " on the " .. channel .. " channel",
            remedy = pinned
                and ("run `lw update` to move this repo's lw.pin to " .. newest
                    .. " (the pin sets the version here, not `lw self-update`)")
                or "run `lw self-update`",
        }
        -- self-update replaces a self-updating host too; only a host it cannot
        -- replace needs its own item.
        if host and facts and facts.self_update then host = nil end
    end
    if host then out[#out + 1] = host end
    return out
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
