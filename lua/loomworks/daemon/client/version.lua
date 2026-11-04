--- loomworks/daemon/client/version.lua — what the editor's daemon client
--- announces and checks in the version handshake (spec §19.9 "From protocol
--- 11"). The editor judges a daemon by the transport range only: the two
--- ranges must overlap. Working-copy and cache formats are the daemon's
--- business (it reads and writes them); what the editor needs beyond the
--- transport is the interfaces it calls, each with its own version (§19.20).

local M = {}

--- The newest transport this client speaks (spec §19.8).
M.PROTOCOL = 11

--- The oldest transport this client speaks: a daemon of protocol 10 is
--- observed through its broadcasts (no interfaces).
M.PROTOCOL_MIN = 10

--- The transport two ranges agree on: the highest in the overlap of
--- `[min, max]` and ours, or nil when they do not overlap. A peer that
--- states no `protocol_min` (protocol 10 and older) states `[max, max]`.
--- @param max integer|nil the peer's `protocol`
--- @param min integer|nil the peer's `protocol_min`
--- @return integer|nil
function M.negotiate(max, min)
    if type(max) ~= "number" then return nil end
    if type(min) ~= "number" or min > max then min = max end
    local hi = math.min(max, M.PROTOCOL)
    local lo = math.max(min, M.PROTOCOL_MIN)
    if hi < lo then return nil end
    return hi
end

--- May the editor observe a daemon that announced `peer` (its challenge, or
--- `welcome.daemon`)? Only when the transport ranges overlap; the daemon's
--- host version may differ. Returns true, or false + "protocol".
--- @param peer table|nil
--- @return boolean ok, string|nil what
function M.compatible(peer)
    if type(peer) ~= "table" or not M.negotiate(peer.protocol, peer.protocol_min) then return false, "protocol" end
    return true
end

--- The transport agreed with a daemon's announced range, within the range
--- this client announced (`opts.protocol` / `opts.protocol_min`: a test's
--- older client; default ours).
--- @param ch table the daemon's `{ protocol, protocol_min }`
--- @param opts table|nil
--- @return integer|nil
function M.agreed(ch, opts)
    local t = M.negotiate(ch.protocol, ch.protocol_min)
    local max = opts and opts.protocol
    if t and type(max) == "number" and t > max then
        local lo = math.max(type(ch.protocol_min) == "number" and ch.protocol_min or ch.protocol,
            opts.protocol_min or max)
        t = (max >= lo) and max or nil
    end
    return t
end

--- What the editor announces as its `lw_version` (spec §19.8): the plugin's
--- own version (loomworks.version), or nil when unknown (then not sent).
--- @return string|nil
function M.identity()
    return require("loomworks.version").get()
end

return M
