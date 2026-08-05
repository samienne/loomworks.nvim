--- loomworks/runenv.lua — compose a run environment by prepending directories
--- to PATH.
---
--- Shared by the meson test runner (DLL/rpath setup for tests) and build-target
--- launches: a Windows executable whose shared libraries live in the build tree
--- hangs / fails in the loader unless those directories are on PATH.

local M = {}

--- Return a copy of the current process environment with `prefix_dirs`
--- prepended to PATH (highest priority first). Windows-aware: writes `PATH`
--- and clears the duplicate `Path` key so a single, canonical value wins.
--- @param prefix_dirs string[] absolute directories to prepend (in priority order)
--- @param base_env? table<string,string> extra vars layered over the inherited env
--- @return table<string,string> env a full environment table (not just deltas)
function M.compose(prefix_dirs, base_env)
    local env = {}
    local current = vim.fn.environ()
    if type(current) == "table" then
        for k, v in pairs(current) do
            -- Skip cmd.exe's "=C:" style drive-cwd pseudo-vars.
            if type(k) == "string" and k:sub(1, 1) ~= "=" then
                env[k] = v
            end
        end
    end
    for k, v in pairs(base_env or {}) do env[k] = v end

    local is_win = vim.fn.has("win32") == 1
    local sep = is_win and ";" or ":"

    local parts = {}
    for _, p in ipairs(prefix_dirs or {}) do
        if type(p) == "string" and p ~= "" then parts[#parts + 1] = p end
    end
    if #parts > 0 then
        local existing = env.PATH or env.Path or ""
        env.PATH = table.concat(parts, sep) .. (existing ~= "" and (sep .. existing) or "")
        if is_win then env.Path = nil end
    end
    return env
end

return M
