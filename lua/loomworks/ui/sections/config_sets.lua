--- loomworks/ui/sections/config_sets.lua — Configuration sets section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render configuration set details when expanded.
--- @param tree loomworks.Tree
--- @param set_name string
--- @param mappings table<string, string>
--- @param tool_entries loomworks.ToolEntry[]
--- @param all_profiles table<string, loomworks.Profile>
--- @param active_profile_key string
--- @param lw table loomworks API
local function render_set_details(tree, set_name, mappings, tool_entries, all_profiles, active_profile_key, lw)
  tree:group("Projects:", "Comment", function()
    local proj_names = {}
    for name in pairs(mappings) do
      proj_names[#proj_names + 1] = name
    end
    table.sort(proj_names)
    for _, pname in ipairs(proj_names) do
      tree:leaf(pname .. " → " .. mappings[pname], "Comment")
    end
  end)

  if #tool_entries > 0 then
    tree:group("Tools:", "Comment", function()
      for _, entry in ipairs(tool_entries) do
        local profile_key = entry.profile_key
        local is_active = profile_key == active_profile_key
        -- Only show running/configured state if a cached profile exists
        local profile = entry.cached and all_profiles[profile_key] or nil
        local profile_running = profile and profile:is_running() or false
        local already_configured = profile and profile:is_configured() or false

        local marker = is_active and "● " or "○ "

        local suffix, hl
        if profile_running then
          local status_label = select(1, profile:status())
          suffix = " (" .. helpers.format_status(status_label) .. ")"
          local pps = profile:projects()
          local pct = helpers.aggregate_progress(pps)
          if pct then suffix = suffix .. " " .. pct .. "%" end
          suffix = suffix .. helpers.format_elapsed(lw.get_operation_elapsed(profile_key))
          hl = "LoomworksRunning"
        elseif is_active then
          hl = "LoomworksActive"
          local op = lw.get_operation(profile_key)
          if op and op.message then
            suffix = " — " .. op.message
          else
            local p_label = already_configured and select(1, profile:status()) or "unconfigured"
            suffix = " (" .. helpers.format_status(p_label) .. ")"
          end
        elseif already_configured then
          local p_label = select(1, profile:status())
          local op = lw.get_operation(profile_key)
          if op and op.message then
            suffix = " — " .. op.message
          else
            suffix = " (" .. helpers.format_status(p_label) .. ")"
          end
          if p_label == "failed_configure" or p_label == "failed_build"
              or p_label:match("failed") then
            hl = "LoomworksFailed"
          else
            hl = "LoomworksConfigured"
          end
        else
          suffix = ""
          hl = "LoomworksUnconfigured"
        end

        local display = entry.tool_label or entry.tool_key

        tree:item(display .. suffix, {
          marker = marker,
          spinning = profile_running,
          hl = hl,
          on_enter = actions.activate(profile_key),
          on_build = profile and actions.build(profile) or nil,
          on_rebuild = profile and actions.rebuild(profile) or nil,
          on_clean = profile and actions.clean(profile) or nil,
          on_configure = profile and actions.configure(profile) or nil,
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

  local set_names = {}
  for name in pairs(config_sets) do
    set_names[#set_names + 1] = name
  end
  table.sort(set_names)

  for _, set_name in ipairs(set_names) do
    local active_profile = all_profiles[active_profile_key]
    local is_active_set = active_profile and active_profile.configuration_set == set_name
    local set_hl = is_active_set and "LoomworksActive" or "LoomworksActionable"

    tree:node(set_name, {
      fold_key = "set:" .. set_name,
      hl = set_hl,
    }, function()
      render_set_details(tree, set_name, config_sets[set_name],
        tool_entries[set_name] or {}, all_profiles, active_profile_key, lw)
    end)
  end

  tree:blank()
end
