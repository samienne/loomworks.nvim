--- loomworks/file_tracker.lua — Stat-based file watcher using uv.fs_poll.
--- Watches file paths and delivers raw content via callback on change.
--- Uses fs_poll (not fs_event) because atomic writes via rename change inodes,
--- which breaks fs_event on Linux/macOS. fs_poll checks paths via stat.

--- @class loomworks.FileTracker
--- @field _watches table<string, uv_fs_poll_t>
--- @field _content table<string, string|nil> last known raw content per path
--- @field _callback fun(path: string, content: string|nil)
--- @field _interval number poll interval in milliseconds
--- @field _read_file fun(path: string): string|nil, string|nil
--- @field _schedule fun(fn: function)
local FileTracker = {}
FileTracker.__index = FileTracker

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

--- @class loomworks.FileTrackerOpts
--- @field callback fun(path: string, content: string|nil) called on file change
--- @field interval? number poll interval in ms (default 2000)
--- @field read_file? fun(path: string): string|nil, string|nil injectable for testing
--- @field schedule? fun(fn: function) injectable for testing

--- Create a new FileTracker.
--- @param opts loomworks.FileTrackerOpts
--- @return loomworks.FileTracker
function FileTracker.new(opts)
    local self = setmetatable({}, FileTracker)
    self._watches = {}
    self._content = {}
    self._callback = opts.callback
    self._interval = opts.interval or 2000
    self._read_file = opts.read_file or io_mod.read_file
    self._schedule = opts.schedule or vim.schedule
    return self
end

--- Read current content and start polling a file.
--- If the file doesn't exist, content is stored as nil.
--- @param path string absolute file path
function FileTracker:watch(path)
    if self._watches[path] then return end

    -- Seed with current content
    self._content[path] = self._read_file(path)

    local poll = uv.new_fs_poll()
    if not poll then return end

    self._watches[path] = poll

    poll:start(path, self._interval, function(err, prev, curr)
        -- fs_poll callback runs in the libuv thread; schedule to main thread
        self._schedule(function()
            local new_content = self._read_file(path)
            local old_content = self._content[path]

            -- Only fire callback if content actually changed
            if new_content ~= old_content then
                self._content[path] = new_content
                self._callback(path, new_content)
            end
        end)
    end)
end

--- Stop watching a file.
--- @param path string
function FileTracker:unwatch(path)
    local poll = self._watches[path]
    if poll then
        poll:stop()
        if not poll:is_closing() then
            poll:close()
        end
        self._watches[path] = nil
        self._content[path] = nil
    end
end

--- Stop all watches.
function FileTracker:stop()
    for path in pairs(self._watches) do
        self:unwatch(path)
    end
end

--- Get last known raw content for a path (no I/O).
--- @param path string
--- @return string|nil
function FileTracker:content(path)
    return self._content[path]
end

--- Update cached content after a self-write.
--- Prevents the next poll from detecting our own write as an external change.
--- @param path string
function FileTracker:mark_written(path)
    if self._watches[path] then
        self._content[path] = self._read_file(path)
    end
end

return FileTracker
