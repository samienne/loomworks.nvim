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
--- @field _paused boolean while true, `sync` (and so every poll) delivers nothing
--- @field _manual boolean no sync of its own: changes are delivered only by `sync()`
--- @field _signal? fun() a manual tracker's watch: called (scheduled) when a watched file's stat changes
--- @field _hold? fun(path: string, content: string|nil): boolean screens each change before delivery
--- @field _held table<string, true> paths whose last change `_hold` held back
--- @field _saves boolean a file missing beside its staged copy is a save in progress (see `_read`)
--- @field _staged fun(path: string): boolean whether a staged copy of `path` exists
--- @field _recheck_timer? uv_timer_t the pending re-check of a save in progress
local FileTracker = {}
FileTracker.__index = FileTracker

local uv = vim.uv or vim.loop
local io_mod = require("loomworks.io")

--- How soon a file missing beside its staged copy (a save between its two
--- renames, spec §19.4) is checked again, in ms.
FileTracker.SAVE_RECHECK_MS = 500

--- Whether a save of `path` is staged: `<path>.tmp` (io.write_file_atomic)
--- or a transaction's `<path>.txn-<id>` (loomworks.txn `staged_path`) exists.
--- The transaction name is matched by its prefix, `staged_path(path, "")`,
--- followed by a hex id, as txn recovery's `strays` matches it (the id is
--- only format-checked, not used).
--- @param path string
--- @return boolean
function FileTracker.staged_copy(path)
    if uv.fs_stat(path .. ".tmp") then return true end
    local prefix = require("loomworks.txn").staged_path(path, "")
    local dir, pbase = prefix:match("^(.*)[/\\]([^/\\]+)$")
    if not dir then dir, pbase = ".", prefix end
    -- (Windows names are case-insensitive, and watched paths may be lowercased.)
    local fold = vim.fn.has("win32") == 1 and string.lower or function(s) return s end
    pbase = fold(pbase)
    local req = uv.fs_scandir(dir == "" and "/" or dir)
    while req do
        local name = uv.fs_scandir_next(req)
        if not name then break end
        if #name > #pbase and fold(name:sub(1, #pbase)) == pbase
            and name:sub(#pbase + 1):match("^%x+$") then
            return true
        end
    end
    return false
end

--- @class loomworks.FileTrackerOpts
--- @field callback fun(path: string, content: string|nil) called on file change
--- @field interval? number poll interval in ms (default 2000)
--- @field read_file? fun(path: string): string|nil, string|nil injectable for testing
--- @field schedule? fun(fn: function) injectable for testing
--- @field batch? fun(deliver: fun()) wraps the delivery of one sync's changes:
---   called once per sync that found changes; it must call `deliver()`, which
---   fires `callback` for each changed path. Lets the owner act once after all
---   of them are applied (spec §2.7).
--- @field manual? boolean no sync of its own: changes are delivered only by
---   `sync()` (the workspace daemon, which applies external changes itself,
---   spec §19.13 "Freshness of views", §19.15)
--- @field signal? fun() with `manual`: watch the content-watched files anyway
---   and call this (scheduled) when one's stat changes, so the owner can sync
---   (the daemon's watch, §19.13); also after the grace of a save in progress
--- @field hold? fun(path: string, content: string|nil): boolean screens every
---   change a sync read (and a path it held before, until it passes): true
---   holds it back, and the sync then delivers nothing (every last known
---   content kept), so the next sync retries (the daemon: a file that cannot
---   be parsed, §19.13)
--- @field saves? boolean a file read missing while its staged copy exists
---   (`<file>.tmp`, or a transaction's `<file>.txn-<id>`) is a save in
---   progress (spec §19.4): it reads as its last known content, and a re-check
---   is signalled after `SAVE_RECHECK_MS`; with no staged copy it reads as
---   missing at once (a deletion)
--- @field staged? fun(path: string): boolean injectable for testing (default
---   `FileTracker.staged_copy`)

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
    self._signal = opts.signal
    self._hold = opts.hold
    self._held = {}
    self._saves = opts.saves or false
    self._staged = opts.staged or FileTracker.staged_copy
    self._batch = opts.batch
    self._order = {}
    self._paused = false
    return self
end

--- Read current content and start polling a file.
--- If the file doesn't exist, content is stored as nil.
--- @param path string absolute file path
--- @param opts? { passive?: boolean } `passive`: a manual tracker does not
---   watch it for its `signal` (its changes are delivered by `sync()` only)
function FileTracker:watch(path, opts)
    if self._watches[path] ~= nil then return end

    -- Seed with current content
    self._content[path] = self:_read(path)
    self._order[#self._order + 1] = path
    if self._manual and (not self._signal or (opts and opts.passive)) then
        self._watches[path] = false
        return
    end

    local poll = uv.new_fs_poll()
    if not poll then
        if self._manual then self._watches[path] = false end
        return
    end

    self._watches[path] = poll

    poll:start(path, self._interval, function(err, prev, curr)
        -- fs_poll callback runs in the libuv thread; schedule to main thread
        -- A change to one file delivers every pending change together (two
        -- files written back to back are applied as one, see `sync`). A
        -- manual tracker tells its owner, which syncs when it may.
        self._schedule(function()
            if self._watches[path] == nil then return end
            -- (`stop_signals` may have run since this was queued.)
            if self._manual then
                if self._signal then self._signal() end
                return
            end
            self:sync()
        end)
    end)
end

--- Read a watched file. With `saves`, a file missing while its staged copy
--- exists (`<file>.tmp`, or a transaction's `<file>.txn-<id>`) is a save in
--- progress (spec §19.4: the target is absent between the save's two
--- renames): it reads as its last known content, and a re-check is
--- scheduled (again on every such read, while the staged copy remains). A
--- missing file with no staged copy reads as missing at once, as a deleted
--- file does. (A save always leaves a staged copy until its last rename; a
--- deletion leaves none. The `.bak` says nothing: a save of identical bytes
--- leaves it equal to the content last applied.) A save's last rename can
--- land between the missing read and the staged check, leaving no staged
--- copy: the target is then read once more before it counts as missing.
--- @param path string
--- @return string|nil
function FileTracker:_read(path)
    local content = self._read_file(path)
    if content ~= nil or not self._saves then return content end
    if not self._staged(path) then return self._read_file(path) end
    self:_recheck()
    return self._content[path]
end

--- Signal the owner again `SAVE_RECHECK_MS` after a save in progress was seen
--- (a polling tracker syncs itself then).
function FileTracker:_recheck()
    if self._recheck_timer or (self._manual and not self._signal) then return end
    local timer = uv.new_timer()
    if not timer then return end
    self._recheck_timer = timer
    timer:start(FileTracker.SAVE_RECHECK_MS, 0, function()
        self._schedule(function()
            if self._recheck_timer == timer then
                self._recheck_timer = nil
                if not timer:is_closing() then timer:close() end
            end
            if next(self._watches) == nil or self._paused then return end
            if self._manual then
                if self._signal then self._signal() end
                return
            end
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
--- (`mark_written`), is skipped. When a callback throws, the change it was
--- applying and every later one go back to undelivered (their last known
--- content is restored), so the next sync delivers them again; the error is
--- then rethrown with its traceback.
---
--- `opts.accept(path, content)`: when it refuses any change, the sync delivers
--- nothing (every last known content kept), so a later sync delivers that
--- change together with the ones read with it, never half of them — the
--- workspace daemon's view check leaves what would reload the workspace or
--- rescan tools, and what changed with it, to the next request's sync
--- (spec §19.13 "Freshness of views").
--- @param opts? { accept?: fun(path: string, content: string|nil): boolean }
function FileTracker:sync(opts)
    if self._paused then return end
    local accept = opts and opts.accept
    local changed = {}
    for _, path in ipairs(vim.list_extend({}, self._order)) do
        if self._watches[path] ~= nil then
            local new_content = self:_read(path)
            if new_content ~= self._content[path] then
                changed[#changed + 1] = { path = path, content = new_content, prev = self._content[path] }
            end
        end
    end
    if self._hold then
        -- Every change is screened, and a path held before that is back to
        -- its last known content (its hold is released then); one change
        -- held holds the whole sync.
        local held, seen = false, {}
        for _, c in ipairs(changed) do
            seen[c.path] = true
            if self._hold(c.path, c.content) then
                self._held[c.path] = true
                held = true
            else
                self._held[c.path] = nil
            end
        end
        for _, path in ipairs(vim.list_extend({}, self._order)) do
            if self._held[path] and not seen[path] then
                self._held[path] = nil
                if self._watches[path] ~= nil and self._hold(path, self._content[path]) then
                    self._held[path] = true
                end
            end
        end
        if held then return end
    end
    if #changed == 0 then return end
    if accept then
        for _, c in ipairs(changed) do
            if not accept(c.path, c.content) then return end
        end
    end
    for _, c in ipairs(changed) do self._content[c.path] = c.content end
    local current = 1
    -- Runs at the error point: un-read the change being applied and the ones
    -- after it. One a callback already reconciled (`mark_written`) or stopped
    -- watching keeps its new state.
    local function on_error(err)
        for i = current, #changed do
            local c = changed[i]
            if self._watches[c.path] ~= nil and self._content[c.path] == c.content then
                self._content[c.path] = c.prev
            end
        end
        if type(err) == "string" and not err:find("stack traceback:", 1, true) then
            return debug.traceback(err, 2)
        end
        return err
    end
    local function deliver()
        local ok, err = xpcall(function()
            for i, c in ipairs(changed) do
                current = i
                -- Skipped once an earlier callback wrote or reconciled the file
                -- itself (`mark_written` moved its content on): delivering the
                -- bytes read above would replay an outdated version.
                if self._watches[c.path] ~= nil and self._content[c.path] == c.content then
                    self._callback(c.path, c.content)
                end
            end
        end, on_error)
        if not ok then error(err, 0) end
    end
    if self._batch then self._batch(deliver) else deliver() end
end

--- Hold every delivery: a paused tracker reads and delivers nothing, so the
--- changes stay pending (`content()` keeps the last delivered bytes) until
--- `resume`. The core pauses a workspace that a reload is replacing: the new
--- load reads the files itself, and the old one must not apply (and save) a
--- change under it meanwhile.
function FileTracker:pause()
    self._paused = true
end

--- Deliver again. A polling tracker schedules a sync: the poll that saw a
--- change while paused delivered nothing, and `fs_poll` fires again only on
--- another stat change, so without it the change could stay pending
--- indefinitely. A manual tracker delivers on its next `sync()` call.
function FileTracker:resume()
    if not self._paused then return end
    self._paused = false
    if self._manual then
        -- A watching manual tracker tells its owner: a change seen while
        -- paused is pending.
        if self._signal then
            self._schedule(function()
                if self._signal and not self._paused and next(self._watches) ~= nil then self._signal() end
            end)
        end
        return
    end
    self._schedule(function()
        -- Paused again, or stopped, before this ran: nothing to deliver now.
        if self._paused or next(self._watches) == nil then return end
        self:sync()
    end)
end

--- Stop all watches.
function FileTracker:stop()
    for path in pairs(self._watches) do
        self:unwatch(path)
    end
    local timer = self._recheck_timer
    self._recheck_timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

--- Stop a manual tracker's watch (its `signal`): the polls and a pending
--- re-check end, and `sync()` still delivers. Nothing for a polling tracker.
function FileTracker:stop_signals()
    if not self._manual then return end
    self._signal = nil
    for path, poll in pairs(self._watches) do
        if poll then
            poll:stop()
            if not poll:is_closing() then poll:close() end
            self._watches[path] = false
        end
    end
    local timer = self._recheck_timer
    self._recheck_timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
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
