local M = {}

local io_mod = require("loomworks.io")
local modules = require("loomworks.modules")

--- Live check whether a project type maps to a registered module.
--- Built lazily, NOT cached at file-load: third-party plugins that
--- ship modules (e.g. loomworks-module-ohos's harmony) get added to
--- runtimepath AFTER loomworks.config is required — a snapshot here
--- was stale forever and falsely warned about legitimate project
--- types. `modules.get` caches successful lookups internally so the
--- per-call cost is a single registry-table read after the first hit.
--- @param ptype string
--- @return boolean
local function is_known_type(ptype)
    return modules.get(ptype) ~= nil
end

local NON_TYPE_KEYS = {
    path = true,
    depends_on = true,
    launch = true,
    variables = true,
    deploy = true,  -- project-level deploy (pre-build phase). Missing
                    -- this made config.validate reject any project that
                    -- carried both a module type key AND a deploy dict
                    -- with "multiple type keys" since the validator
                    -- treated `deploy` as another module-type candidate.
}

--- Extract project type from the project definition table.
--- Type is implicit from the inner key: {"cmake": {}} -> type = "cmake"
--- @param project_def table raw JSON project definition
--- @return string|nil type, table|nil type_config, string|nil err
function M._extract_type(project_def)
    local found_type, found_config
    for key, val in pairs(project_def) do
        if not NON_TYPE_KEYS[key] then
            if found_type then
                return nil, nil, "multiple type keys: " .. found_type .. ", " .. key
            end
            found_type = key
            found_config = val
        end
    end
    if not found_type then
        return nil, nil, "no type key found"
    end
    -- Normalize: JSON [] decodes as empty table, treat same as {}
    if type(found_config) ~= "table" then
        found_config = {}
    end
    return found_type, found_config, nil
end

--- Normalize raw project definitions into internal format.
--- Extracts type from the inner key (e.g. { cmake = {} } -> type = "cmake").
--- Does NOT validate path existence on disk.
--- @param raw_projects table<string, table> raw JSON project definitions
--- @return table<string, table>|nil projects, string|nil err
function M.normalize_projects(raw_projects)
    if type(raw_projects) ~= "table" then
        return nil, "projects must be a table"
    end
    local projects = {}
    for key, def in pairs(raw_projects) do
        if type(def) ~= "table" then
            return nil, "project '" .. key .. "' must be a table"
        end
        local ptype, type_config, type_err = M._extract_type(def)
        if not ptype then
            return nil, "project '" .. key .. "': " .. type_err
        end
        if not is_known_type(ptype) then
            vim.notify("loomworks: project '" .. key .. "' has unknown type '" .. ptype .. "'", vim.log.levels.WARN)
        end
        projects[key] = {
            path = def.path or key,
            type = ptype,
            type_config = type_config,
            depends_on = def.depends_on,
            launch = def.launch,
            variables = def.variables,
            deploy = def.deploy,
        }
    end
    return projects, nil
end

--- Validate raw decoded JSON and normalize into a config structure.
--- @param raw table raw decoded JSON
--- @param root string workspace root for resolving paths
--- @return loomworks.Config|nil config, string|nil err
function M.validate(raw, root)
    if type(raw.projects) ~= "table" then
        return nil, "missing or invalid 'projects' field"
    end

    local projects = {}
    for key, def in pairs(raw.projects) do
        if type(def) ~= "table" then
            return nil, "project '" .. key .. "' must be a table"
        end

        local ptype, type_config, type_err = M._extract_type(def)
        if not ptype then
            return nil, "project '" .. key .. "': " .. type_err
        end

        if not is_known_type(ptype) then
            vim.notify("loomworks: project '" .. key .. "' has unknown type '" .. ptype .. "'", vim.log.levels.WARN)
        end

        local project_path = def.path or key
        local abs_path = root .. "/" .. project_path
        local stat = (vim.uv or vim.loop).fs_stat(abs_path)
        if not stat then
            vim.notify("loomworks: project '" .. key .. "' directory not found: " .. abs_path, vim.log.levels.WARN)
        end

        -- Validate deploy definitions on launch configs
        if def.launch then
            local deploy_mod = require("loomworks.deploy")
            for launch_name, launch_def in pairs(def.launch) do
                if type(launch_def) == "table" and launch_def.deploy then
                    local ok, deploy_err = deploy_mod.validate_deploy_definitions(launch_def.deploy)
                    if not ok then
                        return nil, "project '" .. key .. "' launch '"
                            .. launch_name .. "': " .. deploy_err
                    end
                end
            end
        end

        -- Validate project-level deploy definitions (same shape as
        -- launch-level — `pre_build` distinguishes the phase).
        if def.deploy then
            local deploy_mod = require("loomworks.deploy")
            local ok, deploy_err = deploy_mod.validate_deploy_definitions(def.deploy)
            if not ok then
                return nil, "project '" .. key .. "' deploy: " .. deploy_err
            end
        end

        -- User-declared configuration names cannot contain `:` —
        -- that character is reserved as the tier separator for
        -- auto-generated configs (e.g. `variant:Debug`,
        -- `preset:debug-custom`). Collision-proofing the namespace
        -- upfront removes a whole class of "user config shadows the
        -- module's default" confusion that the strict-separation
        -- design is meant to eliminate.
        --
        -- We strip rather than error here. Older versions of the
        -- plugin had a serialization bug that wrote auto-gens
        -- (`auto:...`, `cmake:...`, etc.) into loomworks.json;
        -- failing the load would leave users with a workspace that
        -- can't open at all and needs manual editing. Stripping plus
        -- a one-shot warning lets the workspace load, the next `:w`
        -- cleans the file, and any genuine user-typed `:` is still
        -- caught — just non-fatally.
        if type_config and type_config.configurations then
            local stripped = {}
            for cfg_name in pairs(type_config.configurations) do
                if type(cfg_name) == "string" and cfg_name:find(":", 1, true) then
                    stripped[#stripped + 1] = cfg_name
                end
            end
            if #stripped > 0 then
                for _, name in ipairs(stripped) do
                    type_config.configurations[name] = nil
                end
                vim.notify(
                    "loomworks: project '" .. key
                        .. "' loomworks.json contained reserved-prefix "
                        .. "config names ("
                        .. table.concat(stripped, ", ")
                        .. ") — stripped on load. They were likely "
                        .. "auto-generated entries written by an older "
                        .. "version. Re-publish (`:w`) to clean the file.",
                    vim.log.levels.WARN)
            end
        end

        -- Validate project-level variable declarations
        local project_variables = nil
        if def.variables then
            local vars_mod = require("loomworks.variables")
            local ok, vars_err = vars_mod.validate_declarations(def.variables)
            if not ok then
                return nil, "project '" .. key .. "': " .. vars_err
            end
            project_variables = def.variables

            -- Validate configuration-level variable overrides
            if type_config and type_config.configurations then
                for cfg_name, cfg_def in pairs(type_config.configurations) do
                    if type(cfg_def) == "table" and cfg_def.variables then
                        local cok, cerr = vars_mod.validate_overrides(
                            cfg_def.variables, project_variables)
                        if not cok then
                            return nil, "project '" .. key .. "' configuration '"
                                .. cfg_name .. "': " .. cerr
                        end
                    end
                end
            end
        end

        projects[key] = {
            path = project_path,
            type = ptype,
            type_config = type_config,
            depends_on = def.depends_on,
            launch = def.launch,
            variables = project_variables,
            deploy = def.deploy,
        }
    end

    -- Warn about case-colliding project keys (same build dir on Windows)
    local proj_lower = {}
    for key in pairs(projects) do
        local lk = key:lower()
        if proj_lower[lk] then
            vim.notify(
                "loomworks: project keys '" .. proj_lower[lk] .. "' and '" .. key
                    .. "' differ only by case — may collide on case-insensitive filesystems",
                vim.log.levels.WARN)
        else
            proj_lower[lk] = key
        end
    end

    -- Validate configuration_sets references
    if raw.configuration_sets then
        if type(raw.configuration_sets) ~= "table" then
            return nil, "'configuration_sets' must be a table"
        end
        -- Warn about case-colliding config set names
        local cs_lower = {}
        for set_name in pairs(raw.configuration_sets) do
            local lk = set_name:lower()
            if cs_lower[lk] then
                vim.notify(
                    "loomworks: configuration sets '" .. cs_lower[lk] .. "' and '" .. set_name
                        .. "' differ only by case — may cause profile key collisions",
                    vim.log.levels.WARN)
            else
                cs_lower[lk] = set_name
            end
        end
        for set_name, mappings in pairs(raw.configuration_sets) do
            if type(mappings) == "table" then
                for proj_name, _ in pairs(mappings) do
                    if not projects[proj_name] then
                        vim.notify(
                            "loomworks: configuration_set '" .. set_name .. "' references unknown project '" .. proj_name .. "'",
                            vim.log.levels.WARN
                        )
                    end
                end
            end
        end
    end

    -- Validate profiles
    local profiles = nil
    if raw.profiles then
        if type(raw.profiles) ~= "table" then
            return nil, "'profiles' must be a table"
        end
        profiles = {}
        for profile_name, profile_def in pairs(raw.profiles) do
            if type(profile_def) ~= "table" then
                return nil, "profile '" .. profile_name .. "' must be a table"
            end
            -- Must mirror Profile:to_config_def() — whatever `publish` writes has
            -- to survive the read, or a shared profile comes back as a stub.
            profiles[profile_name] = {
                configuration_set = profile_def.configuration_set,
                tools = profile_def.tools,
                sdk = profile_def.sdk,
                default_target = profile_def.default_target,
                kit_id = profile_def.kit_id,
                -- Legacy support: cmake.kit_id
                cmake = profile_def.cmake,
            }
        end
    end

    return {
        name = raw.name,
        projects = projects,
        configuration_sets = raw.configuration_sets,
        profiles = profiles,
    }, nil
end

--- Parse raw JSON content into a validated Config.
--- @param content string raw JSON content
--- @param root string workspace root for resolving paths
--- @return loomworks.Config|nil config, string|nil err
function M.parse(content, root)
    local ok, raw = pcall(vim.json.decode, content)
    if not ok or type(raw) ~= "table" then
        return nil, "failed to decode JSON"
    end
    return M.validate(raw, root)
end

--- Load and validate loomworks.json from a workspace root.
--- @param root string
--- @return loomworks.Config|nil config, string|nil err, string|nil raw_content
function M.load(root)
    local path = root .. "/loomworks.json"

    -- Read raw content for hashing
    local raw_content = io_mod.read_file(path)

    local raw, read_err = io_mod.read_json(path)
    if not raw then
        return nil, "failed to read loomworks.json: " .. (read_err or "unknown"), nil
    end

    local config, val_err = M.validate(raw, root)
    if not config then
        return nil, path .. ": " .. val_err, nil
    end

    return config, nil, raw_content
end

return M
