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

return M
