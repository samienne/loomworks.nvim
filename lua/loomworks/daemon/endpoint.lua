--- loomworks/daemon/endpoint.lua — the daemon's endpoint and its access control
--- (spec §19.7).
---
--- The endpoint is a trust boundary — a peer that can issue commands can run
--- builds — so it is restricted by the operating system AND gated by the
--- handshake (§19.8, loomworks.daemon.auth).
---
---   * POSIX — a Unix-domain socket `<dir>/<root hash>.sock` in a short
---     per-user directory created 0700 and verified to be a real directory
---     owned by this user: `$XDG_RUNTIME_DIR/loomworks`, else `$TMPDIR` /
---     `/tmp` + `loomworks-<uid>`. The hashed name keeps the path inside the
---     `sun_path` limit (~104 bytes on macOS, 108 on Linux) for any repository
---     depth; a base whose path would not fit falls back to `/tmp`.
---   * Windows — a named pipe `\\.\pipe\loomworks-<hash of user and root>`.
---     Right after binding (before listening) its security descriptor is
---     replaced, through LuaJIT FFI `SetSecurityInfo`, with the protected DACL
---     `D:P(D;;GA;;;NU)(A;;GA;;;<user SID>)(A;;GA;;;SY)`: owner and SYSTEM
---     only, network logons denied. A pipe whose DACL cannot be applied is
---     never served (the daemon exits with an error). The default DACL lets
---     Everyone and Anonymous READ, which leaked another client's traffic in
---     the 2026-09 spike (DAEMON.md §6).
---
--- Deletion safety: the only file this module removes is a stale socket at
--- exactly `<verified dir>/<root hash>.sock` whose `lstat` type is `socket`
--- owned by this uid, and only for a caller that holds the runtime lock
--- (§19.7). The directory is a candidate of this environment or a real,
--- owned, 0700 directory (M._posix_owned).

local paths = require("loomworks.daemon.paths")

local M = {}

local function uv() return vim.uv or vim.loop end
local function is_win() return package.config:sub(1, 1) == "\\" end

--- Conservative `sun_path` budget (the kernel limit includes the NUL).
M.SUN_PATH_MAX = 100

local function uid() return (uv().getuid and uv().getuid()) or 0 end

local function user_name()
    local ok, pw = pcall(function() return uv().os_get_passwd() end)
    if ok and type(pw) == "table" and pw.username then return pw.username end
    return os.getenv("USERNAME") or os.getenv("USER") or "?"
end

--- POSIX candidates: { dir, path } in preference order.
local function posix_candidates(root)
    local name = paths.root_hash(root) .. ".sock"
    local out = {}
    local function add(dir)
        local p = dir .. "/" .. name
        if #p <= M.SUN_PATH_MAX then out[#out + 1] = { dir = dir, path = p } end
    end
    local function isdir(d)
        local st = d and d ~= "" and uv().fs_stat(d)
        return st and st.type == "directory"
    end
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if isdir(xdg) then add((xdg:gsub("/+$", "")) .. "/loomworks") end
    local tmpdir = os.getenv("TMPDIR")
    if isdir(tmpdir) then add((tmpdir:gsub("/+$", "")) .. "/loomworks-" .. uid()) end
    add("/tmp/loomworks-" .. uid())
    return out
end
M._posix_candidates = posix_candidates

--- The endpoint address a daemon for `root` binds (the first candidate on
--- POSIX). Clients never call this: they read the address from the handle.
--- @param root string
--- @return string
function M.address(root)
    if is_win() then
        return [[\\.\pipe\loomworks-]] .. paths.short_hash(user_name() .. "\n" .. paths._hash_key(root))
    end
    local c = posix_candidates(root)[1]
    return c and c.path or ("/tmp/loomworks-" .. uid() .. "/" .. paths.root_hash(root) .. ".sock")
end

--- Ensure a per-user socket directory: a real directory (not a link), owned
--- by this user, mode 0700. Returns true or nil + reason.
local function ensure_dir(dir)
    pcall(uv().fs_mkdir, dir, tonumber("700", 8))
    local st = uv().fs_lstat(dir)
    if not st then return nil, "cannot create " .. dir end
    if st.type ~= "directory" then return nil, dir .. " is not a directory" end
    if type(st.uid) == "number" and st.uid ~= uid() then return nil, dir .. " is not owned by this user" end
    if st.mode and (st.mode % 512) ~= tonumber("700", 8) then
        pcall(uv().fs_chmod, dir, tonumber("700", 8))
        st = uv().fs_lstat(dir)
        if not st or (st.mode % 512) ~= tonumber("700", 8) then return nil, dir .. " is not mode 0700" end
    end
    return true
end
M._ensure_dir = ensure_dir

-- ---------------------------------------------------------------------------
-- Windows: the pipe's DACL (FFI)
-- ---------------------------------------------------------------------------

local _w
local function win()
    if _w ~= nil then return _w or nil end
    _w = false
    local ok, ffi = pcall(require, "ffi")
    if not ok or ffi.os ~= "Windows" then return nil end
    for _, d in ipairs({
        "void* GetCurrentProcess(void);",
        "int CloseHandle(void* hObject);",
        "void* LocalFree(void* p);",
        "int OpenProcessToken(void* process, uint32_t access, void** token);",
        "int GetTokenInformation(void* token, int cls, void* info, uint32_t len, uint32_t* ret);",
        "int ConvertSidToStringSidA(void* sid, char** str);",
        "int ConvertStringSecurityDescriptorToSecurityDescriptorA(const char* s, uint32_t rev, void** sd, uint32_t* size);",
        "int GetSecurityDescriptorDacl(void* sd, int* present, void** dacl, int* defaulted);",
        "uint32_t SetSecurityInfo(void* h, int type, uint32_t info, void* owner, void* group, void* dacl, void* sacl);",
        "uint32_t GetSecurityInfo(void* h, int type, uint32_t info, void** owner, void** group, void** dacl, void** sacl, void** sd);",
        "int ConvertSecurityDescriptorToStringSecurityDescriptorA(void* sd, uint32_t rev, uint32_t info, char** s, uint32_t* len);",
    }) do
        pcall(ffi.cdef, d)
    end
    local okl, adv = pcall(ffi.load, "advapi32")
    if not okl then return nil end
    _w = { ffi = ffi, adv = adv }
    return _w
end

local SE_KERNEL_OBJECT = 6
local DACL_INFO = 0x00000004
local PROTECTED_DACL = 0x80000000

--- The string SID of this process's user, or nil + error.
--- @return string|nil sid, string|nil err
function M.user_sid()
    local w = win()
    if not w then return nil, "no FFI access to advapi32" end
    local ffi, adv = w.ffi, w.adv
    local tok = ffi.new("void*[1]")
    if adv.OpenProcessToken(ffi.C.GetCurrentProcess(), 0x0008, tok) == 0 then
        return nil, "OpenProcessToken failed"
    end
    local len = ffi.new("uint32_t[1]")
    adv.GetTokenInformation(tok[0], 1, nil, 0, len)
    local sid
    if len[0] > 0 then
        local buf = ffi.new("uint8_t[?]", len[0])
        if adv.GetTokenInformation(tok[0], 1, buf, len[0], len) ~= 0 then
            local str = ffi.new("char*[1]")
            if adv.ConvertSidToStringSidA(ffi.cast("void**", buf)[0], str) ~= 0 then
                sid = ffi.string(str[0])
                ffi.C.LocalFree(str[0])
            end
        end
    end
    ffi.C.CloseHandle(tok[0])
    if not sid then return nil, "cannot read the user SID" end
    return sid
end

--- The DACL the pipe gets (spec §19.7).
--- @param sid string
--- @return string
function M.sddl(sid)
    return "D:P(D;;GA;;;NU)(A;;GA;;;" .. sid .. ")(A;;GA;;;SY)"
end

--- The OS handle of a bound libuv pipe, as an FFI pointer.
local function os_handle(pipe)
    local w = win()
    local ok, fd = pcall(function() return pipe:fileno() end)
    if not ok or type(fd) ~= "number" or fd == -1 then return nil end
    return w.ffi.cast("void*", fd)
end

--- Replace the DACL of a bound pipe (spec §19.7). Returns true or nil + error.
--- @param pipe userdata a bound uv pipe
--- @return boolean|nil ok, string|nil err
function M.apply_dacl(pipe)
    local w = win()
    if not w then return nil, "no FFI access to advapi32" end
    local ffi, adv = w.ffi, w.adv
    local h = os_handle(pipe)
    if not h then return nil, "no OS handle for the pipe" end
    local sid, serr = M.user_sid()
    if not sid then return nil, serr end
    local sd = ffi.new("void*[1]")
    if adv.ConvertStringSecurityDescriptorToSecurityDescriptorA(M.sddl(sid), 1, sd, nil) == 0 then
        return nil, "cannot build the security descriptor"
    end
    local present, defaulted, dacl = ffi.new("int[1]"), ffi.new("int[1]"), ffi.new("void*[1]")
    local rc
    if adv.GetSecurityDescriptorDacl(sd[0], present, dacl, defaulted) ~= 0 and present[0] ~= 0 then
        rc = adv.SetSecurityInfo(h, SE_KERNEL_OBJECT, DACL_INFO + PROTECTED_DACL, nil, nil, dacl[0], nil)
    end
    ffi.C.LocalFree(sd[0])
    if rc ~= 0 then return nil, "SetSecurityInfo failed (" .. tostring(rc) .. ")" end
    return true
end

--- An SDDL string as Windows renders it back (SIDs with a well-known alias,
--- such as the built-in Administrator's `LA`, come back as the alias).
--- @param sddl string
--- @return string|nil
function M._normalize_sddl(sddl)
    local w = win()
    if not w then return nil end
    local ffi, adv = w.ffi, w.adv
    local sd = ffi.new("void*[1]")
    if adv.ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, 1, sd, nil) == 0 then return nil end
    local str = ffi.new("char*[1]")
    local s
    if adv.ConvertSecurityDescriptorToStringSecurityDescriptorA(sd[0], 1, DACL_INFO, str, nil) ~= 0 then
        s = ffi.string(str[0])
        ffi.C.LocalFree(str[0])
    end
    ffi.C.LocalFree(sd[0])
    return s
end

--- The DACL of a bound pipe as SDDL (tests: read back what was applied).
--- @param pipe userdata
--- @return string|nil
function M.read_dacl(pipe)
    local w = win()
    if not w then return nil end
    local ffi, adv = w.ffi, w.adv
    local h = os_handle(pipe)
    if not h then return nil end
    local sd, dacl = ffi.new("void*[1]"), ffi.new("void*[1]")
    if adv.GetSecurityInfo(h, SE_KERNEL_OBJECT, DACL_INFO, nil, nil, dacl, nil, sd) ~= 0 then return nil end
    local str = ffi.new("char*[1]")
    local s
    if adv.ConvertSecurityDescriptorToStringSecurityDescriptorA(sd[0], 1, DACL_INFO, str, nil) ~= 0 then
        s = ffi.string(str[0])
        ffi.C.LocalFree(str[0])
    end
    ffi.C.LocalFree(sd[0])
    return s
end

-- Indirections the POSIX ownership checks go through (tests stub them).
M._lstat = function(p) return uv().fs_lstat(p) end
M._uid = uid

--- Is `addr` this workspace's socket in a private directory of this user,
--- wherever that directory is (POSIX, spec §19.7)? The daemon binds the first
--- candidate of the environment that LAUNCHED it (`$XDG_RUNTIME_DIR`,
--- `$TMPDIR`), which a later client — from ssh, cron, `sudo -u`, a container
--- exec — may not share, so the client cannot recompute the path. Accepted
--- exactly when: an absolute local path without `.`/`..`/empty segments
--- (never `//host/...`); the file name is `<root hash>.sock` of THIS root; the
--- directory is a real directory (lstat, not a link) owned by this uid with
--- mode 0700 — what ensure_dir demands; and the file is a socket owned by
--- this uid. Independent of the current environment. Returns true, or
--- false + reason ("missing" when only the socket file is absent).
--- @param root string
--- @param addr any
--- @return boolean ok, string|nil why
function M._posix_owned(root, addr)
    if type(addr) ~= "string" or addr:sub(1, 1) ~= "/" or addr:sub(1, 2) == "//" or addr:find("\\", 1, true) then
        return false, "not a local absolute path"
    end
    for seg in (addr:sub(2) .. "/"):gmatch("([^/]*)/") do
        if seg == "" or seg == "." or seg == ".." then return false, "not a canonical path" end
    end
    local dir, base = addr:match("^(/.+)/([^/]+)$")
    if not dir or base ~= paths.root_hash(root) .. ".sock" then
        return false, "not this workspace's socket name"
    end
    local me = M._uid()
    local dst = M._lstat(dir)
    if not dst or dst.type ~= "directory" then return false, dir .. " is not a real directory" end
    if type(dst.uid) ~= "number" or dst.uid ~= me then return false, dir .. " is not owned by this user" end
    if not dst.mode or (dst.mode % 512) ~= tonumber("700", 8) then return false, dir .. " is not mode 0700" end
    local sst = M._lstat(addr)
    if not sst then return false, "missing" end
    if sst.type ~= "socket" then return false, addr .. " is not a socket" end
    if type(sst.uid) ~= "number" or sst.uid ~= me then return false, addr .. " is not owned by this user" end
    return true
end

--- Is `addr` an endpoint a daemon of this workspace binds — exactly
--- `address(root)` on Windows; on POSIX one of this environment's per-user
--- socket candidates, or this root's socket in a private directory of this
--- user (M._posix_owned: a daemon launched from another environment)? A
--- client connects to nothing else (spec §19.7): the handle lives in a
--- `.nvim/` other local users may be able to write, and a forged one naming
--- `\host\pipe\x` would make a client open a remote pipe (an SMB connection
--- that leaks the user's NTLM hash) or another user's socket.
--- Returns true, or false + the refusal.
--- @param root string
--- @param addr any
--- @return boolean ok, string|nil err
function M.check(root, addr)
    if type(addr) == "string" then
        if is_win() then
            if addr == M.address(root) then return true end
        else
            for _, c in ipairs(posix_candidates(root)) do
                if c.path == addr then return true end
            end
            local ok, why = M._posix_owned(root, addr)
            if ok then return true end
            if why == "missing" then
                return false, "the daemon's socket " .. addr .. " is gone (the daemon may have exited; "
                    .. "`lw daemon stop --force` recovers the runtime lock's holder)"
            end
        end
    end
    return false, "untrusted handle: it names the endpoint " .. tostring(addr)
        .. ", which no daemon of this workspace uses — not connecting to it (the handle may have been "
        .. "planted; `lw daemon stop --force` recovers the runtime lock's holder)"
end

-- ---------------------------------------------------------------------------
-- Listen
-- ---------------------------------------------------------------------------

--- Bind and listen the endpoint of `root`. The caller holds the runtime lock
--- (§19.7: a stale socket is unlinked only then). Returns the server pipe and
--- the address bound, or nil + error.
--- @param root string
--- @param on_connection fun(err: string|nil)
--- @return userdata|nil server, string addr_or_err
function M.listen(root, on_connection)
    if is_win() then
        local addr = M.address(root)
        local server = uv().new_pipe(false)
        local okb, berr = pcall(function() assert(server:bind(addr)) end)
        if not okb then
            pcall(function() server:close() end)
            return nil, "cannot bind " .. addr .. ": " .. tostring(berr)
        end
        local okd, derr = M.apply_dacl(server)
        if not okd then
            pcall(function() server:close() end)
            return nil, "cannot restrict access to " .. addr .. ": " .. tostring(derr)
        end
        local okl, lerr = pcall(function() assert(server:listen(64, on_connection)) end)
        if not okl then
            pcall(function() server:close() end)
            return nil, "cannot listen on " .. addr .. ": " .. tostring(lerr)
        end
        return server, addr
    end
    local errs = {}
    for _, c in ipairs(posix_candidates(root)) do
        local okd, derr = ensure_dir(c.dir)
        if okd then
            local st = uv().fs_lstat(c.path)
            if st and st.type ~= "socket" then
                errs[#errs + 1] = c.path .. " exists and is not a socket"
            else
                if st then pcall(uv().fs_unlink, c.path) end -- a crashed predecessor's
                local server = uv().new_pipe(false)
                local okb, berr = pcall(function() assert(server:bind(c.path)) end)
                if okb then
                    pcall(uv().fs_chmod, c.path, tonumber("600", 8))
                    local okl, lerr = pcall(function() assert(server:listen(64, on_connection)) end)
                    if okl then return server, c.path end
                    errs[#errs + 1] = "listen " .. c.path .. ": " .. tostring(lerr)
                else
                    errs[#errs + 1] = "bind " .. c.path .. ": " .. tostring(berr)
                end
                pcall(function() server:close() end)
            end
        else
            errs[#errs + 1] = derr
        end
    end
    return nil, "no usable socket: " .. table.concat(errs, "; ")
end

--- Remove the socket file a daemon bound (POSIX; a named pipe has none):
--- exactly `addr` when it is a socket owned by this user inside one of the
--- per-user directories — a candidate, or (without `cands`) any private
--- directory M._posix_owned accepts.
--- The caller holds the runtime lock.
--- `cands` are the candidates computed earlier (the daemon computes them at
--- start: hashing is not allowed inside libuv callbacks in the editor host).
--- With `ino` (recorded when the daemon bound the socket), only the socket
--- it bound — never one a successor bound at the same path since.
--- @param root string
--- @param addr string|nil
--- @param cands? table[]
--- @param ino? integer
function M.cleanup(root, addr, cands, ino)
    if is_win() or type(addr) ~= "string" then return end
    local ok = false
    for _, c in ipairs(cands or posix_candidates(root)) do
        if c.path == addr then ok = true end
    end
    -- A daemon launched from another environment bound a path outside this
    -- process's candidates: removed only when M._posix_owned accepts it (this
    -- root's socket name, this uid's socket, a real 0700 directory of this
    -- uid). A daemon's own cleanup passes `cands`, which hold its address.
    if not ok and (cands or not M._posix_owned(root, addr)) then return end
    local st = M._lstat(addr)
    if st and st.type == "socket" and (ino == nil or st.ino == ino)
        and (type(st.uid) ~= "number" or st.uid == M._uid()) then
        pcall(uv().fs_unlink, addr)
    end
end

return M
