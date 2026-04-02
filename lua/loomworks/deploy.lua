--- loomworks/deploy.lua — Deploy step resolution, freshness, execution, cleanup.
---
--- Deploy steps copy build artifacts from one config unit's build directory
--- to a destination path before launch. Freshness tracking ensures files are
--- only copied when the source has changed or the configuration has switched.

local expand = require("loomworks.expand")

local M = {}

--- Check if a path segment contains . or .. traversal.
--- @param path string
--- @return boolean has_traversal
local function has_path_traversal(path)
    for segment in path:gmatch("[^/\\]+") do
        if segment == "." or segment == ".." then
            return true
        end
    end
    return false
end

--- Validate a single source descriptor.
--- @param source table source descriptor
--- @param dest_key string destination key (for error messages)
--- @return boolean ok, string|nil err
local function validate_single_source(source, dest_key)
    if type(source) ~= "table" then
        return false, "deploy source for '" .. dest_key .. "' must be a table"
    end
    if type(source.project) ~= "string" or source.project == "" then
        return false, "deploy source for '" .. dest_key
            .. "' must have a 'project' field"
    end
    local has_target = type(source.target) == "string" and source.target ~= ""
    local has_path = type(source.path) == "string" and source.path ~= ""
    if not has_target and not has_path then
        return false, "deploy source for '" .. dest_key
            .. "' must have either 'target' or 'path'"
    end
    if has_target and has_path then
        return false, "deploy source for '" .. dest_key
            .. "' must have 'target' or 'path', not both"
    end
    if source.configuration ~= nil and type(source.configuration) ~= "string" then
        return false, "deploy source for '" .. dest_key
            .. "': 'configuration' must be a string"
    end
    return true
end

--- Normalize source value to an array of source descriptors.
--- Accepts a single descriptor or an array of descriptors.
--- @param source table single source or array of sources
--- @return table[] array of source descriptors
function M.normalize_sources(source)
    if source[1] then return source end  -- already an array
    if source.project then return { source } end  -- single descriptor
    return { source }
end

--- Validate deploy definitions from a launch config.
--- Source can be a single descriptor or an array of descriptors.
--- @param deploy table<string, table|table[]> destination → source(s)
--- @return boolean ok, string|nil err
function M.validate_deploy_definitions(deploy)
    if type(deploy) ~= "table" then
        return false, "deploy must be a table"
    end
    for dest_key, source_val in pairs(deploy) do
        if type(dest_key) ~= "string" or dest_key == "" then
            return false, "deploy destination key must be a non-empty string"
        end
        local stripped = dest_key:gsub("%${[^}]+}", "_placeholder_")
        if has_path_traversal(stripped) then
            return false, "deploy destination '" .. dest_key
                .. "' contains '.' or '..' path segments"
        end
        if type(source_val) ~= "table" then
            return false, "deploy source for '" .. dest_key .. "' must be a table"
        end
        local sources = M.normalize_sources(source_val)
        for _, source in ipairs(sources) do
            local ok, err = validate_single_source(source, dest_key)
            if not ok then return false, err end
        end
    end
    return true
end

--- Resolve a single deploy step to concrete source and destination paths.
--- @param dest_template string destination path template (with ${} variables)
--- @param source_def table source descriptor { project, target?, path?, configuration? }
--- @param ctx table { workspace, profile, launch_project }
--- @return table|nil resolved { source_path, dest_path, source_build_dir_id, source_rel_path }
--- @return string|nil error
function M.resolve_deploy_step(dest_template, source_def, ctx)
    local ws = ctx.workspace
    local profile = ctx.profile
    local launch_project = ctx.launch_project

    -- Expand destination in the launch target's project context
    local launch_ctx = expand.launch_context(ws, profile, launch_project)
    local dest_path = expand.expand_string(dest_template, launch_ctx)

    -- Make destination absolute if not already
    if not dest_path:match("^/") and not dest_path:match("^%a:") then
        dest_path = ws.root .. "/" .. dest_path
    end

    -- Resolve source project
    local source_project
    for _, p in pairs(ws._projects) do
        if p.key == source_def.project then
            source_project = p
            break
        end
    end
    if not source_project then
        return nil, "project '" .. source_def.project .. "' not found"
    end

    -- Determine source configuration: pinned or from profile mapping
    local source_variant
    if source_def.configuration then
        source_variant = source_def.configuration
    else
        if profile.mappings and profile.mappings[source_project.key] then
            source_variant = profile.mappings[source_project.key]
        end
    end
    if not source_variant then
        return nil, "no configuration mapping for project '"
            .. source_def.project .. "' in profile"
    end

    -- Find the config unit for (source project, resolved configuration) in the profile
    local pp = profile:project(source_project.key)
    if not pp then
        return nil, "project '" .. source_def.project .. "' not in profile"
    end

    -- Find the config unit — walk profile projects to match variant
    local source_unit = pp._config_unit
    if not source_unit then
        return nil, "no config unit for project '" .. source_def.project .. "' in profile"
    end

    -- Verify the config unit matches the expected variant
    if source_unit._variant ~= source_variant then
        return nil, "config unit variant '" .. (source_unit._variant or "nil")
            .. "' does not match expected '" .. source_variant .. "'"
    end

    -- Get the build directory
    local build_dir = source_unit.build_dir_value
    if not build_dir then
        return nil, "no build directory for project '" .. source_def.project
            .. "' configuration '" .. source_variant .. "'"
    end

    -- Resolve source file path
    local source_rel_path
    if source_def.target then
        -- Look up cmake target → artifact path
        if not source_unit.targets then
            return nil, "no targets available for project '"
                .. source_def.project .. "' (not yet configured?)"
        end
        local target = source_unit.targets[source_def.target]
        if not target then
            return nil, "target '" .. source_def.target
                .. "' not found in project '" .. source_def.project .. "'"
        end
        if not target.artifact then
            return nil, "target '" .. source_def.target
                .. "' has no artifact path"
        end
        source_rel_path = target.artifact
    else
        source_rel_path = source_def.path
        -- Strip ${build_dir}/ prefix if user accidentally included it
        -- (source path is always relative to the build directory)
        source_rel_path = source_rel_path:gsub("^%${build_dir}/", "")
        -- Strip leading / to prevent absolute path concatenation
        source_rel_path = source_rel_path:gsub("^/+", "")
    end

    local source_path = build_dir .. "/" .. source_rel_path

    -- If destination ends with /, it's a directory — append source filename
    if dest_path:sub(-1) == "/" then
        local filename = source_rel_path:match("[^/\\]+$")
        dest_path = dest_path .. filename
    end

    -- Build dir ID for freshness tracking
    local cache_mod = require("loomworks.cache")
    local source_build_dir_id = cache_mod.relative_build_dir(build_dir, ws.root)

    return {
        source_path = source_path,
        dest_path = dest_path,
        source_build_dir_id = source_build_dir_id,
        source_rel_path = source_rel_path,
    }
end

--- Check if a deploy step needs to copy (freshness check).
--- @param resolved table resolved deploy step
--- @param deploy_records table<string, table> normalized dest → record
--- @param normalize fun(p: string): string path normalizer
--- @return boolean needs_copy
function M.check_freshness(resolved, deploy_records, normalize)
    local dest_key = normalize(resolved.dest_path)
    local record = deploy_records[dest_key]

    -- No record → never copied
    if not record then return true end

    -- Destination file missing on disk
    local stat = (vim.uv or vim.loop).fs_stat(resolved.dest_path)
    if not stat then return true end

    -- Source identity changed (config switch or path change)
    if record.source_build_dir ~= resolved.source_build_dir_id then return true end
    if record.source_rel_path ~= resolved.source_rel_path then return true end

    -- Source file newer than last copy
    local source_stat = (vim.uv or vim.loop).fs_stat(resolved.source_path)
    if not source_stat then return true end  -- source missing, will fail on copy

    local source_mtime = source_stat.mtime
    if type(source_mtime) == "table" then
        source_mtime = source_mtime.sec
    end
    local recorded_mtime = record.source_mtime
    if type(recorded_mtime) == "string" then
        -- ISO timestamp → parse to epoch (approximate comparison)
        -- For robustness, always copy if mtime format differs
        return true
    end
    if source_mtime > recorded_mtime then return true end

    return false
end

--- Execute all deploy steps for a launch target.
--- Resolves all steps first (fail-fast), then copies as needed.
--- Source values can be a single descriptor or an array of descriptors.
--- @param deploy_dict table<string, table|table[]> deploy definitions from launch config
--- @param ctx table { workspace, profile, launch_project }
--- @param deploy_records table<string, table> workspace deploy records (mutated on copy)
--- @param normalize fun(p: string): string path normalizer
--- @param on_complete fun(ok: boolean, err?: string)
function M.execute_deploy_steps(deploy_dict, ctx, deploy_records, normalize, on_complete)
    if not deploy_dict or not next(deploy_dict) then
        on_complete(true)
        return
    end

    -- Phase 1: resolve all steps (expand arrays into individual steps)
    local resolved_steps = {}
    for dest_template, source_val in pairs(deploy_dict) do
        local sources = M.normalize_sources(source_val)
        for _, source_def in ipairs(sources) do
            local resolved, err = M.resolve_deploy_step(dest_template, source_def, ctx)
            if not resolved then
                on_complete(false, "Deploy: " .. err)
                return
            end
            resolved_steps[#resolved_steps + 1] = resolved
        end
    end

    -- Phase 2: check freshness and copy
    local uv = vim.uv or vim.loop
    local errors = {}

    for _, step in ipairs(resolved_steps) do
        if M.check_freshness(step, deploy_records, normalize) then
            -- Verify source exists
            local source_stat = uv.fs_stat(step.source_path)
            if not source_stat then
                errors[#errors + 1] = "source file missing: " .. step.source_path
                goto continue
            end

            -- Create parent directory
            local dest_dir = vim.fn.fnamemodify(step.dest_path, ":h")
            vim.fn.mkdir(dest_dir, "p")

            -- Copy file
            local ok, copy_err = uv.fs_copyfile(step.source_path, step.dest_path)
            if not ok then
                errors[#errors + 1] = "copy failed: " .. step.source_path
                    .. " → " .. step.dest_path .. ": " .. tostring(copy_err)
                goto continue
            end

            -- Update deploy record
            local source_mtime = source_stat.mtime
            if type(source_mtime) == "table" then
                source_mtime = source_mtime.sec
            end
            local dest_key = normalize(step.dest_path)
            deploy_records[dest_key] = {
                source_build_dir = step.source_build_dir_id,
                source_rel_path = step.source_rel_path,
                source_mtime = source_mtime,
            }
        end
        ::continue::
    end

    if #errors > 0 then
        on_complete(false, table.concat(errors, "; "))
    else
        on_complete(true)
    end
end

--- Clean deploy records sourced from a given build directory.
--- Deletes destination files and removes records.
--- @param deploy_records table<string, table> workspace deploy records (mutated)
--- @param build_dir_id string relative build dir path to match
--- @return string[] removed_keys list of removed destination keys
function M.clean_deploy_records(deploy_records, build_dir_id)
    local removed = {}
    for dest_key, record in pairs(deploy_records) do
        if record.source_build_dir == build_dir_id then
            -- Try to delete destination file
            pcall(function()
                local uv = vim.uv or vim.loop
                uv.fs_unlink(dest_key)
            end)
            removed[#removed + 1] = dest_key
        end
    end
    -- Remove records
    for _, key in ipairs(removed) do
        deploy_records[key] = nil
    end
    return removed
end

return M
