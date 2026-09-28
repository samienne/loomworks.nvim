--- loomworks/log.lua — Structured logger with file output.
---
--- Writes to {workspace_root}/.nvim/loomworks.log by default.
--- Injectable via core deps for testing. Levels: ERROR, WARN, INFO, DEBUG.
---
--- The file is shared by every host — the editor and each `lw` invocation,
--- possibly at the same time — so it is only ever opened in append mode
--- (never truncated): earlier invocations' lines survive, and concurrent
--- writers each append whole lines. Its size is bounded by rotation: once it
--- exceeds `M.MAX_BYTES` it is renamed to `loomworks.log.1` (replacing the
--- previous one — one old file is kept) and a new file starts. Rotation is
--- best-effort: a failed rename (e.g. the file is momentarily open elsewhere
--- on Windows) just means a later write tries again.

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

--- Rotation threshold for the log file (bytes).
M.MAX_BYTES = 1024 * 1024

local function file_size(path)
    local uv = vim.uv or vim.loop
    local st = uv and uv.fs_stat(path)
    return st and st.size or 0
end

--- Rotate `path` to `path.1` when it exceeds the limit. The size is
--- re-checked right before the rename, narrowing the race with a concurrent
--- writer that rotated first (worst case an old `.1` is replaced early; the
--- live file is never truncated).
local function maybe_rotate(path)
    if file_size(path) <= M.MAX_BYTES then return end
    local old = path .. ".1"
    pcall(os.remove, old)
    if file_size(path) > M.MAX_BYTES then pcall(os.rename, path, old) end
end

--- Append one chunk (whole lines) in a single write, then rotate when the
--- file has grown past the limit.
local function append(path, text)
    local f = io.open(path, "ab")
    if not f then return end
    f:write(text)
    local size = f:seek("end")
    f:close()
    if size and size > M.MAX_BYTES then maybe_rotate(path) end
end

--- Create a new logger.
--- @param opts? { path?: string, level?: number, capture?: boolean }
--- @return loomworks.Logger
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Logger)
    self._path = opts.path
    self._level = opts.level or M.DEBUG
    self._entries = {}
    self._capture = opts.capture or false
    return self
end

--- Set the log file path. Called when workspace root is known.
--- Appends a start marker (never truncates — see the module header), rotating
--- an oversized file first.
--- @param root string workspace root path
function Logger:set_root(root)
    self._path = root .. "/.nvim/loomworks.log"
    maybe_rotate(self._path)
    append(self._path, "-- loomworks log started " .. os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\n")
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

    append(self._path, entry .. "\n")
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
