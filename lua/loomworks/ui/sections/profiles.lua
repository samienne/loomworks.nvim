--- loomworks/ui/sections/profiles.lua — Profiles section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render profile details when expanded.
--- @param tree loomworks.Tree
--- @param profile loomworks.Profile
--- @param lw table loomworks API
local function render_profile_details(tree, profile, lw)
  if profile.orphaned_set then
    tree:leaf("Set '" .. (profile.configuration_set or "?")
      .. "' removed from loomworks.json", "DiagnosticWarn")
  elseif profile.configuration_set then
    tree:leaf("Set: " .. profile.configuration_set, "Comment")
  end

  if profile.tool and profile.tool.label then
    tree:leaf("Tool: " .. profile.tool.label, "Comment")
    -- Show tool details if available (cmake-specific for now)
    if profile.tool.data then
      if profile.tool.data.generator then
        tree:leaf("Generator: " .. profile.tool.data.generator, "Comment")
      end
      if profile.tool.data.compiler_id then
        tree:leaf("Compiler: " .. profile.tool.data.compiler_id, "Comment")
      end
    end
  end

  local op = profile:operation()
  if op and op.message then
    local op_hl = op.success and "DiagnosticOk" or "DiagnosticError"
    tree:leaf("Last: " .. op.message, op_hl)
  end

  local pps = profile:projects()
  if #pps > 0 then
    tree:group({{"Projects:  ", "LoomworksActionable"}, {"[b] build  [c] configure  [o] options  [R] rebuild  [C] clean  [D] delete", "Comment"}}, function()
      for _, pp in ipairs(pps) do
        local cached = pp:cached_state()
        local config_status, status_hl, progress_str, is_spinning =
            helpers.resolve_config_status(pp, cached)

        local unit = lw.get_config_unit(pp.project_key, pp.config_key)
        tree:node(pp.project_key .. " → " .. pp.variant .. progress_str, {
          fold_key = "profile_proj:" .. profile.key .. ":" .. pp.project_key,
          spinning = is_spinning,
          hl = status_hl,
          on_build = actions.build_configuration(unit),
          on_rebuild = actions.rebuild_configuration(unit),
          on_clean = actions.clean_configuration(unit),
          on_configure = actions.configure_configuration(unit),
          on_delete = actions.delete_config(unit),
          on_options = actions.show_options(unit),
        }, function()
          helpers.render_cached_details(tree, config_status, status_hl, cached)
        end)
      end
    end)
  end
end

--- Render the profiles section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile }
return function(tree, ctx)
  local lw = ctx.lw
  local all_profiles = ctx.all_profiles

  -- Collect and sort all profiles alphabetically
  local profiles = {}
  for _, profile in pairs(all_profiles) do
    profiles[#profiles + 1] = profile
  end
  table.sort(profiles, function(a, b) return a.key < b.key end)

  if #profiles == 0 then return end

  tree:leaf("Profiles", "Title")
  tree:leaf("[Enter] activate  [b] build  [c] configure  [R] rebuild  [C] clean  [D] delete", "Comment")
  tree:blank()

  for _, profile in ipairs(profiles) do
    local is_active = profile == ctx.active_profile
    local profile_running = profile:is_running()

    local status_label, status_hl = profile:status()
    local marker = helpers.status_marker(status_label)
    local hl

    local display = profile.key
    if profile.orphaned_set then
      display = display .. " [stale]"
    elseif profile.explicit then
      display = display .. " [explicit]"
    end

    display = display .. " (" .. status_label .. ")"
    if profile_running then
      hl = is_active and "LoomworksActive" or "LoomworksRunning"
      local pps = profile:projects()
      local pct = helpers.aggregate_progress(pps)
      if pct then
        display = display .. " " .. pct .. "%"
      end
      display = display .. helpers.format_elapsed(profile:operation_elapsed())
    elseif is_active then
      hl = "LoomworksActive"
      local op = profile:operation()
      if op and op.message then
        display = display .. " — " .. op.message
      end
    else
      if status_label == "failed_configure" or status_label == "failed_build"
          or status_label:match("failed") then
        hl = "LoomworksFailed"
      elseif status_label == "unconfigured" then
        hl = "LoomworksUnconfigured"
      else
        hl = "LoomworksConfigured"
      end
      local op = profile:operation()
      if op and op.message then
        display = display .. " — " .. op.message
      end
    end

    tree:node(display, {
      fold_key = "profile:" .. profile.key,
      marker = marker,
      spinning = profile_running,
      hl = hl,
      on_enter = actions.activate(profile),
      on_build = actions.build(profile),
      on_rebuild = actions.rebuild(profile),
      on_clean = actions.clean(profile),
      on_configure = actions.configure(profile),
      on_delete = actions.delete_profile(profile),
    }, function()
      render_profile_details(tree, profile, lw)
    end)
  end

  tree:blank()
end
