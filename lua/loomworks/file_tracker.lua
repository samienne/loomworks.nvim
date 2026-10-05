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
--- @field _batch? fun(deliver: fun())
local FileTracker = {}
FileTracker.__index = FileTracker

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

--- @class loomworks.FileTrackerOpts
--- @field callback fun(path: string, content: string|nil) called on file change
--- @field interval? number poll interval in ms (default 2000)
--- @field read_file? fun(path: string): string|nil, string|nil injectable for testing
--- @field schedule? fun(fn: function) injectable for testing
--- @field batch? fun(deliver: fun()) wraps the delivery of one sync's changes:
---   called once per sync that found changes; it must call `deliver()`, which
---   fires `callback` for each changed path. Lets the owner act once after all
---   of them are applied (spec §2.7).
--- @field manual? boolean no polling: changes are delivered only by `sync()`
---   (the workspace daemon, which applies external changes right before each
---   operation, spec §19.15)

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
    self._manual = opts.manual or false
    self._batch = opts.batch
    self._order = {}
    return self
end

--- Read current content and start polling a file.
--- If the file doesn't exist, content is stored as nil.
--- @param path string absolute file path
function FileTracker:watch(path)
    if self._watches[path] ~= nil then return end

    -- Seed with current content
    self._content[path] = self._read_file(path)
    self._order[#self._order + 1] = path
    if self._manual then
        self._watches[path] = false
        return
    end

    local poll = uv.new_fs_poll()
    if not poll then return end

    self._watches[path] = poll

    poll:start(path, self._interval, function(err, prev, curr)
        -- fs_poll callback runs in the libuv thread; schedule to main thread
        -- A change to one file delivers every pending change together (two
        -- files written back to back are applied as one, see `sync`).
        self._schedule(function()
            if self._watches[path] == nil then return end
            self:sync()
        end)
    end)
end

--- Watch a path (typically a directory) for stat changes and fire a
--- per-path signal callback — no content read or comparison. `fs_poll`
--- invokes the handler only when the path's stat actually changes (mtime,
--- size, …), so this is suitable for a directory whose entries change (e.g.
--- the cmake file-api reply dir). Idempotent: a second call for the same
--- path is a no-op. Cleaned up by `unwatch`/`stop` like any other watch.
--- @param path string absolute path
--- @param on_signal fun(path: string) called on each detected change
function FileTracker:watch_signal(path, on_signal)
    if self._watches[path] ~= nil then return end
    -- A manual tracker never polls (no signal watches either).
    if self._manual then return end

    local poll = uv.new_fs_poll()
    if not poll then return end

    self._watches[path] = poll

    poll:start(path, self._interval, function(err)
        if err then return end
        self._schedule(function()
            pcall(on_signal, path)
        end)
    end)
end

--- Stop watching a file.
--- @param path string
function FileTracker:unwatch(path)
    local poll = self._watches[path]
    if poll ~= nil then
        if poll then
            poll:stop()
            if not poll:is_closing() then
                poll:close()
            end
        end
        self._watches[path] = nil
        self._content[path] = nil
    end
end

--- Deliver every pending change NOW, synchronously (a poll does the same):
--- every content-watched path is re-read first, and only then does the
--- callback fire, in watch order, for each one whose content differs from the
--- last known. So while one change is applied, `content()` of every other
--- watched file is already its current disk content: a change that reads a
--- sibling file (loomworks.json reassembles with the working copy) sees the
--- sibling's new bytes, never a stale mix (spec §2.7). The whole delivery runs
--- inside the `batch` option's wrapper when one is set. A path a callback
--- stopped watching (a refused file reloads the workspace, spec §17.4, which
--- stops this tracker), or one an earlier callback already wrote or reconciled
--- (`mark_written`), is skipped.
function FileTracker:sync()
    local changed = {}
    for _, path in ipairs(vim.list_extend({}, self._order)) do
        if self._watches[path] ~= nil then
            local new_content = self._read_file(path)
            if new_content ~= self._content[path] then
                self._content[path] = new_content
                changed[#changed + 1] = { path = path, content = new_content }
            end
        end
    end
    if #changed == 0 then return end
    local function deliver()
        for _, c in ipairs(changed) do
            -- Skipped once an earlier callback wrote or reconciled the file
            -- itself (`mark_written` moved its content on): delivering the
            -- bytes read above would replay an outdated version.
            if self._watches[c.path] ~= nil and self._content[c.path] == c.content then
                self._callback(c.path, c.content)
            end
        end
    end
    if self._batch then self._batch(deliver) else deliver() end
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
--- Pass the bytes actually written: re-reading the file instead could record
--- another process's write that landed right after ours as our own, and that
--- change would then never be delivered (spec §2.7). Without `content` the
--- file is read back (legacy callers).
--- @param path string
--- @param content? string|false the bytes now on disk (false/nil: read back)
function FileTracker:mark_written(path, content)
    if self._watches[path] ~= nil then
        if content == nil or content == false then
            content = self._read_file(path)
        end
        self._content[path] = content
    end
end

return FileTracker
