--- loomworks/daemon/identity.lua — the runtime slot (spec §19.7.1).
---
--- Runtimes are separated per slot: the operating-system user and, on
--- Windows, whether the process token is elevated. The identity string I is
---
---   * Windows — the token user's string SID, a space, and `elevated` or
---     `standard` (TokenElevation of the process token);
---   * POSIX   — the decimal effective uid (root is its own slot).
---
--- The slot token S is the first 16 hex digits of
--- SHA-256("loomworks-daemon-slot-v1" .. "\n" .. I), computed once per
--- process. S is opaque: it is only computed and compared, never parsed,
--- listed or derived from a file name. There is no fallback: a process whose
--- token or effective uid cannot be read has no slot, and every use of one
--- fails with an error naming why (it never shares another slot's files).
---
--- `process_identity(pid)` reads another process's I the same way (Windows:
--- OpenProcess + OpenProcessToken; Linux `/proc/<pid>/status`; macOS
--- `proc_pidinfo`), for the process scan (§19.6.1) and the legacy lock
--- (§19.6 "Legacy files"): a process whose identity cannot be read is of
--- another slot.

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- The domain-separation prefix of S (spec §19.7.1).
M.PREFIX = "loomworks-daemon-slot-v1"

-- ---------------------------------------------------------------------------
-- Test seams
-- ---------------------------------------------------------------------------

--- Replace this process's identity string (tests): a string, or nil to read
--- it from the OS again. Clears the cached slot.
--- @param I string|nil
function M._set_identity(I)
    M._identity_override = I
    M._cache = nil
end

--- Replace the reader of other processes' identities (tests):
--- `fn(pid) -> string|nil`, or nil for the OS reader.
M._process_probe = nil

-- ---------------------------------------------------------------------------
-- Windows (FFI: advapi32 + kernel32)
-- ---------------------------------------------------------------------------

local _w
local function win()
    if _w ~= nil then return _w or nil end
    _w = false
    local ok, ffi = pcall(require, "ffi")
    if not ok or ffi.os ~= "Windows" then return nil end
    for _, d in ipairs({
        "void* GetCurrentProcess(void);",
        "void* OpenProcess(uint32_t dwDesiredAccess, int bInheritHandle, uint32_t dwProcessId);",
        "int CloseHandle(void* hObject);",
        "void* LocalFree(void* p);",
        "int OpenProcessToken(void* process, uint32_t access, void** token);",
        "int GetTokenInformation(void* token, int cls, void* info, uint32_t len, uint32_t* ret);",
        "int ConvertSidToStringSidA(void* sid, char** str);",
    }) do
        pcall(ffi.cdef, d)
    end
    local okl, adv = pcall(ffi.load, "advapi32")
    if not okl then return nil end
    _w = { ffi = ffi, adv = adv, close = function(h) ffi.C.CloseHandle(h) end }
    return _w
end

local TOKEN_QUERY = 0x0008
local TOKEN_USER, TOKEN_ELEVATION = 1, 20
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

--- I of an open token handle, or nil + error.
local function token_identity(w, token)
    local ffi, adv = w.ffi, w.adv
    local sid, elevated
    local len = ffi.new("uint32_t[1]")
    adv.GetTokenInformation(token, TOKEN_USER, nil, 0, len)
    if len[0] > 0 then
        local buf = ffi.new("uint8_t[?]", len[0])
        if adv.GetTokenInformation(token, TOKEN_USER, buf, len[0], len) ~= 0 then
            local str = ffi.new("char*[1]")
            if adv.ConvertSidToStringSidA(ffi.cast("void**", buf)[0], str) ~= 0 then
                sid = ffi.string(str[0])
                ffi.C.LocalFree(str[0])
            end
        end
    end
    local e = ffi.new("uint32_t[1]")
    local rl = ffi.new("uint32_t[1]")
    if adv.GetTokenInformation(token, TOKEN_ELEVATION, e, 4, rl) ~= 0 then
        elevated = e[0] ~= 0
    end
    if not sid then return nil, "cannot read the token's user SID" end
    if elevated == nil then return nil, "cannot read the token's elevation" end
    return sid .. " " .. (elevated and "elevated" or "standard")
end

--- I of an open process handle, or nil + error. The token handle is closed
--- on every path, an FFI error included (it is then reported, not raised).
--- @param w table the FFI bindings (`ffi`, `adv`; tests may pass fakes)
local function win_token_identity(w, process)
    local ffi, adv = w.ffi, w.adv
    local tok = ffi.new("void*[1]")
    if adv.OpenProcessToken(process, TOKEN_QUERY, tok) == 0 then
        return nil, "cannot open the process token"
    end
    local ok, id, err = pcall(token_identity, w, tok[0])
    w.close(tok[0])
    if not ok then return nil, "cannot read the process token: " .. tostring(id) end
    return id, err
end
M._win_token_identity = win_token_identity

-- ---------------------------------------------------------------------------
-- POSIX
-- ---------------------------------------------------------------------------

--- The effective uid of this process, or nil + error.
local function own_euid()
    local ok, ffi = pcall(require, "ffi")
    if ok then
        pcall(ffi.cdef, "unsigned int geteuid(void);")
        local gok, v = pcall(function() return ffi.C.geteuid() end)
        if gok and v ~= nil then return tonumber(v) end
    end
    local f = io.open("/proc/self/status", "r")
    if f then
        local s = f:read("*a") or ""
        f:close()
        local e = s:match("\nUid:%s+%d+%s+(%d+)")
        if e then return tonumber(e) end
    end
    return nil, "cannot read the effective uid"
end

--- The effective uid of this process (POSIX; spec §19.7: the socket
--- directory, the process filter and the trust key's owner are checked
--- against it, never the real uid), or nil + error. Windows has none.
--- @return integer|nil euid, string|nil err
function M.euid()
    if M._euid_override then return M._euid_override end
    if is_win() then return nil, "no effective uid on Windows" end
    return own_euid()
end

--- Test seam: a fixed effective uid (nil reads it from the OS again).
M._euid_override = nil

-- ---------------------------------------------------------------------------
-- The slot
-- ---------------------------------------------------------------------------

--- This process's identity string I (§19.7.1), or nil + error.
--- @return string|nil I, string|nil err
function M.read_identity()
    if M._identity_override then return M._identity_override end
    if is_win() then
        local w = win()
        if not w then return nil, "no FFI access to advapi32" end
        return win_token_identity(w, w.ffi.C.GetCurrentProcess())
    end
    local e, err = own_euid()
    if not e then return nil, err end
    return tostring(e)
end

--- The slot token of an identity string.
--- @param I string
--- @return string
function M.token_of(I)
    -- Pure-Lua SHA-256 (loomworks.trust): no vim.fn, so the first use may be
    -- in a libuv callback of the editor host.
    local raw = require("loomworks.trust")._sha256_raw(M.PREFIX .. "\n" .. I)
    return (raw:sub(1, 8):gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- This process's identity I and slot token S, computed once (raises when
--- the identity cannot be read: there is no shared fallback slot).
--- @return { identity: string, slot: string }
local function cached()
    if M._cache then return M._cache end
    local I, err = M.read_identity()
    if not I then
        error("cannot determine this process's daemon slot (spec §19.7.1): " .. tostring(err), 0)
    end
    M._cache = { identity = I, slot = M.token_of(I) }
    return M._cache
end

--- This process's identity string I.
--- @return string
function M.identity() return cached().identity end

--- This process's slot token S (16 lowercase hex digits).
--- @return string
function M.slot() return cached().slot end

-- ---------------------------------------------------------------------------
-- Other processes
-- ---------------------------------------------------------------------------

--- The identity string of process `pid`, or nil when it cannot be read
--- (gone, access denied, no reader on this host).
--- @param pid integer
--- @return string|nil
function M.process_identity(pid)
    if M._process_probe then return M._process_probe(pid) end
    if type(pid) ~= "number" or pid <= 0 then return nil end
    if is_win() then
        local w = win()
        if not w then return nil end
        local h = w.ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
        if h == nil or w.ffi.cast("intptr_t", h) == 0 then return nil end
        local ok, I = pcall(win_token_identity, w, h)
        w.ffi.C.CloseHandle(h)
        return ok and I or nil
    end
    local e = require("loomworks.proc").euid(pid)
    return e and tostring(e) or nil
end

--- Is process `pid` of this process's slot? False when its identity cannot
--- be read (spec §19.6.1: such a process is skipped).
--- @param pid integer
--- @return boolean
function M.same_slot(pid)
    local ok, mine = pcall(M.identity)
    if not ok then return false end
    local theirs = M.process_identity(pid)
    return theirs ~= nil and theirs == mine
end


return M
