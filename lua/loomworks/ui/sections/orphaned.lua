--- loomworks/ui/sections/orphaned.lua — Orphaned configurations section.
---
--- Shows cached configs with build state that are not referenced by any
--- profile. Only action allowed: delete.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render the orphaned configurations section.
--- Only shown when orphans exist.
--- @param tree loomworks.Tree
--- @param ctx table { lw }
return function(tree, ctx)
  local lw = ctx.lw
  local orphans = lw.get_orphaned_configs()
  if #orphans == 0 then return end

  tree:leaf({{"Orphaned Configurations  ", "Title"}, {"[D] delete", "Comment"}})
  tree:blank()

  -- Group by project
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
        local config_status, status_hl, progress_str, is_spinning =
            helpers.resolve_config_status_global(
              orphan.project_key, orphan.config_key, orphan.cached)

        tree:node(orphan.config_key .. " (" .. config_status .. ")" .. progress_str, {
          fold_key = "orphaned:" .. orphan.project_key .. ":" .. orphan.config_key,
          spinning = is_spinning,
          hl = status_hl,
          on_delete = actions.delete_orphaned_config(orphan.project_key, orphan.config_key),
        }, function()
          helpers.render_cached_details(tree, config_status, status_hl, orphan.cached)
        end)
      end
    end)
  end

  tree:blank()
end
