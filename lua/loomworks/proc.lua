--- loomworks/proc.lua — local process identity and control for lock recovery
--- (spec §19.5).
---
--- A lock record names its holder by process id AND process start time, so a
--- reused process id is never mistaken for the holder. This module answers
--- "does the process with this id and start time still exist?" and, for
--- `--break-locks`, stops a holder's process tree.
---
--- Start time, per OS (all usable under both hosts — nvim and the luvi shim —
--- through LuaJIT FFI or plain file reads):
---   * Windows — `GetProcessTimes` creation time (FFI, kernel32): `win:<100ns>`
---   * Linux   — `/proc/<pid>/stat` field 22 + the boot id: `linux:<boot>:<ticks>`
---   * macOS   — `proc_pidinfo(PROC_PIDTBSDINFO)` (FFI, libSystem): `mac:<s>.<us>`
--- The value is opaque and carries its method prefix: a record written by a
--- method this process cannot use is judged by heartbeat alone (`nil`), never
--- compared across methods. Where nothing works `start_time` returns nil and
--- callers fall back to the heartbeat (§19.5 "Known limitations").
---
--- `start_time(pid)` returns a string (the process exists), `false` (no such
--- process — or a zombie / exited process whose object lingers) or `nil`
--- (cannot tell: no method, or access denied).

local M = {}

local function uv() return vim.uv or vim.loop end

local function os_name()
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi then return ffi.os end
    if package.config:sub(1, 1) == "\\" then return "Windows" end
    local f = io.open("/proc/self/stat", "r")
    if f then f:close(); return "Linux" end
    return "OSX"
end
local OS = os_name()
M._os = OS

-- ---------------------------------------------------------------------------
-- FFI declarations (each guarded: a host without FFI, or a declaration
-- another module already made, must never break lw)
-- ---------------------------------------------------------------------------

local _ffi -- nil = not tried, false = unavailable, else the ffi module
local function ffi_mod()
    if _ffi == nil then
        local ok, f = pcall(require, "ffi")
        _ffi = ok and f or false
    end
    return _ffi or nil
end

local function cdef(src)
    local ffi = ffi_mod()
    if not ffi then return end
    pcall(ffi.cdef, src)
end

local _win_ready
local function win()
    if _win_ready ~= nil then return _win_ready or nil end
    _win_ready = false
    local ffi = ffi_mod()
    if not ffi or OS ~= "Windows" then return nil end
    cdef("void* OpenProcess(uint32_t dwDesiredAccess, int bInheritHandle, uint32_t dwProcessId);")
    cdef("int CloseHandle(void* hObject);")
    cdef("uint32_t GetLastError(void);")
    cdef("int GetProcessTimes(void* h, uint64_t* c, uint64_t* e, uint64_t* k, uint64_t* u);")
    cdef("int GetExitCodeProcess(void* h, uint32_t* code);")
    cdef("int TerminateProcess(void* h, uint32_t code);")
    cdef("uint32_t WaitForSingleObject(void* h, uint32_t ms);")
    cdef("void* CreateToolhelp32Snapshot(uint32_t flags, uint32_t pid);")
    cdef([[typedef struct {
        uint32_t dwSize; uint32_t cntUsage; uint32_t th32ProcessID; uintptr_t th32DefaultHeapID;
        uint32_t th32ModuleID; uint32_t cntThreads; uint32_t th32ParentProcessID;
        int32_t pcPriClassBase; uint32_t dwFlags; uint16_t szExeFile[260];
    } lw_PROCESSENTRY32W;]])
    cdef("int Process32FirstW(void* snap, lw_PROCESSENTRY32W* pe);")
    cdef("int Process32NextW(void* snap, lw_PROCESSENTRY32W* pe);")
    local ok = pcall(function() return ffi.C.OpenProcess and ffi.C.GetProcessTimes end)
    _win_ready = ok and ffi or false
    return _win_ready or nil
end

local W = {
    QUERY = 0x1000,            -- PROCESS_QUERY_LIMITED_INFORMATION
    TERMINATE = 0x0001,        -- PROCESS_TERMINATE
    SYNCHRONIZE = 0x00100000,
    SUSPEND_RESUME = 0x0800,   -- PROCESS_SUSPEND_RESUME
    STILL_ACTIVE = 259,
    ERROR_INVALID_PARAMETER = 87,
}

local function is_null(p)
    local ffi = ffi_mod()
    return p == nil or (ffi and ffi.cast("intptr_t", p) == 0)
end

--- Open a process handle. Returns handle, or nil + "gone" | "denied" | "error".
local function win_open(pid, access)
    local ffi = win()
    if not ffi then return nil, "error" end
    local h = ffi.C.OpenProcess(access, 0, pid)
    if is_null(h) then
        local e = ffi.C.GetLastError()
        if e == W.ERROR_INVALID_PARAMETER then return nil, "gone" end
        if e == 5 then return nil, "denied" end
        return nil, "error"
    end
    return h
end

--- Start time of an open handle ("win:<n>"), false (exited), nil (unknown).
local function win_handle_start(h)
    local ffi = win()
    local code = ffi.new("uint32_t[1]")
    if ffi.C.GetExitCodeProcess(h, code) ~= 0 and code[0] ~= W.STILL_ACTIVE then
        return false
    end
    local t = ffi.new("uint64_t[4]")
    if ffi.C.GetProcessTimes(h, t, t + 1, t + 2, t + 3) == 0 then return nil end
    return "win:" .. (tostring(t[0]):gsub("U?LL$", ""))
end

local function win_start_time(pid)
    local h, why = win_open(pid, W.QUERY)
    if not h then
        if why == "gone" then return false end
        return nil
    end
    local ok, st = pcall(win_handle_start, h)
    win().C.CloseHandle(h)
    if not ok then return nil end
    return st
end

local function linux_boot_id()
    local f = io.open("/proc/sys/kernel/random/boot_id", "r")
    if not f then return "?" end
    local s = (f:read("*l") or "?"):gsub("%s+", "")
    f:close()
    return s
end

--- Parse `/proc/<pid>/stat`: state, ppid, starttime (ticks) — or nil.
local function linux_stat(pid)
    local f = io.open("/proc/" .. tostring(pid) .. "/stat", "r")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    local rest = s:match("^.*%)%s+(.*)$")
    if not rest then return nil end
    local t = {}
    for w in rest:gmatch("%S+") do t[#t + 1] = w end
    -- after "(comm)": t[1] = state (field 3), so field N is t[N - 2]
    return { state = t[1], ppid = tonumber(t[2]), start = t[20] }
end

local _boot
local function linux_start_time(pid)
    local st = linux_stat(pid)
    if not st then
        -- No /proc at all: cannot tell. Otherwise the pid is gone.
        local self = io.open("/proc/self/stat", "r")
        if not self then return nil end
        self:close()
        return false
    end
    if st.state == "Z" or st.state == "X" or st.state == "x" then return false end
    if not st.start then return nil end
    _boot = _boot or linux_boot_id()
    return "linux:" .. _boot .. ":" .. st.start
end

local _mac_ready
local function mac()
    if _mac_ready ~= nil then return _mac_ready or nil end
    _mac_ready = false
    local ffi = ffi_mod()
    if not ffi or OS ~= "OSX" then return nil end
    cdef("int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);")
    local ok = pcall(function() return ffi.C.proc_pidinfo end)
    _mac_ready = ok and ffi or false
    return _mac_ready or nil
end

local MAC_BSDINFO, MAC_BSDINFO_SIZE = 3, 136
local function mac_start_time(pid)
    local ffi = mac()
    if not ffi then return nil end
    local buf = ffi.new("uint8_t[?]", MAC_BSDINFO_SIZE)
    local n = ffi.C.proc_pidinfo(pid, MAC_BSDINFO, 0, buf, MAC_BSDINFO_SIZE)
    if n <= 0 then
        if ffi.errno() == 3 then return false end -- ESRCH
        return nil
    end
    if n < MAC_BSDINFO_SIZE then return nil end
    local u32 = ffi.cast("uint32_t*", buf)
    if u32[1] == 5 then return false end -- pbi_status SZOMB
    local u64 = ffi.cast("uint64_t*", buf + 120)
    return "mac:" .. (tostring(u64[0]):gsub("U?LL$", "")) .. "."
        .. (tostring(u64[1]):gsub("U?LL$", ""))
end

local METHODS = { win = win_start_time, linux = linux_start_time, mac = mac_start_time }
local NATIVE = ({ Windows = "win", Linux = "linux", OSX = "mac" })[OS]

--- Test seam: replace the probe (`fn(pid, method) -> string|false|nil`).
M._probe = nil

--- The start time of process `pid`, measured with `method` (default: this
--- OS's method). See the module header for the return values.
--- @param pid integer
--- @param method? string "win"|"linux"|"mac"
--- @return string|false|nil
function M.start_time(pid, method)
    if type(pid) ~= "number" or pid < 1 or pid ~= math.floor(pid) then return false end
    if M._probe then return M._probe(pid, method) end
    method = method or NATIVE
    if method ~= NATIVE then return nil end
    local fn = METHODS[method]
    if not fn then return nil end
    local ok, v = pcall(fn, pid)
    if not ok then return nil end
    return v
end

--- The method prefix of a start-time value ("win", "linux", "mac"), or nil.
--- @param st string|nil
--- @return string|nil
function M.method_of(st)
    return type(st) == "string" and st:match("^(%a+):") or nil
end

local _self_start
--- This process's start time (memoized), or nil when unavailable.
--- @return string|nil
function M.self_start_time()
    if _self_start == nil then
        local pid = uv().os_getpid and uv().os_getpid() or nil
        local st = pid and M.start_time(pid) or nil
        _self_start = type(st) == "string" and st or false
    end
    return _self_start or nil
end

--- Does the process with this id and start time still exist?
--- @param pid integer
--- @param st string start time recorded for it
--- @return boolean|nil true = exists, false = gone, nil = cannot tell
function M.alive(pid, st)
    local now = M.start_time(pid, M.method_of(st))
    if now == false then return false end
    if type(now) ~= "string" then return nil end
    return now == st
end

-- ---------------------------------------------------------------------------
-- Process trees
-- ---------------------------------------------------------------------------

--- Every process as { pid, ppid } (Windows: plus `start` for cross-checks).
local function snapshot()
    local list = {}
    if OS == "Windows" then
        local ffi = win()
        if not ffi then return list end
        local snap = ffi.C.CreateToolhelp32Snapshot(2, 0) -- TH32CS_SNAPPROCESS
        if is_null(snap) or ffi.cast("intptr_t", snap) == -1 then return list end
        local pe = ffi.new("lw_PROCESSENTRY32W")
        pe.dwSize = ffi.sizeof("lw_PROCESSENTRY32W")
        local ok = ffi.C.Process32FirstW(snap, pe)
        while ok ~= 0 do
            list[#list + 1] = { pid = tonumber(pe.th32ProcessID), ppid = tonumber(pe.th32ParentProcessID) }
            ok = ffi.C.Process32NextW(snap, pe)
        end
        ffi.C.CloseHandle(snap)
        return list
    end
    if OS == "Linux" then
        local found = false
        local req = uv().fs_scandir("/proc")
        if req then
            while true do
                local name = uv().fs_scandir_next(req)
                if not name then break end
                local pid = tonumber(name)
                if pid then
                    local st = linux_stat(pid)
                    if st and st.ppid then
                        found = true
                        list[#list + 1] = { pid = pid, ppid = st.ppid }
                    end
                end
            end
        end
        if found then return list end
    end
    local p = io.popen("ps -A -o pid= -o ppid= 2>/dev/null")
    if p then
        for line in p:lines() do
            local a, b = line:match("^%s*(%d+)%s+(%d+)")
            if a then list[#list + 1] = { pid = tonumber(a), ppid = tonumber(b) } end
        end
        p:close()
    end
    return list
end

--- The descendants of `pid` (children first-level first), from one snapshot.
--- On Windows, where a parent id is never updated when the parent exits, a
--- process counts as a child only if it started after its parent (an older
--- process whose dead parent had the same id is not one).
--- @param pid integer
--- @return integer[]
function M.descendants(pid)
    local by_parent = {}
    for _, e in ipairs(snapshot()) do
        if e.pid ~= e.ppid then
            by_parent[e.ppid] = by_parent[e.ppid] or {}
            table.insert(by_parent[e.ppid], e.pid)
        end
    end
    local out, seen, queue = {}, { [pid] = true }, { pid }
    local starts = {}
    local function start_num(p)
        if starts[p] == nil then
            local st = OS == "Windows" and win_start_time(p) or nil
            starts[p] = type(st) == "string" and tonumber(st:match("(%d+)$")) or false
        end
        return starts[p]
    end
    while #queue > 0 do
        local parent = table.remove(queue, 1)
        for _, child in ipairs(by_parent[parent] or {}) do
            if not seen[child] then
                local okc = true
                if OS == "Windows" then
                    local ps, cs = start_num(parent), start_num(child)
                    okc = ps and cs and cs >= ps or false
                end
                if okc then
                    seen[child] = true
                    out[#out + 1] = child
                    queue[#queue + 1] = child
                end
            end
        end
    end
    return out
end

--- Terminate one process (Windows: verifying the start time on the handle
--- that is terminated, so a reused id is never hit). `st` may be nil for a
--- descendant (identified by the snapshot).
local function win_kill(pid, st)
    local ffi = win()
    if not ffi then return false end
    local h = win_open(pid, W.QUERY + W.TERMINATE + W.SYNCHRONIZE)
    if not h then return false end
    local okk = false
    pcall(function()
        local now = win_handle_start(h)
        if now == false then okk = true; return end
        if st and now ~= st then return end
        if ffi.C.TerminateProcess(h, 1) ~= 0 then
            ffi.C.WaitForSingleObject(h, 2000)
            okk = true
        end
    end)
    ffi.C.CloseHandle(h)
    return okk
end

--- Kill the process tree of the holder `pid` whose recorded start time is
--- `st` (spec §19.5 step 2): the holder and its enumerated descendants, by
--- force. A process whose start time no longer matches is never signalled.
--- `extra` adds descendants enumerated earlier (before an ask step) that are
--- still running. Returns true when the holder no longer exists afterwards.
--- @param pid integer
--- @param st string the holder's recorded start time
--- @param extra? integer[]
--- @return boolean gone, string|nil err
function M.kill_tree(pid, st, extra)
    if type(st) ~= "string" then return false, "the holder's start time is unknown" end
    local alive = M.alive(pid, st)
    local desc = {}
    if alive then
        if OS ~= "Windows" then pcall(uv().kill, pid, "sigstop") end
        desc = M.descendants(pid)
    end
    local seen = {}
    for _, d in ipairs(desc) do seen[d] = true end
    for _, d in ipairs(extra or {}) do
        if not seen[d] then seen[d] = true; desc[#desc + 1] = d end
    end
    if alive then
        if OS == "Windows" then win_kill(pid, st) else pcall(uv().kill, pid, "sigkill") end
    end
    for _, d in ipairs(desc) do
        if OS == "Windows" then win_kill(d, nil) else pcall(uv().kill, d, "sigkill") end
    end
    -- Verify (step 3): the holder is gone. Poll briefly: a killed process can
    -- take a moment to leave the process table.
    local gone = false
    local deadline = uv().hrtime() + 5e9
    repeat
        local a = M.alive(pid, st)
        if a == false then gone = true; break end
        if a == nil then break end
        uv().sleep(50)
    until uv().hrtime() > deadline
    if not gone then return false, "process " .. tostring(pid) .. " is still running" end
    return true
end

--- Ask a holder to let go (spec §19.5 step 1): the interrupt `lw` handles
--- (§16.6). POSIX only — on Windows an `lw` in another console cannot reliably
--- be interrupted (§19.5 "Known limitations"), so this returns false there.
--- @param pid integer
--- @param st string recorded start time (never signal a reused id)
--- @return boolean sent
function M.interrupt(pid, st)
    if OS == "Windows" then return false end
    if M.alive(pid, st) ~= true then return false end
    return pcall(uv().kill, pid, "sigint") and true or false
end

-- ---------------------------------------------------------------------------
-- Test helpers: suspend / resume a process (a hung holder)
-- ---------------------------------------------------------------------------

local _nt
local function ntdll()
    if _nt ~= nil then return _nt or nil end
    _nt = false
    local ffi = win()
    if not ffi then return nil end
    cdef("int32_t NtSuspendProcess(void* h);")
    cdef("int32_t NtResumeProcess(void* h);")
    local ok, lib = pcall(ffi.load, "ntdll")
    _nt = ok and lib or false
    return _nt or nil
end

local function win_suspend(pid, resume)
    local lib = ntdll()
    if not lib then return false end
    local h = win_open(pid, W.SUSPEND_RESUME + W.QUERY)
    if not h then return false end
    local rc = resume and lib.NtResumeProcess(h) or lib.NtSuspendProcess(h)
    win().C.CloseHandle(h)
    return rc == 0
end

--- Suspend a process (Windows NtSuspendProcess, POSIX SIGSTOP). Tests only.
--- @param pid integer
--- @return boolean
function M._suspend(pid)
    if OS == "Windows" then return win_suspend(pid, false) end
    return pcall(uv().kill, pid, "sigstop") and true or false
end

--- Resume a process suspended by `_suspend`. Tests only.
--- @param pid integer
--- @return boolean
function M._resume(pid)
    if OS == "Windows" then return win_suspend(pid, true) end
    return pcall(uv().kill, pid, "sigcont") and true or false
end

return M
