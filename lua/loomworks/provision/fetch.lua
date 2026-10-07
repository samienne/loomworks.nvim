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
--- location rule). A failed, cancelled or mismatching download leaves nothing
--- behind but the note; a present slot whose binary matches its hash is never
--- replaced (content-addressed) - one that does not (corrupt) is downloaded
--- again and renamed over. Requests for one hash share one download (single
--- flight); `M.cancel` aborts it (`:LoomworksDaemon connect`, a stop).
---
--- Source: `<base>/<asset>` for a release-source override (`binary.release_url`,
--- else `LOOMWORKS_RELEASE_URL`: a local directory, `file://` or an http(s)
--- mirror, flat like lw's own, spec §16.29), else lw's fixed origin
--- `https://github.com/samienne/loomworks.nvim/releases/download/v<version>/<asset>`.
--- http(s) goes through `curl` (from the search path's absolute entries only),
--- bounded by a connect timeout and a low-speed limit; from an https source a
--- redirect may only lead to https. The hash, not the transport, is the trust
--- anchor.

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
--- @field tmp string|nil its partial file
--- @field ctl { cancel: fun() }|nil stops its transfer
--- @field cancelled boolean|nil `M.cancel` ended it

--- lw's fixed release origin (lw's `boot.update.DEFAULT_RELEASE_URL` root):
--- a version's assets live under `/releases/download/v<version>/`.
M.ORIGIN = "https://github.com/samienne/loomworks.nvim/releases"

--- Transfer limits and attempts for http(s): a connection must come up
--- within CONNECT_TIMEOUT s, a transfer slower than LOW_SPEED_BPS bytes/s for
--- LOW_SPEED_S s is dropped (a hung download ends in about a minute, not at
--- MAX_TIME), and none runs past MAX_TIME s.
M.CONNECT_TIMEOUT = 20
M.LOW_SPEED_BPS = 1024
M.LOW_SPEED_S = 30
M.MAX_TIME = 300
M.MAX_ATTEMPTS = 3
M.RETRY_DELAY_MS = 1000

--- The rename of a new binary into its slot is retried on Windows while it
--- is held (an antivirus scans a fresh .exe): attempts, delay step (ms).
M.RENAME_ATTEMPTS = 6
M.RENAME_DELAY_MS = 100

--- Partial downloads of this process so far (their file names are unique).
M._seq = 0

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

--- The curl command line fetching `url` into `dest`.
--- @param curl string
--- @param url string
--- @param dest string
--- @param opts? { getenv?: fun(n: string): string|nil }
--- @return string[]
function M.curl_args(curl, url, dest, opts)
    opts = opts or {}
    local args = { curl, "-fsSL", "--connect-timeout", tostring(M.CONNECT_TIMEOUT),
        "--speed-limit", tostring(M.LOW_SPEED_BPS), "--speed-time", tostring(M.LOW_SPEED_S),
        "--max-time", tostring(M.MAX_TIME) }
    -- An https source may redirect only to https (an http mirror the user
    -- configured stays as it is).
    if url:match("^https://") then vim.list_extend(args, { "--proto-redir", "=https" }) end
    local ins = (opts.getenv or os.getenv)("LOOMWORKS_INSECURE_TLS")
    if ins and ins ~= "" and ins ~= "0" and ins:lower() ~= "false" then args[#args + 1] = "-k" end
    vim.list_extend(args, { "-o", dest, url })
    return args
end

--- The default transfer: copy a local source, or curl an http(s) URL into
--- `dest` (which does not exist: a copy refuses to replace anything). Calls
--- `cb(ok, err)` on the main loop. Returns a control whose `cancel()` stops
--- it (kills curl, stops retrying; a copy in progress just completes).
--- @param url string
--- @param dest string
--- @param cb fun(ok: boolean, err: string|nil)
--- @param opts? table
--- @return { cancel: fun() } ctl
function M.transfer(url, dest, cb, opts)
    opts = opts or {}
    local done = vim.schedule_wrap(cb)
    local ctl = { cancelled = false }
    function ctl.cancel()
        ctl.cancelled = true
        if ctl.proc then pcall(ctl.proc.kill, ctl.proc, 15) end
    end
    local src = M.local_path(url)
    if src then
        uv.fs_copyfile(src, dest, { excl = true }, function(err)
            if err then done(false, "cannot copy " .. src .. ": " .. tostring(err)) else done(true) end
        end)
        return ctl
    end
    if not url:match("^https?://") then done(false, "unsupported release source " .. url); return ctl end
    local curl = M.find_curl(opts)
    if not curl then done(false, "curl was not found on the search path"); return ctl end
    local args = M.curl_args(curl, url, dest, opts)
    local attempt = 0
    local function try()
        if ctl.cancelled then return done(false, "cancelled") end
        attempt = attempt + 1
        local ok, proc = pcall(vim.system, args, { text = true }, function(r)
            ctl.proc = nil
            if r.code == 0 and not ctl.cancelled then return done(true) end
            if not ctl.cancelled and attempt < M.MAX_ATTEMPTS and M.is_transient(r.code, r.stderr) then
                return vim.defer_fn(try, M.RETRY_DELAY_MS * attempt)
            end
            local msg = vim.trim(r.stderr or "")
            done(false, "curl failed (exit " .. tostring(r.code) .. (msg ~= "" and (": " .. msg) or "") .. ")")
        end)
        if ok then ctl.proc = proc else done(false, "cannot run curl: " .. tostring(proc)) end
    end
    try()
    return ctl
end

local function lstat_type(p)
    local st = uv.fs_lstat(p)
    return st and st.type or nil
end

--- Remove a partial-download path whatever it is but a directory: a regular
--- file, or a link (unlinked, never written or followed through). True when
--- nothing is there afterwards.
--- @param p string
--- @return boolean ok, string|nil err
local function clear(p)
    local t = lstat_type(p)
    if not t then return true end
    if t == "directory" then return false, p .. " is a directory" end
    pcall(uv.fs_unlink, p)
    if lstat_type(p) then return false, "cannot remove " .. p end
    return true
end

--- Create directory `p` (0700) unless present. `follow`: an existing link to a
--- directory is fine (the editor's data directory and `loomworks/` under it
--- may be links - dotfile setups); otherwise it must be a real directory
--- (lstat: `lw/` and the slots, where pruning acts).
local function mkdir(p, follow)
    local st = follow and uv.fs_stat(p) or uv.fs_lstat(p)
    local t = st and st.type or nil
    if t == "directory" then return true end
    if t or lstat_type(p) then return false, p .. " exists and is not a directory" end
    local ok, err = uv.fs_mkdir(p, 448) -- 0700
    local now = follow and uv.fs_stat(p) or uv.fs_lstat(p)
    if not ok and not (now and now.type == "directory") then
        return false, "cannot create " .. p .. ": " .. tostring(err)
    end
    return true
end

--- The partial file of download `seq` of `sha256` in this process:
--- `<dir>/<sha256>.<pid>.<seq>.dl` (loomworks.provision.cache prunes another
--- process's stale one).
--- @param dir string
--- @param sha256 string
--- @param seq integer
--- @return string
function M.partial_path(dir, sha256, seq)
    return dir .. "/" .. sha256 .. "." .. tostring(uv.os_getpid()) .. "." .. tostring(seq) .. ".dl"
end

--- Rename `from` to `to`, retried on Windows while the file is held
--- (EACCES/EPERM/EBUSY: an antivirus scanning a new .exe), without blocking.
--- @param from string
--- @param to string
--- @param win boolean
--- @param rename fun(a: string, b: string): any, string|nil, string|nil
--- @param cb fun(ok: boolean, err: string|nil)
local function rename_retry(from, to, win, rename, cb)
    local attempt = 0
    local function try()
        attempt = attempt + 1
        local ok, err, code = rename(from, to)
        if ok then return cb(true) end
        if win and attempt < M.RENAME_ATTEMPTS and (code == "EACCES" or code == "EPERM" or code == "EBUSY") then
            return vim.defer_fn(try, M.RENAME_DELAY_MS * attempt)
        end
        cb(false, err)
    end
    try()
end

local function finish(st, ok, path, err)
    st.state = ok and "ready" or "failed"
    st.error = err
    st.ctl = nil
    local waiters = st.waiters or {}
    st.waiters = nil
    for _, w in ipairs(waiters) do pcall(w, ok and path or nil, err) end
end

--- Make sure the managed binary `wanted` is installed; `cb(path)` or
--- `cb(nil, err)` on the main loop. Concurrent calls for one hash share one
--- download. A present binary is re-hashed once per process
--- (loomworks.provision.managed.verify); a corrupt one is downloaded again.
--- opts (tests inject):
---   data         the editor's data directory (default stdpath("data"))
---   win          Windows rules (the file name, the rename retry)
---   release_url  the setup option `binary.release_url`
---   getenv       replaces os.getenv
---   transfer     fun(url, dest, cb(ok, err), opts) → { cancel }|nil — replaces the download
---   hash         fun(path) → sha256|nil, err — replaces the file hash
---   rename       fun(from, to) → ok, err, code — replaces uv.fs_rename
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
    local win = opts.win
    if win == nil then win = is_win() end
    local dest = managed.path(w.sha256, { data = opts.data, win = win })
    local st = M.states[w.sha256]
    if st and st.state == "downloading" then
        table.insert(st.waiters, cb)
        return st
    end
    local vopts = { hash = opts.hash }
    if lstat_type(dest) == "file" and managed.verify(dest, w.sha256, vopts) then
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
    -- The data directory and `loomworks/` may be links (followed); `lw/`,
    -- where pruning acts, must be a real directory.
    for _, d in ipairs({ { vim.fs.dirname(root), true }, { root, true }, { dir, false } }) do
        local ok, err = mkdir(d[1], d[2])
        if not ok then
            vim.schedule(function() finish(st, false, nil, err) end)
            return st
        end
    end
    -- The partial download: unique per process and attempt, removed whatever
    -- happens (a stale one of a crashed editor is pruned,
    -- loomworks.provision.cache). Whatever is at its path (a link) goes first.
    M._seq = M._seq + 1
    local tmp = M.partial_path(dir, w.sha256, M._seq)
    st.tmp = tmp
    local okc, cerr = clear(tmp)
    if not okc then
        vim.schedule(function() finish(st, false, nil, cerr) end)
        return st
    end
    local function fail(err)
        clear(tmp)
        finish(st, false, nil, err)
    end
    local function step(fn)
        return function(...)
            if st.cancelled then clear(tmp); return end -- `M.cancel` already told the waiters
            return fn(...)
        end
    end
    local ctl = (opts.transfer or M.transfer)(url, tmp, vim.schedule_wrap(step(function(ok, err)
        if not ok then return fail("download of " .. url .. " failed: " .. tostring(err)) end
        local got, herr = (opts.hash or require("loomworks.provision.sha256").file)(tmp)
        if not got then return fail(herr) end
        if got:lower() ~= w.sha256 then
            return fail(string.format("%s has SHA-256 %s, expected %s (not installed)", url, got, w.sha256))
        end
        if not win then pcall(uv.fs_chmod, tmp, 493) end -- 0755
        local slot = vim.fs.dirname(dest)
        local okd, derr = mkdir(slot, false)
        if not okd then return fail(derr) end
        if lstat_type(dest) == "file" and managed.verify(dest, w.sha256, vopts) then
            -- Another editor installed it meanwhile: content-addressed, keep it.
            clear(tmp)
            return finish(st, true, dest)
        end
        -- Absent, or corrupt: rename over it.
        rename_retry(tmp, dest, win, opts.rename or uv.fs_rename, step(function(okr, rerr)
            if not okr then
                if lstat_type(dest) == "file" and managed.verify(dest, w.sha256, vopts) then
                    clear(tmp); return finish(st, true, dest)
                end
                return fail("cannot install " .. dest .. ": " .. tostring(rerr))
            end
            managed.verified(dest, w.sha256)
            finish(st, true, dest)
        end))
    end)), opts)
    st.ctl = type(ctl) == "table" and ctl or nil
    return st
end

--- Abort the download of `sha256` in flight: stop its transfer (kill curl),
--- remove its partial file and tell its waiters `cb(nil, "cancelled ...")`.
--- @param sha256 string
--- @param why? string
--- @return boolean cancelled false when none was running
function M.cancel(sha256, why)
    local st = type(sha256) == "string" and M.states[sha256:lower()] or nil
    if not st or st.state ~= "downloading" then return false end
    st.cancelled = true
    if st.ctl and st.ctl.cancel then pcall(st.ctl.cancel) end
    -- On Windows curl may still hold it: the transfer's late callback
    -- removes it then.
    if st.tmp then clear(st.tmp) end
    finish(st, false, nil, "cancelled" .. (why and (" (" .. why .. ")") or ""))
    return true
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
