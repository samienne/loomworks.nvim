--- loomworks/ui/sections/orphaned.lua — Orphaned build dirs section.
---
--- Shows leftover build directories not referenced by any profile.
--- Flat list of paths — no project grouping, no status labels.
--- Actions: delete individual dirs, or clean all at once.

local actions = require("loomworks.ui.actions")

--- Show the orphan cleanup dialog and execute cleanup on confirm.
local function clean_all_orphans()
    local lw = require("loomworks")
    local ws = lw.get_workspace()
    if not ws then return end

    local workspace_view = require("loomworks.workspace_view")
    local ctx = workspace_view.compute_orphan_cleanup_context(ws)

    if #ctx.orphaned_configs == 0 and #ctx.stray_dirs == 0 then
        vim.notify("loomworks: nothing to clean", vim.log.levels.INFO)
        return
    end

    local dialog = require("loomworks.ui.dialog")
    dialog.show({
        title = "Clean Orphaned Build Dirs",
        lines = ctx.lines,
        highlights = ctx.highlights,
        max_height = 30,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                workspace_view.execute_orphan_cleanup(
                    ws, ctx.orphaned_configs, ctx.stray_dirs, function()
                    vim.notify("loomworks: orphaned build dirs cleaned",
                        vim.log.levels.INFO)
                end)
            end,
        },
    })
end

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
--- @param ctx table { lw }
return function(tree, ctx)
    local lw = ctx.lw
    local orphans = lw.get_orphaned_configs()

    local workspace_view = require("loomworks.workspace_view")
    local ws = lw.get_workspace()
    local stray_dirs = ws and workspace_view.find_stray_build_dirs(ws) or {}

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

    local ws_root = ws and ws.root or ""
    for _, orphan in ipairs(orphans) do
        local display = ".nvim/" .. (orphan.build_dir_key or orphan.config_key)
        tree:item(display, {
            hl = "Comment",
            on_delete = actions.delete_orphaned_config(orphan),
        })
        -- Track the absolute path to avoid duplicating with stray dirs
        local entry = orphan.cached_entry or {}
        if entry.build_dir then
            seen_paths[norm_path(entry.build_dir)] = true
        end
    end

    -- Stray build directories (on disk but not in cache) — skip if already shown
    for _, dir in ipairs(stray_dirs) do
        if not seen_paths[norm_path(dir)] then
            local display = rel_display(ws_root, dir)
            tree:item(display, {
                hl = "Comment",
                on_delete = actions.delete_stray_dir(dir),
            })
        end
    end

    tree:item("▸ Clean all", {
        hl = "LoomworksActionable",
        direct = true,
        on_enter = clean_all_orphans,
    })

    tree:blank()
end
