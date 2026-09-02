--- loomworks/modules/meson.lua — Meson build system module.
---
--- V1 scope:
--- * Detects meson projects (meson.build at project root)
--- * Default configurations: Debug, Release, RelWithDebInfo
---   (mapped to meson's buildtype=debug/release/debugoptimized)
--- * tasks(): `meson setup <dir> [--reconfigure]` + `meson compile -C <dir>`
--- * clean_tasks(): `meson compile -C <dir> --clean`
--- * parse_targets: `meson introspect <dir> --targets` (post-configure)
--- * get_options: `meson introspect <dir> --buildoptions` (post-configure)
--- * lsp_configs: emits a clangd entry using the build dir
---   (meson generates compile_commands.json automatically)
--- * Tools: keyed by compiler. Each detected C/C++ compiler produces
---   a distinct tool entry so profiles can pin which toolchain meson
---   uses (CC/CXX set at configure time, compiler bin dir prepended
---   to PATH for builds and tests).
---
--- Cross-compilation: user puts `machine_file` in the configuration's
--- type_config overrides; `tasks()` passes `--cross-file <path>` to setup.

local M = {}

local io_mod = require("loomworks.io")
local reserved_compiler = require("loomworks.reserved_compiler")
local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1

M.id = "meson"
M.api_version = 1
M.has_keyed_tools = true
M.has_options = true
M.languages = { "c++", "c" }

--- Map loomworks configuration name → meson buildtype.
--- Users who want something else can set `buildtype` in the config override.
local BUILDTYPE_BY_NAME = {
    Debug = "debug",
    Release = "release",
    RelWithDebInfo = "debugoptimized",
    MinSizeRel = "minsize",
}

-- ---------------------------------------------------------------------------
-- Detection + validation
-- ---------------------------------------------------------------------------

--- Detect whether a directory is a meson project.
--- @param abs_path string absolute directory path
--- @return { marker: string }|nil
function M.detect(abs_path)
    if uv.fs_stat(abs_path .. "/meson.build") then
        return { marker = "meson.build" }
    end
    return nil
end

--- Validate a meson project path.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return { valid: boolean, warnings: string[] }
function M.validate(path, config)
    local warnings = {}
    if not uv.fs_stat(path .. "/meson.build") then
        warnings[#warnings + 1] = "meson.build not found in " .. path
    end
    return { valid = true, warnings = warnings }
end

-- ---------------------------------------------------------------------------
-- Configuration discovery
-- ---------------------------------------------------------------------------

--- Return the default configurations for a meson project.
--- Fixed shape: Debug / Release / RelWithDebInfo. User can override or
--- add more via loomworks.json configurations block. Each default has
--- `variant = name` so it's concrete (buildable) — a config is abstract
--- when `module_config.variant` is nil (mixin-only).
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table<string, table>
function M.default_configurations(path, config)
    -- All defaults use the `variant:` prefix — these are compile-mode
    -- built-ins, same as cmake's Debug/Release/RelWithDebInfo. The
    -- `canonicalize` step in `info()` turns bare keys into
    -- `variant:Debug` etc.
    return {
        Debug          = { prefix = "variant", variant = "Debug",          buildtype = "debug" },
        Release        = { prefix = "variant", variant = "Release",        buildtype = "release" },
        RelWithDebInfo = { prefix = "variant", variant = "RelWithDebInfo", buildtype = "debugoptimized" },
    }
end

--- Normalize inherits to an array. Accepts string, array, or nil.
--- @param inherits string|string[]|nil
--- @return string[]
local function normalize_inherits(inherits)
    if not inherits then return {} end
    if type(inherits) == "string" then return { inherits } end
    return inherits
end

--- Resolve defaults + user overrides into a canonical-keyed dict.
---
--- Auto-gens from `defaults` become `variant:Debug` etc. via the
--- shared canonicalise step. User overrides from
--- `config.configurations` land as standalone user configs (bare
--- keys, no colon — `:` in user names is rejected at
--- `config.validate`), following the strict auto-gen vs user tier
--- separation: a user-declared "Debug" is NOT a silent override of
--- `variant:Debug`, it's its own config that typically inherits
--- from one.
---
--- Inheritance propagation: when a user config doesn't declare its
--- own `variant`/`buildtype`, walk the first base in its `inherits`
--- chain that does.
--- @param defaults table<string, table>
--- @param config table|nil type_config (may have `.configurations`)
--- @return table<string, table> canonical-keyed dict
function M.resolve_configurations(defaults, config)
    local Configuration = require("loomworks.configuration")
    local result = Configuration.canonicalize(
        defaults, config and config.configurations, M.id)

    -- Inheritance pass: propagate variant + buildtype from the
    -- first base that provides them, so a user config that only
    -- says `inherits = "variant:Debug"` ends up concrete.
    for _, cfg in pairs(result) do
        if cfg.is_user and cfg.inherits and not cfg.variant then
            local bases = normalize_inherits(cfg.inherits)
            for _, base_name in ipairs(bases) do
                local base = result[base_name]
                if base and base.variant then
                    -- Mark propagated values as derived so they are not
                    -- written back as if the user had declared them
                    -- (Configuration._derived).
                    cfg._derived = cfg._derived or {}
                    cfg.variant = base.variant
                    cfg._derived.variant = true
                    if not cfg.buildtype and base.buildtype then
                        cfg.buildtype = base.buildtype
                        cfg._derived.buildtype = true
                    end
                    break
                end
            end
        end
        -- A concrete config with an explicit variant but no buildtype maps its
        -- variant to the meson buildtype (variant values match BUILDTYPE_BY_NAME
        -- keys). Without this, buildtype resolution in M.tasks() falls back to
        -- the config NAME, so a user config named e.g. "Tracy" with variant
        -- "Release" would silently build as debug. Mark it derived so it is not
        -- written back as if the user had declared it (same as the inherits pass).
        if cfg.variant and not cfg.buildtype and BUILDTYPE_BY_NAME[cfg.variant] then
            cfg._derived = cfg._derived or {}
            cfg.buildtype = BUILDTYPE_BY_NAME[cfg.variant]
            cfg._derived.buildtype = true
        end
        -- Store normalised inherits array for downstream callers.
        if cfg.inherits and type(cfg.inherits) == "string" then
            cfg.inherits = { cfg.inherits }
        end
    end

    return result
end

--- Return module-level info for a project.
--- @param path string absolute project path
--- @param config table type_config from loomworks.json
--- @return table info
function M.info(path, config)
    local defaults = M.default_configurations(path, config)
    local configurations = M.resolve_configurations(defaults, config)
    return { configurations = configurations }
end

--- Tier prefix emitted for meson auto-gens (compile-mode variants).
--- Declared so the merge layer can canonicalise even when a caller
--- bypasses `info()` and reads `default_configurations` directly.
M.default_config_prefix = "variant"

--- Map a semantic variant type to a configuration name from available configs.
--- @param variant_type string "debug"|"release"|"release_debug"
--- @param available_configs string[] configuration names from info()
--- @return string|nil
function M.map_variant(variant_type, available_configs)
    local function find(name)
        for _, c in ipairs(available_configs) do
            if c == name then return c end
        end
        return nil
    end
    if variant_type == "debug" then
        return find("Debug") or available_configs[1]
    elseif variant_type == "release" then
        return find("Release") or available_configs[1]
    elseif variant_type == "release_debug" then
        return find("RelWithDebInfo") or find("Release") or available_configs[1]
    end
    return available_configs[1]
end

-- ---------------------------------------------------------------------------
-- Tool detection
-- ---------------------------------------------------------------------------

--- Ask `python` where it installs scripts (both system and --user),
--- look for a `meson` / `meson.exe` executable in those directories,
--- and print the path to the first one found.
---
--- Uses sysconfig.get_path('scripts', scheme) with both the default
--- system scheme and the per-user scheme ('nt_user' on Windows,
--- 'posix_user' elsewhere). The user scheme is what `pip install --user`
--- targets on Windows — e.g.
--- `C:\Users\X\AppData\Roaming\Python\Python313\Scripts`, which
--- `site.USER_BASE` alone doesn't reach.
---
--- Exit code 0 and a single line of stdout on success; non-zero on miss.
local PY_FIND_MESON = [[
import os,sys,sysconfig
ds=[sysconfig.get_path('scripts')]
try:
    ds.append(sysconfig.get_path('scripts','nt_user' if os.name=='nt' else os.name+'_user'))
except Exception:
    pass
for d in ds:
    for n in ('meson','meson.exe'):
        p=os.path.join(d,n)
        if os.path.isfile(p):
            print(p); sys.exit(0)
sys.exit(1)
]]

--- Locate meson as a command prefix array.
--- Tries, in order:
---   1. `meson` on PATH (the standard install)
---   2. A `meson` / `meson.exe` script inside a Python interpreter's
---      system or user Scripts directory (pip install, with or without
---      --user). Canonical install channel, especially on Windows.
--- Returns `{ meson_path }` in both cases — meson scripts are
--- self-contained and need no wrapper args. Returns nil when neither
--- works. Per the graceful-degradation policy, callers should refuse
--- rather than guess further.
--- @return string[]|nil
local function find_meson()
    local p = vim.fn.exepath("meson")
    if p ~= "" then return { p } end

    for _, py in ipairs({ "python", "python3", "py" }) do
        local pp = vim.fn.exepath(py)
        if pp ~= "" then
            local out = vim.fn.system({ pp, "-c", PY_FIND_MESON })
            if vim.v.shell_error == 0 then
                local path = vim.trim(out or "")
                if path ~= "" and uv.fs_stat(path) then
                    return { path }
                end
            end
        end
    end
    return nil
end

--- Detect available tools (sync). Meson itself is a script — the
--- variable that actually matters for reproducible builds is the
--- compiler. Returns one entry per detected C/C++ compiler so the
--- profile UI lets the user pick a specific toolchain instead of
--- deferring to whatever meson auto-probes at configure time.
---
--- Returns empty when either meson or a compiler isn't available; per
--- the degradation policy we surface a missing toolchain rather than
--- silently guessing.
--- @return { tool_data: table }[]
function M.detect_tools()
    local meson = find_meson()
    if not meson then return {} end

    local tools = {}

    -- GNU-driver compilers (gcc / clang) from PATH.
    for _, c in ipairs(require("loomworks.cpp_compilers").detect()) do
        tools[#tools + 1] = {
            tool_data = {
                meson = meson,
                compiler_id = c.id,
                compiler_display = c.display,
                compiler_path = c.path,
                compiler_c_path = c.c_path,
                compiler_bin_dir = c.bin_dir,
                compiler_family = c.family,
                compiler_version = c.version,
                clangd_path = c.clangd_path,
            },
        }
    end

    -- MSVC (cl.exe) and clang-cl on Windows. These take MSVC-style flags
    -- (/W…, /bigobj, /D…) that GNU-driver clang/gcc reject, so projects that
    -- assume Windows == MSVC need one of them. Their environment (INCLUDE / LIB
    -- / PATH-to-cl + the Windows SDK) is layered from vcvarsall at build time
    -- (see compose_task_env).
    if vim.fn.has("win32") == 1 then
        local ok, msvc = pcall(require, "loomworks.msvc")
        if ok then
            local installs = msvc.detect()
            for _, inst in ipairs(installs) do
                tools[#tools + 1] = {
                    tool_data = {
                        meson = meson,
                        compiler_id = inst.id,
                        compiler_display = inst.display,
                        compiler_path = inst.vcvarsall, -- identity for tools_match
                        compiler_family = "msvc",
                        vcvarsall = inst.vcvarsall,
                        arch = inst.arch,
                        -- cc/cxx default to "cl" (resolved on the vcvars PATH)
                    },
                }
            end
            -- clang-cl needs an MSVC install for the SDK/libs, so there's one
            -- clang-cl tool per install (VS-bundled clang-cl preferred,
            -- standalone/PATH as fallback). Several installs may fall back to
            -- the SAME standalone driver; the per-install compiler_id — and the
            -- vcvarsall in tools_match — keep them distinct tools (same driver,
            -- different vcvars env).
            for _, inst in ipairs(installs) do
                local clang_cl = msvc.clang_cl_for(inst)
                if clang_cl then
                    tools[#tools + 1] = {
                        tool_data = {
                            meson = meson,
                            compiler_id = "clang-cl-" .. clang_cl.version
                                .. "-" .. inst.vs_major .. "-" .. inst.product:lower(),
                            compiler_display = "clang-cl " .. clang_cl.version
                                .. " (" .. inst.display .. ")",
                            compiler_path = clang_cl.path,
                            compiler_family = "clang-cl",
                            cc = clang_cl.path,
                            cxx = clang_cl.path,
                            clangd_path = clang_cl.clangd_path,
                            vcvarsall = inst.vcvarsall,
                            arch = inst.arch,
                        },
                    }
                end
            end
        end
    end

    return tools
end

--- Detect available tools (async variant for consistency with interface).
--- @param callback fun(tools: { tool_data: table }[])
function M.detect_tools_async(callback)
    callback(M.detect_tools())
end

--- Clear the shared compiler detection cache so the next
--- `detect_tools` call re-scans PATH. Called by core's rescan flow.
function M.invalidate_tools()
    require("loomworks.cpp_compilers").clear_cache()
    local ok, msvc = pcall(require, "loomworks.msvc")
    if ok then msvc.clear_cache() end
end

--- Cache key suffix from tool_data. The compiler_id pins the
--- toolchain identity so cache entries survive across meson binary
--- upgrades but get invalidated when the user picks a different
--- compiler.
--- @param tool_data table
--- @return string|nil
function M.tool_key(tool_data)
    return tool_data and tool_data.compiler_id or nil
end

--- Display label for tool. Shows the compiler identity (that's what
--- the user is actually choosing between). The resolved meson path
--- lives in tool_data.meson[1] for users who want to inspect it.
--- @param tool_data table
--- @return string|nil
function M.tool_label(tool_data)
    if not tool_data then return nil end
    if tool_data.compiler_display then return tool_data.compiler_display end
    -- Non-keyed cache entries have no compiler_display; fall back to "meson".
    local cmd = tool_data.meson
    if type(cmd) == "table" and cmd[1] then return "meson" end
    if type(cmd) == "string" and cmd ~= "" then return "meson" end
    return nil
end

--- Compare two meson tool_data objects by compiler identity. Two
--- tools are the same iff they point at the same compiler binary;
--- meson binary churn doesn't change toolchain identity.
---
--- The compiler path is the primary identity, but clang-cl tools paired to
--- different MSVC installs can share the SAME standalone driver while carrying
--- different vcvars environments — disambiguate on vcvarsall so they stay
--- distinct tools. (GNU-driver tools have no vcvarsall; cl.exe tools set both
--- fields to the same vcvarsall, so neither is affected.)
--- @param a table
--- @param b table
--- @return boolean
function M.tools_match(a, b)
    if a == nil and b == nil then return true end
    if a == nil or b == nil then return false end
    return (a.compiler_path or "") == (b.compiler_path or "")
        and (a.vcvarsall or "") == (b.vcvarsall or "")
end

--- Resolve the build directory for a meson configuration:
--- `.nvim/build/<project>/<compiler>/<config>`.
---
--- The compiler segment gives each toolchain its own build dir — meson bakes
--- the compiler into a configured build tree (switching compilers on the same
--- dir errors), so a project built with gcc, clang, and MSVC needs three
--- separate dirs. Every component is sanitized like cmake.resolve_build_dir:
--- canonical config names contain ':' (variant:Debug) and the colon — plus
--- < > " | ? * — is invalid in a Windows path, which otherwise fails
--- `meson setup` with "WinError 267". Defining this on the module (rather than
--- in the core default) keeps the core formula opaque for never-built / unknown
--- modules while giving meson filesystem-safe, compiler-scoped paths.
--- @param project_name string
--- @param config_name string|nil canonical configuration name
--- @param config_info table|nil unused (meson has no preset binary_dir)
--- @param workspace_root string
--- @param tool_data table|nil primary tool data
--- @return string absolute build directory
function M.resolve_build_dir(project_name, config_name, config_info, workspace_root, tool_data)
    local function san(s) return (tostring(s):gsub('[:<>"|?*]', "_")) end
    local base = workspace_root .. "/.nvim/build/" .. san(project_name)
    local segment
    if tool_data and tool_data._effective_keys and #tool_data._effective_keys > 1 then
        segment = table.concat(tool_data._effective_keys, "+")
    elseif tool_data and (tool_data.compiler_id or tool_data.id) then
        segment = tool_data.compiler_id or tool_data.id
    end
    local config_part = san(config_name or "default")
    if segment then
        return base .. "/" .. san(segment) .. "/" .. config_part
    end
    return base .. "/" .. config_part
end

-- ---------------------------------------------------------------------------
-- Task generation
-- ---------------------------------------------------------------------------

--- Resolve the meson command prefix from tool_data (array form).
--- Falls through to a fresh find_meson if tool_data is empty. Errors
--- out if neither form is available — per degradation policy, we
--- refuse rather than silently fail later.
--- Accepts legacy string form for backwards compatibility with older caches.
--- @param tool_data table|nil
--- @return string[] command prefix (copy; safe to mutate)
local function resolve_meson(tool_data)
    local cmd = tool_data and tool_data.meson
    if type(cmd) == "table" and cmd[1] then
        return vim.list_extend({}, cmd)
    end
    if type(cmd) == "string" and cmd ~= "" then
        return { cmd }
    end
    local sys = find_meson()
    if sys then return vim.list_extend({}, sys) end
    error("meson: no meson binary available (not on PATH, and no python has it installed via pip)")
end

--- Expand ${ENV_VAR} / ${var} patterns in a string.
--- Used for option values, machine files, etc.
--- @param s string
--- @param ctx? table extra vars (workspace_root, project_path, ...)
--- @return string
local function expand_str(s, ctx)
    return (s:gsub("%${([^}]+)}", function(var)
        if ctx and ctx[var] ~= nil then return tostring(ctx[var]) end
        return os.getenv(var) or "${" .. var .. "}"
    end))
end

--- Build the list of `-Dkey=value` args from user options + inherited.
--- Mirrors cmake.resolve_options semantics (project-wide + inherited + config-specific).
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return string[] list of `-Dkey=value` args
local function build_option_args(project, active_config)
    local args = {}
    local type_config = project.type_config or {}
    local project_opts = type_config.options or {}
    local configs = project.configurations or {}
    local active = configs[active_config] or {}

    local opt_ctx = {
        workspace_root = project.workspace_root,
        project_path = project.path or project.name,
    }

    -- Project-wide first, then the inheritance chain bases-first
    -- left-to-right, then the config's own — later values win. Without the
    -- chain a mixin that exists purely to carry options contributes nothing,
    -- and the build silently omits the options the config named.
    local merged = {}
    for k, v in pairs(project_opts) do merged[k] = v end
    local function apply_inherited(name, visited)
        if visited[name] then return end -- circular guard
        visited[name] = true
        local cfg = configs[name]
        if not cfg then return end
        for _, base_name in ipairs(normalize_inherits(cfg.inherits)) do
            apply_inherited(base_name, visited)
        end
        if cfg.options then
            for k, v in pairs(cfg.options) do merged[k] = v end
        end
    end
    apply_inherited(active_config, {})
    for k, v in pairs(merged) do
        args[#args + 1] = "-D" .. k .. "=" .. expand_str(tostring(v), opt_ctx)
    end
    return args
end

--- Lowercase a trailing `.EXE`. meson matches a compiler's basename against
--- `clang-cl.exe` case-sensitively, and `vim.fn.exepath` reports whatever
--- casing PATHEXT carries — see `msvc.normalize_exe` for the full story. Kept
--- local so composing an environment does not depend on the msvc module
--- loading.
local function normalize_exe(p)
    if type(p) ~= "string" then return p end
    return (p:gsub("%.[eE][xX][eE]$", ".exe"))
end

--- Compose the task env so it pins the chosen compiler.
---
--- Configure step: meson reads CC/CXX when it first probes compilers.
--- If we don't set them, meson picks whatever is first on PATH and
--- bakes that identity into the build dir — defeating the point of
--- letting the user choose a toolchain.
---
--- Build / clean / test steps: on Windows the compiler's bin dir
--- must be on PATH so the generated binaries can find their runtime
--- DLLs (libstdc++-6.dll, libgcc_s_seh-1.dll, vcruntime140.dll, ...).
--- Without this the binary hangs in the loader with
--- STATUS_ENTRYPOINT_NOT_FOUND when a wrong-version DLL is picked up
--- from elsewhere on PATH.
---
--- Base env from the project (currently `env = tool_data.env` which
--- is mostly empty) is preserved; CC/CXX/PATH keys win.
--- @param base_env table<string, string>
--- @param tool_data table|nil
--- @return table<string, string> env, string[] stripped reserved driver vars
--- Exported so the meson TEST unit composes the identical environment: its
--- native runner rebuilds, so it needs the same toolchain env a build
--- gets (notably MSVC's vcvars) or the rebuild cannot find the compiler.
---
--- The tool owns the compiler (spec §15 / meson.md §5): reserved
--- compiler-driver vars (CC/CXX/…) from the config-sourced `base_env` are
--- stripped BEFORE the tool pins its own CC/CXX, so a hand-edited override
--- never shadows the tool's compiler. Stripped names are returned for a
--- diagnostic (the test unit ignores the second value).
local function compose_task_env(base_env, tool_data)
    local env = {}
    local stripped = {}
    for k, v in pairs(base_env or {}) do
        if reserved_compiler.is_reserved_env(k) then
            stripped[#stripped + 1] = k
        else
            env[k] = v
        end
    end
    table.sort(stripped)
    if type(tool_data) ~= "table" then return env, stripped end

    -- MSVC / clang-cl: layer the environment vcvarsall establishes (INCLUDE /
    -- LIB / LIBPATH / PATH-to-cl + the Windows SDK) so cl / clang-cl and the
    -- linker resolve. The host merges this over the inherited environment
    -- before spawning, so vars we don't set (e.g. %APPDATA%) are preserved.
    if tool_data.vcvarsall then
        local ok, msvc = pcall(require, "loomworks.msvc")
        local venv = ok and msvc.vcvars_env(tool_data.vcvarsall, tool_data.arch or "x64") or nil
        if venv then
            for k, v in pairs(venv) do
                -- Collapse to a single PATH key (Windows env is case-insensitive).
                if k:upper() == "PATH" then env.PATH = v else env[k] = v end
            end
            env.Path = nil
        end
        -- cl serves both C and C++; clang-cl gets its explicit path. Normalized
        -- here as well as at detection because the path is persisted in the
        -- cache: a profile created earlier still carries `clang-cl.EXE`, whose
        -- casing stops meson recognising the MSVC driver.
        env.CC = normalize_exe(tool_data.cc or "cl")
        env.CXX = normalize_exe(tool_data.cxx or "cl")
        return env, stripped
    end

    if tool_data.compiler_c_path and env.CC == nil then
        env.CC = tool_data.compiler_c_path
    end
    if tool_data.compiler_path and env.CXX == nil then
        env.CXX = tool_data.compiler_path
    end

    local bin_dir = tool_data.compiler_bin_dir
    if bin_dir and bin_dir ~= "" then
        local is_win = vim.fn.has("win32") == 1
        local sep = is_win and ";" or ":"
        local existing = env.PATH or env.Path or os.getenv("PATH") or ""
        env.PATH = bin_dir .. (existing ~= "" and (sep .. existing) or "")
        if is_win then env.Path = nil end
    end
    return env, stripped
end
M.compose_task_env = compose_task_env  -- shared with the meson test unit

--- Return overseer task templates for a project.
--- Produces:
---   * configure: `meson setup <build_dir> --buildtype=X [--cross-file=...] -Dkey=value ...`
---               or `meson setup <build_dir> --reconfigure ...` if already set up
---   * build:     `meson compile -C <build_dir>`
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local config_info = project.configurations and project.configurations[active_config] or nil
    local env, stripped_env = compose_task_env(project.env or {}, project.tool_data)
    local meson_prefix = resolve_meson(project.tool_data)

    -- Build dir: core provides cached_build_dir (via M.resolve_build_dir) when a
    -- cache entry exists, preserving rename paths. Fall back to the same formula
    -- so the compiler-scoped, sanitized layout is consistent either way.
    local build_dir = project.cached_build_dir
        or M.resolve_build_dir(project.name, active_config, config_info,
            project.workspace_root, project.tool_data)

    -- buildtype from config or name mapping
    local buildtype = (config_info and config_info.buildtype)
        or BUILDTYPE_BY_NAME[active_config]
        or "debug"

    -- Build the setup command: <meson_prefix> setup <dir> --buildtype=X [...]
    local configure_cmd = vim.list_extend({}, meson_prefix)
    local insert_at = #configure_cmd  -- index of last prefix token (for --reconfigure insertion)
    configure_cmd[#configure_cmd + 1] = "setup"
    configure_cmd[#configure_cmd + 1] = build_dir
    configure_cmd[#configure_cmd + 1] = "--buildtype=" .. buildtype

    -- Optional cross-compilation machine file
    if config_info and config_info.machine_file then
        local mf = expand_str(tostring(config_info.machine_file), {
            workspace_root = project.workspace_root,
            project_path = project.path or project.name,
        })
        configure_cmd[#configure_cmd + 1] = "--cross-file=" .. mf
    end

    -- User -D options (project-wide + config-specific)
    for _, opt in ipairs(build_option_args(project, active_config)) do
        configure_cmd[#configure_cmd + 1] = opt
    end

    -- Reconfigure if the build dir already exists (idempotent setup).
    -- Insert --reconfigure right after the `setup` subcommand so it works
    -- for both plain meson and `python -m mesonbuild` invocations.
    local reconfigure_cmd = vim.list_extend({}, configure_cmd)
    table.insert(reconfigure_cmd, insert_at + 2, "--reconfigure")

    local configuration_key = project.configuration_key or active_config
    local cached_tool_data = project.tool_data

    local tasks = {}

    tasks[#tasks + 1] = {
        name = project.name .. ": configure",
        builder = function()
            -- Pick reconfigure or first-time setup based on whether the dir exists
            local uv2 = vim.uv or vim.loop
            local cmd = (uv2.fs_stat(build_dir .. "/meson-info")
                    and reconfigure_cmd) or configure_cmd
            vim.fn.mkdir(build_dir, "p")
            return { cmd = cmd, cwd = abs_path, env = env }
        end,
        loomworks = {
            project_key = project.name,
            action = "configure",
            configuration_key = configuration_key,
            build_dir = build_dir,
            tool_data = cached_tool_data,
            -- Reserved compiler-driver env vars dropped from this build
            -- (hand-edited file); present only when non-empty. The tool's
            -- pinned CC/CXX is used regardless.
            stripped_compiler_keys = (#stripped_env > 0)
                and { env = stripped_env } or nil,
            module_info = {
                buildtype = buildtype,
                source_dir = project.path,
            },
        },
    }

    tasks[#tasks + 1] = {
        name = project.name .. ": build " .. active_config,
        builder = function()
            local cmd = vim.list_extend({}, meson_prefix)
            cmd[#cmd + 1] = "compile"
            cmd[#cmd + 1] = "-C"
            cmd[#cmd + 1] = build_dir
            return { cmd = cmd, cwd = abs_path, env = env }
        end,
        loomworks = {
            project_key = project.name,
            action = "build",
            configuration_key = configuration_key,
            build_dir = build_dir,
            tool_data = cached_tool_data,
        },
    }

    return tasks
end

--- Return overseer task templates for cleaning build artifacts.
--- Uses `meson compile -C <dir> --clean` which delegates to the underlying
--- backend (ninja by default). The build dir itself is preserved.
--- @param project loomworks.ModuleContext
--- @param active_config string
--- @return table[] tasks
function M.clean_tasks(project, active_config)
    local abs_path = project.workspace_root .. "/" .. project.path
    local env = compose_task_env(project.env or {}, project.tool_data)
    local meson_prefix = resolve_meson(project.tool_data)
    local build_dir = project.cached_build_dir
        or (project.workspace_root .. "/.nvim/build/" .. project.name .. "/" .. active_config)
    local configuration_key = project.configuration_key or active_config

    return {
        {
            name = project.name .. ": clean",
            builder = function()
                local cmd = vim.list_extend({}, meson_prefix)
                cmd[#cmd + 1] = "compile"
                cmd[#cmd + 1] = "-C"
                cmd[#cmd + 1] = build_dir
                cmd[#cmd + 1] = "--clean"
                return { cmd = cmd, cwd = abs_path, env = env }
            end,
            loomworks = {
                project_key = project.name,
                action = "clean",
                configuration_key = configuration_key,
                build_dir = build_dir,
            },
        },
    }
end

--- Return progress parser tool name.
--- Meson compile uses ninja by default, which has a recognizable progress format.
--- @return string
function M.progress_parser()
    return "ninja"
end

-- ---------------------------------------------------------------------------
-- Introspection: parse_targets + get_options
-- ---------------------------------------------------------------------------

--- Run `meson introspect <subcommand>` and parse the JSON reply.
--- Returns nil on failure.
--- @param meson_prefix string[] resolved command prefix (e.g. {"meson"} or {"python","-m","mesonbuild"})
--- @param build_dir string
--- @param subcommand string e.g. "--targets", "--buildoptions"
--- @return any|nil
local function run_introspect(meson_prefix, build_dir, subcommand)
    local cmd = vim.list_extend({}, meson_prefix)
    cmd[#cmd + 1] = "introspect"
    cmd[#cmd + 1] = build_dir
    cmd[#cmd + 1] = subcommand
    local out = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then return nil end
    local ok, data = pcall(vim.json.decode, out)
    if not ok then return nil end
    return data
end

--- Map meson target type string to the loomworks target kind.
--- Returns nil for target kinds we don't surface (custom, run targets, jars).
--- @param meson_type string
--- @return string|nil
local function target_kind(meson_type)
    if meson_type == "executable" then return "executable" end
    if meson_type == "static library" then return "static_library" end
    if meson_type == "shared library" then return "shared_library" end
    if meson_type == "shared module" then return "module_library" end
    return nil
end

--- Extract target list via `meson introspect --targets`.
--- @param ctx { build_dir?: string, project_path?: string }
--- @return table<string, { type: string, artifact?: string }>|nil
function M.parse_targets(ctx)
    local build_dir = ctx and ctx.build_dir
    if not build_dir then return nil end
    -- Only a configured build tree has targets to introspect. Every profile has
    -- a computed build-dir path before its first build, so guard on the
    -- `meson-info/` that `meson setup` creates — otherwise we spawn meson (and,
    -- via find_meson, python) on every workspace load just to have introspect
    -- fail on a directory that isn't there. That was ~2s per CLI invocation.
    local uv2 = vim.uv or vim.loop
    if not uv2.fs_stat(build_dir .. "/meson-info") then return nil end
    local meson_prefix = find_meson()
    if not meson_prefix then return nil end

    local raw = run_introspect(meson_prefix, build_dir, "--targets")
    if type(raw) ~= "table" then return nil end

    local normalize = build_dir:gsub("\\", "/")
    if normalize:sub(-1) ~= "/" then normalize = normalize .. "/" end

    local result = {}
    for _, t in ipairs(raw) do
        local kind = target_kind(t.type)
        if kind and t.name and t.build_by_default ~= false then
            local entry = { type = kind }
            local artifacts = t.filename
            if type(artifacts) == "table" and artifacts[1] then
                local abs = tostring(artifacts[1]):gsub("\\", "/")
                -- Strip build_dir prefix if present so artifact is relative
                if abs:sub(1, #normalize) == normalize then
                    entry.artifact = abs:sub(#normalize + 1)
                else
                    entry.artifact = abs
                end
            end

            -- Flatten `target_sources[*].sources` into a single list of
            -- absolute source paths. Callers (MesonTestUnit jump-to-test,
            -- clangd lookups) want the whole compile unit list for the
            -- target without caring about per-language grouping.
            local sources = {}
            if type(t.target_sources) == "table" then
                for _, block in ipairs(t.target_sources) do
                    if type(block.sources) == "table" then
                        for _, s in ipairs(block.sources) do
                            if type(s) == "string" and s ~= "" then
                                sources[#sources + 1] = s
                            end
                        end
                    end
                end
            end
            if #sources > 0 then entry.sources = sources end

            result[t.name] = entry
        end
    end
    return next(result) and result or nil
end

--- Async companion for parse_targets — yields to the event loop.
--- @param ctx table
--- @param callback fun(targets: table|nil)
function M.parse_targets_async(ctx, callback)
    vim.schedule(function() callback(M.parse_targets(ctx)) end)
end

--- Map meson option type to loomworks option value_type.
--- @param meson_type string
--- @return string
local function option_value_type(meson_type)
    if meson_type == "boolean" then return "bool" end
    if meson_type == "string" then return "string" end
    if meson_type == "combo" then return "string" end
    if meson_type == "integer" then return "string" end
    if meson_type == "array" then return "string" end
    return "string"
end

--- Toolchain runtime directories for launching built executables: the
--- pinned compiler's bin dir holds the C++ runtime DLLs (libstdc++-6.dll,
--- libgcc_s_seh-1.dll, libwinpthread-1.dll, …). Core adds the build tree's own
--- shared-library dirs generically, so only the toolchain dir is needed here.
--- @param ctx { tool_data?: table }
--- @return string[]|nil
function M.runtime_path(ctx)
    local td = ctx and ctx.tool_data
    if type(td) == "table" and type(td.compiler_bin_dir) == "string"
        and td.compiler_bin_dir ~= "" then
        return { td.compiler_bin_dir }
    end
    return nil
end

--- Extract build options via `meson introspect --buildoptions`.
--- Groups by `section` (core, base, compiler, directory, user, test).
--- @param build_dir string
--- @param config table|nil unused
--- @return table|nil options tree
function M.get_options(build_dir, config)
    if not build_dir then return nil end
    local meson_prefix = find_meson()
    if not meson_prefix then return nil end

    local raw = run_introspect(meson_prefix, build_dir, "--buildoptions")
    if type(raw) ~= "table" then return nil end

    local SECTION_ORDER = { "user", "core", "base", "compiler", "directory", "test" }
    local SECTION_LABEL = {
        user = "User options",
        core = "Core options",
        base = "Base options",
        compiler = "Compiler options",
        directory = "Directories",
        test = "Test options",
    }

    local buckets = {}
    for _, opt in ipairs(raw) do
        if opt.name then
            local section = opt.section or "user"
            buckets[section] = buckets[section] or {}
            local value = opt.value
            if type(value) == "table" then
                value = table.concat(value, ",")
            elseif value ~= nil then
                value = tostring(value)
            end
            local entry = {
                key = opt.name,
                value = value or "",
                value_type = option_value_type(opt.type),
                helpstring = opt.description or nil,
            }
            if opt.type == "combo" and type(opt.choices) == "table" then
                entry.choices = opt.choices
            end
            buckets[section][#buckets[section] + 1] = entry
        end
    end

    local result = {}
    for _, section in ipairs(SECTION_ORDER) do
        local entries = buckets[section]
        if entries then
            table.sort(entries, function(a, b) return a.key < b.key end)
            result[#result + 1] = {
                label = SECTION_LABEL[section] or section,
                children = entries,
            }
            buckets[section] = nil
        end
    end
    -- Any unknown sections append last
    for section, entries in pairs(buckets) do
        table.sort(entries, function(a, b) return a.key < b.key end)
        result[#result + 1] = {
            label = SECTION_LABEL[section] or section,
            children = entries,
        }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Test integration
-- ---------------------------------------------------------------------------

--- Create a MesonTestUnit for test discovery and execution.
--- Returns nil when the ConfigUnit has no resolved build directory
--- yet — test discovery needs a configured build dir.
--- @param config_unit loomworks.ConfigUnit
--- @return loomworks.MesonTestUnit|nil
function M.create_test_unit(config_unit)
    if not config_unit:build_dir() then return nil end
    local MesonTestUnit = require("loomworks.test_units.meson")
    return MesonTestUnit.new(config_unit)
end

-- ---------------------------------------------------------------------------
-- LSP integration
-- ---------------------------------------------------------------------------

--- Return LSP configs for this project.
--- Emits a single clangd entry rooted at the project source path. Meson
--- generates compile_commands.json at the build dir root automatically.
--- @param project loomworks.Project
--- @return table[]
function M.lsp_configs(project)
    local ws = project._workspace
    if not ws then return {} end
    local root_dir = ws.root .. "/" .. (project.path or project.key)

    -- Prefer the active profile's ProfileProject (robust in multi-tool profiles
    -- where project.cached's variant+tool_key match can miss).
    local build_dir = nil
    local active_profile = ws.get_active_profile and ws:get_active_profile()
    if active_profile then
        local pp = active_profile:project(project.key)
        if pp then build_dir = pp:build_dir() end
    end
    if not build_dir and project.cached then
        build_dir = project.cached.build_dir
    end

    -- Binary override: type_config.clangd wins, else tool_data.clangd_path
    -- (set by the compilers detector when a matching clangd lives next to
    -- the compiler — common for SDK toolchains).
    local tc = project.type_config or {}
    local binary = nil
    local binary_required = false
    if type(tc.clangd) == "string" and tc.clangd ~= "" then
        binary = tc.clangd
    elseif project.tool_data and project.tool_data.clangd_path then
        binary = project.tool_data.clangd_path
        binary_required = project.tool_data.clangd_required == true
    end

    return {
        {
            server = "clangd",
            binary = binary,
            binary_required = binary_required,
            compile_commands_dir = build_dir,
            root_dir = root_dir,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Staleness detection
-- ---------------------------------------------------------------------------

--- Check if project files have changed since last configure.
--- @param path string absolute project path
--- @param config table type_config
--- @param cached table<string, table> cached configurations
--- @return { needs_refresh: boolean, reasons: string[], notes: string[] }
function M.inspect(path, config, cached)
    local reasons = {}
    local check_files = {
        { file = "meson.build", label = "meson.build" },
        { file = "meson.options", label = "meson.options" },
        { file = "meson_options.txt", label = "meson_options.txt" },
    }

    for _, cached_config in pairs(cached) do
        if cached_config.last_configured then
            local configured_time = cached_config.last_configured
            for _, cf in ipairs(check_files) do
                local stat = uv.fs_stat(path .. "/" .. cf.file)
                if stat then
                    local t = os.date("!%Y-%m-%dT%H:%M:%SZ", stat.mtime.sec)
                    if t > configured_time then
                        reasons[#reasons + 1] = cf.label .. " modified since last configure"
                    end
                end
            end
            if #reasons > 0 then break end
        end
    end

    return { needs_refresh = #reasons > 0, reasons = reasons, notes = {} }
end

return M
