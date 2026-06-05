--- loomworks/languages.lua — central source of truth for which
--- language strings loomworks tracks.
---
--- A language is "tracked" if anything in loomworks can act on it:
---   * a registered module declares it in its `languages` field
---     (compile-time relevance: module tasks / tool routing / LSP)
---   * a debug adapter is mapped to it
---     (runtime relevance: launch/attach uses it for adapter resolution)
---
--- Anything else (cmake's `RC`, `ASM`, `ISPC`, vendor-internal
--- pseudo-languages) is intentionally invisible to the language-drift
--- diagnostic and to the configuration's effective_languages
--- comparison. Adding routing for a new language (e.g. Swift, CUDA)
--- happens by declaring it on the module or wiring it into the debug
--- adapter table — never by adding it to a hardcoded list here. Keeping
--- this derived from the registry prevents the set from going stale
--- as modules come and go.

local M = {}

--- Return the set of languages loomworks tracks.
--- Computed fresh on each call so module registration order and
--- debug-adapter overrides are picked up without a restart. Cheap:
--- the module registry is small and each module's `languages` field
--- is a short literal array.
--- @return table<string, true>
function M.tracked_set()
    local set = {}

    -- Languages declared by any loaded module. Iterating `list()`
    -- forces lazy module loading so the union is complete the first
    -- time anyone asks.
    local modules = require("loomworks.modules")
    for _, id in ipairs(modules.list()) do
        local mod = modules.get(id)
        if mod and type(mod.languages) == "table" then
            for _, lang in ipairs(mod.languages) do
                if type(lang) == "string" and lang ~= "" then
                    set[lang] = true
                end
            end
        end
    end

    -- Languages with a debug-adapter mapping. These may not be tied
    -- to any module (e.g. a future swift-only debug setup) but a user
    -- could still meaningfully declare them on a launch config.
    local ok, debug_mod = pcall(require, "loomworks.debug")
    if ok and debug_mod.known_languages then
        for _, lang in ipairs(debug_mod.known_languages()) do
            set[lang] = true
        end
    end

    return set
end

--- Filter an array of language strings to only those loomworks tracks.
--- Preserves order; drops duplicates.
--- @param langs string[]
--- @return string[]
function M.filter(langs)
    if type(langs) ~= "table" or #langs == 0 then return {} end
    local set = M.tracked_set()
    local seen = {}
    local result = {}
    for _, lang in ipairs(langs) do
        if type(lang) == "string" and set[lang] and not seen[lang] then
            seen[lang] = true
            result[#result + 1] = lang
        end
    end
    return result
end

return M
