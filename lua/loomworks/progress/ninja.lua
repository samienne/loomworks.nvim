--- loomworks/progress/ninja.lua — Ninja progress parser.
--- Parses lines like "[2/10] Building CXX object src/main.cpp.o"
--- Used by cmake (with Ninja generator) and meson (Ninja is the default backend).

--- @param line string
--- @return loomworks.ProgressUpdate|nil
local function parse(line)
  local current, total = line:match("^%[(%d+)/(%d+)%]")
  if not current then return nil end

  local message = line:match("^%[%d+/%d+%]%s+(.*)")

  return {
    current = tonumber(current),
    total = tonumber(total),
    message = message,
  }
end

return parse
