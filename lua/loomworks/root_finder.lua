--- loomworks/root_finder.lua — upward workspace-root search (spec §1.1).
---
--- The ONE search every host uses to resolve the workspace from a directory:
--- the headless `lw` (cli.lua) and the editor's auto-load (auto_load.lua), so
--- both bind to the same workspace from the same directory (§13).
---
--- Walk up from the start directory; the first directory holding
--- `loomworks.json` or `.nvim/loomworks.user.json` is the root. A directory
--- with a `.git` entry but no workspace marker is a git working-tree boundary
--- and ends the search with no root — EXCEPT a submodule's `.git` file: a
--- submodule checkout is part of its superproject's working tree, so the walk
--- continues to the superproject's workspace.
---
--- Why the boundary exists at all: a fresh `git worktree` has no `.nvim/` yet
--- (gitignored, not created by `git worktree add`). Without the stop, `lw` in
--- it would silently walk past the worktree and bind to the PARENT checkout's
--- workspace, operating on the wrong build dir; the `lw worktree` / `lw pull`
--- flow relies on nil here to surface the "run `lw init` / `lw pull`" hint.
--- So a linked worktree stays a hard boundary; only submodules are crossed.
---
--- Classification is pure file reads (no git spawn — this runs on every `lw`
--- invocation and every editor cwd change). Host-neutral: runs under nvim and
--- under the luvi host's vim shim (only `vim.uv`/`vim.loop` + `io`).

local uv = vim.uv or vim.loop

local M = {}

--- Forward slashes, no trailing slash (`C:/` becomes `C:`, `/` becomes ``).
--- @param p string
--- @return string
local function slashes(p)
    return (p:gsub("\\", "/"):gsub("/+$", ""))
end

--- Is `p` absolute (POSIX `/…`, UNC `//…`, or Windows drive `C:/…`)?
--- @param p string forward-slashed
local function is_absolute(p)
    return p:sub(1, 1) == "/" or p:match("^%a:/") ~= nil
end

--- Join `rel` onto `base` (unless `rel` is absolute) and fold `.`/`..`
--- segments lexically — the gitdir target need not exist on disk.
--- @param base string forward-slashed directory
--- @param rel string forward-slashed path
--- @return string
local function resolve(base, rel)
    local full = is_absolute(rel) and rel or (base .. "/" .. rel)
    local prefix, rest
    if full:sub(1, 2) == "//" then
        prefix, rest = "//", full:sub(3)
    elseif full:match("^%a:/") then
        prefix, rest = full:sub(1, 3), full:sub(4)
    elseif full:sub(1, 1) == "/" then
        prefix, rest = "/", full:sub(2)
    else
        prefix, rest = "", full
    end
    local parts = {}
    for seg in rest:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = seg
            end -- `..` above an absolute root stays at the root
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return prefix .. table.concat(parts, "/")
end

--- The `gitdir:` target of a `.git` file, resolved against the file's
--- directory; nil when unreadable or not a gitdir file. Tolerates CRLF,
--- surrounding whitespace, and a missing trailing newline.
--- @param git_file string path to the `.git` FILE
--- @return string|nil
local function read_gitdir(git_file)
    local f = io.open(git_file, "rb")
    if not f then return nil end
    local head = f:read(4096)
    f:close()
    if not head then return nil end
    local line = head:match("^[^\r\n]*")
    local target = line and line:match("^%s*gitdir:%s*(.-)%s*$")
    if not target or target == "" then return nil end
    local dir = slashes(git_file):gsub("/[^/]*$", "")
    return resolve(dir, slashes(target))
end

--- Classify a `.git` FILE by its `gitdir:` target (spec §1.1):
---   "worktree"  — a linked worktree (target holds `commondir`, which every
---                 linked-worktree admin dir has and a repository's own git
---                 dir never does; or a missing `…/worktrees/<name>` target);
---   "submodule" — target under a `.git/modules/…` area, directly (nested
---                 `…/modules/A/modules/B` included) or inside a linked
---                 worktree's admin dir (`…/.git/worktrees/<wt>/modules/…`);
---   "boundary"  — anything else: unreadable, no gitdir line, or another
---                 shape (e.g. `--separate-git-dir`). Conservative: stop.
--- The commondir probe disambiguates a submodule whose PATH contains a
--- `worktrees/<x>` component (`.git/modules/tools/worktrees/x`), whose
--- gitdir shape alone looks like a worktree's.
--- @param git_file string
--- @return "worktree"|"submodule"|"boundary"
function M.classify_git_file(git_file)
    local target = read_gitdir(git_file)
    if not target then return "boundary" end
    if uv.fs_stat(target .. "/commondir") then return "worktree" end
    if not uv.fs_stat(target) and target:match("/worktrees/[^/]+$") then
        return "worktree"
    end
    if target:find("/.git/modules/", 1, true)
        or target:find("/%.git/worktrees/[^/]+/modules/") then
        return "submodule"
    end
    return "boundary"
end

--- Walk up from `start` (default: the process cwd) for the workspace root.
--- Returns `(root, info)`: `root` is forward-slashed, nil when no workspace
--- resolves (none on the way up, or a working-tree boundary reached first);
--- `info.submodule` is the nearest submodule directory the walk crossed to
--- get there (nil when none), so a host can say the workspace came from the
--- superproject.
--- @param start? string
--- @return string|nil root, { submodule: string|nil }|nil info
function M.find(start)
    local dir = slashes(start or uv.cwd())
    local submodule
    while dir ~= "" do
        -- A workspace is recognized by the published snapshot OR the working
        -- copy — a not-yet-published `lw init` has only the latter.
        if uv.fs_stat(dir .. "/loomworks.json")
            or uv.fs_stat(dir .. "/.nvim/loomworks.user.json") then
            return dir, { submodule = submodule }
        end
        local git = uv.fs_stat(dir .. "/.git")
        if git then
            -- A `.git` directory is a repository root; a `.git` file is a
            -- linked worktree or a submodule. Only a submodule is crossed.
            if git.type == "directory"
                or M.classify_git_file(dir .. "/.git") ~= "submodule" then
                return nil
            end
            submodule = submodule or dir
        end
        local parent = dir:gsub("/[^/]*$", "")
        if parent == dir then break end
        dir = parent
    end
    return nil
end

M._resolve = resolve

return M
