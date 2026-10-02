--- loomworks/daemon/version.lua — what a client and a daemon compare in the
--- version handshake (spec §19.9): the wire protocol, the host version and the
--- working-copy and cache schema versions.
---
--- The host version is the running release (`0.1.43`, from the bundle
--- directory `…/lua-0.1.43`). A development build — a source checkout, a fused
--- dev executable — has no release identity, so it compares a **source
--- fingerprint** instead: `<changelog version>+dev.<hash>` (e.g.
--- `0.1.44+dev.3f2a9c01d4e5b6a7`), where the hash covers the path, size and
--- modification time of every Lua file under the source's `loomworks/`
--- whenever the sources are on disk — an on-disk root (`--dev`,
--- `LOOMWORKS_LUA`, the editor's checkout) or a directory bundle
--- (`luvi <dir> --`, whose modules load from that directory) — and only for a
--- fused executable, whose sources cannot change under it, the executable
--- itself. Editing any source file therefore makes a dev client and a dev
--- daemon mismatch, exactly as a self-update does for a release (the daemon is
--- restarted when idle, retired when busy, §19.9). The fingerprint stats every
--- source file once per process (about 10 ms).

local M = {}

--- The wire protocol version (spec §19.8). 1 was draft PR #88 (unauthenticated);
--- 2 adds the mutual handshake and the frozen control subset; 3 the routed
--- `build` request and its task stream (§19.15).
M.PROTOCOL = 3

local function uv() return vim.uv or vim.loop end

--- The on-disk Lua root this process runs from (the directory holding
--- `loomworks/`), or nil when it runs from a fused bundle.
--- @return string|nil
function M.lua_root()
    local r = rawget(_G, "__loomworks_luaroot")
    if type(r) == "string" and r ~= "" then return (r:gsub("\\", "/"):gsub("/+$", "")) end
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) ~= "@" then return nil end
    local file = src:sub(2):gsub("\\", "/")
    local root = file:match("^(.*)/loomworks/daemon/version%.lua$")
    return root
end

--- Fingerprint of the source tree under `dir` (paths, sizes, mtimes).
local function tree_fingerprint(dir)
    local entries = {}
    local function walk(d, rel)
        local h = uv().fs_scandir(d)
        if not h then return end
        while true do
            local name, typ = uv().fs_scandir_next(h)
            if not name then break end
            local p, r = d .. "/" .. name, (rel == "" and name or (rel .. "/" .. name))
            if typ == "directory" then
                walk(p, r)
            elseif name:sub(-4) == ".lua" then
                local st = uv().fs_stat(p)
                if st then
                    entries[#entries + 1] = string.format("%s:%d:%d.%d", r, st.size or 0,
                        st.mtime and st.mtime.sec or 0, st.mtime and st.mtime.nsec or 0)
                end
            end
        end
    end
    walk(dir, "")
    table.sort(entries)
    return vim.fn.sha256(table.concat(entries, "\n")):sub(1, 16)
end

--- The directory a `luvi <dir>` host runs its bundle from, when it holds the
--- loomworks sources (nil for a fused executable, whose bundle base is the
--- executable file, and outside luvi).
--- @return string|nil
function M.bundle_dir()
    local ok, luvi = pcall(require, "luvi")
    local base = ok and type(luvi) == "table" and type(luvi.bundle) == "table" and luvi.bundle.base or nil
    if type(base) ~= "string" or base == "" then return nil end
    base = base:gsub("\\", "/"):gsub("/+$", "")
    local st = uv().fs_stat(base .. "/loomworks")
    if st and st.type == "directory" then return base end
    return nil
end

local function exe_fingerprint()
    local ok, exe = pcall(uv().exepath)
    if not ok or type(exe) ~= "string" then return "unknown" end
    local st = uv().fs_stat(exe)
    return vim.fn.sha256(string.format("%s:%d:%d", exe:gsub("\\", "/"), st and st.size or 0,
        st and st.mtime and st.mtime.sec or 0)):sub(1, 16)
end

local _identity
--- The host version a daemon handshake compares (memoized).
--- @return string
function M.identity()
    if _identity then return _identity end
    local ok, rel = pcall(function() return require("loomworks.release_notice").running_version() end)
    if ok and type(rel) == "string" and rel ~= "" then
        _identity = rel
        return _identity
    end
    local okb, base = pcall(function() return require("loomworks.save_guard").version() end)
    base = (okb and type(base) == "string" and base) or "0.0.0"
    base = base:gsub("%+dev$", "")
    local root = M.lua_root() or M.bundle_dir()
    local fp = root and tree_fingerprint(root .. "/loomworks") or exe_fingerprint()
    _identity = base .. "+dev." .. fp
    return _identity
end

--- Test seam: forget (or set) the memoized identity.
--- @param v string|nil
function M._set_identity(v) _identity = v end

--- Is `v` a development identity?
--- @param v string|nil
--- @return boolean
function M.is_dev(v)
    return type(v) == "string" and v:find("+dev.", 1, true) ~= nil
end

--- The working-copy and cache schema versions this build reads and writes.
--- @return { user: integer, cache: integer }
function M.schemas()
    return {
        user = require("loomworks.user").CURRENT_VERSION,
        cache = require("loomworks.cache").CURRENT_VERSION,
    }
end

--- Does a peer's announced versions match ours (spec §19.9)? A CLI client
--- requires protocol, host version and schemas to be equal; an editor client
--- (`opts.editor`) protocol and schemas only.
--- @param peer table { protocol, lw_version, schemas = { user, cache } }
--- @param opts? { editor?: boolean }
--- @return boolean match, string|nil what differs ("protocol"|"version"|"schemas")
function M.matches(peer, opts)
    if type(peer) ~= "table" then return false, "protocol" end
    if peer.protocol ~= M.PROTOCOL then return false, "protocol" end
    local s, ps = M.schemas(), peer.schemas
    if type(ps) ~= "table" or ps.user ~= s.user or ps.cache ~= s.cache then return false, "schemas" end
    if not (opts and opts.editor) and peer.lw_version ~= M.identity() then return false, "version" end
    return true
end

--- Are the peer's schemas newer than ours (spec §19.9: such a daemon is never
--- stopped by this client)?
--- @param peer table
--- @return boolean
function M.peer_schemas_newer(peer)
    local s, ps = M.schemas(), type(peer) == "table" and peer.schemas or nil
    if type(ps) ~= "table" then return false end
    return (type(ps.user) == "number" and ps.user > s.user)
        or (type(ps.cache) == "number" and ps.cache > s.cache)
end

return M
