--- loomworks/workspace_view.lua — View-model layer for workspace UI.
---
--- Orchestration logic for the UI: pure queries and multi-step mutations
--- the UI calls instead of doing inline. Workspace atomic mutations
--- (add_project, remove_project, etc.) stay in workspace.lua — this layer
--- composes them.

local modules = require("loomworks.modules")
local commands = require("loomworks.model_commands")
local deletion_plan = require("loomworks.deletion_plan")

local M = {}

--- A command's outcome (model_commands, API.md §4.1) as the editor's
--- `ok, err`: refused is `false, message`. A `warn` note of an `ok` composite
--- (D1) is reported as the error it was before the command layer, so the
--- editor still shows it as one.
--- @param r loomworks.CommandOutcome
--- @return boolean ok, string|nil err
local function as_result(r)
    if r.outcome ~= "ok" then return false, r.message end
    for i, role in ipairs(r.note_roles or {}) do
        if role == "warn" then return false, r.notes[i] end
    end
    return true
end

--- The candidate token of an automatic configuration set
--- (model_commands.candidate_token).
M.candidate_token = commands.candidate_token

--- Extract display-friendly project_key and config_key from a DeletionItem.
--- Reads from the unit's resolved references, with fallbacks.
--- @param item loomworks.DeletionItem
--- @return string project_key, string config_key
local function item_display_keys(item)
    local unit = item.unit
    if not unit then return "?", "?" end
    local pkey = unit._project and unit._project.key or unit._init_project_key or "?"
    local ckey = unit:config_key() or unit.id
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

--- Context for adding a project of `mod_type` (the add command's initial
--- mappings and tool, model_commands): inherited tool, no-tool profiles,
--- keyed tools. Pure query over cached profiles.
--- @param ws loomworks.Workspace
--- @param mod_type string module type (e.g. "cmake")
--- @return { inherited_tool: table|nil, no_tool_profiles: string[], keyed_tools: table[] }
function M.compute_add_project_context(ws, mod_type)
    local mod = modules.get(mod_type)
    local has_keyed = mod and mod.has_keyed_tools or false

    local inherited_tool = nil
    local no_tool_profiles = {}

    if has_keyed then
        for _, profile in pairs(ws._profiles) do
            if profile._configuration_set_name then
                local tool_ref = profile:tool_for(mod_type)
                if tool_ref then
                    if not inherited_tool then
                        inherited_tool = {
                            tool_key = tool_ref.key,
                            tool_data = tool_ref.data,
                            tool_label = tool_ref.label,
                            tool_mod_type = mod_type,
                        }
                    end
                elseif not profile:tools_data() then
                    no_tool_profiles[#no_tool_profiles + 1] = profile.key
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
--- @return boolean ok, string|nil err
function M.execute_add_project(ws, key, mod_type, path, result)
    -- A keyed module's project without a toolchain is added unmapped: its
    -- configurations are mapped once a tool is chosen (when a profile is
    -- created), so initial mappings passed without one are not a request
    -- (no warn note).
    local mod = require("loomworks.modules").get(mod_type)
    local mappings = result.mappings
    if mod and mod.has_keyed_tools and not result.tool_entry then mappings = nil end
    local r = commands.project_add(ws, key, mod_type, path, mappings, result.tool_entry)
    local ok, err = as_result(r)
    return ok, err, r.project
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

-- =========================================================================
-- Initial Configuration-Set Mappings (adding a project)
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

    -- Build profile lookup from domain objects
    local profiles_by_key = {}
    for _, p in pairs(ws._profiles) do profiles_by_key[p.key] = p end

    local result = {}
    for _, r in ipairs(renames) do
        local profile = profiles_by_key[r.old_key]
        if profile and sets_with_mapping[profile._configuration_set_name] then
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
--- @return table[] items array of { name, real_name?, mappings?, candidate?, cs?, auto, desc? }
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
                    candidate = commands.candidate_token(name, set_mappings),
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
--- @return { projects: loomworks.Project[], mappings: table<loomworks.Project, loomworks.Configuration|nil>, available_configs: table<loomworks.Project, loomworks.Configuration[]> }
function M.compute_create_config_set_context(ws)
    local projects = {}
    local mappings = {}
    local available_configs = {}

    for _, project in pairs(ws._projects) do
        projects[#projects + 1] = project
        local configs = {}
        if project._configurations then
            for _, cfg in ipairs(project._configurations) do
                configs[#configs + 1] = cfg
            end
            table.sort(configs, function(a, b) return a.name < b.name end)
        end
        available_configs[project] = configs
    end
    table.sort(projects, function(a, b) return a.key < b.key end)

    return {
        projects = projects,
        mappings = mappings,
        available_configs = available_configs,
    }
end

--- Execute config set creation.
--- Accepts object-based mappings and serializes to key strings for disk.
--- @param ws loomworks.Workspace
--- @param name string config set name
--- @param mappings table<loomworks.Project, loomworks.Configuration|nil>
--- @return loomworks.ConfigurationSet|nil cs, string|nil err
function M.execute_create_config_set(ws, name, mappings)
    local r = commands.config_set_add(ws, name, mappings)
    if r.outcome ~= "ok" then return nil, r.message end
    return r.config_set
end

--- Context for editing a config set: current mappings, available configs
--- per project (from module.info).
--- @param ws loomworks.Workspace
--- @param set_name string
--- @return { set_name: string, mappings: table<string, string|nil>, available_configs: table<string, string[]>, project_keys: string[] }|nil
function M.compute_edit_config_set_context(ws, set_name)
    -- Find the ConfigurationSet domain object by name
    local config_set = nil
    for _, cs in pairs(ws._config_sets) do
        if cs.name == set_name then config_set = cs; break end
    end
    if not config_set then return nil end

    local projects = {}
    local mappings = {}     -- Project → Configuration|nil
    local available_configs = {} -- Project → Configuration[]

    for _, project in pairs(ws._projects) do
        projects[#projects + 1] = project
        -- Read Configuration object directly from CS mapping
        mappings[project] = config_set:configuration(project)
        -- Collect available Configuration objects
        local configs = {}
        if project._configurations then
            for _, cfg in ipairs(project._configurations) do
                configs[#configs + 1] = cfg
            end
            table.sort(configs, function(a, b) return a.name < b.name end)
        end
        available_configs[project] = configs
    end
    table.sort(projects, function(a, b) return a.key < b.key end)

    return {
        set_name = set_name,
        projects = projects,
        mappings = mappings,
        available_configs = available_configs,
    }
end

--- Execute config set edit: replace the mappings (a project absent from
--- `new_mappings` is unmapped), renaming first when the name changed
--- (model_commands.config_set_update).
--- @param cs loomworks.ConfigurationSet the config set to edit
--- @param new_name string new name (same as cs.name if not renamed)
--- @param new_mappings table<loomworks.Project, loomworks.Configuration|nil>
--- @return boolean ok, string|nil err
function M.execute_edit_config_set(cs, new_name, new_mappings)
    return as_result(commands.config_set_update(cs, new_name, new_mappings))
end

--- Context for deleting a config set: affected profiles, warning lines.
--- @param ws loomworks.Workspace
--- @param cs loomworks.ConfigurationSet
--- @return { profiles: string[], lines: string[], highlights: table[] }|nil
function M.compute_delete_config_set_context(ws, cs)
    local set_name = cs.name
    if cs._removed then return nil end

    -- Find profiles referencing this set
    local affected_profiles = {}
    for _, profile in pairs(ws._profiles) do
        if profile._configuration_set_name == set_name then
            affected_profiles[#affected_profiles + 1] = profile.key
        end
    end
    table.sort(affected_profiles)

    local lines = {
        "  Delete configuration set: " .. set_name,
    }
    local highlights = {
        { line = 1, hl_group = "DiagnosticWarn" },
    }
    -- The set's description summary (spec/ui.md §1.16).
    local summary = require("loomworks.ui.helpers").picker_summary(cs.description, 70)
    if summary ~= "" then
        lines[#lines + 1] = "  " .. summary
        highlights[#highlights + 1] = { line = #lines, hl_group = "Comment" }
    end
    lines[#lines + 1] = ""

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
--- @param _ws loomworks.Workspace unused (the set's own)
--- @param cs loomworks.ConfigurationSet
--- @return boolean ok, string|nil err
function M.execute_delete_config_set(_ws, cs)
    return as_result(commands.config_set_remove(cs))
end

--- Add the automatic configuration set of a template / candidate (its
--- `candidate` token from compute_config_set_candidates).
--- @param ws loomworks.Workspace
--- @param candidate string
--- @return loomworks.ConfigurationSet|nil cs, string|nil err
function M.execute_create_config_set_from_candidate(ws, candidate)
    local r = commands.config_set_add_candidate(ws, candidate)
    if r.outcome ~= "ok" then return nil, r.message end
    return r.config_set
end

-- =========================================================================
-- Orphan Cleanup
-- =========================================================================

--- Build directories on disk under {root}/.nvim/build/ that no cache entry
--- references (Workspace:find_stray_build_dirs).
--- @param ws loomworks.Workspace
--- @return string[] absolute paths of stray directories
function M.find_stray_build_dirs(ws)
    return ws:find_stray_build_dirs()
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

-- =========================================================================
-- Confirmation Dialog Content
-- =========================================================================

--- Collect clean items for a profile (project_key, config_key, build_dir).
--- @param profile loomworks.Profile
--- @return table[]
function M.collect_clean_items(profile)
    local items = {}
    for _, pp in ipairs(profile:projects()) do
        items[#items + 1] = {
            project_key = pp:project_key(),
            config_key = pp:config_key(),
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
--- @param description? string|nil the item's description; its summary follows the title
--- @return { lines: string[], highlights: table[] }
function M.compute_delete_confirmation_context(ws, title, plan, description)
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
    -- The item's description summary, so the user can confirm which item is
    -- going (spec/ui.md §1.16).
    local summary = require("loomworks.ui.helpers").picker_summary(description, 70)
    if summary ~= "" then add("  " .. summary, "Comment") end
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

-- =========================================================================
-- Create Profile
-- =========================================================================

--- Handle a config set choice for profile creation: materialize an
--- auto-detected set (by its candidate token), resolve the
--- ConfigurationSet object.
--- @param ws loomworks.Workspace
--- @param choice { cs?: loomworks.ConfigurationSet, auto: boolean, candidate?: string, real_name?: string, mappings?: table }
--- @return loomworks.ConfigurationSet|nil cs, string|nil err
function M.resolve_config_set_choice(ws, choice)
    if not choice.auto then return choice.cs end
    return M.execute_create_config_set_from_candidate(ws,
        choice.candidate or commands.candidate_token(choice.real_name, choice.mappings))
end

--- The command outcomes the status page's profile-creation picker reads
--- and writes in the `in-process` mode (loomworks.model_commands' own
--- outcomes, API.md §4.1, not `ok, err`: the seam passes them on as the
--- daemon's): the declared and automatic configuration sets, a set's
--- toolchain choices and the creation itself. `set` a ConfigurationSet or
--- `{ candidate = token }` (step 5o C2a).
--- @param ws loomworks.Workspace
--- @return loomworks.CommandOutcome
function M.config_set_candidates(ws) return commands.config_set_candidates(ws) end
--- @param ws loomworks.Workspace
--- @param set loomworks.ConfigurationSet|{ candidate: string }|nil
--- @return loomworks.CommandOutcome
function M.profile_tool_choices(ws, set) return commands.profile_tool_choices(ws, set) end
--- @param ws loomworks.Workspace
--- @param set loomworks.ConfigurationSet|{ candidate: string }|nil
--- @param tool_entry table|nil
--- @param activate boolean
--- @return loomworks.CommandOutcome
function M.create_profile(ws, set, tool_entry, activate)
    return commands.profile_create(ws, set, tool_entry, activate)
end

--- `Workspace/1.delete_user_prefs { plan? }` in the `in-process` mode: the
--- working copy of the loaded workspace (else of the refused load, else of
--- the cwd's root); without `plan` the `confirm` of what would be deleted,
--- with it the deletion of exactly that (model_commands; the command's
--- outcome).
--- @param ws loomworks.Workspace|nil
--- @param plan string|nil
--- @return loomworks.CommandOutcome|{ outcome: "confirm", lines: string[], plan: string }
function M.delete_user_prefs(ws, plan)
    local lw = require("loomworks")
    local r = commands.delete_user_prefs(lw._core(), (ws and ws.root) or lw.user_prefs_root(), plan)
    r.reloaded = nil
    return r
end

--- Execute profile creation: materialize, or return the existing profile of
--- that set and tool; optionally activate.
--- @param cs loomworks.ConfigurationSet
--- @param tool_entry? table { tool_key, tool_data, tool_label, tool_mod_type }
--- @param activate boolean
--- @return loomworks.Profile|nil profile, string|nil err
function M.execute_create_profile(cs, tool_entry, activate)
    local r = commands.profile_create(cs._workspace, cs, tool_entry, activate)
    if not r.profile then
        local _, err = as_result(r)
        return nil, err
    end
    return r.profile
end

-- =========================================================================
-- Project Configuration Editing
-- =========================================================================

--- Save a project configuration from the configuration editor dialog (create,
--- update, or rename): only the dialog's fields change; every other declared
--- field is kept (model_commands.configuration_save).
--- @param project loomworks.Project
--- @param cfg loomworks.Configuration|nil the configuration edited; nil for new
--- @param new_name string
--- @param edits table { inherits?, options?, variables?, languages?, toolchain?, generator? }
--- @return boolean ok, string|nil err
function M.execute_save_configuration(project, cfg, new_name, edits)
    return as_result(commands.configuration_save(project, cfg, new_name, edits))
end

--- Delete a project configuration.
--- @param project loomworks.Project
--- @param cfg loomworks.Configuration
--- @return boolean ok, string|nil err
function M.execute_delete_configuration(project, cfg)
    return as_result(commands.configuration_remove(project, cfg))
end

--- Save project-wide options.
--- @param project loomworks.Project
--- @param options table<string, string>
--- @return boolean ok, string|nil err
function M.execute_save_project_options(project, options)
    return as_result(commands.options_save(project, options))
end

-- =========================================================================
-- Launch Config Editing
-- =========================================================================

--- Save a launch config (create or update, with optional rename;
--- model_commands.launch_save).
--- @param project loomworks.Project
--- @param launch loomworks.LaunchConfiguration|nil nil for a new config
--- @param new_name string
--- @param data { command: string, args: string[], working_dir: string, env: table<string, string>, deploy?: table, debug?: string[] }
--- @return boolean ok, string|nil err, loomworks.LaunchConfiguration|nil launch
function M.execute_save_launch_config(project, launch, new_name, data)
    local r = commands.launch_save(project, launch, new_name, data)
    local ok, err = as_result(r)
    return ok, err, r.launch
end

--- Delete a launch config.
--- @param project loomworks.Project
--- @param launch loomworks.LaunchConfiguration
--- @return boolean ok, string|nil err
function M.execute_delete_launch_config(project, launch)
    return as_result(commands.launch_remove(project, launch))
end

-- ---------------------------------------------------------------------------
-- Variable editing
-- ---------------------------------------------------------------------------

--- Get sorted list of project variable declarations.
--- @param project loomworks.Project
--- @return { name: string, type: string, default: string }[]
function M.get_variables(project)
    if not project.variables then return {} end
    local result = {}
    for name, decl in pairs(project.variables) do
        result[#result + 1] = { name = name, type = decl.type, default = decl.default }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

--- The project's declaration as the working copy holds it (for the
--- variable and configuration editors; model_commands.project_declaration),
--- without ids.
--- @param project loomworks.Project
--- @return loomworks.CommandOutcome
function M.project_declaration(project)
    return commands.project_declaration(project, function() return nil end)
end

--- Each template expanded as a launch of `project` would expand it, under
--- the active profile (the launch, deploy and path editors' previews;
--- model_commands.expand_preview).
--- @param project loomworks.Project
--- @param templates string[]
--- @return loomworks.CommandOutcome values: string[]
function M.expand_preview(project, templates)
    return commands.expand_preview(project, nil, templates)
end

--- Save a variable declaration.
--- @param project loomworks.Project
--- @param old_name string|nil nil for new variable
--- @param new_name string
--- @param data { type: string, default: string }
--- @return boolean ok, string|nil err
function M.execute_save_variable(project, old_name, new_name, data)
    return as_result(commands.variable_save(project, old_name, new_name, data))
end

--- Delete a variable declaration.
--- @param project loomworks.Project
--- @param var_name string
--- @return boolean ok, string|nil err
function M.execute_delete_variable(project, var_name)
    return as_result(commands.variable_remove(project, var_name))
end

-- ---------------------------------------------------------------------------
-- Other model writes (model_commands): publish state, descriptions,
-- profiles' toolchains, deploy, type_config fields, SDKs
-- ---------------------------------------------------------------------------

--- Publish the working copy (`:w`).
--- @param ws loomworks.Workspace
--- @return boolean ok, string|nil err
function M.publish(ws) return as_result(commands.publish(ws)) end

--- Revert the working copy to the published baseline (`:e!`).
--- @param ws loomworks.Workspace
--- @return boolean ok, string|nil err
function M.revert_to_baseline(ws) return as_result(commands.revert_to_baseline(ws)) end

--- Publish one item.
--- @param item table a profile, configuration set, project or configuration
--- @return boolean ok, string|nil err
function M.publish_one(item) return as_result(commands.publish_one(item)) end

--- Revert one item to its published baseline.
--- @param item table
--- @return boolean ok, string|nil err
function M.revert_one(item) return as_result(commands.revert_one(item)) end

--- Set an item's intent (`P` cycles it; the next value is the caller's).
--- @param item table
--- @param intent "local"|"shared"|"local+shared"
--- @return boolean ok, string|nil err
function M.set_intent(item, intent) return as_result(commands.set_intent(item, intent)) end

--- Set or clear an item's description (a launch configuration included).
--- @param item table
--- @param text string|nil
--- @return boolean|nil changed true when saved, false when unchanged, nil on refusal
--- @return string|nil err
function M.set_description(item, text)
    local r = commands.set_description(item, text)
    if r.outcome ~= "ok" then return nil, r.message end
    return r.changed
end

--- Make a profile the active one.
--- @param profile loomworks.Profile
--- @return boolean ok, string|nil err
function M.activate_profile(profile) return as_result(commands.profile_set_active(profile)) end

--- Add a toolchain (its key) to a profile.
--- @param profile loomworks.Profile
--- @param tool_key string
--- @return boolean ok, string|nil err
function M.add_profile_tool(profile, tool_key) return as_result(commands.profile_add_tool(profile, tool_key)) end

--- Remove a toolchain (its key) from a profile.
--- @param profile loomworks.Profile
--- @param tool_key string
--- @return boolean ok, string|nil err
function M.remove_profile_tool(profile, tool_key)
    return as_result(commands.profile_remove_tool(profile, tool_key))
end

--- Save a project's whole deploy declaration (nil or empty removes it).
--- @param project loomworks.Project
--- @param deploy table|nil
--- @return boolean ok, string|nil err
function M.save_deploy(project, deploy) return as_result(commands.deploy_save(project, deploy)) end

--- Set or clear one of a project's editable type_config fields.
--- @param project loomworks.Project
--- @param field string
--- @param value any
--- @return boolean ok, string|nil err
function M.save_type_config_field(project, field, value)
    return as_result(commands.type_config_set(project, field, value))
end

--- `Maintenance/1.execute_deletion { target, plan?, yes? }` in-process
--- (model_commands.execute_deletion; step 5o C2c-2): `cb` gets the request's
--- `refused` or `confirm { lines, plan }` at once (its lines end with the
--- running tasks the deletion stops, if any), or — accepted — the
--- deletion's final outcome once it ended (`ok`, or `refused`: a held lock,
--- a changed plan, a failed removal). Never `cb` at the acceptance.
--- @param ws loomworks.Workspace
--- @param target table a deletion target (its objects; loomworks.deletion_plan)
--- @param plan string|nil the token the confirmation returned
--- @param yes boolean|nil
--- @param cb fun(r: loomworks.CommandOutcome)
function M.execute_deletion(ws, target, plan, yes, cb)
    local r = commands.execute_deletion(ws, target, { plan = plan, yes = yes, done = cb })
    if r.outcome == "confirm" then
        -- The editor's own running tasks the deletion stops first
        -- (Workspace:_run_deletion; spec/ui.md §1.10), after the listing.
        local running = ws:find_running_tasks_for_items(deletion_plan.plan(ws, target).items)
        local stopped = {}
        for _, info in pairs(running) do
            stopped[#stopped + 1] = "  " .. tostring(info.project_key) .. ": " .. tostring(info.action) .. " "
                .. tostring(info.configuration_key)
        end
        if #stopped > 0 then
            table.sort(stopped)
            r.lines[#r.lines + 1] = "Will stop running tasks:"
            vim.list_extend(r.lines, stopped)
        end
    end
    if r.outcome ~= "accepted" then cb(r) end
end

--- `Maintenance/1.nuke { plan?, yes? }` in-process (model_commands.nuke) on
--- the root of `ws`, else the refused load's or the cwd's
--- (`user_prefs_root`): the command's outcome.
--- @param ws loomworks.Workspace|nil
--- @param plan string|nil
--- @param yes boolean|nil
--- @return loomworks.CommandOutcome
function M.nuke(ws, plan, yes)
    local lw = require("loomworks")
    return commands.nuke(lw._core(), (ws and ws.root) or lw.user_prefs_root(), plan, yes)
end

--- The installed SDK providers (or the one named) and the installations
--- each detects (model_commands.sdk_detect): the command's outcome.
--- @param provider string|nil
--- @return loomworks.CommandOutcome
function M.sdk_detect(provider) return commands.sdk_detect(provider) end

--- Declare an SDK.
--- @param ws loomworks.Workspace
--- @param provider string
--- @param path string|nil
--- @return loomworks.SDK|nil sdk, string|nil err
function M.add_sdk(ws, provider, path)
    local r = commands.sdk_add(ws, provider, path)
    if r.outcome ~= "ok" then return nil, r.message end
    return r.sdk
end

--- Remove an SDK's declaration.
--- @param ws loomworks.Workspace
--- @param sdk loomworks.SDK
--- @return boolean ok, string|nil err
function M.remove_sdk(ws, sdk) return as_result(commands.sdk_remove(ws, sdk)) end

return M
