--- loomworks/config_editor.lua — JSON read-modify-write for loomworks.json.
---
--- All mutations write to loomworks.json directly. The file watcher +
--- Core remerge handles propagation to the runtime model.

local io_mod = require("loomworks.io")

local M = {}

--- Read the raw loomworks.json table from disk.
--- @param root string workspace root
--- @return table|nil data, string|nil err
local function read_config(root)
    local path = root .. "/loomworks.json"
    return io_mod.read_json(path)
end

--- Write the raw table back to loomworks.json.
--- @param root string workspace root
--- @param data table
--- @return boolean ok, string|nil err
local function write_config(root, data)
    local path = root .. "/loomworks.json"
    return io_mod.write_json(path, data)
end

--- Create a barebones workspace (loomworks.json).
--- Fails if loomworks.json already exists.
--- @param root string workspace root directory
--- @param name? string workspace name (defaults to directory basename)
--- @return boolean ok, string|nil err
function M.create_workspace(root, name)
    local path = root .. "/loomworks.json"
    local uv = vim.uv or vim.loop
    if uv.fs_stat(path) then
        return false, "loomworks.json already exists in " .. root
    end

    local dir_name = root:match("([^/]+)$") or root
    local data = {
        name = name or dir_name,
        projects = {},
    }

    return write_config(root, data)
end

--- Add a project to an existing workspace.
--- @param root string workspace root directory
--- @param project_key string project name/key
--- @param type string module type ("cmake", "typescript", "harmony")
--- @param path? string relative path (omit if same as project_key)
--- @return boolean ok, string|nil err
function M.add_project(root, project_key, type, path)
    local data, read_err = read_config(root)
    if not data then
        return false, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.projects then
        data.projects = {}
    end

    if data.projects[project_key] then
        return false, "project '" .. project_key .. "' already exists"
    end

    local entry = { [type] = vim.empty_dict() }
    if path and path ~= project_key then
        entry.path = path
    end

    data.projects[project_key] = entry
    return write_config(root, data)
end

--- Add a project with configuration set mappings in one atomic write.
--- Adds the project entry AND updates existing configuration sets.
--- Does NOT create new configuration sets — only adds mappings to existing ones.
--- @param root string workspace root directory
--- @param project_key string project name/key
--- @param type string module type ("cmake", "typescript", "harmony")
--- @param path? string relative path (omit if same as project_key)
--- @param set_mappings table<string, string|nil> set_name → variant (nil entries skipped)
--- @return boolean ok, string|nil err
function M.add_project_with_mappings(root, project_key, type, path, set_mappings)
    local data, read_err = read_config(root)
    if not data then
        return false, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.projects then
        data.projects = {}
    end

    if data.projects[project_key] then
        return false, "project '" .. project_key .. "' already exists"
    end

    -- Add project entry
    local entry = { [type] = vim.empty_dict() }
    if path and path ~= project_key then
        entry.path = path
    end
    data.projects[project_key] = entry

    -- Update existing configuration sets with mappings
    if set_mappings and data.configuration_sets then
        for set_name, variant in pairs(set_mappings) do
            if variant and data.configuration_sets[set_name] then
                data.configuration_sets[set_name][project_key] = variant
            end
        end
    end

    return write_config(root, data)
end

--- Remove a project from an existing workspace.
--- Also removes the project from all configuration_sets and cleans up
--- empty configuration_sets.
--- @param root string workspace root directory
--- @param project_key string project name/key to remove
--- @return boolean ok, string|nil err
function M.remove_project(root, project_key)
    local data, read_err = read_config(root)
    if not data then
        return false, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.projects or not data.projects[project_key] then
        return false, "project '" .. project_key .. "' not found"
    end

    data.projects[project_key] = nil

    -- Clean up configuration_sets references
    if data.configuration_sets then
        local empty_sets = {}
        for set_name, mappings in pairs(data.configuration_sets) do
            if type(mappings) == "table" then
                mappings[project_key] = nil
                -- Check if set is now empty
                if not next(mappings) then
                    empty_sets[#empty_sets + 1] = set_name
                end
            end
        end
        for _, set_name in ipairs(empty_sets) do
            data.configuration_sets[set_name] = nil
        end
        -- Remove configuration_sets entirely if empty
        if not next(data.configuration_sets) then
            data.configuration_sets = nil
        end
    end

    return write_config(root, data)
end

--- Add a configuration set to loomworks.json.
--- Fails if the set name already exists.
--- @param root string workspace root directory
--- @param set_name string configuration set name
--- @param mappings table<string, string> project_key → configuration name
--- @return boolean ok, string|nil err
function M.add_configuration_set(root, set_name, mappings)
    local data, read_err = read_config(root)
    if not data then
        return false, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.configuration_sets then
        data.configuration_sets = {}
    end

    if data.configuration_sets[set_name] then
        return false, "configuration set '" .. set_name .. "' already exists"
    end

    data.configuration_sets[set_name] = mappings
    return write_config(root, data)
end

--- Remove a configuration set from loomworks.json.
--- Orphaned profiles are handled by existing remerge logic.
--- @param root string workspace root directory
--- @param set_name string configuration set name to remove
--- @return boolean ok, string|nil err
function M.remove_configuration_set(root, set_name)
    local data, read_err = read_config(root)
    if not data then
        return false, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.configuration_sets or not data.configuration_sets[set_name] then
        return false, "configuration set '" .. set_name .. "' not found"
    end

    data.configuration_sets[set_name] = nil

    if not next(data.configuration_sets) then
        data.configuration_sets = nil
    end

    return write_config(root, data)
end

--- Compute default configuration sets from project info.
--- Does NOT write to disk — returns the sets table so the caller can
--- present them as options in a picker.
--- @param root string workspace root directory
--- @return table<string, table<string, string>>|nil sets, string|nil err
function M.generate_default_config_sets(root)
    local data, read_err = read_config(root)
    if not data then
        return nil, "failed to read loomworks.json: " .. (read_err or "unknown")
    end

    if not data.projects or not next(data.projects) then
        return nil, "no projects defined"
    end

    local modules = require("loomworks.modules")
    local config_mod = require("loomworks.config")

    -- Gather project info
    local project_infos = {} -- { key, type, config_names[] }
    for project_key, project_def in pairs(data.projects) do
        local ptype = config_mod._extract_type(project_def)
        if ptype then
            local mod = modules.get(ptype)
            if mod and mod.info and mod.map_variant then
                local abs_path = root .. "/" .. (project_def.path or project_key)
                local type_config = project_def[ptype] or {}
                local info = mod.info(abs_path, type_config)
                if info and info.configurations then
                    local config_names = {}
                    for name in pairs(info.configurations) do
                        config_names[#config_names + 1] = name
                    end
                    table.sort(config_names)
                    project_infos[#project_infos + 1] = {
                        key = project_key,
                        type = ptype,
                        config_names = config_names,
                        mod = mod,
                    }
                end
            end
        end
    end

    if #project_infos == 0 then
        return nil, "no projects with detectable configurations"
    end

    -- Standard set candidates
    local candidates = {
        { set_name = "Debug", variant_type = "debug" },
        { set_name = "Release", variant_type = "release" },
    }

    local sets = {}
    for _, candidate in ipairs(candidates) do
        local mappings = {}
        local all_mapped = true
        for _, pinfo in ipairs(project_infos) do
            local mapped = pinfo.mod.map_variant(candidate.variant_type, pinfo.config_names)
            if mapped then
                mappings[pinfo.key] = mapped
            else
                all_mapped = false
                break
            end
        end
        if all_mapped then
            sets[candidate.set_name] = mappings
        end
    end

    -- Fallback: if no candidates succeeded but every project has exactly one config
    if not next(sets) then
        local all_single = true
        local mappings = {}
        for _, pinfo in ipairs(project_infos) do
            if #pinfo.config_names ~= 1 then
                all_single = false
                break
            end
            mappings[pinfo.key] = pinfo.config_names[1]
        end
        if all_single then
            sets["Default"] = mappings
        end
    end

    if not next(sets) then
        return nil, "could not auto-detect configuration sets"
    end

    return sets
end

return M
