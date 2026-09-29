--- loomworks/term.lua — terminal-safe rendering for CLI output.
---
--- Much of what `lw` prints is DATA from workspace files, the cache, the
--- health cache or tool probes (project / profile / configuration names,
--- paths, option values, inventory results). A clone can put terminal control
--- sequences in any of them (ESC-based CSI/OSC sequences that move the cursor,
--- rewrite the screen, set the window title or clipboard, or forge hyperlinks).
--- So every line the CLI writes goes through `render`, which neutralizes every
--- C0/C1 control character except TAB and LF — ESC becomes the visible `^[`,
--- CR `^M`, a UTF-8-encoded C1 control `\u009b`, and so on.
---
--- The CLI's OWN coloring must survive that pass, so the palette never embeds
--- a raw ESC: it emits `sgr(code)` markers — NUL + a random per-process nonce +
--- the SGR parameters — which only `render` turns into real `ESC[<code>m`.
--- Data cannot forge a marker without knowing the nonce, and any NUL/ESC it
--- carries is escaped like every other control character.

local M = {}

local function random_hex(n)
    local uv = vim.uv or vim.loop
    local ok, bytes = pcall(uv.random, n)
    if ok and type(bytes) == "string" and #bytes == n then
        return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end
    math.randomseed(((uv.hrtime and uv.hrtime()) or os.time()) % 2147483647)
    local t = {}
    for i = 1, n do t[i] = ("%02x"):format(math.random(0, 255)) end
    return table.concat(t)
end

--- Per-process marker nonce (hex, so it is pattern-safe).
M.NONCE = random_hex(8)

--- An SGR marker for `code` (e.g. "36", "1", "0"). Only `render` turns it into
--- an escape sequence.
--- @param code string digits and `;`
--- @return string
function M.sgr(code)
    return "\0" .. M.NONCE .. "{" .. code .. "}"
end

--- Escape every control character in `s` except TAB and LF: C0 (and DEL) as
--- caret notation (`^[` for ESC, `^M` for CR, `^@` for NUL, `^?` for DEL) and
--- UTF-8-encoded C1 controls (U+0080–U+009F) as `\u00XX`.
--- @param s any
--- @return string
function M.escape(s)
    s = tostring(s)
    s = s:gsub("\194([\128-\159])", function(c) return ("\\u%04x"):format(c:byte()) end)
    s = s:gsub("[%z\1-\8\11-\31\127]", function(c)
        local b = c:byte()
        if b == 127 then return "^?" end
        return "^" .. string.char(b + 64)
    end)
    return s
end

--- Format an argv as one readable command line, for display only (logs,
--- `lw build -v`): an element that is empty or holds whitespace, a quote or a
--- shell metacharacter is double-quoted, with `"` escaped as `\"`; the rest is
--- joined verbatim. Not a re-executable quoting for any particular shell.
--- Control characters are left in place — the output layer (`render` /
--- `escape`) neutralizes them.
--- @param argv string[]
--- @return string
function M.format_argv(argv)
    local parts = {}
    for _, a in ipairs(argv or {}) do
        a = tostring(a)
        if a == "" or a:find("[%s\"'`$&|;<>()*?!^%%#{}~]") then
            a = '"' .. a:gsub('"', '\\"') .. '"'
        end
        parts[#parts + 1] = a
    end
    return table.concat(parts, " ")
end

local MARKER = "%z" .. M.NONCE .. "{([%d;]*)}"

--- Render a line for the terminal: escape all control characters (see
--- `escape`) and turn this process's own SGR markers into escape sequences.
--- @param s any
--- @return string
function M.render(s)
    s = tostring(s)
    if not s:find("[%z\1-\8\11-\31\127\194]") then return s end
    local parts, pos = {}, 1
    while true do
        local a, b, code = s:find(MARKER, pos)
        if not a then break end
        parts[#parts + 1] = M.escape(s:sub(pos, a - 1))
        parts[#parts + 1] = "\27[" .. code .. "m"
        pos = b + 1
    end
    parts[#parts + 1] = M.escape(s:sub(pos))
    return table.concat(parts)
end

-- The report glyphs `ascii` folds (UTF-8 -> ASCII). Only these: any other
-- non-ASCII text is data (a user name in a path) and passes through.
local ASCII_FOLD = {
    ["\226\128\162"] = "*",   -- • bullet (actionable)
    ["\194\183"] = "-",       -- · middle dot (informational / separator)
    ["\226\156\147"] = "+",   -- ✓
    ["\226\156\151"] = "x",   -- ✗
    ["\226\128\147"] = "-",   -- – en dash
    ["\226\128\148"] = "-",   -- — em dash
    ["\226\134\146"] = "->",  -- →
    ["\226\128\166"] = "...", -- …
    ["\226\137\165"] = ">=",  -- ≥
    ["\226\137\164"] = "<=",  -- ≤
    ["\226\128\152"] = "'",   -- ‘
    ["\226\128\153"] = "'",   -- ’
    ["\226\128\156"] = '"',   -- “
    ["\226\128\157"] = '"',   -- ”
}

--- Fold the report glyphs in `s` to ASCII (`lw health`, spec §16.31: its
--- output must read in any console code page). The strings themselves stay
--- Unicode for the editor, which renders them itself.
--- @param s string
--- @return string
function M.ascii(s)
    s = tostring(s)
    if not s:find("[\194\226]") then return s end
    -- One UTF-8 character at a time: a lead byte and its continuation bytes.
    return (s:gsub("[\192-\247][\128-\191]*", function(ch) return ASCII_FOLD[ch] end))
end

return M
