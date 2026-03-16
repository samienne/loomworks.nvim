--- loomworks/progress/init.lua — Progress parser registry.
--- Maps build tool names to parser functions.
--- Modules declare which parser to use; the task tracker component
--- feeds output lines through the appropriate parser.

local M = {}

--- @alias loomworks.ProgressParser fun(line: string): loomworks.ProgressUpdate|nil

--- @class loomworks.ProgressUpdate
--- @field current number current step
--- @field total number total steps
--- @field message? string optional description (e.g. "Building CXX object...")

--- @type table<string, loomworks.ProgressParser>
local parsers = {}

--- Register a progress parser for a build tool.
--- @param tool string tool name (e.g. "ninja", "msbuild")
--- @param parser loomworks.ProgressParser
function M.register(tool, parser)
    parsers[tool] = parser
end

--- Get a progress parser by tool name.
--- Auto-loads from loomworks.progress.<tool> if not yet registered.
--- @param tool string
--- @return loomworks.ProgressParser|nil
function M.get(tool)
    if not parsers[tool] then
        local ok, mod = pcall(require, "loomworks.progress." .. tool)
        if ok and type(mod) == "function" then
            parsers[tool] = mod
        end
    end
    return parsers[tool]
end

return M
