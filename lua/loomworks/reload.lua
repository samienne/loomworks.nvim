--- loomworks/reload.lua — Dev-only reload orchestrator.
---
--- Tears down the active workspace via `core:shutdown()`, then asks
--- lazy.nvim to reload this plugin + siblings (clears `package.loaded`,
--- re-runs init/config which re-calls `setup()`).
---
--- Accepted leakage: overseer task_tracker on_complete subscribers stay
--- registered and fire against the torn-down workspace (they fail fast).
--- This is a dev hatch — when a reload misbehaves, restart Neovim.

local M = {}

--- Plugin names to reload via lazy. Only entries actually installed
--- get reloaded; missing ones are silently skipped so a user without
--- the ohos plugin still gets a clean :LoomworksReload.
local PLUGINS = {
    "loomworks.nvim",
    "loomworks-module-ohos.nvim",
}

--- Reload loomworks and any siblings.
--- @return boolean ok
function M.reload()
    local ok_core, loomworks = pcall(require, "loomworks")
    if ok_core then
        local core = loomworks._core()
        if core then core:shutdown() end
    end

    local ok_lazy, lazy_config = pcall(require, "lazy.core.config")
    if not ok_lazy then
        vim.notify(
            "loomworks: reload requires lazy.nvim — restart Neovim instead",
            vim.log.levels.ERROR)
        return false
    end

    local installed = {}
    for _, name in ipairs(PLUGINS) do
        if lazy_config.plugins[name] then
            installed[#installed + 1] = name
        end
    end

    if #installed == 0 then
        vim.notify("loomworks: no loomworks plugins registered with lazy",
            vim.log.levels.WARN)
        return false
    end

    require("lazy").reload({ plugins = installed })
    vim.notify("loomworks: reloaded " .. table.concat(installed, ", "),
        vim.log.levels.INFO)
    return true
end

return M
