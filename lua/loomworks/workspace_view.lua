--- loomworks/workspace_view.lua — View-model layer for workspace UI.
---
--- Orchestration logic extracted from UI files. Pure queries and
--- multi-step mutations that the UI calls instead of doing inline.
--- Workspace atomic mutations (add_project, remove_project, etc.)
--- stay in workspace.lua — this layer composes them.

local modules = require("loomworks.modules")

local M = {}

--- Extract display-friendly project_key and config_key from a DeletionItem.
--- Reads from the unit's resolved references, with fallbacks.
--- @param item loomworks.DeletionItem
--- @return string project_key, string config_key
local function item_display_keys(item)
    local unit = item.unit
    if not unit then return "?", "?" end
    local cached = unit._cached
    local pkey = unit._project and unit._project.key or (cached and cached.project_key) or "?"
    local ckey = cached and cached.config_key or unit.id
    return pkey, ckey
end

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
    local project, err = ws:add_project(key, mod_type, path)
    if not project then
        return false, err
    end

    -- Skip mappings when keyed module has no tool selected —
    -- the project is added unmapped until a tool is chosen.
    if has_keyed and not result.tool_entry then
        return true
    end
    for _, cs in pairs(ws._config_sets) do
        local variant = result.mappings[cs.name]
        if variant and project then
            cs:update_mapping(project, variant)
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
--- Returns items sorted by config_key, with build_dir, state, and unit.
--- @param ws loomworks.Workspace
--- @param project loomworks.Project
--- @return { config_key: string, state: string|nil, build_dir: string|nil, unit: loomworks.ConfigUnit|nil }[]
function M.collect_project_configs(ws, project)
    local items = {}
    if not ws.cache.configurations then return items end
    for cache_key, cached in pairs(ws.cache.configurations) do
        if cached.project_key == project.key then
            items[#items + 1] = {
                config_key = cached.config_key,
                state = cached.state,
                build_dir = cached.build_dir,
                unit = ws:find_config_unit_for_cached(cached),
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
--- @param project loomworks.Project
--- @return { project_type: string, downgrade_preview: table[], cached_configs: table[], lines: string[], highlights: table[] }|nil
function M.compute_remove_context(ws, project)
    local proj_type = project.type
    local downgrade_preview = ws:compute_downgrade_preview(project)
    local cached_configs = M.collect_project_configs(ws, project)

    local lines = {
        "  Remove project: " .. project.key,
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
            lines[#lines + 1] = "    " .. project.key .. " / " .. item.config_key
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
--- @param project loomworks.Project project to remove
--- @param ctx { project_type: string, cached_configs: table[], downgrade_preview: table[] }
--- @param on_done? fun(ok: boolean, err: string|nil)
function M.execute_remove_project(ws, project, ctx, on_done)
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
            local ok, err = ws:remove_project(project)
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
        local ok, err = ws:remove_project(project)
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

-- =========================================================================
-- Config Set Editing
-- =========================================================================

--- Context for creating a new config set: project keys, auto-detected
--- mappings, and available configs per project (from module.info).
--- @param ws loomworks.Workspace
--- @return { projects: string[], auto_mappings: table<string, string|nil>, available_configs: table<string, string[]> }
function M.compute_create_config_set_context(ws)
    local project_keys = {}
    local auto_mappings = {}
    local available_configs = {}

    for _, project in pairs(ws._projects) do
        local key = project.key
        project_keys[#project_keys + 1] = key
        local impl = project._module and project._module.impl or nil
        if impl and impl.info then
            local abs_path = ws.root .. "/" .. (project.path or key)
            local info = impl.info(abs_path, project.type_config)
            if info and info.configurations then
                local names = {}
                for name in pairs(info.configurations) do
                    names[#names + 1] = name
                end
                table.sort(names)
                available_configs[key] = names
            end
        end
        if not available_configs[key] then
            available_configs[key] = {}
        end
    end
    table.sort(project_keys)

    return {
        projects = project_keys,
        auto_mappings = auto_mappings,
        available_configs = available_configs,
    }
end

--- Execute config set creation.
--- @param ws loomworks.Workspace
--- @param name string config set name
--- @param mappings table<string, string|nil> project_key → variant
--- @return boolean ok, string|nil err
function M.execute_create_config_set(ws, name, mappings)
    -- Filter out nil mappings
    local clean = {}
    for k, v in pairs(mappings) do
        if v then clean[k] = v end
    end
    return ws:add_configuration_set(name, clean)
end

--- Context for editing a config set: current mappings, available configs
--- per project (from module.info).
--- @param ws loomworks.Workspace
--- @param set_name string
--- @return { set_name: string, mappings: table<string, string|nil>, available_configs: table<string, string[]>, project_keys: string[] }|nil
function M.compute_edit_config_set_context(ws, set_name)
    if not ws.config.configuration_sets
            or not ws.config.configuration_sets[set_name] then
        return nil
    end

    local raw_mappings = ws.config.configuration_sets[set_name]
    local mappings = {}
    local available_configs = {}
    local project_keys = {}
    local projects_by_key = {}

    for _, project in pairs(ws._projects) do
        local key = project.key
        project_keys[#project_keys + 1] = key
        projects_by_key[key] = project
        mappings[key] = raw_mappings[key] or nil

        local impl = project._module and project._module.impl or nil
        if impl and impl.info then
            local abs_path = ws.root .. "/" .. (project.path or key)
            local info = impl.info(abs_path, project.type_config)
            if info and info.configurations then
                local names = {}
                for name in pairs(info.configurations) do
                    names[#names + 1] = name
                end
                table.sort(names)
                available_configs[key] = names
            end
        end
        if not available_configs[key] then
            available_configs[key] = {}
        end
    end
    table.sort(project_keys)

    return {
        set_name = set_name,
        mappings = mappings,
        available_configs = available_configs,
        project_keys = project_keys,
        projects_by_key = projects_by_key,
    }
end

--- Execute config set edit: apply changed mappings, optionally rename.
--- @param cs loomworks.ConfigurationSet the config set to edit
--- @param new_name string new name (same as cs.name if not renamed)
--- @param new_mappings table<string, string|nil>
--- @param old_mappings table<string, string|nil>
--- @param projects_by_key table<string, loomworks.Project> resolved during compute
--- @return boolean ok, string|nil err
function M.execute_edit_config_set(cs, new_name, new_mappings, old_mappings, projects_by_key)
    local ws = cs._workspace
    local old_name = cs.name
    local renamed = new_name ~= old_name

    if renamed then
        -- Rename: create new set, migrate profiles, remove old
        local ok, err = M.execute_rename_config_set(ws, cs, new_name, new_mappings)
        if not ok then return false, err end
        return true
    end

    -- Apply mapping changes to existing set
    for key, new_variant in pairs(new_mappings) do
        local old_variant = old_mappings[key]
        if new_variant ~= old_variant then
            local project = projects_by_key[key]
            if not project then return false, "project '" .. key .. "' not found" end
            local ok, err = cs:update_mapping(project, new_variant)
            if not ok then return false, err end
        end
    end
    -- Handle keys that were in old but not in new (removed)
    for key, old_variant in pairs(old_mappings) do
        if old_variant and new_mappings[key] == nil then
            local project = projects_by_key[key]
            if not project then return false, "project '" .. key .. "' not found" end
            local ok, err = cs:update_mapping(project, nil)
            if not ok then return false, err end
        end
    end
    return true
end

--- Rename a configuration set: create new, migrate cached profiles, remove old.
--- The new set gets the provided mappings (which may also have changed).
--- @param ws loomworks.Workspace
--- @param cs loomworks.ConfigurationSet configuration set being renamed
--- @param new_name string
--- @param mappings table<string, string|nil> final mappings for the new set
--- @return boolean ok, string|nil err
function M.execute_rename_config_set(ws, cs, new_name, mappings)
    -- Filter nil mappings
    local clean = {}
    for k, v in pairs(mappings) do
        if v then clean[k] = v end
    end

    -- Migrate cached profiles that reference old name (before removing old set)
    local old_name = cs.name
    if ws.cache.profiles then
        for _, profile_data in pairs(ws.cache.profiles) do
            if profile_data.configuration_set == old_name then
                profile_data.configuration_set = new_name
            end
        end
    end

    -- Remove old set first (avoids case-collision check blocking case-only renames)
    local ok, err = ws:remove_configuration_set(cs)
    if not ok then return false, err end

    -- Create new set
    local new_cs, add_err = ws:add_configuration_set(new_name, clean)
    if not new_cs then return false, add_err end

    return true
end

--- Context for deleting a config set: affected profiles, warning lines.
--- @param ws loomworks.Workspace
--- @param cs loomworks.ConfigurationSet
--- @return { profiles: string[], lines: string[], highlights: table[] }|nil
function M.compute_delete_config_set_context(ws, cs)
    local set_name = cs.name
    if not ws.config.configuration_sets
            or not ws.config.configuration_sets[set_name] then
        return nil
    end

    -- Find profiles referencing this set
    local affected_profiles = {}
    if ws.cache.profiles then
        for profile_key, profile_data in pairs(ws.cache.profiles) do
            if profile_data.configuration_set == set_name then
                affected_profiles[#affected_profiles + 1] = profile_key
            end
        end
        table.sort(affected_profiles)
    end

    local lines = {
        "  Delete configuration set: " .. set_name,
        "",
    }
    local highlights = {
        { line = 1, hl_group = "DiagnosticWarn" },
    }

    if #affected_profiles > 0 then
        lines[#lines + 1] = "  Profiles that will become orphaned:"
        highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        for _, pk in ipairs(affected_profiles) do
            lines[#lines + 1] = "    " .. pk
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "  Cached configs will become orphaned."
    highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    lines[#lines + 1] = "  Use 'Clean orphaned configs' to remove them later."
    highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Press y to confirm, q to cancel"

    return {
        profiles = affected_profiles,
        lines = lines,
        highlights = highlights,
    }
end

--- Execute config set deletion (orphans profiles, does not delete caches).
--- @param ws loomworks.Workspace
--- @param cs loomworks.ConfigurationSet
--- @return boolean ok, string|nil err
function M.execute_delete_config_set(ws, cs)
    return ws:remove_configuration_set(cs)
end

-- =========================================================================
-- Orphan Cleanup
-- =========================================================================

--- Find build directories on disk under {root}/.nvim/build/ that are not
--- referenced by any cache entry. Uses top-down pruning: reports the
--- highest-level directory whose entire subtree contains no cache entries.
--- @param ws loomworks.Workspace
--- @return string[] absolute paths of stray directories
function M.find_stray_build_dirs(ws)
    local uv = vim.uv or vim.loop
    local build_root = ws.root .. "/.nvim/build"
    local normalize = ws._core._deps.normalize

    -- Collect all normalized build_dirs referenced by cache entries
    local known_dirs = {}
    if ws.cache.configurations then
        for _, cached in pairs(ws.cache.configurations) do
            if cached.build_dir then
                known_dirs[#known_dirs + 1] = normalize(cached.build_dir)
            end
        end
    end

    -- Build a set for exact match and a list for prefix checks
    local known_set = {}
    for _, d in ipairs(known_dirs) do known_set[d] = true end

    --- Check if any known cache dir is a proper child of the candidate.
    --- @param candidate string normalized dir path
    --- @return boolean
    local function has_cache_entry_below(candidate)
        local prefix = candidate .. "/"
        for _, known in ipairs(known_dirs) do
            if known:sub(1, #prefix) == prefix then
                return true
            end
        end
        return false
    end

    -- Top-down walk:
    -- - If this dir IS a cache entry → stop (it's a valid build dir).
    -- - If no cache entry lives below it → report as stray, stop.
    -- - Otherwise → recurse into children.
    local stray = {}
    local function scan(dir)
        local normalized = normalize(dir)
        if known_set[normalized] then
            return -- this dir is a known build dir, don't touch it
        end
        if not has_cache_entry_below(normalized) then
            stray[#stray + 1] = normalized
            return
        end
        -- Some cache entry lives deeper — recurse into children
        local handle = uv.fs_scandir(dir)
        if not handle then return end
        while true do
            local name, ftype = uv.fs_scandir_next(handle)
            if not name then break end
            if ftype == "directory" then
                scan(dir .. "/" .. name)
            end
        end
    end

    local norm_root = normalize(build_root)
    local stat = uv.fs_stat(build_root)
    if stat and stat.type == "directory" then
        -- Scan each top-level child (not the build root itself)
        local handle = uv.fs_scandir(build_root)
        if handle then
            while true do
                local name, ftype = uv.fs_scandir_next(handle)
                if not name then break end
                if ftype == "directory" then
                    scan(norm_root .. "/" .. name)
                end
            end
        end
    end

    table.sort(stray)
    return stray
end

--- Collect all orphaned items for the cleanup dialog: orphaned cached
--- configs + stray build dirs not in cache.
--- @param ws loomworks.Workspace
--- @return { orphaned_configs: table[], stray_dirs: string[], lines: string[], highlights: table[] }
function M.compute_orphan_cleanup_context(ws)
    local orphans = ws:get_orphaned_configs()
    local orphaned_configs = {}

    for _, o in ipairs(orphans) do
        orphaned_configs[#orphaned_configs + 1] = {
            project_key = o.project_key,
            config_key = o.config_key,
            state = o.cached and o.cached.state or nil,
            build_dir = o.cached and o.cached.build_dir or nil,
            unit = o.unit,
        }
    end

    local stray_dirs = M.find_stray_build_dirs(ws)

    local lines = {
        "  Clean orphaned items",
        "",
    }
    local highlights = {
        { line = 1, hl_group = "DiagnosticWarn" },
    }

    local has_anything = #orphaned_configs > 0 or #stray_dirs > 0

    if #orphaned_configs > 0 then
        lines[#lines + 1] = "  Orphaned configurations (" .. #orphaned_configs .. "):"
        highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        for _, item in ipairs(orphaned_configs) do
            local state_label = item.state and (" (" .. item.state .. ")") or ""
            local dir = item.build_dir and ("  " .. rel_path(ws, item.build_dir)) or ""
            lines[#lines + 1] = "    " .. item.project_key .. " / " .. item.config_key
                    .. state_label .. dir
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
        lines[#lines + 1] = ""
    end

    if #stray_dirs > 0 then
        lines[#lines + 1] = "  Stray build directories (" .. #stray_dirs .. "):"
        highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        for _, dir in ipairs(stray_dirs) do
            lines[#lines + 1] = "    " .. rel_path(ws, dir)
            highlights[#highlights + 1] = { line = #lines, hl_group = "DiagnosticWarn" }
        end
        lines[#lines + 1] = ""
    end

    if not has_anything then
        lines[#lines + 1] = "  Nothing to clean."
        highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    else
        lines[#lines + 1] = "  Press y to confirm, q to cancel"
    end

    return {
        orphaned_configs = orphaned_configs,
        stray_dirs = stray_dirs,
        lines = lines,
        highlights = highlights,
    }
end

--- Execute orphan cleanup: delete orphaned cache entries + build dirs,
--- then delete stray build dirs.
--- @param ws loomworks.Workspace
--- @param orphaned_configs table[] { project_key, config_key, build_dir? }
--- @param stray_dirs string[] absolute paths
--- @param on_done? fun()
function M.execute_orphan_cleanup(ws, orphaned_configs, stray_dirs, on_done)
    on_done = on_done or function() end

    local function delete_stray()
        if #stray_dirs == 0 then
            on_done()
            return
        end
        local safe_prefix = ws._core._deps.normalize(ws.root)
        local valid_dirs = {}
        for _, dir in ipairs(stray_dirs) do
            if ws:_validate_build_dir(dir, safe_prefix) then
                valid_dirs[#valid_dirs + 1] = dir
            end
        end
        if #valid_dirs == 0 then
            on_done()
            return
        end
        ws:_delete_build_dirs_async(valid_dirs, function()
            on_done()
        end)
    end

    if #orphaned_configs > 0 then
        ws:_run_deletion(orphaned_configs, function()
            ws:delete_cached_configs(orphaned_configs)
        end, delete_stray)
    else
        delete_stray()
    end
end

-- =========================================================================
-- Project Browser Helpers
-- =========================================================================

--- Derive project key and optional path from a browser entry's absolute path.
--- Root-level: basename as key, path omitted.
--- Nested: relative path as key, explicit path field.
--- @param root string workspace root
--- @param abs_path string absolute path of the entry
--- @param name string directory basename
--- @return string key, string|nil path
function M.derive_key_and_path(root, abs_path, name)
    local rel = abs_path:sub(#root + 2) -- strip root + "/"
    if rel == "" then
        return name, "."
    elseif rel == name then
        return name, nil
    else
        return rel:gsub("/", "_"), rel
    end
end

--- Find the project key in workspace config that matches a browser entry path.
--- Find a project by its relative path or basename.
--- @param ws loomworks.Workspace
--- @param rel_path string relative path from root
--- @param basename string directory basename
--- @return loomworks.Project|nil
function M.find_project_by_path(ws, rel_path, basename)
    for _, proj in pairs(ws._projects) do
        local proj_rel = proj.path or proj.key
        if proj_rel == rel_path or proj_rel == basename then
            return proj
        end
    end
    return nil
end

--- Prepare context for adding a project from the browser. Determines
--- whether a mapping dialog is needed or the project can be added directly.
--- @param ws loomworks.Workspace
--- @param root string workspace root
--- @param abs_path string entry's absolute path
--- @param name string entry's directory basename
--- @param mod_type string module type
--- @return { action: "add_direct"|"show_dialog", key: string, path: string|nil, mod_type: string, config_names?: string[], has_keyed?: boolean }
function M.prepare_add_project_from_browser(ws, root, abs_path, name, mod_type)
    local key, path = M.derive_key_and_path(root, abs_path, name)

    local raw_config_sets = ws.config and ws.config.configuration_sets or nil
    local has_config_sets = raw_config_sets and next(raw_config_sets)

    if not has_config_sets then
        return { action = "add_direct", key = key, path = path, mod_type = mod_type }
    end

    -- Detect available configurations for the new project
    local mod = modules.get(mod_type)
    local config_names = {}
    if mod and mod.info and mod.map_variant then
        local info = mod.info(abs_path, {})
        if info and info.configurations then
            for cfg_name in pairs(info.configurations) do
                config_names[#config_names + 1] = cfg_name
            end
            table.sort(config_names)
        end
    end

    if #config_names == 0 then
        return { action = "add_direct", key = key, path = path, mod_type = mod_type }
    end

    local has_keyed = mod and mod.has_keyed_tools or false

    return {
        action = "show_dialog",
        key = key,
        path = path,
        mod_type = mod_type,
        config_names = config_names,
        has_keyed = has_keyed,
    }
end

-- =========================================================================
-- Confirmation Dialog Content
-- =========================================================================

--- Collect clean items for a profile (project_key, config_key, build_dir).
--- @param profile loomworks.Profile
--- @return table[]
function M.collect_clean_items(profile)
    local items = {}
    for _, pp in ipairs(profile:projects()) do
        local pp_cached = pp._cached
        items[#items + 1] = {
            project_key = pp._project and pp._project.key or (pp_cached and pp_cached.project_key),
            config_key = pp_cached and pp_cached.config_key,
            build_dir = pp:build_dir(),
            unit = pp._config_unit,
        }
    end
    return items
end

--- Collect clean items for a single ConfigUnit.
--- @param unit loomworks.ConfigUnit
--- @return table[]
function M.collect_clean_items_for_unit(unit)
    return { {
        unit = unit,
        build_dir = unit:build_dir(),
    } }
end

--- Build confirmation dialog content for clean/rebuild actions.
--- @param ws loomworks.Workspace
--- @param title string
--- @param items table[] { project_key, config_key, build_dir? }
--- @param opts? { rebuild?: boolean }
--- @return { lines: string[], highlights: table[] }
function M.compute_clean_confirmation_context(ws, title, items, opts)
    local lines = {}
    local highlights = {}

    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then
            highlights[#highlights + 1] = { line = #lines, hl_group = hl }
        end
    end

    add("  " .. title, "DiagnosticWarn")
    add("")

    local running_tasks = ws:find_running_tasks_for_items(items)
    local has_running = false
    for _ in pairs(running_tasks) do has_running = true; break end

    if has_running then
        add("  Will stop running tasks:", "DiagnosticWarn")
        for _, info in pairs(running_tasks) do
            add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key,
                "DiagnosticWarn")
        end
        add("")
    end

    opts = opts or {}
    local desc = opts.rebuild
        and "  Will clean build artifacts then rebuild:"
        or "  Will clean build artifacts and reset to configured:"
    add(desc, "DiagnosticWarn")
    for _, item in ipairs(items) do
        local pkey, ckey = item_display_keys(item)
        add("    " .. pkey .. " / " .. ckey, "DiagnosticWarn")
    end
    add("")

    add("  Press y to confirm, q to cancel", "Comment")

    return { lines = lines, highlights = highlights }
end

--- Build confirmation dialog content for deletion actions.
--- @param ws loomworks.Workspace
--- @param title string
--- @param plan loomworks.DeletionPlan
--- @return { lines: string[], highlights: table[] }
function M.compute_delete_confirmation_context(ws, title, plan)
    local items = plan.items
    local lines = {}
    local highlights = {}

    local function add(text, hl)
        lines[#lines + 1] = text
        if hl then
            highlights[#highlights + 1] = { line = #lines, hl_group = hl }
        end
    end

    add("  " .. title, "DiagnosticWarn")
    add("")

    local running_tasks = ws:find_running_tasks_for_items(items)
    local running_task_ids = {}
    for task_id in pairs(running_tasks) do
        running_task_ids[#running_task_ids + 1] = task_id
    end

    if #running_task_ids > 0 then
        add("  Will stop running tasks:", "DiagnosticWarn")
        for _, info in pairs(running_tasks) do
            add("    " .. info.project_key .. ": " .. info.action .. " " .. info.configuration_key,
                "DiagnosticWarn")
        end
        add("")
    end

    -- Split items by disposition
    local clean_items, reset_items, keep_items = {}, {}, {}
    for _, item in ipairs(items) do
        if item.disposition == "keep" then
            keep_items[#keep_items + 1] = item
        elseif item.disposition == "reset" then
            reset_items[#reset_items + 1] = item
        else
            clean_items[#clean_items + 1] = item
        end
    end

    if #clean_items > 0 then
        add("  Will remove:", "DiagnosticError")
        for _, item in ipairs(clean_items) do
            local pkey, ckey = item_display_keys(item)
            local dir = item.build_dir and rel_path(ws, item.build_dir) or nil
            local suffix = dir and ("  " .. dir) or ""
            add("    " .. pkey .. " / " .. ckey .. suffix, "DiagnosticError")
        end
        add("")
    end

    if #reset_items > 0 then
        add("  Will reset to unconfigured:", "DiagnosticWarn")
        for _, item in ipairs(reset_items) do
            local pkey, ckey = item_display_keys(item)
            local dir = item.build_dir and rel_path(ws, item.build_dir) or nil
            local suffix = dir and ("  " .. dir) or ""
            add("    " .. pkey .. " / " .. ckey .. suffix, "DiagnosticWarn")
        end
        add("")
    end

    if #keep_items > 0 then
        add("  Will keep (referenced by another profile):", "Comment")
        for _, item in ipairs(keep_items) do
            local pkey, ckey = item_display_keys(item)
            add("    " .. pkey .. " / " .. ckey, "Comment")
        end
        add("")
    end

    if #items == 0 and plan.profile then
        add("  No configurations to clean.", "Comment")
        add("")
    end

    add("  Press y to confirm, q to cancel", "Comment")

    return { lines = lines, highlights = highlights }
end

--- Build confirmation dialog content for stray dir deletion.
--- @param ws loomworks.Workspace
--- @param dir string absolute normalized path
--- @return { lines: string[], highlights: table[] }
function M.compute_delete_stray_dir_context(ws, dir)
    local display = rel_path(ws, dir) or dir
    return {
        lines = {
            "  Delete stray build directory:",
            "",
            "    " .. display,
            "",
            "  Press y to confirm, q to cancel",
        },
        highlights = {
            { line = 1, hl_group = "DiagnosticWarn" },
            { line = 3, hl_group = "DiagnosticWarn" },
        },
    }
end

--- Execute stray build dir deletion.
--- @param ws loomworks.Workspace
--- @param dir string absolute normalized path
--- @param on_done? fun(ok: boolean, err: string|nil)
function M.execute_delete_stray_dir(ws, dir, on_done)
    on_done = on_done or function() end
    local safe_prefix = ws._core._deps.normalize(ws.root)
    if not ws:_validate_build_dir(dir, safe_prefix) then
        on_done(false, "path outside workspace")
        return
    end
    ws:_delete_build_dirs_async({ dir }, function(results)
        if results[1] and results[1].ok then
            ws._core._deps.events.emit("deletion_completed", {})
            on_done(true)
        else
            local err = results[1] and results[1].err or "unknown"
            on_done(false, err)
        end
    end)
end

-- =========================================================================
-- Create Profile
-- =========================================================================

--- Handle a config set choice for profile creation: materialize auto-detected
--- sets, resolve the ConfigurationSet object.
--- @param ws loomworks.Workspace
--- @param choice { cs?: loomworks.ConfigurationSet, auto: boolean, real_name?: string, mappings?: table }
--- @return loomworks.ConfigurationSet|nil cs, string|nil err
function M.resolve_config_set_choice(ws, choice)
    local cs = choice.cs
    if choice.auto then
        local created, err = ws:add_configuration_set(choice.real_name, choice.mappings)
        if not created then
            return nil, err or "failed to add config set"
        end
        cs = created
    end
    return cs
end

--- Execute profile creation: materialize or activate.
--- @param cs loomworks.ConfigurationSet
--- @param tool_entry? table { tool_key, tool_data, tool_label, tool_mod_type }
--- @param activate boolean
--- @return loomworks.Profile|nil
function M.execute_create_profile(cs, tool_entry, activate)
    if activate then
        return cs:activate(tool_entry)
    else
        return cs:ensure_profile(tool_entry)
    end
end

-- =========================================================================
-- Project Configuration Editing
-- =========================================================================

--- Context for editing a project configuration.
--- @param project loomworks.Project
--- @param config_name string|nil nil for new configuration
--- @return table context
function M.compute_edit_configuration_context(project, config_name)
    local ws = project._workspace
    local project_key = project.key
    local type_config = project.type_config or {}

    local impl = project._module and project._module.impl or nil
    local abs_path = ws.root .. "/" .. (project.path or project_key)
    local defaults = impl and impl.default_configurations
        and impl.default_configurations(abs_path, type_config) or {}

    -- Build list of available configs for the "inherits" picker
    local mod_info = impl and impl.info and impl.info(abs_path, type_config)
        or { configurations = {} }
    local available_configs = {}
    for name in pairs(mod_info.configurations or {}) do
        available_configs[#available_configs + 1] = name
    end
    table.sort(available_configs)

    -- Get existing config data (from user override or default)
    local config_data = {}
    local is_default = false
    if config_name then
        -- Check user overrides first
        if type_config.configurations and type_config.configurations[config_name] then
            config_data = type_config.configurations[config_name]
        end
        -- Check if it's a default
        if defaults[config_name] then
            is_default = true
        end
    end

    -- Resolve variant from the merged config (already resolved by module)
    local resolved_config = config_name and (mod_info.configurations or {})[config_name]
    local variant = resolved_config and resolved_config.variant or (config_name or "")

    -- Get project-wide options for display
    local project_options = type_config.options or {}

    -- Resolve inherited options with accurate sources
    local inherited_options = {}
    if mod and mod.resolve_options_with_sources and config_name then
        local all_with_sources = mod.resolve_options_with_sources(
            type_config, mod_info.configurations or {}, config_name)
        local own = config_data.options or {}
        for k, info in pairs(all_with_sources) do
            if not own[k] then
                inherited_options[k] = info
            end
        end
    end

    -- Resolve variant source
    local variant_source = nil
    if impl and impl.resolve_variant_source and config_name then
        variant_source = impl.resolve_variant_source(
            mod_info.configurations or {}, config_name)
    end

    -- Resolve build dir from cache (first matching entry for this config)
    local build_dir = nil
    if config_name and ws.cache.configurations then
        local cache_mod = require("loomworks.cache")
        -- Try direct cache key first (non-keyed modules)
        local ck = cache_mod.config_cache_key(project_key, config_name)
        local cc = ws.cache.configurations[ck]
        if cc and cc.build_dir then
            build_dir = cc.build_dir
        else
            -- For keyed modules, find first cache entry matching this variant
            for _, cfg in pairs(ws.cache.configurations) do
                if cfg.project_key == project_key and cfg.variant == config_name and cfg.build_dir then
                    build_dir = cfg.build_dir
                    break
                end
            end
        end
    end

    return {
        project_key = project_key,
        project_type = project.type,
        name = config_name or "",
        variant = variant or (config_name or ""),
        variant_source = variant_source,
        inherits = config_data.inherits or "",
        options = config_data.options and vim.deepcopy(config_data.options) or {},
        toolchain = config_data.toolchain or "",
        generator = config_data.generator or "",
        is_default = is_default,
        has_options = impl and impl.has_options or false,
        available_configs = available_configs,
        project_options = project_options,
        inherited_options = inherited_options,
        build_dir = build_dir,
    }
end

--- Save a project configuration (create, edit, or rename).
--- @param project loomworks.Project
--- @param old_name string|nil nil for new
--- @param new_name string
--- @param data table { variant?, inherits?, options?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function M.execute_save_configuration(project, old_name, new_name, data)
    -- Rename: atomic propagation to config sets, cache entries, and profiles
    if old_name and old_name ~= new_name then
        local type_config = project.type_config
        if type_config and type_config.configurations
                and type_config.configurations[old_name] then
            return project:rename_configuration(old_name, new_name, data)
        end
    end

    return project:save_configuration(new_name, data)
end

--- Delete a project configuration.
--- @param project loomworks.Project
--- @param config_name string
--- @return boolean ok, string|nil err
function M.execute_delete_configuration(project, config_name)
    return project:delete_configuration(config_name)
end

--- Save project-wide options.
--- @param project loomworks.Project
--- @param options table<string, string>
--- @return boolean ok, string|nil err
function M.execute_save_project_options(project, options)
    return project:save_options(options)
end

-- =========================================================================
-- Launch Config Editing
-- =========================================================================

--- Get all launch configs for a project.
--- @param project loomworks.Project
--- @return { name: string, config: table }[]
function M.get_launch_configs(project)
    if not project.launch then return {} end

    local result = {}
    for name, config in pairs(project.launch) do
        result[#result + 1] = { name = name, config = config }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--- Context for editing a launch config.
--- @param project loomworks.Project
--- @param launch_name string|nil nil for new config
--- @return { project_key: string, name: string, command: string, args: string[], working_dir: string, env: table<string, string> }
function M.compute_edit_launch_context(project, launch_name)
    local config = {}
    if launch_name then
        if project.launch and project.launch[launch_name] then
            config = project.launch[launch_name]
        end
    end

    return {
        project_key = project.key,
        name = launch_name or "",
        command = config.command or "",
        args = config.args or {},
        working_dir = config.working_dir or "",
        env = config.env and vim.deepcopy(config.env) or {},
    }
end

--- Save a launch config (create or update, with optional rename).
--- @param project loomworks.Project
--- @param old_name string|nil nil for new config
--- @param new_name string
--- @param data { command: string, args: string[], working_dir: string, env: table<string, string> }
--- @return boolean ok, string|nil err
function M.execute_save_launch_config(project, old_name, new_name, data)
    -- Build config table (omit empty fields)
    local config = { command = data.command }
    if data.args and #data.args > 0 then config.args = data.args end
    if data.working_dir and data.working_dir ~= "" then config.working_dir = data.working_dir end
    if data.env and next(data.env) then config.env = data.env end

    -- If renamed, delete old first
    if old_name and old_name ~= new_name then
        local ok, err = project:delete_launch_config(old_name)
        if not ok then return false, err end
    end

    return project:save_launch_config(new_name, config)
end

--- Delete a launch config.
--- @param project loomworks.Project
--- @param launch_name string
--- @return boolean ok, string|nil err
function M.execute_delete_launch_config(project, launch_name)
    return project:delete_launch_config(launch_name)
end

return M
