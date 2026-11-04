--- loomworks/debug_config.lua — the debug-adapter tables: which DAP adapter
--- debugs a language by default, which adapters a language offers, and the
--- resolution of a workspace's user.json override (`debug.adapters`).
---
--- Host-neutral (pure Lua, no `vim.*`): the editor's debug path and section
--- read it in-process today, and the workspace daemon serves the same tables
--- (`DebugConfig/1`, step 5k). Starting a debug session (nvim-dap) is the
--- editor's: loomworks/debug.lua.

local M = {}

--- Default adapter mapping: language → DAP adapter type.
--- @type table<string, string>
local DEFAULT_ADAPTERS = {
    ["c++"] = "codelldb",
    typescript = "pwa-node",
}

--- Known adapters per language (for picker UI).
--- @type table<string, string[]>
local KNOWN_ADAPTERS = {
    ["c++"] = { "codelldb", "cppdbg" },
    typescript = { "pwa-node", "pwa-chrome" },
}

--- Resolve the DAP adapter type for a language.
--- Checks workspace debug settings (from user.json) first, falls back to defaults.
--- @param workspace loomworks.Workspace|{ _debug_settings?: { adapters?: table<string, string> } }
--- @param language string language name (e.g. "c++", "typescript")
--- @return string|nil adapter_type
function M.resolve_adapter(workspace, language)
    local settings = workspace._debug_settings
    if settings and settings.adapters and settings.adapters[language] then
        return settings.adapters[language]
    end
    return DEFAULT_ADAPTERS[language]
end

--- Get the list of known adapters for a language.
--- @param language string
--- @return string[]
function M.known_adapters(language)
    return KNOWN_ADAPTERS[language] or {}
end

--- Get the default adapter for a language.
--- @param language string
--- @return string|nil
function M.default_adapter(language)
    return DEFAULT_ADAPTERS[language]
end

--- Get all known languages.
--- @return string[]
function M.known_languages()
    local langs = {}
    for lang in pairs(DEFAULT_ADAPTERS) do
        langs[#langs + 1] = lang
    end
    table.sort(langs)
    return langs
end

--- Every language a module or integration declares (spec §8.9.6
--- "Language-based adapter resolution"; `DebugConfig/1.known_languages`):
--- the languages with a default adapter, and those of the workspace's
--- modules (`Module.languages`), sorted.
--- @param workspace loomworks.Workspace|{ _modules?: { languages?: string[] }[] }
--- @return string[]
function M.workspace_languages(workspace)
    local seen, langs = {}, {}
    local function add(lang)
        if type(lang) == "string" and lang ~= "" and not seen[lang] then
            seen[lang] = true
            langs[#langs + 1] = lang
        end
    end
    for _, lang in ipairs(M.known_languages()) do add(lang) end
    for _, mod in ipairs(workspace._modules or {}) do
        for _, lang in ipairs(type(mod.languages) == "table" and mod.languages or {}) do add(lang) end
    end
    table.sort(langs)
    return langs
end

--- The languages of the workspace's modules (`Module.languages`), each once,
--- sorted: those the debug adapters section and `DebugConfig/1.adapters` list.
--- @param workspace loomworks.Workspace|{ _modules?: { languages?: string[] }[] }
--- @return string[]
function M.module_languages(workspace)
    local seen, langs = {}, {}
    for _, mod in ipairs(workspace._modules or {}) do
        for _, lang in ipairs(type(mod.languages) == "table" and mod.languages or {}) do
            if type(lang) == "string" and lang ~= "" and not seen[lang] then
                seen[lang] = true
                langs[#langs + 1] = lang
            end
        end
    end
    table.sort(langs)
    return langs
end

--- The workspace's debug-adapter mapping (`DebugConfig/1.adapters`, API.md
--- §12): one record per language of the workspace's modules
--- (`Module.languages`), sorted; none when no module declares a language. A
--- language with only a default adapter and no module gets no record
--- (workspace_languages has those). Each record: the adapter in effect
--- (`adapter`, absent with neither an override nor a default), the
--- integration's `default`, the adapters `known` for the language (from the
--- integrations' declarations, never from a debugger), and whether the
--- working copy `overridden` the default.
--- @param workspace loomworks.Workspace
--- @return { language: string, adapter?: string, default?: string, known: string[], overridden: boolean }[]
function M.adapter_records(workspace)
    local settings = workspace._debug_settings
    local overrides = settings and settings.adapters or {}
    local records = {}
    for _, lang in ipairs(M.module_languages(workspace)) do
        local known = {}
        for i, a in ipairs(M.known_adapters(lang)) do known[i] = a end
        records[#records + 1] = {
            language = lang, adapter = M.resolve_adapter(workspace, lang), default = M.default_adapter(lang),
            known = known, overridden = overrides[lang] ~= nil,
        }
    end
    return records
end

return M
