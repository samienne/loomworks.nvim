--- loomworks/config_transfer.lua — pure helpers for `lw export` / `lw import`
--- (spec §16.39). The workspace side (what is serialized, the in-memory load
--- of an import) lives on Workspace (`shared_snapshot`, `prepare_import`,
--- `commit_import`); this module holds what needs no workspace: inventories
--- and diffs of raw-shape config tables, the intent an import assigns, the
--- export's output text, and the program-settings review of an import.

local M = {}

local config_mod = require("loomworks.config")

--- The item kinds an export / import carries, in report order.
M.KINDS = { "projects", "configurations", "configuration_sets", "profiles" }

local function tbl(t) return type(t) == "table" and t or {} end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(tbl(t)) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

--- Inventory of a raw-shape config table — a loomworks.json, an export, or a
--- serialized working copy (the project shape is the same in all three). Maps
--- each kind to `{ [name] = content }`, where `content` is what a change is
--- judged on: a project without its configurations (they are their own
--- items), a configuration's table, a set's mappings plus its description,
--- a profile's table. Configurations are named `<project>:<configuration>`.
--- @param data table|nil
--- @return table<string, table<string, any>>
function M.inventory(data)
    local inv = { projects = {}, configurations = {}, configuration_sets = {}, profiles = {} }
    if type(data) ~= "table" then return inv end
    for key, def in pairs(tbl(data.projects)) do
        local content = def
        if type(def) == "table" then
            local ptype, tc = config_mod._extract_type(def)
            if ptype and type(tc) == "table" then
                for cname, cdef in pairs(tbl(tc.configurations)) do
                    inv.configurations[key .. ":" .. cname] = cdef
                end
                content = vim.deepcopy(def)
                content[ptype] = vim.deepcopy(tc)
                content[ptype].configurations = nil
            end
        end
        inv.projects[key] = content
    end
    local descs = tbl(data.configuration_set_descriptions)
    for name, mappings in pairs(tbl(data.configuration_sets)) do
        inv.configuration_sets[name] = { mappings = mappings, description = descs[name] }
    end
    for key, def in pairs(tbl(data.profiles)) do
        inv.profiles[key] = def
    end
    return inv
end

--- Per-kind difference between two inventories.
--- @param before table inventory
--- @param after table inventory
--- @return table<string, { before: integer, after: integer, added: string[], removed: string[], changed: string[] }>
function M.diff(before, after)
    local out = {}
    for _, kind in ipairs(M.KINDS) do
        local b, a = before[kind] or {}, after[kind] or {}
        local d = { before = 0, after = 0, added = {}, removed = {}, changed = {} }
        for _, k in ipairs(sorted_keys(b)) do
            d.before = d.before + 1
            if a[k] == nil then
                d.removed[#d.removed + 1] = k
            elseif not vim.deep_equal(b[k], a[k]) then
                d.changed[#d.changed + 1] = k
            end
        end
        for _, k in ipairs(sorted_keys(a)) do
            d.after = d.after + 1
            if b[k] == nil then d.added[#d.added + 1] = k end
        end
        out[kind] = d
    end
    return out
end

--- Item counts of an inventory, by kind.
--- @param inv table
--- @return table<string, integer>
function M.counts(inv)
    local c = {}
    for _, kind in ipairs(M.KINDS) do
        local n = 0
        for _ in pairs(inv[kind] or {}) do n = n + 1 end
        c[kind] = n
    end
    return c
end

--- "1 project, 2 configurations, …" for a counts table.
--- @param c table<string, integer>
--- @return string
function M.counts_text(c)
    local words = {
        projects = { "project", "projects" },
        configurations = { "configuration", "configurations" },
        configuration_sets = { "configuration set", "configuration sets" },
        profiles = { "profile", "profiles" },
    }
    local parts = {}
    for _, kind in ipairs(M.KINDS) do
        local n = c[kind] or 0
        parts[#parts + 1] = n .. " " .. words[kind][n == 1 and 1 or 2]
    end
    return table.concat(parts, ", ")
end

--- The intent map an import writes (spec §16.39 "Intent of imported items").
--- Every imported item gets an explicit intent: the item's intent in the
--- current working copy when it already holds the item (`current`), else
--- `local+shared` when the current published snapshot holds an item of the
--- same identity, else `local`. `mode` ("local" / "local+shared", the global
--- create-intent options) overrides both — except that a share request leaves
--- profiles on those rules (§2.4). Published items the import does not carry
--- become `shared` (reference-only), so no stale intent keeps them in the
--- working copy. Configuration keys are `<project>/<configuration>` (the
--- intent-map form of the working copy).
--- @param config table the validated import (internal `config.validate` shape)
--- @param baseline table|nil the published snapshot (internal shape)
--- @param mode string|nil nil | "local" | "local+shared"
--- @param current table|nil intents of the items the working copy holds now, by kind
--- @return table intent map
function M.intents(config, baseline, mode, current)
    baseline = baseline or {}
    current = current or {}
    local bp = tbl(baseline.projects)
    local function base_cfgs(key)
        return bp[key] and bp[key].type_config and tbl(bp[key].type_config.configurations) or {}
    end
    local function pick(kind, key, in_base, is_profile)
        if mode == "local" then return "local" end
        if mode == "local+shared" and not is_profile then return "local+shared" end
        local cur = tbl(current[kind])[key]
        if cur then return cur end
        return in_base and "local+shared" or "local"
    end
    local intent = { projects = {}, configurations = {}, configuration_sets = {}, profiles = {} }
    for key, proj in pairs(tbl(config.projects)) do
        intent.projects[key] = pick("projects", key, bp[key] ~= nil)
        local cfgs = proj.type_config and tbl(proj.type_config.configurations) or {}
        for cname in pairs(cfgs) do
            local ck = key .. "/" .. cname
            intent.configurations[ck] = pick("configurations", ck, base_cfgs(key)[cname] ~= nil)
        end
    end
    for name in pairs(tbl(config.configuration_sets)) do
        intent.configuration_sets[name] = pick("configuration_sets", name,
            tbl(baseline.configuration_sets)[name] ~= nil)
    end
    for key in pairs(tbl(config.profiles)) do
        intent.profiles[key] = pick("profiles", key, tbl(baseline.profiles)[key] ~= nil, true)
    end
    -- Published items the import leaves out: reference-only.
    for key in pairs(bp) do
        if intent.projects[key] == nil then intent.projects[key] = "shared" end
        for cname in pairs(base_cfgs(key)) do
            local ck = key .. "/" .. cname
            if intent.configurations[ck] == nil then intent.configurations[ck] = "shared" end
        end
    end
    for name in pairs(tbl(baseline.configuration_sets)) do
        if intent.configuration_sets[name] == nil then intent.configuration_sets[name] = "shared" end
    end
    for key in pairs(tbl(baseline.profiles)) do
        if intent.profiles[key] == nil then intent.profiles[key] = "shared" end
    end
    return intent
end

--- Singular labels of the item kinds, as the import summary names items.
M.KIND_LABEL = {
    projects = "project",
    configurations = "configuration",
    configuration_sets = "configuration set",
    profiles = "profile",
}

--- "<kind> <name>" for every project, configuration set and profile of
--- inventory `from` that inventory `to` lacks, sorted — the items a publish
--- of `to` would remove from a published snapshot `from` (spec §16.39).
--- @param from table inventory
--- @param to table inventory
--- @return string[]
function M.removed_names(from, to)
    local out = {}
    for _, kind in ipairs({ "projects", "configuration_sets", "profiles" }) do
        for _, k in ipairs(sorted_keys(from[kind])) do
            if tbl(to[kind])[k] == nil then out[#out + 1] = M.KIND_LABEL[kind] .. " " .. k end
        end
    end
    table.sort(out)
    return out
end

--- Intent changes between two `Workspace:_item_intents()` maps, for items in
--- both (spec §16.39 summary): `{ kind, name, from, to }`, in report order.
--- A configuration is named `<project>:<configuration>`.
--- @param before table
--- @param after table
--- @return { kind: string, name: string, from: string, to: string }[]
function M.intent_changes(before, after)
    local out = {}
    for _, kind in ipairs(M.KINDS) do
        local b, a = tbl(before[kind]), tbl(after[kind])
        for _, k in ipairs(sorted_keys(b)) do
            if a[k] ~= nil and a[k] ~= b[k] then
                local name = kind == "configurations" and (k:gsub("/", ":", 1)) or k
                out[#out + 1] = { kind = M.KIND_LABEL[kind], name = name, from = b[k], to = a[k] }
            end
        end
    end
    return out
end

--- The text `lw export` prints: exactly what a publish writes (`io.encode_json`),
--- except that DEL and C1 control characters — which can only occur inside
--- JSON strings — are written as `\u` escapes, so no such byte ever reaches a
--- terminal raw (spec §16.7, §16.39). The decoded value is unchanged.
--- @param raw table
--- @return string|nil text, string|nil err
function M.export_text(raw)
    local text, err = require("loomworks.io").encode_json(raw)
    if not text then return nil, err end
    text = text:gsub("\127", "\\u007f")
    text = text:gsub("\194([\128-\159])", function(c) return string.format("\\u%04x", c:byte()) end)
    return text
end

--- The program-settings review of an import (spec §16.39 "Trust"): the
--- program-bearing lines of the working copy the import will sign, each
--- marked `(new)` unless the current working copy holds the same line, and
--- the other-contents lines — in the review format of `lw trust` (§17.4).
--- @param before table current working copy (raw shape)
--- @param after table the working copy the import writes (raw shape)
--- @param modules table|nil module registry
--- @return string[] program lines, string[] other lines, integer new_count
function M.review(before, after, modules)
    local pf = require("loomworks.program_fields")
    local had = {}
    for _, l in ipairs((pf.review(before, modules))) do had[l] = true end
    local prog, other = pf.review(after, modules)
    local marked, new = {}, 0
    for i, l in ipairs(prog) do
        if had[l] then
            marked[i] = l
        else
            marked[i] = l .. "   (new)"
            new = new + 1
        end
    end
    return marked, other, new
end

return M
