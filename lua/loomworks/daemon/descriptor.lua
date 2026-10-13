--- loomworks/daemon/descriptor.lua — the binary descriptor (spec §16.41):
--- what this lw implements, as `lw version --json` prints it and each release
--- publishes it (`lw-<version>-descriptor.json`, listed in the signed
--- SHA256SUMS).
---
--- It is the binary half of `Root.describe` (§19.20), computed without a
--- workspace and without a daemon: the same `binary` and `transport` fields,
--- the working-copy and cache `schemas` of the handshake (§19.9), the core
--- objects with their interface versions and schema digests exactly as a
--- daemon of this build mounts them (loomworks.daemon.core_interfaces on a
--- registry of loomworks.daemon.interfaces — nothing is listed twice), and
--- the root's methods. Interfaces a module mounts depend on the workspace and
--- are not part of it. The document's schema is
--- spec/protocol/meta/descriptor.schema.json.

local M = {}

--- The descriptor format version (bumped only for an incompatible change;
--- fields are only ever added).
M.FORMAT = 1

--- The descriptor of this build.
--- @return table
function M.describe()
    local version = require("loomworks.daemon.version")
    local interfaces = require("loomworks.daemon.interfaces")
    local reg = interfaces.new(nil, { validate_out = false })
    -- No service: the handlers are only built (each closes over it), never
    -- called; mounting checks them against the schema documents.
    require("loomworks.daemon.core_interfaces").mount(reg, {})
    local identity = version.identity()
    return {
        descriptor = M.FORMAT,
        binary = { lw_version = identity, impl = interfaces.IMPL, dev = version.is_dev(identity) },
        transport = { min = version.PROTOCOL_MIN, max = version.PROTOCOL },
        schemas = version.schemas(),
        objects = reg:object_list(true),
        root_methods = interfaces.ROOT_METHODS,
    }
end

local function is_list(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n == 0 then return false end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local function encode(v, indent)
    local t = type(v)
    if t ~= "table" then return vim.json.encode(v) end
    local pad, inner = string.rep("  ", indent), string.rep("  ", indent + 1)
    local parts = {}
    if is_list(v) then
        for _, e in ipairs(v) do parts[#parts + 1] = inner .. encode(e, indent + 1) end
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return "{}" end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts + 1] = inner .. vim.json.encode(k) .. ": " .. encode(v[k], indent + 1)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
end

--- The descriptor as canonical JSON: keys sorted, two-space indent, so equal
--- descriptors are equal bytes (the release asset is hashed).
--- @param doc table
--- @return string
function M.encode(doc)
    return encode(doc, 0)
end

return M
