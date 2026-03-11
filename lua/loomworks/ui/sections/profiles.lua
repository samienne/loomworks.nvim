--- loomworks/ui/sections/profiles.lua — Profiles section renderer.

local helpers = require("loomworks.ui.helpers")
local actions = require("loomworks.ui.actions")

--- Render profile details when expanded.
--- @param tree loomworks.Tree
--- @param profile loomworks.Profile
--- @param lw table loomworks API
local function render_profile_details(tree, profile, lw)
  if profile.configuration_set then
    tree:leaf("Set: " .. profile.configuration_set, "Comment")
  end

  if profile.tool_label then
    tree:leaf("Tool: " .. profile.tool_label, "Comment")
    -- Show tool details if available (cmake-specific for now)
    if profile.tool_data then
      if profile.tool_data.generator then
        tree:leaf("Generator: " .. profile.tool_data.generator, "Comment")
      end
      if profile.tool_data.compiler_id then
        tree:leaf("Compiler: " .. profile.tool_data.compiler_id, "Comment")
      end
    end
  end

  local op = lw.get_operation(profile.key)
  if op and op.message then
    local op_hl = op.success and "DiagnosticOk" or "DiagnosticError"
    tree:leaf("Last: " .. op.message, op_hl)
  end

  local pps = profile:projects()
  if #pps > 0 then
    tree:group("Projects:", "Comment", function()
      for _, pp in ipairs(pps) do
        local cached = pp:cached_state()
        local config_status, status_hl, progress_str, is_spinning =
            helpers.resolve_config_status(pp, cached)

        tree:node(pp.project_key .. " → " .. pp.variant .. progress_str, {
          fold_key = "profile_proj:" .. profile.key .. ":" .. pp.project_key,
          spinning = is_spinning,
          hl = status_hl,
          on_build = actions.build_configuration(pp.project_key, pp.config_key),
          on_rebuild = actions.rebuild_configuration(pp.project_key, pp.config_key),
          on_clean = actions.clean_configuration(pp.project_key, pp.config_key),
          on_configure = actions.configure_configuration(pp.project_key, pp.config_key),
          on_delete = actions.delete_config(pp.project_key, pp.config_key),
        }, function()
          helpers.render_cached_details(tree, config_status, status_hl, cached)
        end)
      end
    end)
  end
end

--- Render an ad-hoc profile entry (single project+config pin).
--- @param tree loomworks.Tree
--- @param profile loomworks.Profile
--- @param lw table loomworks API
local function render_adhoc_node(tree, profile, lw)
  local pps = profile:projects()
  local pp = pps[1]
  if not pp then return end

  local cached = pp:cached_state()
  local config_status, status_hl, progress_str, is_spinning =
      helpers.resolve_config_status(pp, cached)

  -- Compact display: "project / variant × tool"
  local display = pp.project_key .. " / " .. pp.variant
  if profile.tool_label then
    display = display .. " × " .. profile.tool_label
  elseif profile.tool_key then
    display = display .. " × " .. profile.tool_key
  end
  display = display .. " (" .. config_status .. ")" .. progress_str

  tree:node(display, {
    fold_key = "profile:" .. profile.key,
    marker = "· ",
    spinning = is_spinning,
    hl = status_hl,
    on_build = actions.build_configuration(pp.project_key, pp.config_key),
    on_rebuild = actions.rebuild_configuration(pp.project_key, pp.config_key),
    on_clean = actions.clean_configuration(pp.project_key, pp.config_key),
    on_configure = actions.configure_configuration(pp.project_key, pp.config_key),
    on_delete = actions.delete_profile(profile.key),
  }, function()
    helpers.render_cached_details(tree, config_status, status_hl, cached)
  end)
end

--- Render the profiles section.
--- @param tree loomworks.Tree
--- @param ctx table { lw, all_profiles, active_profile_key }
return function(tree, ctx)
  local lw = ctx.lw
  local all_profiles = ctx.all_profiles
  local active_profile_key = ctx.active_profile_key

  -- Separate full profiles from ad-hoc entries
  local full_profiles = {}
  local adhoc_profiles = {}
  for profile_key, profile in pairs(all_profiles) do
    if profile.ad_hoc then
      adhoc_profiles[#adhoc_profiles + 1] = profile_key
    else
      full_profiles[profile_key] = profile
    end
  end
  table.sort(adhoc_profiles)

  -- Collect full profiles to show: configured OR running OR active
  local configured_profiles = {}
  local configured_set = {}
  for profile_key, profile in pairs(full_profiles) do
    if profile:is_configured() or profile:is_running() or profile_key == active_profile_key then
      configured_profiles[#configured_profiles + 1] = profile_key
      configured_set[profile_key] = true
    end
  end
  table.sort(configured_profiles)

  local explicit_unconfigured = {}
  for profile_key, profile in pairs(full_profiles) do
    if profile.explicit and not configured_set[profile_key] then
      explicit_unconfigured[#explicit_unconfigured + 1] = profile_key
    end
  end
  table.sort(explicit_unconfigured)

  local has_full = #configured_profiles > 0 or #explicit_unconfigured > 0
  local has_adhoc = #adhoc_profiles > 0

  if not has_full and not has_adhoc then return end

  tree:leaf("Profiles", "Title")
  tree:blank()

  local function render_profile_node(profile_key)
    local profile = all_profiles[profile_key]
    local is_active = profile_key == active_profile_key
    local profile_running = profile:is_running()

    local marker = is_active and "● " or "○ "
    local hl = profile_running and "DiagnosticWarn" or (is_active and "DiagnosticOk" or nil)

    local display = profile_key
    if profile.explicit then
      display = display .. " [explicit]"
    end

    local status_label, status_hl = profile:status()
    display = display .. " (" .. status_label .. ")"
    if profile_running then
      local pps = profile:projects()
      local pct = helpers.aggregate_progress(pps)
      if pct then
        display = display .. " " .. pct .. "%"
      end
      display = display .. helpers.format_elapsed(lw.get_operation_elapsed(profile_key))
    else
      local op = lw.get_operation(profile_key)
      if op and op.message then
        display = display .. " — " .. op.message
      end
    end
    if not hl then
      hl = status_hl
    end

    tree:node(display, {
      fold_key = "profile:" .. profile_key,
      marker = marker,
      spinning = profile_running,
      hl = hl,
      on_enter = actions.activate(profile_key),
      on_build = actions.build(profile_key),
      on_rebuild = actions.rebuild(profile_key),
      on_clean = actions.clean(profile_key),
      on_configure = actions.configure(profile_key),
      on_delete = actions.delete_profile(profile_key),
    }, function()
      render_profile_details(tree, profile, lw)
    end)
  end

  for _, profile_key in ipairs(configured_profiles) do
    render_profile_node(profile_key)
  end
  for _, profile_key in ipairs(explicit_unconfigured) do
    render_profile_node(profile_key)
  end

  if has_adhoc then
    if has_full then
      tree:blank()
      tree:leaf("Pinned:", "Comment")
    end
    for _, profile_key in ipairs(adhoc_profiles) do
      render_adhoc_node(tree, all_profiles[profile_key], lw)
    end
  end

  tree:blank()
end
