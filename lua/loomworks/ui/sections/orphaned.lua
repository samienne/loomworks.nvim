--- loomworks/ui/sections/orphaned.lua — Orphaned items section.
---
--- Shows orphaned cached configs (not referenced by any profile) and
--- stray build directories (on disk but not in cache).
--- Actions: delete individual items, or clean all orphans at once.

local helpers = require("loomworks.ui.helpers")
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
        title = "Clean Orphaned Items",
        lines = ctx.lines,
        highlights = ctx.highlights,
        max_height = 30,
        keys = {
            n = "close",
            y = function(self)
                self:close()
                workspace_view.execute_orphan_cleanup(
                    ws, ctx.orphaned_configs, ctx.stray_dirs, function()
                    vim.notify("loomworks: orphaned items cleaned",
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

--- Render the orphaned items section.
--- Shown when orphaned configs or stray build dirs exist.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
    local lw = ctx.lw
    local orphans = lw.get_orphaned_configs()

    local workspace_view = require("loomworks.workspace_view")
    local ws = lw.get_workspace()
    local stray_dirs = ws and workspace_view.find_stray_build_dirs(ws) or {}

    if #orphans == 0 and #stray_dirs == 0 then return end

    tree:leaf({{"Orphaned Items  ", "Title"}, {"[D] delete", "Comment"}})
    tree:blank()

    -- Orphaned cached configs grouped by project
    if #orphans > 0 then
        local by_project = {}
        local project_order = {}
        for _, orphan in ipairs(orphans) do
            if not by_project[orphan.project_key] then
                by_project[orphan.project_key] = {}
                project_order[#project_order + 1] = orphan.project_key
            end
            by_project[orphan.project_key][#by_project[orphan.project_key] + 1] = orphan
        end

        for _, project_key in ipairs(project_order) do
            local entries = by_project[project_key]

            tree:node(project_key, {
                fold_key = "orphaned_project:" .. project_key,
                hl = "LoomworksUnconfigured",
            }, function()
                for _, orphan in ipairs(entries) do
                    local unit = orphan.unit
                    local config_status, status_hl, progress_str, is_spinning =
                            helpers.resolve_config_status_global(unit, orphan.cached)

                    tree:node(orphan.config_key .. " (" .. config_status .. ")" .. progress_str, {
                        fold_key = "orphaned:" .. orphan.project_key .. ":" .. orphan.config_key,
                        spinning = is_spinning,
                        hl = status_hl,
                        on_delete = actions.delete_orphaned_config(unit),
                    }, function()
                        helpers.render_cached_details(tree, config_status, status_hl, orphan.cached, nil, unit)
                    end)
                end
            end)
        end
    end

    -- Stray build directories
    if #stray_dirs > 0 then
        local ws_root = ws and ws.root or ""
        for _, dir in ipairs(stray_dirs) do
            local display = rel_display(ws_root, dir)
            tree:item(display .. " (stray)", {
                hl = "LoomworksUnconfigured",
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
