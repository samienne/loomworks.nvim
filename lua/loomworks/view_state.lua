--- loomworks/view_state.lua — the one builder of the editor views'
--- state (spec §19.13 "Views", "Two sources, one shape"):
---
---   header(ws, err, opts)          loomworks.view.Header/1
---   projects_index(ws, opts)       loomworks.view.ProjectsIndex/1
---
--- Pure over the domain model: the daemon builds the views it serves on
--- `/views` with it (loomworks.daemon.views, which passes the session fields
--- and an id function), and the editor builds the same tables from its
--- in-process model when it holds no subscription (no session fields, no
--- ids: what only the daemon knows is optional in the shape and left out).
--- Never loads, never writes, reads no files.

local M = {}

--- @class loomworks.ViewHeader
--- @field root string
--- @field state "loaded"|"unloaded"|"error"|"refused"
--- @field name? string
--- @field active_profile? string the active profile's key
--- @field active_profile_id? string daemon only
--- @field config_set? string the active profile's configuration set
--- @field config_set_id? string daemon only
--- @field error? string the load failure (state error / refused)
--- @field diagnostics? "error"|"warn" the highest structural diagnostic
--- @field trust? "user"|"cache" the file a trust refusal refused
--- @field pid? integer daemon only
--- @field lw_version? string daemon only
--- @field session_generation? integer daemon only

--- @class loomworks.ViewProjectActive
--- @field configuration string
--- @field unit_id? string daemon only
--- @field tool_key? string
--- @field state string a ConfigUnitState (state-lifecycle.md §3.4)

--- @class loomworks.ViewProjectRecord
--- @field id? string daemon only
--- @field key string
--- @field label string
--- @field type string
--- @field path string root-relative, `/`-separated
--- @field abs_path string absolute, `/`-separated, not case-folded
--- @field active? loomworks.ViewProjectActive

--- @class loomworks.ViewProjectsIndex
--- @field projects loomworks.ViewProjectRecord[]

--- @class loomworks.ViewLoadError
--- @field message string
--- @field refused? boolean a trust, newer-schema or journal refusal
--- @field trust? "user"|"cache" the refused file of a trust refusal

--- @class loomworks.ViewOpts
--- @field root? string the workspace root (header; defaults to ws.root)
--- @field session? { pid: integer, lw_version: string, session_generation: integer } daemon only
--- @field id? fun(obj: table): string the opaque id of an entity (daemon only)

--- The model fields every header carries (the welcome header's, §19.13
--- "Header"): the loaded workspace's name and active profile, or its load
--- failure. Also `welcome.header`'s and `Workspace/1.header`'s
--- (loomworks.daemon.snapshot.header).
--- @param ws table|nil the live workspace (nil: not loaded)
--- @param err loomworks.ViewLoadError|nil the load failure, if any
--- @return table { state, name?, active_profile?, error? }
function M.base_header(ws, err)
    if ws then
        local ap = ws._active_profile
        return { state = "loaded", name = ws.name,
            active_profile = (ap and not ap._removed and ap.key) or ws._active_profile_key or nil }
    end
    if err and err.message then
        return { state = err.refused and "refused" or "error", error = err.message }
    end
    return { state = "unloaded" }
end

--- The live active profile object (nil: none, or a removed one).
local function active_profile(ws)
    local ap = ws and ws._active_profile
    if ap and not ap._removed then return ap end
    return nil
end

--- The highest severity among the workspace's structural diagnostics.
--- @param ws table
--- @return "error"|"warn"|nil
local function diagnostics_level(ws)
    if type(ws.diagnostics) ~= "function" then return nil end
    local ok, list = pcall(ws.diagnostics, ws)
    if not ok or type(list) ~= "table" then return nil end
    local level
    for _, d in ipairs(list) do
        if d.severity == "error" then return "error" end
        if d.severity == "warn" then level = "warn" end
    end
    return level
end

--- `loomworks.view.Header/1`'s state.
--- @param ws table|nil the live workspace (nil: not loaded)
--- @param err loomworks.ViewLoadError|nil the load failure, if any
--- @param opts? loomworks.ViewOpts
--- @return loomworks.ViewHeader
function M.header(ws, err, opts)
    opts = opts or {}
    local h = M.base_header(ws, err)
    h.root = opts.root or (ws and ws.root) or nil
    local s = opts.session
    if s then h.pid, h.lw_version, h.session_generation = s.pid, s.lw_version, s.session_generation end
    if h.state == "loaded" then
        local ap = active_profile(ws)
        if ap and opts.id and h.active_profile == ap.key then h.active_profile_id = opts.id(ap) end
        if ap and h.active_profile then
            local cs = ap._config_set_ref
            if cs and not cs._removed and cs.name then
                h.config_set = cs.name
                if opts.id then h.config_set_id = opts.id(cs) end
            elseif type(ap._configuration_set_name) == "string" then
                h.config_set = ap._configuration_set_name
            end
        end
        h.diagnostics = diagnostics_level(ws)
    elseif h.state == "refused" and err and (err.trust == "user" or err.trust == "cache") then
        h.trust = err.trust
    end
    return h
end

--- `p` joined onto `root`, `/`-separated (`.` or empty: the root itself).
local function join(root, p)
    root = (tostring(root or ""):gsub("\\", "/"):gsub("/+$", ""))
    if p == "" or p == "." then return root end
    return root .. "/" .. p
end

--- `loomworks.view.ProjectsIndex/1`'s state: one record per project, by key.
--- @param ws table|nil the live workspace (nil: not loaded → no projects)
--- @param opts? loomworks.ViewOpts
--- @return loomworks.ViewProjectsIndex
function M.projects_index(ws, opts)
    opts = opts or {}
    local out = {}
    if not ws then return { projects = out } end
    local ap = active_profile(ws)
    local root = ws.root or opts.root
    for _, p in pairs(ws._projects or {}) do
        if not p._removed and type(p.key) == "string" then
            local path = type(p.path) == "string" and p.path ~= "" and p.path or p.key
            path = (path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", ""))
            local rec = { key = p.key, label = p.key, type = tostring(p.type or "unknown"),
                path = path, abs_path = join(root, path) }
            if opts.id then rec.id = opts.id(p) end
            local pp = ap and p._module and ap:project(p.key) or nil
            local config = pp and pp:variant_name() or nil
            if type(config) == "string" then
                local unit = pp._config_unit
                if unit and unit._removed then unit = nil end
                local tool = pp:tool_object()
                rec.active = { configuration = config, state = pp:status(),
                    tool_key = tool and type(tool.key) == "string" and tool.key or nil,
                    unit_id = unit and opts.id and opts.id(unit) or nil }
            end
            out[#out + 1] = rec
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return { projects = out }
end

--- A canonical text of a view state (sorted keys): equal states have equal
--- signatures, whatever order their tables were built in.
--- @param v any
--- @return string
function M.signature(v)
    local t = type(v)
    if t ~= "table" then return t:sub(1, 1) .. tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. M.signature(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
end

return M
