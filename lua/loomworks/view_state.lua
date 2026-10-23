--- loomworks/view_state.lua — the one builder of the editor views'
--- state (spec §19.13 "Views", "Two sources, one shape"):
---
---   header(ws, err, opts)          loomworks.view.Header/1
---   projects_index(ws, opts)       loomworks.view.ProjectsIndex/1
---   workspace(ws, opts)            loomworks.view.Workspace/1 (step 5n; the
---                                  status page body, in-process only so far)
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
--- @field version? string the running loomworks version of the lw that built the view

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
--- @field version? string the running loomworks version (header; save_guard.version())

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
    h.version = opts.version
    if h.state == "loaded" then
        -- The view names the active profile and its configuration set only
        -- when the object resolves (live, not removed), so the daemon always
        -- sends their ids with them (§19.13 "Views": `active_profile_id` /
        -- `config_set_id` present exactly when the name is). A dangling key
        -- (base_header's fallback, kept for Workspace/1.header) is left out.
        local ap = active_profile(ws)
        h.active_profile = ap and type(ap.key) == "string" and ap.key or nil
        if h.active_profile then
            if opts.id then h.active_profile_id = opts.id(ap) end
            local cs = ap._config_set_ref
            if cs and not cs._removed and type(cs.name) == "string" then
                h.config_set = cs.name
                if opts.id then h.config_set_id = opts.id(cs) end
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
                -- A removed unit is no unit: no `unit_id`, state `unconfigured`
                -- (§19.13: both describe "no unit for the project yet").
                local unit = pp._config_unit
                if unit and unit._removed then unit = nil end
                local tool = pp:tool_object()
                rec.active = { configuration = config, state = unit and pp:status() or "unconfigured",
                    tool_key = tool and type(tool.key) == "string" and tool.key or nil,
                    unit_id = unit and opts.id and opts.id(unit) or nil }
            end
            out[#out + 1] = rec
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return { projects = out }
end

-- ---------------------------------------------------------------------------
-- loomworks.view.Workspace/1 (step 5n part A: the builder, in-process only)
-- ---------------------------------------------------------------------------

--- @alias loomworks.ViewIntent "local"|"shared"|"local+shared"

--- @class loomworks.ViewDiagnostic
--- @field severity string
--- @field source? string
--- @field message string
--- @field target_fold_key? string

--- @class loomworks.ViewTarget
--- @field type? string
--- @field artifact? string
--- @field dependencies? string[]

--- @class loomworks.ViewUnit
--- @field state string a ConfigUnitState (state-lifecycle.md §3.4), "unconfigured" without a unit
--- @field deleting_reason? string
--- @field unit_id? string daemon only
--- @field project? string project key
--- @field type? string the project's module type
--- @field configuration? string the configuration's name
--- @field missing boolean the configuration is missing
--- @field compat_error? string
--- @field overwritten boolean
--- @field launcher_changed boolean
--- @field artifact_block? { profile: string, path?: string } daemon only: a build now would overwrite that built profile's artifact (spec §5.9)
--- @field tools? string[] the labels of the unit's tools
--- @field build_dir? string
--- @field targets? table<string, loomworks.ViewTarget> target name -> target

--- @class loomworks.ViewProfileTool
--- @field module string module type
--- @field key? string
--- @field label string

--- @class loomworks.ViewToolchainEntry
--- @field key? string
--- @field label string
--- @field resolved boolean
--- @field languages string[]

--- @class loomworks.ViewDevice
--- @field id? string daemon only
--- @field key string the serial
--- @field label string the display name, else the serial
--- @field state "online"|"offline"
--- @field provider? string

--- The outcome of a profile's last finished operation (API.md §14.4):
--- `status` a Tasks/1 final status (`ok`, `failed`, `cancelled`), `message`
--- its end message.
--- @class loomworks.ViewLastResult
--- @field status string
--- @field message? string

--- @class loomworks.ViewProfile
--- @field id? string daemon only
--- @field key string
--- @field label string
--- @field intent? loomworks.ViewIntent
--- @field description? string
--- @field removed_upstream boolean
--- @field active boolean
--- @field modified boolean
--- @field orphaned_set boolean
--- @field incomplete boolean
--- @field running boolean
--- @field busy boolean
--- @field config_set? string
--- @field status? string
--- @field compat_error? string
--- @field artifact_conflict boolean
--- @field origin? string a daemon task's origin
--- @field last_result? loomworks.ViewLastResult the last finished operation's outcome
--- @field tools loomworks.ViewProfileTool[] one per module type, by module
--- @field toolchain? loomworks.ViewToolchainEntry[]
--- @field compiler_cache? { text: string, stale: boolean }
--- @field device_capable? boolean
--- @field device? loomworks.ViewDevice
--- @field default_target? string
--- @field default_target_valid? boolean
--- @field default_target_description? string
--- @field units loomworks.ViewUnit[]

--- @class loomworks.ViewOrphaned
--- @field configurations { id?: string, key: string, build_dir?: string }[] `id` the
---   orphaned build directory's (daemon only; Maintenance/1.execute_deletion)
--- @field stray_dirs string[]

--- @class loomworks.ViewConfigSet
--- @field id? string daemon only
--- @field name string
--- @field intent? loomworks.ViewIntent
--- @field description? string
--- @field removed_upstream boolean
--- @field active boolean
--- @field modified boolean
--- @field mappings table<string, string> project key -> configuration name
--- @field missing table<string, boolean> project keys whose configuration is gone

--- @class loomworks.ViewOption
--- @field key string
--- @field value any
--- @field source? string the providing configuration (nil: own)

--- @class loomworks.ViewVariableValue
--- @field name string
--- @field value? any
--- @field source string "profile", "project" or a configuration's name
--- @field own boolean

--- @class loomworks.ViewConfiguration
--- @field id? string daemon only
--- @field key string the configuration's name
--- @field label string
--- @field intent? loomworks.ViewIntent
--- @field removed_upstream boolean
--- @field modified boolean
--- @field abstract boolean no variant
--- @field inherits? string|string[]
--- @field toolchain_locked? boolean
--- @field role? string
--- @field toolchain? string
--- @field generator? string
--- @field description? string
--- @field description_from_module? boolean
--- @field auto_gen? boolean
--- @field source_missing? boolean
--- @field unresolved_inherits? string[]
--- @field dependents? string[] sorted names of the configurations inheriting this one
--- @field compiler_overrides? table
--- @field user? boolean
--- @field running? boolean
--- @field overwritten? boolean
--- @field tools_configured? integer
--- @field tests? table saved test targets (Project:saved_tests_view)
--- @field options loomworks.ViewOption[] sorted by key
--- @field variables? loomworks.ViewVariableValue[] sorted by name

--- A launch configuration: no publish state of its own (it publishes with
--- its project, spec §2.4).
--- @class loomworks.ViewLaunch
--- @field key string the launch's name
--- @field label string
--- @field description? string
--- @field target? string
--- @field command? string
--- @field args? string[]

--- @class loomworks.ViewTypeConfigField
--- @field name string
--- @field label? string
--- @field kind? string
--- @field placeholder? string
--- @field value? any

--- @class loomworks.ViewProject
--- @field id? string daemon only
--- @field key string
--- @field type string
--- @field path string
--- @field intent? loomworks.ViewIntent
--- @field removed_upstream boolean
--- @field description? string
--- @field description_from_module? boolean
--- @field modified boolean
--- @field orphaned boolean
--- @field running boolean
--- @field needs_refresh boolean
--- @field refresh_reasons? string[]
--- @field tests? table saved test targets (Project:saved_tests_view)
--- @field configurations loomworks.ViewConfiguration[] sorted by name
--- @field presets? { name: string, generator?: string, toolchain_locked?: boolean }[]
--- @field launches loomworks.ViewLaunch[] sorted by name
--- @field deploy { destination: string, sources: table[] }[] sorted by destination
--- @field variables table<string, { type: string, default?: any }> variable name -> declaration
--- @field type_config { fields: loomworks.ViewTypeConfigField[] }

--- @class loomworks.ViewSdk
--- @field id? string daemon only (what Sdks/1.remove takes)
--- @field key string
--- @field label string
--- @field path? string
--- @field resolved boolean
--- @field kits string[]

--- `loomworks.view.Workspace/1`'s state (M.workspace).
--- @class loomworks.ViewWorkspace
--- @field published boolean
--- @field modified boolean
--- @field diagnostics loomworks.ViewDiagnostic[]
--- @field suggestions integer actionable suggestions
--- @field profiles loomworks.ViewProfile[] sorted by key
--- @field orphaned loomworks.ViewOrphaned
--- @field config_sets loomworks.ViewConfigSet[] sorted by name
--- @field projects loomworks.ViewProject[] alphabetical, orphaned last
--- @field sdks loomworks.ViewSdk[]
--- @field sdk_providers integer

--- @class loomworks.ViewWorkspaceOpts : loomworks.ViewOpts
--- @field published? boolean loomworks.json is on disk (the host's file check)
--- @field stray_dirs? string[] absolute build directories on disk no cache entry
---        references (the host's scan, Workspace:find_stray_build_dirs)
--- @field bind? fun(row: table, obj: table) in-process only: called with each row
---        and the domain object it describes, so the editor's actions reach the
---        object without a key lookup. Never part of the state.

--- `obj.description` when it is a string (a normalised description).
local function desc_of(obj)
    local d = obj and obj.description
    return type(d) == "string" and d or nil
end

--- A unit's live state: `state` (ConfigUnitState) and the deleting reason.
--- No unit: unconfigured. A running step's progress is not state but the
--- task's (API.md §14.4 "Progress is not in the view").
--- @param unit loomworks.ConfigUnit|nil
--- @return table
local function unit_state(unit)
    if not unit then return { state = "unconfigured" } end
    local s = { state = unit:state() }
    if s.state == "deleting" then s.deleting_reason = unit:deleting_reason() end
    return s
end

--- A unit's targets, by name: `{ type, artifact?, dependencies? }`.
local function targets_of(unit)
    local targets = unit and unit.targets
    if not targets or not next(targets) then return nil end
    local out = {}
    for name, t in pairs(targets) do
        out[name] = { type = t.type, artifact = t.artifact,
            dependencies = type(t.dependencies) == "table" and vim.deepcopy(t.dependencies) or nil }
    end
    return out
end

--- One profile's row (`profiles[]`).
local function profile_row(ws, profile, active, opts)
    local row = {
        key = profile.key, label = profile.key, intent = profile._intent, description = desc_of(profile),
        removed_upstream = profile._removed_upstream and true or false,
        active = profile == active, modified = ws:is_profile_modified(profile) and true or false,
        orphaned_set = profile.orphaned_set and true or false,
        incomplete = not profile:is_complete(),
        running = profile:is_running() and true or false,
        busy = profile:has_active_operation() and true or false,
    }
    if opts.id then row.id = opts.id(profile) end
    if row.orphaned_set then
        row.config_set = profile._configuration_set_name
    elseif profile._config_set_ref then
        row.config_set = profile._config_set_ref.name
    end
    row.status = profile:status()
    local pps = profile:projects()
    for _, pp in ipairs(pps) do
        if pp._tool_compat_error then row.compat_error = pp._tool_compat_error; break end
    end
    row.artifact_conflict = ws.profile_has_artifact_conflict
        and ws:profile_has_artifact_conflict(profile) and true or false
    -- A task observed in the workspace daemon counts as the profile's active
    -- operation (spec/ui.md §1.5), with its origin.
    local remote = profile:remote_tasks()[1]
    if remote and #profile:active_operations() == 0 then row.origin = remote:origin_label() end
    -- The last finished operation's outcome: state, kept while the next one
    -- runs (a running one's progress is its task's, never the view's).
    local last = profile:operation()
    if last then row.last_result = { status = last.status, message = last.message } end

    -- The tool per module type of the profile's projects.
    row.tools = {}
    local seen = {}
    for _, pp in ipairs(pps) do
        local mod_type = pp._project and pp._project.type
        if mod_type and not seen[mod_type] then
            seen[mod_type] = true
            local t = profile:tool_for(mod_type)
            if t then
                row.tools[#row.tools + 1] = { module = mod_type, key = t.key, label = t.label or t.key or mod_type }
            end
        end
    end
    table.sort(row.tools, function(a, b) return a.module < b.module end)
    -- The toolchain list (the status page's Toolchain row): present when a
    -- module needs a tool or tools are listed.
    local entries = profile:toolchain_entries()
    if #profile:tool_needing_modules() > 0 or #entries > 0 then
        row.toolchain = {}
        for _, e in ipairs(entries) do
            row.toolchain[#row.toolchain + 1] = { key = e.key, label = e.label, resolved = e.resolved and true or false,
                languages = vim.deepcopy(e.languages or {}) }
        end
    end
    local cache_status = profile:compiler_cache_status()
    if cache_status then
        row.compiler_cache = { text = cache_status.text, stale = cache_status.stale and true or false }
    end
    -- The device (an entity record: `label` its name, else its serial);
    -- `device_capable` whether the profile has a device-capable module (the
    -- page shows its device row, "none selected" without a device).
    if profile:has_device_module() then
        row.device_capable = true
        local device = profile:device()
        if device and device:is_online() then
            row.device = { key = device.serial, label = device.display_name or device.serial, state = "online",
                provider = device.provider }
            if opts.id then row.device.id = opts.id(device) end
        elseif profile:device_serial() then
            row.device = { key = profile:device_serial(), label = profile:device_serial(), state = "offline" }
        end
    end
    local lt = profile:default_target()
    if lt then
        row.default_target = lt:display_name()
        row.default_target_valid = lt:is_valid() and true or false
        row.default_target_description = lt._launch and lt._launch.description or nil
    end

    row.units = {}
    for _, pp in ipairs(pps) do
        local unit = pp._config_unit
        local u = unit_state(unit)
        u.project = pp._project and pp._project.key or nil
        u.type = pp._project and pp._project.type or nil
        u.configuration = pp:variant_name()
        u.missing = pp:is_configuration_missing() and true or false
        u.compat_error = pp._tool_compat_error
        u.overwritten = unit and unit.is_overwritten and unit:is_overwritten() and true or false
        u.launcher_changed = unit and unit.launcher_changed and unit:launcher_changed(profile) and true or false
        if unit and opts.id then
            u.unit_id = opts.id(unit)
            -- Whether a build of the unit now would overwrite another
            -- profile's built artifact (spec §5.9 gate, without `force`;
            -- API.md §14.4): the editor asks before a build from this, never
            -- from its own model (daemon.md §19.16 "Model writes").
            local block = ws.artifact_conflict_block and ws:artifact_conflict_block(unit, false) or nil
            if block then u.artifact_block = { profile = block.profile, path = block.path } end
        end
        local cfg = pp._configuration
        if cfg and not cfg._removed and profile.tools_for then
            local tools = profile:tools_for(cfg)
            if #tools > 0 then
                u.tools = {}
                for _, t in ipairs(tools) do u.tools[#u.tools + 1] = t.label or t.key or "?" end
            end
        end
        u.build_dir = unit and unit.build_dir_value or nil
        u.targets = targets_of(unit)
        row.units[#row.units + 1] = u
        if opts.bind then opts.bind(u, pp) end
    end
    if opts.bind then opts.bind(row, profile) end
    return row
end

--- One configuration set's row (`config_sets[]`).
local function config_set_row(ws, cs, active, opts)
    local row = { name = cs.name, intent = cs._intent, description = desc_of(cs),
        removed_upstream = cs._removed_upstream and true or false,
        active = active ~= nil and active._config_set_ref == cs,
        modified = ws:is_config_set_modified(cs) and true or false,
        -- JSON objects even when empty (an empty Lua table encodes as an array).
        mappings = vim.empty_dict(), missing = vim.empty_dict() }
    if opts.id then row.id = opts.id(cs) end
    for project, config in pairs(cs.mappings or {}) do
        -- project key -> configuration name; `missing` the projects whose
        -- configuration was removed or has no source.
        row.mappings[project.key] = config.name
        if config._removed or config._source_missing then row.missing[project.key] = true end
    end
    if opts.bind then opts.bind(row, cs) end
    return row
end

--- The rows of one project configuration (`projects[].configurations[]`).
local function configuration_row(ws, proj, cname, cdata, opts)
    local cfg = proj:get_configuration(cname)
    local row = { key = cname, label = cname, intent = cfg and cfg._intent or nil,
        removed_upstream = cfg and cfg._removed_upstream and true or false, modified = false,
        abstract = not cdata.variant, inherits = cdata.inherits, toolchain_locked = cdata.toolchain_locked or nil,
        role = cdata.role, toolchain = cdata.toolchain, generator = cdata.generator }
    if type(row.inherits) == "table" then row.inherits = vim.deepcopy(row.inherits) end
    if cfg then
        if opts.id then row.id = opts.id(cfg) end
        row.description = desc_of(cfg)
        row.description_from_module = cfg._description_from_module and true or nil
        row.auto_gen = cfg:is_auto_gen() and true or false
        row.source_missing = cfg._source_missing and true or false
        row.unresolved_inherits = cfg:unresolved_inherits_names()
        row.dependents = {}
        for _, d in ipairs(cfg:dependents()) do row.dependents[#row.dependents + 1] = d.name end
        -- Configuration:dependents() walks a registry with no fixed order.
        table.sort(row.dependents)
        row.compiler_overrides = cfg:compiler_override_warnings()
        row.modified = ws:is_config_modified(proj, cfg) and true or false
        row.user = cfg.is_user and true or false
        local running, overwritten, configured = false, false, 0
        for _, cu in ipairs(proj:config_units_for_configuration(cfg) or {}) do
            if cu:shown_action() then running = true end
            if cu.is_overwritten and cu:is_overwritten() then overwritten = true end
            if cu:tool_key() and cu._config_key ~= nil then configured = configured + 1 end
        end
        row.running, row.overwritten, row.tools_configured = running, overwritten, configured
        -- Saved test targets: flagged only when this machine configured a
        -- unit of the configuration (its targets known).
        local impl = proj._module and proj._module.impl
        if impl and impl.parse_targets and cfg.test_targets then
            local known
            for _, u in pairs(ws._config_units or {}) do
                if u._configuration == cfg and u.targets and u:configured_here() then known = u.targets end
            end
            row.tests = proj:saved_tests_view(cfg:test_targets(), cfg, known)
        end
    end
    -- Options: own (`source` nil) and inherited (`source` the provider).
    local mod_impl = proj._module and proj._module.impl or nil
    local own = cdata.options or {}
    local list = {}
    if mod_impl and mod_impl.resolve_options_with_sources then
        local all = mod_impl.resolve_options_with_sources(proj:_type_config_for_module(),
            proj.configurations or {}, cname)
        for k, info in pairs(all) do
            list[#list + 1] = { key = k, value = info.value, source = (not own[k]) and info.source or nil }
        end
    else
        for k, v in pairs(own) do list[#list + 1] = { key = k, value = v } end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    row.options = list
    -- Resolved variables under the active profile and its compiler family
    -- (spec §1.3.1: the family's `overrides` apply; a blank variable's fill
    -- value shows; an unfilled blank has no `value`), as the configuration
    -- editor shows them (Projects/1.declaration).
    if proj.variables and next(proj.variables) and cfg then
        local resolved = require("loomworks.variables").resolve(proj, cfg, proj:active_compiler_family(),
            ws._active_profile)
        local vars = {}
        for vn, entry in pairs(resolved) do
            local source = entry.from_profile and "profile"
                or (entry.source_config and entry.source_config.name) or "project"
            vars[#vars + 1] = { name = vn, value = entry.value, source = source,
                own = (entry.value ~= nil and cfg.variables and cfg.variables[vn]) and true or false }
        end
        table.sort(vars, function(a, b) return a.name < b.name end)
        row.variables = vars
    end
    if opts.bind and cfg then opts.bind(row, cfg) end
    return row
end

--- One project's row (`projects[]`).
local function project_row(ws, proj, opts)
    local row = { key = proj.key, type = proj.type, path = proj.path or proj.key, intent = proj._intent,
        removed_upstream = proj._removed_upstream and true or false,
        description = desc_of(proj), description_from_module = proj._description_from_module and true or nil,
        modified = ws:is_project_modified(proj) and true or false, orphaned = proj.orphaned and true or false,
        running = proj:running_action() ~= nil, needs_refresh = proj.needs_refresh and true or false }
    if opts.id then row.id = opts.id(proj) end
    if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
        row.refresh_reasons = vim.deepcopy(proj.refresh_reasons)
    end
    local impl = proj._module and proj._module.impl or nil
    if proj.own_test_targets and impl and impl.parse_targets then
        local pw = proj:own_test_targets()
        row.tests = proj:saved_tests_view(pw and { entries = pw, source = proj,
            invalid = proj._tests and proj._tests.invalid } or nil, proj, nil)
    end
    row.configurations = {}
    for cname, cdata in pairs(proj.configurations or {}) do
        row.configurations[#row.configurations + 1] = configuration_row(ws, proj, cname, cdata, opts)
    end
    table.sort(row.configurations, function(a, b) return a.key < b.key end)
    if proj.preset_configurations and next(proj.preset_configurations) then
        row.presets = {}
        for name, p in pairs(proj.preset_configurations) do
            row.presets[#row.presets + 1] = { name = name, generator = p.generator,
                toolchain_locked = p.toolchain_locked or nil }
        end
        table.sort(row.presets, function(a, b) return a.name < b.name end)
    end
    row.launches = {}
    for _, launch in ipairs(proj:launch_configs()) do
        -- Launch configurations carry no publish state of their own in the
        -- model (they publish with their project, spec §2.4).
        local name = launch.name
        local l = { key = name, label = name }
        if opts.id then l.id = opts.id(launch) end
        if not launch:is_invalid() then
            l.description = launch.description
            l.target, l.command = launch.target, launch.command
            l.args = type(launch.args) == "table" and vim.deepcopy(launch.args) or nil
        end
        row.launches[#row.launches + 1] = l
        if opts.bind then opts.bind(l, launch) end
    end
    row.deploy = {}
    if proj.deploy then
        local deploy_mod = require("loomworks.deploy")
        for dest, srcs in pairs(proj.deploy) do
            row.deploy[#row.deploy + 1] = { destination = dest,
                sources = vim.deepcopy(deploy_mod.normalize_sources(srcs)) }
        end
        table.sort(row.deploy, function(a, b) return a.destination < b.destination end)
    end
    -- Variable name -> { type, default }.
    row.variables = vim.empty_dict()
    for name, decl in pairs(proj.variables or {}) do
        row.variables[name] = { type = decl.type, default = decl.default }
    end
    -- The module's editable type_config fields, with their current values.
    row.type_config = { fields = {} }
    for _, f in ipairs(impl and impl.editable_type_config_fields and impl.editable_type_config_fields() or {}) do
        local v = proj.type_config and proj.type_config[f.name]
        row.type_config.fields[#row.type_config.fields + 1] = { name = f.name, label = f.label, kind = f.kind,
            placeholder = f.placeholder, value = type(v) == "table" and vim.deepcopy(v) or v }
    end
    if opts.bind then opts.bind(row, proj) end
    return row
end

--- `loomworks.view.Workspace/1`'s state: the status page's body (spec/ui.md
--- §1.1: Diagnostics, Suggestions, Profiles, Orphaned Build Dirs,
--- Configuration Sets, Projects, SDKs). Pure over the model: the host passes
--- what needs the file system (`published`, `stray_dirs`).
--- @param ws table|nil the live workspace (nil: not loaded, every array empty)
--- @param opts? loomworks.ViewWorkspaceOpts
--- @return loomworks.ViewWorkspace
function M.workspace(ws, opts)
    opts = opts or {}
    if not ws then
        -- Not loaded: nothing of a workspace is known, every array empty.
        return { published = false, modified = false, diagnostics = {}, suggestions = 0, profiles = {},
            orphaned = { configurations = {}, stray_dirs = {} }, config_sets = {}, projects = {}, sdks = {},
            sdk_providers = #require("loomworks.sdks").list() }
    end
    local out = { published = opts.published ~= false, modified = ws:has_any_modified() and true or false }

    out.diagnostics = {}
    if type(ws.diagnostics) == "function" then
        for _, d in ipairs(ws:diagnostics()) do
            out.diagnostics[#out.diagnostics + 1] = { severity = d.severity, source = d.source,
                message = d.message, target_fold_key = d.target_fold_key }
        end
    end
    -- Only actionable suggestions count (headless §16.31).
    local ok_s, n = pcall(function() return require("loomworks.suggestions").count_actionable(ws) end)
    out.suggestions = ok_s and type(n) == "number" and n or 0

    local active = ws:get_active_profile()
    out.profiles = {}
    for _, profile in pairs(ws:get_profiles()) do
        out.profiles[#out.profiles + 1] = profile_row(ws, profile, active, opts)
    end
    table.sort(out.profiles, function(a, b) return a.key < b.key end)

    out.orphaned = { configurations = {}, stray_dirs = {} }
    for _, o in ipairs(ws:get_orphaned_configs()) do
        local row = { key = o.build_dir_key or o.config_key,
            build_dir = o.cached_entry and o.cached_entry.build_dir or nil }
        if opts.id and o.build_dir_obj then row.id = opts.id(o.build_dir_obj) end
        out.orphaned.configurations[#out.orphaned.configurations + 1] = row
        if opts.bind then opts.bind(row, o) end
    end
    for _, dir in ipairs(opts.stray_dirs or {}) do out.orphaned.stray_dirs[#out.orphaned.stray_dirs + 1] = dir end

    out.config_sets = {}
    for _, cs in pairs(ws:get_config_sets()) do
        out.config_sets[#out.config_sets + 1] = config_set_row(ws, cs, active, opts)
    end
    table.sort(out.config_sets, function(a, b) return a.name < b.name end)

    -- Projects: alphabetical, orphaned ones last.
    local normal, orphaned = {}, {}
    for _, proj in pairs(ws:get_projects()) do
        local list = proj.orphaned and orphaned or normal
        list[#list + 1] = proj
    end
    table.sort(normal, function(a, b) return a.key < b.key end)
    table.sort(orphaned, function(a, b) return a.key < b.key end)
    out.projects = {}
    for _, list in ipairs({ normal, orphaned }) do
        for _, proj in ipairs(list) do out.projects[#out.projects + 1] = project_row(ws, proj, opts) end
    end

    out.sdks = {}
    for _, sdk in ipairs(ws:sdks()) do
        local resolved = sdk:is_resolved() and true or false
        local row = { key = sdk.key, label = sdk:display_name(), path = sdk:sdk_path(), resolved = resolved, kits = {} }
        for _, kit in ipairs(resolved and sdk:kits() or {}) do
            row.kits[#row.kits + 1] = sdk:kit_label(kit.platform, kit.arch)
        end
        if opts.id then row.id = opts.id(sdk) end
        out.sdks[#out.sdks + 1] = row
        if opts.bind then opts.bind(row, sdk) end
    end
    out.sdk_providers = #require("loomworks.sdks").list()
    return out
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
