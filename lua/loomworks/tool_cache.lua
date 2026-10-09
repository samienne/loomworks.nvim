--- loomworks/tool_cache.lua — the machine-level tool cache `tools.json`
--- (spec §16.43, §16.40; §19.11 "Warm restarts").
---
--- Detecting toolchains probes compilers, vswhere and vcvarsall — seconds of
--- work — so the last result is kept per MODULE TYPE in `<cache>/tools.json`,
--- shared by every workspace, the in-process CLI, every workspace daemon and
--- older `lw` releases on the machine. Both hosts read and fill it through
--- `detect` (cli.lua's caching wrapper around `detect_tools_async`).
---
--- File shape (cache `version` stays 1, so older releases keep reading it):
---   { version = 1, timestamp,                -- read by every release
---     scanned_types = { [type] = true },     -- read by every release
---     tools_by_type = { [type] = tools },    -- read by every release
---     types = { [type] = { tools, timestamp, fp } } }  -- this release
--- An older release ignores `types` (and drops it when it rewrites the file:
--- then every type is a miss here once, and is rewritten with its entry).
---
--- A type is reused only when its entry's fingerprint matches the current
--- inputs (`fingerprints`): the `lw` identity, the normalized search path,
--- PATHEXT, the platform, the module id and module interface version, and
--- the modification time of every search-path directory. No time-to-live.
---
--- Each detected type is written as soon as its detection finishes: re-read,
--- that type's entry and the shared fields replaced, written to a uniquely
--- named temporary file `tools.json.<pid>.<nonce>.tmp` (created exclusively)
--- and renamed over `tools.json` (retried briefly on Windows lock errors,
--- then given up). No lock: concurrent writers can lose an update (last
--- writer wins), costing a later re-detection. A leftover temporary file is
--- removed by housekeeping (`loomworks.housekeeping`, `TEMP_PATTERN`).
---
--- All I/O goes through an injectable `env` table (`M.env(overrides)`).

local M = {}

--- The cache file version every release checks (never bumped for additions).
M.VERSION = 1

--- Version of the fingerprint's own recipe (part of every fingerprint).
M.FP_VERSION = 1

--- The cache file's name in the cache directory.
M.FILE = "tools.json"

--- A temporary file of a write: `tools.json.<pid>.<nonce>.tmp` (captures pid
--- and nonce). Housekeeping removes a leftover one after 24 hours.
M.TEMP_PATTERN = "^tools%.json%.(%d+)%.(%x+)%.tmp$"

--- Rename retries on Windows lock errors (EACCES/EPERM) and their delay.
M.RENAME_RETRIES = 5
M.RENAME_RETRY_MS = 50

local function uv() return vim.uv or vim.loop end

--- Is `name` a temporary file name of a write (`TEMP_PATTERN`, a decimal pid
--- of at most 10 digits and a hex nonce of 16-64 digits)?
--- @param name string
--- @return boolean
function M.is_temp_name(name)
    local pid, nonce = tostring(name):match(M.TEMP_PATTERN)
    return pid ~= nil and #pid <= 10 and #nonce >= 16 and #nonce <= 64
end

--- @class loomworks.ToolCacheEnv
--- @field getenv fun(name: string): string|nil
--- @field is_windows boolean
--- @field platform string "windows"|"macos"|"linux"
--- @field identity fun(): string the running `lw` identity (`lw_version`, with a dev build's source hash)
--- @field stat fun(path: string): table|nil a followed stat (search-path directory mtimes)
--- @field now fun(): integer
--- @field pid fun(): integer
--- @field nonce fun(): string hex
--- @field read_file fun(path: string): string|nil
--- @field write_exclusive fun(path: string, data: string): boolean, string|nil, string|nil
--- @field rename fun(from: string, to: string): boolean|nil, string|nil, string|nil
--- @field unlink fun(path: string): boolean|nil, string|nil
--- @field mkdir_p fun(dir: string): boolean
--- @field sleep fun(ms: integer)
--- @field dir? string the cache directory (default: the platform rules, `default_dir`)

--- The production environment, with `overrides` applied (tests).
--- @param overrides? table
--- @return loomworks.ToolCacheEnv
function M.env(overrides)
    if overrides and overrides._tool_cache_env then return overrides end
    local win = vim.fn.has("win32") == 1
    local env = {
        _tool_cache_env = true,
        getenv = os.getenv,
        is_windows = win,
        platform = require("loomworks.inventory").platform(),
        identity = function() return require("loomworks.daemon.version").identity() end,
        stat = function(p) return uv().fs_stat(p) end,
        now = os.time,
        pid = function() return uv().os_getpid() end,
        nonce = function() return require("loomworks.remote.transport").nonce() end,
        read_file = function(p)
            local f = io.open(p, "rb")
            if not f then return nil end
            local s = f:read("*a"); f:close()
            return s
        end,
        write_exclusive = function(p, data) return require("loomworks.io").write_exclusive(p, data, 438) end,
        rename = function(a, b) return uv().fs_rename(a, b) end,
        unlink = function(p) return uv().fs_unlink(p) end,
        mkdir_p = function(d) return require("loomworks.io").mkdir_p(d) end,
        sleep = function(ms) uv().sleep(ms) end,
    }
    for k, v in pairs(overrides or {}) do env[k] = v end
    return env
end

--- The tool cache directory by the platform rules (spec §16.40 `<cache>`):
--- `%LOCALAPPDATA%/loomworks/cache` on Windows, else
--- `$XDG_CACHE_HOME/loomworks` or `~/.cache/loomworks`. Forward-slashed.
--- @param env? table
--- @return string
function M.default_dir(env)
    local getenv = env and env.getenv or os.getenv
    local win = env and env.is_windows
    if win == nil then win = vim.fn.has("win32") == 1 end
    if win then
        local lad = getenv("LOCALAPPDATA")
        if lad and #lad > 0 then return (lad:gsub("\\", "/")) .. "/loomworks/cache" end
    end
    local xdg = getenv("XDG_CACHE_HOME")
    if xdg and #xdg > 0 then return (xdg:gsub("\\", "/")) .. "/loomworks" end
    local home = getenv("HOME") or getenv("USERPROFILE") or "."
    return (home:gsub("\\", "/")) .. "/.cache/loomworks"
end

--- @param env? table
--- @return string
function M.dir(env)
    env = M.env(env)
    return env.dir or M.default_dir(env)
end

--- @param env? table
--- @return string
function M.path(env)
    return M.dir(env) .. "/" .. M.FILE
end

--- Read the cache file. A missing, unreadable, corrupt or other-version file
--- is nil (treated as empty; the next write replaces it).
--- @param env? table
--- @return table|nil { version, timestamp, scanned_types, tools_by_type, types? }
function M.read(env)
    env = M.env(env)
    local content = env.read_file(M.path(env))
    if not content or content == "" then return nil end
    local ok, data = pcall(vim.json.decode, content)
    if not ok or type(data) ~= "table" or data.version ~= M.VERSION then return nil end
    return data
end

--- The fingerprint of each module type in `types` (a set), computed once from
--- the current inputs (spec §16.43 "Fingerprint"). Core-only: no module hook.
--- @param types table<string, any>
--- @param env? table
--- @return table<string, string> fp by module type
function M.fingerprints(types, env)
    env = M.env(env)
    local inventory = require("loomworks.inventory")
    local ctx = inventory.context(nil, {
        platform = env.platform,
        getenv = env.getenv,
        exists = function(p) return env.stat(p) ~= nil end,
    })
    local entries = inventory.search_path_entries(ctx)
    local parts = {
        "fp=" .. M.FP_VERSION,
        "lw=" .. tostring(env.identity()),
        "platform=" .. tostring(env.platform),
        "path=" .. table.concat(entries, "\n  "),
        "pathext=" .. (env.is_windows and tostring(env.getenv("PATHEXT") or ""):upper() or ""),
    }
    for _, e in ipairs(entries) do
        local st = env.stat(e)
        local m = st and st.mtime
        parts[#parts + 1] = "mtime=" .. e .. "|"
            .. (m and string.format("%d.%d", m.sec or 0, m.nsec or 0) or "absent")
    end
    local base = table.concat(parts, "\n")
    local api = require("loomworks.api_versions")
    local out = {}
    for t in pairs(types or {}) do
        out[t] = vim.fn.sha256(base .. "\nmodule=" .. tostring(t) .. "|api=" .. tostring(api.module)):sub(1, 32)
    end
    return out
end

--- The cached tools of `mod_type` when its entry's fingerprint is `fp`, else
--- nil (a miss: no entry, another fingerprint, or a malformed entry).
--- @param cache table|nil
--- @param mod_type string
--- @param fp string
--- @return table|nil tools
function M.lookup(cache, mod_type, fp)
    local types = cache and type(cache.types) == "table" and cache.types or nil
    local e = types and types[mod_type]
    if type(e) ~= "table" or type(e.tools) ~= "table" or e.fp ~= fp then return nil end
    return e.tools
end

--- Write entries into the file: re-read it, replace each type's entry and
--- the shared fields every release reads, write a uniquely named temporary
--- file and rename it over `tools.json`. Never raises; a failure only loses
--- this cache write.
--- @param entries table<string, { tools: table|nil, fp: string }>
--- @param env? table
--- @return boolean ok, string|nil err
function M.write(entries, env)
    env = M.env(env)
    local dir = M.dir(env)
    local okd, made = pcall(env.mkdir_p, dir)
    if not (okd and made) then return false, "cannot create " .. dir end
    local data = M.read(env) or {}
    local now = env.now()
    local function tbl(v) return type(v) == "table" and v or {} end
    data.version = M.VERSION
    data.timestamp = now
    data.scanned_types = tbl(data.scanned_types)
    data.tools_by_type = tbl(data.tools_by_type)
    data.types = tbl(data.types)
    for t, e in pairs(entries) do
        local tools = type(e.tools) == "table" and e.tools or {}
        data.scanned_types[t] = true
        -- As older releases wrote it: an empty result has no list.
        data.tools_by_type[t] = #tools > 0 and tools or nil
        data.types[t] = { tools = tools, timestamp = now, fp = e.fp }
    end
    local okj, encoded = pcall(vim.json.encode, data)
    if not okj then return false, tostring(encoded) end
    local tmp = string.format("%s/tools.json.%d.%s.tmp", dir, env.pid(), env.nonce())
    -- Exclusive create: never through an existing name or a planted link.
    local okw, werr = env.write_exclusive(tmp, encoded)
    if not okw then return false, "write " .. tmp .. ": " .. tostring(werr) end
    local err
    for i = 1, M.RENAME_RETRIES do
        local ok, rerr, code = env.rename(tmp, M.path(env))
        if ok then return true end
        err = rerr
        if code ~= "EACCES" and code ~= "EPERM" then break end
        if i < M.RENAME_RETRIES then env.sleep(M.RENAME_RETRY_MS) end
    end
    -- Given up: our own temporary file goes (a failed unlink leaves a
    -- leftover for housekeeping).
    pcall(env.unlink, tmp)
    return false, "rename: " .. tostring(err)
end

--- The tools of the module types `opts.needed`: each type whose cached entry
--- matches its fingerprint is reused, the others are detected one at a time
--- (`opts.detect_one`) and each is written as soon as its detection finishes.
--- With `opts.force` (`lw tools`) every type is detected. Once
--- `opts.cancelled()` is true (the work was abandoned), no further type is
--- started: an interrupted type is never written; a type that finished is a
--- complete result and is written. `callback` gets `tools_by_type` (a type
--- with no tools is absent, as from `merge.detect_tools_async`).
--- @param opts { needed: table<string, any>, detect_one: fun(mod_type: string, cb: fun(tools: table|nil)), force?: boolean, cancelled?: fun(): boolean, env?: table }
--- @param callback fun(tools_by_type: table<string, table>)
function M.detect(opts, callback)
    local env = M.env(opts.env)
    local types = {}
    for t in pairs(opts.needed or {}) do types[#types + 1] = t end
    table.sort(types)
    local fps = M.fingerprints(opts.needed, env)
    local cache = not opts.force and M.read(env) or nil
    local result, misses = {}, {}
    for _, t in ipairs(types) do
        local tools = cache and M.lookup(cache, t, fps[t])
        if tools then
            if #tools > 0 then result[t] = tools end
        else
            misses[#misses + 1] = t
        end
    end
    local i = 0
    local function step()
        i = i + 1
        if i > #misses or (opts.cancelled and opts.cancelled()) then
            return callback(result)
        end
        local t = misses[i]
        opts.detect_one(t, function(tools)
            tools = type(tools) == "table" and tools or {}
            M.write({ [t] = { tools = tools, fp = fps[t] } }, env)
            if #tools > 0 then result[t] = tools end
            step()
        end)
    end
    step()
end

return M
