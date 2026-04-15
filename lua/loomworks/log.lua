--- loomworks/log.lua — Structured logger with file output.
---
--- Writes to {workspace_root}/.nvim/loomworks.log by default.
--- Injectable via core deps for testing. Levels: ERROR, WARN, INFO, DEBUG.
--- Truncates log on each workspace load to prevent unbounded growth.

local M = {}

--- @class loomworks.Logger
--- @field _path string|nil log file path
--- @field _level number minimum log level
--- @field _entries string[] captured entries (for testing)
--- @field _capture boolean if true, capture to _entries instead of file
local Logger = {}
Logger.__index = Logger

--- Log levels.
M.ERROR = 1
M.WARN  = 2
M.INFO  = 3
M.DEBUG = 4

local LEVEL_NAMES = { "ERROR", "WARN", "INFO", "DEBUG" }

--- Create a new logger.
--- @param opts? { path?: string, level?: number, capture?: boolean }
--- @return loomworks.Logger
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Logger)
    self._path = opts.path
    self._level = opts.level or M.INFO
    self._entries = {}
    self._capture = opts.capture or false
    return self
end

--- Set the log file path. Called when workspace root is known.
--- Truncates existing log.
--- @param root string workspace root path
function Logger:set_root(root)
    self._path = root .. "/.nvim/loomworks.log"
    -- Truncate on workspace load
    local f = io.open(self._path, "w")
    if f then
        f:write("-- loomworks log started " .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\n")
        f:close()
    end
end

--- Set minimum log level.
--- @param level number M.ERROR, M.WARN, M.INFO, or M.DEBUG
function Logger:set_level(level)
    self._level = level
end

--- Format and write a log entry.
--- @param level number
--- @param fmt string format string
--- @param ... any format arguments
local function write_entry(self, level, fmt, ...)
    if level > self._level then return end

    local msg = string.format(fmt, ...)
    local timestamp = os.date("!%H:%M:%S")
    local entry = string.format("[%s] %s: %s", timestamp, LEVEL_NAMES[level] or "?", msg)

    if self._capture then
        self._entries[#self._entries + 1] = entry
        return
    end

    if not self._path then return end

    local f = io.open(self._path, "a")
    if f then
        f:write(entry .. "\n")
        f:close()
    end
end

--- Log an error.
--- @param fmt string
--- @param ... any
function Logger:error(fmt, ...)
    write_entry(self, M.ERROR, fmt, ...)
end

--- Log a warning.
--- @param fmt string
--- @param ... any
function Logger:warn(fmt, ...)
    write_entry(self, M.WARN, fmt, ...)
end

--- Log an info message.
--- @param fmt string
--- @param ... any
function Logger:info(fmt, ...)
    write_entry(self, M.INFO, fmt, ...)
end

--- Log a debug message.
--- @param fmt string
--- @param ... any
function Logger:debug(fmt, ...)
    write_entry(self, M.DEBUG, fmt, ...)
end

--- Get captured entries (for testing).
--- @return string[]
function Logger:entries()
    return self._entries
end

--- Clear captured entries.
function Logger:clear()
    self._entries = {}
end

--- Create a default file-based logger (singleton for production use).
--- Path is set later via set_root().
--- @return loomworks.Logger
function M.default()
    return M.new()
end

--- Create a capture-mode logger for testing.
--- @param level? number default DEBUG (capture everything)
--- @return loomworks.Logger
function M.test(level)
    return M.new({ capture = true, level = level or M.DEBUG })
end

return M
