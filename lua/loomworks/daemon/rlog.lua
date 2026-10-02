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

--- Append one line to the log file `p` (see `write`). Uses libuv and plain
--- io only, so it may run inside libuv callbacks in the editor host.
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
        -- The log sits in the workspace's `.nvim/`, which a repository can
        -- ship: only ever append to a regular file this process sees as one
        -- (lstat), and create a missing one exclusively — O_EXCL never
        -- follows a link planted at the name.
        local st = uv().fs_lstat(p)
        if st and st.type ~= "file" then return end
        if not st then
            local fd = uv().fs_open(p, "wx", tonumber("644", 8))
            if fd then uv().fs_close(fd) end
            st = uv().fs_lstat(p)
            if not st or st.type ~= "file" then return end
        end
        if st.size and st.size > M.MAX_BYTES then
            local old = p .. ".1"
            local ost = uv().fs_lstat(old)
            if not ost or ost.type == "file" then
                pcall(uv().fs_unlink, old)
                pcall(uv().fs_rename, p, old)
            end
        end
        local f = io.open(p, "ab")
        if not f then return end
        f:write(string.format("%s pid %d %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"),
            uv().os_getpid and uv().os_getpid() or 0, (tostring(line):gsub("[\r\n]+", " "))))
        f:close()
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
