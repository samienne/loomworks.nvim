--- loomworks/test_targets.lua — saved test targets (spec §1.3.4).
---
--- A pure helper with no workspace access: parses and serializes the generic
--- `tests` field of a project (the project-wide list, lifted out of the module
--- section like `description`) and of a user configuration, strips the field
--- from what a module sees, resolves an entry's name to a launch
--- configuration or a build target, and formats a list's source for display.
--- The domain objects (Project, Configuration) own the declarations and the
--- inheritance walk; this module only knows the value shape:
---
---   "tests": [ "Name", ["Name", "arg", …], { "name": "Name", "args": […], "working_dir": "…" }, … ]
---
--- A name may repeat (each occurrence is its own entry, told apart by its
--- occurrence index). An element of any other shape is an invalid entry, kept
--- verbatim and treated as missing; a `tests` value that is not an array is an
--- invalid declaration, kept verbatim, that still stops the inheritance walk.

local M = {}

--- @class loomworks.SavedTestEntry
--- @field name string|nil launch configuration or build target name of the declaring project (unqualified, never expanded); nil for an invalid entry
--- @field args string[]|nil arguments as written (unexpanded), placed after the program's own
--- @field working_dir string|nil working directory as written (unexpanded; absolute or workspace-root-relative)
--- @field extra table<string, any>|nil keys of a table entry this version does not know (kept verbatim, never acted on)
--- @field index integer occurrence index among the entries with this name (1-based); 1 for an invalid entry
--- @field repeated boolean|nil true when the name occurs more than once in its list
--- @field invalid any|nil the raw element of an invalid entry (kept verbatim; the entry is missing)
--- @field decl_invalid boolean|nil planner stand-in for an invalid declaration (a `tests` value that is not an array)

--- @class loomworks.SavedTestDecl
--- @field entries loomworks.SavedTestEntry[] parsed list, in run order (duplicates kept)
--- @field invalid boolean|nil true for an invalid declaration (a `tests` value that is not an array)

--- One-shot reports of invalid entries / declarations (hand-edited files).
M._warned = {}

local function report_once(key, msg)
    if M._warned[key] then return end
    M._warned[key] = true
    if vim.schedule and vim.notify then
        vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
    end
end

--- Compact text of a raw value for messages.
--- @param v any
--- @return string
function M.raw_text(v)
    local ok, s = pcall(vim.json.encode, v)
    if ok and type(s) == "string" then return s end
    return vim.inspect(v)
end

--- Whether a value is a JSON array (an empty table counts as `[]`).
--- @param v any
--- @return boolean
function M.is_list(v)
    if type(v) ~= "table" then return false end
    local n = 0
    for k in pairs(v) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do
        if v[i] == nil then return false end
    end
    return true
end
local is_list = M.is_list

--- Assign occurrence indexes (and the `repeated` flag) to a list, in place.
--- @param entries loomworks.SavedTestEntry[]
--- @return loomworks.SavedTestEntry[]
function M.index_entries(entries)
    local count, seen = {}, {}
    for _, e in ipairs(entries) do
        if e.name then count[e.name] = (count[e.name] or 0) + 1 end
    end
    for _, e in ipairs(entries) do
        if e.name then
            seen[e.name] = (seen[e.name] or 0) + 1
            e.index = seen[e.name]
            e.repeated = count[e.name] > 1 or nil
        else
            e.index, e.repeated = 1, nil
        end
    end
    return entries
end

--- The keys of the table form this version knows (spec §1.3.4).
local TABLE_KEYS = { name = true, args = true, working_dir = true }

--- Parse one raw element: `"Name"`, a non-empty array of strings
--- `["Name", args…]`, or a table `{ name, args?, working_dir? }` (unknown
--- keys kept verbatim in `extra`); anything else is an invalid entry.
--- @param el any
--- @return loomworks.SavedTestEntry
function M.parse_entry(el)
    if type(el) == "string" and el ~= "" then
        return { name = el }
    end
    if type(el) == "table" and not is_list(el) then
        local name, args, wd = el.name, el.args, el.working_dir
        local ok = type(name) == "string" and name ~= ""
            and (args == nil or is_list(args))
            and (wd == nil or type(wd) == "string")
        if ok and args ~= nil then
            for _, a in ipairs(args) do
                if type(a) ~= "string" then ok = false; break end
            end
        end
        if ok then
            local e = { name = name }
            if args ~= nil and #args > 0 then e.args = vim.deepcopy(args) end
            e.working_dir = wd
            for k, v in pairs(el) do
                if not TABLE_KEYS[k] then
                    e.extra = e.extra or {}
                    e.extra[k] = vim.deepcopy(v)
                end
            end
            return e
        end
        return { invalid = vim.deepcopy(el) }
    end
    if is_list(el) and #el > 0 then
        local ok = true
        for _, a in ipairs(el) do
            if type(a) ~= "string" then ok = false; break end
        end
        if ok and el[1] ~= "" then
            local args
            if #el > 1 then
                args = {}
                for i = 2, #el do args[#args + 1] = el[i] end
            end
            return { name = el[1], args = args }
        end
    end
    return { invalid = vim.deepcopy(el) }
end

--- Parse a raw `tests` value. Returns nil when there is no declaration.
--- An invalid declaration (not an array) returns a declaration with no
--- entries and `invalid = true` (it stops the inheritance walk), plus the raw
--- value to write back unchanged. Invalid entries and declarations are
--- reported once, naming `where` (e.g. "App/Tests").
--- @param raw any the `tests` value as read
--- @param where string|nil label for reports
--- @return loomworks.SavedTestDecl|nil decl
--- @return any invalid the raw value of an invalid declaration, kept to be written back unchanged
function M.parse(raw, where)
    if raw == nil then return nil, nil end
    if not is_list(raw) then
        report_once("decl|" .. tostring(where) .. "|" .. M.raw_text(raw),
            "loomworks: " .. tostring(where or "?") .. ": `tests` must be an array of saved test entries"
            .. " — kept as written, and treated as missing")
        return { entries = {}, invalid = true }, raw
    end
    local entries = {}
    for _, el in ipairs(raw) do
        local e = M.parse_entry(el)
        if e.invalid ~= nil then
            report_once("bad|" .. tostring(where) .. "|" .. M.raw_text(el),
                "loomworks: " .. tostring(where or "?") .. ": invalid saved test entry " .. M.raw_text(el)
                .. ' (expected "Name", ["Name", args…] or { "name": …, … }) — kept as written, and treated as missing')
        end
        entries[#entries + 1] = e
    end
    return { entries = M.index_entries(entries) }, nil
end

--- Whether a parsed declaration declares a list (an explicit `[]` does, and
--- so does an invalid declaration).
--- @param decl loomworks.SavedTestDecl|nil
--- @return boolean
function M.declares(decl)
    return decl ~= nil and decl.entries ~= nil
end

--- Serialize one entry in the shortest form that holds it (spec §1.3.4
--- "Persistence"): a bare name, `["Name", args…]` when it has args, the
--- table form only when it has a `working_dir` or unknown keys (kept
--- verbatim, so such a table is never shortened), or an invalid entry's raw
--- element verbatim.
--- @param e loomworks.SavedTestEntry
--- @return any
function M.serialize_entry(e)
    if e.invalid ~= nil then return vim.deepcopy(e.invalid) end
    if e.working_dir ~= nil or (e.extra and next(e.extra)) then
        local t = {}
        for k, v in pairs(e.extra or {}) do t[k] = vim.deepcopy(v) end
        t.name = e.name
        if e.args and #e.args > 0 then t.args = vim.deepcopy(e.args) end
        t.working_dir = e.working_dir
        return t
    end
    if not (e.args and #e.args > 0) then return e.name end
    local raw = { e.name }
    for _, a in ipairs(e.args) do raw[#raw + 1] = a end
    return raw
end

--- Serialize a declaration to its raw `tests` value (nil when nothing to write).
--- @param decl loomworks.SavedTestDecl|nil
--- @param invalid any preserved raw value of an invalid declaration
--- @return any
function M.serialize(decl, invalid)
    if invalid ~= nil then return invalid end
    if not decl or decl.entries == nil then return nil end
    -- An explicit empty list is a declaration (§1.3.4); a plain empty table
    -- encodes as `[]`.
    local list = {}
    for i, e in ipairs(decl.entries) do list[i] = M.serialize_entry(e) end
    return list
end

--- A declaration holding a copy of `entries` (re-indexed), or nil to remove
--- the list (the level inherits again).
--- @param _decl loomworks.SavedTestDecl|nil the current declaration (unused)
--- @param entries loomworks.SavedTestEntry[]|nil nil removes the list
--- @return loomworks.SavedTestDecl|nil
function M.with_entries(_decl, entries)
    if entries == nil then return nil end
    return { entries = M.index_entries(vim.deepcopy(entries)) }
end

--- A comparable fingerprint of an effective list (names, args, working
--- directories, unknown keys), or "" for none.
--- @param entries loomworks.SavedTestEntry[]|nil
--- @return string
function M.fingerprint(entries)
    if not entries then return "" end
    local parts = {}
    for _, e in ipairs(entries) do
        if e.invalid ~= nil then
            parts[#parts + 1] = "\2" .. M.raw_text(e.invalid)
        else
            parts[#parts + 1] = e.name .. "\0" .. table.concat(e.args or {}, "\0")
                .. "\3" .. (e.working_dir or "") .. (e.extra and ("\3" .. M.raw_text(e.extra)) or "")
        end
    end
    return table.concat(parts, "\1")
end

--- An entry's display label: its name with ` #<k>` when the name repeats in
--- its list (spec §16.16), or the raw element of an invalid entry.
--- @param e loomworks.SavedTestEntry
--- @return string
function M.entry_label(e)
    if e.decl_invalid then return "tests (not an array)" end
    if e.invalid ~= nil then return "invalid entry " .. M.raw_text(e.invalid) end
    if e.repeated then return e.name .. " #" .. tostring(e.index) end
    return e.name
end

--- An entry's test id (spec §8.9.2): `<kind>:<name>`, with `#<k>` for the
--- k-th occurrence (k ≥ 2) of a repeated name. `kind` defaults to "target"
--- (unknown kind, or a missing entry).
--- @param e loomworks.SavedTestEntry
--- @param kind "launch"|"target"|nil
--- @return string
function M.entry_id(e, kind)
    local name = e.name or ("<invalid " .. M.raw_text(e.invalid) .. ">")
    local id = (kind or "target") .. ":" .. name
    if e.name and (e.index or 1) >= 2 then id = id .. "#" .. tostring(e.index) end
    return id
end

--- A copy of a module section (type_config) without `tests` in any
--- configuration table — what a module sees (spec §1.3.4: a module never sees
--- the field). The project-wide `tests` is lifted out at load time
--- (`config._extract_tests`); it is removed here too, defensively.
--- Returns the input unchanged when there is nothing to strip.
--- @param tc table|nil
--- @return table|nil
function M.strip_from_type_config(tc)
    if type(tc) ~= "table" then return tc end
    local cfgs = tc.configurations
    local has = tc.tests ~= nil
    if not has and type(cfgs) == "table" then
        for _, c in pairs(cfgs) do
            if type(c) == "table" and c.tests ~= nil then has = true; break end
        end
    end
    if not has then return tc end
    local copy = {}
    for k, v in pairs(tc) do copy[k] = v end
    copy.tests = nil
    if type(cfgs) == "table" then
        local nc = {}
        for name, c in pairs(cfgs) do
            if type(c) == "table" and c.tests ~= nil then
                local cc = {}
                for k, v in pairs(c) do cc[k] = v end
                cc.tests = nil
                nc[name] = cc
            else
                nc[name] = c
            end
        end
        copy.configurations = nc
    end
    return copy
end

--- Graft each user configuration's declared `tests` onto a module's
--- `info().configurations` (the module never saw it, §1.3.4). Generated
--- entries get none: a generated configuration has no persisted table.
--- @param configurations table<string, table>|nil info().configurations (mutated)
--- @param declared table<string, table>|nil type_config.configurations as declared
function M.adopt_declared(configurations, declared)
    if type(configurations) ~= "table" then return end
    for name, entry in pairs(configurations) do
        if type(entry) == "table" then
            if entry.is_user then
                local d = type(declared) == "table" and declared[name] or nil
                entry.tests = type(d) == "table" and d.tests or nil
            else
                entry.tests = nil
            end
        end
    end
end

--- "App/Tests" for a configuration source, "App (project-wide)" for a project.
--- @param source loomworks.Configuration|loomworks.Project|nil
--- @return string
function M.level_label(source)
    if not source then return "?" end
    if source._project then
        return tostring(source._project.key) .. "/" .. tostring(source.name)
    end
    return tostring(source.key) .. " (project-wide)"
end

--- How a configuration got its list: "own", "inherited from <cfg>" or
--- "project-wide".
--- @param source loomworks.Configuration|loomworks.Project|nil
--- @param cfg loomworks.Configuration|nil the configuration asked about
--- @return string
function M.source_text(source, cfg)
    if not source then return "none" end
    if source._project then
        if cfg and source == cfg then return "own" end
        return "inherited from " .. tostring(source.name)
    end
    return "project-wide"
end

--- Find a build target by key, then by display name (the lookup a
--- target-backed launch uses).
--- @param targets table<string, loomworks.Target>
--- @param name string
--- @return loomworks.Target|nil
local function find_target(targets, name)
    local t = targets[name]
    if t then return t end
    for _, cand in pairs(targets) do
        if cand.display_name and cand:display_name() == name then return cand end
    end
    return nil
end

--- Resolve a name against a unit's parsed build targets only.
--- @param targets table<string, loomworks.Target>|nil unit.targets (nil = unknown)
--- @param name string
--- @return "ok"|"missing"|"not executable"|"unknown" state
--- @return loomworks.Target|nil target
function M.resolve(targets, name)
    if type(targets) ~= "table" then return "unknown", nil end
    local t = find_target(targets, name)
    if not t then return "missing", nil end
    if not (t.is_executable and t:is_executable()) then return "not executable", t end
    return "ok", t
end

--- @class loomworks.SavedTestResolution
--- @field state "ok"|"missing"|"unknown" ok = runnable program known (or a command launch)
--- @field kind "launch"|"target"|nil resolved kind (nil when unknown or unresolvable)
--- @field launch table|nil the launch configuration (kind = "launch")
--- @field target loomworks.Target|nil the build target (a `target` entry, or a target-backed launch's)
--- @field also_target boolean|nil a same-named executable build target exists (kind = "launch")
--- @field reason string|nil why it is missing, e.g. "not a target or launch of App/Tests"

--- Resolve one saved entry (spec §1.3.4 "Resolution"): a launch
--- configuration of the project in the model first, otherwise an executable
--- build target of the unit. A launch the trust filter ignored as a whole is
--- missing — never resolved to a same-named build target.
--- The entry's name is matched against `ctx.project`'s launch configurations
--- (a saved entry is a name a file supplies), or against the plain
--- `ctx.launches` declarations (name → declared table) when no project is given.
--- @param e loomworks.SavedTestEntry
--- @param ctx { project: loomworks.Project|nil, launches: table<string, table>|nil, launch_ignored: (fun(name: string): boolean)|nil, targets: table<string, loomworks.Target>|nil, level: string|nil }
--- @return loomworks.SavedTestResolution
function M.resolve_entry(e, ctx)
    local level = ctx.level or "?"
    if e.invalid ~= nil then
        return { state = "missing", reason = "invalid entry at " .. level
            .. ' (expected "Name", ["Name", args…] or { "name": …, … })' }
    end
    local name = e.name
    local targets = type(ctx.targets) == "table" and ctx.targets or nil
    local l
    if ctx.project then
        local launch = ctx.project:find_launch(name)
        l = (launch and not launch:is_invalid()) and launch or nil
    else
        l = type(ctx.launches) == "table" and ctx.launches[name] or nil
    end
    if type(l) == "table" then
        -- A launch of the model is the launch, whatever its shape: one with
        -- neither `command` nor `target` is missing, never the same-named
        -- build target.
        local r = { state = "ok", kind = "launch", launch = l }
        if targets then
            local same = find_target(targets, name)
            r.also_target = (same and same.is_executable and same:is_executable()) and true or nil
        end
        if not (l.command or l.target) then
            r.state = "missing"
            r.reason = "launch '" .. name .. "' of " .. level .. " has neither a command nor a target"
        elseif l.target then
            if not targets then
                r.state = "unknown"
            else
                local t = find_target(targets, l.target)
                if not (t and t.is_executable and t:is_executable()) then
                    r.state = "missing"
                    r.reason = "launch '" .. name .. "' of " .. level .. " runs target '" .. tostring(l.target)
                        .. "', which is " .. (t and "not an executable" or "not a target") .. " (removed or renamed?)"
                else
                    r.target = t
                end
            end
        end
        return r
    end
    if ctx.launch_ignored and ctx.launch_ignored(name) then
        return { state = "missing", reason = "launch '" .. name .. "' of " .. level
            .. " is ignored (program settings are used only from your local config — lw help trust)" }
    end
    local state, t = M.resolve(targets, name)
    if state == "ok" then return { state = "ok", kind = "target", target = t } end
    if state == "unknown" then return { state = "unknown" } end
    return { state = "missing", target = t, reason = state == "not executable"
        and ("not an executable target of " .. level)
        or ("not a target or launch of " .. level .. " (removed or renamed?)") }
end

--- Whether the shared layer declared launch `name` of `project_key` but the
--- trust filter ignored it as a whole and the working copy does not supply it
--- (spec §17.6) — a saved entry naming it is missing (§1.3.4).
--- @param ignored table[]|nil the workspace's `_shared_ignored`
--- @param project loomworks.Project
--- @param name string
--- @return boolean
function M.launch_ignored(ignored, project, name)
    if project:find_launch(name) ~= nil then return false end
    for _, ig in ipairs(ignored or {}) do
        if ig.kind == "launch" and type(ig.path) == "table" and ig.path[2] == project.key
                and ig.path[4] == name then
            return true
        end
    end
    return false
end

return M
