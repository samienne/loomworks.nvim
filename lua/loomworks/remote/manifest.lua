--- loomworks/remote/manifest.lua — the staging manifest of a remote run
--- (spec §18.4) and the `device` block helpers (spec §18.9).
---
--- The manifest is the union of: the artifact; the shared/module-library
--- artifacts of project targets the artifact's target depends on
--- (transitively, as the module reported them — nothing is guessed); the
--- runner's platform runtime files (staged beside the artifact); the `device`
--- block's `stage` globs; and its `archive` globs (one archive per pattern
--- when the runner supports archives, else staged file by file). Every path is
--- kept build-directory-relative, so the device mirror keeps the build layout.

local M = {}

local function uv() return vim.uv or vim.loop end

--- Directory never staged: the host-side run folders (§18.5).
M.RUNS_DIR = ".device-runs"

local function norm(p) return (tostring(p):gsub("\\", "/"):gsub("/+$", "")) end

--- Canonical host path (symlinks + 8.3 names resolved), forward slashes.
local function canon(p)
    local r = uv().fs_realpath(p)
    return norm(r or p)
end
M.canon = canon

local function is_abs(p)
    return p:match("^/") or p:match("^%a:") or p:match("^\\\\") ~= nil
end

--- Is `rel` a clean relative path (no empty, "." or ".." segment, not
--- absolute, no NUL / line break)?
--- @param rel any
--- @return boolean
function M.clean_rel(rel)
    if type(rel) ~= "string" or rel == "" or rel:find("[%z\r\n]") then return false end
    rel = rel:gsub("\\", "/")
    if is_abs(rel) then return false end
    for seg in (rel .. "/"):gmatch("([^/]*)/") do
        if seg == "" or seg == "." or seg == ".." then return false end
    end
    return true
end

--- Validate one stage/archive pattern (spec §18.4): relative, never absolute,
--- no "." / ".." segment (so its fixed prefix cannot escape the build dir).
--- @param pat any
--- @return boolean ok, string|nil err
function M.validate_pattern(pat)
    if type(pat) ~= "string" or pat == "" then return false, "pattern must be a non-empty string" end
    local p = pat:gsub("\\", "/")
    if is_abs(p) or p:match("^~") then return false, "pattern '" .. pat .. "' must be relative to the build directory" end
    for seg in (p .. "/"):gmatch("([^/]*)/") do
        if seg == ".." or seg == "." then
            return false, "pattern '" .. pat .. "' must not contain '.' or '..' segments"
        end
        if seg == "" then return false, "pattern '" .. pat .. "' has an empty segment" end
    end
    if p:find("[%z\r\n]") then return false, "pattern '" .. pat .. "' contains a control character" end
    return true
end

--- Validate a `device` block (project or launch level). Unknown keys are an
--- error so a typo never silently drops a stage set.
--- @param block any
--- @param label string
--- @return boolean ok, string|nil err
function M.validate_block(block, label)
    if block == nil then return true end
    if type(block) ~= "table" then return false, label .. ": device must be an object" end
    local known = { stage = true, archive = true, env = true, working_dir = true }
    for k in pairs(block) do
        if not known[k] then
            return false, label .. ": unknown device field '" .. tostring(k)
                .. "' (known: stage, archive, env, working_dir)"
        end
    end
    for _, key in ipairs({ "stage", "archive" }) do
        local list = block[key]
        if list ~= nil then
            if type(list) ~= "table" then return false, label .. ": device." .. key .. " must be a list of globs" end
            for _, pat in ipairs(list) do
                local ok, err = M.validate_pattern(pat)
                if not ok then return false, label .. ": device." .. key .. ": " .. err end
            end
        end
    end
    if block.env ~= nil then
        if type(block.env) ~= "table" then return false, label .. ": device.env must be an object" end
        for k, v in pairs(block.env) do
            if type(k) ~= "string" or not k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                return false, label .. ": device.env name '" .. tostring(k) .. "' is not a portable identifier"
            end
            if type(v) ~= "string" and type(v) ~= "number" then
                return false, label .. ": device.env." .. k .. " must be a string"
            end
        end
    end
    if block.working_dir ~= nil and not M.clean_rel(block.working_dir) and block.working_dir ~= "." then
        return false, label .. ": device.working_dir must be a build-directory-relative path"
    end
    return true
end

--- Validate a launch configuration's `device_log` table (spec §18.13): an
--- opaque option map; core only checks it is a flat map of scalars.
--- @return boolean ok, string|nil err
function M.validate_log_options(opts, label)
    if opts == nil then return true end
    if type(opts) ~= "table" then return false, label .. ": device_log must be an object" end
    for k, v in pairs(opts) do
        if type(k) ~= "string" then return false, label .. ": device_log keys must be strings" end
        local t = type(v)
        if t ~= "string" and t ~= "number" and t ~= "boolean" then
            return false, label .. ": device_log." .. k .. " must be a string, number or boolean"
        end
    end
    return true
end

--- The effective device block: the launch-level block replaces the
--- project-level one field by field (spec §18.9).
--- @param project_block table|nil
--- @param launch_block table|nil
--- @return table
function M.effective_block(project_block, launch_block)
    local out = {}
    for _, src in ipairs({ project_block or {}, launch_block or {} }) do
        for _, k in ipairs({ "stage", "archive", "env", "working_dir" }) do
            if src[k] ~= nil then out[k] = src[k] end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Globbing
-- ---------------------------------------------------------------------------

--- Compile one glob SEGMENT to an anchored Lua pattern (`*` / `?` never
--- cross a "/": segments are matched one at a time).
local function segment_pattern(seg)
    local out = { "^" }
    for i = 1, #seg do
        local c = seg:sub(i, i)
        if c == "*" then out[#out + 1] = ".*"
        elseif c == "?" then out[#out + 1] = "."
        else out[#out + 1] = (c:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")) end
    end
    out[#out + 1] = "$"
    return table.concat(out)
end

local function split(p)
    local t = {}
    for seg in p:gmatch("[^/]+") do t[#t + 1] = seg end
    return t
end

--- Does build-relative `rel` match `glob`? `**` spans zero or more directory
--- levels; `*` and `?` stay within one segment.
--- @param glob string
--- @param rel string
--- @return boolean
function M.glob_match(glob, rel)
    local g, p = split((glob:gsub("\\", "/"))), split(rel)
    local pats = {}
    local function seg_ok(i, j)
        if not pats[i] then pats[i] = segment_pattern(g[i]) end
        return p[j]:match(pats[i]) ~= nil
    end
    local function match(i, j)
        if i > #g then return j > #p end
        if g[i] == "**" then
            for k = j, #p + 1 do
                if match(i + 1, k) then return true end
            end
            return false
        end
        if j > #p then return false end
        return seg_ok(i, j) and match(i + 1, j + 1)
    end
    return match(1, 1)
end

--- The fixed directory prefix of a glob (segments before the first wildcard).
local function fixed_prefix(glob)
    local segs = {}
    for seg in glob:gsub("\\", "/"):gmatch("[^/]+") do
        if seg:find("[%*%?%[]") then break end
        segs[#segs + 1] = seg
    end
    -- A pattern without wildcards names a file: its prefix is its directory.
    if #segs > 0 and not glob:find("[%*%?%[]") then segs[#segs] = nil end
    return table.concat(segs, "/")
end

--- Regular files under `root/prefix`, as build-relative paths. Symlinked
--- directories are not followed; the run folders are never listed.
local function walk(root, prefix, acc)
    local dir = prefix == "" and root or (root .. "/" .. prefix)
    local h = uv().fs_scandir(dir)
    if not h then return end
    while true do
        local name, typ = uv().fs_scandir_next(h)
        if not name then break end
        local rel = prefix == "" and name or (prefix .. "/" .. name)
        if not (prefix == "" and name == M.RUNS_DIR) then
            local full = root .. "/" .. rel
            local st = uv().fs_lstat(full)
            if st and st.type == "directory" then
                walk(root, rel, acc)
            elseif st and st.type == "file" then
                acc[#acc + 1] = rel
            elseif st and st.type == "link" then
                local tst = uv().fs_stat(full)
                if tst and tst.type == "file" then acc[#acc + 1] = rel end
            end
        end
    end
end

--- Files of the build dir matching a glob.
--- @param root string canonical build dir
--- @param glob string validated pattern
--- @return string[] rel paths (sorted)
function M.glob(root, glob)
    local files = {}
    walk(root, fixed_prefix(glob), files)
    local out = {}
    for _, rel in ipairs(files) do
        if M.glob_match(glob, rel) then out[#out + 1] = rel end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------------

--- File names treated as shared libraries when collecting the loader search
--- directories (`library_dirs`, spec §18.5).
function M.is_shared_library(rel)
    local base = rel:match("([^/]+)$") or rel
    return base:match("%.so$") ~= nil or base:match("%.so%.[%d%.]+$") ~= nil
        or base:match("%.dylib$") ~= nil or base:lower():match("%.dll$") ~= nil
end

local function dirname(rel) return rel:match("^(.*)/[^/]+$") or "" end

--- Build-relative path of an absolute host path inside `root`, or nil.
local function rel_of(root, abs)
    local a = canon(abs)
    local r = root
    if package.config:sub(1, 1) == "\\" then a, r = a:lower(), r:lower() end
    if a:sub(1, #r + 1) == r .. "/" then return canon(abs):sub(#root + 2) end
    return nil
end
M.rel_of = rel_of

--- Derived runtime libraries: shared/module-library artifacts of the project
--- targets `target` depends on, transitively.
local function derived_libraries(unit, target, build_dir)
    local targets = unit and unit.targets or {}
    local out, seen = {}, {}
    local function visit(t)
        for _, dep in ipairs(t.dependencies or {}) do
            if not seen[dep] then
                seen[dep] = true
                local d = targets[dep]
                if d then
                    if (d.type == "shared_library" or d.type == "module_library") and d.artifact then
                        out[#out + 1] = { id = dep, artifact = d.artifact }
                    end
                    visit(d)
                end
            end
        end
    end
    visit(target or {})
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- @class loomworks.Manifest
--- @field root string canonical host build directory
--- @field artifact string build-relative path of the program
--- @field files { rel: string, abs: string, kind: string }[] staged file by file (sorted)
--- @field archives { key: string, members: { rel: string, abs: string }[] }[]
--- @field library_rels string[] build-relative dirs holding staged shared libraries (sorted)

--- Build the manifest.
--- @param o { build_dir: string, artifact: string, unit?: table, target?: table, runner: loomworks.Runner, tool?: table, device?: table }
--- @return loomworks.Manifest|nil manifest, string|nil err
function M.build(o)
    if not o.build_dir or o.build_dir == "" then return nil, "no build directory" end
    local root = canon(o.build_dir)
    local art_rel = rel_of(root, o.artifact)
    if not art_rel then
        return nil, "artifact " .. tostring(o.artifact) .. " is outside the build directory " .. root
            .. " — it cannot be staged by relative path"
    end
    if not uv().fs_stat(o.artifact) then return nil, "artifact " .. o.artifact .. " does not exist (build it first)" end
    local files, by_rel = {}, {}
    local function add(rel, abs, kind)
        if by_rel[rel] then return true end
        by_rel[rel] = true
        files[#files + 1] = { rel = rel, abs = abs, kind = kind }
        return true
    end
    add(art_rel, root .. "/" .. art_rel, "artifact")

    for _, lib in ipairs(derived_libraries(o.unit, o.target, root)) do
        local abs = require("loomworks.paths").artifact_path(root, lib.artifact)
        local rel = rel_of(root, abs)
        if not rel then
            return nil, string.format("library %s resolves outside the build directory (%s); "
                .. "place a copy inside the build tree and select it with a device.stage pattern",
                lib.id, abs)
        end
        if not uv().fs_stat(abs) then
            return nil, "library " .. lib.id .. " (" .. abs .. ") does not exist (build it first)"
        end
        add(rel, abs, "library")
    end

    if o.runner and o.runner.runtime_files then
        local ok, rt = pcall(o.runner.runtime_files, o.tool)
        if not ok then return nil, "device runner runtime_files failed: " .. tostring(rt) end
        for _, e in ipairs(type(rt) == "table" and rt or {}) do
            local lp, r = e["local"], e.relative
            if type(lp) ~= "string" or not is_abs(lp) then
                return nil, "device runner runtime file has no absolute local path"
            end
            if not M.clean_rel(r) then
                return nil, "device runner runtime file '" .. tostring(r) .. "' has an invalid relative path"
            end
            if not uv().fs_stat(lp) then
                return nil, "platform runtime file " .. lp .. " does not exist"
            end
            local d = dirname(art_rel)
            add((d ~= "" and (d .. "/") or "") .. r:gsub("\\", "/"), lp, "runtime")
        end
    end

    local block = o.device or {}
    for _, pat in ipairs(block.stage or {}) do
        local ok, err = M.validate_pattern(pat)
        if not ok then return nil, "device.stage: " .. err end
        for _, rel in ipairs(M.glob(root, pat)) do add(rel, root .. "/" .. rel, "stage") end
    end

    local archives = {}
    for _, pat in ipairs(block.archive or {}) do
        local ok, err = M.validate_pattern(pat)
        if not ok then return nil, "device.archive: " .. err end
        local members = {}
        for _, rel in ipairs(M.glob(root, pat)) do
            if not by_rel[rel] then
                if o.runner and o.runner.archive then
                    by_rel[rel] = true
                    members[#members + 1] = { rel = rel, abs = root .. "/" .. rel }
                else
                    add(rel, root .. "/" .. rel, "archive")
                end
            end
        end
        if #members > 0 then archives[#archives + 1] = { key = pat, members = members } end
    end

    table.sort(files, function(a, b) return a.rel < b.rel end)
    local lib_dirs, seen = {}, {}
    local function lib(rel)
        if M.is_shared_library(rel) then
            local d = dirname(rel)
            if not seen[d] then seen[d] = true; lib_dirs[#lib_dirs + 1] = d end
        end
    end
    for _, f in ipairs(files) do if f.kind ~= "artifact" then lib(f.rel) end end
    for _, a in ipairs(archives) do for _, m in ipairs(a.members) do lib(m.rel) end end
    table.sort(lib_dirs)
    return {
        root = root, artifact = art_rel, files = files, archives = archives, library_rels = lib_dirs,
    }
end

-- ---------------------------------------------------------------------------
-- Device-side paths
-- ---------------------------------------------------------------------------

--- A device path segment derived from a name (workspace / unit identity):
--- anything outside `[A-Za-z0-9._-]` becomes "_", and "." / ".." are escaped.
function M.segment(name)
    local s = tostring(name or "_"):gsub("[^%w%._%-]", "_")
    if s == "" or s == "." or s == ".." then s = "_" .. s end
    return s
end

--- Longest workspace segment kept verbatim; a longer name becomes a readable
--- prefix + a hash of the name.
M.WS_SEGMENT_MAX = 24

--- The workspace segment of the device roots (spec §18.4): the sanitized name
--- when short, else its first 15 characters + "-" + 8 hex digits of its hash.
--- @param name string
--- @return string
function M.workspace_segment(name)
    local s = M.segment(name)
    if #s <= M.WS_SEGMENT_MAX then return s end
    return s:sub(1, 15) .. "-" .. vim.fn.sha256(tostring(name)):sub(1, 8)
end

--- The unit segment of the device roots (spec §18.4): a short readable prefix
--- (the unit identity's last path component, sanitized, at most 12 characters)
--- + "-" + the first 10 hex digits of the identity's hash. Deterministic (the
--- sync record and digest checks key on it) and short: devices truncate a
--- process name — the program's path — at 128 bytes.
--- @param unit_id string
--- @return string
function M.unit_segment(unit_id)
    local id = tostring(unit_id or "_")
    local last = id:gsub("[/\\]+$", ""):match("([^/\\]+)$") or id
    local prefix = M.segment(last):sub(1, 12):gsub("[%._%-]+$", "")
    if prefix == "" or prefix:match("^%.") then prefix = "u" .. prefix end
    return prefix .. "-" .. vim.fn.sha256(id):sub(1, 10)
end

--- The device-side roots for a workspace + unit: the workspace prefix (the
--- only tree core ever asks a device to delete in, §18.12) and the unit's
--- staging root.
--- @param staging_base string
--- @param ws_name string
--- @param unit_id string
--- @return string ws_prefix, string unit_root
function M.device_roots(staging_base, ws_name, unit_id)
    local base = staging_base:gsub("/+$", "")
    local ws_prefix = base .. "/" .. M.workspace_segment(ws_name)
    return ws_prefix, ws_prefix .. "/" .. M.unit_segment(unit_id)
end

--- Is a device path inside `prefix` (separator boundary, after normalising
--- "//", and never containing "." / ".." segments)? (§18.12)
--- @param path string
--- @param prefix string
--- @return boolean
function M.device_path_under(path, prefix)
    if type(path) ~= "string" or type(prefix) ~= "string" or path:find("[%z\r\n]") then return false end
    local p = path:gsub("/+", "/"):gsub("/$", "")
    local q = prefix:gsub("/+", "/"):gsub("/$", "")
    if q == "" or not q:match("^/") then return false end
    for seg in p:gmatch("[^/]+") do
        if seg == "." or seg == ".." then return false end
    end
    return p == q or p:sub(1, #q + 1) == q .. "/"
end

return M
