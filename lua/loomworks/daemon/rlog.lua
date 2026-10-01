--- loomworks/daemon/rlog.lua — the runtime log (spec §19.10, §19.5).
---
--- One file per workspace in the per-user state directory,
--- `<state>/logs/<root hash>.log`, capped at `MAX_BYTES` with one rotated
--- predecessor (`.log.1`). The daemon writes its lifecycle there (start,
--- reclaimed locks, refused connections, stop reason); every client records
--- the launches it makes or fails, and every kill and forced unlock (§19.5).
---
--- Append-only, one whole line per write; several processes may append at
--- once. Rotation is best-effort (a failed rename just retries later), and
--- removes only `<log>.1` — the one rotated predecessor of this exact file.

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
        if dir and not uv().fs_stat(dir) then M._mkdirp(dir) end
        local st = uv().fs_stat(p)
        if st and st.size and st.size > M.MAX_BYTES then
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

--- mkdir -p with libuv only (callable from libuv callbacks in the editor).
--- @param dir string
function M._mkdirp(dir)
    if uv().fs_stat(dir) then return end
    local parent = dir:match("^(.+)/[^/]+$")
    if parent and parent ~= dir and not parent:match("^%a:$") then M._mkdirp(parent) end
    pcall(uv().fs_mkdir, dir, tonumber("700", 8))
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
