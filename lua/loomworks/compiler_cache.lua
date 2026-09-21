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
--- family. sccache is the cross-platform fallback: an MSVC/clang-cl family
--- prefers it outright, a gcc/clang family prefers ccache and falls back to it.
--- @type table<string, string[]>
local AUTO_PREFERENCE = {
    msvc = { "sccache", "ccache" },
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
--- to a launcher. This is the single seam the build-context assembly calls.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil resolved tool_data (yields the compiler family)
--- @param profile? loomworks.Profile active profile (machine-local fill)
--- @param lookup? fun(name: string): string|nil executable resolver
--- @return { tool: string, path: string }|nil
function M.resolve_for(project, configuration, tool_data, profile, lookup)
    if not project then return nil end
    local cpp = require("loomworks.cpp_compilers")
    local family = cpp.family_from_tool_data(tool_data)
    local variables = require("loomworks.variables")
    local policy = variables.resolve_cache_policy(project, configuration, family, profile)
    return M.resolve(policy, family, lookup)
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
