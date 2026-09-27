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

--- @type table<string, string>|nil
--- Cached PATH executable index: base name → absolute path. Built once by
--- scanning each `$PATH` directory a single time (see `M.lookup_path`), so the
--- 76-candidate compiler scan is 76 O(1) table hits instead of 76 full PATH
--- searches (`vim.fn.executable`/`vim.fn.exepath`), each of which walks every
--- PATH directory on Windows and blocks the UI on workspace load.
M._path_index = nil

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

--- True on Windows. Governs PATH separator, executable-extension stripping
--- and case-folding for the PATH index.
--- @return boolean
local function is_windows()
    return vim.fn.has("win32") == 1
end

--- Default Windows `PATHEXT` when the env var is unset/empty.
local DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD"

--- Parse a `PATHEXT` string into an ext (lower-cased, with dot) → rank map.
--- Rank is the 1-based position, so a lower rank wins within one directory
--- (mirroring the Windows command search order).
--- @param pathext string|nil
--- @return table<string, integer>
local function parse_pathext(pathext)
    if not pathext or pathext == "" then pathext = DEFAULT_PATHEXT end
    local ranks, n = {}, 0
    for ext in pathext:gmatch("[^;]+") do
        ext = ext:gsub("^%s+", ""):gsub("%s+$", ""):lower()
        if ext ~= "" then
            if ext:sub(1, 1) ~= "." then ext = "." .. ext end
            if ranks[ext] == nil then
                n = n + 1
                ranks[ext] = n
            end
        end
    end
    return ranks
end

--- Normalize one lister entry to `(name, type)`. Entries are either a plain
--- name string (type unknown) or a `{ name, type }` pair as produced by
--- `uv.fs_scandir_next`.
--- @param entry string|table
--- @return string|nil name, string|nil type
local function entry_parts(entry)
    if type(entry) == "table" then return entry[1], entry[2] end
    return entry, nil
end

--- Build the base-name → absolute-path index from a raw `$PATH` string.
---
--- Pure and side-effect-free apart from the injected `scandir_fn` / `stat_fn`,
--- so it is unit-testable without a real filesystem. Directories are scanned
--- left to right and the FIRST occurrence of a base name wins — matching PATH
--- precedence.
---
--- Only regular files are indexed: an entry whose scandir type is `"file"` is
--- accepted directly; a `"link"` or unknown/nil type is resolved with
--- `stat_fn` (which follows links) and kept only when it is a file. Anything
--- else (directories, broken links, devices) is skipped, so a directory named
--- like a tool (e.g. a `ccache` folder on PATH) can neither be returned nor
--- shadow the real executable later on PATH.
---
--- On Windows only names whose extension is in `PATHEXT` are executables: the
--- base key strips that extension and is lower-cased for case-insensitive
--- matching, and within one directory the earlier PATHEXT extension wins.
--- On Unix the filename is the key verbatim (case-sensitive).
--- @param path_string string|nil raw `$PATH`
--- @param is_win boolean
--- @param scandir_fn fun(dir: string): (string|{ [1]: string, [2]: string|nil })[]|nil
---   entries in `dir` — a name, or a `{ name, type }` pair (nil = unreadable)
--- @param opts? { stat_fn?: fun(path: string): table|nil, pathext?: string }
---   `stat_fn` defaults to `uv.fs_stat`; `pathext` (Windows) defaults to the
---   built-in `.COM;.EXE;.BAT;.CMD` list
--- @return table<string, string> index base name → `<dir>/<filename>` (forward slashes)
function M._build_path_index(path_string, is_win, scandir_fn, opts)
    opts = opts or {}
    local stat_fn = opts.stat_fn or uv.fs_stat
    local ext_rank = is_win and parse_pathext(opts.pathext) or nil
    local index = {}
    if not path_string or path_string == "" then return index end
    local sep = is_win and ";" or ":"
    -- Append a trailing separator so the final entry is captured too.
    for raw in (path_string .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
        -- Strip surrounding quotes and trailing slashes from the dir entry.
        local dir = raw:gsub('^"(.*)"$', "%1"):gsub("[/\\]+$", "")
        if dir ~= "" then
            local dir_norm = dir:gsub("\\", "/")
            local entries = scandir_fn(dir)
            if entries then
                -- Base names claimed by THIS directory → PATHEXT rank, so a
                -- better-ranked extension in the same dir can replace a worse one.
                local claimed = {}
                for _, entry in ipairs(entries) do
                    local filename, etype = entry_parts(entry)
                    local base, rank
                    if filename then
                        if is_win then
                            local ext = filename:match("(%.[^.]+)$")
                            rank = ext and ext_rank[ext:lower()]
                            if rank then
                                base = filename:sub(1, #filename - #ext):lower()
                            end
                        else
                            base = filename
                        end
                    end
                    local want = base and base ~= "" and (index[base] == nil
                        or (claimed[base] and rank and rank < claimed[base]))
                    if want then
                        local full = dir_norm .. "/" .. filename
                        local is_file = etype == "file"
                        if not is_file and (etype == nil or etype == "link"
                                or etype == "unknown") then
                            -- Ambiguous type: stat (follows links) — only here,
                            -- so the common case stays a plain directory read.
                            local st = stat_fn(full)
                            is_file = st ~= nil and st.type == "file"
                        end
                        if is_file then
                            index[base] = full
                            claimed[base] = rank or 0
                        end
                    end
                end
            end
        end
    end
    return index
end

--- List the entries of a directory via libuv as `{ name, type }` pairs, or nil
--- if it can't be read. A bad/inaccessible PATH entry must not break the whole
--- scan. Public (underscored) so tests can drive the real lister.
--- @param dir string
--- @return { [1]: string, [2]: string|nil }[]|nil
function M._scandir_entries(dir)
    local h = uv.fs_scandir(dir)
    if not h then return nil end
    local entries = {}
    while true do
        local name, etype = uv.fs_scandir_next(h)
        if not name then break end
        entries[#entries + 1] = { name, etype }
    end
    return entries
end

--- Return the cached PATH executable index, building it on first use by
--- scanning every `$PATH` directory exactly once.
--- @return table<string, string>
local function get_path_index()
    if M._path_index then return M._path_index end
    -- Read PATH via os.getenv: it works both under the standalone CLI's vim-shim
    -- (which has no `vim.env`) and off the main loop, whereas `vim.env` is a
    -- main-loop-only API that throws in a fast-event context.
    local path_string = os.getenv("PATH") or ""
    M._path_index = M._build_path_index(path_string, is_windows(), M._scandir_entries,
        { pathext = os.getenv("PATHEXT") })
    return M._path_index
end

--- Resolve a candidate name to its absolute path via the cached PATH index —
--- an O(1) lookup, not a full PATH search. Public so `cmake_kits` shares the
--- same index. Returns nil when the name isn't on PATH.
--- @param name string
--- @return string|nil
function M.lookup_path(name)
    local index = get_path_index()
    local key = is_windows() and name:lower() or name
    return index[key]
end

--- Probe a candidate compiler binary by name. Returns absolute path,
--- version and the raw `--version` output if it exists and reports a
--- version. Nil otherwise. Existence is resolved through the cached PATH
--- index (no per-candidate PATH search); the `--version` shell-out is
--- synchronous — this is the sync `M.detect` path's contract.
--- @param name string
--- @return string|nil path, string|nil version, string|nil ver_output
local function probe(name)
    local path = M.lookup_path(name)
    if not path then return nil, nil, nil end
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
--- @param lookup fun(name: string): string|nil path resolver (sync or async-safe)
--- @return string path to the C driver (falls back to the C++ path)
local function c_counterpart(name, path, lookup)
    if not name:match("%+%+") then return path end
    -- Order matters: substitute `clang%+%+` BEFORE `g%+%+`. "clang++" contains
    -- the substring "g++", so a g++→gcc pass first corrupts it to "clangcc"
    -- (lookup fails → wrong fallback to the C++ driver, i.e. CC=clang++).
    local c_name = name:gsub("clang%+%+", "clang"):gsub("g%+%+", "gcc")
    local p = lookup(c_name)
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

--- Assemble the final compiler list from primary `--version` probe results.
---
--- This is the single source of truth for dedup/family/counterpart/sort logic;
--- both `M.detect()` (sync) and `M.detect_async()` (async) feed it their probe
--- results, so the two paths return byte-for-byte identical arrays. Iterates
--- `names` in order so first-seen dedup on `id`/`path` is deterministic.
--- @param names string[] candidate names in scan order
--- @param primary table<string, { path: string, version: string|nil, ver_output: string|nil }>
---        probe result per name that resolved on PATH (absent name = not found)
--- @param lookup fun(name: string): string|nil path resolver for C/C++ counterparts
--- @return loomworks.CompilerToolchain[]
local function assemble(names, primary, lookup)
    local compilers = {}
    local seen_id = {}
    local seen_path = {}

    for _, name in ipairs(names) do
        local pr = primary[name]
        if not pr then goto continue end
        local path, version, ver_output = pr.path, pr.version, pr.ver_output
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
            local cp = lookup(cpp_name)
            if cp then cpp_path = cp end
        end
        local c_path = c_counterpart(name, cpp_path, lookup)

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

    return compilers
end

--- Detect all compilers available via PATH (sync). Caches the result
--- for this nvim process.
--- @return loomworks.CompilerToolchain[]
function M.detect()
    if M._cached then return M._cached end

    local names = candidate_names()
    local primary = {}
    for _, name in ipairs(names) do
        local path, version, ver_output = probe(name)
        if path then
            primary[name] = { path = path, version = version, ver_output = ver_output }
        end
    end

    local compilers = assemble(names, primary, M.lookup_path)
    M._cached = compilers
    return compilers
end

--- Detect all compilers available via PATH without blocking the UI.
---
--- The gate (which names exist on PATH) is an O(1) lookup into the cached PATH
--- executable index — genuinely fast, no shell and no per-candidate PATH walk —
--- so it stays inline; only the slow part — each candidate's `--version`
--- shell-out — is fanned out concurrently via `vim.system`. Results are
--- aggregated with a completion counter and fed to the SAME `assemble` routine
--- the sync path uses, so the async result is byte-for-byte identical (same
--- fields, dedup, and sort order). Populates the shared `M._cached`, and
--- short-circuits to it when already populated (by either path).
--- @param callback fun(compilers: loomworks.CompilerToolchain[])
function M.detect_async(callback)
    if M._cached then
        callback(M._cached)
        return
    end

    local names = candidate_names()

    -- Index gate (O(1) per name, no shell): keep candidate_names() order so the
    -- async dedup resolves identically to the sync scan.
    local primary = {}
    local to_probe = {}
    for _, name in ipairs(names) do
        local path = M.lookup_path(name)
        if path then
            primary[name] = { path = path }
            to_probe[#to_probe + 1] = name
        end
    end

    local function finish()
        local compilers = assemble(names, primary, M.lookup_path)
        M._cached = compilers
        callback(compilers)
    end

    if #to_probe == 0 then
        vim.schedule(finish)
        return
    end

    -- Fan out every `--version` probe concurrently; aggregate with a counter.
    local remaining = #to_probe
    for _, name in ipairs(to_probe) do
        local path = primary[name].path
        vim.system({ path, "--version" }, { text = true }, function(res)
            -- Mirror the sync `run` helper: nil on non-zero exit, else trimmed
            -- stdout (empty string stays empty, matching vim.fn.system + trim).
            local out = (res.code == 0 and res.stdout)
                and vim.trim(res.stdout) or nil
            primary[name].version = parse_version(out)
            primary[name].ver_output = out
            remaining = remaining - 1
            if remaining == 0 then
                -- assemble() calls vim.fn (counterpart lookups, sibling clangd),
                -- so defer onto the main loop out of the libuv callback context.
                vim.schedule(finish)
            end
        end)
    end
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

--- The compiler families user-declared `overrides` blocks may key on.
--- clang-cl is Clang's MSVC-compatible driver and resolves to `clang`.
M.KNOWN_FAMILIES = { clang = true, gcc = true, msvc = true }

--- Normalize a raw compiler-family label to one of the known families
--- (`clang`, `gcc`, `msvc`). `clang-cl` folds to `clang` — it is a Clang
--- driver, so a configuration's `overrides.clang` must apply under it.
--- Returns nil for anything unrecognized.
--- @param family string|nil
--- @return "clang"|"gcc"|"msvc"|nil
function M.normalize_family(family)
    if type(family) ~= "string" then return nil end
    local f = family:lower()
    if f == "clang-cl" then return "clang" end
    if M.KNOWN_FAMILIES[f] then return f end
    return nil
end

--- Derive the compiler family of a resolved tool from its opaque `tool_data`.
--- Prefers an explicit `compiler_family` field (meson sets one; normalized so
--- `clang-cl` → `clang`), then falls back to `compiler_id` / `compiler_path`
--- pattern matching (cmake kits carry no family field). Returns nil when the
--- family cannot be determined — a nil family means no compiler-specific
--- `overrides` apply, so resolution falls through to the plain `variables`.
--- @param tool_data table|nil
--- @return "clang"|"gcc"|"msvc"|nil
function M.family_from_tool_data(tool_data)
    if type(tool_data) ~= "table" then return nil end

    local explicit = M.normalize_family(tool_data.compiler_family)
    if explicit then return explicit end

    local id = tool_data.compiler_id
    if type(id) == "string" then
        local low = id:lower()
        if low:match("^clang") then return "clang" end -- clang- and clang-cl-
        if low:match("^gcc") or low:match("^g%+%+") then return "gcc" end
        if low:match("^msvc") or low:match("^cl%-") then return "msvc" end
    end

    local path = tool_data.compiler_path
    if type(path) == "string" then
        local low = path:lower()
        if low:match("clang%-cl") or low:match("clang") then return "clang" end
        if low:match("g%+%+") or low:match("gcc") then return "gcc" end
        if low:match("cl%.exe$") or low:match("vcvarsall") then return "msvc" end
    end

    if tool_data.vcvarsall then return "msvc" end
    return nil
end

--- Whether a resolved tool builds with the **MSVC ABI** — plain MSVC (`cl`) or
--- clang-cl. clang-cl uses cl.exe's command line and PDB/`/Z7` debug model, so
--- callers that must treat it like MSVC — the compiler-cache `auto` rule (core
--- §1.3.2: no launcher under `auto`), cmake's `/Z7` + CMP0141 injection and the
--- post-configure `/Zi` scan — use this
--- rather than `family_from_tool_data`, which folds clang-cl → `clang` (correct
--- for compiler-family *overrides*, wrong for the MSVC-ABI decisions here).
--- @param tool_data table|nil
--- @return boolean
function M.is_msvc_style(tool_data)
    if type(tool_data) ~= "table" then return false end
    local id = tostring(tool_data.compiler_id or ""):lower()
    local path = tostring(tool_data.compiler_path or ""):lower()
    local fam = tostring(tool_data.compiler_family or ""):lower()
    if id:match("clang%-cl") or path:match("clang%-cl") or fam == "clang-cl" then
        return true
    end
    return M.family_from_tool_data(tool_data) == "msvc"
end

-- ---------------------------------------------------------------------------
-- Compiler-cache compatibility: PDB-writing debug flags (cmake §5d, meson §5a)
-- ---------------------------------------------------------------------------

--- MSVC-style debug-info options that write to a SHARED program database
--- (`.pdb`) — incompatible with a compiler-cache launcher: sccache FAILS such a
--- compile, ccache compiles it uncached. `/Z7` (embedded) is the compatible
--- form. Both the slash and dash spellings are accepted by cl / clang-cl.
local PDB_DEBUG_FLAGS = { ["/Zi"] = true, ["/ZI"] = true, ["-Zi"] = true, ["-ZI"] = true }

--- The first PDB-writing debug flag in an argv/flag list, or nil.
--- @param args string[]|nil
--- @return string|nil flag
function M.pdb_debug_flag(args)
    for _, a in ipairs(args or {}) do
        if type(a) == "string" and PDB_DEBUG_FLAGS[a] then return a end
    end
    return nil
end

--- Accumulate one offending compile unit into a scan accumulator (created on
--- first use as `{}`), grouped by `group` (a target name, else a directory).
--- @param acc table accumulator (mutated)
--- @param group string
--- @param flag string offending flag
--- @param source string|nil representative source path
function M.pdb_scan_add(acc, group, flag, source)
    local g = acc[group]
    if not g then
        g = { flag = flag, units = 0, sample = {} }
        acc[group] = g
    end
    g.units = g.units + 1
    if source and #g.sample < 3 then g.sample[#g.sample + 1] = source end
end

--- Turn a scan accumulator into `cache_compat_scan` findings (module interface
--- §8), sorted by group. Severity is "error" for sccache (it fails those
--- compiles) and "warning" otherwise (ccache compiles them uncached).
--- @param acc table from `pdb_scan_add`
--- @param tool string|nil applied launcher name
--- @return { severity: string, flag: string, group: string, units: integer, sample: string[] }[]
function M.pdb_scan_findings(acc, tool)
    local severity = (tool == "sccache") and "error" or "warning"
    local groups = {}
    for name in pairs(acc) do groups[#groups + 1] = name end
    table.sort(groups)
    local out = {}
    for _, name in ipairs(groups) do
        local g = acc[name]
        out[#out + 1] = {
            severity = severity, flag = g.flag, group = name,
            units = g.units, sample = g.sample,
        }
    end
    return out
end

--- Environment variables the MSVC driver (cl, clang-cl) reads extra command
--- line flags from: `CL` is prepended and `_CL_` appended to every compile.
--- No compile-command listing shows them.
local MSVC_FLAG_ENV_VARS = { "CL", "_CL_" }

--- `cache_compat_scan` findings (module interface §8) for PDB-writing debug
--- flags that reach every compile through the configuration environment's
--- `CL` / `_CL_` (cmake §5d, meson §5a): one finding per offending variable,
--- `group = "environment"`, no unit count (it applies to every compile),
--- `sample` naming the variable. The lookup is case-insensitive (Windows
--- environment names are). Severity as `pdb_scan_findings`.
--- @param env table<string, string>|nil resolved configuration environment
--- @param tool string|nil applied launcher name
--- @return { severity: string, flag: string, group: string, sample: string[] }[]
function M.pdb_env_findings(env, tool)
    local out = {}
    if type(env) ~= "table" then return out end
    local severity = (tool == "sccache") and "error" or "warning"
    local by_upper = {}
    for k, v in pairs(env) do
        if type(k) == "string" and type(v) == "string" then by_upper[k:upper()] = { k, v } end
    end
    for _, name in ipairs(MSVC_FLAG_ENV_VARS) do
        local entry = by_upper[name]
        if entry then
            local tokens = {}
            for tok in entry[2]:gmatch("%S+") do tokens[#tokens + 1] = tok end
            local flag = M.pdb_debug_flag(tokens)
            if flag then
                out[#out + 1] = {
                    severity = severity, flag = flag, group = "environment",
                    sample = { entry[1] },
                }
            end
        end
    end
    return out
end

--- Environment-inventory declaration for the GNU-driver compilers on PATH
--- (headless §16.33, cmake §13 `compilers:path`), shared by every module that
--- builds C/C++ so the scan is probed once. It IS the kit detection
--- (`detect_async`), so a compiler it reports is exactly one a kit could be
--- built from: one result per compiler, id `cxx:<normalized C++ driver path>`,
--- or a single missing result.
--- @return loomworks.InventoryDeclaration
function M.health_declaration()
    local inv = require("loomworks.inventory")
    return {
        id = "compilers:path",
        category = "compilers",
        label = "gcc / clang",
        probe = function(_, done)
            M.detect_async(function(compilers)
                local results = {}
                for _, c in ipairs(compilers) do
                    results[#results + 1] = {
                        id = inv.path_id("cxx", c.path),
                        label = c.family == "gcc" and "GCC" or "Clang",
                        status = "found",
                        version = c.version,
                        path = c.path,
                    }
                end
                if #results == 0 then
                    results[1] = {
                        id = "compilers:path", label = "gcc / clang", status = "missing",
                        detail = "none on PATH",
                        hint = is_windows() and "install LLVM or MinGW-w64 and put it on PATH"
                            or "install gcc or clang (your package manager)",
                    }
                end
                done(results)
            end)
        end,
    }
end

--- Clear the detection cache. Called by modules' `invalidate_tools`. Also drops
--- the PATH executable index so a rescan re-reads `$PATH`.
function M.clear_cache()
    M._cached = nil
    M._path_index = nil
end

return M
