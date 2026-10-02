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

--- The descendants of `pid` (children first-level first), from one snapshot,
--- each with the start time it had then: `{ pid, start }`. A descendant whose
--- start time cannot be read is left out — it is never signalled unverified.
--- A process counts as a child only if it started no earlier than its parent
--- (on Windows a parent id is never updated when the parent exits, so an
--- older process whose dead parent had the same id is not one). This process
--- and its ancestors are never included.
--- @param pid integer
--- @return { pid: integer, start: string }[]
function M.descendants(pid)
    local snap = snapshot()
    local by_parent = {}
    for _, e in ipairs(snap) do
        if e.pid ~= e.ppid then
            by_parent[e.ppid] = by_parent[e.ppid] or {}
            table.insert(by_parent[e.ppid], e.pid)
        end
    end
    local protected = M.ancestors(snap)
    local starts = {}
    local function start_of(p)
        if starts[p] == nil then
            local st = M.start_time(p)
            starts[p] = type(st) == "string" and st or false
        end
        return starts[p]
    end
    local function num(st) return tonumber((st:match("([%d%.]+)$") or ""):match("^(%d+)")) end
    local out, seen, queue = {}, { [pid] = true }, { pid }
    while #queue > 0 do
        local parent = table.remove(queue, 1)
        for _, child in ipairs(by_parent[parent] or {}) do
            if not seen[child] and not protected[child] then
                seen[child] = true
                local cs, ps = start_of(child), start_of(parent)
                if cs and ps then
                    local cn, pn = num(cs), num(ps)
                    if not (cn and pn) or cn >= pn then
                        out[#out + 1] = { pid = child, start = cs }
                        queue[#queue + 1] = child
                    end
                end
            end
        end
    end
    return out
end

--- This process and its ancestors, as a set of pids (walked up the parent
--- ids of one snapshot; on Windows a parent counts only while it started no
--- later than its child). `--break-locks` never signals any of them.
--- @param snap? table a snapshot (default: a fresh one)
--- @return table<integer, boolean>
function M.ancestors(snap)
    local parent_of = {}
    for _, e in ipairs(snap or snapshot()) do parent_of[e.pid] = e.ppid end
    local me = uv().os_getpid and uv().os_getpid() or nil
    local set = {}
    if not me then return set end
    set[me] = true
    local cur, n = me, 0
    while n < 64 do
        n = n + 1
        local p = parent_of[cur] or (cur == me and uv().os_getppid and uv().os_getppid()) or nil
        if not p or p <= 0 or set[p] then break end
        if OS == "Windows" then
            local cs, ps = win_start_time(cur), win_start_time(p)
            local cn = type(cs) == "string" and tonumber(cs:match("(%d+)$")) or nil
            local pn = type(ps) == "string" and tonumber(ps:match("(%d+)$")) or nil
            if not (cn and pn) or pn > cn then break end
        end
        set[p] = true
        cur = p
    end
    return set
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
--- force. A process whose start time no longer matches is never signalled,
--- nor is this process or one of its ancestors. `extra` adds descendants
--- enumerated earlier (`descendants`, before an ask step) that are still the
--- same processes. Returns true when the holder no longer exists afterwards.
--- @param pid integer
--- @param st string the holder's recorded start time
--- @param extra? integer[]
--- @return boolean gone, string|nil err
function M.kill_tree(pid, st, extra)
    if type(st) ~= "string" then return false, "the holder's start time is unknown" end
    local protected = M.ancestors()
    if protected[pid] then return false, "process " .. tostring(pid) .. " is this process or its ancestor" end
    local alive = M.alive(pid, st)
    local desc = {}
    if alive then
        if OS ~= "Windows" then pcall(uv().kill, pid, "sigstop") end
        desc = M.descendants(pid)
    end
    local seen = {}
    for _, d in ipairs(desc) do seen[d.pid] = true end
    for _, d in ipairs(extra or {}) do
        if type(d) == "table" and not seen[d.pid] then seen[d.pid] = true; desc[#desc + 1] = d end
    end
    if alive then
        if OS == "Windows" then win_kill(pid, st) else pcall(uv().kill, pid, "sigkill") end
    end
    -- Each descendant is signalled only if it is still the process recorded
    -- in the snapshot (same id AND start time) — never a reused id, never this
    -- process or an ancestor. On Windows the check is made on the very handle
    -- that is terminated.
    for _, d in ipairs(desc) do
        if not protected[d.pid] and type(d.start) == "string" then
            if OS == "Windows" then
                win_kill(d.pid, d.start)
            elseif M.alive(d.pid, d.start) == true then
                pcall(uv().kill, d.pid, "sigkill")
            end
        end
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
-- Command lines and holder identity (spec §19.5: never kill a process that is
-- not what its lock record claims)
-- ---------------------------------------------------------------------------

local _wcmd
local function win_cmd()
    if _wcmd ~= nil then return _wcmd or nil end
    _wcmd = false
    local ffi = win()
    if not ffi then return nil end
    cdef("int32_t NtQueryInformationProcess(void* h, int cls, void* info, uint32_t len, uint32_t* ret);")
    cdef("void** CommandLineToArgvW(const uint16_t* cmd, int* argc);")
    cdef("int WideCharToMultiByte(uint32_t cp, uint32_t flags, const uint16_t* w, int wlen, char* s, int slen, const char* d, int* used);")
    cdef("void* LocalFree(void* p);")
    cdef("typedef struct { uint16_t Length; uint16_t MaximumLength; uint16_t* Buffer; } lw_UNICODE_STRING;")
    local okn, nt = pcall(ffi.load, "ntdll")
    local oks, sh = pcall(ffi.load, "shell32")
    if not okn or not oks then return nil end
    _wcmd = { ffi = ffi, nt = nt, sh = sh }
    return _wcmd
end

local function utf8_of(ffi, w)
    local n = ffi.C.WideCharToMultiByte(65001, 0, w, -1, nil, 0, nil, nil)
    if n <= 0 then return "" end
    local buf = ffi.new("char[?]", n)
    ffi.C.WideCharToMultiByte(65001, 0, w, -1, buf, n, nil, nil)
    return ffi.string(buf, n - 1)
end

--- Windows: the command line of `pid` (NtQueryInformationProcess class 60,
--- ProcessCommandLineInformation), split with CommandLineToArgvW; the start
--- time is checked on the same handle.
local function win_cmdline(pid, st)
    local w = win_cmd()
    if not w then return nil end
    local ffi = w.ffi
    local h = win_open(pid, W.QUERY)
    if not h then return nil end
    local args
    pcall(function()
        if st and win_handle_start(h) ~= st then return end
        local size, ret = 8192, ffi.new("uint32_t[1]")
        for _ = 1, 3 do
            local buf = ffi.new("uint8_t[?]", size)
            local rc = w.nt.NtQueryInformationProcess(h, 60, buf, size, ret)
            if rc == 0 then
                local us = ffi.cast("lw_UNICODE_STRING*", buf)
                local n = math.floor(us.Length / 2)
                local wide = ffi.new("uint16_t[?]", n + 1)
                ffi.copy(wide, us.Buffer, n * 2)
                wide[n] = 0
                local argc = ffi.new("int[1]")
                local argv = w.sh.CommandLineToArgvW(wide, argc)
                if argv ~= nil then
                    args = {}
                    for i = 0, argc[0] - 1 do
                        args[#args + 1] = utf8_of(ffi, ffi.cast("uint16_t*", argv[i]))
                    end
                    ffi.C.LocalFree(argv)
                end
                return
            end
            if ret[0] > size then size = ret[0] else return end
        end
    end)
    ffi.C.CloseHandle(h)
    return args
end

local function linux_cmdline(pid)
    local f = io.open("/proc/" .. tostring(pid) .. "/cmdline", "rb")
    if not f then return nil end
    local s = f:read("*a") or ""
    f:close()
    if s == "" then return nil end
    local args = {}
    for a in (s:gsub("%z$", "") .. "\0"):gmatch("(.-)%z") do args[#args + 1] = a end
    return args
end

local _mac_sysctl
local function mac_cmdline(pid)
    local ffi = ffi_mod()
    if not ffi or OS ~= "OSX" then return nil end
    if not _mac_sysctl then
        cdef("int sysctl(int* name, unsigned int namelen, void* oldp, size_t* oldlenp, void* newp, size_t newlen);")
        _mac_sysctl = true
    end
    local size = 1024 * 1024
    local buf = ffi.new("uint8_t[?]", size)
    local len = ffi.new("size_t[1]", size)
    local mib = ffi.new("int[3]", { 1, 49, pid }) -- CTL_KERN, KERN_PROCARGS2
    if ffi.C.sysctl(mib, 3, buf, len, nil, 0) ~= 0 then return nil end
    local n = tonumber(len[0])
    if n < 4 then return nil end
    local argc = ffi.cast("int*", buf)[0]
    local s = ffi.string(buf + 4, n - 4)
    -- exec path, NUL padding, then argc NUL-terminated arguments
    local pos = (s:find("\0", 1, true) or #s) + 1
    while s:sub(pos, pos) == "\0" do pos = pos + 1 end
    local args = {}
    while #args < argc and pos <= #s do
        local e = s:find("\0", pos, true) or (#s + 1)
        args[#args + 1] = s:sub(pos, e - 1)
        pos = e + 1
    end
    return #args > 0 and args or nil
end

--- The command line (argv) of process `pid`, or nil when it cannot be read
--- (gone, access denied, no method on this OS). With `st`, nil unless the
--- process still has that start time.
--- @param pid integer
--- @param st? string recorded start time
--- @return string[]|nil
function M.cmdline(pid, st)
    if M._cmdline_probe then return M._cmdline_probe(pid, st) end
    if type(pid) ~= "number" or pid < 1 then return nil end
    if st and OS ~= "Windows" and M.alive(pid, st) ~= true then return nil end
    local ok, args
    if OS == "Windows" then ok, args = pcall(win_cmdline, pid, st)
    elseif OS == "Linux" then ok, args = pcall(linux_cmdline, pid)
    else ok, args = pcall(mac_cmdline, pid) end
    if ok and type(args) == "table" and #args > 0 then return args end
    return nil
end

local function base_of(p)
    local b = tostring(p or ""):gsub("\\", "/"):match("[^/]*$") or ""
    return (b:lower():gsub("%.exe$", ""))
end

--- Release host asset names without `.exe` (`lw-linux-x86_64`, …).
local function host_assets()
    local ok, pin = pcall(require, "boot.pin")
    local out = {}
    for _, a in pairs(ok and pin.HOST_ASSETS or {}) do out[#out + 1] = (a:lower():gsub("%.exe$", "")) end
    return out
end

--- Is `exe` (a base name, lowercased, without `.exe`) a named lw binary:
--- `lw`, a release asset run under its download name (`lw-linux-x86_64`), or
--- a pinned launcher-cache copy `lw-<version>-<asset>` (spec §16.24)? Any
--- other `lw-*` (`lw-foo`) is not.
--- @param exe string
--- @return boolean
function M._is_lw_binary(exe)
    if exe == "lw" then return true end
    if exe:sub(1, 3) ~= "lw-" then return false end
    -- (The naming of boot.launcher.cached_binary_version, parsed here: an
    -- older host's boot modules may lack it.)
    local okp, pin = pcall(require, "boot.pin")
    for _, a in ipairs(host_assets()) do
        if exe == a then return true end
        local suffix = "-" .. a
        if okp and #exe > 3 + #suffix and exe:sub(-#suffix) == suffix
            and pin.valid_version(exe:sub(4, #exe - #suffix)) then
            return true
        end
    end
    return false
end

--- Is `p` (a luvi app path from a command line) the loomworks source app: a
--- directory named `lua` (a checkout's `lua/`, run by dev hosts and the test
--- suites) or `lua-<version>` (a provisioned bundle, `<data>/pinned/…/
--- lua-<ver>/`)? An absolute one must also hold `loomworks/cli.lua`; a
--- relative one is relative to that process's cwd, which is not known here.
--- @param p string
--- @return boolean
function M._is_lw_app(p)
    local n = tostring(p):gsub("\\", "/"):gsub("/+$", "")
    local last = n:match("[^/]*$") or ""
    local okv, pin = pcall(require, "boot.pin")
    local ver = last:match("^lua%-(.+)$")
    if not (last == "lua" or (ver and okv and pin.valid_version(ver))) then return false end
    if n:match("^/") or n:match("^%a:/") then
        local st = uv().fs_stat(n .. "/loomworks/cli.lua")
        return st ~= nil and st.type == "file"
    end
    return true
end

--- Does this command line run an `lw` host: the `lw` binary (also a release
--- asset under its download name, or a pinned `lw-<version>-<asset>` copy),
--- `luvi` running the loomworks app (M._is_lw_app: a plain `luvi` running
--- anything else is not one), or the nvim-hosted fallback
--- (`nvim … -l …/loomworks/cli.lua`)?
--- @param args string[]
--- @return boolean
function M.is_lw(args)
    if type(args) ~= "table" or not args[1] then return false end
    local exe = base_of(args[1])
    if M._is_lw_binary(exe) then return true end
    if exe == "luvi" then
        -- `luvi [options] <app>… [-- <app args>]`: one of the app paths.
        for i = 2, #args do
            local a = tostring(args[i])
            if a == "--" then break end
            if a:sub(1, 1) ~= "-" and M._is_lw_app(a) then return true end
        end
        return false
    end
    if exe == "nvim" then
        for i = 2, #args do
            local a = tostring(args[i]):gsub("\\", "/")
            if a == "loomworks/cli.lua" or a:match("/loomworks/cli%.lua$") then return true end
        end
    end
    return false
end

--- Is this command line `lw … daemon run` — for `root` when it names one
--- with `--root`?
--- @param args string[]
--- @param root? string
--- @return boolean
function M.is_daemon_for(args, root)
    if not M.is_lw(args) then return false end
    local run, named
    for i = 1, #args - 1 do
        if args[i] == "daemon" and args[i + 1] == "run" then run = true end
        if args[i] == "--root" then named = args[i + 1] end
    end
    if not run then return false end
    if named and root then
        local key = require("loomworks.daemon.paths")._hash_key
        return key(named) == key(root)
    end
    return true
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
