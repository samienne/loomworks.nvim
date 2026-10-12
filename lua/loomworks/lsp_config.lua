--- loomworks/lsp_config.lua — the LSP configuration state (spec §9.2 "Where
--- the entries come from", daemon.md §19.16 "LSP configuration", §19.20
--- `LspConfig/1`): per project its module's `lsp_configs` entries with
--- `db_state`, `db_dir` and `db_rev`, the working copy's per-server
--- options, and whether the active profile's owned databases are ready.
---
--- Host-neutral (pure Lua, no `vim.*`): the editor's LSP layer reads it
--- in-process through loomworks/lsp_source.lua, and the workspace daemon
--- serves the same shape (`LspConfig/1.get`, step 5l part B). Starting and
--- stopping servers, the integrations and their withhold reasons stay the
--- editor's (loomworks/lsp.lua, integrations/lsp/*).

local M = {}

--- An entry of the state: the module's `lsp_configs` entry
--- (`loomworks.LspConfigEntry`, types.lua) with the core fields filled in.
--- Every other field is the module's, passed through unread (binary,
--- binary_required, compile_commands_dir, a module's own build_dir,
--- import_paths, ...).
--- @class loomworks.LspStateEntry : loomworks.LspConfigEntry
--- @field db_state "ready"|"unconfigured" the module's, else derived (§9.1)
--- @field db_dir? string the directory whose owned database the entry reads: the module's when it sets one, else the project's active build dir (absent when none)
--- @field db_rev integer raised each time the owned database of `db_dir` is (re)written

--- @class loomworks.LspConfigProject
--- @field project string the project key
--- @field id? string opaque id, only from the daemon (§19.13)
--- @field path? string the project's path relative to the root
--- @field entries loomworks.LspStateEntry[]

--- @class loomworks.LspConfigState
--- @field state "loaded"|"unloaded"|"error"|"refused" the workspace's, as `view.Header/1`
--- @field ready boolean the active profile's owned databases have settled (§9.7)
--- @field projects loomworks.LspConfigProject[] ascending key order
--- @field options table<string, table<string, any>> per-server options (user.json `lsp`, defaults applied)

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

local IS_WIN = package.config:sub(1, 1) == "\\"

--- A path in comparable form: `/`-separated, no trailing separator,
--- lowercased on Windows (§2.3).
--- @param p string
--- @return string
function M.norm(p)
    p = p:gsub("\\", "/")
    if #p > 1 then p = p:gsub("/+$", "") end
    return IS_WIN and p:lower() or p
end

-- ---------------------------------------------------------------------------
-- Database revisions (db_rev)
-- ---------------------------------------------------------------------------

--- Raise the revision of `db_dir`'s owned database: called when a module
--- reports it (re)wrote it (§8.4 `refresh_lsp_database`'s `done(true)`).
--- @param ws loomworks.Workspace
--- @param db_dir string
function M.bump_db_rev(ws, db_dir)
    if type(ws) ~= "table" or type(db_dir) ~= "string" or db_dir == "" then return end
    local revs = ws._lsp_db_revs
    if type(revs) ~= "table" then
        revs = {}
        ws._lsp_db_revs = revs
    end
    local k = M.norm(db_dir)
    revs[k] = (revs[k] or 0) + 1
end

--- The revision of `db_dir`'s owned database (0 when never written).
--- @param ws loomworks.Workspace|nil
--- @param db_dir string|nil
--- @return integer
function M.db_rev(ws, db_dir)
    local revs = type(ws) == "table" and ws._lsp_db_revs or nil
    if type(revs) ~= "table" or type(db_dir) ~= "string" or db_dir == "" then return 0 end
    return revs[M.norm(db_dir)] or 0
end

-- ---------------------------------------------------------------------------
-- Content memo
-- ---------------------------------------------------------------------------
-- `lsp_configs` is not free: cmake's resolves the clangd binary (an env
-- expansion + PATH lookup), may schedule database generation, and walks the
-- active profile, config units and tools each time. A no-op switch would pay
-- the full cost for nothing; clangd and qmlls each pay it for the same project
-- on the same tick.
--
-- The entries are memoized on a CONTENT key that captures everything that
-- determines the output: workspace + project identity, the active profile's
-- resolved config unit (build_dir, config_key, build state), the active tool
-- identity, the project's lsp-affecting `type_config`, and a generation counter
-- bumped when workspace-level lsp options change. A hit returns the prior
-- entries WITHOUT calling `module.lsp_configs` again — so the second
-- integration on a tick is free, and a no-op switch is free. The key changes
-- the moment any determinant does, so a REAL switch recomputes exactly the
-- projects that actually moved.
--
-- Correctness note: a hit skips the whole of `lsp_configs`, its idempotent,
-- mtime-guarded side effect (generating the owned database) included. Build
-- state is part of the key, so a configure/build that would change what the
-- side effect emits also changes the key and forces a recompute.

--- @type table<string, { key: string, entries: table[] }> project.key → memo
local _memo = {}
--- Bumped when the lsp options change, so every content key changes.
local _generation = 0

--- A stable serialization of a plain value (sorted keys), for the memo key.
--- @param v any
--- @return string
local function repr(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta ~= tb then return ta < tb end
        if ta == "string" or ta == "number" then return a < b end
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = repr(k) .. "=" .. repr(v[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- The content key of a project's `lsp_configs` output. nil when the project
--- has no workspace (uncacheable — recomputed every time). Every component is
--- an identity/value read; none touch the filesystem.
--- @param project loomworks.Project
--- @return string|nil
function M._memo_key(project)
    local ws = project._workspace
    if not ws then return nil end

    local parts = {
        "g", tostring(_generation),
        "w", ws.root or "",
        "p", project.key or "",
    }

    local active = ws.get_active_profile and ws:get_active_profile() or nil
    parts[#parts + 1] = "prof"
    parts[#parts + 1] = active and active.key or ""
    if active and active.project then
        local pp = active:project(project.key)
        if pp then
            parts[#parts + 1] = "bd"
            parts[#parts + 1] = pp:build_dir() or ""
            parts[#parts + 1] = "ck"
            parts[#parts + 1] = pp:config_key() or ""
            parts[#parts + 1] = "st"
            parts[#parts + 1] = pp:status() or ""
            local tool = pp.tool_object and pp:tool_object() or nil
            parts[#parts + 1] = "tk"
            parts[#parts + 1] = tool and (tool.key or tostring(tool)) or ""
        end
    end

    -- Fallback determinants used by module.lsp_configs when there is no active
    -- profile (legacy active-config summary + the project's own tool_data
    -- clangd path). Cheap value reads; keep them in the key so the no-active
    -- path invalidates correctly too.
    parts[#parts + 1] = "cbd"
    parts[#parts + 1] = (project.cached and project.cached.build_dir) or ""
    parts[#parts + 1] = "tdc"
    parts[#parts + 1] = (project.tool_data and project.tool_data.clangd_path) or ""

    -- "Configured on this machine" of every unit of the project (spec §9.1):
    -- a module may redirect its database to a unit other than the active one,
    -- so any unit's configure/reset/delete must invalidate the memo.
    parts[#parts + 1] = "ch"
    if project.config_units and ws._config_units then
        for _, unit in ipairs(project:config_units()) do
            if unit.configured_here then
                parts[#parts + 1] = (unit.id or "?") .. "=" .. (unit:configured_here() and "1" or "0")
            end
        end
    end

    -- Per-project lsp overrides (clangd/qmlls binaries, qml_import_paths,
    -- compile_commands_from, *_required), serialized with sorted keys.
    parts[#parts + 1] = "tc"
    parts[#parts + 1] = project.type_config and repr(project.type_config) or ""

    return table.concat(parts, "\30")
end

--- Drop the whole memo (workspace swap — old projects are gone).
function M.clear_memo()
    _memo = {}
end

--- Invalidate every key by advancing the generation (the lsp options
--- changed). Each project recomputes lazily on its next read.
function M.bump_generation()
    _generation = _generation + 1
end

-- ---------------------------------------------------------------------------
-- Entries
-- ---------------------------------------------------------------------------

--- The project's active build dir in `ws`'s active profile, or nil.
--- @param ws table|nil
--- @param project loomworks.Project
--- @return string|nil
local function active_build_dir(ws, project)
    if type(ws) ~= "table" or not ws.get_active_profile then return nil end
    local profile = ws:get_active_profile()
    local pp = profile and profile.project and profile:project(project.key) or nil
    local bd = pp and pp.build_dir and pp:build_dir() or nil
    if type(bd) ~= "string" or bd == "" then return nil end
    return bd
end

--- Fill in `db_state` (spec §8.4) on entries whose module omitted it, derived
--- from the project's active ConfigUnit: "ready" when it is configured on this
--- machine, "unconfigured" otherwise (no active profile / no unit included).
--- A project without a workspace (never the case at runtime) is left alone.
--- @param project loomworks.Project
--- @param entries table[]
function M.derive_db_state(project, entries)
    local ws = project._workspace
    if not ws then return end
    local ready = nil
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.db_state == nil then
            if ready == nil then
                local profile = ws.get_active_profile and ws:get_active_profile() or nil
                local pp = profile and profile.project and profile:project(project.key) or nil
                ready = pp ~= nil and pp.configured_here ~= nil and pp:configured_here() == true
            end
            e.db_state = ready and "ready" or "unconfigured"
        end
    end
end

--- A project's entries: its module's `lsp_configs` output (content-memoized:
--- a hit skips `lsp_configs` entirely) with the core fields filled in —
--- `db_state` when the module omitted it (needs the project's workspace),
--- `db_dir` when the module set none (the project's active build dir in
--- `ws`; a module that redirects its database to another unit sets it, §8.4),
--- and `db_rev` of `db_dir` (re-read every call: a written database changes
--- no memo determinant). Every other field, a module's own `build_dir`
--- included, is left as the module set it. The entry tables are the memo's,
--- identity-stable across hits.
--- @param ws table|nil the workspace to read the active build dir and revisions from (default: the project's)
--- @param project loomworks.Project
--- @return loomworks.LspStateEntry[]
function M.entries(ws, project)
    if type(project) ~= "table" then return {} end
    ws = ws or project._workspace
    local mod = project._module and project._module.impl or nil
    if not mod or not mod.lsp_configs then return {} end

    local entries
    local key = M._memo_key(project)
    local cached = key and _memo[project.key] or nil
    if cached and cached.key == key then
        entries = cached.entries
    else
        local ok, out = pcall(mod.lsp_configs, project)
        if not ok or type(out) ~= "table" then return {} end
        entries = out
        M.derive_db_state(project, entries)
        local bd = active_build_dir(ws, project)
        for _, e in ipairs(entries) do
            if type(e) == "table" and e.db_dir == nil then e.db_dir = bd end
        end
        if key then _memo[project.key] = { key = key, entries = entries } end
    end

    for _, e in ipairs(entries) do
        if type(e) == "table" then e.db_rev = M.db_rev(ws, e.db_dir) end
    end
    return entries
end

--- The first entry for `server` in a list of entries (or a project record).
--- @param entries table[]|loomworks.LspConfigProject|nil
--- @param server string
--- @return loomworks.LspStateEntry|nil
function M.entry(entries, server)
    if type(entries) ~= "table" then return nil end
    if entries.entries then entries = entries.entries end
    for _, e in ipairs(entries) do
        if type(e) == "table" and e.server == server then return e end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- One project's record of the state.
--- @param ws table|nil
--- @param project loomworks.Project
--- @param id_of? fun(project: loomworks.Project): string|nil the daemon's opaque ids
--- @return loomworks.LspConfigProject
function M.project_record(ws, project, id_of)
    return {
        project = project.key,
        id = id_of and id_of(project) or nil,
        path = project.path,
        entries = M.entries(ws, project),
    }
end

--- The project records in ascending key order.
--- @param ws table|nil
--- @param projects table<any, loomworks.Project>|nil the projects (default: `ws._projects`)
--- @param id_of? fun(project: loomworks.Project): string|nil
--- @return loomworks.LspConfigProject[]
function M.project_records(ws, projects, id_of)
    projects = projects or (type(ws) == "table" and ws._projects) or {}
    local sorted = {}
    for _, p in pairs(projects) do
        if type(p) == "table" and p.key then sorted[#sorted + 1] = p end
    end
    table.sort(sorted, function(a, b) return a.key < b.key end)
    local out = {}
    for i, p in ipairs(sorted) do out[i] = M.project_record(ws, p, id_of) end
    return out
end

--- The per-server options with defaults applied (§2, user.json `lsp`).
--- @param ws table
--- @return table<string, table<string, any>>
function M.options(ws)
    local out = {}
    if type(ws) ~= "table" or not ws.lsp_option_servers or not ws.get_lsp_options then return out end
    for _, server in ipairs(ws:lsp_option_servers()) do
        out[server] = ws:get_lsp_options(server)
    end
    return out
end

--- The whole state (§19.20 `LspConfig/1.get`). With no workspace it is
--- `opts.state` (default "unloaded"), not ready, with no projects and no
--- options — the state never loads a workspace.
--- @param ws loomworks.Workspace|nil
--- @param opts? { state?: string, projects?: table<any, loomworks.Project>, id_of?: fun(project: loomworks.Project): string|nil }
--- @return loomworks.LspConfigState
function M.state(ws, opts)
    opts = opts or {}
    if type(ws) ~= "table" then
        return { state = opts.state or "unloaded", ready = false, projects = {}, options = {} }
    end
    return {
        state = "loaded",
        ready = ws._lsp_ready == true,
        projects = M.project_records(ws, opts.projects, opts.id_of),
        options = M.options(ws),
    }
end

return M
