--- loomworks/ui/sections/orphaned.lua — Orphaned build dirs section.
---
--- Shows leftover build directories not referenced by any profile.
--- Flat list of paths — no project grouping, no status labels.
--- Actions: delete individual dirs, or clean all at once — each a
--- `Maintenance/1.execute_deletion` through ui/model_calls naming the row
--- (an orphaned entry's id in `daemon` mode, a stray directory's path as
--- listed; step 5o C2c-2), confirmed with the listing it answers.

local actions = require("loomworks.ui.actions")
local helpers = require("loomworks.ui.helpers")

--- Make a path relative to workspace root for display.
--- @param ws_root string normalized workspace root
--- @param abs string absolute path
--- @return string
local function rel_display(ws_root, abs)
    local norm = vim.fs.normalize(abs)
    local root = vim.fs.normalize(ws_root)
    if norm:sub(1, #root) == root then
        local rel = norm:sub(#root + 1)
        if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
        return rel ~= "" and rel or "."
    end
    return abs
end

--- Render the orphaned build dirs section.
--- Flat list of paths — orphaned cache entries and stray dirs merged together.
--- @param tree loomworks.Tree
--- @param ctx table { view, mode, ref, ws } the workspace view's `orphaned`
return function(tree, ctx)
    local orphans = ctx.view.orphaned.configurations
    local stray_dirs = ctx.view.orphaned.stray_dirs

    if #orphans == 0 and #stray_dirs == 0 then return end

    tree:leaf({{"Orphaned Build Dirs  ", "Title"}, {"[D] delete", "Comment"}})
    tree:blank()

    -- Dedup on lowercased paths — Windows filesystems are case-insensitive.
    local seen_paths = {}
    local is_win = vim.fn.has("win32") == 1

    local function norm_path(p)
        local n = vim.fs.normalize(p)
        return is_win and n:lower() or n
    end

    local ws_root = ctx.ws and ctx.ws.root or ""
    for _, orphan in ipairs(orphans) do
        local display = ".nvim/" .. orphan.key
        tree:item(display, {
            hl = "Comment",
            on_delete = helpers.actionable(ctx, orphan) and actions.delete_orphaned_config(orphan, ctx.ws) or nil,
        })
        -- Track the absolute path to avoid duplicating with stray dirs
        if orphan.build_dir then
            seen_paths[norm_path(orphan.build_dir)] = true
        end
    end

    -- Stray build directories (on disk but not in cache) — skip if already shown
    for _, dir in ipairs(stray_dirs) do
        if not seen_paths[norm_path(dir)] then
            local display = rel_display(ws_root, dir)
            tree:item(display, {
                hl = "Comment",
                on_delete = actions.delete_stray_dir(dir, ctx.ws),
            })
        end
    end

    tree:item("▸ Clean all", {
        hl = "LoomworksActionable",
        direct = true,
        on_enter = actions.delete_orphans(ctx.ws),
    })

    tree:blank()
end
