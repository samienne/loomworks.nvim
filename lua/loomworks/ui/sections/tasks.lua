--- loomworks/ui/sections/tasks.lua — Tasks & build-dir locks section.
---
--- Surfaces the runtime state of long-running operations: every
--- active loomworks-managed task and every held build-dir lock. The
--- section is the diagnostic surface for "why is my build stuck in
--- PENDING?" — when a previous task crashed without firing the
--- lifecycle event that releases its lock, the next task queues
--- behind it indefinitely. The lock list makes that visible; the
--- per-row force-release action makes it recoverable without
--- restarting nvim.
---
--- Per-row Enter opens a `vim.ui.select` menu rather than firing
--- directly: even though both actions are recoverable, a misclicked
--- cancel costs a full rebuild on a large project. The menu acts as a
--- one-keystroke confirmation; Esc dismisses without action. The
--- top-level "reset everything" action uses the heavier confirmation
--- dialog because it touches many items at once.
---
--- The section renders nothing when no tasks are active and no locks
--- are held — keeps the status page quiet during normal idle state.
--- Slotted near the bottom of the status page (after Profiles /
--- Projects / LSP / Debug / SDKs) because it's only interesting when
--- something is wrong; the day-to-day reader sees the workspace state
--- first, not the recovery surface.

--- Format a duration in seconds into a compact label.
--- @param seconds number|nil
--- @return string
local function format_elapsed(seconds)
    if not seconds or seconds < 0 then return "" end
    if seconds < 60 then
        return string.format("%ds", math.floor(seconds))
    end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%dm%ds", m, s)
end

--- Compose the trailing detail string for a task row:
---   "[12/50] / 1m4s" or just "1m4s" when no progress data.
--- @param task loomworks.ActiveTaskInfo
--- @param now_clock number current vim.uv.hrtime() / 1e9
--- @return string
local function task_detail(task, now_clock)
    local parts = {}
    if task.progress and task.progress.current and task.progress.total then
        parts[#parts + 1] = string.format("[%d/%d]",
            task.progress.current, task.progress.total)
    end
    if task.start_time then
        local elapsed = now_clock - task.start_time
        local s = format_elapsed(elapsed)
        if s ~= "" then parts[#parts + 1] = s end
    end
    return table.concat(parts, "  ")
end

--- Compose the trailing detail string for a lock row.
--- @param lock loomworks.BuildDirLockInfo
--- @return string
local function lock_detail(lock)
    local parts = {}
    if lock.exclusive then parts[#parts + 1] = "exclusive" end
    if lock.shared_count > 0 then
        parts[#parts + 1] = string.format("shared(%d)", lock.shared_count)
    end
    if lock.queue_depth > 0 then
        parts[#parts + 1] = string.format("queued(%d)", lock.queue_depth)
    end
    if #parts == 0 then parts[#parts + 1] = "idle" end
    return table.concat(parts, " · ")
end

--- Confirm + execute the nuclear reset.
--- @param lw table loomworks public API
local function reset_all(lw)
    local dialog = require("loomworks.ui.dialog")
    local tasks = lw.get_active_tasks()
    local locks = lw.get_build_dir_locks_info()

    local lines = {
        "Force-reset all task & lock state?",
        "",
        string.format("  active tasks: %d", #tasks),
        string.format("  held locks:   %d", #locks),
        "",
        "This will:",
        "  • Stop every running loomworks-managed task.",
        "  • Drop every build-dir lock (exclusive + shared + queue).",
        "",
        "Use this only when something is stuck. The build itself",
        "is not damaged; restart the build manually after reset.",
        "",
        "  [y] confirm    [n] cancel",
    }

    dialog.show({
        title = "Reset task state",
        lines = lines,
        max_height = 20,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                for _, t in ipairs(tasks) do
                    lw.cancel_task(t.task_id)
                end
                for _, l in ipairs(locks) do
                    lw.force_release_build_dir_lock(l.dir)
                end
            end,
        },
    })
end

--- @param tree loomworks.Tree
--- @param ctx { lw: table }
return function(tree, ctx)
    local lw = ctx.lw
    local tasks = lw.get_active_tasks and lw.get_active_tasks() or {}
    local locks = lw.get_build_dir_locks_info
        and lw.get_build_dir_locks_info() or {}

    -- Quiet section: render nothing when there's no state worth
    -- showing. Avoid adding noise to the steady-state status page.
    if #tasks == 0 and #locks == 0 then return end

    local now = (vim.uv or vim.loop).hrtime() / 1e9

    tree:leaf({
        { "Tasks  ", "Title" },
        { string.format("[%d active]", #tasks), "Comment" },
    })
    tree:item("⟲ Reset all task & lock state", {
        hl = "DiagnosticWarn",
        direct = true,
        on_enter = function() reset_all(lw) end,
    })
    tree:blank()

    for _, task in ipairs(tasks) do
        local label = string.format("▸ %s : %s — %s",
            task.project_key or "?",
            task.config_key or "?",
            task.action or "?")
        local detail = task_detail(task, now)
        if detail ~= "" then label = label .. "  " .. detail end
        local task_id = task.task_id
        local task_label = string.format("%s:%s (%s)",
            task.project_key or "?",
            task.config_key or "?",
            task.action or "?")
        tree:item(label, {
            hl = "DiagnosticInfo",
            spinning = true,
            direct = true,
            on_enter = function()
                vim.ui.select(
                    { "Cancel task", "Open overseer" },
                    {
                        prompt = "Task " .. task_label .. ":",
                        format_item = function(s) return s end,
                    },
                    function(choice)
                        if not choice then return end
                        if choice == "Cancel task" then
                            lw.cancel_task(task_id)
                        elseif choice == "Open overseer" then
                            -- Best-effort: open the overseer task list
                            -- so the user can inspect output. We don't
                            -- focus a specific task because there's no
                            -- stable overseer API for that yet.
                            local ok, ov = pcall(require, "overseer")
                            if ok and ov.open then
                                ov.open({ enter = true })
                            end
                        end
                    end
                )
            end,
        })
    end

    if #locks > 0 then
        if #tasks > 0 then tree:blank() end
        tree:leaf("Build directory locks", "Title")
        for _, lock in ipairs(locks) do
            local detail = lock_detail(lock)
            local label = string.format("▸ %s  %s", lock.dir, detail)
            local hl = (lock.queue_depth > 0 and not lock.exclusive
                    and lock.shared_count == 0)
                and "DiagnosticWarn"
                or "DiagnosticInfo"
            local dir = lock.dir
            tree:item(label, {
                hl = hl,
                direct = true,
                on_enter = function()
                    vim.ui.select(
                        { "Force-release lock" },
                        {
                            prompt = "Lock " .. dir .. ":",
                            format_item = function(s) return s end,
                        },
                        function(choice)
                            if choice == "Force-release lock" then
                                lw.force_release_build_dir_lock(dir)
                            end
                        end
                    )
                end,
            })
        end
    end

    tree:blank()
end
