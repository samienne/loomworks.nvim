--- loomworks/daemon/log_record.lua — the NORMALIZED device-log record schema
--- (DAEMON.md §6.2, scaffold).
---
--- Device/log logic is headless (an "lw plugin"), so the main plugin gains a
--- GENERAL device picker + log viewer instead of a platform-specific one. The
--- viewer is driven by a normalized record `{ ts, level, tag, pid, message,
--- fields? }` — a `fields` typed escape hatch carries platform extras (e.g. a
--- HarmonyOS `hilog` domain) without the core knowing about them. A module's
--- device-log producer emits raw records; this normalizes them, and the log
--- stream reuses the task-stream broadcast pattern (§3.4).
---
--- This is the presentation-neutral schema + helpers; wiring an actual module's
--- device logs through it (and migrating `ohos`) is deferred until that module
--- is actively developed (DAEMON.md §6.2).

local M = {}

--- Ordered severity levels; anything else normalizes to "info".
M.LEVELS = { "verbose", "debug", "info", "warn", "error", "fatal" }

local LEVEL_SET = {}
for i, l in ipairs(M.LEVELS) do LEVEL_SET[l] = i end

--- The fields that belong to the normalized record itself (everything else a
--- producer supplies is folded into `fields`).
local KNOWN = { ts = true, level = true, tag = true, pid = true, message = true, fields = true }

--- Is `level` a recognized severity?
--- @param level any
--- @return boolean
function M.is_level(level) return type(level) == "string" and LEVEL_SET[level] ~= nil end

--- Numeric severity rank (for filtering / min-level), or nil.
--- @param level string
--- @return integer|nil
function M.rank(level) return LEVEL_SET[level] end

--- Normalize a raw producer record into the schema. Unknown top-level keys are
--- folded into `fields` (the platform escape hatch); an unknown level becomes
--- "info"; `ts` defaults to now.
--- @param raw table
--- @return table record { ts, level, tag, pid, message, fields }
function M.normalize(raw)
    raw = raw or {}
    local fields = {}
    if type(raw.fields) == "table" then
        for k, v in pairs(raw.fields) do fields[k] = v end
    end
    for k, v in pairs(raw) do
        if not KNOWN[k] then fields[k] = v end
    end
    return {
        ts = type(raw.ts) == "number" and raw.ts or os.time(),
        level = M.is_level(raw.level) and raw.level or "info",
        tag = type(raw.tag) == "string" and raw.tag or "",
        pid = type(raw.pid) == "number" and raw.pid or nil,
        message = type(raw.message) == "string" and raw.message or tostring(raw.message or ""),
        fields = next(fields) and fields or nil,
    }
end

--- Validate a normalized record.
--- @param record table
--- @return boolean ok, string|nil err
function M.validate(record)
    if type(record) ~= "table" then return false, "record must be a table" end
    if type(record.ts) ~= "number" then return false, "ts must be a number" end
    if not M.is_level(record.level) then return false, "invalid level" end
    if type(record.message) ~= "string" then return false, "message must be a string" end
    return true
end

--- A one-line human rendering for a log viewer (presentation-neutral).
--- @param record table a normalized record
--- @return string
function M.format(record)
    local pid = record.pid and ("[" .. tostring(record.pid) .. "]") or ""
    local tag = (record.tag and record.tag ~= "") and (" " .. record.tag) or ""
    return string.format("%s %-7s%s%s: %s",
        tostring(record.ts), record.level:upper(), tag, pid, record.message)
end

return M
