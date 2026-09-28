--- loomworks/remote/probe.lua — host-executability probe (spec §18.1).
---
--- Reads the executable-format header of a build-target artifact and compares
--- its format — and, where the format records one, its machine architecture —
--- with the host's. A mismatch makes the artifact **foreign**: it never runs on
--- this host (spec §15 invariant 19). The probe never refuses what it cannot
--- judge: an unreadable file, a script, or an unknown format is not a mismatch.
---
--- Formats recognised: ELF, PE (the `MZ` stub + `PE\0\0` header) and Mach-O
--- (thin 32/64-bit, either byte order; a universal "fat" binary is Mach-O with
--- no single architecture). Only the fixed header fields are read.

local M = {}

local function uv() return vim.uv or vim.loop end

--- ELF `e_machine` → architecture name.
local ELF_MACHINE = {
    [3] = "x86", [62] = "x86_64", [40] = "arm", [183] = "aarch64",
    [8] = "mips", [20] = "ppc", [21] = "ppc64", [22] = "s390",
    [243] = "riscv", [258] = "loongarch",
}

--- PE COFF `Machine` → architecture name.
local PE_MACHINE = {
    [0x014c] = "x86", [0x8664] = "x86_64", [0xAA64] = "aarch64",
    [0x01c0] = "arm", [0x01c4] = "arm",
}

--- Mach-O `cputype` → architecture name.
local MACHO_CPU = {
    [7] = "x86", [0x01000007] = "x86_64", [12] = "arm", [0x0100000c] = "aarch64",
}

--- Normalise an architecture spelling (uname machine, provider data) to the
--- names used above.
--- @param a string|nil
--- @return string|nil
function M.normalize_arch(a)
    if type(a) ~= "string" or a == "" then return nil end
    a = a:lower()
    if a == "x86_64" or a == "amd64" or a == "x64" then return "x86_64" end
    if a == "aarch64" or a == "arm64" then return "aarch64" end
    if a:match("^i%d86$") or a == "x86" or a == "ia32" then return "x86" end
    if a:match("^arm") then return "arm" end
    if a:match("^riscv") then return "riscv" end
    return a
end

local function u16(s, off, le)
    local a, b = s:byte(off + 1, off + 2)
    if not b then return nil end
    return le and (a + b * 256) or (a * 256 + b)
end

local function u32(s, off, le)
    local a, b, c, d = s:byte(off + 1, off + 4)
    if not d then return nil end
    if le then return a + b * 256 + c * 65536 + d * 16777216 end
    return a * 16777216 + b * 65536 + c * 256 + d
end

--- Read `len` bytes at `offset` from `path`, or nil.
local function read_at(path, offset, len)
    local fd = uv().fs_open(path, "r", 0)
    if not fd then return nil end
    local data = uv().fs_read(fd, len, offset)
    uv().fs_close(fd)
    return data
end

--- Classify raw header bytes (pure; `fetch(offset, len)` reads more when the
--- format keeps its machine field further in, as PE does).
--- @param head string the first bytes of the file (at least 64 when available)
--- @param fetch? fun(offset: integer, len: integer): string|nil
--- @return { format: "elf"|"pe"|"macho", arch: string|nil }|nil
function M.classify_bytes(head, fetch)
    if type(head) ~= "string" or #head < 4 then return nil end
    if head:sub(1, 4) == "\127ELF" then
        local le = head:byte(6) ~= 2
        local machine = u16(head, 18, le)
        local arch = machine and ELF_MACHINE[machine] or nil
        return { format = "elf", arch = arch }
    end
    if head:sub(1, 2) == "MZ" then
        local lfanew = u32(head, 0x3C, true)
        if not lfanew then return nil end
        local pe = head:sub(lfanew + 1, lfanew + 6)
        if #pe < 6 and fetch then pe = fetch(lfanew, 6) or "" end
        if pe:sub(1, 4) ~= "PE\0\0" then return nil end
        local machine = u16(pe, 4, true)
        return { format = "pe", arch = machine and PE_MACHINE[machine] or nil }
    end
    local magic_be = u32(head, 0, false)
    if magic_be == 0xfeedface or magic_be == 0xfeedfacf then
        local cpu = u32(head, 4, false)
        return { format = "macho", arch = cpu and MACHO_CPU[cpu] or nil }
    end
    if magic_be == 0xcefaedfe or magic_be == 0xcffaedfe then
        local cpu = u32(head, 4, true)
        return { format = "macho", arch = cpu and MACHO_CPU[cpu] or nil }
    end
    if magic_be == 0xcafebabe then
        -- Universal binary: several architectures, none to compare.
        return { format = "macho", arch = nil }
    end
    return nil
end

--- Read and classify an executable's header. nil when unreadable or unknown.
--- @param path string
--- @return { format: string, arch: string|nil }|nil
function M.read(path)
    if type(path) ~= "string" or path == "" then return nil end
    local head = read_at(path, 0, 4096)
    if not head then return nil end
    return M.classify_bytes(head, function(off, len) return read_at(path, off, len) end)
end

--- The host's executable format and architecture.
--- @return { format: string, arch: string|nil, os: string }
function M.host()
    local u = uv().os_uname and uv().os_uname() or {}
    local sys = (u.sysname or ""):lower()
    local format, os_name
    if package.config:sub(1, 1) == "\\" or sys:match("windows") or sys:match("mingw") then
        format, os_name = "pe", "windows"
    elseif sys == "darwin" then
        format, os_name = "macho", "darwin"
    else
        format, os_name = "elf", sys ~= "" and sys or "linux"
    end
    return { format = format, arch = M.normalize_arch(u.machine), os = os_name }
end

--- Architectures a host architecture runs natively or through the platform's
--- standard compatibility layer.
local RUNS = {
    x86_64 = { x86_64 = true, x86 = true },
    x86 = { x86 = true },
    aarch64 = { aarch64 = true, arm = true },
    arm = { arm = true },
}
--- Emulation layers of desktop OSes on arm64 hosts.
local EMULATED = {
    windows = { x86_64 = true, x86 = true },
    darwin = { x86_64 = true },
}

--- Compare a probed header with the host. Returns true (plus a description of
--- the artifact's format) when the host cannot run it.
--- @param info { format: string, arch: string|nil }|nil
--- @param host? { format: string, arch: string|nil, os?: string }
--- @return boolean mismatch, string|nil what e.g. "an ELF aarch64 executable"
function M.mismatch(info, host)
    if not info then return false, nil end
    host = host or M.host()
    local label = ({ elf = "ELF", pe = "PE", macho = "Mach-O" })[info.format] or info.format
    local article = label:match("^[AEIOU]") and "an " or "a "
    local what = article .. label .. (info.arch and (" " .. info.arch) or "") .. " executable"
    if info.format ~= host.format then return true, what end
    if not info.arch or not host.arch then return false, nil end
    if info.arch == host.arch then return false, nil end
    local runs = RUNS[host.arch]
    if runs and runs[info.arch] then return false, nil end
    local emu = host.arch == "aarch64" and EMULATED[host.os or ""] or nil
    if emu and emu[info.arch] then return false, nil end
    if not runs then return false, nil end -- unknown host arch: cannot judge
    return true, what
end

--- Probe a file against the host.
--- @param path string
--- @param host? table
--- @return boolean foreign, string|nil what
function M.is_foreign_file(path, host)
    return M.mismatch(M.read(path), host)
end

return M
