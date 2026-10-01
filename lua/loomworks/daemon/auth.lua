--- loomworks/daemon/auth.lua — the mutual handshake proofs (spec §19.8).
---
---   K = HMAC-SHA256(machine key §17.2, "loomworks-daemon-v1")
---   server_proof = HMAC(K, "server\n" .. E .. "\n" .. Nc .. "\n" .. Ns)
---   client_proof = HMAC(K, "client\n" .. E .. "\n" .. Ns .. "\n" .. Nc)
---
--- E is the endpoint address (from the handle, or the one the daemon bound),
--- Nc / Ns 32 random bytes as hex. The server proves knowledge of K first, so
--- a process squatting the endpoint cannot impersonate the daemon; neither
--- side ever sends K or anything derived from it but the bound proofs.
--- Proofs are compared in constant time.

local trust = require("loomworks.trust")

local M = {}

M.LABEL = "loomworks-daemon-v1"

local function from_hex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

--- The daemon key K (raw bytes), or nil + error (no machine key).
--- @return string|nil key, string|nil err
function M.key()
    local mk, err = trust.key(true)
    if not mk then return nil, err end
    return from_hex(trust.hmac_sha256_hex(mk, M.LABEL))
end

--- 32 random bytes as hex.
--- @return string|nil nonce, string|nil err
function M.nonce()
    local uv = vim.uv or vim.loop
    local ok, bytes = pcall(uv.random, 32)
    if not ok or type(bytes) ~= "string" or #bytes ~= 32 then
        return nil, "no secure random source"
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- Is `n` a well-formed nonce (64 hex digits)?
--- @param n any
--- @return boolean
function M.valid_nonce(n)
    return type(n) == "string" and #n == 64 and n:match("^%x+$") ~= nil
end

--- @param key string K
--- @param endpoint string E
--- @param nc string client nonce
--- @param ns string server nonce
--- @return string
function M.server_proof(key, endpoint, nc, ns)
    return trust.hmac_sha256_hex(key, "server\n" .. endpoint .. "\n" .. nc .. "\n" .. ns)
end

--- @param key string K
--- @param endpoint string E
--- @param nc string client nonce
--- @param ns string server nonce
--- @return string
function M.client_proof(key, endpoint, nc, ns)
    return trust.hmac_sha256_hex(key, "client\n" .. endpoint .. "\n" .. ns .. "\n" .. nc)
end

--- Constant-time string comparison.
--- @param a any
--- @param b any
--- @return boolean
function M.equal(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local bit = require("bit")
    local d = 0
    for i = 1, #a do d = bit.bor(d, bit.bxor(a:byte(i), b:byte(i))) end
    return d == 0
end

return M
