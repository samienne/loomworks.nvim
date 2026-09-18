--- loomworks/daemon/pipe.lua — the daemon's local IPC endpoint address + bind.
---
--- The pipe is a TRUST BOUNDARY (DAEMON.md §4, spec §17.4/§10): any local peer
--- that can open it can issue mutation and build commands, so the endpoint MUST
--- be owner-restricted.
---
---   * POSIX — a Unix-domain socket inside a per-user directory created `0700`
---     (under `XDG_RUNTIME_DIR` when present, else a temp dir), so only the owner
---     can traverse to the socket. This is the primary defense; a `SO_PEERCRED` /
---     `getpeereid` owner check is a further hardening that libuv does not expose
---     directly (documented gap, `check_peer` below).
---   * Windows — a named pipe. A pipe a process creates is, by the default
---     security descriptor, reachable by the creating user (and SYSTEM/admins);
---     a tighter SDDL DACL needs `CreateNamedPipe` with a security descriptor,
---     which libuv's `uv_pipe_bind` does not surface (documented gap).
---
--- The address is derived from the workspace root so it is stable and unique per
--- folder, but clients never recompute it — they read the bound address from the
--- handle file (§17.2). Determinism here only avoids collisions between folders.

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- A short, stable, filesystem-safe token for a workspace root (djb2 over the
--- normalized bytes — no crypto dependency, only needs to be collision-avoiding).
--- @param root string
--- @return string
function M.token(root)
    local norm = (root or ""):gsub("\\", "/"):gsub("/+$", "")
    if is_win() then norm = norm:lower() end
    local h = 5381
    for i = 1, #norm do
        h = (h * 33 + norm:byte(i)) % 0x100000000
    end
    return string.format("%08x", h)
end

--- The per-user directory holding POSIX daemon sockets, created `0700`.
--- @return string
local function socket_dir()
    local base = os.getenv("XDG_RUNTIME_DIR")
    if not base or base == "" then
        base = os.getenv("TMPDIR") or "/tmp"
    end
    base = base:gsub("/+$", "")
    local uid = (uv.getuid and uv.getuid()) or 0
    local dir = base .. "/loomworks-" .. tostring(uid)
    pcall(uv.fs_mkdir, dir, tonumber("700", 8))
    -- Tighten in case it pre-existed with looser bits.
    pcall(uv.fs_chmod, dir, tonumber("700", 8))
    return dir
end

--- The endpoint address for a workspace root.
--- @param root string
--- @return string
function M.address(root)
    local tok = M.token(root)
    if is_win() then
        return [[\\.\pipe\loomworks-]] .. tok
    end
    return socket_dir() .. "/" .. tok .. ".sock"
end

--- Bind and listen a libuv pipe server on the workspace's owner-restricted
--- endpoint. On POSIX a stale socket file from a previous run is unlinked first
--- (its daemon is gone — the caller holds the write-authority lock, §4).
--- @param root string
--- @param backlog? integer
--- @param on_connection fun(err: string|nil)
--- @return table|nil server, string|nil address_or_err, string|nil address
function M.listen(root, backlog, on_connection)
    local addr = M.address(root)
    if not is_win() then
        -- A leftover socket path blocks bind with EADDRINUSE; the lock guarantees
        -- no live daemon owns it, so removing it is safe.
        pcall(uv.fs_unlink, addr)
    end
    local server = uv.new_pipe(false)
    local ok, err = pcall(function() server:bind(addr) end)
    if not ok then
        pcall(function() server:close() end)
        return nil, "bind failed: " .. tostring(err)
    end
    local lok, lerr = pcall(function()
        server:listen(backlog or 32, on_connection)
    end)
    if not lok then
        pcall(function() server:close() end)
        return nil, "listen failed: " .. tostring(lerr)
    end
    return server, addr, addr
end

--- Best-effort peer-owner check. libuv does not expose SO_PEERCRED/getpeereid
--- for a uv_pipe_t, and the owner-only socket directory / named-pipe default
--- security already gate access, so this returns true. Kept as the seam where a
--- stronger FFI-based peer check would live.
--- @param _conn userdata
--- @return boolean
function M.check_peer(_conn)
    return true
end

--- Remove a POSIX socket file (daemon shutdown cleanup). No-op on Windows.
--- @param root string
function M.cleanup(root)
    if is_win() then return end
    pcall(uv.fs_unlink, M.address(root))
end

return M
