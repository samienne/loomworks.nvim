--- loomworks/proto/schema_check.lua — the contract checks over the protocol's
--- schema documents (spec §19.20 "Schemas and conformance"):
---
---   * `lint(set, rel)` — the document is valid against its meta-schema
---     (`meta/interface.schema.json`, or `meta/transport.schema.json` for
---     `transport.json`), every schema node uses only the allowed keywords,
---     every `pattern` is in the portable subset, every `$ref` resolves, and
---     no document under `frozen/` is a draft;
---   * `ratchet(old_set, new_set, rel)` — the current document against its
---     frozen snapshot: parameters may only gain optional properties and
---     enum values (a client that sends a new value checks the interface's
---     schema digest / version first), results and signals only gain
---     properties, enum values (clients show an unknown value as neutral)
---     and alternatives; nothing is removed, renamed, retyped or made
---     required. Anything else is a new version. The transport document
---     (`transport.json`) is held to the same
---     rules frame by frame (frames a client sends as parameters, the others
---     as results); its error codes and definitions are never removed.
---
--- Pure Lua (shared); used by the tests and by any tool that checks a
--- document set.

local schema = require("loomworks.proto.schema")
local documents = require("loomworks.proto.documents")

local M = {}

local function sorted_keys(t)
    local ks = {}
    if type(t) == "table" then
        for k in pairs(t) do ks[#ks + 1] = k end
    end
    table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
    return ks
end

--- The meta-schema a document is checked against.
--- @param rel string
--- @return string
function M.meta_for(rel)
    if rel == "transport.json" then return "meta/transport.schema.json" end
    return "meta/interface.schema.json"
end

-- Walk every schema node of a document: calls fn(node, path) for each.
local function walk_schema(node, path, fn)
    if type(node) ~= "table" then return end
    fn(node, path)
    for _, k in ipairs({ "items", "additionalProperties" }) do
        if type(node[k]) == "table" then walk_schema(node[k], path .. "/" .. k, fn) end
    end
    for _, k in ipairs({ "properties", "$defs" }) do
        if type(node[k]) == "table" then
            for _, name in ipairs(sorted_keys(node[k])) do
                walk_schema(node[k][name], path .. "/" .. k .. "/" .. name, fn)
            end
        end
    end
    if type(node.oneOf) == "table" then
        for i, b in ipairs(node.oneOf) do walk_schema(b, path .. "/oneOf/" .. (i - 1), fn) end
    end
end

--- Every schema node of an interface, transport or meta document, with its
--- JSON pointer.
--- @param doc table
--- @param rel string
--- @return { node: table, path: string }[]
function M.schema_nodes(doc, rel)
    local out = {}
    local function add(node, path) out[#out + 1] = { node = node, path = path } end
    local function root(node, path) walk_schema(node, path, add) end
    if rel:match("^meta/") then
        root(doc, "")
        return out
    end
    for _, name in ipairs(sorted_keys(doc.methods)) do
        local m = doc.methods[name]
        if type(m) == "table" then
            for _, k in ipairs({ "params", "result" }) do
                if m[k] ~= nil then root(m[k], "/methods/" .. name .. "/" .. k) end
            end
            if type(m.task) == "table" then
                for _, k in ipairs({ "meta", "result" }) do
                    if m.task[k] ~= nil then root(m.task[k], "/methods/" .. name .. "/task/" .. k) end
                end
            end
        end
    end
    for _, name in ipairs(sorted_keys(doc.signals)) do
        local s = doc.signals[name]
        if type(s) == "table" and s.args ~= nil then root(s.args, "/signals/" .. name .. "/args") end
    end
    if doc.subscribe_args ~= nil then root(doc.subscribe_args, "/subscribe_args") end
    for _, name in ipairs(sorted_keys(doc.frames)) do root(doc.frames[name], "/frames/" .. name) end
    for _, name in ipairs(sorted_keys(doc["$defs"])) do root(doc["$defs"][name], "/$defs/" .. name) end
    return out
end

--- Lint one document of a set. Returns the list of problems (empty: clean).
--- @param set loomworks.proto.DocumentSet
--- @param rel string
--- @return string[]
function M.lint(set, rel)
    local problems = {}
    local function bad(fmt, ...) problems[#problems + 1] = rel .. ": " .. string.format(fmt, ...) end
    local doc, err = set:load(rel)
    if not doc then
        bad("%s", tostring(err))
        return problems
    end
    -- Against the meta-schema (the meta-schemas themselves only by keyword).
    if not rel:match("^meta/") then
        local ok, verr = set:validate(M.meta_for(rel), "", doc)
        if not ok then bad("not valid against %s: %s", M.meta_for(rel), tostring(verr)) end
    end
    -- A frozen snapshot is what a stable release shipped: never a draft.
    if rel:match("^frozen/") and doc.status == "draft" then
        bad("a draft is never frozen (status draft under frozen/)")
    end
    -- An interface document's name and version agree with its path.
    if doc.interface ~= nil then
        local want = documents.interface_path(doc.interface, doc.version)
        if want ~= rel and not rel:match("^frozen/") then
            bad("names %s/%s but lives at %s (expected %s)", tostring(doc.interface), tostring(doc.version), rel,
                tostring(want))
        end
        for _, mname in ipairs(sorted_keys(doc.methods)) do
            if not tostring(mname):match("^[a-z][a-z0-9_]*$") then bad("method %s is not snake_case", mname) end
        end
        for _, sname in ipairs(sorted_keys(doc.signals)) do
            if not tostring(sname):match("^[a-z][a-z0-9_]*$") then bad("signal %s is not snake_case", sname) end
        end
    end
    local resolve = set:resolver()
    for _, e in ipairs(M.schema_nodes(doc, rel)) do
        for _, k in ipairs(sorted_keys(e.node)) do
            if not schema.KEYWORDS[k] then bad("%s: keyword '%s' is not allowed", e.path == "" and "/" or e.path, k) end
        end
        if e.node.pattern ~= nil then
            local p, perr = schema.translate_pattern(e.node.pattern)
            if not p then bad("%s: pattern %s is outside the portable subset (%s)", e.path, tostring(e.node.pattern), perr) end
        end
        if type(e.node["$ref"]) == "string" then
            local target, _, rerr = schema.resolve_ref(e.node["$ref"], { doc = doc, base = rel, resolve_doc = resolve })
            if not target then bad("%s: %s", e.path, tostring(rerr)) end
        end
    end
    return problems
end

-- ---------------------------------------------------------------------------
-- Additive ratchet
-- ---------------------------------------------------------------------------

local function type_set(node)
    local t = node.type
    if t == nil then return nil end
    local s = {}
    for _, n in ipairs(type(t) == "table" and t or { t }) do s[n] = true end
    return s
end

local function set_text(s)
    if not s then return "any" end
    local ks = sorted_keys(s)
    return table.concat(ks, "|")
end

local function same_set(a, b)
    if a == nil or b == nil then return a == b end
    for k in pairs(a) do if not b[k] then return false end end
    for k in pairs(b) do if not a[k] then return false end end
    return true
end

local function list_set(l)
    local s = {}
    for _, v in ipairs(l or {}) do s[v] = true end
    return s
end

--- Compare an old schema node with the new one in a direction: "in" (the
--- client sends it: parameters) or "out" (the daemon sends it: results,
--- signals, task meta and results).
local function compare(st, old, new, oc, nc, dir, path)
    -- Follow references on each side (each in its own document set).
    local guard = 0
    while type(old) == "table" and old["$ref"] and guard < 32 do
        local key = tostring(oc.base) .. "|" .. old["$ref"] .. "|" .. dir
        local t, tc = schema.resolve_ref(old["$ref"], oc)
        if not t then return st.bad(path, "unresolved old reference " .. old["$ref"]) end
        if type(new) == "table" and new["$ref"] then
            local nt, ncc = schema.resolve_ref(new["$ref"], nc)
            if not nt then return st.bad(path, "unresolved reference " .. new["$ref"]) end
            key = key .. "|" .. tostring(ncc.base) .. new["$ref"]
            if st.seen[key] then return end
            st.seen[key] = true
            new, nc = nt, ncc
        end
        old, oc = t, tc
        guard = guard + 1
    end
    while type(new) == "table" and new["$ref"] and guard < 64 do
        local nt, ncc = schema.resolve_ref(new["$ref"], nc)
        if not nt then return st.bad(path, "unresolved reference " .. new["$ref"]) end
        new, nc = nt, ncc
        guard = guard + 1
    end
    if type(old) ~= "table" or type(new) ~= "table" then
        if old ~= new then st.bad(path, "changed") end
        return
    end
    if not same_set(type_set(old), type_set(new)) then
        st.bad(path, "retyped from " .. set_text(type_set(old)) .. " to " .. set_text(type_set(new)))
    end
    if old.const ~= nil or new.const ~= nil then
        if not schema.equal(old.const, new.const) then st.bad(path, "constant changed") end
    end
    for _, k in ipairs({ "minimum", "maximum", "pattern" }) do
        if old[k] ~= new[k] then st.bad(path, k .. " changed") end
    end
    if old.enum ~= nil or new.enum ~= nil then
        local os_, ns = list_set(old.enum), list_set(new.enum)
        if old.enum == nil or new.enum == nil then
            st.bad(path, "enum added or removed")
        else
            for v in pairs(os_) do
                if not ns[v] then st.bad(path, "enum value " .. tostring(v) .. " removed") end
            end
            -- Gaining a value is additive in every position: a client that
            -- sends a new parameter value checks the interface's schema
            -- digest / version first, and a client reading a result or
            -- signal shows a value it does not know as neutral.
        end
    end
    -- Properties.
    local op, np = old.properties or {}, new.properties or {}
    for _, k in ipairs(sorted_keys(op)) do
        if np[k] == nil then
            st.bad(path, "property '" .. k .. "' removed")
        else
            compare(st, op[k], np[k], oc, nc, dir, path .. "/properties/" .. k)
        end
    end
    local oreq, nreq = list_set(old.required), list_set(new.required)
    if dir == "in" then
        for k in pairs(nreq) do
            if not oreq[k] then st.bad(path, "parameter '" .. k .. "' made required") end
        end
    else
        for k in pairs(oreq) do
            if not nreq[k] then st.bad(path, "'" .. k .. "' no longer required (old clients rely on it)") end
        end
    end
    -- additionalProperties: the same kind; schemas compared.
    local oa, na = old.additionalProperties, new.additionalProperties
    if type(oa) == "table" and type(na) == "table" then
        compare(st, oa, na, oc, nc, dir, path .. "/additionalProperties")
    elseif oa ~= na and not (type(oa) == "table" and type(na) == "table") then
        st.bad(path, "additionalProperties changed")
    end
    if old.items ~= nil or new.items ~= nil then
        if old.items == nil or new.items == nil then
            st.bad(path, "items added or removed")
        else
            compare(st, old.items, new.items, oc, nc, dir, path .. "/items")
        end
    end
    if old.oneOf ~= nil or new.oneOf ~= nil then
        local ol, nl = old.oneOf or {}, new.oneOf or {}
        if old.oneOf == nil or new.oneOf == nil then
            st.bad(path, "oneOf added or removed")
        elseif #nl < #ol or (dir == "in" and #nl ~= #ol) then
            st.bad(path, "alternatives changed from " .. #ol .. " to " .. #nl)
        else
            for i = 1, #ol do compare(st, ol[i], nl[i], oc, nc, dir, path .. "/oneOf/" .. (i - 1)) end
        end
    end
end

--- The frames a client sends (compared as parameters); every other frame is
--- the daemon's (compared as results).
M.CLIENT_FRAMES = { hello = true, auth = true, call = true }

-- The transport document against its frozen copy: frames, error codes and
-- definitions are never removed; each frame is compared in its direction.
function M._ratchet_transport(st, old, new, oc, nc)
    if (tonumber(new.transport) or 0) < (tonumber(old.transport) or 0) then
        st.bad("/transport", "lowered")
    end
    for _, name in ipairs(sorted_keys(old.frames)) do
        local nf = new.frames and new.frames[name]
        local p = "/frames/" .. name
        if nf == nil then
            st.bad(p, "frame removed")
        else
            compare(st, old.frames[name], nf, oc, nc, M.CLIENT_FRAMES[name] and "in" or "out", p)
        end
    end
    for _, code in ipairs(sorted_keys(old.error_codes)) do
        if not (new.error_codes and new.error_codes[code]) then
            st.bad("/error_codes/" .. code, "error code removed")
        end
    end
    for _, name in ipairs(sorted_keys(old["$defs"])) do
        if not (new["$defs"] and new["$defs"][name]) then st.bad("/$defs/" .. name, "definition removed") end
    end
end

--- Check the current document `rel` of `new_set` against its frozen copy in
--- `old_set` (same relative path). Returns the problems (empty: additive).
--- @param old_set loomworks.proto.DocumentSet
--- @param new_set loomworks.proto.DocumentSet
--- @param rel string
--- @return string[]
function M.ratchet(old_set, new_set, rel)
    local problems = {}
    local old, oerr = old_set:load(rel)
    local new, nerr = new_set:load(rel)
    if not old then return { rel .. ": no frozen copy: " .. tostring(oerr) } end
    if not new then return { rel .. ": removed (" .. tostring(nerr) .. ") — a shipped version is never removed" } end
    local st = { seen = {} }
    function st.bad(path, what)
        if rel == "transport.json" then
            problems[#problems + 1] = string.format("%s%s: %s — a breaking transport change: make transport %d",
                rel, path, what, (tonumber(new.transport) or 0) + 1)
            return
        end
        problems[#problems + 1] = string.format("%s%s: %s — make version %d", rel, path,
            what, (tonumber(new.version) or 0) + 1)
    end
    local oc = { doc = old, base = rel, resolve_doc = old_set:resolver() }
    local nc = { doc = new, base = rel, resolve_doc = new_set:resolver() }
    if rel == "transport.json" then
        M._ratchet_transport(st, old, new, oc, nc)
        return problems
    end
    for _, k in ipairs({ "interface", "version" }) do
        if old[k] ~= new[k] then st.bad("/" .. k, "changed") end
    end
    for _, k in ipairs({ "same_build", "internal", "frozen", "types_only" }) do
        if (old[k] == true) ~= (new[k] == true) then st.bad("/" .. k, "changed") end
    end
    for _, name in ipairs(sorted_keys(old.methods)) do
        local om, nm = old.methods[name], new.methods and new.methods[name]
        local p = "/methods/" .. name
        if not nm then
            st.bad(p, "method removed")
        else
            compare(st, om.params, nm.params, oc, nc, "in", p .. "/params")
            compare(st, om.result, nm.result, oc, nc, "out", p .. "/result")
            if (om.task ~= nil) ~= (nm.task ~= nil) then
                st.bad(p, "task-streamed changed")
            elseif om.task then
                compare(st, om.task.meta, nm.task.meta, oc, nc, "out", p .. "/task/meta")
                compare(st, om.task.result, nm.task.result, oc, nc, "out", p .. "/task/result")
            end
            if (om.needs_env == true) ~= (nm.needs_env == true) then st.bad(p, "needs_env changed") end
            if (om.mutates == true) ~= (nm.mutates == true) then st.bad(p, "mutates changed") end
            local ne = list_set(nm.errors)
            for _, code in ipairs(om.errors or {}) do
                if not ne[code] then st.bad(p, "error code " .. code .. " removed") end
            end
        end
    end
    for _, name in ipairs(sorted_keys(old.signals)) do
        local os_, ns = old.signals[name], new.signals and new.signals[name]
        local p = "/signals/" .. name
        if not ns then
            st.bad(p, "signal removed")
        else
            compare(st, os_.args, ns.args, oc, nc, "out", p .. "/args")
            if (os_.initial == true) ~= (ns.initial == true) then st.bad(p, "initial changed") end
        end
    end
    -- Subscription args are parameters. None before: a new schema may only
    -- accept optional args (an old client sends none).
    if old.subscribe_args ~= nil then
        if new.subscribe_args == nil then st.bad("/subscribe_args", "subscription args removed")
        else compare(st, old.subscribe_args, new.subscribe_args, oc, nc, "in", "/subscribe_args") end
    elseif new.subscribe_args ~= nil and type(new.subscribe_args.required) == "table"
        and #new.subscribe_args.required > 0 then
        st.bad("/subscribe_args", "subscription args made required")
    end
    for _, code in ipairs(sorted_keys(old.errors)) do
        if not (new.errors and new.errors[code]) then st.bad("/errors/" .. code, "error code removed") end
    end
    -- Shared definitions are never removed (other documents reference them);
    -- their content is checked through the methods and signals using them.
    -- A types-only document (loomworks.Common) has no methods to reach its
    -- definitions through: each is held to the result rule.
    for _, name in ipairs(sorted_keys(old["$defs"])) do
        local nd = new["$defs"] and new["$defs"][name]
        if not nd then
            st.bad("/$defs/" .. name, "definition removed")
        elseif old.types_only then
            compare(st, old["$defs"][name], nd, oc, nc, "out", "/$defs/" .. name)
        end
    end
    return problems
end

return M
