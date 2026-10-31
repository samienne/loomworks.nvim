--- loomworks/deploy.lua — Deploy step resolution, freshness, execution, cleanup.
---
--- Deploy steps copy build artifacts from one config unit's build directory
--- to a destination path before launch. Freshness tracking ensures files are
--- only copied when the source has changed or the configuration has switched.

local expand = require("loomworks.expand")
local uv = vim.uv or vim.loop

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
    if source.pre_build ~= nil and type(source.pre_build) ~= "boolean" then
        return false, "deploy source for '" .. dest_key
            .. "': 'pre_build' must be a boolean"
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

--- Check whether a destination string denotes a directory (trailing "/").
--- @param dest string
--- @return boolean
local function is_dir_destination(dest)
    return dest:sub(-1) == "/" or dest:sub(-1) == "\\"
end

--- Partition a deploy dict by the `pre_build` flag on each source.
--- Each phase dict preserves the destination keys with only the
--- sources whose `pre_build` value matches the bucket.
--- @param deploy table<string, table|table[]>|nil
--- @return table pre_dict, table post_dict
function M.partition_by_phase(deploy)
    local pre_dict, post_dict = {}, {}
    if not deploy then return pre_dict, post_dict end
    for dest, source_val in pairs(deploy) do
        local sources = M.normalize_sources(source_val)
        local pre_sources, post_sources = {}, {}
        for _, src in ipairs(sources) do
            if src.pre_build then
                pre_sources[#pre_sources + 1] = src
            else
                post_sources[#post_sources + 1] = src
            end
        end
        if #pre_sources > 0 then pre_dict[dest] = pre_sources end
        if #post_sources > 0 then post_dict[dest] = post_sources end
    end
    return pre_dict, post_dict
end

--- Merge a project-level deploy dict with a launch-level deploy dict.
--- For directory destinations (trailing "/"), sources from both levels
--- are concatenated (union). For single-file destinations, launch-level
--- overrides project-level wholesale (cascade override).
--- Inputs may be nil or empty; both are normalised internally.
--- @param project_deploy table<string, table|table[]>|nil
--- @param launch_deploy table<string, table|table[]>|nil
--- @return table<string, table[]> merged deploy dict (values always arrays)
function M.merge_deploy_sources(project_deploy, launch_deploy)
    local merged = {}

    if project_deploy then
        for dest, source_val in pairs(project_deploy) do
            local sources = M.normalize_sources(source_val)
            local copy = {}
            for i, s in ipairs(sources) do copy[i] = s end
            merged[dest] = copy
        end
    end

    if launch_deploy then
        for dest, source_val in pairs(launch_deploy) do
            local sources = M.normalize_sources(source_val)
            if is_dir_destination(dest) and merged[dest] then
                -- Directory: concatenate (project first, then launch)
                for _, s in ipairs(sources) do
                    merged[dest][#merged[dest] + 1] = s
                end
            else
                -- File destination or no collision: launch wins
                local copy = {}
                for i, s in ipairs(sources) do copy[i] = s end
                merged[dest] = copy
            end
        end
    end

    return merged
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

--- "deploy <what> references unresolved variable(s) ${a}, ${b}".
--- @param what string
--- @param vars string[]
--- @return string
local function unresolved_msg(what, vars)
    local refs = {}
    for _, v in ipairs(vars) do refs[#refs + 1] = "${" .. v .. "}" end
    return "deploy " .. what .. " references unresolved variable" .. (#refs > 1 and "s " or " ")
        .. table.concat(refs, ", ") .. " (not defined in this launch context)"
end

--- Resolve a single deploy step to concrete source and destination paths.
--- A `${...}` reference that does not resolve (in the destination, or a
--- `path` source) fails the step, never expands to a literal path.
--- @param dest_template string destination path template (with ${} variables)
--- @param source_def table source descriptor { project, target?, path?, configuration? }
--- @param ctx table { workspace, profile, launch_project, launch_build_target? }
--- @return table|nil resolved { source_path, dest_path, source_build_dir_id, source_rel_path }
--- @return string|nil error
function M.resolve_deploy_step(dest_template, source_def, ctx)
    local ws = ctx.workspace
    local profile = ctx.profile
    local launch_project = ctx.launch_project

    -- Expand destination in the launch target's project context
    local launch_ctx = expand.launch_context(ws, profile, launch_project,
        { target = ctx.launch_build_target })
    -- An unresolved reference (e.g. `${target_dir}` for a command launch or
    -- an unconfigured unit, §8.7) would stay literal and copy into a folder
    -- named after it: fail the step instead, naming the variable.
    local dest_unresolved = expand.unresolved_vars(dest_template, launch_ctx)
    if #dest_unresolved > 0 then
        return nil, unresolved_msg("destination '" .. dest_template .. "'", dest_unresolved)
    end
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
        -- Safety: if artifact is absolute (prefix strip failed in parse_targets),
        -- strip the build_dir prefix here with case-insensitive comparison
        if source_rel_path:match("^%a:") or source_rel_path:match("^/") then
            local bd_norm = build_dir:gsub("\\", "/"):gsub("/?$", "/")
            local art_norm = source_rel_path:gsub("\\", "/")
            if art_norm:lower():sub(1, #bd_norm) == bd_norm:lower() then
                source_rel_path = art_norm:sub(#bd_norm + 1)
            end
        end
    else
        source_rel_path = source_def.path
        -- Expand variables in source path using source project's context.
        -- ${variant} resolves to the module variant (e.g., CMAKE_BUILD_TYPE = "Debug"),
        -- not the configuration name (e.g., "debug-with-addon").
        -- ${configuration} resolves to the configuration name from the profile mapping.
        local module_variant = source_variant
        if source_unit._configuration and source_unit._configuration.module_config then
            module_variant = source_unit._configuration.module_config.variant or source_variant
        end
        local source_ctx = {
            build_dir = build_dir,
            variant = module_variant,
            configuration = source_variant,
            project_path = source_project.path or source_project.key,
            workspace_root = ws.root,
        }
        if profile._config_set_ref then
            source_ctx.config_set = profile._config_set_ref.name
        end
        local src_unresolved = expand.unresolved_vars(source_rel_path, source_ctx)
        if #src_unresolved > 0 then
            return nil, unresolved_msg("source path '" .. source_rel_path .. "'", src_unresolved)
        end
        source_rel_path = expand.expand_string(source_rel_path, source_ctx)
        -- If expansion produced an absolute path, use it directly
        if source_rel_path:match("^%a:") or source_rel_path:match("^/") then
            -- Strip build_dir prefix if present (user used ${build_dir} redundantly)
            local bd_prefix = build_dir:gsub("\\", "/") .. "/"
            local norm = source_rel_path:gsub("\\", "/")
            if norm:sub(1, #bd_prefix) == bd_prefix then
                source_rel_path = norm:sub(#bd_prefix + 1)
            else
                -- Truly absolute — use as source_path directly, skip build_dir concat
                local source_path = source_rel_path
                local dest_path_final = dest_path
                local is_dir_abs = dest_path_final:sub(-1) == "/"
                if not is_dir_abs then
                    local stat = (vim.uv or vim.loop).fs_stat(dest_path_final)
                    if stat and stat.type == "directory" then is_dir_abs = true end
                end
                if is_dir_abs then
                    if dest_path_final:sub(-1) == "/" then
                        dest_path_final = dest_path_final:sub(1, -2)
                    end
                    local filename = source_rel_path:match("[^/\\]+$")
                    dest_path_final = dest_path_final .. "/" .. filename
                end
                return {
                    source_path = source_path,
                    dest_path = dest_path_final,
                    source_build_dir_id = source_unit.id,
                    source_rel_path = source_rel_path,
                }
            end
        end
    end

    local source_path = build_dir .. "/" .. source_rel_path

    -- If destination ends with / or is an existing directory, append source filename
    local is_dir = dest_path:sub(-1) == "/"
    if not is_dir then
        local stat = (vim.uv or vim.loop).fs_stat(dest_path)
        if stat and stat.type == "directory" then
            is_dir = true
        end
    end
    if is_dir then
        -- Strip trailing / for consistent path joining
        if dest_path:sub(-1) == "/" then
            dest_path = dest_path:sub(1, -2)
        end
        local filename = source_rel_path:match("[^/\\]+$")
        dest_path = dest_path .. "/" .. filename
    end

    -- Source unit id for freshness tracking (spec §8.8.3: the id of the
    -- config unit, which in a shared tree is not just its directory)
    local source_build_dir_id = source_unit.id

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

--- Execute all deploy steps for a launch target. Returns a Future.
--- Resolves all steps first (fail-fast), then copies as needed.
--- Source values can be a single descriptor or an array of descriptors.
---
--- By default the copies are synchronous and `on_complete` runs before this
--- returns. With `opts.async` each copy runs on the event loop and the next
--- step continues through `opts.resume(fn)` (default `vim.schedule`), so a
--- long copy never blocks the caller's loop; `opts.cancelled()` true before a
--- step skips it and every later one (the deploy then fails "cancelled").
--- Only `on_complete` reports an asynchronous deploy (the returned Future is
--- settled already only for a synchronous one).
--- @param deploy_dict table<string, table|table[]> deploy definitions from launch config
--- @param ctx table { workspace, profile, launch_project, on_step? }
---   `on_step(ev)` (optional) hears each step as it is decided, before any
---   copy: `{ action = "copy"|"fresh", source, dest }` — `lw -v` prints it
---   (headless §16.4 *Verbose*).
--- @param deploy_records table<string, table> workspace deploy records (mutated on copy)
--- @param normalize fun(p: string): string path normalizer
--- @param on_complete? fun(ok: boolean, err?: string)
--- @param opts? { async: boolean|nil, cancelled: (fun(): boolean)|nil, resume: (fun(fn: function))|nil }
--- @return loomworks.Future
function M.execute_deploy_steps(deploy_dict, ctx, deploy_records, normalize, on_complete, opts)
    local future_mod = require("loomworks.future")
    opts = opts or {}

    if not deploy_dict or not next(deploy_dict) then
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    -- Phase 1: resolve all steps (expand arrays into individual steps)
    local resolved_steps = {}
    for dest_template, source_val in pairs(deploy_dict) do
        local sources = M.normalize_sources(source_val)
        for _, source_def in ipairs(sources) do
            local resolved, err = M.resolve_deploy_step(dest_template, source_def, ctx)
            if not resolved then
                if on_complete then on_complete(false, "Deploy: " .. err) end
                return future_mod.rejected("Deploy: " .. err)
            end
            resolved_steps[#resolved_steps + 1] = resolved
        end
    end

    -- Phase 2: check freshness and copy, one step after the other.
    local uv = vim.uv or vim.loop
    local errors = {}
    local result
    local resume = opts.resume or vim.schedule

    local function finish()
        if #errors > 0 then
            local err = table.concat(errors, "; ")
            result = future_mod.rejected(err)
            if on_complete then on_complete(false, err) end
            return
        end
        result = future_mod.resolved(true)
        if on_complete then on_complete(true) end
    end

    local function copied(step, source_stat, ok, copy_err)
        if not ok then
            errors[#errors + 1] = "copy failed: " .. step.source_path
                .. " → " .. step.dest_path .. ": " .. tostring(copy_err)
            return
        end
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

    local i = 0
    local function next_step()
        i = i + 1
        local step = resolved_steps[i]
        if not step then return finish() end
        if opts.cancelled and opts.cancelled() then
            errors[#errors + 1] = "cancelled"
            return finish()
        end
        local needs_copy = M.check_freshness(step, deploy_records, normalize)
        if ctx.on_step then
            ctx.on_step({ action = needs_copy and "copy" or "fresh",
                source = step.source_path, dest = step.dest_path })
        end
        if not needs_copy then return next_step() end
        local source_stat = uv.fs_stat(step.source_path)
        if not source_stat then
            errors[#errors + 1] = "source file missing: " .. step.source_path
            return next_step()
        end
        local dest_dir = vim.fn.fnamemodify(step.dest_path, ":h")
        assert(require("loomworks.io").mkdir_p(dest_dir))
        if not opts.async then
            local ok, copy_err = uv.fs_copyfile(step.source_path, step.dest_path)
            copied(step, source_stat, ok, copy_err)
            return next_step()
        end
        uv.fs_copyfile(step.source_path, step.dest_path, nil, function(copy_err, ok)
            resume(function()
                copied(step, source_stat, ok and not copy_err, copy_err)
                return next_step()
            end)
        end)
    end
    next_step()

    return result or future_mod.Future.new()
end

--- Fold backslashes to "/" and drop trailing slashes.
--- @param p string
--- @return string
local function slash(p)
    return (p:gsub("\\", "/"):gsub("/+$", ""))
end

--- Split a "/"-separated path into its non-empty segments.
--- @param p string
--- @return string[]
local function segments(p)
    local out = {}
    for seg in p:gmatch("[^/]+") do out[#out + 1] = seg end
    return out
end

--- Whether `p` has a `.` / `..` segment, or (on Windows) a segment ending
--- in "." or " " that Win32 would silently trim into another name.
--- @param p string
--- @return boolean
local function has_dot_segment(p)
    local win = vim.fn.has("win32") == 1
    for _, seg in ipairs(segments(p)) do
        if seg == "." or seg == ".." then return true end
        if win and seg:match("[%. ]$") then return true end
    end
    return false
end

--- Strictly under: `path` is a descendant of `prefix` (separator-bounded).
local function strictly_under(path, prefix)
    return path:sub(1, #prefix + 1) == prefix .. "/"
end

--- Classify a deploy record's destination for cleanup (spec §8.8.5 step 2).
---   "remove"  — absolute, traversal-free, a regular file (lstat), lexically
---               and canonically strictly under the workspace root, every
---               directory from the root down a real directory (no link or
---               junction on the way): safe to unlink.
---   "outside" — a regular file that is not inside the workspace (or no root
---               is known): never unlinked, left in place and reported.
---   "invalid" — not an absolute, traversal-free path to a regular file
---               (relative, `.`/`..`, a directory, a link, missing): dropped
---               without touching disk.
--- @param dest any record key (from loomworks.cache.json — untrusted)
--- @param root string|nil absolute workspace root
--- @param normalize fun(p: string): string comparison normalizer
--- @return "remove"|"outside"|"invalid"
function M.cleanup_disposition(dest, root, normalize)
    if type(dest) ~= "string" or dest == "" then return "invalid" end
    local p = slash(dest)
    if not (p:match("^/") or p:match("^%a:/")) then return "invalid" end
    if has_dot_segment(p) then return "invalid" end
    local st = uv.fs_lstat(p)
    if not st or st.type ~= "file" then return "invalid" end
    if type(root) ~= "string" or root == "" then return "outside" end

    -- Canonical containment: the file's realpath strictly under the root's.
    local root_real = uv.fs_realpath(root)
    local dest_real = uv.fs_realpath(p)
    if not root_real or not dest_real then return "outside" end
    root_real = normalize(slash(root_real))
    if not strictly_under(normalize(slash(dest_real)), root_real) then
        return "outside"
    end

    -- Lexical containment under the root (as given or canonical), then lstat
    -- every directory from the root down: no link or junction on the way.
    local np = normalize(p)
    local base
    for _, r in ipairs({ normalize(slash(root)), root_real }) do
        if strictly_under(np, r) then base = r; break end
    end
    if not base then return "outside" end
    local segs = segments(np:sub(#base + 2))
    local cur = base
    for i = 1, #segs - 1 do
        cur = cur .. "/" .. segs[i]
        local dst = uv.fs_lstat(cur)
        if not dst or dst.type ~= "directory" then return "outside" end
    end
    return "remove"
end

--- Clean deploy records sourced from a given build directory (spec §8.8.5).
--- Every matching record is dropped. Its destination file is unlinked only
--- when `cleanup_disposition` says "remove"; a destination outside the
--- workspace is left in place and passed to `opts.on_left`, an invalid key
--- to `opts.on_invalid`. With no `opts.root`, nothing is unlinked.
--- @param deploy_records table<string, table> workspace deploy records (mutated)
--- @param build_dir_id string config unit id (spec §8.8.5) to match
--- @param opts? { root?: string, normalize?: fun(p: string): string, on_left?: fun(dest: string), on_invalid?: fun(dest: string) }
--- @return string[] removed_keys list of removed destination keys
function M.clean_deploy_records(deploy_records, build_dir_id, opts)
    opts = opts or {}
    local normalize = opts.normalize or function(p) return p end
    local removed = {}
    for dest_key, record in pairs(deploy_records) do
        if record.source_build_dir == build_dir_id then
            removed[#removed + 1] = dest_key
        end
    end
    for _, key in ipairs(removed) do
        deploy_records[key] = nil
        local disposition = M.cleanup_disposition(key, opts.root, normalize)
        if disposition == "remove" then
            uv.fs_unlink(slash(key))
        elseif disposition == "outside" then
            if opts.on_left then opts.on_left(key) end
        elseif opts.on_invalid then
            opts.on_invalid(key)
        end
    end
    return removed
end

return M
