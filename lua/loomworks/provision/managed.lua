--- loomworks/provision/managed.lua — the plugin-managed `lw` host binary
--- under the editor's data directory (spec §19.16 "Host binary").
---
--- Everything the plugin installs lives under `<stdpath("data")>/loomworks/`
--- (spec §19.16 "Install location"). Host binaries are content-addressed:
---
---     <stdpath("data")>/loomworks/lw/<sha256>/lw        (lw.exe on Windows)
---
--- `<sha256>` is the binary's lowercase hex SHA-256: a versioned path, so a
--- binary is never replaced in place (a running daemon keeps its file). The
--- wanted binary (release version, asset, SHA-256) comes from the plugin's
--- own pin, loomworks.provision.pinned (spec §19.16 "Plugin pin", written
--- only by scripts/release/pin.sh from a verified release), or — with the
--- setup option `binary.channel` — the newer accepted channel release
--- (loomworks.provision.channel, §19.16 "Channel upgrades", step 5h.5). A
--- wanted binary that is not installed is downloaded by
--- loomworks.provision.fetch (daemon mode only).

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- @class loomworks.provision.Pin  the plugin pin (loomworks.provision.pinned, generated)
--- @field version string the pinned release version
--- @field assets table<string, string> host asset name -> lowercase hex SHA-256

--- The reason shown when the plugin's pin names no binary at all.
M.NOT_YET = "none wanted (the plugin carries no pin)"

--- The published host-binary assets, keyed by "<os>/<arch>": the plugin's
--- own copy of lw's table (boot.pin.HOST_ASSETS is binary-side; a test keeps
--- the two equal). A platform absent here has no plugin-managed lw.
M.HOST_ASSETS = {
    ["linux/x86_64"] = "lw-linux-x86_64",
    ["macos/arm64"] = "lw-macos-arm64",
    ["windows/x86_64"] = "lw-windows-x86_64.exe",
}

local function norm_os(sysname)
    local s = type(sysname) == "string" and sysname:lower() or ""
    if s:find("linux", 1, true) then return "linux" end
    if s:find("darwin", 1, true) or s:find("mac", 1, true) then return "macos" end
    if s:find("windows", 1, true) or s:find("mingw", 1, true) or s:find("msys", 1, true)
        or s:find("cygwin", 1, true) then
        return "windows"
    end
    return nil
end

local function norm_arch(machine)
    local m = type(machine) == "string" and machine:lower() or nil
    if m == "x86_64" or m == "amd64" or m == "x64" then return "x86_64" end
    if m == "arm64" or m == "aarch64" then return "arm64" end
    return m
end

--- The host asset for (sysname, machine) (uname values; this host's when
--- both are nil), or nil + why for a platform with no published binary.
--- @param sysname? string
--- @param machine? string
--- @return string|nil asset, string|nil why
function M.host_asset(sysname, machine)
    if sysname == nil and machine == nil then
        local ok, u = pcall(uv.os_uname)
        if ok and type(u) == "table" then sysname, machine = u.sysname, u.machine end
        if sysname == nil and is_win() then sysname = "Windows" end
    end
    local os_, arch = norm_os(sysname), norm_arch(machine)
    local asset = os_ and M.HOST_ASSETS[os_ .. "/" .. tostring(arch)]
    if not asset then
        return nil, "none wanted (no published lw for " .. tostring(os_ or sysname) .. "/" .. tostring(arch) .. ")"
    end
    return asset
end

--- The editor's data directory for loomworks (`<stdpath("data")>/loomworks`).
--- @param data? string the editor's data directory (tests inject)
--- @return string
function M.root(data)
    data = data or vim.fn.stdpath("data")
    return (tostring(data):gsub("\\", "/"):gsub("/+$", "")) .. "/loomworks"
end

--- The directory holding the managed host binaries.
--- @param data? string
--- @return string
function M.dir(data) return M.root(data) .. "/lw" end

--- The file name of a host binary on this platform.
--- @param win? boolean (tests inject)
--- @return string
function M.exe_name(win)
    if win == nil then win = is_win() end
    return win and "lw.exe" or "lw"
end

--- The path a managed host binary of `sha256` has, or nil for a value that is
--- not 64 hex digits (never a path from an unchecked string).
--- @param sha256 string
--- @param opts? { data?: string, win?: boolean }
--- @return string|nil
function M.path(sha256, opts)
    opts = opts or {}
    if type(sha256) ~= "string" or not sha256:match("^%x+$") or #sha256 ~= 64 then return nil end
    return M.dir(opts.data) .. "/" .. sha256:lower() .. "/" .. M.exe_name(opts.win)
end

--- The managed binary the plugin wants: this host's asset of the plugin pin
--- (loomworks.provision.pinned), or nil + why (an unsupported platform, a pin
--- without this host's asset, an invalid pin). With `opts.setting` naming a
--- `binary.channel` that applies, the accepted channel release when it is
--- newer than the pin (never below the pin; loomworks.provision.channel).
--- Tests inject `pinned`, `sysname`, `machine` and `channel` (replaces
--- loomworks.provision.channel.accepted).
--- @param opts? { pinned?: loomworks.provision.Pin, sysname?: string, machine?: string, setting?: loomworks.provision.BinarySetting, data?: string, channel?: fun(setting: table, asset: string): loomworks.provision.Wanted|nil }
--- @return loomworks.provision.Wanted|nil wanted, string|nil why
function M.wanted(opts)
    opts = opts or {}
    local w, why = M.pinned_wanted(opts)
    if not w or type(opts.setting) ~= "table" or opts.setting.channel == nil then return w, why end
    local chan = require("loomworks.provision.channel")
    local acc = (opts.channel or function(s, a) return chan.accepted(s, a, { data = opts.data }) end)(opts.setting, w.asset)
    if acc and acc.asset == w.asset and chan.compare(acc.version, w.version) > 0 then return acc end
    return w
end

--- The plugin pin's binary for this host (`wanted` without the channel).
--- @param opts? { pinned?: loomworks.provision.Pin, sysname?: string, machine?: string }
--- @return loomworks.provision.Wanted|nil wanted, string|nil why
function M.pinned_wanted(opts)
    opts = opts or {}
    local pin = opts.pinned
    if pin == nil then
        local ok, p = pcall(require, "loomworks.provision.pinned")
        pin = ok and p or nil
    end
    if type(pin) ~= "table" or type(pin.assets) ~= "table" then return nil, M.NOT_YET end
    local asset, why = M.host_asset(opts.sysname, opts.machine)
    if not asset then return nil, why end
    local sha = pin.assets[asset]
    if sha == nil then return nil, "none wanted (the plugin pin has no " .. asset .. ")" end
    local w, bad = require("loomworks.provision.fetch").check_wanted({ sha256 = sha, version = pin.version, asset = asset })
    if not w then return nil, "none wanted (invalid plugin pin: " .. tostring(bad) .. ")" end
    return w
end

--- A regular file, not a link (lstat): a link in a slot is never launched
--- unhashed.
local function is_file(p)
    local st = p and uv.fs_lstat(p)
    return st ~= nil and st.type == "file"
end

--- Binaries hashed in this process: `path` -> "<sha256>|<size>|<mtime>" of
--- the file that matched (a changed file is hashed again).
--- @type table<string, string>
M._verified = {}

local function stamp(path, sha256)
    local st = uv.fs_lstat(path)
    if not st or st.type ~= "file" then return nil end
    return sha256:lower() .. "|" .. tostring(st.size) .. "|" .. tostring(st.mtime and st.mtime.sec) .. "."
        .. tostring(st.mtime and st.mtime.nsec)
end

--- Record that `path` holds `sha256` (it was just verified, e.g. installed).
--- @param path string
--- @param sha256 string
function M.verified(path, sha256)
    M._verified[path] = stamp(path, sha256)
end

--- Whether the managed binary at `path` (a regular file) has SHA-256
--- `sha256`. Hashed once per process (~65 ms) before its first use, again
--- only when the file changed; a mismatch is never cached.
--- @param path string
--- @param sha256 string
--- @param opts? { hash?: fun(p: string): string|nil, string|nil }
--- @return boolean ok, string|nil why, "unreadable"|"mismatch"|nil kind
function M.verify(path, sha256, opts)
    opts = opts or {}
    local key = stamp(path, sha256)
    if not key then return false, path .. " is not a regular file" end
    if M._verified[path] == key then return true end
    local got, err = (opts.hash or require("loomworks.provision.sha256").file)(path)
    if not got then return false, tostring(err), "unreadable" end
    if got:lower() ~= sha256:lower() then
        return false, path .. " has SHA-256 " .. got:lower() .. ", expected " .. sha256:lower(), "mismatch"
    end
    M._verified[path] = key
    return true
end

--- Seconds between two last-use marks of one slot (a selection on every
--- status render costs no write).
M.TOUCH_EVERY_S = 3600

--- Mark the managed binary at `path` used now: its slot directory's mtime is
--- its last use, which pruning (loomworks.provision.cache) honours. A no-op
--- (false) for any path that is not `<dir>/<64 hex>/lw[.exe]` of this
--- editor's managed directory, as spelled or as resolved (realpath: a
--- linked data directory).
--- @param path string|nil
--- @param opts? { data?: string, win?: boolean, now?: integer }
--- @return boolean marked
function M.touch(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or path == "" then return false end
    local p = path:gsub("\\", "/")
    local slot, sha, name = p:match("^(.*/(%x+))/([^/]+)$")
    if not slot or name ~= M.exe_name(opts.win) or #sha ~= 64 or sha ~= sha:lower() then return false end
    local win = opts.win
    if win == nil then win = is_win() end
    local function norm(s)
        s = s:gsub("\\", "/"):gsub("/+$", "")
        return win and s:lower() or s
    end
    -- The slot must be a direct child of the managed directory as spelled
    -- or as resolved: a daemon reports uv.exepath(), which follows a linked
    -- data directory (separator-bounded, exactly one segment below).
    local function under(prefix)
        prefix = norm(prefix)
        local s = norm(slot)
        return s:sub(1, #prefix + 1) == prefix .. "/" and s:sub(#prefix + 2) == sha
    end
    local dir = M.dir(opts.data)
    local real = uv.fs_realpath(dir)
    if not under(dir) and not (real and under(real)) then return false end
    local st = uv.fs_lstat(slot)
    if not st or st.type ~= "directory" then return false end
    local now = opts.now or os.time()
    if st.mtime and now - st.mtime.sec < M.TOUCH_EVERY_S and now >= st.mtime.sec then return true end
    return uv.fs_utime(slot, now, now) and true or false
end

--- The managed host binary when it is already present, or nil + why (+ the
--- wanted record when it is only not installed yet, or corrupt — `corrupt =
--- true`: it can be downloaded; `unreadable = true` too when hashing it failed
--- to read it rather than found another hash). Present means a regular file (lstat) whose
--- SHA-256 matches (`verify`, once per process); one that is found is marked
--- used (`touch`). `opts.wanted` returns a `loomworks.provision.Wanted`
--- record or a bare hash. Tests inject `exists` (a fake file system: no
--- hashing or marking unless `verify` / `touch` are injected too).
--- `opts.setting` (the setup option `binary`) lets the default `wanted`
--- weigh `binary.channel`.
--- @param opts? { data?: string, win?: boolean, setting?: loomworks.provision.BinarySetting, wanted?: fun(): (loomworks.provision.Wanted|string|nil), string|nil, exists?: fun(path: string): boolean, verify?: fun(path: string, sha256: string): boolean, string|nil, touch?: fun(path: string, opts: table) }
--- @return string|nil path, string|nil why, loomworks.provision.Wanted|nil missing
function M.find(opts)
    opts = opts or {}
    local want, why
    if opts.wanted then want, why = opts.wanted()
    else want, why = M.wanted({ setting = opts.setting, data = opts.data }) end
    if not want then return nil, why or M.NOT_YET end
    local sha = type(want) == "table" and want.sha256 or want
    local p = M.path(sha, opts)
    if not p then return nil, "invalid hash " .. tostring(sha) end
    local record = type(want) == "table" and want or nil
    if not (opts.exists or is_file)(p) then
        return nil, "not installed (" .. p .. ")", record
    end
    local verify = opts.verify or (opts.exists == nil and M.verify) or nil
    if verify then
        local ok, vwhy, kind = verify(p, sha)
        if not ok then
            -- A read error (e.g. the file is locked) is not a mismatch, but
            -- neither can be launched unhashed: both are downloaded again.
            local unreadable = kind == "unreadable" or nil
            local again = record and vim.tbl_extend("force", record, { corrupt = true, unreadable = unreadable }) or nil
            return nil, (unreadable and "could not be read, not launched (" or "corrupt, not launched (")
                .. tostring(vwhy) .. ")", again
        end
    end
    local touch = opts.touch or (opts.exists == nil and M.touch) or nil
    if touch then pcall(touch, p, { data = opts.data, win = opts.win }) end
    return p
end

return M
