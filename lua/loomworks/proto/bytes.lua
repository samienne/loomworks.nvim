--- loomworks/proto/bytes.lua — the bytes of a task's `output` frame and the
--- UTF-8 rule of every string a server sends (frames are UTF-8 JSON,
--- RFC 8259).
---
--- A chunk of raw output travels as `text` when it is valid UTF-8, else as
--- `data`, its bytes in base64 (RFC 4648 §4) — exactly one of the two. A
--- server holds back an incomplete trailing UTF-8 sequence of a stream until
--- its next chunk (`split_tail`), so a character split between two pipe reads
--- still arrives as `text`. A server's own text (`line.text`) is made valid
--- with U+FFFD (`sanitize`).
---
--- Host-neutral pure Lua (shared by the daemon, the `lw` CLI and the editor):
--- no `vim.*`, no `bit` library.

local M = {}

local byte, char, concat, floor = string.byte, string.char, table.concat, math.floor

--- The length of the valid UTF-8 sequence starting at `i` of `s`, or nil
--- when the bytes there are not one (overlong forms, surrogates and code
--- points above U+10FFFF are invalid; a truncated sequence too).
--- @param s string
--- @param i integer
--- @return integer|nil
local function seq_len(s, i)
    local c = byte(s, i)
    if c < 0x80 then return 1 end
    local n, lo, hi
    if c >= 0xC2 and c <= 0xDF then n, lo, hi = 2, 0x80, 0xBF
    elseif c == 0xE0 then n, lo, hi = 3, 0xA0, 0xBF
    elseif c == 0xED then n, lo, hi = 3, 0x80, 0x9F
    elseif c >= 0xE1 and c <= 0xEF then n, lo, hi = 3, 0x80, 0xBF
    elseif c == 0xF0 then n, lo, hi = 4, 0x90, 0xBF
    elseif c == 0xF4 then n, lo, hi = 4, 0x80, 0x8F
    elseif c >= 0xF1 and c <= 0xF3 then n, lo, hi = 4, 0x80, 0xBF
    else return nil end
    local c2 = byte(s, i + 1)
    if not c2 or c2 < lo or c2 > hi then return nil end
    for k = i + 2, i + n - 1 do
        local ck = byte(s, k)
        if not ck or ck < 0x80 or ck > 0xBF then return nil end
    end
    return n
end

--- Whether `s` is valid UTF-8.
--- @param s string
--- @return boolean
function M.is_utf8(s)
    if not s:find("[\128-\255]") then return true end
    local i, n = 1, #s
    while i <= n do
        local l = seq_len(s, i)
        if not l then return false end
        i = i + l
    end
    return true
end

--- `s` with each byte that is not part of a valid UTF-8 sequence replaced
--- by U+FFFD.
--- @param s string
--- @return string
function M.sanitize(s)
    if M.is_utf8(s) then return s end
    local out, i, n = {}, 1, #s
    while i <= n do
        local l = seq_len(s, i)
        if l then out[#out + 1] = s:sub(i, i + l - 1); i = i + l
        else out[#out + 1] = "\239\191\189"; i = i + 1 end
    end
    return concat(out)
end

--- Split off an incomplete trailing UTF-8 sequence of `s`: the last bytes
--- that are a valid start of a sequence the end of `s` cuts short.
--- @param s string
--- @return string head, string tail `head .. tail == s`; tail is "" or 1-3 bytes
function M.split_tail(s)
    local n = #s
    for i = n, math.max(1, n - 2), -1 do
        local c = byte(s, i)
        if c < 0x80 then return s, "" end
        if c >= 0xC0 then
            -- A lead byte: hold it (and its continuation bytes) back when the
            -- sequence it starts is still incomplete and valid so far.
            local need = c >= 0xF0 and 4 or c >= 0xE0 and 3 or 2
            if n - i + 1 >= need then return s, "" end
            -- Valid so far when some completion is a valid sequence: the
            -- smallest second byte its lead allows, then continuation bytes.
            local probe = s:sub(i)
            if #probe == 1 then probe = probe .. char(c == 0xE0 and 0xA0 or c == 0xF0 and 0x90 or 0x80) end
            probe = probe .. ("\128"):rep(need - #probe)
            if seq_len(probe, 1) then return s:sub(1, i - 1), s:sub(i) end
            return s, ""
        end
    end
    return s, ""
end

local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
    local ch = ALPHA:sub(i, i)
    ENC[i - 1] = ch
    DEC[byte(ch)] = i - 1
end

--- `s` in base64 (RFC 4648 §4, padded).
--- @param s string
--- @return string
function M.b64encode(s)
    local out, n = {}, #s
    for i = 1, n - 2, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + b * 256 + c
        out[#out + 1] = ENC[floor(v / 262144)] .. ENC[floor(v / 4096) % 64]
            .. ENC[floor(v / 64) % 64] .. ENC[v % 64]
    end
    local r = n % 3
    if r == 1 then
        local v = byte(s, n) * 65536
        out[#out + 1] = ENC[floor(v / 262144)] .. ENC[floor(v / 4096) % 64] .. "=="
    elseif r == 2 then
        local a, b = byte(s, n - 1, n)
        local v = a * 65536 + b * 256
        out[#out + 1] = ENC[floor(v / 262144)] .. ENC[floor(v / 4096) % 64] .. ENC[floor(v / 64) % 64] .. "="
    end
    return concat(out)
end

--- The bytes of base64 `s` (RFC 4648 §4), or nil when `s` is not base64.
--- @param s string
--- @return string|nil
function M.b64decode(s)
    if type(s) ~= "string" or #s % 4 ~= 0 then return nil end
    local out, n = {}, #s
    for i = 1, n, 4 do
        local c1, c2, c3, c4 = byte(s, i, i + 3)
        local last = i + 3 == n
        local a, b = DEC[c1], DEC[c2]
        if not a or not b then return nil end
        if c3 == 61 and c4 == 61 and last then
            if b % 16 ~= 0 then return nil end
            out[#out + 1] = char(a * 4 + floor(b / 16))
        elseif c4 == 61 and last then
            local c = DEC[c3]
            if not c or c % 4 ~= 0 then return nil end
            out[#out + 1] = char(a * 4 + floor(b / 16), (b % 16) * 16 + floor(c / 4))
        else
            local c, d = DEC[c3], DEC[c4]
            if not c or not d then return nil end
            out[#out + 1] = char(a * 4 + floor(b / 16), (b % 16) * 16 + floor(c / 4), (c % 4) * 64 + d)
        end
    end
    return concat(out)
end

--- The fields of an `output` frame carrying `chunk`: `{ text = chunk }` when
--- it is valid UTF-8, else `{ data = <base64> }`.
--- @param chunk string
--- @return table
function M.output_fields(chunk)
    if M.is_utf8(chunk) then return { text = chunk } end
    return { data = M.b64encode(chunk) }
end

--- The raw bytes an `output` frame carries (its `data` decoded, else its
--- `text`); "" for a frame with neither or with `data` that is not base64.
--- @param frame table
--- @return string
function M.output_bytes(frame)
    if type(frame.data) == "string" then return M.b64decode(frame.data) or "" end
    return type(frame.text) == "string" and frame.text or ""
end

--- Whether `frame` (a task `output` frame) carries its chunk correctly:
--- exactly one of `text` (valid UTF-8) and `data` (base64).
--- @param frame table
--- @return boolean ok, string|nil err
function M.check_output(frame)
    local t, d = frame.text, frame.data
    if (t ~= nil) == (d ~= nil) then return false, "output frame: exactly one of text and data" end
    if t ~= nil and (type(t) ~= "string" or not M.is_utf8(t)) then
        return false, "output frame: text is not valid UTF-8"
    end
    if d ~= nil and not M.b64decode(d) then return false, "output frame: data is not base64" end
    return true
end

return M
