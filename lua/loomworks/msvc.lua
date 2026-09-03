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
--- @type table<string, table|false>
M._clang_cl_for = {}

local VSWHERE = "C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
local VSWHERE_ARGS = { "-all", "-format", "json", "-products", "*" }

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

--- Build an install descriptor from one vswhere JSON entry, or nil when it is
--- not a usable VS install (unknown product line, or no vcvarsall on disk).
--- @param install table one entry from vswhere's JSON output
--- @return table|nil
local function build_install(install)
    local path = install.installationPath
    local line = install.catalog and install.catalog.productLineVersion
    local vs_major = ({ ["2022"] = "17", ["2019"] = "16", ["2017"] = "15" })[line]
    if not (path and vs_major) then return nil end
    local product = (install.productId or ""):match("%.(%w+)$") or "Unknown"
    path = path:gsub("\\", "/")
    local vcvarsall = path .. "/VC/Auxiliary/Build/vcvarsall.bat"
    if not uv.fs_stat(vcvarsall) then return nil end
    return {
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

--- Parse vswhere JSON stdout into the sorted install list. Shared by the sync
--- and async detection paths so both return the identical shape/ordering.
--- @param output string|nil
--- @return table[]
local function parse_installs(output)
    local installs = {}
    local ok, data = pcall(vim.json.decode, output or "")
    if ok and type(data) == "table" then
        for _, install in ipairs(data) do
            local built = build_install(install)
            if built then installs[#installs + 1] = built end
        end
    end
    -- Newest / richest edition first (Enterprise > Professional > BuildTools by
    -- string order is coincidental; the id sort keeps a stable deterministic order).
    table.sort(installs, function(a, b) return a.id > b.id end)
    return installs
end

--- Detect Visual Studio installations via vswhere. Cached for the process.
--- @return { id: string, display: string, vs_major: string, version_line: string, product: string, vcvarsall: string, arch: string, install_path: string }[]
function M.detect()
    if M._installs then return M._installs end

    if not uv.fs_stat(VSWHERE) then
        M._installs = {}
        return M._installs
    end

    local cmd = { VSWHERE }
    vim.list_extend(cmd, VSWHERE_ARGS)
    M._installs = parse_installs(run(cmd))
    return M._installs
end

--- Detect Visual Studio installations without blocking (async vswhere).
--- Returns the SAME install shape as `M.detect()` and populates the same cache,
--- so callers can share results. Calls back immediately when already cached.
--- @param callback fun(installs: table[])
function M.detect_async(callback)
    if M._installs then
        callback(M._installs)
        return
    end

    if not uv.fs_stat(VSWHERE) then
        M._installs = {}
        callback(M._installs)
        return
    end

    local cmd = { VSWHERE }
    vim.list_extend(cmd, VSWHERE_ARGS)
    vim.system(cmd, { text = true }, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                M._installs = {}
            else
                M._installs = parse_installs(res.stdout)
            end
            callback(M._installs)
        end)
    end)
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

--- Find a sibling clangd next to a clang-cl driver, if present.
--- @param path string clang-cl executable path
--- @return string|nil normalized clangd.exe path, or nil
local function sibling_clangd(path)
    local dir = path:match("^(.+)[/\\][^/\\]+$")
    if not dir then return nil end
    local candidate = dir .. "/clangd.exe"
    if uv.fs_stat(candidate) then return M.normalize_exe(candidate) end
    return nil
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

--- Async sibling of `M.clang_cl`. The `exepath` gate is a fast sync lookup;
--- only the `clang-cl --version` probe is run off the main loop via
--- `vim.system`. Shares and populates the same `M._clang_cl` cache, so a later
--- sync `clang_cl()` is a cache hit (and vice-versa). Calls back immediately
--- when already cached.
--- @param callback fun(info: { path: string, version: string }|nil)
function M.clang_cl_async(callback)
    if M._clang_cl ~= nil then
        callback(M._clang_cl or nil)
        return
    end
    local path = vim.fn.exepath("clang-cl")
    if not path or path == "" then
        M._clang_cl = false
        callback(nil)
        return
    end
    path = M.normalize_exe(path)
    vim.system({ path, "--version" }, { text = true }, function(res)
        vim.schedule(function()
            local out = res.code == 0 and res.stdout or nil
            local version = parse_version(out) or "0"
            M._clang_cl = { path = path, version = version }
            callback(M._clang_cl)
        end)
    end)
end

--- Locate the clang-cl paired to a specific MSVC install. clang-cl is Clang's
--- MSVC-compatible driver: it has no STL / Windows SDK / linker of its own and
--- reuses the paired install's via vcvarsall, so there is exactly one clang-cl
--- per install. Prefers the VS-bundled clang-cl (the "C++ Clang tools for
--- Windows" component), falling back to a standalone / PATH clang-cl.
--- Cached per install_path.
--- @param install table one entry returned by `M.detect()`
--- @return { path: string, version: string, clangd_path: string|nil }|nil
function M.clang_cl_for(install)
    if not (install and install.install_path) then return nil end
    local key = install.install_path
    if M._clang_cl_for[key] ~= nil then
        return M._clang_cl_for[key] or nil
    end

    local path, clangd_path

    -- 1. VS-bundled clang-cl, already paired to this install's STL + SDK.
    local bundled = install.install_path .. "/VC/Tools/Llvm/x64/bin/clang-cl.exe"
    if uv.fs_stat(bundled) then
        path = M.normalize_exe(bundled)
        clangd_path = sibling_clangd(bundled)
    else
        -- 2. Standalone / PATH clang-cl. It still borrows this install's SDK +
        --    libs through vcvarsall when the tool is used.
        local standalone = M.clang_cl()
        if standalone then
            path = standalone.path
            clangd_path = sibling_clangd(standalone.path)
        end
    end

    if not path then
        M._clang_cl_for[key] = false
        return nil
    end

    local version = parse_version(run({ path, "--version" })) or "0"
    local result = { path = path, version = version, clangd_path = clangd_path }
    M._clang_cl_for[key] = result
    return result
end

--- Async sibling of `M.clang_cl_for`. Same resolution (VS-bundled clang-cl
--- preferred, standalone/PATH fallback) and the same per-install cache, with
--- the `--version` probe run off the main loop via `vim.system`. The bundled
--- probe uses a fast sync `fs_stat`; the standalone branch defers to
--- `clang_cl_async`. Calls back immediately when already cached.
--- @param install table one entry returned by `M.detect()`
--- @param callback fun(info: { path: string, version: string, clangd_path: string|nil }|nil)
function M.clang_cl_for_async(install, callback)
    if not (install and install.install_path) then
        callback(nil)
        return
    end
    local key = install.install_path
    if M._clang_cl_for[key] ~= nil then
        callback(M._clang_cl_for[key] or nil)
        return
    end

    -- Complete the descriptor with an async `--version` probe of `path`.
    local function finish(path, clangd_path)
        vim.system({ path, "--version" }, { text = true }, function(res)
            vim.schedule(function()
                local out = res.code == 0 and res.stdout or nil
                local version = parse_version(out) or "0"
                local result = { path = path, version = version, clangd_path = clangd_path }
                M._clang_cl_for[key] = result
                callback(result)
            end)
        end)
    end

    -- 1. VS-bundled clang-cl, already paired to this install's STL + SDK.
    local bundled = install.install_path .. "/VC/Tools/Llvm/x64/bin/clang-cl.exe"
    if uv.fs_stat(bundled) then
        finish(M.normalize_exe(bundled), sibling_clangd(bundled))
        return
    end

    -- 2. Standalone / PATH clang-cl (borrows this install's SDK + libs via
    --    vcvarsall when the tool is used).
    M.clang_cl_async(function(standalone)
        if not standalone then
            M._clang_cl_for[key] = false
            callback(nil)
            return
        end
        finish(standalone.path, sibling_clangd(standalone.path))
    end)
end

--- Clear cached detection + env snapshots (called from the module rescan flow).
function M.clear_cache()
    M._installs = nil
    M._env = {}
    M._clang_cl = nil
    M._clang_cl_for = {}
end

return M
