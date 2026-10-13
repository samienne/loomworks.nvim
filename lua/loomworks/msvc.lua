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

-- ---------------------------------------------------------------------------
-- Batch-file safety. vcvarsall has to run inside cmd.exe, so loomworks writes
-- small .bat files. Everything written into one comes from tool data (which
-- can come from the cache) or from the build command, so each piece is
-- validated or quoted for cmd's parser — a path or argument must never be
-- able to add a command.
-- ---------------------------------------------------------------------------

--- The architecture arguments vcvarsall.bat accepts (host[_target]).
M.VCVARS_ARCHES = {
    x86 = true, x64 = true, amd64 = true, arm = true, arm64 = true,
    x86_amd64 = true, x86_x64 = true, x86_arm = true, x86_arm64 = true,
    amd64_x86 = true, amd64_arm = true, amd64_arm64 = true,
    x64_x86 = true, x64_arm = true, x64_arm64 = true,
    arm64_amd64 = true, arm64_x64 = true, arm64_x86 = true, arm64_arm = true,
}

--- Characters cmd.exe treats specially (or that end a line) — never allowed in
--- the vcvarsall path, which is written into a `call "<path>"` line.
local BAT_UNSAFE_PATH = '["%%^&|<>!\r\n%z]'

--- Is `arch` a vcvarsall architecture argument?
--- @param arch any
--- @return boolean
function M.valid_arch(arch)
    return type(arch) == "string" and M.VCVARS_ARCHES[arch:lower()] == true
end

--- Validate a vcvarsall.bat path before it is written into a batch file: an
--- absolute path to an existing file named `vcvarsall.bat`, free of cmd.exe
--- metacharacters (`"` `%` `^` `&` `|` `<` `>` `!`, line breaks).
--- @param path any
--- @return boolean ok, string|nil err
function M.check_vcvarsall(path)
    if type(path) ~= "string" or path == "" then return false, "no vcvarsall.bat path" end
    if path:find(BAT_UNSAFE_PATH) then
        return false, "refusing vcvarsall path with shell metacharacters: " .. path
    end
    if not (path:match("^%a:[/\\]") or path:match("^[/\\][/\\][^/\\]")) then
        return false, "vcvarsall path is not absolute: " .. path
    end
    local base = path:match("([^/\\]+)$") or ""
    if base:lower() ~= "vcvarsall.bat" then
        return false, "not a vcvarsall.bat: " .. path
    end
    local st = uv.fs_stat(path)
    if not st or st.type ~= "file" then
        return false, "vcvarsall.bat not found: " .. path
    end
    return true, nil
end

--- Quote one argv element for a command line inside a .bat file, so cmd.exe
--- passes it through literally and the program's (MSVC CRT) argument parser
--- receives exactly `arg`: always double-quoted (cmd leaves `& | < > ^ ( )`
--- alone inside quotes), `%` doubled (a batch file expands `%...%` even in
--- quotes), backslashes before the closing quote doubled (CRT rule). An
--- argument containing `"`, a line break or NUL cannot be carried safely and
--- is refused (nil + err). Delayed expansion (`!`) is disabled by the batch
--- preamble (`setlocal DisableDelayedExpansion`).
--- @param arg string
--- @return string|nil quoted, string|nil err
function M.bat_quote(arg)
    arg = tostring(arg)
    if arg:find('["\r\n%z]') then
        return nil, "cannot pass an argument containing a quote or line break through a batch file: " .. arg
    end
    local q = arg:gsub("%%", "%%%%")
    q = q:gsub("(\\+)$", "%1%1")
    return '"' .. q .. '"'
end

--- The fixed preamble of every generated batch file: no echo, no delayed
--- expansion, and no current-directory search for bare command names (cmd.exe
--- honours NoDefaultCurrentDirectoryInExePath for the commands it runs).
M.BAT_PREAMBLE = "@echo off\r\nsetlocal DisableDelayedExpansion\r\n"
    .. "set \"NoDefaultCurrentDirectoryInExePath=1\"\r\n"

-- ---------------------------------------------------------------------------
-- The Visual Studio Installer folder on vcvarsall's PATH. VS 2022's
-- vcvarsall.bat (VsDevCmd.bat and its ext scripts) runs `vswhere.exe` by bare
-- name; it lives in "<ProgramFiles(x86)>\Microsoft Visual Studio\Installer",
-- which is usually not on PATH, so every run printed "'vswhere.exe' is not
-- recognized ..." (and continued). Every environment loomworks runs vcvarsall
-- in gets that folder appended — when it exists, and only once. Output is
-- never filtered: a real failure stays visible.
-- ---------------------------------------------------------------------------

--- Environment reader (overridable by tests). Reads the PROCESS environment —
--- inside a daemon request scope that is the requesting client's
--- (loomworks.daemon.envscope).
--- @param name string
--- @return string|nil
function M._getenv(name) return os.getenv(name) end

--- The Visual Studio Installer folder (where vswhere.exe lives), or nil when
--- it does not exist: `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer`,
--- else the same under `%ProgramFiles%` (32-bit / ARM layouts).
--- @return string|nil dir backslash-separated
function M.installer_dir()
    for _, var in ipairs({ "ProgramFiles(x86)", "ProgramFiles" }) do
        local base = M._getenv(var)
        if type(base) == "string" and base ~= "" then
            local dir = (base:gsub("/", "\\"):gsub("\\+$", ""))
                .. "\\Microsoft Visual Studio\\Installer"
            local st = uv.fs_stat(dir)
            if st and st.type == "directory" then return dir end
        end
    end
    return nil
end

--- A PATH entry's comparison key: backslashes, no trailing separator, no
--- surrounding quotes, case-folded (Windows paths are case-insensitive).
local function path_entry_key(e)
    return (e:gsub('^%s*"', ""):gsub('"%s*$', ""):gsub("/", "\\"):gsub("\\+$", ""):lower())
end

--- `env` (a step / spawn environment overlay, not modified) with the Visual
--- Studio Installer folder appended to its PATH when that folder exists and
--- is not already on it (case-insensitive). The PATH extended is the
--- overlay's own (any casing of the name — collapsed to one `PATH` key), else
--- the inherited process PATH. Returns a copy; unchanged when there is
--- nothing to add.
--- @param env table<string, string>|nil
--- @return table<string, string>
function M.with_installer_path(env)
    local out = {}
    for k, v in pairs(env or {}) do out[k] = v end
    local dir = M.installer_dir()
    if not dir then return out end
    local base, name
    for k, v in pairs(out) do
        if type(k) == "string" and k:upper() == "PATH" then base, name = v, k end
    end
    if not base then
        base = M._getenv("PATH") or ""
        -- Spell the key as the inherited environment does (`Path` in a normal
        -- Windows session): hosts that merge the overlay over the inherited
        -- environment case-sensitively (vim.system) must not end up with two
        -- PATH entries, of which Windows would honour an arbitrary one.
        local ok, cur = pcall(uv.os_environ)
        if ok and type(cur) == "table" then
            for k in pairs(cur) do
                if type(k) == "string" and k:upper() == "PATH" then name = k; break end
            end
        end
    end
    local want = path_entry_key(dir)
    for e in base:gmatch("[^;]+") do
        if path_entry_key(e) == want then return out end
    end
    for k in pairs(out) do
        if type(k) == "string" and k:upper() == "PATH" then out[k] = nil end
    end
    base = base:gsub(";+$", "")
    out[name or "PATH"] = base .. (base ~= "" and ";" or "") .. dir
    return out
end

--- Create `path` exclusively (after removing whatever is there, without
--- following a link) and write `content`. Refuses to write through a
--- pre-existing symlink / junction planted at that name.
--- @param path string
--- @param content string
--- @return boolean ok, string|nil err
function M.write_bat_exclusive(path, content)
    local st = uv.fs_lstat(path)
    if st then
        local ok_rm, err_rm = uv.fs_unlink(path)
        if not ok_rm then return false, "cannot replace " .. path .. ": " .. tostring(err_rm) end
    end
    local fd, oerr = uv.fs_open(path, "wx", 420)
    if not fd then return false, "cannot create " .. path .. ": " .. tostring(oerr) end
    local ok_w, werr = uv.fs_write(fd, content, 0)
    uv.fs_close(fd)
    if not ok_w then return false, "cannot write " .. path .. ": " .. tostring(werr) end
    return true, nil
end

--- A random hex token for temp file names (unpredictable per run).
--- @return string
local function random_token()
    local ok, bytes = pcall(uv.random, 8)
    if ok and type(bytes) == "string" and #bytes == 8 then
        return (bytes:gsub(".", function(c) return ("%02x"):format(c:byte()) end))
    end
    math.randomseed(uv.hrtime() % 2147483647)
    return ("%08x%08x"):format(math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end
M._random_token = random_token

--- Run a command synchronously, returning trimmed stdout or nil on failure.
--- Callers pass an ABSOLUTE program path (vswhere, a found clang-cl).
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
        -- Product version (e.g. "17.11.2") — display only (health inventory detail).
        product_version = (install.catalog and install.catalog.productDisplayVersion)
            or install.installationVersion,
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
    if not M.valid_arch(arch) then
        return nil, "invalid vcvarsall architecture: " .. tostring(arch)
    end
    local okv, verr = M.check_vcvarsall(vcvarsall)
    if not okv then return nil, verr end
    local key = vcvarsall .. "|" .. arch
    if M._env[key] then return M._env[key] end

    -- An unpredictable name in the per-user temp dir, created exclusively.
    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or ""):gsub("\\", "/")
    if not tmp:match("^%a:/") and not tmp:match("^/") then
        return nil, "no absolute TEMP directory for the vcvars batch"
    end
    local bat = tmp .. "/lw_vcvars_" .. arch .. "_" .. random_token() .. ".bat"
    local okw, werr = M.write_bat_exclusive(bat, M.BAT_PREAMBLE
        .. 'call "' .. vcvarsall:gsub("/", "\\") .. '" ' .. arch .. "\r\n"
        .. "set\r\n")
    if not okw then return nil, "could not write temp batch: " .. tostring(werr) end

    -- The Installer folder on PATH so vcvarsall finds vswhere.exe (above).
    local penv = M.with_installer_path(nil)
    local res = require("loomworks.exe").system({ "cmd.exe", "/d", "/c", bat },
        { text = true, env = next(penv) and penv or nil }):wait()
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
    local path = require("loomworks.exe").editor_exepath("clang-cl")
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
    local path = require("loomworks.exe").editor_exepath("clang-cl")
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
--- reuses the paired install's via vcvarsall, so there is at most one clang-cl
--- per install. The VS-bundled clang-cl (the "C++ Clang tools for Windows"
--- component) always pairs with its own install. A standalone / PATH clang-cl
--- is used only when `opts.standalone` is set — callers set it for exactly ONE
--- install, the newest (`standalone_host`), so a PATH clang-cl yields one
--- tool instead of one named after every install (an old VS without clang
--- tools must not get a "clang-cl (VS 2017)" tool it never shipped).
--- Cached per (install_path, standalone).
--- @param install table one entry returned by `M.detect()`
--- @param opts? { standalone?: boolean } allow the standalone/PATH fallback
--- @return { path: string, version: string, clangd_path: string|nil }|nil
function M.clang_cl_for(install, opts)
    if not (install and install.install_path) then return nil end
    local standalone_ok = opts and opts.standalone and true or false
    local key = install.install_path .. (standalone_ok and "|standalone" or "")
    if M._clang_cl_for[key] ~= nil then
        return M._clang_cl_for[key] or nil
    end

    local path, clangd_path

    -- 1. VS-bundled clang-cl, already paired to this install's STL + SDK.
    local bundled = install.install_path .. "/VC/Tools/Llvm/x64/bin/clang-cl.exe"
    if uv.fs_stat(bundled) then
        path = M.normalize_exe(bundled)
        clangd_path = sibling_clangd(bundled)
    elseif standalone_ok then
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

--- Async sibling of `M.clang_cl_for`. Same resolution (VS-bundled clang-cl,
--- else — with `opts.standalone` — the standalone/PATH one) and the same
--- cache, with the `--version` probe run off the main loop via `vim.system`.
--- The bundled probe uses a fast sync `fs_stat`; the standalone branch defers
--- to `clang_cl_async`. Calls back immediately when already cached.
--- @param install table one entry returned by `M.detect()`
--- @param opts? { standalone?: boolean } allow the standalone/PATH fallback
--- @param callback fun(info: { path: string, version: string, clangd_path: string|nil }|nil)
function M.clang_cl_for_async(install, opts, callback)
    if type(opts) == "function" then opts, callback = nil, opts end
    if not (install and install.install_path) then
        callback(nil)
        return
    end
    local standalone_ok = opts and opts.standalone and true or false
    local key = install.install_path .. (standalone_ok and "|standalone" or "")
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
    if not standalone_ok then
        M._clang_cl_for[key] = false
        callback(nil)
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

--- Whether `install` is the one a standalone / PATH clang-cl pairs with: the
--- first of `installs` (the locator's order — newest version line first), the
--- install most likely to carry an STL that a current clang-cl accepts.
--- @param install table
--- @param installs table[] the list `install` came from
--- @return boolean
function M.standalone_host(install, installs)
    return installs[1] == install
end

--- The MSVC toolset version vcvarsall selects for `install` by default (e.g.
--- "14.44.35207") — what builds depend on, unlike the VS product version. Read
--- from `VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt`, the file
--- vcvarsall itself reads: one small file read, no spawn. Nil when absent.
--- @param install table one entry from `M.detect()`
--- @param read_file fun(path: string): string|nil
--- @return string|nil
function M.toolset_version(install, read_file)
    if not (install and install.install_path) then return nil end
    local ok, content = pcall(read_file,
        install.install_path .. "/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt")
    if not ok or type(content) ~= "string" then return nil end
    return content:match("^%s*(%d+%.%d+[%d%.]*)")
end

--- The cmake / ninja executables a Visual Studio install bundles (the "C++ CMake
--- tools for Windows" component), relative to the install path.
local BUNDLED_TOOLS = {
    cmake = "/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe",
    ninja = "/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe",
}

--- Inventory id of the cmake / ninja bundled with the install owning
--- `vcvarsall` (`vs-<name>:<normalized vcvarsall>`). Keyed by vcvarsall — the
--- install identity every MSVC-style tool records — so a module's requirement
--- and this declaration agree without a filesystem access.
--- @param name "cmake"|"ninja"
--- @param vcvarsall string
--- @return string
function M.bundled_id(name, vcvarsall)
    return require("loomworks.inventory").path_id("vs-" .. name, vcvarsall)
end

--- Paths of the cmake + ninja bundled with `install`, or nil unless BOTH exist:
--- vcvarsall (VsDevCmd `ext/cmake.bat`) appends their two directories to PATH
--- only when both are present — and appends, so a cmake / ninja already on PATH
--- still wins.
--- @param install table one entry from `M.detect()`
--- @param exists fun(path: string): boolean
--- @return { cmake: string, ninja: string }|nil
function M.bundled_tools(install, exists)
    if not (install and install.install_path) then return nil end
    local out = {}
    for name, rel in pairs(BUNDLED_TOOLS) do
        local p = install.install_path .. rel
        if not exists(p) then return nil end
        out[name] = p
    end
    return out
end

--- Environment-inventory declaration for the Visual Studio toolchains
--- (headless §16.33, cmake §13 `compilers:msvc`), shared by every module that
--- builds with cl.exe / clang-cl so it is probed once. Windows only (nil
--- elsewhere). Enumerates the installs the locator finds — one result each,
--- id `msvc:<normalized vcvarsall>`, version = the default toolset
--- (`toolset_version`), detail = the VS product version — plus every clang-cl
--- paired to an install or on the search path (`clang-cl:<normalized path>`),
--- reusing the same detection the kits run, and each install's bundled cmake +
--- ninja (`bundled_tools`, listed under build tools).
--- @return loomworks.InventoryDeclaration|nil
function M.health_declaration()
    if vim.fn.has("win32") ~= 1 then return nil end
    local inv = require("loomworks.inventory")
    return {
        id = "compilers:msvc",
        category = "compilers",
        label = "MSVC (Visual Studio)",
        probe = function(ctx, done)
            M.detect_async(function(installs)
                local results, seen = {}, {}
                for _, inst in ipairs(installs) do
                    -- Version = the MSVC toolset a build gets (what vcvarsall
                    -- selects), not the VS product version — that one, minus
                    -- its release-date parenthetical, is the detail.
                    local pv = inst.product_version and tostring(inst.product_version):match("^%s*([%d%.]+)")
                    results[#results + 1] = {
                        id = inv.path_id("msvc", inst.vcvarsall),
                        label = inst.display,
                        status = "found",
                        version = M.toolset_version(inst, ctx.read_file),
                        detail = pv and ("VS " .. pv) or nil,
                        path = inst.install_path,
                    }
                end
                if #installs == 0 then
                    done({ {
                        id = "compilers:msvc", label = "MSVC (Visual Studio)", status = "missing",
                        hint = "install Visual Studio Build Tools (Desktop development with C++)",
                    } })
                    return
                end
                -- The cmake + ninja each install bundles (build tools): an
                -- MSVC-style build that runs inside vcvarsall finds them there
                -- when PATH has none (cmake §13 / meson §12 requirements
                -- accept them as alternatives). Last step: settles the probe.
                local function add_bundled()
                    local jobs = {}
                    for _, inst in ipairs(installs) do
                        local tools = M.bundled_tools(inst, ctx.exists)
                        for _, name in ipairs(tools and { "cmake", "ninja" } or {}) do
                            local r = {
                                id = M.bundled_id(name, inst.vcvarsall),
                                label = name .. " (VS " .. tostring(inst.version_line or inst.vs_major or "?")
                                    .. " " .. tostring(inst.product or "?") .. ")",
                                status = "found", path = tools[name], detail = "VS-bundled",
                                category = "build tools",
                            }
                            results[#results + 1] = r
                            jobs[#jobs + 1] = r
                        end
                    end
                    local pending = #jobs
                    if pending == 0 then return done(results) end
                    for _, r in ipairs(jobs) do
                        ctx.run({ r.path, "--version" }, function(res)
                            r.version = inv.parse_version((res.stdout or "") .. "\n" .. (res.stderr or ""))
                            pending = pending - 1
                            if pending == 0 then done(results) end
                        end)
                    end
                end
                -- clang-cl: VS-bundled per install, else the one on PATH.
                local function add_clang_cl(cc)
                    if not (cc and cc.path) then return end
                    local id = inv.path_id("clang-cl", cc.path)
                    if seen[id] then return end
                    seen[id] = true
                    results[#results + 1] = {
                        id = id, label = "clang-cl", status = "found",
                        version = cc.version ~= "0" and cc.version or nil,
                        path = cc.path,
                    }
                end
                local idx = 0
                local function next_install()
                    idx = idx + 1
                    if idx > #installs then
                        -- A clang-cl on PATH not paired to any install above.
                        M.clang_cl_async(function(cc)
                            add_clang_cl(cc)
                            if not next(seen) then
                                results[#results + 1] = {
                                    id = "clang-cl", label = "clang-cl", status = "missing",
                                    hint = "VS Installer: C++ Clang tools for Windows",
                                }
                            end
                            add_bundled()
                        end)
                        return
                    end
                    M.clang_cl_for_async(installs[idx], function(cc)
                        add_clang_cl(cc)
                        next_install()
                    end)
                end
                next_install()
            end)
        end,
    }
end

--- Clear cached detection + env snapshots (called from the module rescan flow).
function M.clear_cache()
    M._installs = nil
    M._env = {}
    M._clang_cl = nil
    M._clang_cl_for = {}
end

return M
