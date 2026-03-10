--- loomworks/ui/sections/projects.lua — Projects section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

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

--- Render the projects section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile_key, projects }
return function(tree, ctx)
  local lw = ctx.lw
  local all_profiles = ctx.all_profiles
  local active_profile_key = ctx.active_profile_key
  local projects = ctx.projects
  if not projects or not next(projects) then return end

  tree:leaf("Projects", "Title")
  tree:blank()

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

          for _, cname in ipairs(config_names) do
            local cdata = proj.configurations[cname]

            -- Check if any profile has a running task for this variant
            local config_has_running = false
            for _, profile in pairs(all_profiles) do
              local pp = profile:project(key)
              if pp and pp.variant == cname then
                if lw.get_running_action(pp.project_key, pp.config_key) then
                  config_has_running = true
                  break
                end
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

              -- List all profiles that map to this variant
              local profile_entries = {}
              for profile_key, profile in pairs(all_profiles) do
                local pp = profile:project(key)
                if pp and pp.variant == cname then
                  profile_entries[#profile_entries + 1] = {
                    profile_key = profile_key,
                    pp = pp,
                    is_active = profile_key == active_profile_key,
                  }
                end
              end

              table.sort(profile_entries, function(a, b)
                if a.is_active ~= b.is_active then return a.is_active end
                return a.profile_key < b.profile_key
              end)

              for _, entry in ipairs(profile_entries) do
                local pp = entry.pp
                local cached = pp:cached_state()
                local config_status, status_hl, progress_str, is_spinning =
                    helpers.resolve_config_status(pp.project_key, pp.config_key, cached)

                if entry.is_active and not is_spinning then
                  status_hl = "DiagnosticOk"
                end

                tree:node(entry.profile_key .. progress_str, {
                  fold_key = "config_profile:" .. key .. ":" .. cname .. ":"
                      .. entry.profile_key,
                  spinning = is_spinning,
                  hl = status_hl,
                  on_enter = actions.activate(entry.profile_key),
                  on_build = actions.build(entry.profile_key),
                  on_configure = actions.configure(entry.profile_key),
                  on_delete = actions.delete_config(pp.project_key, pp.config_key),
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
