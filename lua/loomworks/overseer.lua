local M = {}

--- Resolve a task's program before overseer spawns it (loomworks.exe): cmd[1]
--- becomes an absolute path found in an absolute PATH entry of the task env
--- (else the process PATH) — never the current directory — and on Windows the
--- task env gains `NoDefaultCurrentDirectoryInExePath=1` so a cmd.exe / .bat
--- the task runs does not search its cwd either. Returns the spec, or nil +
--- err: an unresolvable program is reported, never spawned by its bare name.
--- A module's display-only `display_cmd` (§8.1) is dropped here, so it never
--- reaches overseer — every `new_task` spec passes through this.
--- @param spec table
--- @return table|nil spec, string|nil err
local function harden(spec)
    if type(spec) == "table" then spec.display_cmd = nil end
    return require("loomworks.exe").harden_spec(spec)
end
M._harden = harden

--- The command line a task spec runs, for display (headless §16.4): the
--- module's `display_cmd` when it supplied one — the command a wrapper such as
--- a toolchain-environment batch file runs (core §8.1) — else `cmd`, readably
--- quoted (term.format_argv). Control characters are NOT escaped here; the
--- output layer does that (`log_task_command` escapes for the log file).
--- @param spec { cmd?: string[], display_cmd?: string[] }
--- @return string
function M.command_text(spec)
    local argv = (type(spec.display_cmd) == "table" and #spec.display_cmd > 0)
        and spec.display_cmd or spec.cmd
    return require("loomworks.term").format_argv(type(argv) == "table" and argv or {})
end

--- Write a configure / build step's command line and cwd to the workspace log
--- at info level — for every configure and build, from the editor's task path
--- and the headless runner alike (headless §16.4). Never raises.
--- @param ws loomworks.Workspace|nil
--- @param name string|nil task name
--- @param spec { cmd?: string[], display_cmd?: string[], cwd?: string }
--- @param cwd string|nil the directory it runs in (defaults to `spec.cwd`)
function M.log_task_command(ws, name, spec, cwd)
    local log = ws and ws._core and ws._core._deps and ws._core._deps.log
    if not log or type(spec) ~= "table" then return end
    local term = require("loomworks.term")
    pcall(log.info, log, "%s: $ %s  (in %s)", term.escape(name or "?"),
        term.escape(M.command_text(spec)), term.escape(cwd or spec.cwd or "?"))
end

--- Resolve user-declared project variables for the active configuration,
--- honouring compiler-specific `overrides` for the active tool's compiler
--- family (core §1.3.1). Returns nil when the project has no variable
--- declarations so module contexts stay lean. The Configuration object is the
--- inheritance root — pass nil to get project-default values only.
--- The active `profile` supplies fill values for variables left blank by the
--- config chain (core §1.3.1); a blank a build reaches here would already have
--- been refused by the build gate (`Profile:assert_buildable`), so entries
--- with no value are dropped rather than passed to the module as `nil`.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil active tool_data — its compiler family selects overrides
--- @param profile loomworks.Profile|nil active profile supplying blank-fill values
--- @return table<string, { value: string, type: string }>|nil
local function resolve_project_variables(project, configuration, tool_data, profile)
    if not project or not project.variables or not next(project.variables) then
        return nil
    end
    local family = require("loomworks.cpp_compilers").family_from_tool_data(tool_data)
    local variables = require("loomworks.variables")
    local resolved = variables.resolve(project, configuration, family, profile)
    if not next(resolved) then return nil end
    -- Drop the source_config reference: modules shouldn't depend on
    -- Configuration object identity, and the value is what's load-bearing
    -- for command expansion. A blank (nil value) entry is omitted.
    local out = {}
    for name, entry in pairs(resolved) do
        if entry.value ~= nil then
            out[name] = { value = entry.value, type = entry.type }
        end
    end
    if not next(out) then return nil end
    return out
end

--- Resolve the compiler-cache launcher for a build context (core §1.3.2, §8.1).
--- Core owns this resolution: it derives a concrete launcher from the effective
--- `cache` policy and the tool's compiler family, PATH-gated. Returns the
--- `{ tool, path }` a module applies, or nil (policy `off`, `auto` on an
--- MSVC-style compiler, or the launcher not found). Applicability (a preset, a
--- VS/Xcode generator) is the module's call, not reflected here.
--- Single-sourced so every context-assembly site sets `compiler_cache`
--- identically — the module owns application, core owns resolution.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil active tool_data (yields the compiler family)
--- @param profile loomworks.Profile|nil active profile (machine-local fill)
--- @return { tool: string, path: string }|nil
local function resolve_compiler_cache(project, configuration, tool_data, profile)
    return require("loomworks.compiler_cache").resolve_for(
        project, configuration, tool_data, profile)
end

--- Resolve the configuration environment (spec §1.3.3) for a build context and
--- the composed task environment: the tool's `env` with the configuration's
--- resolved `env` layered on top. Single-sourced so every context-assembly site
--- (configure/build/clean, per-unit and per-profile) sets `env` and
--- `configuration_env` identically. The compiler family (for
--- `overrides.<family>.env`) comes from the tool, like variable resolution.
--- @param project loomworks.Project|nil
--- @param configuration loomworks.Configuration|nil
--- @param tool_data table|nil active tool_data
--- @param profile loomworks.Profile|nil active profile (blank-variable fill)
--- @param root string|nil workspace root
--- @return table<string, string> task_env, table<string, string> configuration_env
local function resolve_task_env(project, configuration, tool_data, profile, root)
    local config_env = require("loomworks.config_env")
    local family = require("loomworks.cpp_compilers").family_from_tool_data(tool_data)
    local cenv = config_env.resolve(project, configuration, family, profile, root)
    return config_env.compose(tool_data and tool_data.env, cenv), cenv
end
M._resolve_task_env = resolve_task_env  -- exported for target.lua / tests

--- Build the configuration map a module's task generator (`mod.tasks`) sees.
--- Merges the module's regular configurations with its preset configurations,
--- which arrive under a separate `preset_configurations` key but are keyed by
--- the same canonical `preset:<name>` that `unit:variant()` resolves to for a
--- mapped preset. Without this merge, `config_info` is nil for a preset and the
--- module can't take its `--preset` path. Generic and module-agnostic:
--- `preset_configurations` is nil for modules that have none (meson/shell/ts),
--- so the second loop is a no-op there. Presets and regular configs occupy
--- disjoint key spaces, so a plain union is correct — neither clobbers the other.
--- @param mod_info loomworks.ModuleInfo
--- @return table<string, loomworks.ConfigurationInfo>
local function task_configurations(mod_info)
    local configs = {}
    for k, v in pairs(mod_info.configurations or {}) do configs[k] = v end
    for k, v in pairs(mod_info.preset_configurations or {}) do configs[k] = v end
    return configs
end
M._task_configurations = task_configurations  -- exported for tests

--- The tool data a unit's tasks RUN with (spec §17.7): the detected data for
--- its tool key. A keyed tool known only from the cache yields nil + reason —
--- cached tool data is a record, never a source of executable paths.
--- @param unit loomworks.ConfigUnit
--- @return table|nil tool_data, string|nil err
local function exec_tool_data(unit)
    local tool = unit._tool
    local key = (tool and tool.key) or unit:tool_key()
    if key == nil then return (tool and tool.data) or unit:tool_data() end
    if tool and tool._detected ~= false then return tool.data end
    return nil, "toolchain '" .. key .. "' is not detected on this machine — rescan tools "
        .. "(cached tool data is never used to run programs)"
end
M._exec_tool_data = function(unit) return (exec_tool_data(unit)) end

--- Refuse a task collection whose tool is not detected (notify once per call).
local function refuse_undetected(err)
    vim.notify("loomworks: " .. err, vim.log.levels.ERROR)
    return nil
end

--- A build command with the parallel-jobs option (the editor's serial `-j1`
--- build; `Build/1.build` `jobs`, spec §19.15) appended: `-- -j<jobs>`, the
--- build tool's own option after the driver's — or, when `cmd` already has a
--- `--`, `-j<jobs>` right after it. Changes `cmd` in place.
--- @param cmd string[]
--- @param jobs integer|string
--- @return string[] cmd
function M.append_parallel_jobs(cmd, jobs)
    -- A command already passing the build tool's options (`--`, e.g. from
    -- forwarded args): `-j<jobs>` goes right after that `--`, not a second one.
    for i, v in ipairs(cmd) do
        if v == "--" then
            table.insert(cmd, i + 1, "-j" .. tostring(jobs))
            return cmd
        end
    end
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = "-j" .. tostring(jobs)
    return cmd
end

--- Collect task definitions for a single project configuration, grouped by action.
--- @param unit loomworks.ConfigUnit
--- @param opts? { profile?: loomworks.Profile, force_full_reconfigure?: boolean, build_args?: string[], build_targets?: string[] }
---   profile is the profile to resolve against (default: the active one); the
---   rest is the caller's request forwarded to the module context (§8.1), as
---   for a profile (collect_profile_tasks); the editor's unit actions pass none
--- @return table|nil task_defs_by_action { configure = {...}, build = {...} }
local function collect_configuration_tasks(unit, opts)
    opts = opts or {}
    local modules = require("loomworks.modules")

    local project = unit._project
    if not project then return nil end

    local ws = unit._workspace
    if not ws then return nil end
    local profile = opts.profile or ws._active_profile

    local mod = project._module and project._module.impl or nil
    if not mod or not mod.tasks then return nil end

    local variant = unit:variant()
    local tool = unit._tool
    local tool_data, terr = exec_tool_data(unit)
    if terr then return refuse_undetected(terr) end

    -- Get module info (reconstruct type_config with configurations for module)
    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local tc_for_module = project:_type_config_for_module()
    local mod_info = { configurations = {} }
    if mod.info then
        local ok, result = pcall(mod.info, abs_path, tc_for_module)
        if ok and result then
            mod_info = result
        end
    end

    local task_env, configuration_env = resolve_task_env(
        project, unit._configuration, tool_data, profile, ws.root)
    local project_ctx = {
        name = project.key,
        path = project.path or project.key,
        type = project.type,
        configuration = variant,
        configuration_key = unit:config_key(),
        configurations = task_configurations(mod_info),
        type_config = tc_for_module,
        tool_data = tool_data,
        workspace_root = ws.root,
        env = task_env,
        configuration_env = configuration_env,
        cached_build_dir = unit:build_dir(),
        resolved_variables = resolve_project_variables(project, unit._configuration, tool_data, profile),
        compiler_cache = resolve_compiler_cache(project, unit._configuration, tool_data, profile),
        recorded_cache_launcher = unit.module_info and unit.module_info.cache_launcher or nil,
        recorded_module_info = unit.module_info,
        recorded_options = unit._cached_options,
        force_full_reconfigure = opts.force_full_reconfigure or nil,
        build_args = opts.build_args,
        build_targets = opts.build_targets,
    }

    local pt = mod.progress_parser
            and mod.progress_parser(project_ctx, variant)
            or nil

    local ok_tasks, mod_tasks = pcall(mod.tasks, project_ctx, variant)
    if not ok_tasks or not mod_tasks then
        vim.notify("loomworks: module '" .. project.type .. "' tasks() failed: " .. tostring(mod_tasks),
            vim.log.levels.ERROR)
        return nil, nil
    end
    local by_action = { configure = {}, build = {} }

    local tool_ref = tool and tool:to_ref() or (unit:tool_key() and {
        key = unit:tool_key(), data = unit:tool_data(),
    }) or nil

    for _, task_def in ipairs(mod_tasks) do
        local lw_meta = task_def.loomworks
        if lw_meta then
            lw_meta.unit = unit
            -- The profile this context resolved against (its blank-variable
            -- and `cache` fills): the active one for a unit-scoped action,
            -- the requested one for a daemon launch's unit build.
            -- The build gate and the post-configure record use the same one
            -- (core §5.1).
            lw_meta.profile = profile
            lw_meta.progress_tool = pt
            lw_meta.variant = variant
            lw_meta.tool = tool_ref
            if by_action[lw_meta.action] then
                by_action[lw_meta.action][#by_action[lw_meta.action] + 1] = task_def
            end
        end
    end

    return by_action
end

--- The result line of a ProfileProject a profile-level operation does not run
--- (core §5.4 "Invalid ProfileProjects"): `<project>/<configuration> not run:
--- <reason> — <remedy>`.
--- @param pp loomworks.ProfileProject
--- @param reason string the invalid reason (ProfileProject:invalid_reason)
--- @param remedy? string appended after " — " when given
--- @return string
function M.refusal_line(pp, reason, remedy)
    local pk = pp._project and pp._project.key or "?"
    local cn = pp.variant_name and pp:variant_name() or "?"
    return pk .. "/" .. tostring(cn) .. " not run: " .. reason
        .. (remedy and (" — " .. remedy) or "")
end

--- The result line of `pp` when a profile-level operation does not run it
--- (core §5.4 "Invalid ProfileProjects"): `refusal_line` of
--- `ProfileProject:invalid_reason()`, the one validity check of every
--- profile-level gate; nil when `pp` is valid.
--- @param pp loomworks.ProfileProject
--- @return loomworks.RefusalLine|nil
function M.pp_refusal(pp)
    if not pp.invalid_reason then return nil end
    local reason, remedy = pp:invalid_reason()
    if not reason then return nil end
    return M.refusal_line(pp, reason, remedy)
end

--- The result line of a ProfileProject a profile-level operation did not run
--- (core §5.4 "Invalid ProfileProjects"; `refusal_line`): the project, its
--- configuration, the reason and the remedy. The host reports these after the
--- other projects ran (`refused_message`) and fails the operation.
--- @alias loomworks.RefusalLine string

--- The failure of a profile-level operation whose invalid ProfileProjects
--- were not run (core §5.4 "Invalid ProfileProjects"): their result lines,
--- one per line. Reported after the other projects ran. (Here, beside
--- `refusal_line`, so both hosts' callers reach it without a plugin→binary
--- require; build_run.refused_message is this.)
--- @param refused loomworks.RefusalLine[]
--- @return string
function M.refused_message(refused)
    return table.concat(refused, "\n")
end

--- The task definitions of a profile-level operation, grouped by action
--- (`collect_profile_tasks`).
--- @class loomworks.ProfileTaskDefs
--- @field configure table[] the configure task definitions
--- @field build table[] the build task definitions
--- @field refused loomworks.RefusalLine[] the ProfileProjects left out as invalid
---   for the action (empty when every one is valid)

--- Collect task definitions for a profile, grouped by action.
--- Does not change the active profile. Uses registered ProfileProject and
--- Project objects instead of recomputing from scratch.
--- @param profile loomworks.Profile
--- @param opts? { force_full_reconfigure?: boolean, build_args?: string[], build_targets?: string[], build_targets_for?: table<loomworks.Project, string[]> }
---   forwarded to the module context (§8.1): force_full_reconfigure makes every
---   configure take the module's full path; build_args / build_targets are the
---   caller's build request for the build tasks (headless `lw build`, §16.4);
---   build_targets_for (the resolved `--target` operands) replaces
---   build_targets per project and skips every project it does not name
--- A ProfileProject invalid for the action (`ProfileProject:invalid_reason`:
--- a module `error`, §8 `info`; a refused build directory, §1.7; a tool
--- compat error, §8.4 `validate_config_tool`) is not run (core §5.4 "Invalid ProfileProjects"):
--- its tasks are left out and `refused` names it with its reason, so the
--- caller fails the operation after the other projects ran.
--- @return loomworks.ProfileTaskDefs|nil task_defs_by_action
local function collect_profile_tasks(profile, opts)
    opts = opts or {}
    local modules = require("loomworks.modules")

    local ws = profile._workspace
    if not ws then return nil end

    local pps = profile:projects()
    if #pps == 0 then return nil end

    local by_action = { configure = {}, build = {}, refused = {} }

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end

        -- A resolved `--target` request (§16.4) builds only the projects it
        -- selected, each with its own bare target names.
        if opts.build_targets_for and not opts.build_targets_for[project] then goto continue end

        do
            local refusal = M.pp_refusal(pp)
            if refusal then
                by_action.refused[#by_action.refused + 1] = refusal
                goto continue
            end
        end

        local mod = project._module and project._module.impl or nil
        if not mod or not mod.tasks then goto continue end

        local active_config = pp:variant_name()
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        -- Detected tool data only (spec §17.7): a cache-only tool runs nothing.
        if project_tool and project_tool.detected == false then
            return refuse_undetected("toolchain '" .. tostring(project_tool.key)
                .. "' is not detected on this machine — rescan tools "
                .. "(cached tool data is never used to run programs)")
        end
        local tool_data = project_tool and project_tool.data or nil
        local task_env, configuration_env = resolve_task_env(
            project, pp._configuration, tool_data, profile, ws.root)
        -- No configure record, but the build dir already holds configure
        -- state (§5.1): the module takes its full reconfigure.
        local orphan_state = pp._config_unit
            and pp._config_unit:has_orphan_configure_state(pp:build_dir()) or false
        local project_ctx = {
            name = project.key,
            path = project.path or project.key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp:config_key(),
            configurations = project.configurations,
            type_config = project:_type_config_for_module(),
            tool_data = tool_data,
            workspace_root = ws.root,
            env = task_env,
            configuration_env = configuration_env,
            cached_build_dir = pp:build_dir(),
            resolved_variables = resolve_project_variables(project, pp._configuration, tool_data, profile),
            compiler_cache = resolve_compiler_cache(project, pp._configuration, tool_data, profile),
            recorded_cache_launcher = pp._config_unit and pp._config_unit.module_info
                and pp._config_unit.module_info.cache_launcher or nil,
            recorded_module_info = pp._config_unit and pp._config_unit.module_info or nil,
            recorded_options = pp._config_unit and pp._config_unit._cached_options or nil,
            force_full_reconfigure = (opts.force_full_reconfigure or orphan_state) or nil,
            build_args = opts.build_args,
            build_targets = opts.build_targets_for and opts.build_targets_for[project] or opts.build_targets,
        }

        local pt = mod.progress_parser
                and mod.progress_parser(project_ctx, active_config)
                or nil

        local ok_t, mod_tasks = pcall(mod.tasks, project_ctx, active_config)
        if not ok_t or not mod_tasks then
            vim.notify("loomworks: module '" .. (project.type or "?") .. "' tasks() failed: " .. tostring(mod_tasks),
                vim.log.levels.ERROR)
            goto continue
        end
        for _, task_def in ipairs(mod_tasks) do
            local lw_meta = task_def.loomworks
            if lw_meta then
                lw_meta.unit = pp._config_unit
                -- The profile being built: its fills resolved this context,
                -- so the build gate's staleness check and the post-configure
                -- record resolve against it too (core §5.1), never against
                -- whichever profile happens to be active.
                lw_meta.profile = profile
                lw_meta.progress_tool = pt
                lw_meta.variant = active_config
                lw_meta.tool = project_tool
                lw_meta.configure_state_orphan = orphan_state or nil
                if by_action[lw_meta.action] then
                    by_action[lw_meta.action][#by_action[lw_meta.action] + 1] = task_def
                end
            end
        end

        ::continue::
    end

    return by_action
end

--- Collect clean task definitions for a single configuration.
--- @param unit loomworks.ConfigUnit
--- @return table[]|nil clean_tasks, string|nil undetected the refusal of an undetected tool
local function collect_configuration_clean_tasks(unit)
    local modules = require("loomworks.modules")

    local project = unit._project
    if not project then return nil end

    local ws = unit._workspace
    if not ws then return nil end

    local mod = project._module and project._module.impl or nil
    if not mod or not mod.clean_tasks then return nil end

    local variant = unit:variant()
    local tool_data, terr = exec_tool_data(unit)
    if terr then return refuse_undetected(terr), terr end

    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local mod_info = mod.info and mod.info(abs_path, project.type_config)
            or { configurations = {} }

    local task_env, configuration_env = resolve_task_env(
        project, unit._configuration, tool_data, ws._active_profile, ws.root)
    local project_ctx = {
        name = project.key,
        path = project.path or project.key,
        type = project.type,
        configuration = variant,
        configuration_key = unit:config_key(),
        configurations = task_configurations(mod_info),
        tool_data = tool_data,
        type_config = project.type_config,
        workspace_root = ws.root,
        env = task_env,
        configuration_env = configuration_env,
        cached_build_dir = unit:build_dir(),
        resolved_variables = resolve_project_variables(project, unit._configuration, tool_data, ws._active_profile),
        compiler_cache = resolve_compiler_cache(project, unit._configuration, tool_data, ws._active_profile),
    }

    local clean = mod.clean_tasks(project_ctx, variant)
    -- A wipe deletes this unit's build dir: the runner needs the unit for
    -- crash safety and shared-dir protection (spec §4.6, §4.7).
    for _, task_def in ipairs(clean or {}) do
        if task_def.loomworks and task_def.loomworks.wipe_build_dir
                and task_def.loomworks.unit == nil then
            task_def.loomworks.unit = unit
        end
    end
    return clean
end

--- Collect clean task definitions for all projects in a profile.
--- An invalid ProfileProject (`ProfileProject:invalid_reason`: a module
--- `error`, §8 `info`; a refused build directory, §1.7; a tool compat error,
--- §8.4 `validate_config_tool`) is not cleaned (core §5.4 "Invalid
--- ProfileProjects"): it is left out and named in `refused`.
--- @param profile loomworks.Profile
--- @return table[]|nil clean_tasks
--- @return loomworks.RefusalLine[]|nil refused nil when none
local function collect_profile_clean_tasks(profile)
    local modules = require("loomworks.modules")

    local ws = profile._workspace
    if not ws then return nil end

    local pps = profile:projects()
    if #pps == 0 then return nil end

    local tasks, refused = {}, {}

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end

        do
            local refusal = M.pp_refusal(pp)
            if refusal then
                refused[#refused + 1] = refusal
                goto continue
            end
        end

        local mod = project._module and project._module.impl or nil
        if not mod or not mod.clean_tasks then goto continue end

        local active_config = pp:variant_name()
        if not active_config then goto continue end

        local project_tool = profile:tool_for(project.type)
        -- Detected tool data only (spec §17.7): a cache-only tool runs nothing.
        if project_tool and project_tool.detected == false then
            return refuse_undetected("toolchain '" .. tostring(project_tool.key)
                .. "' is not detected on this machine — rescan tools "
                .. "(cached tool data is never used to run programs)")
        end
        local tool_data = project_tool and project_tool.data or nil
        local task_env, configuration_env = resolve_task_env(
            project, pp._configuration, tool_data, profile, ws.root)
        local project_ctx = {
            name = project.key,
            path = project.path or project.key,
            type = project.type,
            configuration = active_config,
            configuration_key = pp:config_key(),
            configurations = project.configurations,
            tool_data = tool_data,
            type_config = project.type_config,
            workspace_root = ws.root,
            env = task_env,
            configuration_env = configuration_env,
            cached_build_dir = pp:build_dir(),
            resolved_variables = resolve_project_variables(project, pp._configuration, tool_data, profile),
            compiler_cache = resolve_compiler_cache(project, pp._configuration, tool_data, profile),
        }

        local clean = mod.clean_tasks(project_ctx, active_config)
        if clean then
            for _, task_def in ipairs(clean) do
                -- The unit the task cleans. A wipe is a build-directory
                -- deletion of this unit's dir: the runner needs the unit for
                -- crash safety and shared-dir protection (spec §4.6). A module
                -- clean's headless runner needs it to record the clean (the
                -- unit back to `configured`, spec §3, §16.1).
                task_def.loomworks = task_def.loomworks or {}
                if task_def.loomworks.unit == nil then
                    task_def.loomworks.unit = pp._config_unit
                end
                tasks[#tasks + 1] = task_def
            end
        end

        ::continue::
    end

    -- A refused ProfileProject's build directory is kept (core §5.4: it is
    -- not cleaned): a core-performed wipe of a valid one's dir is dropped
    -- when that dir is the refused one's — the same config unit (projects
    -- sharing one build dir share it) or the same directory identity. (A
    -- distinct unit merely referencing the dir is kept by the deletion's
    -- shared-dir check, spec §4.6.)
    if #refused > 0 and #tasks > 0 then
        local function ident(p)
            if type(p) ~= "string" or p == "" then return nil end
            return ws._build_dir_identity and ws:_build_dir_identity(p) or p
        end
        local refused_units, refused_dirs = {}, {}
        for _, pp in ipairs(pps) do
            local unit = pp._config_unit
            if unit and M.pp_refusal(pp) then
                refused_units[unit] = true
                local id = ident(unit:build_dir())
                if id then refused_dirs[id] = true end
            end
        end
        local kept = {}
        for _, td in ipairs(tasks) do
            local lw = td.loomworks
            local id = lw and lw.wipe_build_dir and ident(lw.build_dir) or nil
            if not (lw and lw.wipe_build_dir and (refused_units[lw.unit] or (id and refused_dirs[id]))) then
                kept[#kept + 1] = td
            end
        end
        tasks = kept
    end

    return #tasks > 0 and tasks or nil, #refused > 0 and refused or nil
end

--- Filter configure tasks to only those whose ConfigUnit needs configuring.
--- Includes units that are unconfigured, configure_failed, or stale
--- (configuration options changed since last configure), or whose build
--- directory was removed out of band (spec §3.1 rule 7) — the load/remerge
--- resets a vanished unit, and this is the re-check for a directory that
--- disappears between remerge and build.
--- Each selected task's `loomworks.configure_reason` is set to the unit's
--- `configure_reason()` (why it configures, §16.4). With `forced` every
--- configure task is selected (a forced full reconfigure, `lw build
--- --reconfigure`).
--- @param all_tasks table { configure: table[], build: table[] }
--- @param forced? boolean
--- @return table[] configure tasks that actually need running
local function filter_unconfigured_tasks(all_tasks, forced)
    local needs_configure = {}
    for _, task_def in ipairs(all_tasks.configure) do
        local lw_meta = task_def.loomworks
        if not lw_meta then goto next end

        local reason = lw_meta.unit:configure_reason(forced, lw_meta.profile,
            lw_meta.configure_state_orphan)
        if reason then
            lw_meta.configure_reason = reason
            needs_configure[#needs_configure + 1] = task_def
        end

        ::next::
    end

    return needs_configure
end
M._filter_unconfigured_tasks = filter_unconfigured_tasks

--- The one-line "why this configure runs" report (headless §16.4, core
--- §8.1 `reconfigure`): the gate's reason plus the module's classification,
--- e.g. `configure: first configure`, `full reconfigure (--fresh): configure
--- record from an older lw`, `reconfigure (in place): compiler launcher
--- changed`. `meta` is a configure task's `loomworks` table or a plan step
--- (same field names). nil when no reason was recorded.
--- @param meta table { configure_reason?, reconfigure?, reconfigure_detail? }
--- @return string|nil
function M.configure_reason_line(meta)
    local reason = meta and meta.configure_reason
    if not reason then return nil end
    local kind = meta.reconfigure
    if reason == "first configure" or reason == "build directory missing"
            or kind == nil or kind == "initial" then
        return "configure: " .. reason
    elseif kind == "full" then
        local how = meta.reconfigure_detail
        return "full reconfigure" .. (how and (" (" .. how .. ")") or "") .. ": " .. reason
    end
    return "reconfigure (in place): " .. reason
end

--- Whether a unit's tests build themselves when run headlessly — true iff the
--- unit has at least one native batch runner and every such runner reports
--- `run_command_all_rebuilds()`. When true, a headless test run can skip its
--- separate build of the unit as redundant. Runners without a native batch
--- command (no `run_command_all`) don't run headlessly and so don't count
--- toward "self-rebuilding". Asked through `batch_runner_test_units()`, not the
--- discovery-gated `test_units()`: the plan is made before configure runs, so
--- on a fresh clone the unit is not yet configured here (spec §17.8).
--- @param unit loomworks.ConfigUnit
--- @return boolean
function M._unit_tests_self_rebuild(unit)
    if not unit then return false end
    local list_fn = unit.batch_runner_test_units or unit.test_units
    if type(list_fn) ~= "function" then return false end
    local ok, tus = pcall(list_fn, unit)
    if not ok or type(tus) ~= "table" or #tus == 0 then return false end
    local any_runner = false
    for _, tu in ipairs(tus) do
        if tu.run_command_all then
            any_runner = true
            if not (tu.run_command_all_rebuilds and tu:run_command_all_rebuilds()) then
                return false
            end
        end
    end
    return any_runner
end

--- The ordered steps of collected configure and build task definitions: each
--- task's builder run now (a builder that raises refuses the plan), every step
--- a ready-to-spawn `{cmd, cwd, env}` with its loomworks metadata.
--- @param configure_tasks table[]
--- @param build_tasks table[]
--- @return table[] steps, string|nil err
local function plan_steps(configure_tasks, build_tasks)
    local steps = {}
    -- A builder that raises (e.g. a refused unsafe vcvarsall / npm argument)
    -- must fail the plan, not silently drop the step (the build would then
    -- report success without having run it).
    local plan_err
    local function add(task_defs, kind)
        for _, td in ipairs(task_defs or {}) do
            if td.builder then
                local ok, spec = pcall(td.builder)
                if not ok and not plan_err then
                    plan_err = (td.name or kind) .. ": " .. tostring(spec)
                end
                if ok and type(spec) == "table" and type(spec.cmd) == "table" then
                    steps[#steps + 1] = {
                        kind = kind,
                        name = td.name,
                        unit = td.loomworks and td.loomworks.unit or nil,
                        -- The profile being built (core §5.1): the headless
                        -- runner records the configure against it.
                        profile = td.loomworks and td.loomworks.profile or nil,
                        build_dir = td.loomworks and td.loomworks.build_dir or nil,
                        -- Module record that replaces the unit's record after a configure
                        -- (cache_launcher, passed_options, …) and the
                        -- full-reconfigure reset list (core §5.1 / §8.1); the
                        -- headless runner records / performs them like the
                        -- editor's task path does.
                        module_info = td.loomworks and td.loomworks.module_info or nil,
                        pre_configure_reset = td.loomworks and td.loomworks.pre_configure_reset or nil,
                        -- Why this configure runs + how the module runs it
                        -- (the one-line report, §16.4).
                        configure_reason = td.loomworks and td.loomworks.configure_reason or nil,
                        reconfigure = td.loomworks and td.loomworks.reconfigure or nil,
                        reconfigure_detail = td.loomworks and td.loomworks.reconfigure_detail or nil,
                        -- Whether the module put the caller's build request
                        -- on its native command (§8.1); the headless runner
                        -- falls back / refuses otherwise.
                        applied_build_args = td.loomworks and td.loomworks.applied_build_args or nil,
                        applied_build_targets = td.loomworks and td.loomworks.applied_build_targets or nil,
                        -- The module's progress parser name (`[N/M]` lines,
                        -- `loomworks.progress`): the daemon runner's percent
                        -- within the step, as the editor's task path does.
                        progress_tool = td.loomworks and td.loomworks.progress_tool or nil,
                        cmd = spec.cmd,
                        -- The command a wrapper runs, for display (§8.1).
                        display_cmd = spec.display_cmd,
                        cwd = (type(spec.cwd) == "string" and spec.cwd ~= "")
                            and spec.cwd or nil,
                        env = spec.env,
                    }
                end
            end
        end
    end
    add(configure_tasks, "configure")
    add(build_tasks, "build")
    return steps, plan_err
end

--- The configure tasks a plan runs: with `configure_only` (an explicit
--- configure, `Build/1.configure`, spec §19.15) every one — also a unit
--- already configured, its `configure_reason` set when it has one — else the
--- units that need it (filter_unconfigured_tasks).
--- @param all_tasks table { configure: table[], build: table[] }
--- @param opts table { configure_only?: boolean, reconfigure?: boolean }
--- @return table[]
local function planned_configures(all_tasks, opts)
    if not opts.configure_only then return filter_unconfigured_tasks(all_tasks, opts.reconfigure) end
    for _, td in ipairs(all_tasks.configure or {}) do
        local lw_meta = td.loomworks
        if lw_meta and lw_meta.unit then
            lw_meta.configure_reason = lw_meta.unit:configure_reason(opts.reconfigure, lw_meta.profile,
                lw_meta.configure_state_orphan)
        end
    end
    return all_tasks.configure or {}
end

--- Build an ordered, overseer-free execution plan for a profile "build".
--- Sequencing: configure the units that
--- need it (unconfigured / failed / stale), then build. Each step carries a
--- ready-to-spawn `{cmd, cwd, env}`. Intended for headless runners — it
--- requires no overseer.nvim and launches nothing.
--- @param profile loomworks.Profile
--- @param opts? table { tasks?: table, for_test?: boolean|table, configure_only?: boolean, reconfigure?: boolean, build_args?: string[], build_targets?: string[], build_targets_for?: table }
---   for_test drops the build step of any unit whose native test runner
---   self-rebuilds — configuration is still planned for every unit; as a
---   table `{ keep = { [unit] = true } }` it also keeps the build of the
---   listed units (a unit with saved test executables in the plan, §16.16);
---   configure_only plans the configure step of every unit and no build
---   (`Build/1.configure`, §19.15); reconfigure forces a FULL reconfigure of
---   every unit (`lw build --reconfigure`, §16.4);
---   build_args / build_targets go to each module's build task context (§8.1),
---   and each build step reports whether its module applied them
---   (`applied_build_args` / `applied_build_targets`).
---   tasks (the task definitions of a unit-scoped plan, plan_unit_build) skips
---   collect_profile_tasks and plans those directly, shaped the same way.
--- @return table[]|nil steps list of { kind, name, unit, profile, build_dir, module_info, pre_configure_reset, configure_reason, reconfigure, reconfigure_detail, applied_build_args, applied_build_targets, cmd, cwd, env }
--- @return string|nil err a task builder that raised (the plan is refused, not partial)
--- @return loomworks.RefusalLine[]|nil refused the ProfileProjects left out as
---   invalid for the action (core §5.4 "Invalid ProfileProjects"), nil when
---   none: the caller runs the steps, then fails the operation with them
function M.plan_profile_build(profile, opts)
    opts = opts or {}
    local all_tasks = opts.tasks or collect_profile_tasks(profile, {
        force_full_reconfigure = opts.reconfigure or nil,
        build_args = opts.build_args,
        build_targets = opts.build_targets,
        build_targets_for = opts.build_targets_for,
    })
    if not all_tasks then return nil end
    local needs_configure = planned_configures(all_tasks, opts)

    local build_tasks = all_tasks.build
    if opts.configure_only then
        build_tasks = {}
    elseif opts.for_test then
        local keep = type(opts.for_test) == "table" and opts.for_test.keep or {}
        build_tasks = {}
        for _, td in ipairs(all_tasks.build or {}) do
            local unit = td.loomworks and td.loomworks.unit
            if (unit and keep[unit]) or not (unit and M._unit_tests_self_rebuild(unit)) then
                build_tasks[#build_tasks + 1] = td
            end
        end
    end

    local steps, plan_err = plan_steps(needs_configure, build_tasks)
    if plan_err then return nil, plan_err end
    local refused = all_tasks.refused
    return steps, nil, (refused and #refused > 0) and refused or nil
end

--- The plan of `plan_profile_build` for configuration units instead of a
--- profile (`Build/1` `units`, spec §19.15): each unit's tasks collected as
--- collect_configuration_tasks collects them (the tool its unit records,
--- the active profile's context), then the configures
--- of every unit before the builds, in the order given.
--- @param units loomworks.ConfigUnit[]
--- @param opts? table { configure_only?: boolean, reconfigure?: boolean, build_args?: string[], build_targets_for?: table<loomworks.Project, string[]> }
---   as for plan_profile_build; build_targets_for (the resolved targets)
---   skips every unit whose project it does not name
--- @return table[]|nil steps, string|nil err
function M.plan_units_build(units, opts)
    opts = opts or {}
    local all_tasks = { configure = {}, build = {} }
    for _, unit in ipairs(units) do
        local project = unit._project
        if not (opts.build_targets_for and not (project and opts.build_targets_for[project])) then
            local by_action = collect_configuration_tasks(unit, {
                force_full_reconfigure = opts.reconfigure or nil,
                build_args = opts.build_args,
                build_targets = opts.build_targets_for and opts.build_targets_for[project] or nil,
            })
            -- No module, no tasks or an undetected tool: refused, never an
            -- empty plan ("nothing to configure" is only a module with no
            -- configure step), as the editor's unit configure refuses.
            if not by_action then
                return nil, (project and project.key or "?") .. "/" .. tostring(unit:config_key())
                    .. ": no tasks (unavailable module or undetected tool)"
            end
            vim.list_extend(all_tasks.configure, by_action.configure or {})
            vim.list_extend(all_tasks.build, by_action.build or {})
        end
    end
    local needs_configure = planned_configures(all_tasks, opts)
    local steps, plan_err = plan_steps(needs_configure, opts.configure_only and {} or all_tasks.build)
    if plan_err then return nil, plan_err end
    return steps
end

--- Plan the build of ONE configuration unit as a launch builds it in-process
--- (spec §8.8.4 steps 3 and 5, LaunchTarget:build; §19.15 "Build scope of a
--- launch"), overseer-free, its steps shaped as plan_profile_build's: with
--- `opts.target_id` and a module that builds a single target
--- (`build_target_task`), that target's one build step, as Target:build runs
--- it; otherwise the unit's configure when it needs one, then its build, as
--- a unit build runs them. The tool/configuration compatibility gate
--- refuses first. The steps resolve against
--- `opts.profile` (the launch's requested profile; default the active one) —
--- its environment, variables and build gate — and a single-target build
--- builds the unit's own build directory (the one the caller locked).
--- @param ws loomworks.Workspace the unit's workspace
--- @param unit loomworks.ConfigUnit
--- @param opts? { target_id?: string, profile?: loomworks.Profile }
--- @return table[]|nil steps, string|nil err
function M.plan_unit_build(ws, unit, opts)
    opts = opts or {}
    local compat_err = unit.tool_compat_error and unit:tool_compat_error() or nil
    if compat_err then
        return nil, compat_err .. " — change the profile's tool to match the configuration"
    end
    local project = unit._project
    if not project then return nil, "no project for this configuration" end
    local mod = project._module and project._module.impl or nil
    local tool_data, terr = exec_tool_data(unit)
    if terr then return nil, terr end
    local profile = opts.profile or ws._active_profile
    local all_tasks
    if opts.target_id and mod and mod.build_target_task then
        local project_ctx = project:to_module_context(ws.root)
        project_ctx.configuration = unit:variant()
        project_ctx.configuration_key = unit:config_key()
        project_ctx.tool_data = tool_data
        project_ctx.cached_build_dir = unit:build_dir()
        project_ctx.env, project_ctx.configuration_env = resolve_task_env(project,
            unit._configuration, tool_data, profile, ws.root)
        local ok, td = pcall(mod.build_target_task, project_ctx, opts.target_id)
        if not ok then return nil, tostring(td) end
        if td then
            td.loomworks = td.loomworks or {}
            td.loomworks.unit = unit
            td.loomworks.profile = td.loomworks.profile or profile
            all_tasks = { configure = {}, build = { td } }
        end
    end
    if not all_tasks then
        all_tasks = collect_configuration_tasks(unit, { profile = profile })
        if not all_tasks then
            return nil, "module '" .. tostring(project.type) .. "' returned no build tasks for " .. project.key
        end
    end
    local steps, err = M.plan_profile_build(nil, { tasks = all_tasks })
    if err then return nil, err end
    return steps or {}
end

--- Build an overseer-free "clean" plan for a profile: one step per project's
--- module clean task (e.g. `meson compile --clean`, `cmake --build --target
--- clean`). Skips build dirs that don't exist on disk (nothing to clean —
--- e.g. never configured). Intended for the headless runner. Each step
--- carries a ready-to-spawn `{cmd, cwd, env}`.
--- @param profile loomworks.Profile
--- @return table[]|nil steps list of { kind, name, build_dir, cmd, cwd, env, unit } — or
---   { kind, name, build_dir, wipe_build_dir = true, unit } for a core-performed
---   wipe (run it with `Workspace:clean_wipe_build_dir(units, build_dir)`,
---   passing every wipe step's unit for the same build_dir as one batch)
--- @return loomworks.RefusalLine[]|nil refused the ProfileProjects not cleaned
---   as invalid (core §5.4): the caller cleans the others, then fails
function M.plan_profile_clean(profile)
    local tasks, refused = collect_profile_clean_tasks(profile)
    return M._clean_steps(tasks), refused
end

--- The clean plan of `plan_profile_clean` for configuration units instead of
--- a profile (`Build/1.clean` `units`, spec §19.15): each unit's clean tasks
--- collected by collect_configuration_clean_tasks (the tool its unit
--- records), in the order given.
--- A unit whose tool is not detected refuses the whole clean (nil), as
--- plan_profile_clean does; a unit whose module has no clean is skipped.
--- @param units loomworks.ConfigUnit[]
--- @return table[]|nil steps as plan_profile_clean's
function M.plan_units_clean(units)
    local tasks = {}
    for _, unit in ipairs(units) do
        local clean, undetected = collect_configuration_clean_tasks(unit)
        if undetected then return nil end
        for _, task_def in ipairs(clean or {}) do
            -- The unit the task cleans, as for a profile (collect_profile_clean_tasks):
            -- the headless runner records a module clean against it.
            task_def.loomworks = task_def.loomworks or {}
            if task_def.loomworks.unit == nil then task_def.loomworks.unit = unit end
            tasks[#tasks + 1] = task_def
        end
    end
    return M._clean_steps(#tasks > 0 and tasks or nil)
end

--- The steps of collected clean task definitions (plan_profile_clean).
--- @param tasks table[]|nil
--- @return table[]|nil steps
function M._clean_steps(tasks)
    if not tasks then return nil end
    local uv = vim.uv or vim.loop
    local steps = {}
    for _, td in ipairs(tasks) do
        local build_dir = td.loomworks and td.loomworks.build_dir or nil
        -- Nothing to clean if the build dir was never created.
        if td.loomworks and td.loomworks.wipe_build_dir then
            -- Core-performed wipe (no command): the runner validates + deletes.
            if build_dir and uv.fs_stat(build_dir) then
                steps[#steps + 1] = {
                    kind = "clean",
                    name = td.name,
                    build_dir = build_dir,
                    wipe_build_dir = true,
                    unit = td.loomworks.unit,
                }
            end
        elseif td.builder and (not build_dir or uv.fs_stat(build_dir)) then
            local ok, spec = pcall(td.builder)
            if ok and type(spec) == "table" and type(spec.cmd) == "table" then
                steps[#steps + 1] = {
                    kind = "clean",
                    name = td.name,
                    build_dir = build_dir,
                    cmd = spec.cmd,
                    cwd = (type(spec.cwd) == "string" and spec.cwd ~= "") and spec.cwd or nil,
                    env = spec.env,
                    unit = td.loomworks and td.loomworks.unit or nil,
                }
            end
        end
    end
    return steps
end

--- Resolve the per-unit JUnit output path. One unit → the caller's path
--- verbatim; several → insert a sanitized label before the extension so the
--- files don't clobber (result.xml → result.app-Debug.xml).
--- @param base string caller-supplied JUnit path (absolute)
--- @param label string unit label (e.g. "app:Debug")
--- @param multi boolean true when more than one unit produces JUnit
--- @return string
local function junit_dest_for(base, label, multi)
    if not multi then return base end
    local slug = label:gsub("[^%w%-_.]", "-")
    local dir, name = base:match("^(.*)/([^/]+)$")
    if not name then name = base end
    local stem, ext = name:match("^(.+)%.([^.]+)$")
    local newname = stem and (stem .. "." .. slug .. "." .. ext) or (name .. "." .. slug)
    return dir and (dir .. "/" .. newname) or newname
end
M._junit_dest_for = junit_dest_for  -- exported for tests

--- Build a headless "run all tests" plan for a profile: one step per buildable
--- unit's native test runner (TestUnit:run_command_all — module TestUnits
--- only, never core's saved-targets TestUnit). Assumes the profile has
--- already been built. Returns the test steps plus the number of buildable
--- units seen, so a caller can tell "all passed" from "no tests".
--- `opts.extra_args` forwards caller args to each runner; `opts.junit` (an
--- absolute path) requests JUnit output — each step carries `junit_dest` (where
--- the caller wants it) and `junit_out` (where the runner actually wrote it).
--- `opts.skip_units` drops the listed units' batch steps (a foreign unit,
--- §16.16); `opts.junit_dest_for(label)`, when given, assigns the JUnit path
--- instead of the per-runner rule (the caller's whole-plan labelling).
--- `opts.no_rebuild` (`lw test --no-build`, §16.16) is forwarded to each
--- runner; a self-rebuilding runner whose spec does not confirm it
--- (`no_rebuild = true`) yields a step with `refused` set (the reason) — the
--- caller refuses it before any step runs, never letting it rebuild.
--- A ProfileProject invalid for the action (`ProfileProject:invalid_reason`) gets no step
--- (core §5.4 "Invalid ProfileProjects"): it is named in `refused`, so the
--- caller runs the other projects' tests, then fails.
--- @param profile loomworks.Profile
--- @param opts? table { extra_args?: string[], junit?: string, no_rebuild?: boolean, skip_units?: table<loomworks.ConfigUnit, boolean>, junit_dest_for?: fun(label: string, unit: loomworks.ConfigUnit): string|nil }
--- @return table[]|nil steps, integer units_seen
--- @return loomworks.RefusalLine[]|nil refused nil when none
function M.plan_profile_test(profile, opts)
    opts = opts or {}
    local all_tasks = collect_profile_tasks(profile)
    if not all_tasks then return nil, 0 end
    local refused = (all_tasks.refused and #all_tasks.refused > 0) and all_tasks.refused or nil

    local seen, units = {}, {}
    for _, td in ipairs(all_tasks.build or {}) do
        local unit = td.loomworks and td.loomworks.unit
        if unit and not seen[unit] then seen[unit] = true; units[#units + 1] = unit end
    end

    -- Pass 1: enumerate every runnable test unit up front, so the JUnit-path
    -- assignment below knows whether to use a single file or per-unit files.
    local runnable = {}
    local skip = opts.skip_units or {}
    for _, unit in ipairs(units) do
        local label = (unit._project and unit._project.key or "?") .. ":" .. tostring(unit:variant())
        local list_fn = unit.batch_runner_test_units or unit.test_units
        if not skip[unit] then
            for _, tu in ipairs(list_fn(unit)) do
                if tu.run_command_all and not tu.is_saved_targets then
                    runnable[#runnable + 1] = { unit = unit, tu = tu, label = label }
                end
            end
        end
    end
    local multi = #runnable > 1

    -- Pass 2: build the steps, threading extra args + the resolved JUnit dest.
    local steps = {}
    for _, r in ipairs(runnable) do
        local junit_dest
        if opts.junit_dest_for then
            junit_dest = opts.junit_dest_for(r.label, r.unit)
        else
            junit_dest = opts.junit and junit_dest_for(opts.junit, r.label, multi) or nil
        end
        local ok, spec = pcall(function()
            return r.tu:run_command_all({ extra_args = opts.extra_args, junit = junit_dest,
                profile = profile, no_rebuild = opts.no_rebuild or nil })
        end)
        if not ok then
            -- A throwing runner is a bug, not "no tests" — surface it
            -- instead of silently dropping the unit.
            local ws = r.unit._workspace
            if ws and ws._core and ws._core._deps.notify then
                ws._core._deps.notify(
                    "loomworks: test runner for " .. r.label .. " errored: " .. tostring(spec),
                    vim.log.levels.WARN)
            end
        elseif type(spec) == "table" and type(spec.cmd) == "table" then
            steps[#steps + 1] = {
                kind = "test",
                name = r.label,
                unit = r.unit,
                runner = (type(spec.cmd[1]) == "string"
                    and spec.cmd[1]:gsub("\\", "/"):match("([^/]+)$"):gsub("%.[eE][xX][eE]$", "")) or "runner",
                cmd = spec.cmd,
                cwd = (type(spec.cwd) == "string" and spec.cwd ~= "") and spec.cwd or nil,
                env = spec.env,
                junit_dest = junit_dest,
                junit_out = spec.junit_out,
                refused = (opts.no_rebuild and not spec.no_rebuild and r.tu.run_command_all_rebuilds
                    and r.tu:run_command_all_rebuilds())
                    and "its test runner rebuilds its targets and cannot skip that" or nil,
            }
        end
    end
    return steps, #units, refused
end

--- Launch a run/launch task via overseer.
--- Unlike build tasks, this doesn't use task_tracker or ConfigUnit state.
--- Opens the overseer window automatically.
--- @param opts { name: string, cmd: string[], cwd?: string, env?: table }
--- @return number|nil task_id
function M.launch_run_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    -- overseer expects cmd as a list (argv) for direct execution
    local cmd = opts.cmd
    if type(cmd) == "string" then
        cmd = { cmd }
    end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end
    local spec, h_err = harden({ cmd = cmd, cwd = opts.cwd, env = opts.env })
    if not spec then
        vim.notify("loomworks: " .. tostring(opts.name) .. ": " .. tostring(h_err), vim.log.levels.ERROR)
        return nil
    end
    local task = overseer.new_task({
        name = opts.name,
        cmd = spec.cmd,
        cwd = opts.cwd,
        env = spec.env,
        components = { "default" },
    })
    task:start()
    overseer.open({ enter = false })
    return task.id
end

--- Run a simple command as an overseer task. Returns a Future.
--- Used for device install/launch operations.
--- Supports `check_output(lines)` to detect failures when exit code is
--- unreliable (e.g., some device connectors return 0 on partial failure).
--- The function returns an error string to reject, or nil/true for success.
--- @param opts { name: string, cmd: string|string[], args?: string[], cwd?: string, env?: table, check_output?: fun(lines: string[]): string|nil }
--- @return loomworks.Future
function M.run_cmd_task(opts)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return future_mod.rejected("overseer.nvim not found")
    end

    local cmd = opts.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end

    local spec, h_err = harden({ cmd = cmd, cwd = opts.cwd, env = opts.env })
    if not spec then
        return future_mod.rejected(tostring(opts.name) .. ": " .. tostring(h_err))
    end

    return future_mod.create(function(resolve, reject)
        local output_lines = {}
        local task = overseer.new_task({
            name = opts.name,
            cmd = spec.cmd,
            cwd = opts.cwd,
            env = spec.env,
            components = { "default" },
        })
        if opts.check_output then
            task:subscribe("on_output_lines", function(_, lines)
                for _, line in ipairs(lines or {}) do
                    output_lines[#output_lines + 1] = line
                end
            end)
        end
        task:subscribe("on_complete", function(_, status)
            if status ~= "SUCCESS" then
                reject(opts.name .. " failed (" .. tostring(status) .. ")")
                return
            end
            if opts.check_output then
                local err = opts.check_output(output_lines)
                if err then
                    reject(opts.name .. ": " .. err)
                    return
                end
            end
            resolve(true)
        end)
        task:start()
        overseer.open({ enter = false })
    end)
end

--- Run a long-running streaming task: every line of stdout is
--- forwarded to `opts.on_line` instead of displayed via overseer's
--- default output buffer. The overseer task itself still exists
--- (shows up in the task list, killable there) so the user has a
--- unified "what's running" view, but actual rendering happens in a
--- caller-owned surface (e.g. the device-log view).
---
--- Unlike `run_cmd_task` this does not return a Future — streaming
--- tasks don't have a meaningful "done" value; the caller holds the
--- task handle and tears it down when the owning session ends.
---
--- `on_complete(status)` fires when the task finishes (process exit,
--- user-stop, or error) — useful for the caller to invalidate its
--- own state, not for chaining.
--- @param opts { name: string, cmd: string|string[], args?: string[], cwd?: string, env?: table, on_line: fun(line: string), on_complete?: fun(status: string) }
--- @return table|nil overseer task handle
function M.run_streaming_task(opts)
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return nil
    end

    local cmd = opts.cmd
    if type(cmd) == "string" then cmd = { cmd } end
    if opts.args then
        cmd = vim.list_extend(vim.deepcopy(cmd), opts.args)
    end

    -- Minimal component set: we want the task lifecycle (on_start /
    -- on_output_lines / on_complete hooks) but don't want the default
    -- output-to-buffer rendering — the caller is rendering lines
    -- somewhere else and duplicating them into a hidden task buffer
    -- is wasted memory for a firehose log tail.
    --
    -- `use_terminal = false` is CRITICAL for log tailing. Overseer's
    -- default jobstart strategy runs the process under a pty sized
    -- to the current nvim window, which hard-wraps long stdout lines
    -- at `vim.o.columns - 4` and emits ANSI cursor-positioning
    -- sequences between records. For line-oriented log output —
    -- lines routinely >200 chars — that turns every record into two or three
    -- fragments, none of which parse. A non-terminal jobstart uses
    -- a plain stdout pipe and gives us raw newline-separated output.
    local spec, h_err = harden({ cmd = cmd, cwd = opts.cwd, env = opts.env })
    if not spec then
        vim.notify("loomworks: " .. tostring(opts.name) .. ": " .. tostring(h_err), vim.log.levels.ERROR)
        return nil
    end
    local task = overseer.new_task({
        name = opts.name,
        cmd = spec.cmd,
        cwd = opts.cwd,
        env = spec.env,
        strategy = { "jobstart", use_terminal = false },
        components = { "on_output_summarize", "on_exit_set_status" },
    })

    task:subscribe("on_output_lines", function(_, lines)
        for _, line in ipairs(lines or {}) do
            if opts.on_line then
                local ok_cb, err = pcall(opts.on_line, line)
                if not ok_cb then
                    vim.notify("loomworks: streaming on_line error: " .. tostring(err),
                        vim.log.levels.WARN)
                end
            end
        end
    end)

    if opts.on_complete then
        task:subscribe("on_complete", function(_, status)
            pcall(opts.on_complete, status)
        end)
    end

    task:start()
    return task
end

return M
