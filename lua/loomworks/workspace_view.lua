--- loomworks/workspace_view.lua — View-model layer for workspace UI.
---
--- Orchestration logic extracted from UI files. Pure queries and
--- multi-step mutations that the UI calls instead of doing inline.
--- Workspace atomic mutations (add_project, remove_project, etc.)
--- stay in workspace.lua — this layer composes them.

local modules = require("loomworks.modules")

local M = {}

-- =========================================================================
-- Add Project
-- =========================================================================

--- Collect keyed tools from a detected tools array.
--- @param tools_for_type table[]|nil
--- @return table[]
local function collect_keyed_tools(tools_for_type)
    local keyed = {}
    if tools_for_type then
        for _, tool in ipairs(tools_for_type) do
            if tool.tool_key then
                keyed[#keyed + 1] = tool
            end
        end
    end
    return keyed
end

--- Context for the mapping dialog: inherited tool, no-tool profiles,
--- keyed tools. Pure query over cached profiles.
--- @param ws loomworks.Workspace
--- @param mod_type string module type (e.g. "cmake")
--- @return { inherited_tool: table|nil, no_tool_profiles: string[], keyed_tools: table[] }
function M.compute_add_project_context(ws, mod_type)
    local mod = modules.get(mod_type)
    local has_keyed = mod and mod.has_keyed_tools or false

    local inherited_tool = nil
    local no_tool_profiles = {}

    if has_keyed and ws.cache.profiles then
        for k, data in pairs(ws.cache.profiles) do
            if data.configuration_set then
                local tool = data.tools and data.tools[mod_type]
                if tool then
                    if not inherited_tool then
                        inherited_tool = {
                            tool_key = tool.key,
                            tool_data = tool.data,
                            tool_label = tool.label,
                            tool_mod_type = mod_type,
                        }
                    end
                elseif not data.tools or not next(data.tools) then
                    no_tool_profiles[#no_tool_profiles + 1] = k
                end
            end
        end
        table.sort(no_tool_profiles)
    end

    return {
        inherited_tool = inherited_tool,
        no_tool_profiles = no_tool_profiles,
        keyed_tools = inherited_tool and {} or collect_keyed_tools(ws._tools_by_type[mod_type]),
    }
end

--- Ensure tools are detected for a module type. Uses cached tools if
--- available, otherwise triggers async detection and caches the result.
--- Calls callback(keyed_tools) when ready.
--- @param ws loomworks.Workspace
--- @param mod table module object
--- @param mod_type string module type
--- @param callback fun(keyed_tools: table[])
function M.ensure_tools_detected(ws, mod, mod_type, callback)
    local existing_tools = ws._tools_by_type[mod_type]
    if existing_tools then
        callback(collect_keyed_tools(existing_tools))
        return
    end

    local schedule = ws._core._deps.schedule or vim.schedule
    mod.detect_tools_async(function(raw_tools)
        schedule(function()
            local enriched = {}
            for _, raw in ipairs(raw_tools) do
                enriched[#enriched + 1] = {
                    tool_data = raw.tool_data,
                    tool_key = mod.tool_key and mod.tool_key(raw.tool_data) or nil,
                    tool_label = mod.tool_label and mod.tool_label(raw.tool_data) or nil,
                }
            end
            ws._tools_by_type[mod_type] = enriched
            callback(collect_keyed_tools(enriched))
        end)
    end)
end

--- Execute the add-project pipeline: add_project, apply mappings,
--- upgrade profiles with tool.
--- @param ws loomworks.Workspace
--- @param key string project key
--- @param mod_type string module type
--- @param path string|nil relative path
--- @param result { mappings: table, tool_entry: table|nil }
--- @param has_keyed boolean whether module has keyed tools
--- @return boolean ok, string|nil err
function M.execute_add_project(ws, key, mod_type, path, result, has_keyed)
    local ok, err = ws:add_project(key, mod_type, path)
    if not ok then
        return false, err
    end

    -- Skip mappings when keyed module has no tool selected —
    -- the project is added unmapped until a tool is chosen.
    if has_keyed and not result.tool_entry then
        return true
    end

    for set_name, variant in pairs(result.mappings) do
        if variant then
            ws:update_config_set_mapping(set_name, key, variant)
        end
    end

    if result.tool_entry then
        ws:upgrade_profiles_for_tool(result.tool_entry)
    end

    return true
end

-- =========================================================================
-- Remove Project
-- =========================================================================

--- Collect all cached configurations for a project.
--- Returns items sorted by config_key, with build_dir and state.
--- @param ws loomworks.Workspace
--- @param project_key string
--- @return { project_key: string, config_key: string, state: string|nil, build_dir: string|nil }[]
function M.collect_project_configs(ws, project_key)
    local items = {}
    if not ws.cache.configurations then return items end
    for _, cached in pairs(ws.cache.configurations) do
        if cached.project_key == project_key then
            items[#items + 1] = {
                project_key = cached.project_key,
                config_key = cached.config_key,
                state = cached.state,
                build_dir = cached.build_dir,
            }
        end
    end
    table.sort(items, function(a, b) return a.config_key < b.config_key end)
    return items
end

--- Make a path relative to workspace root for display.
--- @param ws loomworks.Workspace
--- @param abs string|nil
--- @return string|nil
local function rel_path(ws, abs)
    if not abs then return nil end
    local ws_root = vim.fs.normalize(ws.root)
    local normalized = vim.fs.normalize(abs)
    if normalized:sub(1, #ws_root) == ws_root then
        local rel = normalized:sub(#ws_root + 1)
        if rel:sub(1, 1) == "/" then rel = rel:sub(2) end
        return rel ~= "" and rel or "."
    end
    return abs
end

--- Context for removal confirmation: type, downgrade preview, cached
--- configs, dialog lines and highlights. Pure query.
--- @param ws loomworks.Workspace
--- @param project_key string
--- @return { project_type: string, downgrade_preview: table[], cached_configs: table[], lines: string[], highlights: table[] }|nil
function M.compute_remove_context(ws, project_key)
    local proj = ws.config.projects[project_key]
    if not proj then return nil end

    local proj_type = proj.type
    local downgrade_preview = ws:compute_downgrade_preview(project_key)
    local cached_configs = M.collect_project_configs(ws, project_key)

    local lines = {
        "  Remove project: " .. project_key,
        "",
        "  This removes the project from loomworks.json.",
    }
    local highlights = {
        { line = 1, hl_group = "DiagnosticWarn" },
        { line = 3, hl_group = "Comment" },
    }

    -- Show cached configurations with build state
    local stateful = {}
    for _, item in ipairs(cached_configs) do
        if item.state and item.state ~= "unconfigured" then
            stateful[#stateful + 1] = item
        end
    end

    if #stateful > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Will delete cached configurations:"
        highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        for _, item in ipairs(stateful) do
            local dir = item.build_dir and rel_path(ws, item.build_dir) or nil
            local suffix = dir and ("  " .. dir) or ""
            local state_label = item.state and (" (" .. item.state .. ")") or ""
            lines[#lines + 1] = "    " .. project_key .. " / " .. item.config_key
                .. state_label .. suffix
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
    elseif #cached_configs > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Will delete " .. #cached_configs .. " cached configuration(s)."
        highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    end

    if #downgrade_preview > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "  Profiles to rename:"
        highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
        for _, rename in ipairs(downgrade_preview) do
            lines[#lines + 1] = "    " .. rename.old_key .. " → " .. rename.new_key
            highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
        end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Press y to confirm, q to cancel"

    return {
        project_type = proj_type,
        downgrade_preview = downgrade_preview,
        cached_configs = cached_configs,
        lines = lines,
        highlights = highlights,
    }
end

--- Execute remove: delete cached configs + build dirs, remove project,
--- downgrade profiles. The deletion is async (build dirs deleted via
--- subprocess), so on_done is called when complete.
--- @param ws loomworks.Workspace
--- @param key string project key
--- @param ctx { project_type: string, cached_configs: table[], downgrade_preview: table[] }
--- @param on_done? fun(ok: boolean, err: string|nil)
function M.execute_remove_project(ws, key, ctx, on_done)
    on_done = on_done or function() end

    -- Step 1: Delete cached configs and build dirs (async)
    local configs = ctx.cached_configs or {}
    if #configs > 0 then
        ws:_run_deletion(configs, function()
            ws:delete_cached_configs(configs)
            ws:_save_cache()
            ws:remerge()
        end, function()
            -- Step 2: Remove project from config (after deletion completes)
            local ok, err = ws:remove_project(key)
            if not ok then
                on_done(false, err)
                return
            end
            -- Step 3: Downgrade profiles if needed
            if #ctx.downgrade_preview > 0 then
                ws:downgrade_profiles_from_tool(ctx.project_type)
            end
            on_done(true)
        end)
    else
        -- No cached configs to delete — remove directly
        local ok, err = ws:remove_project(key)
        if not ok then
            on_done(false, err)
            return
        end
        if #ctx.downgrade_preview > 0 then
            ws:downgrade_profiles_from_tool(ctx.project_type)
        end
        on_done(true)
    end
end

-- =========================================================================
-- Mapping Dialog Data
-- =========================================================================

--- Auto-detect variant mappings for configuration sets.
--- @param mod table module with map_variant
--- @param set_names string[] sorted config set names
--- @param available_configs string[] project's configuration names
--- @return table<string, string|nil> set_name → variant
function M.compute_initial_mappings(mod, set_names, available_configs)
    local mappings = {}
    for _, set_name in ipairs(set_names) do
        local variant_type = set_name:lower()
        local mapped = mod.map_variant and mod.map_variant(variant_type, available_configs) or nil
        mappings[set_name] = mapped
    end
    return mappings
end

--- Profile upgrade preview filtered by mappings. Uses workspace's
--- compute_profile_renames for correct multi-tool key computation.
--- @param ws loomworks.Workspace
--- @param tool_entry table { tool_key, tool_data, tool_label, tool_mod_type }
--- @param mappings table<string, string|nil> current mappings
--- @return { old_key: string, new_key: string }[]
function M.compute_upgrade_preview(ws, tool_entry, mappings)
    local renames = ws:compute_profile_renames(function(tools)
        local t = tools and vim.deepcopy(tools) or {}
        t[tool_entry.tool_mod_type] = {
            key = tool_entry.tool_key,
            data = tool_entry.tool_data,
            label = tool_entry.tool_label,
        }
        return t
    end)

    -- Filter: only renames whose config set has a non-nil mapping
    local sets_with_mapping = {}
    for set_name, variant in pairs(mappings) do
        if variant then sets_with_mapping[set_name] = true end
    end

    local result = {}
    for _, r in ipairs(renames) do
        local pd = ws.cache.profiles[r.old_key]
        if pd and sets_with_mapping[pd.configuration_set] then
            result[#result + 1] = r
        end
    end
    return result
end

-- =========================================================================
-- Create Profile
-- =========================================================================

--- Config set candidates for the create-profile picker.
--- Combines existing sets with auto-detected candidates.
--- @param ws loomworks.Workspace
--- @param config_sets table<string, loomworks.ConfigurationSet> existing config sets
--- @return table[] items array of { name, real_name?, mappings?, cs?, auto, desc? }
function M.compute_config_set_candidates(ws, config_sets)
    local existing = {}
    for name, cs in pairs(config_sets) do
        existing[#existing + 1] = { name = name, cs = cs, auto = false }
    end
    table.sort(existing, function(a, b) return a.name < b.name end)

    local auto_sets = ws:generate_default_config_sets()
    local auto_items = {}
    if auto_sets then
        for name, set_mappings in pairs(auto_sets) do
            if not config_sets[name] then
                local parts = {}
                local keys = {}
                for k in pairs(set_mappings) do keys[#keys + 1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    parts[#parts + 1] = k .. "→" .. set_mappings[k]
                end
                auto_items[#auto_items + 1] = {
                    name = name .. " (auto-detected)",
                    real_name = name,
                    mappings = set_mappings,
                    cs = nil,
                    auto = true,
                    desc = table.concat(parts, ", "),
                }
            end
        end
        table.sort(auto_items, function(a, b) return a.real_name < b.real_name end)
    end

    local items = {}
    for _, e in ipairs(existing) do items[#items + 1] = e end
    for _, a in ipairs(auto_items) do items[#items + 1] = a end

    return items
end

return M
