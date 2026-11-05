--- loomworks/fidget.lua — Optional fidget.nvim integration for build progress.
---
--- Shows a progress entry per daemon task (the observer's daemon_task_*
--- events) and per user action. No-op if fidget is not installed.

local M = {}

local fidget_progress
local handles = {} -- keyed by "daemon:<task id>" or "action:<title>:<clock>"

--- Maximum visible width for fidget title/message text. Bounded
--- here so an unusually long ninja step description, deploy path,
--- or ad-hoc status string can't blow the popup out to the full
--- terminal width. Set via `loomworks.setup({ progress_max_width = N })`.
local progress_max_width = 60

--- Truncate text to `progress_max_width` chars, adding an ellipsis
--- when shortening. Operates on bytes — works correctly for ASCII
--- which is what build tools emit; multi-byte text would just
--- result in slightly off truncation, never a crash.
--- @param s string|nil
--- @return string|nil
local function clip(s)
    if s == nil then return nil end
    if #s <= progress_max_width then return s end
    return s:sub(1, progress_max_width - 1) .. "…"
end

local ACTION_TITLE = {
    configure = "Configuring",
    build = "Building",
    ["configure+build"] = "Building",
    delete = "Deleting",
    clean = "Cleaning",
    reset = "Resetting",
    test = "Testing",
    run = "Preparing",
}

--- A remote task's entry message: its action and origin marker
--- (`Building (lw)`).
--- @param task loomworks.RemoteTask
--- @return string
local function daemon_title(task)
    local origin = task:origin_label()
    return (ACTION_TITLE[task.kind] or task.kind) .. (origin and (" (" .. origin .. ")") or "")
end

--- Create a fidget handle for an operation or task.
--- @param key string handle key
--- @param title string
--- @param message string
--- @return table|nil handle
local function create_handle(key, title, message)
    if not fidget_progress then return nil end
    if handles[key] then return handles[key] end

    local handle = fidget_progress.handle.create({
        title = clip(message),
        message = clip(title),
        lsp_client = { name = "loomworks" },
    })
    handles[key] = handle
    return handle
end

--- Initialize fidget integration. Call from setup().
--- No-op if fidget.nvim is not available.
--- @param opts? { progress_max_width?: integer }
function M.setup(opts)
    if opts and type(opts.progress_max_width) == "number"
            and opts.progress_max_width > 0 then
        progress_max_width = math.floor(opts.progress_max_width)
    end

    local ok, fp = pcall(require, "fidget.progress")
    if not ok then return end
    fidget_progress = fp

    local lw = require("loomworks")

    -- Operations observed in the workspace daemon (spec §19.16): e.g. `lw
    -- build` in a terminal — the same entry as a local operation of the kind
    -- and profile, plus the origin marker. Keyed by the daemon's task id.
    lw.on("daemon_task_started", function(data)
        local task = data.task
        create_handle("daemon:" .. task.id, daemon_title(task), task.profile_name or task.name)
    end)

    lw.on("daemon_task_progress", function(data)
        local handle = handles["daemon:" .. data.task.id]
        if handle and data.task.pct then
            handle:report({ percentage = data.task.pct })
        end
    end)

    -- A task carrying steps (step 5t, §19.15 "Steps of a task") keeps its
    -- one entry, which follows its current step.
    lw.on("daemon_task_step", function(data)
        local task = data.task
        local handle = handles["daemon:" .. task.id]
        if not handle then return end
        -- No step running: the entry's own message again, without the step.
        handle:report({ message = clip(task:step_text() or daemon_title(task)) })
    end)

    lw.on("daemon_task_stopped", function(data)
        local task = data.task
        local key = "daemon:" .. task.id
        local handle = handles[key]
        if not handle then return end
        handle:report({ message = clip(task:outcome()) })
        handle:finish()
        handles[key] = nil
    end)
end

-- ---------------------------------------------------------------------------
-- Public API for top-level action handles
-- ---------------------------------------------------------------------------

--- Create a top-level progress handle for a user action.
--- Returns a handle object with :report(), :finish(), :cancel() or nil
--- if fidget is not available.
--- @param title string e.g., "Launching ScenePluginTest: debug"
--- @return table|nil handle
function M.start_action(title)
    if not fidget_progress then return nil end
    local key = "action:" .. title .. ":" .. tostring(os.clock())
    return create_handle(key, "", title)
end

--- The progress entry of a user action that runs a build, configure or
--- clean (spec §19.16 "Editor operations"): none in `daemon` mode — the
--- routed task's own entry is its one progress entry, and an operation the
--- daemon cannot carry is refused ("Availability") — and in the
--- `in-process` mode exactly `start_action(title)`.
--- @param title string
--- @return table|nil handle
function M.start_op_action(title)
    if require("loomworks.daemon.observer").current() then return nil end
    return M.start_action(title)
end

--- Report progress on a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message string
function M.report(handle, message)
    if handle then handle:report({ message = clip(message) }) end
end

--- Finish a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message? string final message
function M.finish(handle, message)
    if not handle then return end
    if message then handle:report({ message = clip(message) }) end
    handle:finish()
end

--- Cancel a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message? string
function M.fail(handle, message)
    if not handle then return end
    if message then handle:report({ message = clip(message) }) end
    handle:cancel()
end

--- Cancel and clear every tracked fidget handle.
---
--- Recovery hatch for cases where a handle has been orphaned —
--- typically because an event sequence the integration relies on
--- (daemon_task_stopped, dap event_initialized /
--- event_terminated) didn't fire as expected, leaving the popup
--- spinning forever after every overseer task has already
--- completed. Bound to `:LoomworksFidgetClear`.
---
--- Returns the number of handles cleared so the command can give
--- the user useful feedback rather than silently doing nothing.
--- Safe to call when fidget.nvim is not loaded — returns 0.
--- @return integer cleared
function M.clear()
    if not fidget_progress then return 0 end
    local n = 0
    for key, handle in pairs(handles) do
        pcall(function() handle:cancel() end)
        handles[key] = nil
        n = n + 1
    end
    return n
end

return M
