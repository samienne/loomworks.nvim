--- loomworks/views.lua — the editor's view store (spec §19.13 "Views", "Two
--- sources, one shape"; step 5j part C).
---
--- Holds the editor's always-warm views, `loomworks.view.Header/1`
--- (`header`) and `loomworks.view.ProjectsIndex/1` (`projects`), from one of
--- two sources per view:
---
---   * the daemon's: while the observer holds a subscription to the view, the
---     table it took from the subscription's `initial`, then each `update`
---     (`get` after a `seq` gap). Rendered as it is — a daemon that has not
---     loaded the workspace reports `state = "unloaded"` and no projects;
---   * otherwise the one the editor builds from its in-process model with the
---     daemon's builder (loomworks.view_state, through the builder init.lua
---     registers): the same shape, without what only the daemon knows.
---
--- Readers (lualine through `buf_status`, the status page header,
--- `lw.buf_project`) see one table per view and never know its source. Plugin
--- side: requires nothing of the binary side.

local M = {}

--- @alias loomworks.ViewName "header"|"projects"

--- Per view: the daemon's table and the observer that holds it.
--- @type table<string, { owner: table, state: table }>
local daemon = {}

--- Per view: the in-process builder (registered by init.lua).
--- @type table<string, fun(): table|nil>
local builders = {}

--- @type fun()[]
local listeners = {}

local redraw_pending = false

--- A view may have changed: tell the listeners and redraw the statusline
--- (it reads the store; a running state it then shows starts the spinner).
--- The store calls it when a daemon view is set or cleared; init.lua calls it
--- when the in-process model may have changed (a task started or stopped, the
--- active profile or a build state changed), since an in-process view is
--- built on read and has no change of its own. Redraws coalesce: one per
--- event-loop turn however many changes.
function M.changed()
    for _, fn in ipairs(listeners) do pcall(fn) end
    if redraw_pending then return end
    redraw_pending = true
    vim.schedule(function()
        redraw_pending = false
        pcall(vim.cmd, "redrawstatus")
    end)
end
local changed = M.changed

--- Register the in-process builder of a view.
--- @param name loomworks.ViewName
--- @param fn fun(): table|nil
function M.set_builder(name, fn) builders[name] = fn end

--- Call `fn()` whenever a view may have changed (see `M.changed`).
--- @param fn fun()
function M.on_change(fn) listeners[#listeners + 1] = fn end

--- Adopt the daemon's full state of a view (an `initial`, `update` or `get`).
--- @param owner table the observer holding the subscription
--- @param name loomworks.ViewName
--- @param state table
function M.set(owner, name, state)
    if type(state) ~= "table" then return end
    daemon[name] = { owner = owner, state = state }
    changed()
end

--- Drop the daemon's tables `owner` holds (all, or the one view `name`): the
--- view is built in-process again.
--- @param owner table
--- @param name? loomworks.ViewName
--- @return boolean cleared whether `owner` held any of them
function M.clear(owner, name)
    local any = false
    for n, d in pairs(daemon) do
        if d.owner == owner and (name == nil or n == name) then
            daemon[n] = nil
            any = true
        end
    end
    if any then changed() end
    return any
end

--- Where a view comes from now.
--- @param name loomworks.ViewName
--- @return "daemon"|"in-process"
function M.source(name) return daemon[name] and "daemon" or "in-process" end

--- The daemon's table of a view while `owner` holds it, else nil.
--- @param owner table
--- @param name loomworks.ViewName
--- @return table|nil
function M.daemon_state(owner, name)
    local d = daemon[name]
    if d and d.owner == owner then return d.state end
    return nil
end

--- A view's current table: the daemon's, else built in-process (nil when no
--- builder is registered or it fails).
--- @param name loomworks.ViewName
--- @return table|nil
function M.get(name)
    local d = daemon[name]
    if d then return d.state end
    local b = builders[name]
    if not b then return nil end
    local ok, state = pcall(b)
    return ok and type(state) == "table" and state or nil
end

--- @return loomworks.ViewHeader|nil
function M.header() return M.get("header") end

--- @return loomworks.ViewProjectsIndex|nil
function M.projects_index() return M.get("projects") end

local is_win = vim.fn.has("win32") == 1

--- A path in the normalized form of §2.3: `/`-separated, no trailing
--- separator, lowercased on Windows.
--- @param p string
--- @return string
function M.normalize(p)
    p = vim.fs.normalize(p)
    return is_win and p:lower() or p
end

--- Canonical `abs_path` per record (records are replaced, never mutated).
local norm_cache = setmetatable({}, { __mode = "k" })

--- Normalized physical identity per normalized path spelling (a Windows 8.3
--- short name, a junction or symlink resolve to one path), bounded: cleared
--- when it grows past CANON_MAX entries.
local canon_cache, canon_count, CANON_MAX = {}, 0, 512

--- `path`'s real path when it exists, else its nearest existing ancestor's
--- real path joined with the rest (a buffer's file may not exist yet); nil
--- when nothing along it resolves.
--- @param path string
--- @return string|nil
local function realpath(path)
    local cur, tail = vim.fs.normalize(path), ""
    for _ = 1, 64 do
        local r = vim.uv.fs_realpath(cur)
        if r then return (r:gsub("\\", "/"):gsub("/+$", "")) .. tail end
        local parent, seg = cur:match("^(.*)/([^/]+)$")
        if not parent or parent == "" or parent:match("^%a:$") then return nil end
        tail = "/" .. seg .. tail
        cur = parent
    end
    return nil
end

--- `path` in the one canonical space every comparison here uses: its
--- physical identity (resolved through links and 8.3 short names),
--- normalized; its normalized spelling when nothing along it resolves.
--- Cached per spelling, so a hot path resolves each spelling once.
--- @param path string
--- @return string
local function canonical(path)
    local p = M.normalize(path)
    local c = canon_cache[p]
    if c == nil then
        local ok, r = pcall(realpath, path)
        c = ok and type(r) == "string" and M.normalize(r) or p
        if canon_count >= CANON_MAX then canon_cache, canon_count = {}, 0 end
        canon_cache[p], canon_count = c, canon_count + 1
    end
    return c
end

--- Whether canonical `p` is canonical `root` or lies under it (§19.13
--- "Views": equal, or followed by `/`).
--- @param root string
--- @param p string
--- @return boolean
local function in_root(root, p)
    return p == root or p:sub(1, #root + 1) == root .. "/"
end

--- The record of `index` whose `abs_path` is the longest prefix of `path` on
--- a separator boundary (§19.13 "Views": equal, or followed by `/`). Both
--- the path and every root are compared by their physical identity (a
--- Windows 8.3 short name, a junction or symlink — on either side — maps to
--- the folder it names), so a spelling that lies under an outer project but
--- resolves into an inner one maps to the inner one.
--- @param index loomworks.ViewProjectsIndex|nil
--- @param path string an absolute path
--- @return loomworks.ViewProjectRecord|nil
function M.match(index, path)
    if type(index) ~= "table" or type(index.projects) ~= "table" or type(path) ~= "string" or path == "" then
        return nil
    end
    if #index.projects == 0 then return nil end
    local p = canonical(path)
    local best, best_len = nil, -1
    for _, rec in ipairs(index.projects) do
        if type(rec) == "table" and type(rec.abs_path) == "string" then
            local prefix = norm_cache[rec]
            if not prefix then
                prefix = canonical(rec.abs_path)
                norm_cache[rec] = prefix
            end
            if #prefix > best_len and in_root(prefix, p) then
                best, best_len = rec, #prefix
            end
        end
    end
    return best
end

--- Whether `path` lies under `root` (separator-bounded), both compared by
--- their physical identity (as `match`).
--- @param root string
--- @param path string
--- @return boolean
function M.under(root, path)
    if type(root) ~= "string" or root == "" or type(path) ~= "string" or path == "" then return false end
    return in_root(canonical(root), canonical(path))
end

--- `lw.buf_project`: the ProjectsIndex record of a buffer's file.
--- @param bufnr? integer defaults to the current buffer
--- @return loomworks.ViewProjectRecord|nil
function M.buf_project(bufnr)
    return M.match(M.projects_index(), vim.api.nvim_buf_get_name(bufnr or 0))
end

local RUNNING = { configuring = true, building = true, deleting = true, cleaning = true }

--- The profile's overall state for the statusline icon, from the states of
--- the projects the active profile maps (§19.13: computed by the client).
--- Running and failed dominate so the actionable signal shows first.
--- @param index loomworks.ViewProjectsIndex
--- @return string|nil
function M.profile_state(index)
    local counts, total = {}, 0
    for _, rec in ipairs(index and index.projects or {}) do
        local a = rec.active
        if a then
            counts[a.state] = (counts[a.state] or 0) + 1
            total = total + 1
        end
    end
    local function n(s) return counts[s] or 0 end
    if total == 0 then return nil end
    if n("deleting") > 0 or n("cleaning") > 0 then return "deleting" end
    if n("configuring") > 0 or n("building") > 0 then
        return n("building") > 0 and "building" or "configuring"
    end
    if n("configure_failed") > 0 then return "failed_configure" end
    if n("build_failed") > 0 then return "failed_build" end
    if n("built") == total then return "built" end
    if n("configured") + n("built") == total then return "configured" end
    if n("unconfigured") == total then return "unconfigured" end
    return "mixed"
end

--- Whether a state animates (a running task).
--- @param state string|nil
--- @return boolean
function M.is_running(state) return state ~= nil and RUNNING[state] == true end

--- `lw.buf_status` from the two views: nil unless the header is `loaded` and
--- a record matches `path`.
--- @param header loomworks.ViewHeader|nil
--- @param index loomworks.ViewProjectsIndex|nil
--- @param path string the buffer's file
--- @return loomworks.BufStatus|nil
function M.status_of(header, index, path)
    if type(header) ~= "table" or header.state ~= "loaded" then return nil end
    local rec = M.match(index, path)
    if not rec then return nil end
    local a = rec.active
    return {
        profile_key = header.active_profile,
        set_name = header.config_set,
        tool_key = a and a.tool_key or nil,
        project = rec.key,
        configuration = a and a.configuration or nil,
        status = a and a.state or nil,
        profile_state = header.active_profile and M.profile_state(index) or nil,
        diagnostic_severity = header.diagnostics,
    }
end

--- Test seam: forget the daemon's tables (builders and listeners stay).
function M._reset() daemon = {} end

return M
