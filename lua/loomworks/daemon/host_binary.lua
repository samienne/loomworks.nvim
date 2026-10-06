--- loomworks/daemon/host_binary.lua — the host binary the editor launches the
--- workspace daemon from (spec §19.16).
---
--- In this order:
---   1. `LOOMWORKS_LW` — an existing file;
---   2. the repository pin (§16.21): the pinned version's host binary already
---      provisioned in the per-user pinned cache (`<data>/pinned/lw-<version>-
---      <asset>`, §16.22). Never downloaded here, and not re-hashed: the host
---      that provisioned it verified it, and the file lives in the user's own
---      data directory, never in the repository;
---   3. `lw` on the search path (on Windows only an `.exe`: a `.cmd` shim
---      cannot be started detached without a console).
--- The editor never launches a daemon from its own plugin source.

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

local function is_file(p)
    local st = p and uv.fs_stat(p)
    return st ~= nil and st.type == "file"
end

--- The pinned host binary for the workspace at `root`, when provisioned.
--- @param root string
--- @return string|nil
function M.pinned(root)
    local okp, pin = pcall(require, "boot.pin")
    local okd, bpaths = pcall(require, "boot.paths")
    if not (okp and okd) then return nil end
    local pin_root = pin.find_pin_root(root)
    local p = pin_root and pin.read(pin_root)
    if not p then return nil end
    local asset = pin.detect_asset()
    if not asset then return nil end
    local path = bpaths.data_dir() .. "/pinned/lw-" .. p.version .. "-" .. asset
    if is_file(path) then return path end
    return nil
end

--- `lw` on the search path, or nil.
--- @return string|nil
function M.on_path()
    local ok, exe = pcall(vim.fn.exepath, "lw")
    if not ok or type(exe) ~= "string" or exe == "" then return nil end
    -- The binary itself, not PATH's spelling of it (`lw.EXE` via PATHEXT, a
    -- link): the daemon it starts then reports the executable the CLI does.
    local uv = vim.uv or vim.loop
    local real = uv.fs_realpath(exe)
    if type(real) == "string" and real ~= "" then exe = real end
    exe = exe:gsub("\\", "/")
    if is_win() and not exe:lower():match("%.exe$") then return nil end
    return exe
end

--- Resolve the host binary for the workspace at `root`.
--- @param root string
--- @param opts? { getenv?: fun(name: string): string|nil, pinned?: fun(root: string): string|nil, on_path?: fun(): string|nil }
--- @return string|nil path, string|nil source "LOOMWORKS_LW" | "pin" | "PATH"
function M.resolve(root, opts)
    opts = opts or {}
    local getenv = opts.getenv or os.getenv
    local env = getenv("LOOMWORKS_LW")
    if env and env ~= "" and is_file(env) then return (env:gsub("\\", "/")), "LOOMWORKS_LW" end
    local pinned = (opts.pinned or M.pinned)(root)
    if pinned then return pinned, "pin" end
    local p = (opts.on_path or M.on_path)()
    if p then return p, "PATH" end
    return nil
end

--- The note shown when no host binary resolves.
M.NONE_NOTE = "no lw host binary found (LOOMWORKS_LW, lw.pin, PATH) — running in-process"

return M
