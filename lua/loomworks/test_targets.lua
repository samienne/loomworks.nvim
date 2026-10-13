--- loomworks/test_targets.lua — saved test targets (spec §1.3.4).
---
--- A pure helper with no workspace access: parses and serializes the generic
--- `tests` field of a project (the project-wide list, lifted out of the module
--- section like `description`) and of a user configuration, strips the field
--- from what a module sees, and formats a list's source for display. The
--- domain objects (Project, Configuration) own the declarations and the
--- inheritance walk; this module only knows the value shape:
---
---   "tests": { "targets": [ "Name", { "target": "Name", "args": ["…"] } ] }
---
--- Unknown keys of the `tests` object are kept verbatim and ignored.

local M = {}

--- @class loomworks.SavedTestEntry
--- @field target string build target name of the declaring project (unqualified)
--- @field args string[]|nil arguments passed verbatim after the results option

--- @class loomworks.SavedTestDecl
--- @field entries loomworks.SavedTestEntry[] parsed list, in run order, duplicates dropped
--- @field extra table<string, any>|nil unknown keys of the `tests` object, kept verbatim

--- One-shot warnings (duplicate / malformed entries in a hand-edited file).
M._warned = {}

local function warn_once(key, msg)
    if M._warned[key] then return end
    M._warned[key] = true
    if vim.schedule and vim.notify then
        vim.schedule(function() vim.notify(msg, vim.log.levels.WARN) end)
    end
end

--- Parse a raw `tests` value. Returns nil when there is no declaration (absent
--- value, or a `tests` object without a `targets` array). A duplicate name is
--- dropped (first occurrence kept) and a malformed element skipped, each with a
--- one-time warning naming `where` (e.g. "App/Tests").
--- @param raw any the `tests` value as read
--- @param where string|nil label for warnings
--- @return loomworks.SavedTestDecl|nil decl
--- @return any invalid a non-table `tests` value, kept to be written back unchanged
function M.parse(raw, where)
    if raw == nil then return nil, nil end
    if type(raw) ~= "table" then return nil, raw end
    local extra
    for k, v in pairs(raw) do
        if k ~= "targets" then
            extra = extra or {}
            extra[k] = v
        end
    end
    local list = raw.targets
    if type(list) ~= "table" then
        -- No list: keep the object's other keys, but nothing is declared.
        return extra and { entries = nil, extra = extra } or nil, nil
    end
    local entries, seen = {}, {}
    for _, el in ipairs(list) do
        local name, args
        if type(el) == "string" then
            name = el
        elseif type(el) == "table" and type(el.target) == "string" then
            name = el.target
            if type(el.args) == "table" then
                args = {}
                for _, a in ipairs(el.args) do args[#args + 1] = tostring(a) end
            end
        end
        if not name or name == "" then
            warn_once("bad|" .. tostring(where) .. "|" .. vim.inspect(el),
                "loomworks: " .. tostring(where or "?") .. ": ignoring a malformed saved test target "
                .. vim.inspect(el) .. " (expected a name or { target, args })")
        elseif seen[name] then
            warn_once("dup|" .. tostring(where) .. "|" .. name,
                "loomworks: " .. tostring(where or "?") .. ": saved test target '" .. name
                .. "' is listed twice; the first one is kept")
        else
            seen[name] = true
            entries[#entries + 1] = { target = name, args = args }
        end
    end
    return { entries = entries, extra = extra }, nil
end

--- Whether a parsed declaration declares a list (an explicit `[]` does).
--- @param decl loomworks.SavedTestDecl|nil
--- @return boolean
function M.declares(decl)
    return decl ~= nil and decl.entries ~= nil
end

--- Serialize one entry: a bare name, or `{ target, args }` when it has args.
--- @param e loomworks.SavedTestEntry
--- @return string|table
function M.serialize_entry(e)
    if e.args and #e.args > 0 then
        return { target = e.target, args = vim.deepcopy(e.args) }
    end
    return e.target
end

--- Serialize a declaration to its raw `tests` value (nil when nothing to write).
--- @param decl loomworks.SavedTestDecl|nil
--- @param invalid any preserved non-table value
--- @return any
function M.serialize(decl, invalid)
    if not decl then return invalid end
    local raw = {}
    for k, v in pairs(decl.extra or {}) do raw[k] = vim.deepcopy(v) end
    if decl.entries then
        local list = {}
        for i, e in ipairs(decl.entries) do list[i] = M.serialize_entry(e) end
        -- An explicit empty list is a declaration (§1.3.4); a plain empty
        -- table encodes as `[]`.
        raw.targets = list
    end
    if next(raw) == nil then return nil end
    return raw
end

--- A copy of a declaration with `entries` replaced (unknown keys kept).
--- With `entries == nil` the list is removed (the level inherits again).
--- @param decl loomworks.SavedTestDecl|nil
--- @param entries loomworks.SavedTestEntry[]|nil nil removes the list
--- @return loomworks.SavedTestDecl|nil
function M.with_entries(decl, entries)
    local extra = decl and decl.extra and vim.deepcopy(decl.extra) or nil
    if entries == nil and extra == nil then return nil end
    return { entries = entries and vim.deepcopy(entries) or nil, extra = extra }
end

--- A comparable fingerprint of an effective list (names + args), or "" for none.
--- @param entries loomworks.SavedTestEntry[]|nil
--- @return string
function M.fingerprint(entries)
    if not entries then return "" end
    local parts = {}
    for _, e in ipairs(entries) do
        parts[#parts + 1] = e.target .. "\0" .. table.concat(e.args or {}, "\0")
    end
    return table.concat(parts, "\1")
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

--- Resolve one saved entry against a unit's parsed build targets.
--- @param targets table<string, loomworks.Target>|nil unit.targets (nil = unknown)
--- @param name string
--- @return "ok"|"not built"|"missing"|"not executable"|"unknown" state
--- @return loomworks.Target|nil target
function M.resolve(targets, name)
    if type(targets) ~= "table" then return "unknown", nil end
    local t = targets[name]
    if not t then
        for _, cand in pairs(targets) do
            if cand.display_name and cand:display_name() == name then t = cand; break end
        end
    end
    if not t then return "missing", nil end
    if not (t.is_executable and t:is_executable()) then return "not executable", t end
    return "ok", t
end

return M
