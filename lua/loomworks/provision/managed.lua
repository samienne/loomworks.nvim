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
--- own pin (step 5h.4) or a channel upgrade (step 5h.5); until then nothing
--- is wanted and the slot is empty. A wanted binary that is not installed is
--- downloaded by loomworks.provision.fetch (step 5h.3, daemon mode only).

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- The reason shown while no managed binary is wanted (before step 5h.4's
--- plugin pin).
M.NOT_YET = "none wanted (the plugin carries no pin yet)"

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

--- The managed binary the plugin wants, or nil + why. Nothing yet (step
--- 5h.4 brings the plugin pin).
--- @return loomworks.provision.Wanted|nil wanted, string|nil why
function M.wanted()
    return nil, M.NOT_YET
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
--- @return boolean ok, string|nil why
function M.verify(path, sha256, opts)
    opts = opts or {}
    local key = stamp(path, sha256)
    if not key then return false, path .. " is not a regular file" end
    if M._verified[path] == key then return true end
    local got, err = (opts.hash or require("loomworks.provision.sha256").file)(path)
    if not got then return false, tostring(err) end
    if got:lower() ~= sha256:lower() then
        return false, path .. " has SHA-256 " .. got:lower() .. ", expected " .. sha256:lower()
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
--- editor's managed directory.
--- @param path string|nil
--- @param opts? { data?: string, win?: boolean, now?: integer }
--- @return boolean marked
function M.touch(path, opts)
    opts = opts or {}
    if type(path) ~= "string" or path == "" then return false end
    local p = path:gsub("\\", "/")
    local slot, sha, name = p:match("^(.*/(%x+))/([^/]+)$")
    if not slot or name ~= M.exe_name(opts.win) or #sha ~= 64 or sha ~= sha:lower() then return false end
    local want = M.dir(opts.data) .. "/" .. sha
    local win = opts.win
    if win == nil then win = is_win() end
    if (win and slot:lower() or slot) ~= (win and want:lower() or want) then return false end
    local st = uv.fs_lstat(slot)
    if not st or st.type ~= "directory" then return false end
    local now = opts.now or os.time()
    if st.mtime and now - st.mtime.sec < M.TOUCH_EVERY_S and now >= st.mtime.sec then return true end
    return uv.fs_utime(slot, now, now) and true or false
end

--- The managed host binary when it is already present, or nil + why (+ the
--- wanted record when it is only not installed yet, or corrupt — `corrupt =
--- true`: it can be downloaded). Present means a regular file (lstat) whose
--- SHA-256 matches (`verify`, once per process); one that is found is marked
--- used (`touch`). `opts.wanted` returns a `loomworks.provision.Wanted`
--- record or a bare hash. Tests inject `exists` (a fake file system: no
--- hashing or marking unless `verify` / `touch` are injected too).
--- @param opts? { data?: string, win?: boolean, wanted?: fun(): (loomworks.provision.Wanted|string|nil), string|nil, exists?: fun(path: string): boolean, verify?: fun(path: string, sha256: string): boolean, string|nil, touch?: fun(path: string, opts: table) }
--- @return string|nil path, string|nil why, loomworks.provision.Wanted|nil missing
function M.find(opts)
    opts = opts or {}
    local want, why = (opts.wanted or M.wanted)()
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
        local ok, vwhy = verify(p, sha)
        if not ok then
            local again = record and vim.tbl_extend("force", record, { corrupt = true }) or nil
            return nil, "corrupt, not launched (" .. tostring(vwhy) .. ")", again
        end
    end
    local touch = opts.touch or (opts.exists == nil and M.touch) or nil
    if touch then pcall(touch, p, { data = opts.data, win = opts.win }) end
    return p
end

return M
