--- loomworks/inventory.lua — environment inventory framework (headless §16.33).
---
--- `lw health` answers "is this machine ready?" with an inventory of every
--- external thing loomworks knows how to use. Core owns NO knowledge of any
--- particular tool: the inventory is the union of **declarations** contributed
--- by
---   * modules            — `impl.health_inventory(ctx)` (§8.4);
---   * inventory companions — `lua/loomworks/integrations/inventory/*.lua`, the
---     host-neutral half of a language-server / debug-adapter integration
---     (§9.3, §8.9.6), each a table with `health_inventory(ctx)`;
---   * SDK providers      — core lists `detect_all()` + the installations
---     profiles pin, plus the provider's optional `health_inventory(ctx)`
---     (§10.1);
---   * core itself        — the running `lw`, the compiler-cache launchers and
---     the plugin registry (incl. rejected plugins + reason).
---
--- A declaration is `{ id, category, label, probe }`. Declarations sharing an
--- `id` are probed once and listed once (first declaration wins). `probe(ctx,
--- done)` calls `done(result | result[])`; probes run concurrently, each under
--- `PROBE_TIMEOUT_MS`, and a probe that errors or times out yields `unknown`.
---
--- Probing happens ONLY on an explicit health run (`probe_tier`). Its raw
--- results are cached as the health cache's inventory tier (`health_cache.lua`)
--- under an environment key (`environment_key`); the passive `N suggestions`
--- count re-derives the required split from the current workspace
--- (`requirements`, pure) against the cached results and never probes.

local M = {}

local uv = vim.uv or vim.loop

--- Report order of the fixed, core-owned categories. An unrecognized category
--- renders under "other".
--- @type string[]
M.CATEGORIES = {
    "build tools", "compilers", "compiler caches", "language servers",
    "debug adapters", "SDKs", "plugins", "lw", "other",
}

local CATEGORY_RANK = {}
for i, c in ipairs(M.CATEGORIES) do CATEGORY_RANK[c] = i end

--- Per-probe timeout (ms). A probe still pending after it reads `unknown`.
M.PROBE_TIMEOUT_MS = 5000

--- Version of the `lw health --json` document.
M.JSON_SCHEMA = 1

--- @class loomworks.InventoryResult
--- @field id string stable, opaque identity (e.g. `exe:cmake`, `cxx:<path>`)
--- @field label string display name
--- @field status "found"|"missing"|"unknown"
--- @field version? string
--- @field path? string
--- @field detail? string
--- @field hint? string one-line install remedy / help pointer
--- @field category? string filled in from the declaration
--- @field decl? string id of the declaration that produced it

--- @class loomworks.InventoryDeclaration
--- @field id string
--- @field category string one of `M.CATEGORIES`
--- @field label string
--- @field probe fun(ctx: loomworks.InventoryContext, done: fun(res: loomworks.InventoryResult|loomworks.InventoryResult[]))

--- @class loomworks.InventoryRequirement
--- @field id string inventory id the project needs
--- @field label string display when no result carries `id`
--- @field hint? string remedy when missing and no result carries one
--- @field via? string id of the enumerating declaration that would produce `id`
--- @field required_by string[] profile/project names needing it (filled by core)

--- @class loomworks.InventoryContext
--- @field platform "windows"|"macos"|"linux"
--- @field is_windows boolean
--- @field lookup fun(name: string): string|nil executable-search-path lookup
--- @field run fun(argv: string[], cb: fun(res: { code: integer, stdout: string, stderr: string }))
--- @field read_file fun(path: string): string|nil
--- @field exists fun(path: string): boolean
--- @field getenv fun(name: string): string|nil
--- @field timeout_ms integer
--- @field workspace loomworks.Workspace|nil
--- @field stdpath_data string|false|nil the editor's data dir inside Neovim (false/nil: derive headlessly)

-- ---------------------------------------------------------------------------
-- Small shared helpers
-- ---------------------------------------------------------------------------

--- Whether the host is Windows.
--- @return boolean
local function is_windows()
    return vim.fn.has("win32") == 1
end

--- Host platform name.
--- @return "windows"|"macos"|"linux"
function M.platform()
    if is_windows() then return "windows" end
    local ok, uname = pcall(function() return uv.os_uname().sysname end)
    if ok and type(uname) == "string" and uname:lower():find("darwin") then return "macos" end
    return "linux"
end

--- Normalize a path for use inside an inventory id: forward slashes, and
--- lower-cased on Windows (case-insensitive filesystem), so an id derived from a
--- recorded tool path matches the one a scan produced.
--- @param p string
--- @param win? boolean override the host check (tests)
--- @return string
function M.norm_path(p, win)
    p = tostring(p or ""):gsub("\\", "/")
    if win == nil then win = is_windows() end
    if win then p = p:lower() end
    return p
end

--- `<prefix>:<normalized path>` — the id of a path-identified installation.
--- @param prefix string
--- @param p string
--- @return string
function M.path_id(prefix, p)
    return prefix .. ":" .. M.norm_path(p)
end

--- First dotted version in `s` (`3.30.2`, `v20.11.0` → `20.11.0`), or nil.
--- @param s string|nil
--- @return string|nil
function M.parse_version(s)
    if type(s) ~= "string" then return nil end
    return s:match("(%d+%.%d+%.%d+)") or s:match("(%d+%.%d+)")
end

-- ---------------------------------------------------------------------------
-- Context
-- ---------------------------------------------------------------------------

--- Run `argv` asynchronously with a timeout; `cb` receives `{ code, stdout,
--- stderr }` (code 127 when the spawn itself failed). A Windows batch script
--- (`.cmd`/`.bat`, e.g. npm) runs through `cmd /d /c`, which CreateProcess
--- needs. The callback may run in a fast-event context: it must only record.
--- @param argv string[]
--- @param timeout_ms integer
--- @param cb fun(res: { code: integer, stdout: string, stderr: string })
local function default_run(argv, timeout_ms, cb)
    local cmd = argv
    if is_windows() and type(argv[1]) == "string" and argv[1]:lower():match("%.[cb][ma][dt]$") then
        cmd = { "cmd", "/d", "/c", (argv[1]:gsub("/", "\\")) }
        for i = 2, #argv do cmd[#cmd + 1] = argv[i] end
    end
    local ok, err = pcall(vim.system, cmd, { text = true, timeout = timeout_ms }, function(res)
        cb({ code = res.code or -1, stdout = res.stdout or "", stderr = res.stderr or "" })
    end)
    if not ok then cb({ code = 127, stdout = "", stderr = tostring(err) }) end
end

--- Read a whole file, or nil.
--- @param path string
--- @return string|nil
local function default_read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Build the probe context. `overrides` replaces any field (tests inject
--- `lookup`, `run`, `read_file`, `exists`, `getenv`, `platform`).
--- @param workspace loomworks.Workspace|nil
--- @param overrides? table
--- @return loomworks.InventoryContext
function M.context(workspace, overrides)
    overrides = overrides or {}
    local timeout = overrides.timeout_ms or M.PROBE_TIMEOUT_MS
    local ctx = {
        platform = M.platform(),
        lookup = function(name) return require("loomworks.cpp_compilers").lookup_path(name) end,
        run = function(argv, cb) default_run(argv, timeout, cb) end,
        read_file = default_read_file,
        exists = function(path) return uv.fs_stat(path) ~= nil end,
        getenv = os.getenv,
        timeout_ms = timeout,
        workspace = workspace,
        -- Inside Neovim the editor's own data directory; headless (the shim
        -- has no stdpath) `editor_data_dir` derives it from the platform rules.
        stdpath_data = nil,
    }
    if not vim._loomworks_shim and type(vim.fn.stdpath) == "function" then
        local ok, d = pcall(vim.fn.stdpath, "data")
        if ok and type(d) == "string" and d ~= "" then ctx.stdpath_data = (d:gsub("\\", "/")) end
    end
    for k, v in pairs(overrides) do ctx[k] = v end
    ctx.is_windows = ctx.platform == "windows"
    return ctx
end

-- ---------------------------------------------------------------------------
-- Shared declaration builders (host-neutral; used by modules/companions)
-- ---------------------------------------------------------------------------

--- A declaration for an executable found on the search path, with its version
--- from a version query. Modules that use the same executable build it through
--- this helper with the same `id`, so the declarations agree.
--- @param spec { id: string, category?: string, label: string, names?: string[], version_args?: string[], hint?: string|fun(ctx: loomworks.InventoryContext): string|nil }
--- @return loomworks.InventoryDeclaration
function M.exe_declaration(spec)
    local names = spec.names or { spec.label }
    return {
        id = spec.id,
        category = spec.category or "build tools",
        label = spec.label,
        probe = function(ctx, done)
            local path
            for _, n in ipairs(names) do
                path = ctx.lookup(n)
                if path then break end
            end
            local hint = spec.hint
            if type(hint) == "function" then hint = hint(ctx) end
            if not path then
                done({ id = spec.id, label = spec.label, status = "missing", hint = hint })
                return
            end
            local argv = { path }
            for _, a in ipairs(spec.version_args or { "--version" }) do argv[#argv + 1] = a end
            ctx.run(argv, function(res)
                done({
                    id = spec.id, label = spec.label, status = "found", path = path,
                    version = M.parse_version((res.stdout or "") .. "\n" .. (res.stderr or "")),
                    hint = hint,
                })
            end)
        end,
    }
end

--- The editor data directory Mason installs under (clangd §14): the editor's
--- `stdpath("data")` when running inside Neovim; headless, the same directory
--- from the platform rules and `NVIM_APPNAME` (`%LOCALAPPDATA%\<app>-data` on
--- Windows, `$XDG_DATA_HOME/<app>` or `~/.local/share/<app>` elsewhere).
--- @param ctx loomworks.InventoryContext
--- @return string|nil
function M.editor_data_dir(ctx)
    if ctx.stdpath_data then return ctx.stdpath_data end
    local app = ctx.getenv("NVIM_APPNAME")
    if not app or app == "" then app = "nvim" end
    if ctx.is_windows then
        local base = ctx.getenv("LOCALAPPDATA")
        if not base or base == "" then return nil end
        return (base:gsub("\\", "/")) .. "/" .. app .. "-data"
    end
    local xdg = ctx.getenv("XDG_DATA_HOME")
    if xdg and xdg ~= "" then return xdg .. "/" .. app end
    local home = ctx.getenv("HOME")
    if not home or home == "" then return nil end
    return home .. "/.local/share/" .. app
end

--- Mason's root (`<data>/mason`), or nil.
--- @param ctx loomworks.InventoryContext
--- @return string|nil
function M.mason_root(ctx)
    local d = M.editor_data_dir(ctx)
    return d and (d .. "/mason") or nil
end

--- Read a Mason package's install receipt without decoding it (a receipt can be
--- ~100 KB): the version is the tail of the source id (`pkg:…@<version>`), the
--- `bin` links map link name → path relative to the package directory.
--- @param ctx loomworks.InventoryContext
--- @param package string Mason package name
--- @return { dir: string, version: string|nil, bin: table<string, string> }|nil
function M.mason_package(ctx, package)
    local root = M.mason_root(ctx)
    if not root then return nil end
    local dir = root .. "/packages/" .. package
    local receipt = ctx.read_file(dir .. "/mason-receipt.json")
    if not receipt then
        if ctx.exists(dir) then return { dir = dir, bin = {} } end
        return nil
    end
    local version = receipt:match('"id"%s*:%s*"pkg:[^"]-@([^"]+)"')
    if version then version = version:gsub("^v(%d)", "%1") end
    local bin = {}
    local links = receipt:match('"links"%s*:%s*(%b{})')
    local bins = links and links:match('"bin"%s*:%s*(%b{})')
    if bins then
        for name, rel in bins:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
            -- JSON-escaped separators (`\/`, `\\`) → `/`.
            rel = rel:gsub("\\/", "/"):gsub("\\\\", "/"):gsub("\\", "/")
            bin[name] = dir .. "/" .. rel
        end
    end
    return { dir = dir, version = version, bin = bin }
end

--- Whether `path` lies under Mason's root (a search-path hit that is really the
--- Mason install — an editor's PATH carries `<data>/mason/bin`).
--- @param ctx loomworks.InventoryContext
--- @param path string
--- @return boolean
function M.under_mason(ctx, path)
    local root = M.mason_root(ctx)
    if not root then return false end
    local p, r = M.norm_path(path, ctx.is_windows), M.norm_path(root, ctx.is_windows)
    return p:sub(1, #r + 1) == r .. "/"
end

--- A declaration for a language server / debug adapter found on the search path
--- and/or in Mason's install directory (clangd §14). One result per location
--- found; a single `missing` result when neither has it.
---   * `names`       — search-path names (version via `version_args`, nil = no spawn);
---   * `mason`       — `{ package, bin?, file? }`: the receipt's `bin` link
---     (`bin`, tried with `.cmd`/`.exe`) or a file relative to the package dir
---     (`file`, tried with `.exe` on Windows); version from the receipt;
---   * `mason_bin`   — a name in `<data>/mason/bin` (no receipt, no version).
--- @param spec { id: string, category: string, label: string, names?: string[], version_args?: string[]|false, mason?: { package: string, bin?: string, file?: string }, mason_bin?: string, hint?: string }
--- @return loomworks.InventoryDeclaration
function M.tool_declaration(spec)
    return {
        id = spec.id,
        category = spec.category,
        label = spec.label,
        probe = function(ctx, done)
            local results = {}

            -- Mason install (filesystem only).
            local mpath, mversion
            if spec.mason then
                local pkg = M.mason_package(ctx, spec.mason.package)
                if pkg then
                    mversion = pkg.version
                    if spec.mason.bin then
                        for _, k in ipairs({ spec.mason.bin, spec.mason.bin .. ".cmd", spec.mason.bin .. ".exe" }) do
                            if pkg.bin[k] and ctx.exists(pkg.bin[k]) then mpath = pkg.bin[k] break end
                        end
                    end
                    if not mpath and spec.mason.file then
                        local cands = { pkg.dir .. "/" .. spec.mason.file }
                        if ctx.is_windows then table.insert(cands, 1, cands[1] .. ".exe") end
                        for _, c in ipairs(cands) do
                            if ctx.exists(c) then mpath = c break end
                        end
                    end
                end
            end
            if not mpath and spec.mason_bin then
                local root = M.mason_root(ctx)
                if root then
                    for _, ext in ipairs({ "", ".cmd", ".exe" }) do
                        local c = root .. "/bin/" .. spec.mason_bin .. ext
                        if ctx.exists(c) then mpath = c break end
                    end
                end
            end
            if mpath then
                results[#results + 1] = {
                    id = spec.id .. ":mason", label = spec.label, status = "found",
                    version = mversion, path = mpath, detail = "Mason",
                }
            end

            -- Search path (skipping a hit that IS the Mason install).
            local ppath
            for _, n in ipairs(spec.names or {}) do
                local p = ctx.lookup(n)
                if p and not M.under_mason(ctx, p) then ppath = p break end
            end
            local function finish()
                if #results == 0 then
                    results[1] = { id = spec.id, label = spec.label, status = "missing", hint = spec.hint }
                end
                done(results)
            end
            if not ppath then return finish() end
            if spec.version_args == false then
                results[#results + 1] = { id = spec.id .. ":path", label = spec.label, status = "found", path = ppath }
                return finish()
            end
            local argv = { ppath }
            for _, a in ipairs(spec.version_args or { "--version" }) do argv[#argv + 1] = a end
            ctx.run(argv, function(res)
                results[#results + 1] = {
                    id = spec.id .. ":path", label = spec.label, status = "found", path = ppath,
                    version = M.parse_version((res.stdout or "") .. "\n" .. (res.stderr or "")),
                }
                finish()
            end)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Contributors
-- ---------------------------------------------------------------------------

--- @class loomworks.InventoryContributor
--- @field kind "module"|"sdk"|"integration"
--- @field id string
--- @field api? integer declared interface version
--- @field rejected? string rejection reason (plugin present but not loaded)
--- @field impl? table the loaded plugin table

--- Memoized contributor list (plugins do not change within a process; a
--- `:LoomworksReload` reloads this module and so drops the memo).
--- @type loomworks.InventoryContributor[]|nil
M._contributors = nil

--- Every discovered module, SDK provider and inventory companion — loaded ones
--- with their interface version, rejected ones with the reason. Sorted by kind
--- then id, so the list (and the environment key built from it) is stable.
--- @return loomworks.InventoryContributor[]
function M.contributors()
    if M._contributors then return M._contributors end
    local out = {}

    local ok_m, modules = pcall(require, "loomworks.modules")
    if ok_m then
        for _, id in ipairs(modules.list()) do
            local impl = modules.get(id)
            if impl then out[#out + 1] = { kind = "module", id = id, api = impl.api_version, impl = impl } end
        end
        for id, reason in pairs(modules.rejected and modules.rejected() or {}) do
            out[#out + 1] = { kind = "module", id = id, rejected = reason }
        end
    end

    local ok_s, sdks = pcall(require, "loomworks.sdks")
    if ok_s then
        for _, id in ipairs(sdks.list()) do
            local impl = sdks.get(id)
            if impl then out[#out + 1] = { kind = "sdk", id = id, api = impl.api_version, impl = impl } end
        end
        for id, reason in pairs(sdks.rejected and sdks.rejected() or {}) do
            out[#out + 1] = { kind = "sdk", id = id, rejected = reason }
        end
    end

    local files = {}
    pcall(function()
        files = vim.api.nvim_get_runtime_file("lua/loomworks/integrations/inventory/*.lua", true)
    end)
    local seen = {}
    for _, path in ipairs(files) do
        local id = path:match("inventory[/\\]([^/\\]+)%.lua$")
        if id and not seen[id] then
            seen[id] = true
            local ok, impl = pcall(require, "loomworks.integrations.inventory." .. id)
            if ok and type(impl) == "table" and type(impl.health_inventory) == "function" then
                out[#out + 1] = { kind = "integration", id = id, impl = impl }
            else
                out[#out + 1] = { kind = "integration", id = id,
                    rejected = ok and "no health_inventory hook" or tostring(impl) }
            end
        end
    end

    local order = { module = 1, sdk = 2, integration = 3 }
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return order[a.kind] < order[b.kind] end
        return a.id < b.id
    end)
    M._contributors = out
    return out
end

--- Human label for a plugin-registry entry.
--- @param c loomworks.InventoryContributor
--- @return string
local function plugin_label(c)
    if c.kind == "module" then return c.id .. " module" end
    if c.kind == "sdk" then return c.id .. " SDK provider" end
    return c.id .. " integration"
end

--- Plugin-registry id of a contributor (`module:<id>`, `sdk-provider:<id>`,
--- `integration:<id>`) — the id a "module not loaded" requirement names.
--- @param kind string
--- @param id string
--- @return string
function M.plugin_id(kind, id)
    if kind == "module" then return "module:" .. id end
    if kind == "sdk" then return "sdk-provider:" .. id end
    return "integration:" .. id
end

--- Install remedy for a module plugin a project needs.
--- @param mod_type string
--- @param rejected? string
--- @return string
local function module_hint(mod_type, rejected)
    if rejected then
        return "update the plugin that provides the " .. mod_type .. " module"
    end
    return "lw module install " .. mod_type .. " (or install the plugin that provides it)"
end

--- The pinned SDKs of the workspace's profiles, deduplicated by key, sorted.
--- @param workspace loomworks.Workspace|nil
--- @return { key: string, sdk: loomworks.SDK|nil }[]
local function pinned_sdks(workspace)
    local out, seen = {}, {}
    if type(workspace) ~= "table" then return out end
    for _, p in pairs(workspace._profiles or {}) do
        local sdk = type(p.sdk) == "function" and p:sdk() or nil
        local key = (sdk and sdk.key) or p._sdk_key
        if key and not seen[key] then
            seen[key] = true
            out[#out + 1] = { key = key, sdk = sdk }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- Core's own declarations: the running lw, the compiler-cache launchers, the
--- plugin registry, and one declaration per loaded SDK provider.
--- @param ctx loomworks.InventoryContext
--- @param contributors loomworks.InventoryContributor[]
--- @return loomworks.InventoryDeclaration[]
local function core_declarations(ctx, contributors)
    local decls = {}

    -- Compiler caches (§1.3.2) — informational only, never required here.
    for _, tool in ipairs(require("loomworks.compiler_cache").KNOWN_LAUNCHERS) do
        decls[#decls + 1] = M.exe_declaration({
            id = "exe:" .. tool, category = "compiler caches", label = tool,
            names = { tool }, hint = "lw help cache",
        })
    end

    -- SDK providers: detected + pinned installations (§10.1 default).
    for _, c in ipairs(contributors) do
        if c.kind == "sdk" and c.impl then
            local provider = c.impl
            decls[#decls + 1] = {
                id = "sdks:" .. c.id,
                category = "SDKs",
                label = provider.display_name or c.id,
                probe = function(pctx, done)
                    local results, seen_path = {}, {}
                    for _, pin in ipairs(pinned_sdks(pctx.workspace)) do
                        local sdk = pin.sdk
                        if sdk and sdk._type == c.id then
                            local path = sdk._path
                            local info
                            if path and type(provider.validate) == "function" then
                                local ok, v = pcall(provider.validate, path)
                                info = ok and v or nil
                            end
                            if path then seen_path[M.norm_path(path)] = true end
                            results[#results + 1] = {
                                id = "sdk:" .. sdk.key,
                                label = sdk.display_name and sdk:display_name() or sdk.key,
                                status = info and "found" or "missing",
                                version = type(info) == "table" and info.version or sdk._version,
                                path = path,
                                hint = not info and "the pinned installation no longer validates — lw sdk" or nil,
                            }
                        end
                    end
                    if type(provider.detect_all) == "function" then
                        local ok, found = pcall(provider.detect_all)
                        for _, inst in ipairs(ok and type(found) == "table" and found or {}) do
                            if inst.path and not seen_path[M.norm_path(inst.path)] then
                                seen_path[M.norm_path(inst.path)] = true
                                results[#results + 1] = {
                                    id = M.path_id("sdk-path", inst.path),
                                    label = provider.display_name or c.id,
                                    status = "found", version = inst.version, path = inst.path,
                                }
                            end
                        end
                    end
                    -- A provider with nothing detected and nothing pinned
                    -- contributes no line (a user-declared SDK type is not a
                    -- finding by its absence).
                    done(results)
                end,
            }
        end
    end

    -- Plugin registry: every discovered plugin, rejected ones with the reason.
    decls[#decls + 1] = {
        id = "plugins",
        category = "plugins",
        label = "plugins",
        probe = function(_, done)
            local results = {}
            for _, c in ipairs(contributors) do
                results[#results + 1] = {
                    id = M.plugin_id(c.kind, c.id),
                    label = plugin_label(c),
                    status = c.rejected and "missing" or "found",
                    version = c.api and ("api " .. tostring(c.api)) or nil,
                    detail = c.rejected and ("rejected: " .. c.rejected) or nil,
                    hint = c.rejected and (c.kind == "module" and module_hint(c.id, c.rejected)
                        or ("update the plugin that provides " .. plugin_label(c))) or nil,
                }
            end
            done(results)
        end,
    }

    -- The running lw release (§16.32 facts).
    decls[#decls + 1] = {
        id = "lw",
        category = "lw",
        label = "lw",
        probe = function(_, done)
            local sug = require("loomworks.suggestions")
            local okf, facts = pcall(sug._host_facts)
            facts = okf and facts or nil
            local version = sug._current_release_version() or (facts and facts.release_version)
            local detail
            if not facts then
                detail = "in-editor plugin"
            elseif facts.dev_build then
                detail = "dev build"
            elseif facts.pinned then
                detail = "pinned (lw.pin)"
            end
            done({
                id = "lw", label = facts and "lw" or "loomworks", status = "found",
                version = version, path = facts and facts.exe or nil, detail = detail,
            })
        end,
    }
    return decls
end

--- Collect every declaration, deduplicated by id (first declaration wins), in
--- contributor order: modules, SDK providers' extras, inventory companions,
--- then core's own.
--- @param ctx loomworks.InventoryContext
--- @return loomworks.InventoryDeclaration[]
function M.declarations(ctx)
    local contributors = M.contributors()
    local out, seen = {}, {}
    local function add(list)
        for _, d in ipairs(type(list) == "table" and list or {}) do
            if type(d) == "table" and type(d.id) == "string" and type(d.probe) == "function"
                and not seen[d.id] then
                seen[d.id] = true
                out[#out + 1] = d
            end
        end
    end
    for _, c in ipairs(contributors) do
        if c.impl and type(c.impl.health_inventory) == "function" then
            local ok, list = pcall(c.impl.health_inventory, ctx)
            if ok then add(list) end
        end
    end
    add(core_declarations(ctx, contributors))
    return out
end

-- ---------------------------------------------------------------------------
-- Probing
-- ---------------------------------------------------------------------------

--- Run every declaration's probe concurrently, each under `ctx.timeout_ms`;
--- an erroring or timed-out probe yields one `unknown` result. Results carry
--- their declaration's `category` and id (`decl`). Blocks (pumping the event
--- loop) until every probe settled.
--- @param decls loomworks.InventoryDeclaration[]
--- @param ctx loomworks.InventoryContext
--- @return loomworks.InventoryResult[] results, string[] declared ids
function M.probe_all(decls, ctx)
    local slots, pending = {}, #decls
    local declared = {}
    local timers = {}

    local function settle(i, res)
        if slots[i] then return end
        slots[i] = res
        pending = pending - 1
        local t = timers[i]
        if t then
            timers[i] = nil
            pcall(function() t:stop(); t:close() end)
        end
    end

    -- Timers are due relative to the loop's cached "now"; in the standalone host
    -- the loop may not have run for seconds (workspace load), so refresh it or
    -- every probe would time out at once.
    pcall(uv.update_time)
    for i, d in ipairs(decls) do
        declared[#declared + 1] = { id = d.id, category = d.category }
        local function unknown(why)
            return { { id = d.id, label = d.label, status = "unknown", detail = why } }
        end
        local t = uv.new_timer()
        timers[i] = t
        t:start(ctx.timeout_ms or M.PROBE_TIMEOUT_MS, 0, function()
            settle(i, unknown("probe timed out"))
        end)
        local ok, err = pcall(d.probe, ctx, function(res)
            if type(res) ~= "table" then return settle(i, unknown("probe returned nothing")) end
            if res.status or res.id then res = { res } end
            settle(i, res)
        end)
        if not ok then settle(i, unknown("probe failed: " .. tostring(err))) end
    end

    if pending > 0 then
        vim.wait((ctx.timeout_ms or M.PROBE_TIMEOUT_MS) + 1000, function() return pending <= 0 end, 10)
    end

    local results, seen = {}, {}
    for i, d in ipairs(decls) do
        for _, r in ipairs(slots[i] or {}) do
            if type(r) == "table" then
                local id = r.id or d.id
                if not seen[id] then
                    seen[id] = true
                    results[#results + 1] = {
                        id = id,
                        label = r.label or d.label,
                        status = (r.status == "found" or r.status == "missing") and r.status or "unknown",
                        version = r.version,
                        path = r.path and tostring(r.path):gsub("\\", "/") or nil,
                        detail = r.detail,
                        hint = r.hint,
                        category = CATEGORY_RANK[r.category or d.category] and (r.category or d.category) or "other",
                        decl = d.id,
                    }
                end
            end
        end
    end
    return results, declared
end

-- ---------------------------------------------------------------------------
-- Environment key + tier
-- ---------------------------------------------------------------------------

--- The environment key (§16.33): a digest of the executable search path, the
--- platform, the contributors (with interface version or rejection), the
--- running bundle, and the SDK installations profiles pin. Spawns nothing.
--- @param workspace loomworks.Workspace|nil
--- @return string
function M.environment_key(workspace)
    local parts = {
        "platform=" .. M.platform(),
        "path=" .. tostring(os.getenv("PATH") or ""),
        "pathext=" .. tostring(os.getenv("PATHEXT") or ""),
        "bundle=" .. tostring(_G.__loomworks_luaroot or "-"),
    }
    for _, c in ipairs(M.contributors()) do
        parts[#parts + 1] = table.concat({ c.kind, c.id, tostring(c.api or "-"),
            c.rejected and "rejected" or "ok" }, "|")
    end
    for _, pin in ipairs(pinned_sdks(workspace)) do
        parts[#parts + 1] = "sdk|" .. pin.key .. "|" .. tostring(pin.sdk and pin.sdk._path or "")
    end
    return vim.fn.sha256(table.concat(parts, "\n")):sub(1, 16)
end

--- Probe the environment now (an explicit health run) and return the tier to
--- cache: `{ results, declared, key, computed_at }`. Always re-probes: the
--- search-path index is rebuilt first.
--- @param workspace loomworks.Workspace|nil
--- @param opts? { ctx?: table, clock?: fun(): integer }
--- @return table tier
function M.probe_tier(workspace, opts)
    opts = opts or {}
    local key = M.environment_key(workspace)
    if not opts.ctx then
        -- Fresh search-path index: health always re-probes.
        require("loomworks.cpp_compilers")._path_index = nil
    end
    local ctx = M.context(workspace, opts.ctx)
    local results, declared = M.probe_all(M.declarations(ctx), ctx)
    return {
        results = results,
        declared = declared,
        key = key,
        computed_at = (opts.clock or os.time)(),
    }
end

-- ---------------------------------------------------------------------------
-- Required derivation (pure) and classification
-- ---------------------------------------------------------------------------

--- Profiles in scope: the active one, else every profile (sorted by key).
--- @param workspace loomworks.Workspace
--- @return loomworks.Profile[]
local function scope_profiles(workspace)
    if workspace._active_profile then return { workspace._active_profile } end
    local out = {}
    for _, p in pairs(workspace._profiles or {}) do out[#out + 1] = p end
    table.sort(out, function(a, b) return (a.key or "") < (b.key or "") end)
    return out
end

--- What the workspace requires (§16.33 "Required vs other"), merged by id, in
--- first-appearance order. Pure: evaluates modules' `health_requirements` and
--- the profiles — no spawn, no filesystem access.
--- @param workspace loomworks.Workspace|nil
--- @return loomworks.InventoryRequirement[]
function M.requirements(workspace)
    local out, by_id = {}, {}
    if type(workspace) ~= "table" then return out end

    local function add(req, who)
        if type(req) ~= "table" or type(req.id) ~= "string" then return end
        local e = by_id[req.id]
        if not e then
            e = { id = req.id, label = req.label or req.id, hint = req.hint, via = req.via,
                required_by = {}, _seen = {} }
            by_id[req.id] = e
            out[#out + 1] = e
        end
        if who and not e._seen[who] then
            e._seen[who] = true
            e.required_by[#e.required_by + 1] = who
        end
    end

    local function project_reqs(project, tool, configuration, who)
        if not project or project.orphaned or project._removed then return end
        local mod = project._module
        if not mod then
            local mtype = tostring(project.type or "?")
            local rejected
            local ok_m, modules = pcall(require, "loomworks.modules")
            if ok_m and modules.rejected then rejected = modules.rejected()[mtype] end
            add({ id = M.plugin_id("module", mtype), label = mtype .. " module",
                hint = module_hint(mtype, rejected), via = "plugins" }, who)
            return
        end
        local impl = mod.impl
        if type(impl) ~= "table" or type(impl.health_requirements) ~= "function" then return end
        local ok, reqs = pcall(impl.health_requirements,
            { project = project, tool = tool, configuration = configuration })
        if ok and type(reqs) == "table" then
            for _, r in ipairs(reqs) do add(r, who) end
        end
    end

    local profiles = scope_profiles(workspace)
    if #profiles == 0 then
        local projects = {}
        for _, p in pairs(workspace._projects or {}) do projects[#projects + 1] = p end
        table.sort(projects, function(a, b) return (a.key or "") < (b.key or "") end)
        for _, project in ipairs(projects) do
            project_reqs(project, nil, nil, project.key)
        end
        return out
    end

    for _, profile in ipairs(profiles) do
        local sdk = type(profile.sdk) == "function" and profile:sdk() or nil
        local sdk_key = (sdk and sdk.key) or profile._sdk_key
        if sdk_key then
            add({
                id = "sdk:" .. sdk_key,
                label = sdk and sdk.display_name and sdk:display_name() or sdk_key,
                hint = "declare or fix the SDK installation — lw sdk",
                via = sdk and sdk._type and ("sdks:" .. sdk._type) or nil,
            }, profile.key)
        end
        for _, pp in ipairs(type(profile.projects) == "function" and profile:projects() or {}) do
            local project = pp._project
            if project then
                local tool = type(pp.tool_object) == "function" and pp:tool_object() or nil
                local cfg = type(pp.configuration) == "function" and pp:configuration() or nil
                project_reqs(project, tool, cfg, profile.key .. "/" .. project.key)
            end
        end
    end
    for _, e in ipairs(out) do e._seen = nil end
    return out
end

--- Split a tier's results into entries against the workspace's requirements.
--- Every result becomes an entry (`required`, `required_by`); a requirement no
--- result carries becomes a synthesized entry — `missing`, or `unknown` when
--- its enumerating declaration (`via`) was inconclusive or not probed.
--- @param tier table `{ results, declared }`
--- @param reqs loomworks.InventoryRequirement[]
--- @return table[] entries (results + category/required/required_by), in category order
function M.classify(tier, reqs)
    local results = type(tier) == "table" and tier.results or {}
    local declared = {}
    for _, d in ipairs(type(tier) == "table" and tier.declared or {}) do
        if type(d) == "table" and d.id then declared[d.id] = d.category or "other" end
    end
    local by_id = {}
    local entries = {}
    for _, r in ipairs(results) do
        local e = vim.deepcopy(r)
        e.required = false
        e.required_by = {}
        by_id[e.id] = e
        entries[#entries + 1] = e
    end
    for _, req in ipairs(reqs or {}) do
        local e = by_id[req.id]
        if not e then
            local status, category = "missing", "other"
            if req.via then
                category = declared[req.via] or "other"
                local via_res = by_id[req.via]
                if not declared[req.via] or (via_res and via_res.status == "unknown") then
                    status = "unknown"
                end
            end
            e = { id = req.id, label = req.label, status = status, hint = req.hint,
                category = category, required_by = {} }
            if status == "unknown" and not declared[req.via or ""] then
                e.detail = "not probed yet — lw health"
            end
            by_id[req.id] = e
            entries[#entries + 1] = e
        end
        e.required = true
        for _, who in ipairs(req.required_by or {}) do
            e.required_by[#e.required_by + 1] = who
        end
        if not e.hint then e.hint = req.hint end
    end
    -- Stable category order, declaration order within a category.
    for i, e in ipairs(entries) do e._i = i end
    table.sort(entries, function(a, b)
        local ra, rb = CATEGORY_RANK[a.category] or #M.CATEGORIES, CATEGORY_RANK[b.category] or #M.CATEGORIES
        if ra ~= rb then return ra < rb end
        return a._i < b._i
    end)
    for _, e in ipairs(entries) do e._i = nil end
    return entries
end

--- "a, b, c +2 more" — the names a requirement lists.
--- @param names string[]
--- @return string
function M.names_phrase(names)
    local shown = {}
    for i = 1, math.min(3, #names) do shown[i] = names[i] end
    local s = table.concat(shown, ", ")
    if #names > 3 then s = s .. " +" .. (#names - 3) .. " more" end
    return s
end

--- The actionable suggestions for classified entries: one per MISSING REQUIRED
--- entry (§16.33); everything else is information.
--- @param entries table[]
--- @return loomworks.Suggestion[]
function M.suggestions_for(entries)
    local out = {}
    for _, e in ipairs(entries) do
        if e.required and e.status == "missing" then
            out[#out + 1] = {
                kind = "suggestion",
                title = e.label .. " not found — needed by " .. M.names_phrase(e.required_by),
                remedy = e.hint,
            }
        end
    end
    return out
end

--- Actionable inventory suggestions for a cached tier against the CURRENT
--- workspace (the passive path): nothing when the tier is absent or recorded for
--- another environment. Never probes.
--- @param workspace loomworks.Workspace|nil
--- @param tier table|nil
--- @return loomworks.Suggestion[]
function M.cached_suggestions(workspace, tier)
    if type(tier) ~= "table" or type(tier.results) ~= "table" then return {} end
    if tier.key ~= M.environment_key(workspace) then return {} end
    return M.suggestions_for(M.classify(tier, M.requirements(workspace)))
end

return M
