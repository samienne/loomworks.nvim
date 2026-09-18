--- loomworks/daemon/pipe.lua — the daemon's local IPC endpoint address + bind.
---
--- The pipe is a TRUST BOUNDARY (DAEMON.md §4, spec §17.4/§17.8): any local peer
--- that can open it can issue mutation and build commands, so the endpoint MUST
--- be owner-restricted.
---
---   * POSIX — a Unix-domain socket inside a per-user directory created `0700`,
---     so only the owner can traverse to it. The directory lives under
---     `$XDG_RUNTIME_DIR` (per-user, cleaned on logout) when present, else
---     `$TMPDIR`, else `/tmp`; it is NOT placed under the repo's `.nvim/`, because
---     a Unix socket path must fit `sun_path` (~104 on macOS, ~108 on Linux) and a
---     deep repo path would overflow it. The address is keyed by a hash of the
---     workspace root so it is stable and unique per folder, and a length guard
---     falls back to a shorter base if a pathological `$TMPDIR` would overflow.
---     A `SO_PEERCRED` / `getpeereid` owner check is a further hardening libuv
---     does not expose directly (documented gap, `check_peer`).
---   * Windows — a named pipe `\\.\pipe\loomworks-<token>`. A pipe a process
---     creates is, by the default security descriptor, reachable only by the
---     creating user (and SYSTEM/admins); a tighter SDDL DACL needs
---     `CreateNamedPipe` with a security descriptor, which libuv's
---     `uv_pipe_bind` does not surface (documented gap).
---
--- Clients never recompute the address — they read the bound address from the
--- handle file (§17.2), so the daemon is the only party that resolves it.

local uv = vim.uv or vim.loop

local M = {}

--- Conservative Unix-domain `sun_path` budget. The real kernel limit is ~104
--- (macOS) / ~108 (Linux) INCLUDING the NUL terminator; we stay well under it.
M.SUN_PATH_MAX = 100

local function is_win() return package.config:sub(1, 1) == "\\" end

local function uid() return (uv.getuid and uv.getuid()) or 0 end

--- A short, stable, filesystem-safe token for a workspace root (djb2 over the
--- normalized bytes — no crypto dependency, only needs to be collision-avoiding).
--- Case is preserved on POSIX (case-sensitive filesystems) and folded on Windows
--- (case-insensitive), matching how the rest of the code normalizes paths.
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

--- Candidate base directories for the POSIX socket dir, most-preferred first.
--- EXISTENCE-AWARE: a base whose directory does not exist is skipped (a common
--- CI case — `XDG_RUNTIME_DIR` set but its path absent — which would otherwise
--- fail the non-recursive leaf `mkdir`). `/tmp` is always appended as the
--- guaranteed last resort.
--- @return string[]
local function candidate_bases()
    local out, seen = {}, {}
    local function add(b, force)
        if not b or b == "" then return end
        b = b:gsub("/+$", "")
        if seen[b] then return end
        if force then
            seen[b] = true; out[#out + 1] = b; return
        end
        local st = uv.fs_stat(b)
        if st and st.type == "directory" then seen[b] = true; out[#out + 1] = b end
    end
    add(os.getenv("XDG_RUNTIME_DIR"))
    add(os.getenv("TMPDIR"))
    add("/tmp", true)
    return out
end

--- Pure: choose (dir, socket_path) for a token, preferring the first base whose
--- full socket path fits under `SUN_PATH_MAX`. If none fits, use `/tmp` (the
--- shortest reliable base) even if long — a best effort beats a cryptic bind
--- failure. `bases` is injectable for tests (no existence check on injected bases).
--- @param tok string
--- @param bases? string[]
--- @return string dir, string socket_path
function M._resolve_socket_path(tok, bases)
    local name = "loomworks-" .. tostring(uid())
    for _, base in ipairs(bases or candidate_bases()) do
        base = base:gsub("/+$", "")
        local dir = base .. "/" .. name
        local path = dir .. "/" .. tok .. ".sock"
        if #path <= M.SUN_PATH_MAX then
            return dir, path
        end
    end
    local dir = "/tmp/" .. name
    return dir, dir .. "/" .. tok .. ".sock"
end

--- All (dir, socket_path) candidates for a token in preference order, honoring
--- the length guard, existence-aware, with `/tmp` as the guaranteed tail.
--- `listen` tries them in order so a hijacked or unusable base falls through.
--- @param tok string
--- @return { dir: string, path: string }[]
local function socket_candidates(tok)
    local name = "loomworks-" .. tostring(uid())
    local out = {}
    for _, base in ipairs(candidate_bases()) do
        local dir = base:gsub("/+$", "") .. "/" .. name
        local path = dir .. "/" .. tok .. ".sock"
        if #path <= M.SUN_PATH_MAX then out[#out + 1] = { dir = dir, path = path } end
    end
    if #out == 0 then
        local dir = "/tmp/" .. name
        out[1] = { dir = dir, path = dir .. "/" .. tok .. ".sock" }
    end
    return out
end

--- The canonical endpoint address for a workspace root — the first (preferred)
--- candidate. PURE toward the filesystem (it may `stat` bases to skip missing
--- ones, but never creates anything). Clients never call this — they read the
--- bound address from the handle; `listen` records the address it actually bound,
--- which may be a later candidate if the first was unusable.
--- @param root string
--- @return string
function M.address(root)
    local tok = M.token(root)
    if is_win() then
        return [[\\.\pipe\loomworks-]] .. tok
    end
    return socket_candidates(tok)[1].path
end

--- Ensure the per-user socket directory exists, is a directory, is `0700`, and
--- is owned by this user — refusing a directory we do not own (the classic
--- pre-created-`/tmp/<name>` attack). Returns the dir, or nil + reason.
--- @param dir string
--- @return string|nil dir, string|nil err
local function ensure_dir(dir)
    pcall(uv.fs_mkdir, dir, tonumber("700", 8))
    pcall(uv.fs_chmod, dir, tonumber("700", 8))
    local st = uv.fs_stat(dir)
    if not st then return nil, "cannot create socket directory " .. dir end
    if st.type ~= "directory" then return nil, dir .. " exists but is not a directory" end
    -- Ownership check (POSIX): st.uid is nil where unsupported, in which case we
    -- skip rather than falsely reject.
    if uv.getuid and type(st.uid) == "number" and st.uid ~= uid() then
        return nil, "socket directory " .. dir .. " is not owned by this user"
    end
    return dir
end

--- Bind + listen a libuv pipe server on a single concrete address.
--- @return table|nil server, string|nil err
local function bind_and_listen(addr, backlog, on_connection)
    local server = uv.new_pipe(false)
    local ok, err = pcall(function() server:bind(addr) end)
    if not ok then
        pcall(function() server:close() end)
        return nil, "bind failed for " .. addr .. ": " .. tostring(err)
    end
    local lok, lerr = pcall(function() server:listen(backlog or 32, on_connection) end)
    if not lok then
        pcall(function() server:close() end)
        return nil, "listen failed for " .. addr .. ": " .. tostring(lerr)
    end
    return server, nil
end

--- Bind and listen on the workspace's owner-restricted endpoint. On POSIX it
--- tries each candidate (§17.8) in order — ensuring the owner-only 0700 socket
--- directory and unlinking any stale socket first (safe: the caller holds the
--- write-authority lock, §4, so no LIVE daemon owns the address) — and returns
--- the address it actually bound, which the daemon records in the handle.
--- @param root string
--- @param backlog? integer
--- @param on_connection fun(err: string|nil)
--- @return table|nil server, string|nil address_or_err, string|nil address
function M.listen(root, backlog, on_connection)
    if is_win() then
        local addr = M.address(root)
        local server, err = bind_and_listen(addr, backlog, on_connection)
        if not server then return nil, err end
        return server, addr, addr
    end

    local errs = {}
    for _, cand in ipairs(socket_candidates(M.token(root))) do
        local dir_ok, derr = ensure_dir(cand.dir)
        if dir_ok then
            pcall(uv.fs_unlink, cand.path) -- clear a crashed predecessor's socket
            local server, err = bind_and_listen(cand.path, backlog, on_connection)
            if server then return server, cand.path, cand.path end
            errs[#errs + 1] = err
        else
            errs[#errs + 1] = derr
        end
    end
    return nil, "no usable socket endpoint: " .. table.concat(errs, "; ")
end

--- Best-effort peer-owner check. libuv does not expose SO_PEERCRED/getpeereid
--- for a uv_pipe_t, and the owner-only socket directory / named-pipe default
--- security already gate access, so this is a clean no-op returning true on every
--- platform. Kept as the seam where a stronger FFI-based peer check would live.
--- @param _conn userdata
--- @return boolean
function M.check_peer(_conn)
    return true
end

--- Remove the daemon's POSIX socket file on shutdown. Takes the ACTUAL bound
--- address (which may be a non-canonical candidate), not the root — so it always
--- unlinks the socket that was really created. A Windows named-pipe address
--- (`\\.\pipe\…`) has no filesystem entry, so this is a no-op there.
--- @param addr string|nil the address returned by M.listen
function M.cleanup(addr)
    if type(addr) ~= "string" or addr:sub(1, 2) == [[\\]] then return end
    pcall(uv.fs_unlink, addr)
end

return M
