--- loomworks/compiler_cache.lua — Compiler-cache (ccache / sccache) resolution.
---
--- Core owns *resolution*: it derives a concrete launcher from the effective
--- `cache` **policy** (core §1.3.2, the reserved `cache` variable) and the
--- active tool's compiler family, gated on the launcher actually being present
--- on the toolchain search path. Modules own *application* — how to wrap their
--- own compiler invocation with the resolved launcher (see the per-module
--- specs). The resolved launcher is derived, never stored; a change to it makes
--- a configured unit stale (core §5, module §11).
---
--- This module is deliberately free of any module-specific ("if cmake …")
--- logic: it maps (policy, family) → `{ tool, path }|nil` and nothing more.

local M = {}

--- Under `auto`, the ordered launcher preference per normalized compiler
--- family. A gcc/clang family prefers ccache and falls back to sccache — both
--- fall back to a plain compile for anything they cannot cache, so enabling
--- them automatically is safe. The MSVC-style family (msvc, and clang-cl) is
--- deliberately ABSENT: under `auto` it resolves to no launcher (spec §1.3.2),
--- because sccache FAILS a compile that writes a shared .pdb (/Zi, /ZI) and
--- such flags can come from code loomworks does not control. Caching there is
--- an explicit opt-in (`cache=sccache` / `cache=ccache`).
--- @type table<string, string[]>
local AUTO_PREFERENCE = {
    gcc = { "ccache", "sccache" },
    clang = { "ccache", "sccache" },
}

--- Fallback preference when the compiler family is unknown/undeterminable.
local DEFAULT_PREFERENCE = { "ccache", "sccache" }

--- Normalize a raw `cache` policy value (string or boolean) to one of
--- `"auto"`, `"off"`, or a concrete launcher name (lower-cased). `false`, and
--- the strings `off`/`false`/`none`/`no`, all mean "off"; `nil`/empty/`auto`
--- mean "auto"; anything else is treated as "prefer this named launcher".
--- @param policy string|boolean|nil
--- @return "auto"|"off"|string
function M.normalize_policy(policy)
    if policy == nil then return "auto" end
    if policy == false then return "off" end
    if policy == true then return "auto" end -- defensive: bare `true` == on == auto
    if type(policy) ~= "string" then return "auto" end
    local p = policy:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if p == "" or p == "auto" then return "auto" end
    if p == "off" or p == "false" or p == "none" or p == "no" then return "off" end
    return p
end

--- Whether a raw family string names an MSVC-style compiler for the `auto`
--- rule: `msvc`, or the MSVC-ABI clang-cl driver (which `normalize_family`
--- folds to `clang`, so the signal is recovered from the raw string).
--- @param family any
--- @return boolean
local function msvc_style_family(family)
    if type(family) ~= "string" then return false end
    local f = family:lower()
    if f:find("clang-cl", 1, true) then return true end
    return require("loomworks.cpp_compilers").normalize_family(family) == "msvc"
end

--- Whether `policy` is `auto` AND `family` is MSVC-style, i.e. `auto`
--- deliberately resolves to no launcher here (spec §1.3.2) — as opposed to
--- "no launcher found". Status/health use it to say "not enabled
--- automatically for MSVC-style compilers" instead of "none found".
--- @param policy string|boolean|nil
--- @param family any
--- @return boolean
function M.auto_off_for_family(policy, family)
    return M.normalize_policy(policy) == "auto" and msvc_style_family(family)
end

--- Resolve a compiler-cache launcher from a policy + compiler family.
---
--- `lookup(name) -> string|nil` resolves an executable name to an absolute path
--- (or nil when absent); it defaults to the shared `cpp_compilers` PATH index,
--- and is injectable so tests need no real filesystem.
--- @param policy string|boolean|nil effective `cache` policy (core §1.3.2)
--- @param family? "clang"|"gcc"|"msvc"|string|nil active compiler family
--- @param lookup? fun(name: string): string|nil executable resolver
--- @return { tool: string, path: string }|nil
function M.resolve(policy, family, lookup)
    lookup = lookup or require("loomworks.cpp_compilers").lookup_path

    local p = M.normalize_policy(policy)
    if p == "off" then return nil end

    local candidates
    if p == "auto" then
        -- MSVC-style (msvc, clang-cl): `auto` never enables a launcher (§1.3.2).
        -- resolve_for passes an already-MSVC-ified family for a clang-cl
        -- tool_data; the raw "clang-cl" string is handled too.
        if msvc_style_family(family) then return nil end
        local fam = require("loomworks.cpp_compilers").normalize_family(family)
        candidates = AUTO_PREFERENCE[fam or ""] or DEFAULT_PREFERENCE
    else
        -- Explicit named launcher: use exactly that tool (still PATH-gated).
        candidates = { p }
    end

    for _, tool in ipairs(candidates) do
        local path = lookup(tool)
        if path then
            return { tool = tool, path = path }
        end
    end
    return nil
end

--- Resolve the launcher for a (project, configuration) pair by first resolving
--- the effective `cache` policy through the variable machinery, then mapping it
--- to a launcher. This is the single seam the build-context assembly calls —
--- and the one status/health reporting must use too, so what is displayed is
--- exactly what a build applies (e.g. clang-cl counting as MSVC-style, so
--- `auto` leaves it uncached).
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil resolved tool_data (yields the compiler family)
--- @param profile? loomworks.Profile active profile (machine-local fill)
--- @param lookup? fun(name: string): string|nil executable resolver
--- @return { tool: string, path: string }|nil launcher
--- @return "auto"|"off"|string|nil policy the normalized effective policy (nil without a project)
--- @return table|nil source which layer supplied the policy (`variables.resolve_cache_policy`)
function M.resolve_for(project, configuration, tool_data, profile, lookup)
    if not project then return nil, nil, nil end
    local cpp = require("loomworks.cpp_compilers")
    -- Compiler-family for OVERRIDES resolution folds clang-cl → clang (spec: a
    -- clang-cl build honours `overrides.clang`).
    local override_family = cpp.family_from_tool_data(tool_data)
    local variables = require("loomworks.variables")
    local policy, source = variables.resolve_cache_policy(
        project, configuration, override_family, profile)
    -- Compiler-family for the launcher PREFERENCE treats clang-cl as MSVC-style
    -- (auto → no launcher, §1.3.2) — distinct from the override family above.
    local pref_family = cpp.is_msvc_style(tool_data) and "msvc" or override_family
    return M.resolve(policy, pref_family, lookup), M.normalize_policy(policy), source
end

--- A persistable (string-only) form of a policy provenance from `resolve_for`
--- / `variables.resolve_cache_policy`, stored with a compat record so its
--- "turn caching off" hint names the mechanism that enabled the cache.
--- @param source table|nil
--- @return { layer: string, configuration?: string, family?: string, profile?: string }|nil
function M.policy_source_record(source)
    if type(source) ~= "table" or type(source.layer) ~= "string" then return nil end
    return {
        layer = source.layer,
        configuration = source.configuration and source.configuration.name or nil,
        family = source.family,
        profile = source.profile and source.profile.key or nil,
    }
end

--- The command that turns caching off through the mechanism that enabled it
--- (a compat record's `policy_source`): the profile fill → `lw profile set
--- <profile> <project> cache off`; a compiler-family override → `lw config set
--- <project> <cfg> overrides.<family>.cache off`; a configuration variable →
--- `lw config set <project> <cfg> variables.cache off` (on the chain level that
--- set it). Without a recorded source (an older record, or the default), the
--- configuration's own `variables.cache`.
--- @param rec table|nil `module_info.cache_compat`
--- @param project_key string
--- @param config_name string
--- @return string
function M.cache_off_command(rec, project_key, config_name)
    local src = type(rec) == "table" and rec.policy_source or nil
    local layer = type(src) == "table" and src.layer or nil
    if layer == "profile" and src.profile then
        return string.format("lw profile set %s %s cache off", src.profile, project_key)
    elseif layer == "override" and src.family then
        return string.format("lw config set %s %s overrides.%s.cache off", project_key,
            src.configuration or config_name, src.family)
    elseif layer == "configuration" then
        return string.format("lw config set %s %s variables.cache off", project_key,
            src.configuration or config_name)
    end
    return string.format("lw config set %s %s variables.cache off", project_key, config_name)
end

--- The launcher name (`sccache`, `ccache`, …) for a recorded launcher path —
--- the lower-cased basename without an `.exe` suffix. nil for nil/"none".
--- @param path string|nil
--- @return string|nil
function M.tool_of_path(path)
    if type(path) ~= "string" or path == "" or path == "none" then return nil end
    local base = path:gsub("\\", "/"):match("[^/]+$") or path
    return (base:lower():gsub("%.exe$", ""))
end

--- The module's CURRENT freshness stamp of the compile data its compatibility
--- scan reads (core §8 `cache_compat_stamp`) — an opaque string that changes
--- whenever that data is rewritten (a configure, or the generator re-run the
--- build tool triggers itself). nil when the module has no stamp hook, the
--- hook errors, or there is no data yet. Cheap by contract (a stat or a
--- directory listing), so health's passive key may call it.
--- @param impl table|nil module implementation
--- @param ctx table the scan context (`build_dir`, `tool_data`, …)
--- @return string|nil
function M.compat_stamp(impl, ctx)
    if not impl or type(impl.cache_compat_stamp) ~= "function" then return nil end
    local ok, stamp = pcall(impl.cache_compat_stamp, ctx or {})
    return (ok and type(stamp) == "string") and stamp or nil
end

--- Run a module's optional post-configure compatibility scan (core §5.1, §8
--- `cache_compat_scan`) for a configure that applied `launcher_path`. Returns
--- the record core stores in `module_info.cache_compat` —
--- `{ tool, scanned, reason?, findings[], totals?, advice?, source_stamp? }`
--- (`totals` = `{ units, targets }` compiled in the scanned build, `advice` =
--- the module's wording, both optional; `source_stamp` = the module's
--- `cache_compat_stamp` of the data scanned, taken BEFORE the scan so a
--- rewrite racing it reads as changed next time) — or nil when the module has
--- no hook or no launcher was applied. A throwing hook is recorded as skipped
--- (advisory: never break the configure). Core adds `policy_source` (which
--- layer enabled the cache).
--- @param impl table|nil module implementation
--- @param ctx table `{ build_dir, configuration, tool_data, config_name, variant, configuration_env }` (`configuration_env`: the resolved configuration environment the configure ran with, core §1.3.3 — e.g. MSVC's `CL` / `_CL_`, which compile commands do not show)
--- @param launcher_path string|nil recorded launcher ("none"/nil → no scan)
--- @return table|nil
function M.run_compat_scan(impl, ctx, launcher_path)
    local tool = M.tool_of_path(launcher_path)
    if not tool then return nil end
    if not impl or type(impl.cache_compat_scan) ~= "function" then return nil end
    local scan_ctx = vim.tbl_extend("force", {}, ctx or {})
    scan_ctx.compiler_cache = { tool = tool, path = launcher_path }
    local stamp = M.compat_stamp(impl, scan_ctx)
    local ok, res = pcall(impl.cache_compat_scan, scan_ctx)
    if not ok or type(res) ~= "table" then
        return { tool = tool, scanned = false, findings = {}, source_stamp = stamp,
            reason = "the compatibility check failed: " .. tostring(res) }
    end
    local totals = type(res.totals) == "table" and res.totals or nil
    local advice = type(res.advice) == "table" and res.advice or nil
    return {
        tool = tool,
        scanned = res.scanned ~= false,
        reason = res.reason,
        findings = type(res.findings) == "table" and res.findings or {},
        totals = totals and {
            units = tonumber(totals.units), targets = tonumber(totals.targets),
        } or nil,
        advice = advice and {
            fix_targets = type(advice.fix_targets) == "string" and advice.fix_targets or nil,
            cause_pervasive = type(advice.cause_pervasive) == "string" and advice.cause_pervasive or nil,
            fix_pervasive = type(advice.fix_pervasive) == "string" and advice.fix_pervasive or nil,
        } or nil,
        source_stamp = stamp,
    }
end

--- The worst severity among a compat record's findings ("error" > "warning"),
--- or nil when there are none.
--- @param rec table|nil `module_info.cache_compat`
--- @return "error"|"warning"|nil
function M.compat_severity(rec)
    local worst
    for _, f in ipairs(rec and rec.findings or {}) do
        if f.severity == "error" then return "error" end
        worst = "warning"
    end
    return worst
end

--- Shorten a sample source path to its last two components (`…/dir/a.c`), so
--- a finding line stays readable for deep dependency trees.
--- @param p any
--- @return string
local function short_path(p)
    local s = tostring(p):gsub("\\", "/")
    local parts = {}
    for seg in s:gmatch("[^/]+") do parts[#parts + 1] = seg end
    if #parts <= 2 then return s end
    return "…/" .. parts[#parts - 1] .. "/" .. parts[#parts]
end

--- The unit-level findings of a compat record (those with a unit count — not
--- an environment finding) and their summed unit count.
--- @param rec table|nil
--- @return table[] findings, integer units
local function unit_findings(rec)
    local out, units = {}, 0
    for _, f in ipairs(rec and rec.findings or {}) do
        if type(f.units) == "number" then
            out[#out + 1] = f
            units = units + f.units
        end
    end
    return out, units
end

--- Share of the scanned build's compiled units a finding must cover to be
--- reported as PERVASIVE (one collapsed line instead of one per target).
M.PERVASIVE_SHARE = 0.9

--- Whether a compat record's unit findings cover every (or nearly every —
--- `PERVASIVE_SHARE`) compiled unit of the scanned build, across more than one
--- group: the flag then almost certainly comes from a directory- or
--- project-wide setting, not from individual targets, so listing every target
--- (hundreds) helps nobody and per-target advice is wrong. Needs the module's
--- `totals`; false without them.
--- @param rec table|nil
--- @return boolean pervasive, integer units, integer total_units
function M.compat_pervasive(rec)
    local total = rec and type(rec.totals) == "table" and tonumber(rec.totals.units) or nil
    local list, units = unit_findings(rec)
    if not total or total <= 0 or #list < 2 then return false, units, total or 0 end
    return units >= M.PERVASIVE_SHARE * total, units, total
end

--- One-line-per-group summary of a compat record's findings, e.g.
--- `zlib: 12 units (/Zi) — …/zlib/a.c, …/zlib/b.c`, or for an environment
--- finding (no unit count) `environment: every compile (/Zi) — CL`. A
--- PERVASIVE record (`compat_pervasive`) collapses its unit findings into ONE
--- line — `every target (1870 units) compiles with /Zi — <module cause>` (or
--- `nearly every target (… of … units, … of … targets)`) — keeping any
--- environment lines. Sample paths are shortened to their last two components.
--- @param rec table
--- @return string[]
function M.compat_group_lines(rec)
    local lines = {}
    local pervasive, units, total = M.compat_pervasive(rec)
    if pervasive then
        local list = unit_findings(rec)
        local flag = tostring(list[1].flag)
        local total_targets = type(rec.totals) == "table" and tonumber(rec.totals.targets) or nil
        local scope
        if units >= total and (not total_targets or #list >= total_targets) then
            scope = string.format("every target (%d units)", units)
        else
            scope = string.format("nearly every target (%d of %d units%s)", units, total,
                total_targets and string.format(", %d of %d targets", #list, total_targets) or "")
        end
        local cause = rec.advice and rec.advice.cause_pervasive
            or "likely a directory- or project-wide compile option"
        lines[#lines + 1] = string.format("%s compiles with %s — %s", scope, flag, cause)
    end
    for _, f in ipairs(rec and rec.findings or {}) do
        local line
        if f.units == nil then
            -- An environment finding (§8): the flag reaches every compile.
            line = string.format("%s: every compile (%s)", tostring(f.group), tostring(f.flag))
        elseif not pervasive then
            line = string.format("%s: %d unit%s (%s)", tostring(f.group), f.units,
                f.units == 1 and "" or "s", tostring(f.flag))
        end
        if line then
            if type(f.sample) == "table" and #f.sample > 0 then
                local sample = {}
                for i, p in ipairs(f.sample) do sample[i] = f.units == nil and tostring(p) or short_path(p) end
                line = line .. " — " .. table.concat(sample, ", ")
            end
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- How to fix a compat record's findings (without the cache-off alternative):
--- the module's `advice` wording for a pervasive / per-target record, else a
--- generic sentence. An environment finding adds where to remove it.
--- @param rec table
--- @return string
local function compat_fix(rec)
    local advice = rec.advice or {}
    local parts = {}
    local list = unit_findings(rec)
    if #list > 0 then
        if M.compat_pervasive(rec) then
            parts[#parts + 1] = advice.fix_pervasive
                or "remove that /Zi where it is set (or make it /Z7)"
        else
            parts[#parts + 1] = advice.fix_targets
                or "switch those targets to embedded debug info (/Z7)"
        end
    end
    for _, f in ipairs(rec.findings or {}) do
        if f.units == nil then
            local var = type(f.sample) == "table" and f.sample[1] or "CL"
            parts[#parts + 1] = string.format("remove %s from the configuration's env.%s",
                tostring(f.flag), tostring(var))
        end
    end
    return table.concat(parts, "; ")
end

--- The end-of-configure message for a compat record with findings (nil when
--- clean or skipped): what fails / is not cached, where, and both ways out —
--- the fix (module advice) and turning caching off through the mechanism that
--- enabled it (`cache_off_command`).
--- @param rec table|nil `module_info.cache_compat`
--- @param project_key string
--- @param config_name string
--- @return string|nil message, "error"|"warning"|nil severity
function M.compat_message(rec, project_key, config_name)
    local severity = M.compat_severity(rec)
    if not severity then return nil, nil end
    local effect = severity == "error"
        and (rec.tool .. " will FAIL these compiles")
        or (rec.tool .. " cannot cache these compiles")
    local fix = compat_fix(rec)
    local msg = string.format(
        "%s/%s: %s — they write a shared .pdb debug database:\n  %s\n"
            .. "Fix: %s — or turn caching off: %s   (lw help cache)",
        project_key, config_name, effect,
        table.concat(M.compat_group_lines(rec), "\n  "),
        fix, M.cache_off_command(rec, project_key, config_name))
    return msg, severity
end

--- The one-line health remedy for a compat record: the short fix plus the
--- cache-off command for the mechanism in effect, and the help topic.
--- @param rec table
--- @param project_key string
--- @param config_name string
--- @return string
function M.compat_remedy(rec, project_key, config_name)
    local list = unit_findings(rec)
    local fix
    if #list == 0 then
        fix = "remove it from the configuration's env"
    elseif M.compat_pervasive(rec) then
        fix = "remove the directory-wide /Zi"
    else
        fix = "switch them to /Z7"
    end
    return string.format("%s, or `%s` — lw help cache", fix,
        M.cache_off_command(rec, project_key, config_name))
end

--- The closing line after a FAILED build of a unit whose post-configure scan
--- recorded an error-severity finding (the launcher fails those compiles):
--- points back at the finding instead of leaving the reader to connect a
--- compiler error to it. nil when the record has no error finding. Advisory
--- only — the scan never gates the build (§5.1).
--- @param rec table|nil `module_info.cache_compat`
--- @return string|nil
function M.compat_failure_hint(rec)
    if M.compat_severity(rec) ~= "error" then return nil end
    local _, units = unit_findings(rec)
    local env = false
    for _, f in ipairs(rec.findings or {}) do if f.units == nil then env = true end end
    local flag = rec.findings[1] and rec.findings[1].flag or "/Zi"
    local what
    if units > 0 then
        what = string.format("%d compile%s use%s %s", units, units == 1 and "" or "s",
            units == 1 and "s" or "", tostring(flag))
    elseif env then
        what = string.format("every compile gets %s from the configuration env", tostring(flag))
    else
        what = "some compiles use " .. tostring(flag)
    end
    return string.format("build failed — %s, which %s cannot cache (see the scan finding "
        .. "above; lw health; lw help cache)", what, tostring(rec.tool))
end

--- Whether a module can apply a compiler-cache launcher to a configuration at
--- all — its optional `cache_launcher_applicable(ctx)` hook (module interface
--- §8), which may also return a short `reason` and a one-sentence `hint` when
--- it cannot. Absent hook, or a hook that errors, means applicable. Shared by
--- launcher staleness (`ConfigUnit`) and the profile's cache status / health so
--- they never disagree.
--- @param impl table|nil module implementation
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil
--- @return boolean applicable, string|nil reason, string|nil hint
function M.applicability(impl, configuration, tool_data)
    if not impl or type(impl.cache_launcher_applicable) ~= "function" then return true end
    local ok, applicable, reason, hint = pcall(impl.cache_launcher_applicable, {
        configuration = configuration,
        tool_data = tool_data,
    })
    if not ok or applicable ~= false then return true end
    return false, type(reason) == "string" and reason or nil,
        type(hint) == "string" and hint or nil
end

--- Return the name of the first compiler-cache launcher present on the
--- toolchain search path (checking `sccache` then `ccache`), or nil when none
--- is installed. Used by the health suggestion provider and status reporting;
--- it never spawns the tool. `lookup` is injectable for tests.
--- @param lookup? fun(name: string): string|nil
--- @return string|nil tool name of the present launcher
function M.any_present(lookup)
    lookup = lookup or require("loomworks.cpp_compilers").lookup_path
    for _, tool in ipairs({ "sccache", "ccache" }) do
        if lookup(tool) then return tool end
    end
    return nil
end

return M
