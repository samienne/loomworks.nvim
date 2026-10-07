--- loomworks/provision/cache.lua — pruning the plugin-managed host binaries
--- (spec §19.16 "Host binary", step 5h.3). DELETION CODE: see CLAUDE.md
--- "Deletion Safety", rule 11.
---
--- `<stdpath("data")>/loomworks/lw/` holds one `<sha256>/lw[.exe]` per
--- binary the plugin installed. Pruning keeps the wanted hash and removes the
--- others, one regular file and then its (then empty) directory, never
--- recursively, and only:
---   * when a binary is wanted (nothing is pruned without one) and no download
---     runs in this editor;
---   * entries whose whole name is exactly 64 lowercase hex digits, that are
---     real directories (lstat: a link or junction is skipped, never followed)
---     whose realpath is a direct child of the realpath of `.../loomworks/lw`
---     (separator-bounded), which itself must be a real directory;
---   * whose only content is the regular file `lw` or `lw.exe` — anything else
---     and the entry is left alone;
---   * never the binary of a daemon this editor launched or observes, nor one
---     a caller names as in use (a failed unlink — Windows: running — skips).
--- A partial download a crashed editor left (`<sha256>.<pid>.dl`, a regular
--- file) is removed once it is a day old and not this process's.

local uv = vim.uv or vim.loop

local M = {}

--- Age (seconds) after which another process's partial download is stale.
M.STALE_DL_S = 24 * 3600

local function is_win() return package.config:sub(1, 1) == "\\" end

local function lstat_type(p)
    local st = uv.fs_lstat(p)
    return st and st.type or nil
end

--- A path for comparison: forward slashes, no trailing slash, lowercased on
--- Windows.
local function norm(p, win)
    p = (p:gsub("\\", "/"):gsub("/+$", ""))
    if win then p = p:lower() end
    return p
end

--- Whether `name` is a managed slot's name: exactly 64 lowercase hex digits.
--- @param name any
--- @return boolean
function M.is_slot_name(name)
    return type(name) == "string" and #name == 64 and name:match("^[0-9a-f]+$") ~= nil
end

--- The pid of a partial download's name (`<sha256>.<pid>.dl`), or nil.
--- @param name string
--- @return integer|nil
function M.partial_pid(name)
    local sha, pid = name:match("^(%x+)%.(%d+)%.dl$")
    if not sha or not M.is_slot_name(sha) then return nil end
    return tonumber(pid)
end

local function scandir(dir)
    local out = {}
    local h = uv.fs_scandir(dir)
    if not h then return nil end
    while true do
        local name = uv.fs_scandir_next(h)
        if not name then break end
        out[#out + 1] = name
    end
    return out
end

--- Prune the managed binaries. opts (tests inject):
---   data    the editor's data directory (default stdpath("data"))
---   keep    string[]  hashes to keep (the wanted one; required, non-empty)
---   in_use  string[]  binary paths in use (daemons launched or observed)
---   busy    boolean   a download runs (default: loomworks.provision.fetch)
---   now     integer   seconds (default os.time())
---   pid     integer   this process (default uv.os_getpid())
---   win     boolean   Windows path comparison
--- @param opts table
--- @return { removed: string[], skipped: table<string, string> } report, string|nil why nothing was done
function M.prune(opts)
    opts = opts or {}
    local report = { removed = {}, skipped = {} }
    local win = opts.win
    if win == nil then win = is_win() end
    local keep = {}
    for _, s in ipairs(opts.keep or {}) do
        if M.is_slot_name(type(s) == "string" and s:lower() or nil) then keep[s:lower()] = true end
    end
    if next(keep) == nil then return report, "no wanted binary" end
    local busy = opts.busy
    if busy == nil then
        busy = false
        for _, st in pairs(require("loomworks.provision.fetch").states) do
            if st.state == "downloading" then busy = true end
        end
    end
    if busy then return report, "a download is running" end

    local managed = require("loomworks.provision.managed")
    local dir = managed.dir(opts.data)
    if lstat_type(dir) ~= "directory" then return report, dir .. " is not a directory" end
    local real_dir = uv.fs_realpath(dir)
    if not real_dir then return report, "cannot resolve " .. dir end
    real_dir = norm(real_dir, win)

    -- In use: each binary path, and its realpath, as a comparable directory.
    local used = {}
    for _, p in ipairs(opts.in_use or {}) do
        if type(p) == "string" and p ~= "" then
            used[#used + 1] = norm(p, win)
            local r = uv.fs_realpath(p)
            if r then used[#used + 1] = norm(r, win) end
        end
    end
    local function in_use(slot_paths)
        for _, u in ipairs(used) do
            for _, s in ipairs(slot_paths) do
                if u == s or u:sub(1, #s + 1) == s .. "/" then return true end
            end
        end
        return false
    end

    local now = opts.now or os.time()
    local pid = opts.pid or uv.os_getpid()
    for _, name in ipairs(scandir(dir) or {}) do
        local child = dir .. "/" .. name
        local ppid = M.partial_pid(name)
        if ppid then
            local st = uv.fs_lstat(child)
            if not st or st.type ~= "file" then
                report.skipped[name] = "not a regular file"
            elseif ppid == pid then
                report.skipped[name] = "this editor's download"
            elseif now - (st.mtime and st.mtime.sec or now) < M.STALE_DL_S then
                report.skipped[name] = "recent"
            elseif uv.fs_unlink(child) then
                report.removed[#report.removed + 1] = child
            else
                report.skipped[name] = "cannot remove"
            end
        elseif not M.is_slot_name(name) then
            report.skipped[name] = "not a managed binary name"
        elseif keep[name] then
            report.skipped[name] = "wanted"
        elseif lstat_type(child) ~= "directory" then
            report.skipped[name] = "not a real directory"
        else
            local real = uv.fs_realpath(child)
            local nreal = real and norm(real, win)
            if nreal ~= real_dir .. "/" .. name then
                report.skipped[name] = "resolves outside " .. dir
            elseif in_use({ norm(child, win), nreal }) then
                report.skipped[name] = "in use"
            else
                local entries = scandir(child) or { "?" }
                local exe = entries[1]
                if #entries > 1 or (exe and exe ~= "lw" and exe ~= "lw.exe") then
                    report.skipped[name] = "unexpected content"
                elseif exe and lstat_type(child .. "/" .. exe) ~= "file" then
                    report.skipped[name] = "unexpected content"
                elseif exe and not uv.fs_unlink(child .. "/" .. exe) then
                    report.skipped[name] = "cannot remove (running?)"
                elseif not uv.fs_rmdir(child) then
                    report.skipped[name] = "cannot remove the directory"
                else
                    report.removed[#report.removed + 1] = child
                end
            end
        end
    end
    return report
end

return M
