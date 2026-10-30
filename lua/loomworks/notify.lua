--- loomworks/notify.lua — the host's notification seam for model code.
---
--- Model code that runs in every host (the editor, `lw` in-process, the
--- workspace daemon) notifies through here, never through `vim.notify`
--- directly: the call reaches the process's core `_deps.notify`, which each
--- host installs — the editor's `vim.notify`, the CLI's painted stderr
--- printer, the daemon's per-request reply notes — so a warning is painted
--- `warn` (an error `fail`) in both CLI hosts and a load's warnings become
--- its persistent load diagnostics (spec §16.7 *Highlighting*, core
--- daemon.md §19.13 "Load warnings"). Binary-side only: the plugin side of
--- the split (UI, LSP, DAP, the overseer adapter, tests/split/boundary.lua)
--- keeps `vim.notify`.

local M = {}

--- Notify `msg` at `level` through the process core's `_deps.notify`.
--- Before `loomworks` is loaded (a module used on its own) it is
--- `vim.notify`.
--- @param msg string
--- @param level? integer vim.log.levels
function M.notify(msg, level)
    local lw = package.loaded["loomworks"]
    local core = type(lw) == "table" and type(lw._core) == "function" and lw._core() or nil
    local fn = core and core._deps and core._deps.notify
    if fn then return fn(msg, level) end
    return vim.notify(msg, level)
end

return M
