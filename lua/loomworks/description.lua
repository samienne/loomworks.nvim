--- loomworks/description.lua — descriptions (spec §1.10, §17.11).
---
--- A pure module with no workspace access and no I/O. A description is free
--- display text stored normalised (LF line endings, no trailing whitespace, no
--- leading/trailing blank lines, empty = absent). The first line is the
--- summary, the lines after it (minus the separating blank lines) the body,
--- as in a git commit message.
---
--- The display helpers never interpret the text: `inert` / `inert_line` render
--- control characters and bidi overrides visibly, `statusline_escape` makes it
--- safe for a statusline/winbar/tabline, and `fit` truncates by display width
--- (never bytes). Works identically in Neovim and the standalone `lw` host
--- (no vim.fn dependency).

local M = {}

--- Longest description a writer accepts, in bytes after normalisation.
M.MAX_BYTES = 4096

--- Split a string on LF into a list of lines (a trailing LF yields a final
--- empty line, as in the text).
--- @param s string
--- @return string[]
local function split_lines(s)
    local lines = {}
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

--- Normalise a description value (spec §1.10). A non-string is nil (absent).
--- CRLF and lone CR become LF, trailing whitespace is removed from every
--- line, leading and trailing blank lines are removed, and an empty result
--- is nil.
--- @param v any
--- @return string|nil
function M.normalize(v)
    if type(v) ~= "string" then return nil end
    local s = v:gsub("\r\n", "\n")
    s = s:gsub("\r", "\n")
    local lines = split_lines(s)
    for i, line in ipairs(lines) do
        lines[i] = (line:gsub("%s+$", ""))
    end
    local first, last = 1, #lines
    while first <= last and lines[first] == "" do first = first + 1 end
    while last >= first and lines[last] == "" do last = last - 1 end
    if first > last then return nil end
    return table.concat(lines, "\n", first, last)
end

--- Validate a normalised description for storing (writers only; readers
--- accept any string). nil (absent) is valid. Refuses a control character
--- other than LF and TAB (C0, DEL and C1) and more than `MAX_BYTES` bytes.
--- @param s string|nil normalised text
--- @return boolean ok, string|nil err
function M.validate(s)
    if s == nil then return true, nil end
    if type(s) ~= "string" then
        return false, "a description must be text"
    end
    if #s > M.MAX_BYTES then
        return false, "the description is too long (" .. #s .. " bytes; at most "
            .. M.MAX_BYTES .. ")"
    end
    local pos = s:find("[%z\1-\8\11-\31\127]")
    if pos then
        return false, string.format(
            "the description contains a control character (0x%02X); only line breaks and tabs are allowed",
            s:byte(pos))
    end
    local c1 = s:find("\194[\128-\159]")
    if c1 then
        return false, string.format(
            "the description contains a control character (U+%04X); only line breaks and tabs are allowed",
            s:byte(c1 + 1))
    end
    return true, nil
end

--- The summary: the first line. nil for an absent description.
--- @param s string|nil
--- @return string|nil
function M.summary(s)
    if type(s) ~= "string" or s == "" then return nil end
    return s:match("^([^\n]*)")
end

--- The body: every line after the first, with the blank lines separating it
--- from the summary (and any trailing blank lines) removed. nil when none.
--- @param s string|nil
--- @return string|nil
function M.body(s)
    if type(s) ~= "string" then return nil end
    local nl = s:find("\n", 1, true)
    if not nl then return nil end
    local lines = split_lines(s:sub(nl + 1))
    local first, last = 1, #lines
    while first <= last and lines[first]:match("^%s*$") do first = first + 1 end
    while last >= first and lines[last]:match("^%s*$") do last = last - 1 end
    if first > last then return nil end
    return table.concat(lines, "\n", first, last)
end

--- Decode the UTF-8 sequence at byte `i`. Returns the code point (nil for an
--- invalid byte, which then counts as one column) and the sequence length.
--- @param s string
--- @param i integer
--- @return integer|nil cp, integer len
local function decode(s, i)
    local c = s:byte(i)
    local len, cp
    if c < 0x80 then return c, 1
    elseif c >= 0xC2 and c <= 0xDF then len, cp = 2, c - 0xC0
    elseif c >= 0xE0 and c <= 0xEF then len, cp = 3, c - 0xE0
    elseif c >= 0xF0 and c <= 0xF4 then len, cp = 4, c - 0xF0
    else return nil, 1 end
    for k = 1, len - 1 do
        local b = s:byte(i + k)
        if not b or b < 0x80 or b > 0xBF then return nil, 1 end
        cp = cp * 64 + (b - 0x80)
    end
    return cp, len
end

-- East Asian wide / fullwidth ranges (width 2). Kept deliberately simple.
local WIDE = {
    { 0x1100, 0x115F }, { 0x2E80, 0x303E }, { 0x3041, 0x33FF },
    { 0x3400, 0x4DBF }, { 0x4E00, 0x9FFF }, { 0xA000, 0xA4CF },
    { 0xAC00, 0xD7A3 }, { 0xF900, 0xFAFF }, { 0xFE30, 0xFE4F },
    { 0xFF00, 0xFF60 }, { 0xFFE0, 0xFFE6 }, { 0x1F300, 0x1F64F },
    { 0x1F900, 0x1F9FF }, { 0x20000, 0x2FFFD }, { 0x30000, 0x3FFFD },
}
-- Zero-width: combining marks, zero-width space/joiners, variation selectors.
local ZERO = {
    { 0x0300, 0x036F }, { 0x200B, 0x200F }, { 0xFE00, 0xFE0F },
    { 0x20D0, 0x20FF },
}

local function in_ranges(cp, ranges)
    for _, r in ipairs(ranges) do
        if cp >= r[1] and cp <= r[2] then return true end
    end
    return false
end

--- Display width of one code point (nil = invalid byte = 1 column).
--- @param cp integer|nil
--- @return integer
local function cp_width(cp)
    if not cp then return 1 end
    if cp < 0x300 then return 1 end
    if in_ranges(cp, ZERO) then return 0 end
    if in_ranges(cp, WIDE) then return 2 end
    return 1
end

--- Display width of a string in terminal columns (UTF-8 aware; East Asian
--- wide characters count 2, combining marks 0).
--- @param s string
--- @return integer
function M.width(s)
    local w, i, n = 0, 1, #s
    while i <= n do
        local cp, len = decode(s, i)
        w = w + cp_width(cp)
        i = i + len
    end
    return w
end

--- Truncate `s` to at most `cols` display columns, ending with `…` when cut
--- (never cutting inside a character). "" for cols < 1 or a nil string.
--- @param s string|nil
--- @param cols integer
--- @return string
function M.fit(s, cols)
    if type(s) ~= "string" or not cols or cols < 1 then return "" end
    if M.width(s) <= cols then return s end
    local budget = cols - 1 -- room for the ellipsis
    local w, i, n = 0, 1, #s
    while i <= n do
        local cp, len = decode(s, i)
        local cw = cp_width(cp)
        if w + cw > budget then break end
        w = w + cw
        i = i + len
    end
    return s:sub(1, i - 1) .. "…"
end

-- Bidi embedding/override (U+202A–U+202E) and isolate (U+2066–U+2069)
-- controls, as their UTF-8 byte sequences.
local function bidi_cp(s, i)
    local a, b, c = s:byte(i, i + 2)
    if a ~= 0xE2 or not b or not c then return nil end
    if b == 0x80 and c >= 0xAA and c <= 0xAE then
        return 0x2000 + (c - 0x80) -- 0x202A..0x202E
    end
    if b == 0x81 and c >= 0xA6 and c <= 0xA9 then
        return 0x2040 + (c - 0x80) -- 0x2066..0x2069
    end
    return nil
end

--- Render text inert for display (spec §17.11): C0 controls as caret
--- notation (`^[`), DEL as `^?`, C1 controls and bidi controls as `\uXXXX`
--- text, TAB as a space. LF is kept (one buffer line per description line) —
--- unless `keep_lf` is false, when it becomes a space too.
--- @param s string|nil
--- @param keep_lf? boolean default true
--- @return string
local function render(s, keep_lf)
    if type(s) ~= "string" then return "" end
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c == 10 then
            out[#out + 1] = keep_lf and "\n" or " "
            i = i + 1
        elseif c == 9 then
            out[#out + 1] = " "
            i = i + 1
        elseif c < 32 then
            out[#out + 1] = "^" .. string.char(c + 64)
            i = i + 1
        elseif c == 127 then
            out[#out + 1] = "^?"
            i = i + 1
        elseif c == 0xC2 and i < n and s:byte(i + 1) >= 0x80 and s:byte(i + 1) <= 0x9F then
            out[#out + 1] = string.format("\\u%04X", s:byte(i + 1))
            i = i + 2
        elseif c == 0xE2 and bidi_cp(s, i) then
            out[#out + 1] = string.format("\\u%04X", bidi_cp(s, i))
            i = i + 3
        else
            -- Copy a run of ordinary bytes in one go.
            local j = i
            while j <= n do
                local b = s:byte(j)
                if b < 32 or b == 127 or b == 0xC2 or b == 0xE2 then break end
                j = j + 1
            end
            if j == i then j = i + 1 end
            out[#out + 1] = s:sub(i, j - 1)
            i = j
        end
    end
    return table.concat(out)
end

--- Inert rendering that keeps LF (multi-line detail views; split on LF into
--- one buffer line per description line).
--- @param s string|nil
--- @return string
function M.inert(s)
    return render(s, true)
end

--- Inert rendering for a one-line context: additionally turns LF into a
--- space, so the result never spans lines.
--- @param s string|nil
--- @return string
function M.inert_line(s)
    return render(s, false)
end

--- Make text safe for a statusline / winbar / tabline component: `%` becomes
--- `%%` (no statusline items, highlight groups or expressions can be
--- injected), TAB/LF/CR become spaces and every other control character (C0,
--- DEL, C1) and bidi control is removed.
--- @param s string|nil
--- @return string
function M.statusline_escape(s)
    if type(s) ~= "string" then return "" end
    local r = s:gsub("[\t\n\r]", " ")
    r = r:gsub("[%z\1-\31\127]", "")
    r = r:gsub("\194[\128-\159]", "")
    r = r:gsub("\226\128[\170-\174]", "")
    r = r:gsub("\226\129[\166-\169]", "")
    r = r:gsub("%%", "%%%%")
    return r
end

--- Join the lines of a `#`-comment editor buffer into the text, dropping
--- every line that starts with `#` (git-commit style). Not normalised.
--- @param lines string[]
--- @return string
function M.strip_comments(lines)
    local kept = {}
    for _, line in ipairs(lines or {}) do
        if line:sub(1, 1) ~= "#" then kept[#kept + 1] = line end
    end
    return table.concat(kept, "\n")
end

--- Read a description value from a file (spec §1.10). Returns the normalised
--- text, plus the raw value when it is present but not a string (JSON null
--- counts as absent). Such a value is ignored (the item has no description)
--- but written back unchanged unless the description is set or cleared, so
--- the domain objects keep it as `_description_invalid` for the serialisers
--- and a diagnostic.
--- @param v any
--- @return string|nil description, any invalid
function M.from_file(v)
    if v == nil or (vim and v == vim.NIL) then return nil, nil end
    if type(v) ~= "string" then return nil, v end
    return M.normalize(v), nil
end

--- Normalise + validate a writer's text in one step (used by the domain
--- objects' `set_description`). Returns the normalised text (nil = clear)
--- or nil plus an error.
--- @param text any string or nil
--- @return boolean ok, string|nil normalised, string|nil err
function M.prepare(text)
    if text ~= nil and type(text) ~= "string" then
        return false, nil, "a description must be text"
    end
    local s = M.normalize(text)
    local ok, err = M.validate(s)
    if not ok then return false, nil, err end
    return true, s, nil
end

return M
