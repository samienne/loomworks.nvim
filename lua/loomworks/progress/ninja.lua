--- loomworks/progress/ninja.lua — Ninja progress parser.
--- Parses lines containing "[N/M] description" anywhere on the line.
--- Used by cmake (Ninja generator), meson (Ninja backend), and the
--- shell module for projects that drive ninja-flavored output.
---
--- The `[N/M]` token is matched anywhere, not just at start of line,
--- because real-world build wrappers commonly prefix every line with
--- their own tags — e.g., a script that pipes ninja through a
--- formatter and emits `[INFO] [NINJA] [10/20] Building ...`. The
--- progress signal is the `[N/M]` regardless of what comes before it.
---
--- The trailing description gets a structural compaction: if the
--- last whitespace-delimited token is a path (contains `/` or `\`),
--- only its basename is kept. So
---   "Building CXX object src/CMakeFiles/foo.dir/path/file.cpp.o"
--- becomes
---   "Building CXX object file.cpp.o"
--- which keeps the verb ("Building CXX object") informative while
--- dropping the deep-path noise that was making the fidget popup
--- balloon to the full window width on real-world projects.
--- Single-token messages, custom-command strings, and tokens
--- without path separators pass through unchanged.

--- @param line string
--- @return loomworks.ProgressUpdate|nil
local function parse(line)
    -- Find `[N/M]` anywhere; the trailing text after it (after any
    -- whitespace) is the message. Lua's `match` returns the leftmost
    -- match, which is exactly what we want — non-numeric prefixes
    -- like `[INFO]` can't accidentally match the `%d+/%d+` pattern.
    local current, total, message =
        line:match("%[(%d+)/(%d+)%]%s*(.*)$")
    if not current then return nil end

    if message and message ~= "" then
        local prefix, last = message:match("^(.-)%s+(%S+)$")
        if last and last:find("[/\\]") then
            local basename = last:match("[^/\\]+$")
            if basename and basename ~= "" then
                message = prefix .. " " .. basename
            end
        end
    end

    return {
        current = tonumber(current),
        total = tonumber(total),
        message = message,
    }
end

return parse
