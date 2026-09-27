--- loomworks/progress/init.lua — Progress parser registry.
--- Maps build tool names to parser functions.
--- Modules declare which parser to use; the task tracker component
--- feeds output lines through the appropriate parser.

local M = {}

--- @alias loomworks.ProgressParser fun(line: string): loomworks.ProgressUpdate|nil

--- @class loomworks.ProgressUpdate
--- @field current? number current step (nil for message-only updates)
--- @field total? number total steps (nil for message-only updates)
--- @field message? string status description (e.g. "Building CXX object...", "CompileArkTS")

--- @type table<string, loomworks.ProgressParser>
local parsers = {}

--- Register a progress parser for a build tool.
--- @param tool string tool name (e.g. "ninja", "msbuild")
--- @param parser loomworks.ProgressParser
function M.register(tool, parser)
    parsers[tool] = parser
end

--- Get a progress parser by tool name.
--- Auto-loads from loomworks.progress.<tool> if not yet registered — through
--- `loomworks.plugin_loader` (runtime path only, plain-identifier names only),
--- since the name is chosen by a module from project/tool data.
--- @param tool string
--- @return loomworks.ProgressParser|nil
function M.get(tool)
    if type(tool) ~= "string" then return nil end
    if not parsers[tool] then
        local mod = require("loomworks.plugin_loader").load("progress", tool)
        if type(mod) == "function" then
            parsers[tool] = mod
        end
    end
    return parsers[tool]
end

return M
