--- loomworks/housekeeping.lua — per-user state outside the workspace (spec
--- §16.40).
---
--- Temporary files of a workspace operation (the results file of a named test
--- executable, the editor buffer of a description) live in the workspace's
--- `.nvim/tmp/`, not the system temp directory, so an interrupted `lw` leaves
--- nothing outside the workspace.

local M = {}

local function uv() return vim.uv or vim.loop end

local function norm(p)
    return (tostring(p):gsub("\\", "/"):gsub("/+$", ""))
end

--- A random hex nonce (24 digits).
--- @return string
function M.nonce()
    return require("loomworks.remote.transport").nonce()
end

--- The system temporary directory, forward-slashed.
--- @return string
function M.os_tmpdir()
    return norm(uv().os_tmpdir())
end

--- Ensure `dir` is a real directory (created with one `mkdir` when missing,
--- never through a link). Returns true when it is one.
local function real_dir(dir)
    local st = uv().fs_lstat(dir)
    if not st then
        pcall(uv().fs_mkdir, dir, tonumber("755", 8))
        st = uv().fs_lstat(dir)
    end
    return st ~= nil and st.type == "directory"
end

--- The workspace's temporary directory `<root>/.nvim/tmp`, created when
--- missing: `.nvim/` only when the root exists (the root is never created),
--- each level a real directory, not a link. nil when it cannot be had.
--- @param root string|nil
--- @return string|nil
function M.workspace_tmp_dir(root)
    if type(root) ~= "string" or root == "" then return nil end
    root = norm(root)
    local rst = uv().fs_stat(root)
    if not rst or rst.type ~= "directory" then return nil end
    local nvim = root .. "/.nvim"
    if not real_dir(nvim) then return nil end
    local dir = nvim .. "/tmp"
    if not real_dir(dir) then return nil end
    return dir
end

--- A fresh path for a temporary file of a workspace operation:
--- `<root>/.nvim/tmp/<prefix><nonce><ext>`, or the same name in the system
--- temp directory when the workspace's cannot be had (§16.40).
--- @param root string|nil
--- @param prefix string e.g. "lw-test-"
--- @param ext string e.g. ".xml"
--- @return string
function M.tmp_path(root, prefix, ext)
    local name = prefix .. M.nonce() .. ext
    local dir = M.workspace_tmp_dir(root) or M.os_tmpdir()
    return dir .. "/" .. name
end

return M
