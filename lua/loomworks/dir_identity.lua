--- loomworks/dir_identity.lua — the physical identity of a directory path
--- (spec §4.6): one folder spelled differently (a junction or symlink, a
--- Windows 8.3 short name, an aliased workspace root, `..` segments) resolves
--- to ONE path. Used as the comparison key of shared build-directory
--- protection and of the build-directory locks (in-process queue and the
--- cross-process `<dir>.loomworks-lock`).
---
--- A path that does not exist yet (configure creates its build directory)
--- resolves through its nearest existing ancestor plus the remaining tail, so
--- the identity is the same before and after the directory is created.

local M = {}

local function fwd(p) return (tostring(p):gsub("\\", "/")) end

--- Resolve `path`: its real path when it exists, else the real path of its
--- nearest existing ancestor joined with the rest of `path`; `path` itself
--- (forward slashes) when nothing along it resolves. Forward slashes, no
--- trailing separator; NOT case-folded (callers normalize for comparison).
--- @param path string
--- @param realpath? fun(p: string): string|nil defaults to uv.fs_realpath
--- @return string
function M.resolve(path, realpath)
    if not path or path == "" then return path end
    realpath = realpath or function(p) return (vim.uv or vim.loop).fs_realpath(p) end
    local p = fwd(path)
    if #p > 1 and not p:match("^%a:/$") then p = p:gsub("/+$", "") end
    local cur, tail = p, ""
    for _ = 1, 256 do
        local r = realpath(cur)
        if r then
            r = fwd(r)
            if tail == "" then return r end
            return (r:gsub("/+$", "")) .. tail
        end
        local parent, seg = cur:match("^(.*)/([^/]+)$")
        if not parent then break end
        -- Never climb above a UNC share (`//server/share`): `/` would
        -- resolve to the current drive's root on Windows.
        if p:sub(1, 2) == "//" and not parent:match("^//[^/]+/[^/]+") then break end
        if parent == "" then parent = "/" end
        if parent:match("^%a:$") then parent = parent .. "/" end
        if parent == cur then break end
        tail = "/" .. seg .. tail
        cur = parent
    end
    return p
end

return M
