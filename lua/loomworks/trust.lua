--- loomworks/trust.lua — Machine signatures for loomworks-written workspace
--- state (spec §17).
---
--- A workspace directory may come from anywhere (a clone, an archive, a copy
--- from another machine), so the `.nvim/` files inside it are untrusted input
--- until proven otherwise. Every `.nvim/` file loomworks writes that feeds
--- execution — the working copy (`loomworks.user.json`), the build cache
--- (`loomworks.cache.json`) and the health cache (`loomworks.health.json`) —
--- carries an HMAC-SHA256 made with a per-machine secret key that lives in the
--- per-user data directory, never in a repository. A file whose signature does
--- not verify was not written by loomworks on this machine (it was copied in,
--- edited by hand, or written by an earlier loomworks) and is not used until
--- the user decides (spec §17.4).
---
--- File format. The signature is the FIRST member of the top-level object, on
--- its own line, exactly:
---
---     {
---       "_sig": "<64 lowercase hex>",
---       ...the rest of the file, byte for byte...
---
--- The signed bytes are the file with that member removed (`{` followed by
--- everything after the member's comma). Signing the exact bytes avoids any
--- JSON canonicalization question (number formatting, `{}` vs `[]`, escaping)
--- — the signed text IS the deterministic sorted encoding loomworks writes —
--- and a fixed first-line position cannot be confused with a nested `_sig`.
--- Older loomworks versions read the file as ordinary JSON (the extra member is
--- ignored). The MAC input binds the file role (`kind`) so a signed cache cannot
--- be renamed into a working copy:
---
---     mac = HMAC-SHA256(key, "loomworks-sig-v1\n" .. kind .. "\n" .. sha256_hex(signed bytes))
---
--- The key is 32 random bytes stored as 64 hex characters in
--- `<data dir>/trust.key` (`%LOCALAPPDATA%\loomworks` on Windows,
--- `$XDG_DATA_HOME/loomworks` or `~/.local/share/loomworks` elsewhere — the same
--- directory the `lw` host uses, so the editor and the CLI share it), created
--- on first use with owner-only permissions where the OS has them.
---
--- Host-neutral: runs identically under Neovim and the standalone host (the
--- HMAC is pure Lua over LuaJIT's `bit`; the content digest is the host's
--- `vim.fn.sha256`, which both hosts implement as standard SHA-256).

local M = {}

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift, ror = bit.rshift, bit.lshift, bit.ror
local tobit = bit.tobit

local function uv() return vim.uv or vim.loop end

--- File roles that carry a signature. The value is the file's basename under
--- `<root>/.nvim/`.
M.FILES = {
    user = "loomworks.user.json",
    cache = "loomworks.cache.json",
    health = "loomworks.health.json",
}

M.SIG_VERSION = "loomworks-sig-v1"

-- ---------------------------------------------------------------------------
-- SHA-256 (pure Lua, for the short HMAC inputs; binary-safe)
-- ---------------------------------------------------------------------------

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

local function add(...)
    local s = 0
    for i = 1, select("#", ...) do s = s + select(i, ...) end
    return tobit(s % 4294967296)
end

--- SHA-256 of an arbitrary byte string, as 32 raw bytes.
--- @param msg string
--- @return string
function M._sha256_raw(msg)
    local len = #msg
    local extra = 64 - ((len + 9) % 64)
    if extra == 64 then extra = 0 end
    local bitlen = len * 8
    local tail = { "\128", string.rep("\0", extra) }
    -- 64-bit big-endian length (messages here are far below 2^32 bits' high word)
    local hi = math.floor(bitlen / 4294967296)
    local lo = bitlen % 4294967296
    local function be32(n)
        return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255),
            band(rshift(n, 8), 255), band(n, 255))
    end
    tail[#tail + 1] = be32(hi) .. be32(lo)
    msg = msg .. table.concat(tail)

    local h0, h1, h2, h3 = tobit(0x6a09e667), tobit(0xbb67ae85), tobit(0x3c6ef372), tobit(0xa54ff53a)
    local h4, h5, h6, h7 = tobit(0x510e527f), tobit(0x9b05688c), tobit(0x1f83d9ab), tobit(0x5be0cd19)
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
        end
        for i = 16, 63 do
            local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
            local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
            w[i] = add(w[i - 16], s0, w[i - 7], s1)
        end
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = add(h, S1, ch, K[i + 1], w[i])
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = add(S0, maj)
            h, g, f, e, d, c, b, a = g, f, e, add(d, t1), c, b, a, add(t1, t2)
        end
        h0, h1, h2, h3 = add(h0, a), add(h1, b), add(h2, c), add(h3, d)
        h4, h5, h6, h7 = add(h4, e), add(h5, f), add(h6, g), add(h7, h)
    end
    local function raw(n)
        return string.char(band(rshift(n, 24), 255), band(rshift(n, 16), 255),
            band(rshift(n, 8), 255), band(n, 255))
    end
    return raw(h0) .. raw(h1) .. raw(h2) .. raw(h3) .. raw(h4) .. raw(h5) .. raw(h6) .. raw(h7)
end

local function to_hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function from_hex(h)
    return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

--- HMAC-SHA256 (RFC 2104) of `msg` under `key` (raw bytes), as lowercase hex.
--- @param key string
--- @param msg string
--- @return string
function M.hmac_sha256_hex(key, msg)
    if #key > 64 then key = M._sha256_raw(key) end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local b = key:byte(i)
        ipad[i] = string.char(bxor(b, 0x36))
        opad[i] = string.char(bxor(b, 0x5c))
    end
    local inner = M._sha256_raw(table.concat(ipad) .. msg)
    return to_hex(M._sha256_raw(table.concat(opad) .. inner))
end

-- ---------------------------------------------------------------------------
-- Machine key
-- ---------------------------------------------------------------------------

local _key_path_override = nil
local _key_cache = nil -- { path = string, key = string(raw) }

--- Per-user data directory (shared with the `lw` host: boot.paths).
local function data_dir()
    local ok, paths = pcall(require, "boot.paths")
    if ok and type(paths) == "table" and type(paths.data_dir) == "function" then
        local dok, d = pcall(paths.data_dir)
        if dok and type(d) == "string" and d ~= "" then return d end
    end
    -- boot.paths is on the runtime path in both hosts; this fallback mirrors it.
    local env = function(n) local v = os.getenv(n); return (v and v ~= "") and v or nil end
    local o = env("LOOMWORKS_DATA_DIR")
    if o then return (o:gsub("\\", "/"):gsub("/+$", "")) end
    if package.config:sub(1, 1) == "\\" and env("LOCALAPPDATA") then
        return (env("LOCALAPPDATA"):gsub("\\", "/")) .. "/loomworks"
    end
    if env("XDG_DATA_HOME") then return (env("XDG_DATA_HOME"):gsub("\\", "/")) .. "/loomworks" end
    return ((env("HOME") or env("USERPROFILE") or "."):gsub("\\", "/")) .. "/.local/share/loomworks"
end

--- The per-user data directory (also the default home of the device locks,
--- spec §18.7).
--- @return string
function M.data_dir()
    return data_dir()
end

--- Path of the machine key file.
--- @return string
function M.key_path()
    return _key_path_override or (data_dir() .. "/trust.key")
end

--- Test seam: use a different key file (nil restores the default) and forget
--- any cached key.
--- @param path string|nil
function M._set_key_path(path)
    _key_path_override = path
    _key_cache = nil
end

--- Forget the in-memory key (next use re-reads the key file).
function M._reset() _key_cache = nil end

local function read_all(path)
    local fd = uv().fs_open(path, "r", 384)
    if not fd then return nil end
    local st = uv().fs_fstat(fd)
    local data = st and uv().fs_read(fd, st.size, 0) or nil
    uv().fs_close(fd)
    return data
end

local function mkdir_p(dir)
    if uv().fs_stat(dir) then return true end
    local parent = dir:match("^(.+)[/\\][^/\\]+$")
    if parent and parent ~= dir and not parent:match("^%a:$") then mkdir_p(parent) end
    uv().fs_mkdir(dir, 448) -- 0700
    return uv().fs_stat(dir) ~= nil
end

--- Load the machine key (raw bytes), creating it on first use.
--- @param create? boolean default true
--- @return string|nil key, string|nil err
function M.key(create)
    local path = M.key_path()
    if _key_cache and _key_cache.path == path then return _key_cache.key end
    local text = read_all(path)
    if not text and create ~= false then
        local dir = path:match("^(.+)[/\\][^/\\]+$")
        if dir then mkdir_p(dir) end
        local rnd = uv().random and uv().random(32) or nil
        if type(rnd) ~= "string" or #rnd ~= 32 then
            return nil, "no secure random source to create the trust key"
        end
        -- O_EXCL + owner-only mode: never overwrite an existing key (a lost
        -- race reads the winner's key below).
        local fd = uv().fs_open(path, "wx", 384) -- 0600
        if fd then
            uv().fs_write(fd, to_hex(rnd) .. "\n", 0)
            uv().fs_fsync(fd)
            uv().fs_close(fd)
        end
        text = read_all(path)
    end
    if not text then return nil, "cannot read the trust key at " .. path end
    local hex = text:match("^%s*(%x+)%s*$")
    if not hex or #hex ~= 64 then
        return nil, "the trust key at " .. path .. " is malformed (delete it to create a new one; "
            .. "every workspace's .nvim files then need `lw trust` / a reset)"
    end
    local key = from_hex(hex:lower())
    _key_cache = { path = path, key = key }
    return key
end

-- ---------------------------------------------------------------------------
-- Sign / verify
-- ---------------------------------------------------------------------------

local SIG_PREFIX = '{\n  "_sig": "'

--- MAC over `content` (the signed bytes) for a file role.
--- @param kind string one of M.FILES' keys
--- @param content string
--- @return string|nil hex, string|nil err
function M.mac(kind, content)
    local key, err = M.key(true)
    if not key then return nil, err end
    local digest = vim.fn.sha256(content)
    return M.hmac_sha256_hex(key, M.SIG_VERSION .. "\n" .. kind .. "\n" .. digest)
end

--- Split a file into (sig_hex, signed_content) when it carries a signature
--- line; nil when it does not.
--- @param text string
--- @return string|nil sig, string|nil content
function M.split(text)
    if type(text) ~= "string" or text:sub(1, #SIG_PREFIX) ~= SIG_PREFIX then return nil end
    local sig, comma = text:match('^(%x+)"(,?)\n', #SIG_PREFIX + 1)
    if not sig or #sig ~= 64 then return nil end
    local member_len = #SIG_PREFIX + 64 + 1 + #comma + 1 -- hex + quote + [comma] + newline
    -- Put back the newline that followed `{` so the signed bytes are the
    -- original encoding: "{\n" .. rest.
    return sig:lower(), "{\n" .. text:sub(member_len + 1)
end

--- Sign `content` (a JSON object text starting with `{`) for `kind`.
--- @param kind string
--- @param content string
--- @return string|nil signed_text, string|nil err
function M.sign(kind, content)
    if not M.FILES[kind] then return nil, "unknown signed file kind: " .. tostring(kind) end
    if type(content) ~= "string" or content:sub(1, 2) ~= "{\n" then
        return nil, "can only sign a JSON object written by loomworks (must start with `{` and a newline)"
    end
    local mac, err = M.mac(kind, content)
    if not mac then return nil, err end
    local rest = content:sub(3)
    local comma = rest:match("^%s*}") and "" or ","
    return SIG_PREFIX .. mac .. '"' .. comma .. "\n" .. rest
end

--- Constant-time-ish string equality (inputs are fixed-length hex).
local function same(a, b)
    if #a ~= #b then return false end
    local d = 0
    for i = 1, #a do d = bor(d, bxor(a:byte(i), b:byte(i))) end
    return d == 0
end

--- Verify a file's text for `kind`.
---   "valid"    — signed by this machine's key; `content` is the signed bytes
---                (the file minus the signature member), ready to decode.
---   "unsigned" — no signature member (hand-written, or an earlier loomworks);
---                `content` is the text as-is (for review only).
---   "invalid"  — a signature member that does not verify (copied from another
---                machine, or edited after signing); `content` is the text with
---                the member removed (for review only).
--- @param kind string
--- @param text string
--- @return "valid"|"unsigned"|"invalid" status, string content, string|nil err
function M.verify(kind, text)
    local sig, content = M.split(text)
    if not sig then return "unsigned", text end
    local mac, err = M.mac(kind, content)
    if not mac then return "invalid", content, err end
    if same(mac, sig) then return "valid", content end
    return "invalid", content
end

--- Encode a table exactly as loomworks writes JSON state (sorted, pretty).
--- @param tbl table
--- @return string
function M.encode(tbl)
    local io_mod = require("loomworks.io")
    return io_mod._pretty_json(io_mod.encode_sorted(tbl))
end

--- Kind of a `.nvim/` path by basename (nil when not a signed file).
--- @param path string
--- @return string|nil
function M.kind_for_path(path)
    local base = type(path) == "string" and path:match("([^/\\]+)$") or nil
    for kind, name in pairs(M.FILES) do
        if base == name then return kind end
    end
    return nil
end

--- Re-sign the file at `path` as it is now (the explicit "trust" decision):
--- the current text minus any signature member must decode to a JSON object.
--- The bytes the user reviewed are the bytes signed — pass `expected` (the
--- content that was shown) to refuse when the file changed in between.
--- @param path string
--- @param kind string
--- @param expected? string content previously returned by `verify`
--- @return boolean ok, string|nil err
function M.sign_file(path, kind, expected)
    local io_mod = require("loomworks.io")
    local text = io_mod.read_file(path)
    if not text then return false, "cannot read " .. path end
    local _, content = M.split(text)
    content = content or text
    if expected and expected ~= content then
        return false, path .. " changed while it was being reviewed — review it again"
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return false, path .. " is not valid JSON — fix or discard it"
    end
    -- Normalize to loomworks' own encoding so the file is signable in the fixed
    -- format (a hand-formatted file is re-encoded; its data is unchanged).
    if content:sub(1, 2) ~= "{\n" then
        decoded._sig = nil
        content = M.encode(decoded)
    end
    local signed, serr = M.sign(kind, content)
    if not signed then return false, serr end
    return io_mod.write_file_atomic(path, signed)
end

return M
