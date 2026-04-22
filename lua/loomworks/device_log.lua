--- loomworks/device_log.lua — client-side device-log view.
---
--- hdc/hilog's on-device filter flags are unreliable across
--- HarmonyOS releases, so we take the DevEco approach: receive the
--- raw stream, parse each line into a structured record, and filter
--- client-side. Two tiers of filtering keep memory bounded and the
--- view interactive:
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
-- Parser
-- ---------------------------------------------------------------------------

--- Strip escape sequences, BOM, and stray control bytes from a line.
--- hdc can prepend colour sequences, send BEL characters, or mix
--- CRLF depending on the build — without sanitising, those leak
--- into the parse regex (breaking it) or into the rendered buffer
--- (showing up as weird glyphs).
--- @param line string
--- @return string
local function sanitize(line)
    -- UTF-8 BOM
    if line:sub(1, 3) == "\xEF\xBB\xBF" then
        line = line:sub(4)
    end
    -- ANSI CSI: ESC '[' [params] final-byte
    line = line:gsub("\27%[[%d;?]*[@-~]", "")
    -- OSC sequences: ESC ']' ... (terminated by BEL or ST)
    line = line:gsub("\27%][^\7\27]*[\7\27]", "")
    -- Other single-char escape sequences: ESC followed by one byte
    -- that isn't '[' or ']' (covers ESC(A, ESC=, ESC\, ...).
    line = line:gsub("\27[^%[%]]", "")
    -- Remove non-printable C0 controls except TAB, LF, CR, and DEL.
    line = line:gsub("[%z\1-\8\11-\12\14-\31\127]", "")
    -- Trailing CR (Windows-style line endings in a substream)
    line = line:gsub("\r+$", "")
    return line
end

--- Parse a single hilog line.
---
--- Expected format:
---   MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: message
---
--- Some lines use a two-segment DOMAIN/TAG form (no PROC) — we fall
--- back to that rather than dropping them.
---
--- Unparseable lines return nil; the caller is expected to keep them
--- as raw text so diagnostic output (hdc errors, kernel panics) isn't
--- silently swallowed.
--- @param line string
--- @return table|nil record { time, pid, tid, level, domain, proc?, tag, msg }
function M.parse_line(line)
    if type(line) ~= "string" or line == "" then return nil end
    line = sanitize(line)
    if line == "" then return nil end

    local time, pid, tid, level, rest = line:match(
        "^(%d%d%-%d%d %d%d:%d%d:%d%d%.%d+)%s+(%d+)%s+(%d+)%s+([A-Z])%s+(.*)$")
    if not time then return nil end

    -- Three-segment form: DOMAIN/PROC/TAG: msg
    local domain, proc, tag, msg = rest:match("^([^/%s]+)/([^/]+)/([^:]+):%s?(.*)$")
    if not domain then
        -- Two-segment form: DOMAIN/TAG: msg
        domain, tag, msg = rest:match("^([^/%s]+)/([^:]+):%s?(.*)$")
        proc = nil
    end
    if not domain then return nil end

    return {
        time = time,
        pid = tonumber(pid),
        tid = tonumber(tid),
        level = level,
        domain = domain,
        proc = proc,
        tag = tag,
        msg = msg or "",
    }
end

-- ---------------------------------------------------------------------------
-- Filtering
-- ---------------------------------------------------------------------------

--- Level ordering — records are "at or above" the requested minimum.
local LEVEL_RANK = { V = 0, D = 1, I = 2, W = 3, E = 4, F = 5 }

--- Apply a soft filter. AND semantics: every non-nil filter field must
--- match. Filter fields are all optional.
--- @param filter table { pid?, proc?, tag?, level?, regex? }
--- @param record table
--- @return boolean
function M.match_filter(filter, record)
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
            return record.raw:match(filter.regex) ~= nil
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
        if not record.msg or not record.msg:match(filter.regex) then
            return false
        end
    end
    return true
end

--- Does the hilog `proc` column refer to `bundle`?
---
--- Three cases:
---   * exact match             `proc == bundle`
---   * prefix + separator      `proc` starts with `bundle.` or
---                             `bundle:` (sub-processes and service
---                             helpers that live under the app, e.g.
---                             `com.example.app.worker` or
---                             `com.example.app:helper`)
---   * left-truncation         HarmonyOS hilog truncates the proc
---                             column to ~30 chars from the LEFT
---                             for long bundle names. The proc seen
---                             in the stream is a suffix of the
---                             real bundle. Matches when
---                             `bundle:sub(-#proc) == proc`.
--- @param proc string|nil
--- @param bundle string
--- @return boolean
local function proc_matches_bundle(proc, bundle)
    if not proc or not bundle or bundle == "" then return false end
    if proc == bundle then return true end
    local n = #bundle
    local prefix = proc:sub(1, n + 1)
    if prefix == bundle .. "." or prefix == bundle .. ":" then
        return true
    end
    if #bundle > #proc and bundle:sub(-#proc) == proc then
        return true
    end
    return false
end

--- Build the session prefilter.
---
--- Modes:
---   * `"strict"` (default) — keep a record only if **both** the PID
---     is the app's PID AND the proc column matches the bundle.
---     This is the DevEco "All logs of selected app" behaviour:
---     drops system noise emitted by services that happen to run on
---     adjacent PIDs, drops the kernel/helpers that aren't our app.
---     If the launch resolved only one of pid/bundle, the prefilter
---     degrades to whichever was available (still narrow enough).
---   * `"app-related"` — keep if **either** side matches. Broader
---     net for when the strict mode is hiding runtime-helper output
---     the user wants to see.
---   * `"all"` — no prefilter. For debugging the stream itself.
---
--- Regardless of mode, unparseable "raw" records always pass — hdc
--- errors, kernel panics, and similar diagnostic lines stay visible.
---
--- @param opts { pid?: number, bundle?: string, mode?: "strict"|"app-related"|"all" }
--- @return fun(record: table): boolean
function M.make_prefilter(opts)
    opts = opts or {}
    local mode = opts.mode or "strict"
    local pid = opts.pid
    local bundle = opts.bundle

    if mode == "all" then
        return function() return true end
    end

    if mode == "app-related" then
        return function(record)
            if not record then return false end
            if record.header or record.raw then return true end
            if pid and record.pid == pid then return true end
            if bundle and proc_matches_bundle(record.proc, bundle) then
                return true
            end
            return false
        end
    end

    -- Default: strict — AND of whichever criteria are provided.
    return function(record)
        if not record then return false end
        if record.header or record.raw then return true end
        local pid_ok = pid and record.pid == pid
        local bundle_ok = bundle and proc_matches_bundle(record.proc, bundle)
        if pid and bundle then return pid_ok and bundle_ok end
        if pid then return pid_ok end
        if bundle then return bundle_ok end
        return false
    end
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
        _paused = false,
        _dropped = 0,
        _ns = vim.api.nvim_create_namespace("loomworks_device_log"),
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

    if vim.api.nvim_win_is_valid(prev) then
        vim.api.nvim_set_current_win(prev)
    end

    -- On first show, jump to the end so auto-follow is "on" right away.
    self:_scroll_to_end(true)
end

function LogView:hide()
    if self._win and vim.api.nvim_win_is_valid(self._win) then
        vim.api.nvim_win_close(self._win, true)
    end
    self._win = nil
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

--- Push a parsed (or raw-fallback) record. Appends to the ring
--- buffer, drops the oldest when full, and appends to the visible
--- buffer iff the soft filter matches.
--- @param record table
function LogView:append_record(record)
    self._records[#self._records + 1] = record

    if #self._records > MAX_RECORDS then
        -- Trim a batch at a time to avoid per-line table.remove
        -- thrashing when the stream is firehose-level.
        local drop = #self._records - MAX_RECORDS
        local kept = {}
        for i = drop + 1, #self._records do
            kept[#kept + 1] = self._records[i]
        end
        self._records = kept
        self._dropped = self._dropped + drop
        -- Full re-render so the buffer stays in sync with the ring.
        -- Cheap at this size; running the stream longer will keep
        -- doing this incrementally.
        self:_rerender()
        return
    end

    if self._paused then return end
    if not M.match_filter(self._filter, record) then return end
    self:_append_line(record)
end

--- Render a record to a display string.
---
--- Parsed records are reconstructed into the original hilog line
--- format (timestamp, pid, tid, level, DOMAIN/PROC/TAG: msg) so you
--- can diff the view against the raw stream and tell at a glance
--- whether parsing dropped or mangled any fields.
---
--- Three record shapes:
---   * header  — session banner injected by `M.start`
---   * raw     — unparseable line; marked `[UNPARSED]` so any
---               streaming / buffering issue shows up immediately
---   * parsed  — real hilog record
---
--- @param record table
--- @return string
function LogView:_render(record)
    if record.header then return record.header end
    if record.raw then return "[UNPARSED] " .. record.raw end

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

function LogView:_append_line(record)
    local line = self:_render(record)
    vim.bo[self._buf].modifiable = true

    local n = vim.api.nvim_buf_line_count(self._buf)
    -- Freshly created buffers have one empty line; replace it in
    -- place to avoid a leading blank in the view.
    local first = vim.api.nvim_buf_get_lines(self._buf, 0, 1, false)[1]
    local is_empty = (n == 1 and (first == nil or first == ""))
    if is_empty then
        vim.api.nvim_buf_set_lines(self._buf, 0, 1, false, { line })
        self:_highlight(record, 0)
    else
        vim.api.nvim_buf_set_lines(self._buf, n, n, false, { line })
        self:_highlight(record, n)
    end

    vim.bo[self._buf].modifiable = false
    self:_maybe_scroll()
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
    self._dropped = 0
    vim.bo[self._buf].modifiable = true
    vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, {})
    vim.api.nvim_buf_clear_namespace(self._buf, self._ns, 0, -1)
    vim.bo[self._buf].modifiable = false
end

--- Add a synthetic header record to the top of the ring + view.
--- Used by `M.start` to stamp the session's prefilter onto the
--- output — so the user knows which session/filter they're looking
--- at without having to dig through loomworks.log.
--- @param text string
function LogView:_inject_header(text)
    local rec = { header = "── " .. text .. " ──" }
    self._records[#self._records + 1] = rec
    self:_append_line(rec)
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
        if M.match_filter(self._filter, rec) then
            lines[#lines + 1] = self:_render(rec)
            hl_records[#hl_records + 1] = rec
        end
    end
    if #lines == 0 then
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, { "" })
    else
        vim.api.nvim_buf_set_lines(self._buf, 0, -1, false, lines)
        for i, rec in ipairs(hl_records) do
            self:_highlight(rec, i - 1)
        end
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
    { "cf", "edit regex filter (empty to clear)" },
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

local function ensure_view()
    if not _view then _view = LogView.new() end
    return _view
end

--- Start a new hilog stream. Disposes any previous stream first so
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
            local rec = M.parse_line(line)
            if not rec then
                rec = { raw = line }
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

--- Stop the current stream. Safe to call when nothing's running.
function M.stop()
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
function M.toggle()
    ensure_view():toggle()
end

function M.show()
    ensure_view():show()
end

function M.hide()
    if _view then _view:hide() end
end

function M.set_filter(filter)
    if _view then _view:set_filter(filter) end
end

function M.clear()
    if _view then _view:clear() end
end

function M.is_running() return _task ~= nil end
function M.task() return _task end

--- Test-only: reset module singletons between spec runs.
function M._reset_for_tests()
    M.stop()
    _view = nil
end

-- Expose LogView for tests.
M._LogView = LogView

return M
