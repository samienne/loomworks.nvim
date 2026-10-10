--- loomworks/daemon/rlog.lua — the runtime log (spec §19.10, §19.5).
---
--- One file per workspace, inside it: `<root>/.nvim/loomworks.daemon.log`
--- (spec §16.40), capped at `MAX_BYTES` with one rotated predecessor
--- (`.log.1`). The daemon writes its lifecycle there (start,
--- reclaimed locks, refused connections, stop reason); every client records
--- the launches it makes or fails, and every kill and forced unlock (§19.5).
---
--- Append-only, one whole line per write (opened and closed again, so no
--- process holds the file); several processes may append at once. A write
--- creates the log's directory (`.nvim/`) only when ITS parent (the workspace
--- root) exists — never the root itself, so a daemon whose workspace was
--- removed does not bring it back. Rotation is best-effort (a failed rename
--- just retries later), and removes only `<log>.1` — the one rotated
--- predecessor of this exact file.

local paths = require("loomworks.daemon.paths")

local M = {}

M.MAX_BYTES = 2 * 1024 * 1024

local function uv() return vim.uv or vim.loop end

--- The runtime log path of `root`.
--- @param root string
--- @return string
function M.path(root) return paths.log_path(root) end

--- Append one line (timestamp, pid, text) to the runtime log of `root`.
--- Never raises.
--- @param root string
--- @param line string
function M.write(root, line)
    M.write_path(M.path(root), line)
end

--- The start of every runtime-log line (`write_path`'s format).
local LINE_PAT = "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ pid %d+ "

--- Is the open file `fd` the file `st` (an lstat of its name) describes —
--- the same device and inode, a regular file? Guards the window between the
--- lstat and the open (a name swapped for a link or another file meanwhile).
local function same_file(fd, st)
    local fst = uv().fs_fstat(fd)
    return fst ~= nil and fst.type == "file" and fst.ino == st.ino and fst.dev == st.dev
end

--- Is the regular file `p` (lstat `st`) lw's runtime log: empty, or starting
--- with a runtime-log line? A file at the name that is not (one a repository
--- ships in `.nvim/`, say) is never written, rotated or removed.
local function ours(p, st)
    if (st.size or 0) == 0 then return true end
    local fd = uv().fs_open(p, "r", 0)
    if not fd then return false end
    local ok = same_file(fd, st)
    local head = ok and uv().fs_read(fd, 64, 0) or nil
    uv().fs_close(fd)
    return ok and type(head) == "string" and head:match(LINE_PAT) ~= nil
end

--- Append one line to the log file `p` (see `write`). Uses libuv and plain
--- io only, so it may run inside libuv callbacks in the editor host.
---
--- The log sits in the workspace's `.nvim/`, which a repository can ship, so
--- it is only ever appended to when it is a regular file of lw's own format
--- (`ours`), through a descriptor checked to be the file lstat saw; a missing
--- log is created exclusively (O_EXCL never follows a link planted at the
--- name). Rotation renames it to `.1` only when an existing `.1` is lw's
--- too; otherwise nothing is written (the cap holds, a foreign `.1` stays).
--- @param p string
--- @param line string
function M.write_path(p, line)
    pcall(function()
        local dir = p:match("^(.*)/[^/]+$")
        if dir and not uv().fs_stat(dir) then
            local parent = dir:match("^(.*)/[^/]+$")
            local pst = parent and uv().fs_stat(parent)
            if not (pst and pst.type == "directory") then return end
            pcall(uv().fs_mkdir, dir, tonumber("755", 8))
        end
        local function fresh()
            local fd = uv().fs_open(p, "wx", tonumber("644", 8))
            if fd then uv().fs_close(fd) end
            local st = uv().fs_lstat(p)
            if not st or st.type ~= "file" then return nil end
            return st
        end
        local st = uv().fs_lstat(p)
        if st and (st.type ~= "file" or not ours(p, st)) then return end
        if not st then st = fresh(); if not st then return end end
        if st.size and st.size > M.MAX_BYTES then
            local old = p .. ".1"
            local ost = uv().fs_lstat(old)
            if ost and (ost.type ~= "file" or not ours(old, ost)) then return end
            if ost then uv().fs_unlink(old) end
            if not uv().fs_rename(p, old) then return end
            st = fresh()
            if not st then return end
        end
        local fd = uv().fs_open(p, "a", tonumber("644", 8))
        if not fd then return end
        if same_file(fd, st) then
            uv().fs_write(fd, string.format("%s pid %d %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"),
                uv().os_getpid and uv().os_getpid() or 0, (tostring(line):gsub("[\r\n]+", " "))), -1)
        end
        uv().fs_close(fd)
    end)
end

--- A logging function bound to `root` (its path resolved now, so the
--- function is safe in libuv callbacks).
--- @param root string
--- @return fun(line: string)
function M.writer(root)
    local p = M.path(root)
    return function(line) M.write_path(p, line) end
end

return M
