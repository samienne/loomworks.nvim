--- loomworks/housekeeping.lua — per-user state outside the workspace (spec
--- §16.40).
---
--- * Temporary files of a workspace operation (the results file of a named
---   test executable, the editor buffer of a description) live in the
---   workspace's `.nvim/tmp/`, not the system temp directory (`tmp_path`).
--- * Leftovers of interrupted `lw` processes outside the workspace are found
---   by `collect` and removed by `remove`: once a day at the start of a CLI
---   command (`startup`, silent) and on request by `lw cleanup` (`cmd`).
---
--- DELETION SAFETY (CLAUDE.md item 9, spec §16.40 "Removal safety"):
---   * only direct children of the fixed directories, each a real directory
---     (lstat) whose resolved path is the one expected (`fixed`);
---   * only names matching an exact pattern (validated version / sha256 /
---     module name / vcvars arch / hex nonce / pid);
---   * a candidate that is a link or junction is skipped; the lstat type must
---     be the pattern's (file / directory / socket); trees go through
---     `io.rm_rf` (links unlinked, never followed);
---   * only past the pattern's age; never in use: device locks only of a
---     provably dead holder with no program record (nonce-checked reclaim),
---     sockets only when they refuse a connection (moved aside, put back if
---     replaced), pinned releases never the current pin's / the running
---     exe's / the running bundle's / recently used (renamed to `.trash-*`
---     before the tree is removed).
--- Bundle-side on purpose: every host (old ones included, §16.14) runs it;
--- it needs no boot module (`boot.pin`, 0.1.6, only through pcall).

local M = {}

local function uv() return vim.uv or vim.loop end

local IS_WIN = package.config:sub(1, 1) == "\\"

local function norm(p)
    return (tostring(p):gsub("\\", "/"):gsub("/+$", ""))
end

--- Comparison key of a path: normalized, case-folded on Windows.
local function key(p)
    local n = norm(p)
    if IS_WIN then n = n:lower() end
    return n
end

--- Is `p` the key `base` or below it (separator-bounded)?
local function under(p, base)
    return p == base or p:sub(1, #base + 1) == base .. "/"
end
M._under = under

local function realkey(p)
    local ok, r = pcall(uv().fs_realpath, p)
    if ok and type(r) == "string" and r ~= "" then return key(r) end
    return nil
end

local HOUR, DAY = 3600, 86400

--- Ages (seconds) past which a leftover is removed (spec §16.40).
M.AGE = {
    transient = DAY,      -- downloads, staging, temp files, `.new`
    vcvars = HOUR,        -- `lw_vcvars_*.bat`
    results = DAY,        -- `lw-test-*.xml`
    editor = 7 * DAY,     -- `lw-describe-*.txt`
    legacy_log = 30 * DAY, -- `<data>/daemon/logs/*`
    socket = HOUR,
}
--- Default `lw cleanup --all` threshold for pinned releases.
M.PINNED_DEFAULT = 30 * DAY
--- How often the startup pass runs (per user).
M.INTERVAL = DAY
--- The stamp file in `<data>`.
M.STAMP = ".housekeeping"
--- Entries read from a temp directory at most.
M.TMP_SCAN_CAP = 10000
--- Total time the socket tests may wait (ms).
M.SOCKET_BUDGET_MS = 1000

-- ---------------------------------------------------------------------------
-- In-workspace temporary files
-- ---------------------------------------------------------------------------

--- A random hex nonce (24 digits).
--- @return string
function M.nonce()
    return require("loomworks.remote.transport").nonce()
end

--- The system temporary directory, forward-slashed.
--- @return string
function M.os_tmpdir()
    return norm(uv().os_tmpdir())
end

--- Ensure `dir` is a real directory (created with one `mkdir` when missing,
--- never through a link). Returns true when it is one.
local function real_dir(dir)
    local st = uv().fs_lstat(dir)
    if not st then
        pcall(uv().fs_mkdir, dir, tonumber("755", 8))
        st = uv().fs_lstat(dir)
    end
    return st ~= nil and st.type == "directory"
end

--- The workspace's temporary directory `<root>/.nvim/tmp`, created when
--- missing: `.nvim/` only when the root exists (the root is never created),
--- each level a real directory, not a link. nil when it cannot be had.
--- @param root string|nil
--- @return string|nil
function M.workspace_tmp_dir(root)
    if type(root) ~= "string" or root == "" then return nil end
    root = norm(root)
    local rst = uv().fs_stat(root)
    if not rst or rst.type ~= "directory" then return nil end
    local nvim = root .. "/.nvim"
    if not real_dir(nvim) then return nil end
    local dir = nvim .. "/tmp"
    if not real_dir(dir) then return nil end
    return dir
end

--- A fresh path for a temporary file of a workspace operation:
--- `<root>/.nvim/tmp/<prefix><nonce><ext>`, or the same name in the system
--- temp directory when the workspace's cannot be had (§16.40).
--- @param root string|nil
--- @param prefix string e.g. "lw-test-"
--- @param ext string e.g. ".xml"
--- @return string
function M.tmp_path(root, prefix, ext)
    local name = prefix .. M.nonce() .. ext
    local dir = M.workspace_tmp_dir(root) or M.os_tmpdir()
    return dir .. "/" .. name
end

-- ---------------------------------------------------------------------------
-- Name patterns
-- ---------------------------------------------------------------------------

--- A safe release version (mirrors boot.pin.valid_version, which a host older
--- than 0.1.6 lacks).
local function valid_version(v)
    if type(v) ~= "string" or v == "" then return false end
    if v:find("[/\\%s]") or v:find("..", 1, true) then return false end
    return v:match("^%w[%w%.%+%-]*$") ~= nil
end
M._valid_version = valid_version

--- A release version as lw names its downloads and stages: `<n>.<n>.<n>`
--- plus an optional pre-release / build tail (`0.1.40`, `0.1.40-beta.1`),
--- and a safe version. Narrower than `valid_version`, so a user's
--- `.stage-old` in a data directory pointed at $HOME never matches.
local function release_version(v)
    return valid_version(v) and v:match("^%d+%.%d+%.%d+[%w%.%+%-]*$") ~= nil
end
M._release_version = release_version

local function valid_module(n)
    return type(n) == "string" and n:match("^%w[%w._-]*$") ~= nil
end

local function is_sha(s)
    return type(s) == "string" and #s == 64 and s:match("^[0-9a-f]+$") ~= nil
end

local function is_hex(s, min, max)
    return type(s) == "string" and #s >= min and #s <= max and s:match("^%x+$") ~= nil
end

local function valid_arch(a)
    local ok, msvc = pcall(require, "loomworks.msvc")
    if ok and type(msvc) == "table" and type(msvc.valid_arch) == "function" then
        return msvc.valid_arch(a)
    end
    return false
end

--- The published host-binary asset names (boot.pin.HOST_ASSETS, plus this
--- copy for hosts that predate it).
local function host_assets()
    local set = { ["lw-linux-x86_64"] = true, ["lw-macos-arm64"] = true, ["lw-windows-x86_64.exe"] = true }
    local ok, pin = pcall(require, "boot.pin")
    if ok and type(pin) == "table" and type(pin.HOST_ASSETS) == "table" then
        for _, a in pairs(pin.HOST_ASSETS) do set[a] = true end
    end
    return set
end

--- The version of a pinned host binary name `lw-<ver>-<asset>`, or nil.
local function pinned_binary_version(name, assets)
    if name:sub(1, 3) ~= "lw-" then return nil end
    for a in pairs(assets) do
        local tail = "-" .. a
        if #name > 3 + #tail and name:sub(-#tail) == tail then
            local v = name:sub(4, #name - #tail)
            if release_version(v) then return v end
        end
    end
    return nil
end
M._pinned_binary_version = pinned_binary_version

-- ---------------------------------------------------------------------------
-- Collection
-- ---------------------------------------------------------------------------

--- `dir` as a fixed parent: a real directory (lstat) whose resolved path is
--- `want` (a key) when given. Returns its resolved key, or nil.
local function fixed(dir, want)
    local st = uv().fs_lstat(dir)
    if not st or st.type ~= "directory" then return nil end
    local r = realkey(dir)
    if not r then return nil end
    if want and r ~= want then return nil end
    return r
end
M._fixed = fixed

--- The names in `dir` (at most `cap`).
local function names(dir, cap)
    local out = {}
    local h = uv().fs_scandir(dir)
    while h do
        local n = uv().fs_scandir_next(h)
        if not n then break end
        out[#out + 1] = n
        if cap and #out >= cap then break end
    end
    return out
end

local function mtime(st)
    return (st and st.mtime and st.mtime.sec) or 0
end

--- Bytes in a tree (files only; links counted as themselves, never followed).
local function tree_size(path, st)
    st = st or uv().fs_lstat(path)
    if not st then return 0 end
    if st.type ~= "directory" then return st.size or 0 end
    local total = 0
    for _, n in ipairs(names(path)) do total = total + tree_size(path .. "/" .. n) end
    return total
end

--- Is `data` lw's own data directory (spec §16.40)? Any one marker: the
--- machine key, the housekeeping stamp, `pinned/`, or an installed release
--- `lua-<ver>/loomworks/cli.lua` (real entries, lstat). Without one (e.g.
--- LOOMWORKS_DATA_DIR pointed at a home directory) nothing in it is
--- scanned, and no stamp is written there.
--- @param data string
--- @return boolean
function M.is_lw_data(data)
    local function is(p, t) local st = uv().fs_lstat(p); return st ~= nil and st.type == t end
    if is(data .. "/trust.key", "file") or is(data .. "/" .. M.STAMP, "file")
            or is(data .. "/pinned", "directory") then
        return true
    end
    for _, n in ipairs(names(data)) do
        local v = n:match("^lua%-(.+)$")
        if v and release_version(v) and is(data .. "/" .. n .. "/loomworks/cli.lua", "file") then return true end
    end
    return false
end

--- The default per-user data directory (boot.paths rules, via trust).
local function default_data()
    return norm(require("loomworks.trust").data_dir())
end

--- The temp directories `lw` writes to: the system temp directory and, on
--- Windows, %TEMP% (the vcvars probe's).
local function default_tmp_dirs()
    local out, seen = {}, {}
    local function add(d)
        if type(d) ~= "string" or d == "" then return end
        d = norm(d)
        if not d:match("^/") and not d:match("^%a:/") then return end
        if not seen[key(d)] then seen[key(d)] = true; out[#out + 1] = d end
    end
    pcall(function() add(uv().os_tmpdir()) end)
    if IS_WIN then add(os.getenv("TEMP")); add(os.getenv("TMP")) end
    return out
end

--- POSIX per-user socket directories (spec §19.7).
local function default_run_dirs()
    if IS_WIN then return {} end
    local id = (uv().getuid and uv().getuid()) or 0
    local out = {}
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if xdg and xdg ~= "" then out[#out + 1] = norm(xdg) .. "/loomworks" end
    local t = os.getenv("TMPDIR")
    if t and t ~= "" then out[#out + 1] = norm(t) .. "/loomworks-" .. id end
    out[#out + 1] = "/tmp/loomworks-" .. id
    return out
end

--- The running bundle's root (the directory holding `loomworks/`), or nil.
local function running_bundle()
    local r = rawget(_G, "__loomworks_luaroot")
    if type(r) == "string" and r ~= "" then return r end
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        local p = norm(src:sub(2))
        return p:match("^(.*)/loomworks/housekeeping%.lua$")
    end
    return nil
end

--- The version the nearest `lw.pin` pins, or nil (boot.pin via pcall).
local function current_pin_version()
    local ok, pin = pcall(require, "boot.pin")
    if not ok or type(pin) ~= "table" or type(pin.find_pin_root) ~= "function" then return nil end
    local start = os.getenv("LW_ROOT")
    if not start or start == "" then start = uv().cwd() end
    local ok2, p = pcall(function() return pin.read(pin.find_pin_root(start)) end)
    return (ok2 and type(p) == "table") and p.version or nil
end

--- @class loomworks.HousekeepingItem
--- @field kind string short label ("download", "pinned release", …)
--- @field path string
--- @field type "file"|"directory"|"socket"
--- @field size integer bytes
--- @field age integer seconds since modification
--- @field remove? fun(item: loomworks.HousekeepingItem): boolean, string|nil
--- @field _st table the lstat that qualified it

--- @class loomworks.HousekeepingOpts
--- @field root? string the workspace root (its `.nvim/tmp`)
--- @field all? boolean add pinned releases and every legacy runtime log
--- @field pinned_age? integer pinned threshold (seconds); implies the pinned part
--- @field now? integer
--- @field data? string per-user data directory
--- @field tmp_dirs? string[]
--- @field run_dirs? string[]
--- @field exe? string|false the running executable (false: none)
--- @field bundle? string|false the running bundle root
--- @field pin_version? string|false the current repository's pinned version
--- @field device_lock_dir_default? boolean device locks are in `<data>/device-locks`
--- @field sockets? boolean test sockets (default: POSIX)

--- Add a candidate `dir/name` when its lstat type is `typ` and it is at least
--- `min_age` old. Returns the item or nil.
local function consider(items, ctx, dir, name, typ, kind, min_age, extra)
    local path = dir .. "/" .. name
    local st = uv().fs_lstat(path)
    if not st or st.type ~= typ then return nil end
    local age = ctx.now - mtime(st)
    if age < 0 then age = 0 end
    if age < min_age then return nil end
    local item = { kind = kind, path = path, type = typ, age = age, _st = st, _min_age = min_age }
    item.size = (typ == "directory") and tree_size(path, st) or (st.size or 0)
    for k, v in pairs(extra or {}) do item[k] = v end
    items[#items + 1] = item
    return item
end

--- Leftovers directly in `<data>`.
local function scan_data(items, ctx, data)
    local T = M.AGE.transient
    for _, n in ipairs(names(data)) do
        local v = n:match("^%.dl%-(.+)%.zip$")
        if v and release_version(v) then consider(items, ctx, data, n, "file", "download", T) end
        v = n:match("^%.stage%-(.+)$")
        if v and release_version(v) then consider(items, ctx, data, n, "directory", "staging", T) end
        if n == "release-notes-seen.tmp" or n:match("^release%-notes%-seen%.tmp%d+$") then
            consider(items, ctx, data, n, "file", "temp file", T)
        end
    end
end

--- Rename a pinned release aside (`.trash-<nonce>`), then remove the tree and
--- an emptied `<sha256>/` parent (spec §16.40).
local function remove_pinned_dir(item)
    local trash = item._pinned_root .. "/.trash-" .. M.nonce()
    local ok, err = uv().fs_rename(item.path, trash)
    if not ok then return false, "not renamed aside (in use?): " .. tostring(err) end
    local rok, rerr = M._rm_tree(trash)
    pcall(uv().fs_rmdir, item._sha_dir)
    if not rok then return false, "renamed aside to " .. trash .. ", not fully removed: " .. tostring(rerr) end
    return true
end

--- Is `k` (a resolved key) something running, or a tree holding it?
local function is_running(k, ctx)
    for _, r in ipairs(ctx.running) do
        if r == k or under(r, k) then return true end
    end
    return false
end

--- Leftovers and (with `ctx.pinned_age`) prunable releases in
--- `<data>/pinned`.
local function scan_pinned(items, ctx, pinned, rpinned)
    local T = M.AGE.transient
    local assets = host_assets()
    for _, n in ipairs(names(pinned)) do
        local sha, v = n:match("^%.dl%-(%x+)%-(.+)%.zip$")
        if sha and is_sha(sha) and release_version(v) then consider(items, ctx, pinned, n, "file", "download", T) end
        sha, v = n:match("^%.stage%-(%x+)%-(.+)$")
        if sha and is_sha(sha) and release_version(v) then consider(items, ctx, pinned, n, "directory", "staging", T) end
        local base = n:match("^(.+)%.dl$")
        if base and pinned_binary_version(base, assets) then consider(items, ctx, pinned, n, "file", "download", T) end
        local nonce = n:match("^%.trash%-(%x+)$")
        if nonce and is_hex(nonce, 8, 64) then consider(items, ctx, pinned, n, "directory", "trash", 0) end
        if ctx.pinned_age then
            local bv = pinned_binary_version(n, assets)
            if bv then
                local st = uv().fs_lstat(pinned .. "/" .. n)
                if st and st.type == "file" then
                    local k = realkey(pinned .. "/" .. n)
                    if bv == ctx.pin_version or not k or is_running(k, ctx)
                            or ctx.now - mtime(st) < ctx.pinned_age then
                        ctx.kept_pinned = ctx.kept_pinned + 1
                    else
                        consider(items, ctx, pinned, n, "file", "pinned binary", ctx.pinned_age)
                    end
                end
            end
            if is_sha(n) then
                local sdir = pinned .. "/" .. n
                if fixed(sdir, rpinned .. "/" .. n) then
                    for _, ln in ipairs(names(sdir)) do
                        local lv = ln:match("^lua%-(.+)$")
                        local st = lv and release_version(lv) and uv().fs_lstat(sdir .. "/" .. ln)
                        if st and st.type == "directory" then
                            local k = realkey(sdir .. "/" .. ln)
                            if lv == ctx.pin_version or not k or is_running(k, ctx)
                                    or ctx.now - mtime(st) < ctx.pinned_age then
                                ctx.kept_pinned = ctx.kept_pinned + 1
                            else
                                consider(items, ctx, sdir, ln, "directory", "pinned release", ctx.pinned_age, {
                                    remove = remove_pinned_dir, _pinned_root = pinned, _sha_dir = sdir,
                                })
                            end
                        end
                    end
                end
            end
        end
    end
end

local function scan_modules(items, ctx, mods)
    local T = M.AGE.transient
    for _, n in ipairs(names(mods)) do
        local m = n:match("^%.dl%-(.+)%.zip$")
        if m and valid_module(m) then consider(items, ctx, mods, n, "file", "download", T) end
        m = n:match("^%.stage%-(.+)$")
        if m and valid_module(m) then consider(items, ctx, mods, n, "directory", "staging", T) end
    end
end

--- Remove a dead holder's device lock by the nonce-checked reclaim (§19.5).
local function remove_device_lock(item)
    local lr = require("loomworks.lock_record")
    local cur = lr.read(item.path, math.huge)
    if not cur or lr._identity(cur) ~= lr._identity(item._info) then
        return false, "the lock changed meanwhile"
    end
    if lr.reclaim(item.path, item._info) then return true end
    return false, "the lock changed meanwhile"
end

local function scan_device_locks(items, ctx, dir)
    local T = M.AGE.transient
    local build_lock = require("loomworks.build_lock")
    local lr = require("loomworks.lock_record")
    for _, n in ipairs(names(dir)) do
        if n:match("^[%w%._%-]+%.leftover%.tmp%.%d+$") then
            consider(items, ctx, dir, n, "file", "temp file", T)
        end
        local nonce = n:match("^[%w%._%-]+%.lock%.reclaim%.(%x+)$")
        if nonce then consider(items, ctx, dir, n, "file", "temp file", T) end
        if n:match("^[%w%._%-]+%.lock$") then
            local path = dir .. "/" .. n
            local st = uv().fs_lstat(path)
            if st and st.type == "file" then
                local info = lr.read(path, build_lock.STALE_SECONDS)
                -- Provably gone (same host, no such process) and no program
                -- left running on the device (§18.7: that record must stay).
                if info and lr.classify(info) == "dead" and info.device_pid == nil
                        and info.program == nil then
                    consider(items, ctx, dir, n, "file", "device lock", 0, {
                        remove = remove_device_lock, _info = info,
                    })
                end
            end
        end
    end
end

local function scan_legacy_logs(items, ctx, dir)
    local min = ctx.all and 0 or M.AGE.legacy_log
    for _, n in ipairs(names(dir)) do
        local h = n:match("^(%x+)%.log$") or n:match("^(%x+)%.log%.1$")
        if h and #h == 16 then consider(items, ctx, dir, n, "file", "runtime log", min) end
    end
end

--- `lw-test-*.xml` / `lw-describe-*.txt` (and on Windows the vcvars probe) in
--- a temp directory.
local function scan_tmp(items, ctx, dir, vcvars)
    -- A shared temp directory (POSIX /tmp) holds other users' files: only
    -- this user's are candidates.
    local function mine(n)
        if ctx.is_windows then return true end
        local st = uv().fs_lstat(dir .. "/" .. n)
        return st ~= nil and st.uid == ctx.uid
    end
    for _, n in ipairs(names(dir, M.TMP_SCAN_CAP)) do
        if not mine(n) then goto continue end
        local h = n:match("^lw%-test%-(%x+)%.xml$")
        if h and is_hex(h, 16, 64) then consider(items, ctx, dir, n, "file", "test results", M.AGE.results) end
        h = n:match("^lw%-describe%-(%x+)%.txt$")
        if h and is_hex(h, 16, 64) then consider(items, ctx, dir, n, "file", "editor buffer", M.AGE.editor) end
        if vcvars then
            local arch, tok = n:match("^lw_vcvars_([%w_]+)_(%x+)%.bat$")
            if arch and #tok == 16 and valid_arch(arch) then
                consider(items, ctx, dir, n, "file", "vcvars probe", M.AGE.vcvars)
            end
        end
        ::continue::
    end
end

--- Does the socket at `path` refuse a connection? Waits at most `ms`.
local function refuses(path, ms)
    local pipe = uv().new_pipe(false)
    if not pipe then return false end
    local res
    local ok = pcall(function()
        pipe:connect(path, function(err) res = err or "connected" end)
    end)
    if ok then vim.wait(ms, function() return res ~= nil end, 10) end
    pcall(function() if not pipe:is_closing() then pipe:close() end end)
    return type(res) == "string" and res:match("ECONNREFUSED") ~= nil
end
M._refuses = refuses

--- Remove a stale socket: move it aside, check it is the file tested (same
--- inode), else put it back (spec §16.40 rule 5).
local function remove_socket(item)
    local aside = item.path .. ".reclaim." .. M.nonce()
    local ok, err = uv().fs_rename(item.path, aside)
    if not ok then return false, tostring(err) end
    if M._after_aside then M._after_aside(item, aside) end -- test seam
    local st = uv().fs_lstat(aside)
    -- Same file as tested: inode and device (an inode number can be reused
    -- at once), and its modification time unchanged (a fresh bind has a new
    -- one).
    local o = item._st
    local same = st and st.type == "socket" and st.ino == o.ino and st.dev == o.dev
        and st.mtime and o.mtime and st.mtime.sec == o.mtime.sec and st.mtime.nsec == o.mtime.nsec
    if same then
        local uok, uerr = uv().fs_unlink(aside)
        if uok then return true end
        return false, tostring(uerr)
    end
    -- A daemon bound the name meanwhile: put its socket back. If the name is
    -- taken again already, the moved socket is left where it is (it may be a
    -- live daemon's endpoint), never unlinked; a later pass tests it like
    -- any other.
    if not uv().fs_lstat(item.path) and uv().fs_rename(aside, item.path) then
        return false, "a daemon bound it meanwhile; put back"
    end
    return false, "a daemon bound it meanwhile; left at " .. aside
end

--- The root hashes of every workspace daemon running on this host, by a
--- process scan (loomworks.daemon.discover, spec §19.6.1), or nil when the
--- scan fails or finds a daemon whose root is unknown (then no socket is
--- probed at all). A running daemon's socket is never connected to.
local function live_daemon_hashes()
    local ok, found = pcall(function() return (require("loomworks.daemon.discover").scan()) end)
    if not ok or type(found) ~= "table" then return nil end
    local dpaths = require("loomworks.daemon.paths")
    local set = {}
    for _, d in ipairs(found) do
        if not d.root then return nil end
        set[dpaths.root_hash(d.root)] = true
    end
    return set
end

local function scan_run_dir(items, ctx, dir)
    local st = uv().fs_lstat(dir)
    if not st or st.type ~= "directory" then return end
    local me = (uv().getuid and uv().getuid()) or -1
    if type(st.uid) ~= "number" or st.uid ~= me then return end
    if not st.mode or (st.mode % 512) ~= tonumber("700", 8) then return end
    for _, n in ipairs(names(dir)) do
        local h = n:match("^(%x+)%.sock$") or n:match("^(%x+)%.sock%.reclaim%.%x+$")
        local aside = n:match("%.reclaim%.%x+$") ~= nil
        if h and #h == 16 then
            local p = dir .. "/" .. n
            local sst = uv().fs_lstat(p)
            if sst and sst.type == "socket" and sst.uid == me and ctx.now - mtime(sst) >= M.AGE.socket then
                if ctx.live_hashes == nil then ctx.live_hashes = live_daemon_hashes() or false end
                if not ctx.live_hashes or ctx.live_hashes[h] then
                    -- a running daemon's (or unknown): never probed, never removed
                elseif ctx.socket_ms > 0 then
                    local t0 = uv().hrtime()
                    local refused = refuses(p, math.min(500, ctx.socket_ms))
                    ctx.socket_ms = ctx.socket_ms - math.floor((uv().hrtime() - t0) / 1e6)
                    if refused then
                        consider(items, ctx, dir, n, "socket", "socket", M.AGE.socket,
                            { remove = (not aside) and remove_socket or nil })
                    end
                end
            end
        end
    end
end

--- The running executable when it is an `lw` host (the standalone host, not
--- a bare luvi runtime running a source tree), else nil: only then are
--- `<exe>.old` / `<exe>.new` self-update leftovers of ours (§16.32). The
--- editor-hosted fallback (nvim) has none.
--- @return string|nil
function M.lw_host_exe()
    if not vim._loomworks_shim then return nil end
    local ok, p = pcall(uv().exepath)
    if not ok or type(p) ~= "string" or p == "" then return nil end
    local base = (norm(p):match("([^/]+)$") or ""):lower():gsub("%.exe$", "")
    if base == "luvi" then return nil end
    return norm(p)
end

--- `<exe>.old` / `<exe>.new` beside the running `lw` host.
local function scan_exe(items, ctx, exe)
    exe = norm(exe)
    local dir, base = exe:match("^(.*)/([^/]+)$")
    if not dir or not fixed(dir) then return end
    -- Only Windows renames the running binary aside (§16.32); elsewhere a
    -- `<exe>.old` is the user's own (a rollback copy) and stays.
    if ctx.is_windows then consider(items, ctx, dir, base .. ".old", "file", "self-update", 0) end
    consider(items, ctx, dir, base .. ".new", "file", "self-update", M.AGE.transient)
end

--- The workspace's `.nvim/tmp` leftovers.
local function scan_workspace_tmp(items, ctx, root)
    root = norm(root)
    local rroot = realkey(root)
    if not rroot then return end
    if not fixed(root .. "/.nvim", rroot .. "/.nvim") then return end
    local dir = root .. "/.nvim/tmp"
    if not fixed(dir, rroot .. "/.nvim/tmp") then return end
    for _, n in ipairs(names(dir)) do
        local h = n:match("^lw%-test%-(%x+)%.xml$")
        if h and is_hex(h, 16, 64) then consider(items, ctx, dir, n, "file", "test results", M.AGE.results) end
        h = n:match("^lw%-describe%-(%x+)%.txt$")
        if h and is_hex(h, 16, 64) then consider(items, ctx, dir, n, "file", "editor buffer", M.AGE.editor) end
    end
end

--- Find what housekeeping (or `lw cleanup`) would remove (spec §16.40).
--- Never raises for a missing or odd directory: it is just skipped.
--- @param opts? loomworks.HousekeepingOpts
--- @return loomworks.HousekeepingItem[] items, { kept_pinned: integer, pinned: boolean } info
function M.collect(opts)
    opts = opts or {}
    local ctx = {
        now = opts.now or os.time(),
        all = opts.all and true or false,
        pinned_age = opts.pinned_age or (opts.all and M.PINNED_DEFAULT or nil),
        kept_pinned = 0,
        running = {},
        socket_ms = M.SOCKET_BUDGET_MS,
        is_windows = opts.is_windows,
        uid = opts.uid,
        live_hashes = opts.live_daemon_hashes,
    }
    if ctx.is_windows == nil then ctx.is_windows = IS_WIN end
    if ctx.uid == nil then ctx.uid = (uv().getuid and uv().getuid()) or -1 end
    local items = {}
    local function guarded(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then ctx.errors = (ctx.errors or 0) + 1; ctx.last_error = err end
    end

    if ctx.pinned_age then
        local pv = opts.pin_version
        if pv == nil then pv = current_pin_version() end
        ctx.pin_version = pv or nil
        local exe = opts.exe
        if exe == nil then local ok, p = pcall(uv().exepath); exe = ok and p or nil end
        local bundle = opts.bundle
        if bundle == nil then bundle = running_bundle() end
        for _, p in ipairs({ exe or false, bundle or false }) do
            if p then ctx.running[#ctx.running + 1] = realkey(p) or key(p) end
        end
    end

    local data = norm(opts.data or default_data())
    local dst = uv().fs_stat(data)
    local rdata = dst and dst.type == "directory" and M.is_lw_data(data) and realkey(data) or nil
    if rdata then
        guarded(scan_data, items, ctx, data)
        local pinned = data .. "/pinned"
        local rpinned = fixed(pinned, rdata .. "/pinned")
        if rpinned then guarded(scan_pinned, items, ctx, pinned, rpinned) end
        local mods = data .. "/modules"
        if fixed(mods, rdata .. "/modules") then guarded(scan_modules, items, ctx, mods) end
        local dl_default = opts.device_lock_dir_default
        if dl_default == nil then
            local o = os.getenv("LOOMWORKS_DEVICE_LOCK_DIR")
            dl_default = not o or o == ""
        end
        local locks = data .. "/device-locks"
        if dl_default and fixed(locks, rdata .. "/device-locks") then
            guarded(scan_device_locks, items, ctx, locks)
        end
        local logs = data .. "/daemon/logs"
        if fixed(data .. "/daemon", rdata .. "/daemon") and fixed(logs, rdata .. "/daemon/logs") then
            guarded(scan_legacy_logs, items, ctx, logs)
        end
    end
    for _, t in ipairs(opts.tmp_dirs or default_tmp_dirs()) do
        if fixed(t) then guarded(scan_tmp, items, ctx, norm(t), ctx.is_windows) end
    end
    if opts.sockets ~= false and not IS_WIN then
        for _, d in ipairs(opts.run_dirs or default_run_dirs()) do guarded(scan_run_dir, items, ctx, d) end
    end
    local exe = opts.exe
    if exe == nil then exe = M.lw_host_exe() end
    if exe then guarded(scan_exe, items, ctx, exe) end
    if opts.root then guarded(scan_workspace_tmp, items, ctx, opts.root) end

    -- One entry per path (a temp dir listed twice, …).
    local seen, out = {}, {}
    for _, it in ipairs(items) do
        local k = key(it.path)
        if not seen[k] then seen[k] = true; out[#out + 1] = it end
    end
    return out, { kept_pinned = ctx.kept_pinned, pinned = ctx.pinned_age ~= nil,
        pinned_age = ctx.pinned_age, errors = ctx.errors, last_error = ctx.last_error }
end

--- Remove a tree: links unlinked as links (never followed), directories
--- emptied then removed. A read-only file is made writable before a retry
--- only when it has a single link: the attribute belongs to the file, so
--- clearing it through a hard link would change the other name's file too.
--- @param path string
--- @return boolean ok, string|nil err
function M._rm_tree(path)
    local st = uv().fs_lstat(path)
    if not st then return true end
    if st.type == "directory" then
        local errs = {}
        for _, n in ipairs(names(path)) do
            local ok, e = M._rm_tree(path .. "/" .. n)
            if not ok then errs[#errs + 1] = e end
        end
        local ok, e = uv().fs_rmdir(path)
        if not ok then errs[#errs + 1] = "rmdir " .. path .. ": " .. tostring(e) end
        if #errs > 0 then return false, table.concat(errs, "; ") end
        return true
    end
    local ok, e = uv().fs_unlink(path)
    if ok then return true end
    if st.type == "link" and uv().fs_rmdir(path) then return true end -- a directory link / junction
    if st.type == "file" and (st.nlink or 1) <= 1
            and (tostring(e):match("^EPERM") or tostring(e):match("^EACCES")) then
        pcall(uv().fs_chmod, path, tonumber("644", 8))
        ok, e = uv().fs_unlink(path)
        if ok then return true end
    end
    return false, "unlink " .. path .. ": " .. tostring(e)
end

--- Remove one collected item, re-checking it first (still the same type, not
--- a link, still old enough). A path gone by the end counts as removed (a
--- concurrent remover).
--- @param item loomworks.HousekeepingItem
--- @param now? integer
--- @return boolean ok, string|nil err
function M.remove(item, now)
    local st = uv().fs_lstat(item.path)
    if not st then return true end
    if st.type ~= item.type then return false, "changed meanwhile" end
    local age = (now or os.time()) - mtime(st)
    if age < (item._min_age or 0) then return false, "changed meanwhile" end
    local ok, err
    if item.remove then
        ok, err = item.remove(item)
    else
        ok, err = M._rm_tree(item.path)
    end
    if not uv().fs_lstat(item.path) then return true end
    if ok then return true end
    return false, tostring(err or "not removed")
end

-- ---------------------------------------------------------------------------
-- The startup pass
-- ---------------------------------------------------------------------------

--- Record the last use of the pinned release this process runs (spec
--- §16.40), bundle-side, so one run by a host that does not record it (an
--- older host) is not pruned as unused: the running bundle root and the
--- running executable get the current time as their modification time, only
--- when they resolve to `<data>/pinned/<sha256>/lua-<ver>` /
--- `<data>/pinned/lw-<ver>-<asset>` (separator-bounded). Never raises.
--- @param opts? { data?: string, bundle?: string|false, exe?: string|false, now?: integer }
function M.touch_running(opts)
    opts = opts or {}
    pcall(function()
        local data = norm(opts.data or default_data())
        local rpinned = realkey(data .. "/pinned")
        if not rpinned then return end
        local now = opts.now or os.time()
        local function rel_of(p)
            local k = p and realkey(p)
            if k and k:sub(1, #rpinned + 1) == rpinned .. "/" then return k:sub(#rpinned + 2) end
            return nil
        end
        local bundle = opts.bundle
        if bundle == nil then bundle = running_bundle() end
        local exe = opts.exe
        if exe == nil then local ok, p = pcall(uv().exepath); exe = ok and p or nil end
        local rb = bundle and rel_of(bundle)
        local sha, v = nil, nil
        if rb then sha, v = rb:match("^(%x+)/lua%-([^/]+)$") end
        if sha and is_sha(sha) and release_version(v) then pcall(uv().fs_utime, bundle, now, now) end
        local re = exe and rel_of(exe)
        if re and not re:find("/", 1, true) and pinned_binary_version(re, host_assets()) then
            pcall(uv().fs_utime, exe, now, now)
        end
    end)
end

--- Claim the day's pass: false when one ran within `M.INTERVAL`. Sets the
--- stamp's modification time (creating it exclusively when missing).
local function claim(data, now)
    local stamp = data .. "/" .. M.STAMP
    local st = uv().fs_lstat(stamp)
    if st then
        if st.type ~= "file" then return false end
        local m = mtime(st)
        -- A stamp well in the future (the clock moved back) does not hold
        -- the pass off; a few minutes of skew do.
        if m <= now + 300 and now - m < M.INTERVAL then return false end
        return uv().fs_utime(stamp, now, now) and true or false
    end
    local fd = uv().fs_open(stamp, "wx", tonumber("644", 8))
    if not fd then return false end
    uv().fs_close(fd)
    pcall(uv().fs_utime, stamp, now, now)
    return true
end

--- Set the stamp (after `lw cleanup --yes`).
local function touch_stamp(data, now)
    local stamp = data .. "/" .. M.STAMP
    local st = uv().fs_lstat(stamp)
    if st and st.type == "file" then pcall(uv().fs_utime, stamp, now, now); return end
    if not st then
        local fd = uv().fs_open(stamp, "wx", tonumber("644", 8))
        if fd then uv().fs_close(fd) end
    end
end

--- The housekeeping pass at the start of a CLI command (spec §16.40): at most
--- once per `M.INTERVAL` per user, silent, never raises. A summary line goes
--- to the workspace's runtime log when there is a workspace and the pass
--- removed something or failed to.
--- @param root string|nil the workspace root, if any
--- @param opts? loomworks.HousekeepingOpts
--- @return integer|nil removed, integer|nil failed (nil when the pass did not run)
function M.startup(root, opts)
    opts = opts or {}
    -- The test suites set this so a spawned lw never touches the machine's
    -- temp and socket directories (spec §16.40).
    if not opts.force and os.getenv("LOOMWORKS_NO_HOUSEKEEPING") == "1" then return nil end
    local removed, failed, bytes, err_text
    local ok, err = pcall(function()
        local data = norm(opts.data or default_data())
        local dst = uv().fs_stat(data)
        if not dst or dst.type ~= "directory" or not M.is_lw_data(data) then return end
        local now = opts.now or os.time()
        if not claim(data, now) then return end
        local o = {}
        for k, v in pairs(opts) do o[k] = v end
        o.root, o.data, o.now, o.all, o.pinned_age = root, data, now, false, nil
        local items, info = M.collect(o)
        removed, failed, bytes = 0, 0, 0
        for _, it in ipairs(items) do
            local rok, rerr = M.remove(it, now)
            if rok then
                removed, bytes = removed + 1, bytes + (it.size or 0)
            else
                failed = failed + 1
                err_text = it.path .. ": " .. tostring(rerr)
            end
        end
        if info.errors then failed = failed + info.errors; err_text = err_text or tostring(info.last_error) end
    end)
    if not ok then failed, err_text = (failed or 0) + 1, tostring(err) end
    if root and ((removed or 0) > 0 or (failed or 0) > 0) then
        pcall(function()
            require("loomworks.daemon.rlog").write(root, string.format(
                "housekeeping: removed %d leftover(s) of interrupted lw runs outside the workspace (%s)%s",
                removed or 0, M.size_text(bytes or 0),
                (failed or 0) > 0 and ("; " .. failed .. " not removed, e.g. " .. tostring(err_text)) or ""))
        end)
    end
    return removed, failed
end

-- ---------------------------------------------------------------------------
-- `lw cleanup`
-- ---------------------------------------------------------------------------

--- "512 B", "4.0 KB", "11.9 MB".
--- @param n integer
--- @return string
function M.size_text(n)
    n = tonumber(n) or 0
    if n < 1024 then return string.format("%d B", n) end
    local units = { "KB", "MB", "GB", "TB" }
    local v, i = n / 1024, 1
    while v >= 1024 and i < #units do v, i = v / 1024, i + 1 end
    return string.format("%.1f %s", v, units[i])
end

--- "45 s", "12 min", "5 hours", "3 days".
--- @param s integer
--- @return string
function M.age_text(s)
    s = tonumber(s) or 0
    if s < 120 then return string.format("%d s", s) end
    if s < 2 * HOUR then return string.format("%d min", math.floor(s / 60)) end
    if s < 2 * DAY then return string.format("%d hours", math.floor(s / HOUR)) end
    return string.format("%d days", math.floor(s / DAY))
end

--- Parse `--pinned-older-than`: seconds, or a whole number with s/m/h/d.
--- @param v any
--- @return integer|nil
function M.parse_duration(v)
    if type(v) ~= "string" then return nil end
    local n, unit = v:match("^(%d+)([smhd]?)$")
    n = tonumber(n)
    if not n or n <= 0 then return nil end
    return n * (({ s = 1, m = 60, h = HOUR, d = DAY })[unit] or 1)
end

--- Parse the `lw cleanup` arguments (args[1] is "cleanup"). Returns the
--- options, or nil + the usage error.
--- @param args string[]
--- @return table|nil opts, string|nil err
function M.parse_args(args)
    local o = { yes = false, dry = false, all = false }
    local i = 2
    while i <= #args do
        local v = args[i]
        if v == "--yes" or v == "-y" then o.yes = true
        elseif v == "--dry-run" then o.dry = true
        elseif v == "--all" then o.all = true
        elseif v == "--pinned-older-than" or v:sub(1, 20) == "--pinned-older-than=" then
            local val = v:sub(21)
            if v == "--pinned-older-than" then i = i + 1; val = args[i] end
            if val == nil or val == "" then return nil, "--pinned-older-than needs a duration (e.g. 90d)" end
            o.pinned_age = M.parse_duration(val)
            if not o.pinned_age then
                return nil, "invalid duration '" .. tostring(val) .. "' for --pinned-older-than: "
                    .. "a whole number with s, m, h or d (e.g. 90d, 12h), or seconds"
            end
        else
            return nil, "unexpected argument '" .. tostring(v) .. "'"
        end
        i = i + 1
    end
    if o.yes and o.dry then return nil, "--dry-run and --yes cannot be combined" end
    return o
end

--- `lw cleanup [--dry-run | --yes] [--all] [--pinned-older-than <dur>]`
--- (spec §16.40).
--- @param root string|nil the workspace root (its `.nvim/tmp`)
--- @param args string[] argv (args[1] = "cleanup")
--- @param host { out: fun(s: string), die: fun(msg: string, code?: integer) }
--- @param opts? loomworks.HousekeepingOpts test seams
--- @return integer exit code
function M.cmd(root, args, host, opts)
    local o, err = M.parse_args(args)
    if not o then
        host.die(err .. " - usage: lw cleanup [--dry-run | --yes] [--all] [--pinned-older-than <duration>]", 2)
        return 2
    end
    local c = {}
    for k, v in pairs(opts or {}) do c[k] = v end
    c.root, c.all, c.pinned_age = root, o.all, o.pinned_age
    local now = c.now or os.time()
    c.now = now
    local items, info = M.collect(c)
    table.sort(items, function(a, b) return a.path < b.path end)
    local out = host.out
    local kw = 4
    for _, it in ipairs(items) do kw = math.max(kw, #it.kind) end
    local function row(prefix, it)
        return string.format("%s%-" .. kw .. "s  %s  %s, %s old", prefix, it.kind, it.path,
            M.size_text(it.size), M.age_text(it.age))
    end
    local kept = info.pinned and string.format(
        "Kept %d pinned release file%s (pinned by this repository, running, or used within %s).",
        info.kept_pinned, info.kept_pinned == 1 and "" or "s", M.age_text(info.pinned_age)) or nil
    if #items == 0 then
        out("lw cleanup: nothing to clean up.")
        if kept then out(kept) end
        if not info.pinned then out("(`--all` also prunes pinned releases unused for 30 days.)") end
        return 0
    end
    local total = 0
    for _, it in ipairs(items) do total = total + (it.size or 0) end
    if not o.yes then
        out("lw cleanup: dry run - nothing is removed. Left behind outside the workspace:")
        for _, it in ipairs(items) do out(row("  ", it)) end
        out(string.format("%d item%s, %s. Remove them with: lw cleanup --yes%s", #items,
            #items == 1 and "" or "s", M.size_text(total), o.all and " --all" or ""))
        if kept then out(kept) end
        return 0
    end
    local removed, bytes, failures = 0, 0, 0
    for _, it in ipairs(items) do
        local ok, rerr = M.remove(it, now)
        if ok then
            removed, bytes = removed + 1, bytes + (it.size or 0)
            out(row("removed  ", it))
        else
            failures = failures + 1
            out(string.format("FAILED   %s  %s: %s", it.kind, it.path, tostring(rerr)))
        end
    end
    local data = norm(c.data or default_data())
    local dst = uv().fs_stat(data)
    if dst and dst.type == "directory" then pcall(touch_stamp, data, now) end
    out(string.format("Removed %d of %d item%s (%s).", removed, #items, #items == 1 and "" or "s",
        M.size_text(bytes)))
    if kept then out(kept) end
    return failures > 0 and 1 or 0
end

return M
