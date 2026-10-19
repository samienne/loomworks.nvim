--- loomworks/device_log_records.lua — a device log's lines as records,
--- host-neutral (pure Lua): the editor's in-process device-log view
--- (loomworks.device_log) and the workspace daemon's `Launch/1.device_log`
--- (API.md §9.5) parse and prefilter a module's log stream with this same
--- code, and the daemon sends the lines it keeps as the normalized records
--- of spec §19.18 (`normalize`).

local M = {}

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------

--- Strip escape sequences, BOM, and stray control bytes from a line.
--- The device connector can prepend colour sequences, send BEL
--- characters, or mix CRLF depending on the build — without
--- sanitising, those leak into the parse regex (breaking it) or into
--- the rendered buffer (showing up as weird glyphs).
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
    -- Headless CSI remnants: something upstream (overseer output
    -- processing, neovim jobstart, or the device connector itself)
    -- can eat the ESC byte but leave the visible `[41;155H` tail. Strip the tail
    -- too — require at least two digits in the parameter block so
    -- legitimate bracketed content like `[a92ab178]` or `[0xABCD]`
    -- doesn't match.
    line = line:gsub("%[%??%d%d+[%d; ]*[A-Za-z]", "")
    -- Remove non-printable C0 controls except TAB, LF, CR, and DEL.
    line = line:gsub("[%z\1-\8\11-\12\14-\31\127]", "")
    -- Trailing CR (Windows-style line endings in a substream)
    line = line:gsub("\r+$", "")
    return line
end

--- Expose the line sanitiser so streaming callers can clean a line
--- up once and use the result for both parse AND the raw fallback
--- (otherwise an unparseable line shows up in the view with its
--- escape remnants still attached).
--- @param line string
--- @return string cleaned
function M.sanitize_line(line)
    if type(line) ~= "string" then return "" end
    return sanitize(line)
end

--- Parse a single device log line.
---
--- Expected format:
---   MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: message
---
--- Some lines use a two-segment DOMAIN/TAG form (no PROC) — we fall
--- back to that rather than dropping them.
---
--- Returns `nil, cleaned_line` when the line couldn't be parsed; the
--- caller is expected to keep that cleaned fallback visible as a
--- raw record so buffering / streaming issues are obvious.
--- @param line string
--- @return table|nil record { time, pid, tid, level, domain, proc?, tag, msg }
--- @return string|nil cleaned_line  sanitised form, for raw fallback
function M.parse_line(line)
    if type(line) ~= "string" or line == "" then return nil, "" end
    line = sanitize(line)
    if line == "" then return nil, "" end

    local time, pid, tid, level, rest = line:match(
        "^(%d%d%-%d%d %d%d:%d%d:%d%d%.%d+)%s+(%d+)%s+(%d+)%s+([A-Z])%s+(.*)$")
    if not time then return nil, line end

    -- Three-segment form: DOMAIN/PROC/TAG: msg. Neither PROC nor TAG holds
    -- whitespace, so a two-segment line whose message contains "/" and ": "
    -- (`C03F00/MUSL-LDSO: load /system/lib/x.so: ok`) is never split there.
    local domain, proc, tag, msg = rest:match("^([^/%s]+)/([^/%s]+)/([^:%s]+):%s?(.*)$")
    if not domain then
        -- Two-segment form: DOMAIN/TAG: msg
        domain, tag, msg = rest:match("^([^/%s]+)/([^:%s]+):%s?(.*)$")
        proc = nil
    end
    if not domain then return nil, line end

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

--- Does the device log's `proc` column refer to `bundle`?
---
--- Three cases:
---   * exact match             `proc == bundle`
---   * prefix + separator      `proc` starts with `bundle.` or
---                             `bundle:` (sub-processes and service
---                             helpers that live under the app, e.g.
---                             `com.example.app.worker` or
---                             `com.example.app:helper`)
---   * left-truncation         some device log formats truncate the
---                             proc column to ~30 chars from the LEFT
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
---     This is the "All logs of selected app" behaviour:
---     drops system noise emitted by services that happen to run on
---     adjacent PIDs, drops the kernel/helpers that aren't our app.
---     If the launch resolved only one of pid/bundle, the prefilter
---     degrades to whichever was available (still narrow enough).
---   * `"app-related"` — keep if **either** side matches. Broader
---     net for when the strict mode is hiding runtime-helper output
---     the user wants to see.
---   * `"all"` — no prefilter. For debugging the stream itself.
---
--- Regardless of mode, unparseable "raw" records always pass —
--- device-connector errors, kernel panics, and similar diagnostic
--- lines stay visible.
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
-- Normalized records (spec §19.18)
-- ---------------------------------------------------------------------------

--- A parsed line's level letter as a normalized record's level.
M.LEVELS = { V = "verbose", D = "debug", I = "info", W = "warn", E = "error", F = "fatal" }

--- The level of a line whose level letter is unknown, and of an unparsed line.
M.DEFAULT_LEVEL = "info"

--- @class loomworks.DeviceLogRecord
--- A normalized device log record (spec §19.18, API.md §9.5).
--- @field ts? string the line's time as printed
--- @field level string verbose, debug, info, warn, error or fatal
--- @field tag? string
--- @field pid? integer
--- @field message string
--- @field fields? { tid?: integer, domain?: string, proc?: string }

--- A record of `parse_line` — or `{ raw = line }` for a line it could not
--- parse — as a normalized record: its time is `ts`, its message `message`,
--- and `tid`, `domain` and `proc` go to `fields`; an unparsed line is only
--- its `message`, at the default level.
--- @param rec table
--- @return loomworks.DeviceLogRecord
function M.normalize(rec)
    if rec.raw then return { level = M.DEFAULT_LEVEL, message = rec.raw } end
    local fields = { tid = rec.tid, domain = rec.domain, proc = rec.proc }
    return {
        ts = rec.time,
        level = M.LEVELS[rec.level] or M.DEFAULT_LEVEL,
        tag = rec.tag,
        pid = rec.pid,
        message = rec.msg or "",
        fields = next(fields) ~= nil and fields or nil,
    }
end

return M