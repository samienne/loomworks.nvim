-- Search-path hygiene for the host bootstrap (main.lua).
--
-- LuaJIT's default package.path / package.cpath begin with `./?.lua` / `./?.dll`
-- (`.\?.lua` on Windows), and on Windows also search `<exe dir>\lua\?.lua`
-- (the `!` entries). The host resolves loomworks' own code through dedicated
-- searchers, so the path searchers only ever see names nothing of ours
-- provides — and for those, a file relative to the current directory (a
-- cloned repository) or next to the executable must never be picked up. This
-- module computes the sanitized search strings; it is pure (no I/O) so the
-- standalone tests can exercise it directly.

local M = {}

--- Is `entry` (one `;`-separated template) an absolute path?
--- Windows: a drive-rooted `C:\` / `C:/` path or a UNC `\\server\share` path —
--- NOT a bare `\foo` (rooted at the *current* drive). POSIX: a leading `/`.
--- @param entry string
--- @param is_windows boolean
--- @return boolean
function M.is_absolute(entry, is_windows)
  if type(entry) ~= "string" or entry == "" then return false end
  if is_windows then
    return entry:match("^%a:[/\\]") ~= nil or entry:match("^[/\\][/\\]%w") ~= nil
  end
  return entry:sub(1, 1) == "/"
end

--- Normalize a directory for a case-/separator-insensitive prefix test.
local function norm(p, is_windows)
  p = p:gsub("\\", "/"):gsub("/+$", "")
  if is_windows then p = p:lower() end
  return p
end

--- Sanitize a `package.path` / `package.cpath` string: drop every entry that
--- is empty, relative (`./?.lua`, `?.lua`, `lua/?.lua`, an unexpanded `!`
--- template, ...) or rooted inside `opts.exclude_dirs` (the executable's own
--- directory). Absolute system entries are kept in order. Returns the new
--- string and the list of removed entries (for diagnostics/tests).
--- @param s string
--- @param opts? { is_windows?: boolean, exclude_dirs?: string[] }
--- @return string sanitized, string[] removed
function M.sanitize(s, opts)
  opts = opts or {}
  local is_windows = opts.is_windows
  if is_windows == nil then is_windows = package.config:sub(1, 1) == "\\" end
  local excl = {}
  for _, d in ipairs(opts.exclude_dirs or {}) do
    if type(d) == "string" and d ~= "" then excl[#excl + 1] = norm(d, is_windows) end
  end
  local keep, removed = {}, {}
  for entry in (tostring(s or "") .. ";"):gmatch("([^;]*);") do
    local ok = M.is_absolute(entry, is_windows)
    if ok then
      local n = norm(entry, is_windows)
      for _, d in ipairs(excl) do
        if n == d or n:sub(1, #d + 1) == d .. "/" then ok = false; break end
      end
    end
    if ok then keep[#keep + 1] = entry
    elseif entry ~= "" then removed[#removed + 1] = entry end
  end
  return table.concat(keep, ";"), removed
end

return M
