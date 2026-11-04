--- loomworks/ui/sections/tasks.lua — Tasks section.
---
--- Surfaces the runtime state of long-running operations: every task
--- observed through `Tasks/1` (core §19.16) — the editor's own and other
--- clients'. The section is the diagnostic surface for "why is my build
--- still running?".
---
--- Per-row Enter opens a `vim.ui.select` menu rather than firing
--- directly: a misclicked cancel costs a full rebuild on a large project.
--- The menu acts as a one-keystroke confirmation; Esc dismisses without
--- action.
---
--- The section renders nothing when no task runs — keeps the status page
--- quiet during normal idle state. Slotted near the bottom of the status
--- page (after Profiles / Projects / LSP / Debug / SDKs) because it's only
--- interesting when something is wrong; the day-to-day reader sees the
--- workspace state first.

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

--- Rows of a remote task (one per unit; one for the profile when it has
--- none): `▸ <project> : <configuration> — <kind>`, then `{pct}%`, the
--- elapsed time and the dimmed origin marker as the last token (spec/ui.md
--- §1.9).
--- @param task loomworks.RemoteTask
--- @param now number
--- @return {[1]: string, [2]: string}[][] chunk lists
local function remote_rows(task, now)
    local detail = {}
    if task.pct then detail[#detail + 1] = task.pct .. "%" end
    local s = format_elapsed(task:elapsed(now))
    if s ~= "" then detail[#detail + 1] = s end
    local tail = #detail > 0 and ("  " .. table.concat(detail, "  ")) or ""
    local origin = task:origin_label()
    local function row(text)
        local chunks = { { text .. tail, "DiagnosticInfo" } }
        if origin then chunks[#chunks + 1] = { "  " .. origin, "Comment" } end
        return chunks
    end
    -- A task carrying steps (a launch target's build or preparation, step
    -- 5t) keeps one row, which follows its current step (spec/ui.md §1.9).
    if task.steps then
        local step = task:step_text()
        return { row(string.format("▸ %s — %s%s", task.profile_name or task.name, task.kind,
            step and (": " .. step) or "")) }
    end
    local rows = {}
    for _, u in ipairs(task.units) do
        rows[#rows + 1] = row(string.format("▸ %s : %s — %s", u.project, u.configuration or "?", task.kind))
    end
    if #rows == 0 then
        rows[1] = row(string.format("▸ %s — %s", task.profile_name or task.name, task.kind))
    end
    return rows
end

--- A remote task's rows (core §19.16): Enter offers `Show output`, `Open
--- overseer` while overseer lists it (step 5k C1b, loomworks.daemon.task_runner)
--- and, for a task the editor itself started through a call (step 5k,
--- `task.owned`), `Cancel task` (`Tasks/1.cancel`); another client's task
--- belongs to it (never cancelled from here, §19.15).
--- @param tree loomworks.Tree
--- @param task loomworks.RemoteTask
--- @param now number
local function render_remote(tree, task, now)
    for _, chunks in ipairs(remote_rows(task, now)) do
        tree:item(chunks, {
            hl = "DiagnosticInfo",
            spinning = true,
            direct = true,
            on_enter = function()
                local runner = require("loomworks.daemon.task_runner")
                local choices = { "Show output" }
                if task.owned then choices[#choices + 1] = "Cancel task" end
                -- Its single overseer task (core §19.16 "Tasks in the task
                -- runner"), unless overseer cannot host it.
                if runner.overseer_task(task) then choices[#choices + 1] = "Open overseer" end
                vim.ui.select(choices, {
                    prompt = "Task " .. task.name .. ":",
                    format_item = function(s) return s end,
                }, function(choice)
                    if choice == "Show output" then require("loomworks.ui.remote_output").show(task) end
                    if choice == "Cancel task" then require("loomworks.daemon.editor_ops").cancel(task) end
                    if choice == "Open overseer" then runner.open(task) end
                end)
            end,
        })
    end
end

--- @param tree loomworks.Tree
--- @param ctx { lw: table }
return function(tree, ctx)
    local remote = ctx.lw.get_daemon_tasks()

    -- Quiet section: render nothing when there's no state worth
    -- showing. Avoid adding noise to the steady-state status page.
    if #remote == 0 then return end

    local now = (vim.uv or vim.loop).hrtime() / 1e9

    tree:leaf({
        { "Tasks  ", "Title" },
        { string.format("[%d active]", #remote), "Comment" },
    })
    tree:blank()

    -- Ordered by start.
    local entries = {}
    for i, task in ipairs(remote) do
        entries[#entries + 1] = { task = task, start = task.start_time or now, seq = i }
    end
    table.sort(entries, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        return a.seq < b.seq
    end)
    for _, entry in ipairs(entries) do
        render_remote(tree, entry.task, now)
    end

    tree:blank()
end
