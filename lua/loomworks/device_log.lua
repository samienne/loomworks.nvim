--- loomworks/device_log.lua — generic on-device streaming log view.
---
--- A reusable log view that lets a module supply its own line parser
--- and pid/process prefilter. Device connectors typically expose
--- on-device filter flags that are unreliable across OS versions, so
--- we take the same approach as device-log UIs in vendor IDEs:
--- receive the raw stream, parse each line into a structured record,
--- and filter client-side. Two tiers of filtering keep memory bounded
--- and the view interactive:
---
---   * session prefilter  applied at receive; dropped records are
---                        gone. Default matches pid OR proc-contains
---                        -bundle, so we catch both the app's main
---                        process and any runtime helpers that log
---                        under different PIDs but for the same app.
---                        Immutable for the stream lifetime.
---
---   * soft filter        applied at render; fully interactive.
---                        Changing it re-renders from the ring
---                        buffer, no history lost.
---
--- The stream itself runs under overseer (task visible in the task
--- list, killable the usual way) via `loomworks.overseer.run_streaming_task`
--- which skips the default output-to-buffer component and forwards
--- lines into this module.

local M = {}

-- ---------------------------------------------------------------------------
-- Parser (host-neutral: loomworks.device_log_records, which the workspace
-- daemon's `Launch/1.device_log` parses with too)
-- ---------------------------------------------------------------------------

local records = require("loomworks.device_log_records")

--- Expose the line sanitiser (device_log_records.sanitize_line).
M.sanitize_line = records.sanitize_line

--- Parse a single device log line (device_log_records.parse_line).
M.parse_line = records.parse_line

-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

--- Level ordering — records are "at or above" the requested minimum.
local LEVEL_RANK = { V = 0, D = 1, I = 2, W = 3, E = 4, F = 5 }

--- Apply a soft filter. AND semantics: every non-nil filter field must
--- match. Filter fields are all optional.
---
--- The optional `rendered` argument anchors `filter.regex` to the
--- full rendered line (what the user sees). Callers that haven't
--- rendered yet can omit it — regex then falls back to `record.msg`
--- on parsed records (keeps the old narrower behaviour for
--- non-view callers / tests).
---
--- @param filter table { pid?, proc?, tag?, level?, regex? }
--- @param record table
--- @param rendered? string  rendered form of `record` — regex target
--- @return boolean
function M.match_filter(filter, record, rendered)
    if not record then return false end
    if record.header then
        -- Session banners are loomworks-generated; always show.
        return true
    end
    if record.raw then
        -- Raw (unparseable) records stay visible by default so
        -- parser/buffering problems are immediately obvious. Only
        -- an active regex filter may hide them.
        if filter.regex then
            local text = rendered or record.raw
            return text:match(filter.regex) ~= nil
        end
        return true
    end

    if filter.pid and record.pid ~= filter.pid then return false end
    if filter.proc then
        if not record.proc or not record.proc:find(filter.proc, 1, true) then
            return false
        end
    end
    if filter.tag then
        if not record.tag or not record.tag:find(filter.tag, 1, true) then
            return false
        end
    end
    if filter.level then
        local r = LEVEL_RANK[record.level] or 0
        local m = LEVEL_RANK[filter.level] or 0
        if r < m then return false end
    end
    if filter.regex then
        local text = rendered or record.msg or ""
        if not text:match(filter.regex) then return false end
    end
    return true
end

--- Build the session prefilter (device_log_records.make_prefilter).
M.make_prefilter = records.make_prefilter

-- ---------------------------------------------------------------------------
-- Rendering (pure — shared by view appends, re-renders, and regex
-- filtering so the "what you see is what you grep" contract holds
-- regardless of which caller produced the rendered string).
-- ---------------------------------------------------------------------------

--- Reconstruct a record verbosely: matches the raw device log line
--- format 1:1 so it can be diffed against the source stream.
---   MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: msg
--- @param record table
--- @return string
local function render_verbose(record)
    local pid = record.pid or 0
    local tid = record.tid or pid
    local locator
    if record.proc and record.proc ~= "" then
        locator = string.format("%s/%s/%s",
            record.domain or "?", record.proc, record.tag or "?")
    else
        locator = string.format("%s/%s",
            record.domain or "?", record.tag or "?")
    end
    return string.format("%s %5d %5d %s %s: %s",
        record.time or "??-?? ??:??:??.???",
        pid, tid, record.level or "?", locator, record.msg or "")
end

--- Compact layout: drop the date, drop tid, drop the domain — the
--- three fields that are either constant within a session or
--- duplicate adjacent ones in practice. What's left is what you
--- actually read at a glance.
---   HH:MM:SS.mmm PID LEVEL PROC/TAG: msg
---   HH:MM:SS.mmm PID LEVEL TAG: msg       (no proc)
--- @param record table
--- @return string
local function render_compact(record)
    local t = record.time or ""
    local sp = t:find(" ")
    local time = sp and t:sub(sp + 1) or t
    local locator
    if record.proc and record.proc ~= "" then
        locator = string.format("%s/%s", record.proc, record.tag or "?")
    else
        locator = record.tag or "?"
    end
    return string.format("%s %d %s %s: %s",
        time, record.pid or 0, record.level or "?", locator, record.msg or "")
end

--- Render a record to a display string.
---
--- Module-level (rather than a LogView method) so match_filter and
--- programmatic callers — not just the view — can compute the same
--- rendered form. That's the anchor for full-line regex filtering:
--- the string the user sees is the same one the regex matches.
---
--- Three record shapes:
---   * header  — session banner injected by `M.start`
---   * raw     — unparseable line; marked `[UNPARSED]`
---   * parsed  — real device-log record, laid out per `layout`
---
--- @param record table
--- @param layout? "compact"|"verbose" (default "compact")
--- @return string
function M.render(record, layout)
    if not record then return "" end
    if record.header then return record.header end
    if record.raw then return "[UNPARSED] " .. record.raw end
    if layout == "verbose" then
        return render_verbose(record)
    end
    return render_compact(record)
end

-- ---------------------------------------------------------------------------
-- LogView (one buffer + one bottom split)
-- ---------------------------------------------------------------------------

local LogView = {}
LogView.__index = LogView

--- Max records kept in the ring buffer. ~1 MB of memory at typical
--- line lengths; chosen to be bounded but large enough to span a
--- typical debugging session.
local MAX_RECORDS = 5000

--- How close to the bottom the cursor must be for new lines to
--- auto-follow. 3 gives the user some room to scroll up a few lines
--- to inspect something without immediately jumping back to the end.
local AUTOSCROLL_SLACK = 3

--- Flush cadence for batched buffer writes (ms). At high input rates
--- each buffer write fires TextChanged + CursorMoved (and every
--- plugin subscribed to them) globally, so the render rate must be
--- capped independent of input rate. 250 ms (~4 flushes/sec) still
--- feels continuous to the eye and leaves plenty of headroom for
--- other event-loop work.
local FLUSH_INTERVAL_MS = 250

--- Max records processed per flush. Prevents a single tick from
--- blocking the main thread for too long when a burst arrives — the
--- remainder flows into the next flush. Sized to keep a flush under
--- a couple of ms on commodity hardware.
local MAX_LINES_PER_FLUSH = 200

--- Hard cap on the pending queue. When the stream produces records
--- faster than we can flush (heavy app logging, slow nvim), oldest
--- pending records start dropping at the append point — bounds
--- memory and stops the queue from growing unboundedly if we're
--- persistently behind. Dropped records are still counted and
--- reported in the view (a gap line) so the user knows there's a gap.
local MAX_PENDING = 2000

--- Create the singleton view. Lazy — nothing materialises until
--- something calls `show()` or `append_record()`.
--- @return table LogView
function LogView.new()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "loomworks-device-log"
    pcall(vim.api.nvim_buf_set_name, buf, "loomworks://device-log")

    local self = setmetatable({
        _buf = buf,
        _win = nil,
        _records = {},
        _filter = {},
        _layout = "compact",   -- "compact" | "verbose"; cV toggles
        _paused = false,
        _dropped = 0,
        _ns = vim.api.nvim_create_namespace("loomworks_device_log"),
        -- Batching state
        _pending = {},         -- records awaiting render
        _flush_scheduled = false,
        _needs_full_rerender = false,
        _has_content = false,  -- tracks "first-line placeholder" state
    }, LogView)
    self:_setup_keymaps()
    return self
end

--- Show in a bottom split (focus returns to the previous window so
--- the log view doesn't steal the cursor).
--- @param opts? { height?: number }
function LogView:show(opts)
    opts = opts or {}
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        vim.api.nvim_set_current_win(self._win)
        return
    end

    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. (opts.height or 15) .. "split")
    self._win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self._win, self._buf)

    vim.wo[self._win].number = false
    vim.wo[self._win].relativenumber = false
    vim.wo[self._win].signcolumn = "no"
    vim.wo[self._win].wrap = false
    vim.wo[self._win].winfixheight = true

    -- Its window closed any way (`q`, `:q`, `<C-w>c`): `on_close`, which
    -- ends a stream the workspace daemon carries (M.start_remote).
    local win = self._win
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(win), once = true,
        callback = function()
            if self._win == win then self._win = nil end
            if self.on_close then self.on_close() end
        end,
    })

    if vim.api.nvim_win_is_valid(prev) then
        vim.api.nvim_set_current_win(prev)
    end

    -- On first show, jump to the end so auto-follow is "on" right away.
    self:_scroll_to_end(true)
end

function LogView:hide()
    local was = self._win
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        vim.api.nvim_win_close(self._win, true)
    end
    self._win = nil
    -- (WinClosed calls it too; `on_close` is idempotent.)
    if was and self.on_close then self.on_close() end
end

function LogView:toggle()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        self:hide()
    else
        self:show()
    end
end

function LogView:is_visible()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

--- Push a parsed (or raw-fallback) record.
---
--- Ring-buffer push is immediate (cheap Lua list op). Actual buffer
--- rendering is deferred into a batched flush so we don't hammer
--- nvim APIs on every incoming line.
---
--- Backpressure: if the pending queue is already at `MAX_PENDING`,
--- drop the oldest pending record (not the newest — we want the
--- freshest tail visible). Keeps memory bounded when we're
--- persistently behind and stops the queue from being an unbounded
--- sink for bursty traffic.
--- @param record table
function LogView:append_record(record)
    self._records[#self._records + 1] = record

    if #self._records > MAX_RECORDS then
        local drop = #self._records - MAX_RECORDS
        local kept = {}
        for i = drop + 1, #self._records do
            kept[#kept + 1] = self._records[i]
        end
        self._records = kept
        self._dropped = self._dropped + drop
        -- Request a full rerender on next flush — cheaper to do one
        -- rebuild per overflow than to try and trim the visible
        -- buffer in sync with the ring in-place.
        self._needs_full_rerender = true
    end

    if #self._pending >= MAX_PENDING then
        -- Queue saturated: drop the oldest pending record. O(N)
        -- table.remove is acceptable at this frequency — we only
        -- hit this branch when we're already behind, and one
        -- element shifts aren't the bottleneck in that regime.
        table.remove(self._pending, 1)
        self._pending_dropped = (self._pending_dropped or 0) + 1
    end

    self._pending[#self._pending + 1] = record
    self:_schedule_flush()
end

--- Queue a flush if one isn't already pending. `vim.defer_fn` owns
--- the timer lifecycle; a single dangling flush after the view is
--- disposed is harmless (it finds empty pending + no buffer and
--- returns).
function LogView:_schedule_flush()
    if self._flush_scheduled then return end
    self._flush_scheduled = true
    local self_ref = self
    vim.defer_fn(function()
        self_ref._flush_scheduled = false
        self_ref:_flush()
    end, FLUSH_INTERVAL_MS)
end

--- Process the pending queue: either a full rerender (if we
--- overflowed the ring), or a batch append of all pending records
--- that pass the soft filter.
---
--- We do ONE `nvim_buf_set_lines` call with the whole batch, ONE
--- cursor move for auto-scroll, and extmarks grouped under a single
--- modifiable window. That keeps nvim's event loop cost proportional
--- to the flush rate (~12/sec) instead of the line rate (could be
--- hundreds/sec during heavy app activity).
function LogView:_flush()
    if not vim.api.nvim_buf_is_valid(self._buf) then
        self._pending = {}
        return
    end

    if self._needs_full_rerender then
        self._needs_full_rerender = false
        self._pending = {}  -- the full rerender replays from _records
        self:_rerender()
        return
    end

    if self._paused or #self._pending == 0 then
        return
    end

    -- Take at most MAX_LINES_PER_FLUSH records so the flush stays
    -- bounded in time even when the queue is deep. Leftovers flow
    -- into the next tick.
    local take = math.min(#self._pending, MAX_LINES_PER_FLUSH)
    local batch = {}
    local remainder = {}
    for i = 1, take do batch[i] = self._pending[i] end
    for i = take + 1, #self._pending do
        remainder[#remainder + 1] = self._pending[i]
    end
    self._pending = remainder

    -- If we dropped pending records to stay under the cap, tell the
    -- user in the view itself — silent drops would hide a real
    -- problem. One gap line per flush regardless of drop count, ahead
    -- of the records that follow the gap. It is NOT kept in the ring:
    -- the dropped records are still there, so a re-render shows them all
    -- in order and the gap no longer applies.
    if self._pending_dropped and self._pending_dropped > 0 then
        local gap = { header = string.format("── %d lines dropped (the view fell behind the stream) ──",
            self._pending_dropped) }
        self._pending_dropped = 0
        table.insert(batch, 1, gap)
    end

    local lines = {}
    local hl_records = {}
    for _, rec in ipairs(batch) do
        -- Render first, then filter — so a regex-based soft filter
        -- can match the full rendered line rather than just `msg`.
        local rendered = M.render(rec, self._layout)
        if M.match_filter(self._filter, rec, rendered) then
            lines[#lines + 1] = rendered
            hl_records[#hl_records + 1] = rec
        end
    end


    -- Schedule the next flush early when there's still a remainder
    -- so we work down the queue promptly instead of waiting a full
    -- interval.
    if #self._pending > 0 then
        self:_schedule_flush()
    end

    if #lines == 0 then return end

    vim.bo[self._buf].modifiable = true
    local start_line
    if not self._has_content then
        -- Fresh buffer has one placeholder blank line; replace it.
        start_line = 0
        vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, lines)
        self._has_content = true
    else
        start_line = vim.api.nvim_buf_line_count(self._buf)
        vim.api.nvim_buf_set_lines(self._buf, start_line, start_line, false, lines)
    end
    for i, rec in ipairs(hl_records) do
        self:_highlight(rec, start_line + i - 1)
    end
    vim.bo[self._buf].modifiable = false

    self:_maybe_scroll()
end

local LEVEL_HL = {
    F = "ErrorMsg",
    E = "ErrorMsg",
    W = "WarningMsg",
    I = nil,
    D = "Comment",
    V = "Comment",
}

--- Overlay highlight on a line. Three colour channels:
---   * header    → Title (stands out at the top)
---   * raw       → ErrorMsg (any unparsed line should be visible —
---                 it's a parser/buffering problem, not a normal log)
---   * parsed    → per-level (E/F red, W yellow, D/V dim, I default)
function LogView:_highlight(record, line_idx)
    local hl
    if record.header then
        hl = "Title"
    elseif record.raw then
        hl = "ErrorMsg"
    else
        hl = LEVEL_HL[record.level]
    end
    if not hl then return end
    vim.api.nvim_buf_set_extmark(self._buf, self._ns, line_idx, 0, {
        end_row = line_idx + 1,
        end_col = 0,
        hl_eol = true,
        hl_group = hl,
        priority = 100,
    })
end

--- Auto-follow only when the cursor is near the bottom. Lets the
--- user scroll up to inspect something without being yanked back.
function LogView:_maybe_scroll()
    if not self:is_visible() then return end
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, self._win)
    if not ok then return end
    local n = vim.api.nvim_buf_line_count(self._buf)
    if cur[1] >= n - AUTOSCROLL_SLACK then
        self:_scroll_to_end(false)
    end
end

function LogView:_scroll_to_end(force)
    if not self:is_visible() then return end
    local n = vim.api.nvim_buf_line_count(self._buf)
    if n == 0 then return end
    if force or true then
        pcall(vim.api.nvim_win_set_cursor, self._win, { n, 0 })
    end
end

function LogView:set_filter(filter)
    self._filter = filter or {}
    self:_rerender()
end

function LogView:clear()
    self._records = {}
    self._pending = {}
    self._dropped = 0
    self._pending_dropped = 0
    self._has_content = false
    self._needs_full_rerender = false
    vim.bo[self._buf].modifiable = true
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(self._buf, self._ns, 0, -1)
    vim.bo[self._buf].modifiable = false
end

--- Add a synthetic header record and flush immediately so it lands
--- at the top of the view without waiting for the next batched
--- flush. Headers happen once per session, so this one-off sync
--- flush has no perf impact.
--- @param text string
function LogView:_inject_header(text)
    local rec = { header = "── " .. text .. " ──" }
    self._records[#self._records + 1] = rec
    self._pending[#self._pending + 1] = rec
    self:_flush()
end

function LogView:set_paused(paused)
    self._paused = paused
end

function LogView:is_paused()
    return self._paused
end

function LogView:_rerender()
    vim.bo[self._buf].modifiable = true
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(self._buf, self._ns, 0, -1)

    local lines = {}
    local hl_records = {}
    for _, rec in ipairs(self._records) do
        local rendered = M.render(rec, self._layout)
        if M.match_filter(self._filter, rec, rendered) then
            lines[#lines + 1] = rendered
            hl_records[#hl_records + 1] = rec
        end
    end
    if #lines == 0 then
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
        self._has_content = false
    else
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)
        for i, rec in ipairs(hl_records) do
            self:_highlight(rec, i - 1)
        end
        self._has_content = true
    end

    vim.bo[self._buf].modifiable = false
    self:_scroll_to_end(true)
end

--- Cycle min-level: off → I → W → E → off.
function LogView:_cycle_level()
    local order = { [false] = "I", I = "W", W = "E", E = false }
    local cur = self._filter.level or false
    local nxt = order[cur]
    self._filter.level = nxt or nil
    self:_rerender()
    vim.notify("device log: min level = " .. (nxt or "off"))
end

--- Keymaps shown by `?`. Keep this list in sync with `_setup_keymaps`
--- — it's rendered verbatim so the help overlay always matches the
--- actually-bound keys.
local HELP_ROWS = {
    { "?",  "show this help" },
    { "q",  "hide log view (stream keeps running)" },
    { "cc", "clear buffer + ring" },
    { "p",  "pause / resume render" },
    { "cl", "cycle min level (off → I → W → E → off)" },
    { "cf", "edit regex filter (matches the full rendered line)" },
    { "cV", "toggle compact / verbose layout" },
}

--- Close the currently-open help overlay, if any.
function LogView:_close_help()
    if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
        pcall(vim.api.nvim_win_close, self._help_win, true)
    end
    self._help_win = nil
    if self._help_group then
        pcall(vim.api.nvim_del_augroup_by_id, self._help_group)
    end
    self._help_group = nil
end

--- Show a small floating help overlay listing the buffer-local
--- keymaps. Toggles: pressing `?` again closes it. Also closes when
--- the user leaves the log window. Deliberately does NOT listen for
--- CursorMoved — the buffer's auto-scroll on new lines fires that
--- event, which would snap the overlay shut every few milliseconds
--- on a busy device.
function LogView:_show_help()
    -- Toggle semantics.
    if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
        self:_close_help()
        return
    end

    local lines = { "loomworks device log" }
    local key_col = 4
    for _, row in ipairs(HELP_ROWS) do
        key_col = math.max(key_col, #row[1])
    end
    for _, row in ipairs(HELP_ROWS) do
        lines[#lines + 1] = string.format("  %-" .. key_col .. "s  %s",
            row[1], row[2])
    end

    local width = 0
    for _, l in ipairs(lines) do
        if #l > width then width = #l end
    end
    width = width + 2

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    local win = vim.api.nvim_open_win(buf, false, {
        relative = "cursor",
        row = 1, col = 0,
        width = width,
        height = #lines,
        style = "minimal",
        border = "rounded",
        focusable = false,
        noautocmd = true,
    })
    self._help_win = win

    local group = vim.api.nvim_create_augroup(
        "loomworks_device_log_help_" .. win, { clear = true })
    self._help_group = group
    -- Dismiss only on window leave. Buffer-level CursorMoved is
    -- unusable here because of auto-scroll.
    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" },
        { group = group, buffer = self._buf, once = true,
          callback = function() self:_close_help() end })
end

function LogView:_setup_keymaps()
    local buf = self._buf
    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, {
            buffer = buf, silent = true, nowait = true, desc = desc,
        })
    end

    map("?", function() self:_show_help() end, "loomworks: toggle device-log help")
    map("<Esc>", function()
        -- Close the help overlay if it's showing; otherwise no-op
        -- (let <Esc> do whatever the user's global mappings say).
        if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
            self:_close_help()
        end
    end, "loomworks: close device-log help overlay")
    map("q", function()
        if self._help_win and vim.api.nvim_win_is_valid(self._help_win) then
            self:_close_help()
            return
        end
        self:hide()
    end, "loomworks: hide device-log view (or close help overlay)")
    map("cc", function() self:clear() end, "loomworks: clear device-log")
    map("p", function()
        self:set_paused(not self._paused)
        vim.notify("device log: " .. (self._paused and "paused" or "resumed"))
    end, "loomworks: pause/resume device-log render")
    map("cl", function() self:_cycle_level() end,
        "loomworks: cycle device-log min level")
    map("cf", function()
        vim.ui.input({
            prompt = "device log regex (empty to clear): ",
            default = self._filter.regex or "",
        }, function(input)
            if input == nil then return end
            self._filter.regex = (input ~= "" and input) or nil
            self:_rerender()
        end)
    end, "loomworks: edit device-log regex filter")
    map("cV", function()
        self._layout = (self._layout == "verbose") and "compact" or "verbose"
        self:_rerender()
        vim.notify("device log layout: " .. self._layout)
    end, "loomworks: toggle compact/verbose device-log layout")
end

-- ---------------------------------------------------------------------------
-- Public API (singleton stream + view)
-- ---------------------------------------------------------------------------

--- @type table|nil singleton LogView
local _view = nil

--- @type table|nil overseer task for the current stream
local _task = nil

--- @type fun(record: table): boolean|nil
local _prefilter = nil

--- @class loomworks.DeviceLogRemote
--- A stream the workspace daemon carries (`Launch/1.device_log`, step 5n
--- C3): `handle` cancels it (nil when it was refused at once).
--- @field handle { cancel: fun(self: table) }|nil

--- @type loomworks.DeviceLogRemote|nil the daemon-carried stream feeding the view
local _remote = nil

--- @type fun()|nil starts the active run's daemon-carried stream again (M.set_source)
local _source = nil

local function ensure_view()
    if not _view then
        _view = LogView.new()
        -- Closing the view ends a daemon-carried stream (its task is
        -- cancelled, its subscription dropped); an in-process stream keeps
        -- running hidden, as before.
        _view.on_close = function()
            if _remote then M.stop_remote() end
        end
    end
    return _view
end

--- The sink of a daemon-carried stream (M.start_remote): what the daemon's
--- `Launch/1.device_log` task delivers (API.md §9.5), fed into the view.
--- @class loomworks.DeviceLogSink
--- @field level fun(name: string|nil) the task's `start` meta `level`
--- @field records fun(records: loomworks.DeviceLogRecord[], dropped: integer|nil) a `log` signal
--- @field line fun(text: string) a line of the task
--- @field ended fun(err: string|nil) the task ended (nil: exit 0) or could not start

--- Show a device log the workspace daemon streams (`daemon` mode, step 5n
--- C3; API.md §9.5). Ends any previous stream, clears the view, shows it
--- with `opts.banner`, then `opts.open(sink)` starts the stream and returns
--- its handle (`handle:cancel()`; nil when refused at once). The sink feeds
--- the view the daemon's records (normalized records, rendered as parsed
--- lines); the task's `start` meta `level` sets the soft level filter as
--- `default_soft_filter` does in-process — only when the view is new, so a
--- level the user tuned is kept across runs; `dropped` is a gap line; the
--- task's lines and its end are lines of the view, which stays readable.
--- Closing the view, M.stop or M.stop_remote cancel the stream; nothing more
--- reaches the view from it then. `opts.on_end(err)` follows the stream's
--- own end (never a cancel).
--- @param opts { banner?: string, open: fun(sink: loomworks.DeviceLogSink): table|nil, on_end?: fun(err: string|nil) }
--- @return loomworks.DeviceLogRemote
function M.start_remote(opts)
    M.stop()
    local view_existed = _view ~= nil
    local view = ensure_view()
    view:clear()
    if opts.banner and opts.banner ~= "" then view:_inject_header(opts.banner) end
    view:show()

    --- @type loomworks.DeviceLogRemote
    local remote = {}
    _remote = remote
    local function live() return _remote == remote end
    --- @type loomworks.DeviceLogSink
    local sink = {
        level = function(name)
            if not live() or view_existed then return end
            local letter = records.level_letter(name)
            if letter then
                local f = vim.tbl_extend("force", {}, view._filter or {})
                f.level = letter
                view:set_filter(f)
            end
        end,
        records = function(list, dropped)
            if not live() then return end
            -- Records the daemon's queue dropped are gone: the gap stays
            -- in the ring (a re-render keeps it in place).
            if type(dropped) == "number" and dropped > 0 then
                view:append_record({ header = string.format("… %d records dropped", dropped) })
            end
            for _, r in ipairs(type(list) == "table" and list or {}) do
                view:append_record(records.denormalize(r))
            end
        end,
        line = function(text)
            if not live() or type(text) ~= "string" or text == "" then return end
            view:append_record({ header = text })
        end,
        ended = function(err)
            if not live() then return end
            _remote = nil
            view:append_record({ header = "── device log stream ended"
                .. (err and (": " .. tostring(err)) or "") .. " ──" })
            if opts.on_end then opts.on_end(err) end
        end,
    }
    local handle = opts.open(sink)
    if live() then remote.handle = handle end
    return remote
end

--- End the daemon-carried stream, if any: its task cancelled and its
--- subscription dropped (the handle's `cancel`), a last line in the view.
function M.stop_remote()
    local r = _remote
    if not r then return end
    _remote = nil
    if r.handle then pcall(r.handle.cancel, r.handle) end
    if _view then _view:append_record({ header = "── device log stream stopped ──" }) end
end

--- What opening the view does while no stream runs (`daemon` mode): start
--- the active device run's stream again. The session tracker sets it for a
--- run the daemon launched and clears it when the run ends or its stream
--- ended on its own. nil: opening only shows the view.
--- @param fn fun()|nil
function M.set_source(fn)
    _source = fn
end

--- Opening the view starts the active run's stream when none runs
--- (M.set_source); true when it did (the stream shows the view).
--- @return boolean
local function open_source()
    if _source and not _task and not _remote and not (_view and _view:is_visible()) then
        _source()
        return true
    end
    return false
end

--- Start a new device-log stream. Disposes any previous stream first so
--- the "one active session" invariant holds.
---
--- Soft filter handling (the user-tunable level / regex / tag
--- filter):
---   * `opts.soft_filter`        explicit override; always wins.
---   * `opts.default_soft_filter` applied only on the first launch
---                                within this nvim process (when the
---                                view is lazily created). Session
---                                tracker passes `{ level = "I" }`
---                                here so fresh runs start readable
---                                without drowning the user in
---                                V/D-level noise.
---   * Otherwise                 keep whatever filter the user had
---                                dialed in across previous runs —
---                                their `cl`/`cf` tuning persists
---                                across device-relaunches.
---
--- @param opts { cmd: string[], prefilter?: fun, soft_filter?: table, default_soft_filter?: table, name?: string, banner?: string, on_exit?: fun(code) }
--- @return table|nil overseer task
function M.start(opts)
    M.stop()
    _prefilter = opts.prefilter

    local view_existed = _view ~= nil
    local view = ensure_view()
    if opts.soft_filter ~= nil then
        view:set_filter(opts.soft_filter)
    elseif not view_existed and opts.default_soft_filter ~= nil then
        view:set_filter(opts.default_soft_filter)
    end
    view:clear()
    -- A banner line at the top makes it obvious which session we're
    -- looking at and — crucially — which prefilter we set when it
    -- started. If lines are sneaking past, you can see immediately
    -- whether the filter was set wrong or there's a parsing issue.
    if opts.banner and opts.banner ~= "" then
        view:_inject_header(opts.banner)
    end
    view:show()

    local lw_overseer = require("loomworks.overseer")
    _task = lw_overseer.run_streaming_task({
        name = opts.name or "device logs",
        cmd = opts.cmd,
        on_line = function(line)
            -- IMPORTANT: parse_line returns the sanitised form as its
            -- second value on failure. Use that for the raw record —
            -- falling back to the untouched input would leak escape
            -- remnants (`[41;155H`, BEL, etc.) into the `[UNPARSED]`
            -- lines.
            local rec, cleaned = M.parse_line(line)
            if not rec then
                if not cleaned or cleaned == "" then return end
                rec = { raw = cleaned }
            end
            if _prefilter and not _prefilter(rec) then return end
            view:append_record(rec)
        end,
        on_complete = function(status)
            if opts.on_exit then opts.on_exit(status) end
        end,
    })
    return _task
end

--- Stop the current stream (in-process, or carried by the workspace
--- daemon: M.stop_remote). Safe to call when nothing's running.
function M.stop()
    M.stop_remote()
    if _task then
        pcall(function() _task:stop() end)
        pcall(function() _task:dispose() end)
        _task = nil
    end
    _prefilter = nil
end

--- Toggle the log view window. Lazily materialises the view on
--- first call so `<leader>wO` works before a device session has
--- ever started — the buffer is just empty until something streams
--- into it.
--- In `daemon` mode, opening it while no stream runs starts the active
--- device run's stream again (M.set_source).
function M.toggle()
    if open_source() then return end
    ensure_view():toggle()
end

function M.show()
    if open_source() then return end
    ensure_view():show()
end

function M.hide()
    if _view then _view:hide() end
end

--- Is the view shown?
--- @return boolean
function M.is_visible()
    return _view ~= nil and _view:is_visible()
end

function M.set_filter(filter)
    if _view then _view:set_filter(filter) end
end

--- Update only the soft-filter level on the active view, preserving
--- any regex/tag/pid the user has tuned. No-op if no view exists.
--- @param level "D"|"I"|"W"|"E"|"F"|nil  nil clears the level filter
function M.set_level(level)
    if not _view then return end
    local cur = _view._filter or {}
    local merged = vim.tbl_extend("force", {}, cur)
    -- D is the most permissive — same as "no level filter" — so we
    -- store it as nil to keep the cycle UX consistent with `_cycle_level`.
    merged.level = (level == "D") and nil or level
    _view:set_filter(merged)
end

--- Programmatic layout control. Valid values: "compact", "verbose".
--- @param layout "compact"|"verbose"
function M.set_layout(layout)
    if layout ~= "compact" and layout ~= "verbose" then return end
    local view = ensure_view()
    view._layout = layout
    view:_rerender()
end

function M.clear()
    if _view then _view:clear() end
end

--- Is a stream running — in-process, or carried by the workspace daemon?
function M.is_running() return _task ~= nil or _remote ~= nil end
function M.task() return _task end

--- Test-only: reset module singletons between spec runs.
function M._reset_for_tests()
    M.stop()
    _source = nil
    if _view then _view.on_close = nil; _view:hide() end
    _view = nil
end

--- Test-only: the view's rendered lines (empty without a view).
--- @return string[]
function M._lines_for_tests()
    if not _view or not vim.api.nvim_buf_is_valid(_view._buf) then return {} end
    _view:_flush()
    return vim.api.nvim_buf_get_lines(_view._buf, 0, -1, false)
end

--- Test-only: the view's filter (nil without a view).
--- @return table|nil
function M._filter_for_tests()
    return _view and _view._filter
end

-- Expose LogView for tests.
M._LogView = LogView

return M
