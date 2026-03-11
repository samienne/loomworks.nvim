--- loomworks/ui/sections/projects.lua — Projects section renderer.
---
--- Profile-agnostic: shows cached state and detected tools directly,
--- without any profile context. Uses global running checks.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")
local merge = require("loomworks.merge")

--- Sort project keys: non-orphaned first (alphabetical), orphaned last.
--- @param projects table<string, loomworks.Project>
--- @return string[]
local function sorted_project_keys(projects)
  local normal, orphaned = {}, {}
  for key, proj in pairs(projects) do
    if proj.orphaned then
      orphaned[#orphaned + 1] = key
    else
      normal[#normal + 1] = key
    end
  end
  table.sort(normal)
  table.sort(orphaned)
  for _, key in ipairs(orphaned) do
    normal[#normal + 1] = key
  end
  return normal
end

--- Look up a tool display label from detected tools.
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @param mod_type string
--- @param tool_key string
--- @return string
local function get_tool_display(tools_by_type, mod_type, tool_key)
  local tools = tools_by_type[mod_type]
  if tools then
    for _, dt in ipairs(tools) do
      if dt.tool_key == tool_key then
        return dt.tool_label or tool_key
      end
    end
  end
  return tool_key
end

--- Collect tool entries for a keyed-tool variant: cached entries + unconfigured detected tools.
--- @param proj loomworks.Project
--- @param variant string
--- @param tools_by_type table<string, loomworks.DetectedTool[]>
--- @return table[] entries { config_key, tool_key, display_label, cached }
local function collect_tool_entries(proj, variant, tools_by_type)
  local entries = {}
  local seen_tool_keys = {}

  -- 1. Cached entries for this variant
  if proj.cached_configurations then
    for config_key, cached_config in pairs(proj.cached_configurations) do
      local v, tk = merge.parse_profile_key(config_key)
      if v == variant and tk then
        entries[#entries + 1] = {
          config_key = config_key,
          tool_key = tk,
          display_label = get_tool_display(tools_by_type, proj.type, tk),
          cached = cached_config,
        }
        seen_tool_keys[tk] = true
      end
    end
  end

  -- 2. Detected tools not yet cached for this variant
  local relevant_tools = tools_by_type[proj.type] or {}
  for _, dt in ipairs(relevant_tools) do
    if dt.tool_key and not seen_tool_keys[dt.tool_key] then
      entries[#entries + 1] = {
        config_key = variant .. ":" .. dt.tool_key,
        tool_key = dt.tool_key,
        display_label = dt.tool_label or dt.tool_key,
        cached = nil,
      }
    end
  end

  table.sort(entries, function(a, b) return a.config_key < b.config_key end)
  return entries
end

--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, projects }
return function(tree, ctx)
  local lw = ctx.lw
  local projects = ctx.projects
  if not projects or not next(projects) then return end

  tree:leaf("Projects", "Title")
  tree:blank()

  local tools_by_type = lw.get_tools_by_type()
  local sorted = sorted_project_keys(projects)

  for _, key in ipairs(sorted) do
    local proj = projects[key]
    local proj_running = proj:running_action()
    local is_active_project = proj.configuration ~= nil and not proj.orphaned
    local proj_hl = proj_running and "DiagnosticWarn"
        or (is_active_project and "DiagnosticOk" or nil)

    local type_tag = "[" .. proj.type .. "]"
    local orphan_tag = proj.orphaned and " (orphaned)" or ""
    local refresh_tag = proj.needs_refresh and " !" or ""

    tree:node(key .. " " .. type_tag .. orphan_tag .. refresh_tag, {
      fold_key = "project:" .. key,
      spinning = proj_running ~= nil,
      hl = proj_hl,
    }, function()
      tree:leaf("Path: " .. (proj.path or key), "Comment")

      if proj.needs_refresh and proj.refresh_reasons and #proj.refresh_reasons > 0 then
        for _, reason in ipairs(proj.refresh_reasons) do
          tree:leaf("! " .. reason, "DiagnosticWarn")
        end
      end

      if proj.configurations and next(proj.configurations) then
        tree:group("Configurations:", "Comment", function()
          local config_names = {}
          for name in pairs(proj.configurations) do
            config_names[#config_names + 1] = name
          end
          table.sort(config_names)

          local project_has_keyed_tools = lw.module_has_keyed_tools(proj.type)

          for _, cname in ipairs(config_names) do
            local cdata = proj.configurations[cname]

            -- Check running state across all config_keys for this variant
            local config_has_running = false
            if project_has_keyed_tools then
              local entries = collect_tool_entries(proj, cname, tools_by_type)
              for _, entry in ipairs(entries) do
                if lw.get_running_action(key, entry.config_key) then
                  config_has_running = true
                  break
                end
              end
            else
              if lw.get_running_action(key, cname) then
                config_has_running = true
              end
            end

            local config_hl = config_has_running and "DiagnosticWarn" or "Comment"

            local brief = {}
            if cdata.toolchain_locked then brief[#brief + 1] = "toolchain-locked" end
            if cdata.role then brief[#brief + 1] = "role:" .. cdata.role end
            local brief_str = #brief > 0
                and ("  (" .. table.concat(brief, ", ") .. ")") or ""

            tree:node(cname .. brief_str, {
              fold_key = "config:" .. key .. ":" .. cname,
              spinning = config_has_running,
              hl = config_hl,
              on_delete = actions.delete_configuration(key, cname),
            }, function()
              if cdata.toolchain then
                tree:leaf("Toolchain: " .. tostring(cdata.toolchain), "Comment")
              end
              if cdata.generator then
                tree:leaf("Generator: " .. cdata.generator, "Comment")
              end

              if project_has_keyed_tools then
                -- Keyed-tool modules: show each tool (cached + unconfigured)
                local entries = collect_tool_entries(proj, cname, tools_by_type)
                for _, entry in ipairs(entries) do
                  local config_status, status_hl, progress_str, is_spinning =
                      helpers.resolve_config_status_global(key, entry.config_key, entry.cached)

                  tree:node(entry.display_label .. progress_str, {
                    fold_key = "config_tool:" .. key .. ":" .. entry.config_key,
                    spinning = is_spinning,
                    hl = status_hl,
                    on_build = actions.build_configuration(key, entry.config_key),
                    on_configure = actions.configure_configuration(key, entry.config_key),
                    on_delete = entry.cached
                        and actions.delete_config(key, entry.config_key) or nil,
                    on_pin = actions.pin_config(key, entry.config_key),
                  }, function()
                    helpers.render_cached_details(tree, config_status, status_hl, entry.cached)
                  end)
                end
              else
                -- Non-keyed modules: show single status
                local cached = proj.cached_configurations
                    and proj.cached_configurations[cname]
                local config_status, status_hl, progress_str, is_spinning =
                    helpers.resolve_config_status_global(key, cname, cached)

                tree:node("Status: " .. config_status .. progress_str, {
                  fold_key = "config_status:" .. key .. ":" .. cname,
                  spinning = is_spinning,
                  hl = status_hl,
                  on_build = actions.build_configuration(key, cname),
                  on_configure = actions.configure_configuration(key, cname),
                  on_delete = cached and actions.delete_configuration(key, cname) or nil,
                  on_pin = actions.pin_config(key, cname),
                }, function()
                  helpers.render_cached_details(tree, config_status, status_hl, cached)
                end)
              end
            end)
          end
        end)
      end

      tree:blank()
    end)
  end
end
