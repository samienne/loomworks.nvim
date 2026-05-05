--- loomworks/progress/ninja.lua — Ninja progress parser.
--- Parses lines like "[2/10] Building CXX object src/main.cpp.o"
--- Used by cmake (with Ninja generator) and meson (Ninja is the default backend).
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
    local current, total = line:match("^%[(%d+)/(%d+)%]")
    if not current then return nil end

    local message = line:match("^%[%d+/%d+%]%s+(.*)")

    if message then
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
