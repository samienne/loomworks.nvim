--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param cs loomworks.ConfigurationSet
--- @param tool_entries loomworks.ToolEntry[]
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile_key string
--- @param lw table loomworks API
local function render_set_details(tree, cs, tool_entries, all_profiles, active_profile_key, lw)
  local set_name = cs.name
  tree:group("Projects:", "Comment", function()
    local proj_names = {}
    for project, variant in pairs(cs.mappings) do
      proj_names[#proj_names + 1] = { key = project.key, variant = variant }
    end
    table.sort(proj_names, function(a, b) return a.key < b.key end)
    for _, entry in ipairs(proj_names) do
      tree:leaf(entry.key .. " → " .. entry.variant, "Comment")
    end
  end)

  if #tool_entries > 0 then
    tree:group({{"Tools:  ", "LoomworksActionable"}, {"[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
      for _, entry in ipairs(tool_entries) do
        local profile_key = entry.profile_key
        local is_active = profile_key == active_profile_key
        -- Only show running/configured state if a cached profile exists
        local profile = entry.cached and all_profiles[profile_key] or nil
        local profile_running = profile and profile:is_running() or false
        local already_configured = profile and profile:is_configured() or false

        local suffix, hl, marker
        if profile_running then
          local status_label = select(1, profile:status())
          marker = helpers.status_marker(status_label)
          suffix = " (" .. status_label .. ")"
          local pps = profile:projects()
          local pct = helpers.aggregate_progress(pps)
          if pct then suffix = suffix .. " " .. pct .. "%" end
          suffix = suffix .. helpers.format_elapsed(profile:operation_elapsed())
          hl = is_active and "LoomworksActive" or "LoomworksRunning"
        elseif is_active then
          hl = "LoomworksActive"
          local op = profile and profile:operation()
          if op and op.message then
            local p_label = already_configured and select(1, profile:status()) or "unconfigured"
            marker = helpers.status_marker(p_label)
            suffix = " — " .. op.message
          else
            local p_label = already_configured and select(1, profile:status()) or "unconfigured"
            marker = helpers.status_marker(p_label)
            suffix = " (" .. p_label .. ")"
          end
        elseif already_configured then
          local p_label = select(1, profile:status())
          marker = helpers.status_marker(p_label)
          local op = profile:operation()
          if op and op.message then
            suffix = " — " .. op.message
          else
            suffix = " (" .. p_label .. ")"
          end
          if p_label == "failed_configure" or p_label == "failed_build"
              or p_label:match("failed") then
            hl = "LoomworksFailed"
          else
            hl = "LoomworksConfigured"
          end
        else
          marker = helpers.status_marker("unconfigured")
          suffix = ""
          hl = "LoomworksUnconfigured"
        end

        local display = entry.tool_label or entry.tool_key

        tree:item(display .. suffix, {
          marker = marker,
          spinning = profile_running,
          hl = hl,
          on_enter = profile and actions.activate(profile)
              or actions.activate_new(cs, entry),
          on_build = profile and actions.build(profile)
              or actions.build_new(cs, entry),
          on_configure = profile and actions.configure(profile)
              or actions.configure_new(cs, entry),
          on_rebuild = profile and actions.rebuild(profile) or nil,
          on_clean = profile and actions.clean(profile) or nil,
          on_delete = profile and actions.delete_profile(profile) or nil,
        })
      end
    end)
  end
end

--- Render the configuration sets section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile_key, config_sets, tool_entries }
return function(tree, ctx)
  local config_sets = ctx.config_sets
  if not config_sets or not next(config_sets) then return end

  local all_profiles = ctx.all_profiles
  local active_profile_key = ctx.active_profile_key
  local tool_entries = ctx.tool_entries or {}
  local lw = ctx.lw

  tree:leaf("Configuration Sets", "Title")
  tree:blank()

  local sorted = {}
  for name, cs in pairs(config_sets) do
    sorted[#sorted + 1] = { name = name, cs = cs }
  end
  table.sort(sorted, function(a, b) return a.name < b.name end)

  for _, entry in ipairs(sorted) do
    local cs = entry.cs
    local active_profile = all_profiles[active_profile_key]
    local is_active_set = active_profile and active_profile.configuration_set == cs.name
    local set_hl = is_active_set and "LoomworksActive" or "LoomworksActionable"

    tree:node(cs.name, {
      fold_key = "set:" .. cs.name,
      hl = set_hl,
    }, function()
      render_set_details(tree, cs,
        tool_entries[cs.name] or {}, all_profiles, active_profile_key, lw)
    end)
  end

  tree:blank()
end
