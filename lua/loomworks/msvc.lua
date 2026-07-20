--- loomworks/msvc.lua — shared MSVC (Visual Studio) toolchain discovery and
--- environment setup, for modules that build with cl.exe / clang-cl.
---
--- Two things a module needs to build with MSVC-family compilers:
---   1. Which VS installations exist (via vswhere) and their vcvarsall.bat.
---   2. The environment vcvarsall establishes (INCLUDE / LIB / LIBPATH / PATH
---      to cl.exe + the Windows SDK). We snapshot it once per (vcvarsall, arch)
---      by running vcvarsall then `set` in a temp batch file — passing a single
---      simple argument to cmd.exe avoids Windows nested-quote breakage.
---
--- Host-neutral: uses vim.system / vim.json / vim.fn, which the standalone
--- shim provides, so it works under both Neovim and the luvi host.

local uv = vim.uv or vim.loop

local M = {}

--- @type table|nil
M._installs = nil
--- @type table<string, table>
M._env = {}
--- @type table|nil|false
M._clang_cl = nil

--- Run a command synchronously, returning trimmed stdout or nil on failure.
--- @param cmd string[]
--- @return string|nil
local function run(cmd)
    local res = vim.system(cmd, { text = true }):wait()
    if res.code ~= 0 then return nil end
    return res.stdout
end

--- Extract a dotted version from `--version` output.
--- @param output string|nil
--- @return string|nil
local function parse_version(output)
    if not output then return nil end
    return output:match("(%d+%.%d+%.%d+)") or output:match("(%d+%.%d+)")
end

--- Detect Visual Studio installations via vswhere. Cached for the process.
--- @return { id: string, display: string, vs_major: string, version_line: string, product: string, vcvarsall: string, arch: string, install_path: string }[]
function M.detect()
    if M._installs then return M._installs end
    local installs = {}

    local vswhere = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    if not uv.fs_stat(vswhere) then
        M._installs = installs
        return installs
    end

    local output = run({ vswhere, "-all", "-format", "json", "-products", "*" })
    local ok, data = pcall(vim.json.decode, output or "")
    if ok and type(data) == "table" then
        for _, install in ipairs(data) do
            local path = install.installationPath
            local line = install.catalog and install.catalog.productLineVersion
            local vs_major = ({ ["2022"] = "17", ["2019"] = "16", ["2017"] = "15" })[line]
            if path and vs_major then
                local product = (install.productId or ""):match("%.(%w+)$") or "Unknown"
                path = path:gsub("\\", "/")
                local vcvarsall = path .. "/VC/Auxiliary/Build/vcvarsall.bat"
                if uv.fs_stat(vcvarsall) then
                    installs[#installs + 1] = {
                        id = "msvc-" .. vs_major .. "-" .. line .. "-" .. product:lower(),
                        display = "MSVC " .. vs_major .. " " .. line .. " (" .. product .. ")",
                        vs_major = vs_major,
                        version_line = line,
                        product = product,
                        vcvarsall = vcvarsall,
                        arch = "x64",
                        install_path = path,
                    }
                end
            end
        end
    end
    -- Newest / richest edition first (Enterprise > Professional > BuildTools by
    -- string order is coincidental; the id sort keeps a stable deterministic order).
    table.sort(installs, function(a, b) return a.id > b.id end)
    M._installs = installs
    return installs
end

--- Snapshot the environment vcvarsall establishes. Cached per (vcvarsall, arch).
--- Runs `call vcvarsall <arch> && set` from a temp batch (single cmd argument
--- sidesteps Windows quoting), then parses the NAME=VALUE lines.
--- @param vcvarsall string path to vcvarsall.bat
--- @param arch? string default "x64"
--- @return table<string, string>|nil env, string|nil err
function M.vcvars_env(vcvarsall, arch)
    arch = arch or "x64"
    local key = vcvarsall .. "|" .. arch
    if M._env[key] then return M._env[key] end

    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "."):gsub("\\", "/")
    local bat = tmp .. "/lw_vcvars_" .. arch .. ".bat"
    local f, ferr = io.open(bat, "w")
    if not f then return nil, "could not write temp batch: " .. tostring(ferr) end
    f:write("@echo off\r\n")
    f:write('call "' .. vcvarsall:gsub("/", "\\") .. '" ' .. arch .. "\r\n")
    f:write("set\r\n")
    f:close()

    local res = vim.system({ "cmd.exe", "/c", bat }, { text = true }):wait()
    pcall(os.remove, bat)
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return nil, "vcvarsall failed (exit " .. tostring(res.code) .. ")"
    end

    local env = {}
    for lineval in res.stdout:gmatch("[^\r\n]+") do
        local k, v = lineval:match("^([^=]+)=(.*)$")
        if k and v then env[k] = v end
    end
    -- Sanity: a real vcvars environment always sets INCLUDE + LIB.
    if not (env.INCLUDE and env.LIB) then
        return nil, "vcvarsall produced no INCLUDE/LIB environment"
    end
    M._env[key] = env
    return env
end

--- Normalize an executable path: forward slashes, lowercase `.exe`.
---
--- `vim.fn.exepath` reports the extension in whatever casing PATHEXT carries,
--- so a compiler commonly comes back as `clang-cl.EXE`. meson matches the
--- compiler basename against `clang-cl.exe` **case-sensitively**: given the
--- uppercase spelling it does not recognise clang's MSVC driver, probes for a
--- GNU-style linker instead, and configure fails with "Unable to detect linker
--- for compiler `... -Wl,--version`".
---
--- Applied both at detection and where a task environment is composed — the
--- tool's paths are persisted in the cache, so a profile created before this
--- existed still carries the uppercase spelling and would otherwise stay
--- broken until the profile was recreated.
---
--- Windows paths are case-insensitive, so this costs nothing.
--- @param path string|nil
--- @return string|nil
function M.normalize_exe(path)
    if type(path) ~= "string" or path == "" then return path end
    return (path:gsub("\\", "/"):gsub("%.[eE][xX][eE]$", ".exe"))
end

--- Locate clang-cl (clang's MSVC driver), if installed. Cached.
--- @return { path: string, version: string }|nil
function M.clang_cl()
    if M._clang_cl ~= nil then
        return M._clang_cl or nil
    end
    local path = vim.fn.exepath("clang-cl")
    if not path or path == "" then
        M._clang_cl = false
        return nil
    end
    path = M.normalize_exe(path)
    local version = parse_version(run({ path, "--version" })) or "0"
    M._clang_cl = { path = path, version = version }
    return M._clang_cl
end

--- Clear cached detection + env snapshots (called from the module rescan flow).
function M.clear_cache()
    M._installs = nil
    M._env = {}
    M._clang_cl = nil
end

return M
