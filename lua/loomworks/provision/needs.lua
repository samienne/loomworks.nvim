--- loomworks/provision/needs.lua — does an lw release offer what this plugin
--- needs (spec §19.16 "Plugin pin")?
---
--- Compares a release's binary descriptor (spec §16.41, the
--- `lw-<version>-descriptor.json` it publishes, the document `lw version
--- --json` prints) against the editor client: the transport ranges overlap
--- (loomworks.daemon.version.negotiate), the release's working-copy schemas
--- are no newer than ours (version.observer_compatible — what the observer
--- itself checks at connect), and every interface the observer uses
--- (loomworks.daemon.observer ROOT and FEATURES) is offered at its version.
---
--- One check, two uses: scripts/release/pin.lua refuses to pin (and the
--- release workflow refuses to publish) a release that fails it; ordinary CI
--- only warns, since a development checkout may need interfaces newer than
--- the last published release (the editor then degrades with feature notes;
--- developers point binary.path / LOOMWORKS_LW at a newer lw).

local M = {}

--- The interfaces the editor client uses: observer.ROOT, then its features.
--- @return { object: string, iface: string, v: integer, feature?: string }[]
function M.needed()
    local observer = require("loomworks.daemon.observer")
    local out = { observer.ROOT }
    for _, f in ipairs(observer.FEATURES) do out[#out + 1] = f end
    return out
end

--- Check a descriptor. Returns true, or false + the problems (one line each).
--- @param d any a decoded binary descriptor
--- @return boolean ok, string[] problems
function M.check(d)
    local problems = {}
    if type(d) ~= "table" then return false, { "no descriptor" } end
    if type(d.descriptor) ~= "number" or d.descriptor < 1 then
        problems[#problems + 1] = "not a binary descriptor (descriptor = " .. tostring(d.descriptor) .. ")"
    end
    local version = require("loomworks.daemon.version")
    local t = type(d.transport) == "table" and d.transport or {}
    local ok, what = version.observer_compatible({ protocol = t.max, protocol_min = t.min, schemas = d.schemas })
    if not ok and what == "protocol" then
        problems[#problems + 1] = string.format("transport %s..%s does not overlap ours %d..%d",
            tostring(t.min), tostring(t.max), version.PROTOCOL_MIN, version.PROTOCOL)
    elseif not ok then
        local s, ps = version.schemas(), type(d.schemas) == "table" and d.schemas or {}
        problems[#problems + 1] = string.format("schemas user %s / cache %s are not usable by ours (user %d / cache %d)",
            tostring(ps.user), tostring(ps.cache), s.user, s.cache)
    end
    local offered = require("loomworks.daemon.observer").offered_versions
    for _, want in ipairs(M.needed()) do
        local found = false
        for _, v in ipairs(offered(d.objects, want)) do
            if v == want.v then found = true end
        end
        if not found then
            problems[#problems + 1] = string.format("%s %s/%d is not offered", want.object, want.iface, want.v)
        end
    end
    return #problems == 0, problems
end

return M
