--- loomworks/provision/fetch.lua — download, verify and install the
--- plugin-managed `lw` host binary (spec §19.16 "Host binary", step 5h.3).
---
--- A wanted binary (`loomworks.provision.Wanted`: release version, asset name,
--- SHA-256 — from the plugin's own pin, step 5h.4) is fetched asynchronously
--- into a temporary file next to the managed slot, its SHA-256 compared with
--- the wanted one, made executable (POSIX) and renamed into
---
---     <stdpath("data")>/loomworks/lw/<sha256>/lw        (lw.exe on Windows)
---
--- Nothing is written outside `<stdpath("data")>/loomworks/` (the install
--- location rule). A failed or mismatching download leaves nothing behind but
--- the note; a present slot is never replaced (content-addressed). Requests
--- for one hash share one download (single flight).
---
--- Source: `<base>/<asset>` for a release-source override (`binary.release_url`,
--- else `LOOMWORKS_RELEASE_URL`: a local directory, `file://` or an http(s)
--- mirror, flat like lw's own, spec §16.29), else lw's fixed origin
--- `https://github.com/samienne/loomworks.nvim/releases/download/v<version>/<asset>`.
--- http(s) goes through `curl` (from the search path's absolute entries only).
--- The hash, not the transport, is the trust anchor.

local uv = vim.uv or vim.loop

local M = {}

--- @class loomworks.provision.Wanted  the managed binary the plugin wants
--- @field sha256 string lowercase hex SHA-256 of the asset (the trust anchor)
--- @field version string the release version (`0.1.44`)
--- @field asset string the release asset name (`lw-linux-x86_64`, `lw-windows-x86_64.exe`)

--- @class loomworks.provision.FetchState  the download of one hash (status page, checkhealth)
--- @field state "downloading"|"ready"|"failed"
--- @field url string
--- @field version string
--- @field asset string
--- @field path string the managed slot it installs into
--- @field error string|nil why it failed
--- @field waiters function[]|nil callbacks of the in-flight download

--- lw's fixed release origin (lw's `boot.update.DEFAULT_RELEASE_URL` root):
--- a version's assets live under `/releases/download/v<version>/`.
M.ORIGIN = "https://github.com/samienne/loomworks.nvim/releases"

--- Transfer limits (seconds) and attempts for http(s).
M.CONNECT_TIMEOUT = 30
M.MAX_TIME = 600
M.MAX_ATTEMPTS = 3
M.RETRY_DELAY_MS = 1000

--- Per hash: the download in flight, done or failed in this editor.
--- @type table<string, loomworks.provision.FetchState>
M.states = {}

local function is_win() return package.config:sub(1, 1) == "\\" end
local function slash(p) return (p:gsub("\\", "/")) end

--- Whether `v` is a safe release version (lw's `boot.pin.valid_version` rule:
--- never a path or URL fragment).
--- @param v any
--- @return boolean
function M.valid_version(v)
    if type(v) ~= "string" or v == "" then return false end
    if v:find("[/\\%s]") or v:find("..", 1, true) then return false end
    return v:match("^%w[%w%.%+%-]*$") ~= nil
end

--- Whether `a` is a safe host asset name (`lw-<platform>[.exe]`).
--- @param a any
--- @return boolean
function M.valid_asset(a)
    if type(a) ~= "string" or a:find("..", 1, true) then return false end
    return a:match("^lw%-[%w][%w%._%-]*$") ~= nil
end

--- Check a wanted record: the normalized record, or nil + why.
--- @param w any
--- @return loomworks.provision.Wanted|nil, string|nil
function M.check_wanted(w)
    if type(w) ~= "table" then return nil, "no wanted binary" end
    local sha = type(w.sha256) == "string" and w.sha256:lower() or nil
    if not sha or #sha ~= 64 or not sha:match("^%x+$") then return nil, "invalid hash " .. tostring(w.sha256) end
    if not M.valid_version(w.version) then return nil, "invalid release version " .. tostring(w.version) end
    if not M.valid_asset(w.asset) then return nil, "invalid asset name " .. tostring(w.asset) end
    return { sha256 = sha, version = w.version, asset = w.asset }
end

--- A local source (a plain path or `file://`), or nil for a URL.
--- @param url string
--- @return string|nil
function M.local_path(url)
    local scheme = url:match("^(%a[%w+.-]*)://")
    if scheme == "file" then
        local p = url:gsub("^file://", "")
        -- file:///C:/x → C:/x
        if p:match("^/%a:[/\\]") then p = p:sub(2) end
        return p
    end
    if not scheme then return url end -- a bare path (`C:/x` has no `://`)
    return nil
end

--- The release-source override: `binary.release_url`, else
--- `LOOMWORKS_RELEASE_URL`, else nil (lw's fixed origin).
--- @param opts? { release_url?: string, getenv?: fun(n: string): string|nil }
--- @return string|nil
function M.override(opts)
    opts = opts or {}
    local v = opts.release_url
    if v == nil or v == "" then v = (opts.getenv or os.getenv)("LOOMWORKS_RELEASE_URL") end
    if v == nil or v == "" then return nil end
    return (v:gsub("[/\\]+$", ""))
end

--- Where `w` is fetched from.
--- @param w loomworks.provision.Wanted (checked)
--- @param opts? { release_url?: string, getenv?: fun(n: string): string|nil }
--- @return string
function M.url(w, opts)
    local base = M.override(opts)
    if base then
        -- A mirror is flat — unless it is a GitHub-style `latest/download`
        -- base, which lw also resolves to the versioned path (§16.29).
        local root = not M.local_path(base) and base:match("^(.-)/releases/latest/download$")
        if root then return root .. "/releases/download/v" .. w.version .. "/" .. w.asset end
        return base .. "/" .. w.asset
    end
    return M.ORIGIN .. "/download/v" .. w.version .. "/" .. w.asset
end

--- `curl` from the search path's absolute entries (never the current
--- directory, spec §19.16), or nil.
--- @param opts? { getenv?: fun(n: string): string|nil, is_file?: fun(p: string): boolean }
--- @return string|nil
function M.find_curl(opts)
    opts = opts or {}
    local win = is_win()
    local binsel = require("loomworks.provision.select")
    local is_file = opts.is_file or function(p)
        local st = uv.fs_stat(p)
        return st ~= nil and st.type == "file"
    end
    for _, dir in ipairs(binsel.path_dirs((opts.getenv or os.getenv)("PATH"), win)) do
        local p = dir .. "/" .. (win and "curl.exe" or "curl")
        if is_file(p) then return p end
    end
    return nil
end

--- Whether a curl failure is worth retrying (as lw's `boot.download`): a 4xx
--- other than 408/429 is final, everything else may pass next time.
--- @param code integer
--- @param stderr string|nil
--- @return boolean
function M.is_transient(code, stderr)
    if code == 0 then return false end
    if code ~= 22 then return true end
    local status = tonumber((stderr or ""):match("returned error:%s*(%d%d%d)"))
    if not status or status == 408 or status == 429 then return true end
    return not (status >= 400 and status < 500)
end

--- The default transfer: copy a local source, or curl an http(s) URL into
--- `dest`. Calls `cb(ok, err)` on the main loop.
--- @param url string
--- @param dest string
--- @param cb fun(ok: boolean, err: string|nil)
--- @param opts? table
function M.transfer(url, dest, cb, opts)
    opts = opts or {}
    local done = vim.schedule_wrap(cb)
    local src = M.local_path(url)
    if src then
        uv.fs_copyfile(src, dest, function(err)
            if err then done(false, "cannot copy " .. src .. ": " .. tostring(err)) else done(true) end
        end)
        return
    end
    if not url:match("^https?://") then return done(false, "unsupported release source " .. url) end
    local curl = M.find_curl(opts)
    if not curl then return done(false, "curl was not found on the search path") end
    local args = { curl, "-fsSL", "--connect-timeout", tostring(M.CONNECT_TIMEOUT),
        "--max-time", tostring(M.MAX_TIME) }
    local ins = (opts.getenv or os.getenv)("LOOMWORKS_INSECURE_TLS")
    if ins and ins ~= "" and ins ~= "0" and ins:lower() ~= "false" then args[#args + 1] = "-k" end
    vim.list_extend(args, { "-o", dest, url })
    local attempt = 0
    local function try()
        attempt = attempt + 1
        local ok, err = pcall(vim.system, args, { text = true }, function(r)
            if r.code == 0 then return done(true) end
            if attempt < M.MAX_ATTEMPTS and M.is_transient(r.code, r.stderr) then
                return vim.defer_fn(try, M.RETRY_DELAY_MS * attempt)
            end
            local msg = vim.trim(r.stderr or "")
            done(false, "curl failed (exit " .. tostring(r.code) .. (msg ~= "" and (": " .. msg) or "") .. ")")
        end)
        if not ok then done(false, "cannot run curl: " .. tostring(err)) end
    end
    try()
end

local function lstat_type(p)
    local st = uv.fs_lstat(p)
    return st and st.type or nil
end

local function remove_file(p)
    if lstat_type(p) == "file" then pcall(uv.fs_unlink, p) end
end

local function mkdir(p)
    local t = lstat_type(p)
    if t == "directory" then return true end
    if t then return false, p .. " exists and is not a directory" end
    local ok, err = uv.fs_mkdir(p, 448) -- 0700
    if not ok and lstat_type(p) ~= "directory" then return false, "cannot create " .. p .. ": " .. tostring(err) end
    return true
end

local function finish(st, ok, path, err)
    st.state = ok and "ready" or "failed"
    st.error = err
    local waiters = st.waiters or {}
    st.waiters = nil
    for _, w in ipairs(waiters) do pcall(w, ok and path or nil, err) end
end

--- Make sure the managed binary `wanted` is installed; `cb(path)` or
--- `cb(nil, err)` on the main loop. Concurrent calls for one hash share one
--- download. opts (tests inject):
---   data         the editor's data directory (default stdpath("data"))
---   win          Windows rules (the file name)
---   release_url  the setup option `binary.release_url`
---   getenv       replaces os.getenv
---   transfer     fun(url, dest, cb(ok, err), opts) — replaces the download
---   hash         fun(path) → sha256|nil, err — replaces the file hash
---   on_state     fun(state) — called when the state changes
--- @param wanted loomworks.provision.Wanted
--- @param opts? table
--- @param cb fun(path: string|nil, err: string|nil)
--- @return loomworks.provision.FetchState|nil state
function M.ensure(wanted, opts, cb)
    opts = opts or {}
    cb = cb or function() end
    local managed = require("loomworks.provision.managed")
    local w, why = M.check_wanted(wanted)
    if not w then
        vim.schedule(function() cb(nil, why) end)
        return nil
    end
    local dest = managed.path(w.sha256, opts)
    local st = M.states[w.sha256]
    if st and st.state == "downloading" then
        table.insert(st.waiters, cb)
        return st
    end
    if lstat_type(dest) == "file" then
        M.states[w.sha256] = { state = "ready", url = M.url(w, opts), version = w.version,
            asset = w.asset, path = dest }
        vim.schedule(function() cb(dest) end)
        return M.states[w.sha256]
    end
    local url = M.url(w, opts)
    st = { state = "downloading", url = url, version = w.version, asset = w.asset, path = dest, waiters = { cb } }
    M.states[w.sha256] = st
    if opts.on_state then table.insert(st.waiters, 1, function() opts.on_state(st) end) end

    local dir = managed.dir(opts.data)
    local root = managed.root(opts.data)
    for _, d in ipairs({ vim.fs.dirname(root), root, dir }) do
        local ok, err = mkdir(d)
        if not ok then
            vim.schedule(function() finish(st, false, nil, err) end)
            return st
        end
    end
    -- The partial download: per process, removed whatever happens (a stale
    -- one of a crashed editor is pruned, loomworks.provision.cache).
    local tmp = dir .. "/" .. w.sha256 .. "." .. tostring(uv.os_getpid()) .. ".dl"
    remove_file(tmp)
    local function fail(err)
        remove_file(tmp)
        finish(st, false, nil, err)
    end
    ;(opts.transfer or M.transfer)(url, tmp, vim.schedule_wrap(function(ok, err)
        if not ok then return fail("download of " .. url .. " failed: " .. tostring(err)) end
        local got, herr = (opts.hash or require("loomworks.provision.sha256").file)(tmp)
        if not got then return fail(herr) end
        if got:lower() ~= w.sha256 then
            return fail(string.format("%s has SHA-256 %s, expected %s (not installed)", url, got, w.sha256))
        end
        if not (opts.win or (opts.win == nil and is_win())) then pcall(uv.fs_chmod, tmp, 493) end -- 0755
        local slot = vim.fs.dirname(dest)
        local okd, derr = mkdir(slot)
        if not okd then return fail(derr) end
        if lstat_type(dest) == "file" then
            -- Another editor installed it meanwhile: content-addressed, keep it.
            remove_file(tmp)
            return finish(st, true, dest)
        end
        local okr, rerr = uv.fs_rename(tmp, dest)
        if not okr then
            if lstat_type(dest) == "file" then remove_file(tmp); return finish(st, true, dest) end
            return fail("cannot install " .. dest .. ": " .. tostring(rerr))
        end
        finish(st, true, dest)
    end), opts)
    return st
end

--- One line for the status page and checkhealth: the state of the download
--- of `sha256` in this editor, or nil when none was started.
--- @param sha256 string|nil
--- @return string|nil
function M.describe(sha256)
    local st = sha256 and M.states[sha256:lower()]
    if not st then return nil end
    local what = "lw v" .. st.version .. " (" .. st.asset .. ")"
    if st.state == "downloading" then return "downloading " .. what .. " from " .. st.url end
    if st.state == "failed" then return "could not install " .. what .. ": " .. tostring(st.error) end
    return what .. " installed at " .. slash(st.path)
end

return M
