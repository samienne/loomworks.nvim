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

--- The process's core, when `loomworks` is loaded.
--- @return table|nil
local function process_core()
    local lw = package.loaded["loomworks"]
    return type(lw) == "table" and type(lw._core) == "function" and lw._core() or nil
end

--- Notify `msg` at `level` through the process core's `_deps.notify`.
--- Before `loomworks` is loaded (a module used on its own) it is
--- `vim.notify`. `opts.in_diagnostics`: a structural diagnostic of the
--- workspace already shows this warning, so as a load diagnostic it is
--- left out of the views (still a load note of the CLI's replies).
--- @param msg string
--- @param level? integer vim.log.levels
--- @param opts? { in_diagnostics?: boolean }
function M.notify(msg, level, opts)
    local core = process_core()
    local fn = core and core._deps and core._deps.notify
    if fn then return fn(msg, level, opts) end
    return vim.notify(msg, level)
end

--- The keys `once` reported during the current load.
--- @type table<string, true>
local reported = {}

--- A workspace load starts (`Core:_begin_load_notes`): what `once` reported
--- for the previous load is reported again, so each load's diagnostics carry
--- it (core daemon.md §19.13 "Load warnings").
function M.new_load()
    reported = {}
end

--- Notify once per load per `key` — a warning a model sync would otherwise
--- repeat on each remerge (a rejected plugin, a stale mapping).
--- @param key string
--- @param msg string
--- @param level? integer
--- @param opts? { in_diagnostics?: boolean }
function M.once(key, msg, level, opts)
    if reported[key] then return end
    reported[key] = true
    return M.notify(msg, level, opts)
end

--- Is a workspace load of this process capturing its warnings now?
--- @return boolean
function M.in_load()
    local core = process_core()
    return core ~= nil and core._load_capture ~= nil
end

return M
