--- The environment of a process started from the managed lw (spec §19.16
--- "Plugin pin"): it gets no install-folder or source override, so an
--- exported LOOMWORKS_LUA or LOOMWORKS_INSTALL_DIR in the editor's environment
--- is removed from the child's. A binary the user installed or named keeps the
--- inherited environment.
local uv = vim.uv or vim.loop

local M = {}

--- The variables a managed lw's child never inherits.
M.MANAGED_UNSET = { "LOOMWORKS_LUA", "LOOMWORKS_INSTALL_DIR" }

--- Run `fn` (which spawns synchronously, e.g. `vim.system`) with `names`
--- removed from this process's environment, restoring them right after,
--- whatever `fn` does. vim.system's own `env` can only add or replace
--- variables, and the shape its `clear_env` form takes differs between Neovim
--- releases; the spawn copies the environment at once, so removing the names
--- around it is exact. (Windows' environment is case-insensitive:
--- os_getenv / os_unsetenv find any spelling.)
--- @param names string[]|nil
--- @param fn fun(): ...
--- @return ... fn's results (pcall form: ok, ...)
function M.without(names, fn)
    local saved = {}
    for _, n in ipairs(names or {}) do
        local v = uv.os_getenv(n)
        if v ~= nil then
            saved[#saved + 1] = { n, v }
            uv.os_unsetenv(n)
        end
    end
    local function restore(...)
        for _, kv in ipairs(saved) do uv.os_setenv(kv[1], kv[2]) end
        return ...
    end
    return restore(pcall(fn))
end

return M
