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
function M.resolve_for(project, configuration, tool_data, profile, lookup)
    if not project then return nil, nil end
    local cpp = require("loomworks.cpp_compilers")
    -- Compiler-family for OVERRIDES resolution folds clang-cl → clang (spec: a
    -- clang-cl build honours `overrides.clang`).
    local override_family = cpp.family_from_tool_data(tool_data)
    local variables = require("loomworks.variables")
    local policy = variables.resolve_cache_policy(
        project, configuration, override_family, profile)
    -- Compiler-family for the launcher PREFERENCE treats clang-cl as MSVC-style
    -- (auto → no launcher, §1.3.2) — distinct from the override family above.
    local pref_family = cpp.is_msvc_style(tool_data) and "msvc" or override_family
    return M.resolve(policy, pref_family, lookup), M.normalize_policy(policy)
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
