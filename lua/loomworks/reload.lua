--- loomworks/reload.lua — Dev-only reload orchestrator.
---
--- Sequence:
---   1. Tear down the active workspace via `core:shutdown()`. Stops the
---      file tracker, cancels in-flight overseer tasks (fire-and-forget),
---      detaches event subscribers, drops build_dir_locks.
---   2. Ask lazy.nvim to reload this plugin + any sibling plugins.
---      lazy clears `package.loaded` entries for those plugins and
---      re-runs their `init`/`config` callbacks. The config callbacks
---      call `setup()` again with the user's original opts.
---
--- Out of scope (accepted leakage):
---   * Overseer task_tracker on_complete subscribers stay registered.
---     They fire against the torn-down workspace and fail fast.
---   * Plugin-global augroups (`loomworks.lsp.*`, `loomworks_auto_load`)
---     are re-created with `clear = true` on setup re-run, self-healing.
---   * User commands declared in `plugin/loomworks.lua` are re-registered
---     with `force = true` so re-running setup doesn't error on dup.
---
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

    -- Delegate to lazy: clears package.loaded + re-runs init/config
    -- per plugin. Config functions re-call setup(), which idempotently
    -- re-registers augroups (clear = true), user commands (force = true
    -- per our registration), and keymaps (vim.keymap.set overwrites).
    require("lazy").reload({ plugins = installed })
    vim.notify("loomworks: reloaded " .. table.concat(installed, ", "),
        vim.log.levels.INFO)
    return true
end

return M
