--- loomworks/ui/sections/diagnostics.lua — Diagnostics section.
---
--- Aggregates structural diagnostics from `Workspace:diagnostics()`
--- (incomplete profiles, source-missing configurations, stale
--- configuration_set mappings, unresolved inherits) into a single
--- list at the top of the status page.
---
--- Each entry's source object also has its own inline indicator
--- elsewhere on the page (`[incomplete]`, `⚠ missing source`, ...);
--- this section is the at-a-glance view, those are the in-context
--- views. Both surfaces stay in sync because the section reads
--- from the same predicates the inline indicators do.
---
--- On Enter: jumps to the relevant tree node by `fold_key`. Sets
--- `m'` first so `<C-o>` returns the user to the diagnostics
--- entry. Entries without a `target_fold_key` (informational only)
--- are direct-action no-ops.

--- Find the line number of the tree node with the given fold_key.
--- @param tree loomworks.Tree
--- @param fold_key string
--- @return integer|nil line number (1-based)
local function find_line_for_fold_key(tree, fold_key)
    if not tree.line_meta then return nil end
    for ln, w in pairs(tree.line_meta) do
        if w.fold_key == fold_key then return ln end
    end
    return nil
end

--- Jump the cursor to a tree line, preserving `<C-o>`/`<C-i>`.
--- @param line integer 1-based line number
local function jump_to_line(line)
    -- Set the prior-position mark so <C-o> returns the user to
    -- the diagnostics entry. `m'` is the standard mechanism Vim
    -- uses internally for jumplist updates on long-distance moves.
    pcall(vim.cmd, "normal! m'")
    local win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
end

--- Render the diagnostics section.
--- @param tree loomworks.Tree
--- @param ctx { lw: table }
return function(tree, ctx)
    local lw = ctx.lw
    local ws = lw.get_workspace()
    if not ws or not ws.diagnostics then return end

    local diagnostics = ws:diagnostics()
    if #diagnostics == 0 then return end

    local n_warn, n_err = 0, 0
    for _, d in ipairs(diagnostics) do
        if d.severity == "error" then
            n_err = n_err + 1
        else
            n_warn = n_warn + 1
        end
    end
    local summary_parts = {}
    if n_err > 0 then summary_parts[#summary_parts + 1] = n_err .. " error(s)" end
    if n_warn > 0 then summary_parts[#summary_parts + 1] = n_warn .. " warning(s)" end
    local summary = table.concat(summary_parts, ", ")

    tree:leaf({
        { "Diagnostics  ", "Title" },
        { summary, "Comment" },
    })
    tree:blank()

    for _, d in ipairs(diagnostics) do
        local hl = d.severity == "error"
            and "DiagnosticError" or "DiagnosticWarn"
        local icon = d.severity == "error" and "✗ " or "⚠ "
        local label = icon .. "[" .. d.source .. "] " .. d.message

        local on_enter = nil
        if d.target_fold_key then
            local target = d.target_fold_key
            on_enter = function()
                local line = find_line_for_fold_key(tree, target)
                if line then jump_to_line(line) end
            end
        end

        tree:item(label, {
            hl = hl,
            direct = on_enter ~= nil,
            on_enter = on_enter,
        })
    end

    tree:blank()
end
