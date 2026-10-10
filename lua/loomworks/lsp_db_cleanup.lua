--- Safety checks for removing module-owned LSP databases (spec §4.6 *Owned
--- LSP database cleanup*, §8.4 `lsp_database_root` / `lsp_database_dir`).
---
--- A module that owns an LSP database (e.g. cmake's generated
--- compile_commands.json) keeps it under `<root>/.nvim/cache/<area>/…`, a
--- mirror derived from a build directory. This file holds the pure-ish path
--- checks (no deletion itself): callers delete only what these functions
--- approve, with the link-safe `io.rm_rf` / `io.rm_rf_async`.
---
--- Rules enforced here (spec §4.6 rules 3–5):
---   * nil / empty root, area segment or mirror → nothing to remove;
---   * the area segment is one plain path segment (no separators, not `.`
---     or `..`, no drive colon);
---   * the mirror lies STRICTLY inside `<root>/.nvim/cache/<area>/`
---     (normalized, separator-bounded) and has no `.` / `..` segment;
---   * `.nvim`, `.nvim/cache`, the area dir, every directory between the area
---     and the mirror, and the mirror itself are real directories (lstat: a
---     symlink or junction refuses), and the mirror's realpath lies strictly
---     under the realpath of the area `<root>/.nvim/cache/<area>`
---     (separator-bounded, normalized);
---   * on Windows, no segment ends in "." or " " (Win32 trims them, so
---     `App/.. ` would name the area itself).
--- A path that does not exist (at any level) is "absent": nothing to remove.

local M = {}

--- Windows path semantics (trailing dot/space trimming). Test seam.
M._win = vim.fn.has("win32") == 1

local uv = vim.uv or vim.loop

--- Fold backslashes to "/" and drop trailing slashes.
--- @param p string
--- @return string
local function slash(p)
    return (p:gsub("\\", "/"):gsub("/+$", ""))
end

--- Default comparison normalizer: "/" separators, lowercased on Windows.
local IS_WIN = vim.fn.has("win32") == 1
local function default_normalize(p)
    p = slash(p)
    return IS_WIN and p:lower() or p
end

--- @param p string
--- @return boolean
local function has_dot_segment(p)
    for seg in (p .. "/"):gmatch("([^/]*)/") do
        if seg == "." or seg == ".." then return true end
    end
    return false
end

--- Whether any segment ends in "." or " ". Win32 path parsing silently trims
--- those, so `App/.. ` is opened as `App/..` and `App.` as `App`: a segment
--- that passes the plain checks could name a different (parent) directory.
--- Only meaningful on Windows (`M._win`, overridable in tests); elsewhere
--- such names are ordinary.
--- @param p string
--- @return boolean
local function has_win_trimmed_segment(p)
    if not M._win then return false end
    for seg in (p .. "/"):gmatch("([^/]*)/") do
        if seg:match("[%. ]$") then return true end
    end
    return false
end

--- Strictly under: `path` is a descendant of `prefix` (separator-bounded).
--- @param path string
--- @param prefix string
--- @return boolean
local function strictly_under(path, prefix)
    return path:sub(1, #prefix + 1) == prefix .. "/"
end

--- @param p string
--- @return boolean
local function is_absolute(p)
    return p:match("^/") ~= nil or p:match("^%a:/") ~= nil
end

--- Whether `seg` is a valid owned-database area name: one plain path segment.
--- @param seg any
--- @return boolean
function M.valid_segment(seg)
    return type(seg) == "string" and seg ~= "" and seg ~= "." and seg ~= ".."
        and not seg:find("[/\\:]") and not has_win_trimmed_segment(seg)
end

--- lstat `p`: "absent" when missing, "dir" for a real directory, "other" for
--- anything else (file, symlink, junction).
--- @param p string
--- @return "absent"|"dir"|"other"
local function kind(p)
    local st = uv.fs_lstat(p)
    if not st then return "absent" end
    return st.type == "directory" and "dir" or "other"
end

--- The realpath of `p` in comparison form, or nil.
--- @param p string
--- @param normalize fun(p: string): string
--- @return string|nil
local function real(p, normalize)
    local rp = uv.fs_realpath(p)
    if not rp then return nil end
    return normalize(slash(rp))
end

--- Check `.nvim` and `.nvim/cache` (and the area dir) are real directories.
--- @return "ok"|"absent"|nil status, string|nil reason
local function check_parents(root, seg)
    for _, p in ipairs({ root .. "/.nvim", root .. "/.nvim/cache", root .. "/.nvim/cache/" .. seg }) do
        local k = kind(p)
        if k == "absent" then return "absent" end
        if k ~= "dir" then return nil, p .. " is a link or not a directory" end
    end
    return "ok"
end

--- Check a module's whole owned-database area for the nuke (spec §4.6 last
--- paragraph, ui §1.11 check 4): the target must be exactly the direct child
--- `<root>/.nvim/cache/<seg>` and neither it, `.nvim/cache` nor `.nvim` may be
--- a link or junction; its realpath must lie under `.nvim`'s.
--- @param root string|nil absolute workspace root
--- @param seg string|nil the module's `lsp_database_root`
--- @param normalize? fun(p: string): string
--- @return "ok"|"absent"|nil status, string|nil area_or_reason
function M.check_area(root, seg, normalize)
    normalize = normalize or default_normalize
    if type(root) ~= "string" or root == "" or seg == nil or seg == "" then return "absent" end
    if not M.valid_segment(seg) then
        return nil, "invalid owned LSP database area name '" .. tostring(seg) .. "'"
    end
    root = slash(root)
    if not is_absolute(root) or has_dot_segment(root) then
        return nil, "workspace root is not a plain absolute path: " .. root
    end
    local area = root .. "/.nvim/cache/" .. seg
    local st, why = check_parents(root, seg)
    if st ~= "ok" then return st, why end
    local rnvim, rarea = real(root .. "/.nvim", normalize), real(area, normalize)
    if not rnvim or not rarea or not strictly_under(rarea, rnvim) then
        return nil, area .. " does not resolve inside " .. root .. "/.nvim"
    end
    return "ok", area
end

--- Check one build directory's owned-database mirror (spec §4.6 rules 3–5).
--- @param root string|nil absolute workspace root
--- @param seg string|nil the module's `lsp_database_root`
--- @param mirror string|nil the module's `lsp_database_dir(ctx)` result
--- @param normalize? fun(p: string): string comparison normalizer
--- @return "ok"|"absent"|nil status, string|nil path_or_reason
---   "ok" + the mirror path (slash form) when it may be removed; "absent"
---   when there is nothing to remove; nil + reason when refused.
--- @return string|nil area the area directory (slash form) on "ok"
function M.check_mirror(root, seg, mirror, normalize)
    normalize = normalize or default_normalize
    -- Rule 3: nil / empty anything → nothing to remove, never a fallback.
    if type(root) ~= "string" or root == "" or seg == nil or seg == ""
            or type(mirror) ~= "string" or mirror == "" then
        return "absent"
    end
    if not M.valid_segment(seg) then
        return nil, "invalid owned LSP database area name '" .. tostring(seg) .. "'"
    end
    root = slash(root)
    local raw = slash(mirror)
    -- Rule 4: plain absolute paths, no "." / ".." anywhere (checked on the raw
    -- form: a normalizer may collapse them), strictly inside the area.
    if not is_absolute(root) or has_dot_segment(root) then
        return nil, "workspace root is not a plain absolute path: " .. root
    end
    if not is_absolute(raw) or has_dot_segment(raw) or has_win_trimmed_segment(raw) then
        return nil, "refusing owned LSP database path with a relative, '.'/'..' or"
            .. " trailing-dot/space segment: " .. mirror
    end
    local area = root .. "/.nvim/cache/" .. seg
    local n_area, n_mirror = normalize(area), normalize(raw)
    if has_dot_segment(n_mirror) or not strictly_under(n_mirror, n_area) then
        return nil, "refusing owned LSP database path outside " .. area .. "/: " .. mirror
    end
    -- Rule 5: no links anywhere from .nvim down to the mirror.
    local st, why = check_parents(root, seg)
    if st ~= "ok" then return st, why end
    -- Walk area → mirror one segment at a time (lstat each). The tail comes
    -- from the normalized form the boundary check approved (lowercased on
    -- Windows, where the filesystem is case-insensitive).
    local tail = n_mirror:sub(#n_area + 2)
    if tail == "" then return nil, "refusing the owned LSP database area itself: " .. mirror end
    local cur = area
    for part in tail:gmatch("[^/]+") do
        cur = cur .. "/" .. part
        local k = kind(cur)
        if k == "absent" then return "absent" end
        if k ~= "dir" then return nil, cur .. " is a link or not a directory" end
    end
    -- The mirror must resolve strictly inside the area's own realpath (not
    -- merely inside .nvim): removing it may never take the area, a sibling
    -- area, or anything else under .nvim with it.
    local rarea, rmirror = real(area, normalize), real(cur, normalize)
    if not rarea or not rmirror or not strictly_under(rmirror, rarea) then
        return nil, cur .. " does not resolve inside " .. area
    end
    return "ok", cur, area
end

return M
