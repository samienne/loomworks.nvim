--- loomworks/provision/managed.lua — the plugin-managed `lw` host binary
--- under the editor's data directory (spec §19.16 "Host binary").
---
--- Everything the plugin installs lives under `<stdpath("data")>/loomworks/`
--- (spec §19.16 "Install location"). Host binaries are content-addressed:
---
---     <stdpath("data")>/loomworks/lw/<sha256>/lw        (lw.exe on Windows)
---
--- `<sha256>` is the binary's lowercase hex SHA-256: a versioned path, so a
--- binary is never replaced in place (a running daemon keeps its file). The
--- wanted binary (release version, asset, SHA-256) comes from the plugin's
--- own pin (step 5h.4) or a channel upgrade (step 5h.5); until then nothing
--- is wanted and the slot is empty. A wanted binary that is not installed is
--- downloaded by loomworks.provision.fetch (step 5h.3, daemon mode only).

local uv = vim.uv or vim.loop

local M = {}

local function is_win() return package.config:sub(1, 1) == "\\" end

--- The reason shown while no managed binary is wanted (before step 5h.4's
--- plugin pin).
M.NOT_YET = "none wanted (the plugin carries no pin yet)"

--- The editor's data directory for loomworks (`<stdpath("data")>/loomworks`).
--- @param data? string the editor's data directory (tests inject)
--- @return string
function M.root(data)
    data = data or vim.fn.stdpath("data")
    return (tostring(data):gsub("\\", "/"):gsub("/+$", "")) .. "/loomworks"
end

--- The directory holding the managed host binaries.
--- @param data? string
--- @return string
function M.dir(data) return M.root(data) .. "/lw" end

--- The file name of a host binary on this platform.
--- @param win? boolean (tests inject)
--- @return string
function M.exe_name(win)
    if win == nil then win = is_win() end
    return win and "lw.exe" or "lw"
end

--- The path a managed host binary of `sha256` has, or nil for a value that is
--- not 64 hex digits (never a path from an unchecked string).
--- @param sha256 string
--- @param opts? { data?: string, win?: boolean }
--- @return string|nil
function M.path(sha256, opts)
    opts = opts or {}
    if type(sha256) ~= "string" or not sha256:match("^%x+$") or #sha256 ~= 64 then return nil end
    return M.dir(opts.data) .. "/" .. sha256:lower() .. "/" .. M.exe_name(opts.win)
end

--- The managed binary the plugin wants, or nil + why. Nothing yet (step
--- 5h.4 brings the plugin pin).
--- @return loomworks.provision.Wanted|nil wanted, string|nil why
function M.wanted()
    return nil, M.NOT_YET
end

local function is_file(p)
    local st = p and uv.fs_stat(p)
    return st ~= nil and st.type == "file"
end

--- The managed host binary when it is already present, or nil + why (+ the
--- wanted record when it is only not installed yet: it can be downloaded).
--- `opts.wanted` returns a `loomworks.provision.Wanted` record or a bare hash.
--- @param opts? { data?: string, win?: boolean, wanted?: fun(): (loomworks.provision.Wanted|string|nil), string|nil, exists?: fun(path: string): boolean }
--- @return string|nil path, string|nil why, loomworks.provision.Wanted|nil missing
function M.find(opts)
    opts = opts or {}
    local want, why = (opts.wanted or M.wanted)()
    if not want then return nil, why or M.NOT_YET end
    local sha = type(want) == "table" and want.sha256 or want
    local p = M.path(sha, opts)
    if not p then return nil, "invalid hash " .. tostring(sha) end
    if not (opts.exists or is_file)(p) then
        return nil, "not installed (" .. p .. ")", type(want) == "table" and want or nil
    end
    return p
end

return M
