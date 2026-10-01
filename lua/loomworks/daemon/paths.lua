--- loomworks/daemon/paths.lua — where the workspace runtime's files live
--- (spec §19.2, §19.6, §19.10).
---
---   <root>/.nvim/loomworks.daemon.lock   the runtime lock R (§19.2)
---   <root>/.nvim/loomworks.daemon.json   the handle: discovery only (§19.6)
---   <state>/                             the per-user state directory: the
---                                        daemon's working directory and its
---                                        runtime logs (§19.10)
---
--- `<state>` is `<data dir>/daemon`, the per-user data directory of the `lw`
--- host (boot.paths: %LOCALAPPDATA%\loomworks, $XDG_DATA_HOME/loomworks or
--- ~/.local/share/loomworks; LOOMWORKS_DATA_DIR overrides it).
---
--- Pure path arithmetic; nothing here creates a file.

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- A workspace root as the runtime files name it: forward slashes, no
--- trailing slash.
--- @param root string
--- @return string
function M.norm_root(root)
    return (tostring(root):gsub("\\", "/"):gsub("/+$", ""))
end

--- The root as hashed for per-user names: its real path (so a client that
--- reached the workspace through an 8.3 short name, a junction or a symlink
--- names the same files as the daemon), case-folded on Windows, whose
--- filesystems are case-insensitive (the same folding as §2.3).
--- @param root string
--- @return string
local function hash_key(root)
    local uv = vim.uv or vim.loop
    local ok, real = pcall(uv.fs_realpath, M.norm_root(root))
    local r = M.norm_root((ok and type(real) == "string") and real or root)
    if is_win() then r = r:lower() end
    return r
end

--- A short hex hash of a string (first 16 hex digits of its SHA-256).
--- @param s string
--- @return string
function M.short_hash(s)
    return vim.fn.sha256(s):sub(1, 16)
end

--- The short hash naming a workspace's per-user files (runtime log, POSIX
--- socket).
--- @param root string
--- @return string
function M.root_hash(root)
    return M.short_hash(hash_key(root))
end

--- @param root string
--- @return string
function M.lock_path(root)
    return M.norm_root(root) .. "/.nvim/loomworks.daemon.lock"
end

--- @param root string
--- @return string
function M.handle_path(root)
    return M.norm_root(root) .. "/.nvim/loomworks.daemon.json"
end

--- The per-user data directory (shared with the trust key, §17.2).
--- @return string
function M.data_dir()
    return require("loomworks.trust").data_dir()
end

--- The per-user state directory of the workspace runtime.
--- @return string
function M.state_dir()
    return M.data_dir() .. "/daemon"
end

--- The runtime log of a workspace (§19.10): one file per workspace, named by
--- the root hash.
--- @param root string
--- @return string
function M.log_path(root)
    return M.state_dir() .. "/logs/" .. M.root_hash(root) .. ".log"
end

M._hash_key = hash_key

return M
