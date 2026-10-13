--- loomworks/proto/documents.lua — the protocol's schema documents (spec
--- §19.20 "Schemas and conformance"): where they are, how an interface
--- version names its file, reading and decoding them, and resolving the
--- cross-document references between them.
---
--- Layout (relative to the protocol directory):
---
---   transport.json                         the transport layer's frames and error codes
---   meta/interface.schema.json             the interface-document meta-schema
---   meta/transport.schema.json             the transport-document meta-schema
---   interfaces/<namespace>/<Rest>.<v>.json one interface version
---                                          (`loomworks.Root/1` -> interfaces/loomworks/Root.1.json)
---   frozen/...                             the same layout: every version a stable release shipped
---
--- The protocol directory is `spec/protocol/` of a source tree, and
--- `loomworks/protocol/` inside a release bundle (beside this file's
--- `loomworks/`) or a fused executable's bundle.
---
--- Pure Lua (shared): plain `io` and `vim.json`.

local M = {}

local function read_file(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function source_dir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return nil end
    return (src:sub(2):gsub("\\", "/"):match("^(.*)/[^/]*$"))
end

local _dir -- memoized protocol directory (false: none on disk)

--- The on-disk protocol directory, or nil when this build reads its documents
--- from a fused bundle. `M._set_dir` overrides it (tests).
--- @return string|nil
function M.dir()
    if _dir ~= nil then return _dir or nil end
    local here = source_dir() -- <...>/loomworks/proto
    _dir = false
    if here then
        for _, d in ipairs({ here .. "/../protocol", here .. "/../../../spec/protocol" }) do
            if read_file(d .. "/transport.json") then
                _dir = d
                break
            end
        end
    end
    return _dir or nil
end

--- Test seam: set (or forget, nil) the protocol directory.
--- @param d string|nil
function M._set_dir(d) _dir = d end

--- Read a document's bytes by its path relative to the protocol directory.
--- @param rel string
--- @return string|nil text, string|nil err
function M.read(rel)
    local d = M.dir()
    if d then
        local s = read_file(d .. "/" .. rel)
        if s then return s end
        return nil, "no protocol document " .. rel
    end
    local ok, luvi = pcall(require, "luvi")
    if ok and type(luvi) == "table" and luvi.bundle and luvi.bundle.readfile then
        local okr, s = pcall(luvi.bundle.readfile, "loomworks/protocol/" .. rel)
        if okr and type(s) == "string" then return s end
    end
    return nil, "no protocol document " .. rel
end

--- Decode a document's text.
--- @param text string
--- @return table|nil doc, string|nil err
function M.decode(text)
    local ok, doc = pcall(vim.json.decode, text)
    if not ok or type(doc) ~= "table" then return nil, "malformed document: " .. tostring(doc) end
    return doc
end

--- The relative path of an interface version's document.
--- @param name string `loomworks.Root`
--- @param v integer
--- @return string|nil rel
function M.interface_path(name, v)
    local ns, rest = tostring(name):match("^([%w_]+)%.(.+)$")
    if not ns or type(v) ~= "number" then return nil end
    return string.format("interfaces/%s/%s.%d.json", ns, rest, v)
end

--- Parse an interface reference `<name>/<v>` (as a `$ref` document part).
--- @param s string
--- @return string|nil name, integer|nil v
function M.parse_iface_ref(s)
    local name, v = tostring(s):match("^([%w_%.]+)/(%d+)$")
    if not name then return nil end
    return name, tonumber(v)
end

--- Join a relative document path onto the directory of `base` (a relative
--- path itself), resolving `..`.
--- @param base string|nil
--- @param rel string
--- @return string
function M.join(base, rel)
    local parts = {}
    if base then
        for p in base:gmatch("[^/]+") do parts[#parts + 1] = p end
        parts[#parts] = nil -- the base file's name
    end
    for p in rel:gmatch("[^/]+") do
        if p == ".." then parts[#parts] = nil elseif p ~= "." then parts[#parts + 1] = p end
    end
    return table.concat(parts, "/")
end

--- A document set: loads documents by relative path (memoized) from a reader,
--- and resolves the document part of a `$ref` — `<name>/<v>` for an interface
--- version, a `*.json` path relative to the referring document — for
--- loomworks.proto.schema. `reader(rel)` defaults to `M.read`; the base of a
--- document is its relative path.
--- @class loomworks.proto.DocumentSet
--- @field reader fun(rel: string): string|nil, string|nil
--- @field docs table<string, table|false> decoded documents by relative path
--- @field texts table<string, string> their bytes
local Set = {}
Set.__index = Set

--- @param reader? fun(rel: string): string|nil, string|nil
--- @return loomworks.proto.DocumentSet
function M.set(reader)
    return setmetatable({ reader = reader or M.read, docs = {}, texts = {} }, Set)
end

--- Load a document by relative path.
--- @param rel string
--- @return table|nil doc, string|nil err
function Set:load(rel)
    local d = self.docs[rel]
    if d then return d end
    local text, err = self.reader(rel)
    if not text then return nil, err end
    local doc, derr = M.decode(text)
    if not doc then return nil, rel .. ": " .. derr end
    self.docs[rel], self.texts[rel] = doc, text
    return doc
end

--- Load an interface version's document.
--- @param name string
--- @param v integer
--- @return table|nil doc, string|nil rel_or_err
function Set:interface(name, v)
    local rel = M.interface_path(name, v)
    if not rel then return nil, "malformed interface name " .. tostring(name) end
    local doc, err = self:load(rel)
    if not doc then return nil, err end
    return doc, rel
end

--- The `resolve_doc` function of loomworks.proto.schema.validate over this set.
--- @return fun(name: string, base: string|nil): table|nil, string|nil
function Set:resolver()
    return function(name, base)
        local iname, v = M.parse_iface_ref(name)
        local rel = iname and M.interface_path(iname, v) or M.join(base, name)
        local doc = self:load(rel)
        if not doc then return nil end
        return doc, rel
    end
end

--- Validate `value` against the schema at `pointer` (a JSON pointer, e.g.
--- `/methods/describe/result`) of the document at `rel`.
--- @param rel string
--- @param pointer string
--- @param value any
--- @return boolean ok, string|nil err
function Set:validate(rel, pointer, value)
    local doc, err = self:load(rel)
    if not doc then return false, err end
    local schema_mod = require("loomworks.proto.schema")
    local node = schema_mod.pointer(doc, pointer)
    if node == nil then return false, "no schema at " .. rel .. "#" .. pointer end
    return schema_mod.validate(node, value, { doc = doc, base = rel, resolve_doc = self:resolver() })
end

return M
