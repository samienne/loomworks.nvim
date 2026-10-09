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

return M
