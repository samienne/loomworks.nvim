--- loomworks/provision/sha256.lua — SHA-256 of binary data, for the host
--- binaries the plugin downloads (spec §19.16 "Host binary", step 5h.3).
---
--- `vim.fn.sha256` hashes a Lua string holding NUL and high bytes correctly
--- on the Neovim versions tested (0.12: such a string reaches Vimscript as a
--- Blob, which `sha256()` accepts). That conversion is not a documented
--- guarantee on every supported version (>= 0.9), so it is used only after a
--- known-answer check passes in this process; otherwise a pure-Lua
--- implementation (Lua BitOp, `bit`, which Neovim always provides) is used.
--- Both run on the main loop only (`vim.fn` is not callable in a fast event).

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror, tobit = bit.rshift, bit.lshift, bit.ror, bit.tobit
local byte, rep, char = string.byte, string.rep, string.char

local M = {}

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
for i = 1, 64 do K[i] = tobit(K[i]) end

local W = {}

--- Compress the 64-byte block of `s` starting at `i` into `H`.
local function block(s, i, H)
    for j = 0, 15 do
        local a, b, c, d = byte(s, i + j * 4, i + j * 4 + 3)
        W[j] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for j = 16, 63 do
        local w15, w2 = W[j - 15], W[j - 2]
        local s0 = bxor(ror(w15, 7), ror(w15, 18), rshift(w15, 3))
        local s1 = bxor(ror(w2, 17), ror(w2, 19), rshift(w2, 10))
        W[j] = tobit(W[j - 16] + s0 + W[j - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 0, 63 do
        local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = h + S1 + ch + K[j + 1] + W[j]
        local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + S0 + maj)
    end
    H[1], H[2], H[3], H[4] = tobit(H[1] + a), tobit(H[2] + b), tobit(H[3] + c), tobit(H[4] + d)
    H[5], H[6], H[7], H[8] = tobit(H[5] + e), tobit(H[6] + f), tobit(H[7] + g), tobit(H[8] + h)
end

--- The pure-Lua SHA-256 of `s`, lowercase hex.
--- @param s string
--- @return string
function M.lua(s)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for i = 1, 8 do H[i] = tobit(H[i]) end
    local len = #s
    local full = len - len % 64
    for i = 1, full, 64 do block(s, i, H) end
    -- The tail: the rest, 0x80, zeros, the bit length as 64-bit big endian.
    local bits = len * 8
    local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
    local pad = (55 - len) % 64
    local tail = s:sub(full + 1) .. "\128" .. rep("\0", pad)
        .. char(band(rshift(hi, 24), 255), band(rshift(hi, 16), 255), band(rshift(hi, 8), 255), band(hi, 255))
        .. char(math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256, math.floor(lo / 256) % 256, lo % 256)
    for i = 1, #tail, 64 do block(tail, i, H) end
    local out = {}
    for i = 1, 8 do out[i] = bit.tohex(H[i], 8) end
    return table.concat(out)
end

--- A string with NUL and high bytes, and its SHA-256 (the known answer the
--- native check compares against).
M.PROBE = "a\0b\0\0c" .. char(255, 0, 10, 13)
M.PROBE_SHA256 = "d113d7d8ccf053e2cc4e48dcbb08ecb67cc0f1b46071cfd728b3b79a3f4268a9"

local native_ok

--- Whether `vim.fn.sha256` hashes binary strings faithfully here (checked
--- once per process against `PROBE`).
--- @return boolean
function M.native_ok()
    if native_ok == nil then
        local ok, r = pcall(function() return vim.fn.sha256(M.PROBE) end)
        native_ok = ok and r == M.PROBE_SHA256
    end
    return native_ok
end

--- The SHA-256 of `s`, lowercase hex: `vim.fn.sha256` when it passed the
--- check, else the pure-Lua one.
--- @param s string
--- @return string
function M.hex(s)
    if M.native_ok() then return vim.fn.sha256(s) end
    return M.lua(s)
end

--- The SHA-256 of the file at `path`, or nil + why.
--- @param path string
--- @return string|nil sha256, string|nil err
function M.file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, "cannot read " .. path .. ": " .. tostring(err) end
    local data = f:read("*a")
    f:close()
    if not data then return nil, "cannot read " .. path end
    return M.hex(data)
end

return M
