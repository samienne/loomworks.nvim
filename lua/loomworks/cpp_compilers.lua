--- loomworks/cpp_compilers.lua — Native C/C++ compiler detection
--- and identification.
---
--- Single source of truth for "what is this C/C++ compiler" knowledge
--- in the codebase. Used by modules that pin a compiler toolchain
--- (cmake, meson) and by the user-declared compiler SDK provider
--- (`sdks/cpp_compiler.lua`).
---
--- Two entry points:
---   * `M.detect()` / `M.detect_async()` — probe PATH for known
---     compiler binaries (gcc, g++, clang, clang++, versioned
---     variants) and return everything found. Results are cached for
---     the nvim process; `clear_cache()` re-scans.
---   * `M.probe_path(path)` — identify an arbitrary user-provided
---     compiler executable. No PATH search; the caller is asserting
---     "this is the compiler I want." Returns the same shape as the
---     PATH-detected variants.
---
--- All family-specific knowledge (regex against `--version` output,
--- C-counterpart naming, sibling-clangd discovery gated on Clang)
--- lives in this file. Other parts of the codebase consume the
--- resulting toolchain table opaquely.

local M = {}

--- @class loomworks.CompilerToolchain
--- @field id string unique identifier (e.g. "gcc-14.2.0", "clang-18.1.8")
--- @field display string human-readable (e.g. "GCC 14.2.0")
--- @field family "gcc"|"clang" compiler family
--- @field version string dotted version string
--- @field path string absolute path to the C++ driver (g++/clang++)
--- @field c_path string absolute path to the C driver (gcc/clang)
--- @field bin_dir string directory containing the driver (and its
---        runtime DLLs on Windows — the key reason callers want this)
--- @field clangd_path string|nil sibling clangd, if present

local uv = vim.uv or vim.loop

--- @type loomworks.CompilerToolchain[]|nil
M._cached = nil

--- Run a command synchronously via vim.fn.system.
--- @param cmd string[]
--- @return string|nil trimmed stdout, or nil on non-zero exit
local function run(cmd)
    local result = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return nil end
    return vim.trim(result)
end

--- Extract a dotted version from `--version` output.
--- @param output string|nil
--- @return string|nil
local function parse_version(output)
    if not output then return nil end
    return output:match("(%d+%.%d+%.%d+)") or output:match("(%d+%.%d+)")
end

--- Identify the compiler family from `--version` output, falling back to the
--- binary name when the output says nothing we recognize.
---
--- The output is authoritative and the name is only a hint, because a name can
--- lie: on macOS `/usr/bin/gcc` and `/usr/bin/g++` are shims for Apple clang.
--- Trusting the name there reports one compiler twice — honestly as clang, and
--- again as a "GCC" that is not GCC — so a toolchain pinned to gcc silently
--- builds with clang.
---
--- Order matters: "Apple clang" output still contains "clang".
--- @param ver_output string|nil raw `--version` stdout
--- @param name_or_path string|nil binary name or path, used only as fallback
--- @return "gcc"|"clang"|nil
local function family_of(ver_output, name_or_path)
    local lower = (ver_output or ""):lower()
    if lower:match("clang version") or lower:match("apple clang") then
        return "clang"
    elseif lower:match("free software foundation") or lower:match("gcc")
        or lower:match("g%+%+") then
        return "gcc"
    end
    local basename = (name_or_path or ""):match("[^/\\]+$") or ""
    if basename:match("^clang") then return "clang"
    elseif basename:match("^g[c%+]") then return "gcc" end
    return nil
end

--- Probe a candidate compiler binary by name. Returns absolute path,
--- version and the raw `--version` output if it exists and reports a
--- version. Nil otherwise.
--- @param name string
--- @return string|nil path, string|nil version, string|nil ver_output
local function probe(name)
    if vim.fn.executable(name) ~= 1 then return nil, nil, nil end
    local path = vim.fn.exepath(name)
    if path == "" then return nil, nil, nil end
    local out = run({ path, "--version" })
    return path, parse_version(out), out
end

--- Find a clangd binary alongside a compiler driver.
--- @param driver_path string
--- @return string|nil
local function sibling_clangd(driver_path)
    local dir = driver_path:match("^(.+)[/\\][^/\\]+$")
    if not dir then return nil end
    for _, candidate in ipairs({ dir .. "/clangd", dir .. "/clangd.exe" }) do
        if vim.fn.executable(candidate) == 1 or uv.fs_stat(candidate) then
            return candidate
        end
    end
    return nil
end

--- Derive the bin directory from a driver path. On Windows this is
--- the dir the DLLs (libstdc++-6.dll etc.) live in and must be
--- prepended to PATH when running binaries built by the compiler.
--- @param driver_path string
--- @return string
local function bin_dir_of(driver_path)
    return driver_path:match("^(.+)[/\\][^/\\]+$") or ""
end

--- Derive the sibling C driver path for a C++ driver (e.g. g++ → gcc).
--- @param name string candidate name that matched (e.g. "g++-13")
--- @param path string path that matched
--- @return string path to the C driver (falls back to the C++ path)
local function c_counterpart(name, path)
    if not name:match("%+%+") then return path end
    -- Order matters: substitute `clang%+%+` BEFORE `g%+%+`. "clang++" contains
    -- the substring "g++", so a g++→gcc pass first corrupts it to "clangcc"
    -- (probe fails → wrong fallback to the C++ driver, i.e. CC=clang++). Same
    -- rationale as the from_probe() path below.
    local c_name = name:gsub("clang%+%+", "clang"):gsub("g%+%+", "gcc")
    local p = probe(c_name)
    return p or path
end

--- Candidate binary names worth probing. Plain names + versioned
--- variants. Kept narrow on purpose; exotic toolchains can be added
--- when a user reports needing them.
---
--- Clang names come first so that when two names resolve to the same compiler
--- (macOS ships gcc/g++ as Apple clang shims) the entry keeps the path that
--- matches what it actually is. Elsewhere the two families produce different
--- ids, so the order has no effect.
local function candidate_names()
    local names = {}
    for _, base in ipairs({ "clang++", "clang", "g++", "gcc" }) do
        names[#names + 1] = base
        for v = 8, 25 do
            names[#names + 1] = base .. "-" .. v
        end
    end
    return names
end

--- Detect all compilers available via PATH (sync). Caches the result
--- for this nvim process.
--- @return loomworks.CompilerToolchain[]
function M.detect()
    if M._cached then return M._cached end

    local compilers = {}
    local seen_id = {}
    local seen_path = {}

    for _, name in ipairs(candidate_names()) do
        local path, version, ver_output = probe(name)
        if not path or not version then goto continue end
        if seen_path[path] then goto continue end

        -- Ask the binary what it is rather than trusting its name — see
        -- family_of. A shim (macOS /usr/bin/gcc → Apple clang) resolves to its
        -- real family here, so it collides with the honest entry on `id` below
        -- and is deduplicated instead of being listed as a second compiler.
        local family = family_of(ver_output, name)
        if not family then goto continue end

        local id = family .. "-" .. version
        if seen_id[id] then goto continue end
        seen_id[id] = true
        seen_path[path] = true

        -- Ensure we store the C++ driver path (g++ / clang++).
        -- If `name` matched the C driver, look for its C++ counterpart.
        local is_cpp = name:match("%+%+") ~= nil
        local cpp_path = path
        if not is_cpp then
            local cpp_name
            if family == "gcc" then
                cpp_name = name:gsub("^gcc", "g++")
            else
                cpp_name = name:gsub("^clang", "clang++")
            end
            local cp = probe(cpp_name)
            if cp then cpp_path = cp end
        end
        local c_path = c_counterpart(name:match("%+%+") and name or name, cpp_path)

        compilers[#compilers + 1] = {
            id = id,
            display = (family == "gcc" and "GCC " or "Clang ") .. version,
            family = family,
            version = version,
            path = cpp_path,
            c_path = c_path,
            bin_dir = bin_dir_of(cpp_path),
            clangd_path = sibling_clangd(cpp_path),
        }

        ::continue::
    end

    table.sort(compilers, function(a, b)
        if a.family ~= b.family then return a.family < b.family end
        return a.version > b.version
    end)

    M._cached = compilers
    return compilers
end

--- Async variant. Uses the sync path since `vim.fn.system` for
--- `--version` is fast and the scan runs at most once per nvim process.
--- @param callback fun(compilers: loomworks.CompilerToolchain[])
function M.detect_async(callback)
    vim.schedule(function() callback(M.detect()) end)
end

--- Look up a compiler by id.
--- @param id string
--- @return loomworks.CompilerToolchain|nil
function M.get_by_id(id)
    for _, c in ipairs(M.detect()) do
        if c.id == id then return c end
    end
    return nil
end

--- Identify an arbitrary user-provided compiler executable. Used by
--- the custom-compiler SDK provider — the user picks a path; we work
--- out everything else.
---
--- Resolution:
---   * Run `--version`; match the output against known family
---     patterns (Clang first because some GCC distros mention Clang
---     in `__has_include` lines; Apple Clang and stock LLVM Clang
---     are both reported as "Clang"). Falls back to inspecting the
---     basename if `--version` is silent on family.
---   * Version extraction is the same digit-pattern used by the
---     PATH scanner.
---   * `c_path` is derived from the basename only when the input
---     looks like a C++ driver (`*++` / `clang++` / `g++`); otherwise
---     `c_path` equals `path` (the input is already a C driver, or
---     the family doesn't follow the C/C++ split convention).
---   * `clangd_path` is **only** populated when family is Clang —
---     a GCC sibling won't have a clangd binary and probing
---     for one would be misleading.
---
--- Returned shape mirrors `loomworks.CompilerToolchain` so callers
--- can treat PATH-detected and user-declared compilers identically.
--- @param path string absolute path to a compiler executable
--- @return loomworks.CompilerToolchain|nil
function M.probe_path(path)
    if not path or path == "" then return nil end
    if not uv.fs_stat(path) then return nil end

    local ver_output = run({ path, "--version" })
    if not ver_output then return nil end
    local version = parse_version(ver_output)
    if not version then return nil end

    -- Family detection: the `--version` output is authoritative, the basename
    -- only a fallback. Shared with the PATH scan (see family_of).
    local family = family_of(ver_output, path)

    -- Derive C counterpart by name only when input looks like a
    -- C++ driver. We don't `probe` (no recursive --version call) —
    -- existence check is sufficient. Order matters: `clang%+%+`
    -- must be substituted *before* `g%+%+` because "clang++"
    -- contains "g++" as a substring; running the GCC rule first
    -- would corrupt "clang++" → "clangcc".
    local c_path = path
    local basename = path:match("[^/\\]+$") or ""
    local is_cpp = basename:match("%+%+") ~= nil
    if is_cpp then
        local c_basename = basename
            :gsub("clang%+%+", "clang")
            :gsub("g%+%+", "gcc")
        local sep = path:find("[/\\][^/\\]+$")
        if sep then
            local candidate = path:sub(1, sep) .. c_basename
            if uv.fs_stat(candidate) then c_path = candidate end
        end
    end

    -- clangd discovery: only meaningful for the Clang family.
    local clangd_path = family == "clang" and sibling_clangd(path) or nil

    local family_label = family == "gcc" and "GCC"
        or family == "clang" and "Clang"
        or "C++"

    return {
        id = (family or "cpp") .. "-" .. version,
        display = family_label .. " " .. version,
        family = family,
        version = version,
        path = path,
        c_path = c_path,
        bin_dir = bin_dir_of(path),
        clangd_path = clangd_path,
    }
end

--- Clear the detection cache. Called by modules' `invalidate_tools`.
function M.clear_cache()
    M._cached = nil
end

return M
