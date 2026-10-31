local M = {}

local nice = require("loomworks.nice")

--- Action set that gets the nice/ionice wrapper. Configure, build and
--- clean are the long-running ones competing with the editor for CPU
--- and disk; test runs are wrapped at the loomtest runner instead
--- (because they don't pass through this module's action dispatch).
--- Detection probes (parse_targets, get_options, version checks) are
--- intentionally excluded — those are short and user-blocking, so
--- niceing them just makes the editor feel slow.
local NICE_ACTIONS = { configure = true, build = true, clean = true }

--- Wrap the `cmd` field of a task builder result with nice/ionice when
--- the action qualifies. No-op on non-Linux or when the wrapper
--- binaries are missing (see `loomworks.nice`).
--- @param build_result table builder() output with optional `cmd`
--- @param action string|nil loomworks action tag
--- @return table the same build_result (mutated in place)
--- Resolve a task's program before overseer spawns it (loomworks.exe): cmd[1]
--- becomes an absolute path found in an absolute PATH entry of the task env
--- (else the process PATH) — never the current directory — and on Windows the
--- task env gains `NoDefaultCurrentDirectoryInExePath=1` so a cmd.exe / .bat
--- the task runs does not search its cwd either. Applied BEFORE the nice
--- wrapper so the real program is the one resolved. Returns the spec, or nil +
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

local function apply_nice(build_result, action)
    if not action or not NICE_ACTIONS[action] then return build_result end
    if type(build_result.cmd) ~= "table" then return build_result end
    build_result.cmd = nice.wrap_cmd(build_result.cmd)
    return build_result
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

--- Return a raw build command spec for a ConfigUnit.
--- Intended for callers that want to invoke a plain overseer task
--- without going through the loomworks task tracker (e.g. loomtest
--- auto-building tests). Delegates to the module via `build_target_task`
--- when a specific target is requested and the module supports it,
--- otherwise falls back to the "build" action from `module.tasks()`.
--- @param unit loomworks.ConfigUnit
--- @param target_id? string optional target to build in isolation
--- @return table|nil spec `{ cmd, cwd?, env? }` or nil when unavailable
function M.build_spec_for(unit, target_id)
    local project = unit._project
    if not project then return nil end
    local mod = project._module and project._module.impl or nil
    if not mod then return nil end

    -- Build a ctx the module's tasks can consume (same shape as
    -- collect_configuration_tasks uses).
    local ws = unit._workspace
    if not ws then return nil end
    local variant = unit:variant()
    local tool_data, terr = exec_tool_data(unit)
    if terr then return refuse_undetected(terr) end

    local abs_path = ws.root .. "/" .. (project.path or project.key)
    local tc_for_module = project._type_config_for_module
        and project:_type_config_for_module() or (project.type_config or {})

    local mod_info = { configurations = {} }
    if mod.info then
        local ok, result = pcall(mod.info, abs_path, tc_for_module)
        if ok and result then mod_info = result end
    end

    local task_env, configuration_env = resolve_task_env(
        project, unit._configuration, tool_data, ws._active_profile, ws.root)
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
        resolved_variables = resolve_project_variables(project, unit._configuration, tool_data, ws._active_profile),
        compiler_cache = resolve_compiler_cache(project, unit._configuration, tool_data, ws._active_profile),
        recorded_cache_launcher = unit.module_info and unit.module_info.cache_launcher or nil,
        recorded_module_info = unit.module_info,
        recorded_options = unit._cached_options,
    }

    --- Validate spec types and coerce missing cwd to the workspace root.
    --- overseer's new_task rejects userdata fields with opaque messages,
    --- so normalize early and reject with a helpful one. Also applies
    --- the nice/ionice wrap — `build_spec_for` is only ever called for
    --- builds (per-target, or the build action fallback), so we wrap
    --- here unconditionally rather than threading an action arg through.
    --- @param spec table|nil
    --- @return table|nil normalized spec, string|nil err
    local function normalize(spec)
        if type(spec) ~= "table" or type(spec.cmd) ~= "table" then
            return nil, "builder returned no cmd array"
        end
        for i, c in ipairs(spec.cmd) do
            if type(c) ~= "string" then
                return nil, ("cmd[%d] is %s, not string"):format(i, type(c))
            end
        end
        -- cwd: coerce to string if sensible, else fall back to workspace root
        if spec.cwd == nil or type(spec.cwd) ~= "string" or spec.cwd == "" then
            spec.cwd = ws.root
        end
        if spec.env ~= nil and type(spec.env) ~= "table" then
            spec.env = nil
        end
        local hardened, h_err = harden(spec)
        if not hardened then return nil, h_err end
        spec.cmd = nice.wrap_cmd(spec.cmd)
        return spec, nil
    end

    -- Prefer a per-target build when possible
    if target_id and mod.build_target_task then
        local ok, task_def = pcall(mod.build_target_task, project_ctx, target_id)
        if ok and task_def and task_def.builder then
            local ok2, spec = pcall(task_def.builder)
            if ok2 then
                local norm, err = normalize(spec)
                if norm then return norm end
                if err then
                    vim.notify("loomworks: build_target_task spec invalid: " .. err,
                        vim.log.levels.WARN)
                end
            end
        end
    end

    -- Fall back to the full "build" action from tasks()
    if not mod.tasks then return nil end
    local ok_t, mod_tasks = pcall(mod.tasks, project_ctx, variant)
    if not ok_t or type(mod_tasks) ~= "table" then return nil end
    for _, t in ipairs(mod_tasks) do
        if t.loomworks and t.loomworks.action == "build" and t.builder then
            local ok2, spec = pcall(t.builder)
            if ok2 then
                local norm, err = normalize(spec)
                if norm then return norm end
                if err then
                    vim.notify("loomworks: build task spec invalid: " .. err,
                        vim.log.levels.ERROR)
                    return nil
                end
            end
        end
    end
    return nil
end

--- The result line of a ProfileProject a profile-level operation does not run
--- (core §5.4 "Invalid ProfileProjects"): `<project>/<configuration> not run:
--- <reason> — <remedy>`.
--- @param pp loomworks.ProfileProject
--- @param reason string the tool compat error
--- @return string
function M.refusal_line(pp, reason)
    local pk = pp._project and pp._project.key or "?"
    local cn = pp.variant_name and pp:variant_name() or "?"
    return pk .. "/" .. tostring(cn) .. " not run: " .. reason
        .. " — change the profile's tool to match the configuration"
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
--- A ProfileProject invalid for the action (a tool compat error, §8.4
--- `validate_config_tool`) is not run (core §5.4 "Invalid ProfileProjects"):
--- its tasks are left out and `refused` names it with its reason, so the
--- caller fails the operation after the other projects ran.
--- @return loomworks.ProfileTaskDefs|nil task_defs_by_action
local function collect_profile_tasks(profile, opts)
    opts = opts or {}
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
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
            local compat = pp.tool_compat_error and pp:tool_compat_error() or nil
            if compat then
                by_action.refused[#by_action.refused + 1] = M.refusal_line(pp, compat)
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
--- A ProfileProject with a tool compat error (§8.4 `validate_config_tool`:
--- clean is blocked on it) is not cleaned (core §5.4 "Invalid
--- ProfileProjects"): it is left out and named in `refused`.
--- @param profile loomworks.Profile
--- @return table[]|nil clean_tasks
--- @return loomworks.RefusalLine[]|nil refused nil when none
local function collect_profile_clean_tasks(profile)
    local loomworks = require("loomworks")
    local modules = require("loomworks.modules")

    local ws = loomworks.get_workspace()
    if not ws then return nil end

    local pps = profile:projects()
    if #pps == 0 then return nil end

    local tasks, refused = {}, {}

    for _, pp in ipairs(pps) do
        local project = pp._project
        if not project then goto continue end

        do
            local compat = pp.tool_compat_error and pp:tool_compat_error() or nil
            if compat then
                refused[#refused + 1] = M.refusal_line(pp, compat)
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
            local compat = pp.tool_compat_error and pp:tool_compat_error() or nil
            local unit = pp._config_unit
            if compat and unit then
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

--- A module clean task (the build system's artifact clean, not a wipe)
--- succeeded: record it — the unit's built state drops to `configured`
--- (spec §4.7; `mark_cached_configs_cleaned` leaves every other state). The
--- editor records only after success, as the headless runners do
--- (build_run.after_clean_step): a failed clean keeps the unit `built`.
--- @param ws loomworks.Workspace|nil
--- @param unit loomworks.ConfigUnit|nil
local function record_module_clean(ws, unit)
    if ws and unit and ws.mark_cached_configs_cleaned then
        ws:mark_cached_configs_cleaned({ { unit = unit } })
    end
end

--- Core-performed clean for a clean task that declares
--- `loomworks.wipe_build_dir = true` (spec §8.1): the module asks core to
--- remove the build directory instead of spawning a command. Deletion safety
--- (CLAUDE.md): nil/empty build_dir => nothing to wipe; the path (possibly
--- cache-sourced) must pass `_validate_build_dir` (canonical, trailing-"/"
--- boundary, never the workspace root); removal is in-process
--- (`io.rm_rf_async`: libuv calls, links not followed) — no shell.
--- With the task's config unit (`loomworks.unit`, set by the clean task
--- collectors) the wipe is a build-directory DELETION (spec §4.6, §4.7) via
--- `Workspace:clean_wipe_build_dir`: cache `unknown` on disk before the tree
--- is removed, the unit reset to unconfigured only after the removal
--- succeeded, a directory still referenced by a config outside the clean
--- kept. `units` (default: the task's own unit) are all the clean's units
--- sharing this build directory, deleted as one batch. The Future rejects
--- when the deletion reports it did not happen (lock refused or removal
--- failed).
--- @param ws loomworks.Workspace|nil
--- @param task_def table
--- @param units? loomworks.ConfigUnit[]
--- @return loomworks.Future
local function wipe_build_dir(ws, task_def, units)
    local future_mod = require("loomworks.future")
    local bd = task_def.loomworks and task_def.loomworks.build_dir
    if type(bd) ~= "string" or bd == "" then return future_mod.resolved(true) end
    if not ws or not ws:_validate_build_dir(bd, ws.root) then
        return future_mod.rejected("clean refused: unsafe build directory " .. tostring(bd))
    end
    local unit = task_def.loomworks.unit
    units = units or (unit and { unit } or nil)
    if units and #units > 0 and ws.clean_wipe_build_dir then
        local f = ws:clean_wipe_build_dir(units, bd)
        return f:next(function(ok)
            -- The deletion's own outcome: `false` = a lock was refused or the
            -- removal failed (both reported) — the clean did not happen.
            if ok ~= true then
                error("could not remove " .. bd, 0)
            end
            return true
        end)
    end
    local io_dep = (ws._core and ws._core._deps and ws._core._deps.io) or require("loomworks.io")
    return io_dep.rm_rf_async(bd)
end
M._wipe_build_dir = wipe_build_dir

--- Determine the lock type for a task action.
--- @param action string "configure", "build", "clean", etc.
--- @return "exclusive"|"shared"
local function lock_type_for_action(action)
    return action == "build" and "shared" or "exclusive"
end

--- Build and start a single overseer task from a task definition. Acquires a
--- build dir lock before starting; if it can't be acquired immediately the task
--- is queued and started when the lock frees. Uses event subscriptions (not a
--- component) so the overseer task stays pure and the ConfigUnit is captured
--- directly. Returns a Future that resolves with boolean success.
--- @param overseer table overseer module
--- @param task_def table task definition with .builder and .loomworks
--- @param on_complete? function legacy callback (deprecated, use Future)
--- @return loomworks.Future
local function start_one_task(overseer, task_def, on_complete)
    local future_mod = require("loomworks.future")
    local lw_meta = task_def.loomworks
    local unit = lw_meta.unit

    local f = future_mod.create(function(resolve, reject, token)
        local function do_start()
            if token:is_cancelled() then
                reject("cancelled")
                return
            end

            -- Cross-process gate: in addition to the in-process lock, hold a
            -- lockfile so a CLI (or another editor) can't build the same
            -- directory concurrently. Fail-fast — release the in-process lock
            -- and reject if another live process holds it.
            if lw_meta.build_dir then
                local ws = unit._workspace
                if ws and ws._acquire_file_lock then
                    local dir = ws._core._deps.normalize(lw_meta.build_dir)
                    local ok_fl, fl_err = ws:_acquire_file_lock(dir, lw_meta.action)
                    if not ok_fl then
                        ws:release_build_dir_lock(dir, lock_type_for_action(lw_meta.action))
                        vim.schedule(function()
                            vim.notify("loomworks: " .. tostring(fl_err), vim.log.levels.WARN)
                        end)
                        reject(fl_err)
                        return
                    end
                end
            end

            -- Full-reconfigure support (core §5.1 / §8.1 `pre_configure_reset`):
            -- remove the module-named configure-state entries inside the build
            -- dir now that the exclusive lock is held. Core performs (and
            -- validates) the deletion, never the module. On refusal/failure
            -- the configure is not started.
            if lw_meta.action == "configure" and type(lw_meta.pre_configure_reset) == "table"
                    and #lw_meta.pre_configure_reset > 0 then
                local ws = unit._workspace
                local ok_r, r_err = true, nil
                if ws and ws._pre_configure_reset then
                    ok_r, r_err = ws:_pre_configure_reset(lw_meta.build_dir, lw_meta.pre_configure_reset)
                end
                if not ok_r then
                    if ws and lw_meta.build_dir then
                        local dir = ws._core._deps.normalize(lw_meta.build_dir)
                        ws:release_build_dir_lock(dir, lock_type_for_action(lw_meta.action))
                        if ws._release_file_lock then ws:_release_file_lock(dir) end
                    end
                    local msg = "loomworks: " .. tostring(r_err)
                    vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                    reject(msg)
                    return
                end
            end

            -- Why this configure runs (the gate's reason + the module's
            -- full/in-place choice), to the log — the editor's counterpart of
            -- the line the headless runner prints (§16.4).
            if lw_meta.action == "configure" then
                local why = M.configure_reason_line(lw_meta)
                local ws = unit._workspace
                if why and ws and ws._core and ws._core._deps.log then
                    ws._core._deps.log:info("%s — %s", task_def.name or "?", why)
                end
            end

            local raw_spec = task_def.builder()
            -- The command line + cwd, to the log (headless §16.4) — as the
            -- module wrote it, before program resolution and priority
            -- wrapping (`harden` then drops the display-only `display_cmd`).
            if type(raw_spec) == "table" and (lw_meta.action == "configure"
                    or lw_meta.action == "build") then
                M.log_task_command(unit._workspace, task_def.name, raw_spec)
            end
            local build_result, h_err = harden(raw_spec)
            if not build_result then
                if lw_meta.build_dir then
                    local ws = unit._workspace
                    if ws then
                        local dir = ws._core._deps.normalize(lw_meta.build_dir)
                        ws:release_build_dir_lock(dir, lock_type_for_action(lw_meta.action))
                        if ws._release_file_lock then ws:_release_file_lock(dir) end
                    end
                end
                local msg = "loomworks: " .. (task_def.name or "task") .. ": " .. tostring(h_err)
                vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                reject(msg)
                return
            end
            apply_nice(build_result, lw_meta.action)
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)

            token:on_cancel(function()
                if task and not task:is_complete() then
                    task:stop()
                end
            end)

            local progress_parser = lw_meta.progress_tool
                and require("loomworks.progress").get(lw_meta.progress_tool) or nil

            local lock_released = false
            local function release_lock()
                if lock_released or not lw_meta.build_dir then return end
                lock_released = true
                local ws = unit._workspace
                if ws then
                    local dir = ws._core._deps.normalize(lw_meta.build_dir)
                    ws:release_build_dir_lock(dir, lock_type_for_action(lw_meta.action))
                    if ws._release_file_lock then ws:_release_file_lock(dir) end
                end
            end

            local function emit(event, data)
                unit._workspace._core._deps.events.emit(event, data)
            end

            task:subscribe("on_start", function()
                if lw_meta.build_dir then
                    unit.build_dir_value = lw_meta.build_dir
                    unit._workspace:_save_cache()
                end
                unit:register_task(task.id, lw_meta.action)
                emit("task_started", { task_id = task.id, unit = unit, action = lw_meta.action })
            end)

            if progress_parser then
                task:subscribe("on_output_lines", function(_, lines)
                    for i = #lines, 1, -1 do
                        local update = progress_parser(lines[i])
                        if update then
                            unit:update_progress(task.id, update)
                            emit("task_progress", { task_id = task.id, unit = unit, progress = update })
                            return
                        end
                    end
                end)
            end

            task:subscribe("on_complete", function(_, status)
                if status ~= "CANCELED" then
                    unit._workspace:record_task_result({
                        unit = unit,
                        action = lw_meta.action,
                        variant = lw_meta.variant,
                        tool = lw_meta.tool,
                        profile = lw_meta.profile,
                        build_dir = lw_meta.build_dir,
                        module_info = lw_meta.module_info,
                        success = status == "SUCCESS",
                    })
                end
                unit:unregister_task(task.id)
                emit("task_stopped", { task_id = task.id, unit = unit })
                release_lock()
                if status == "SUCCESS" then resolve(true)
                else reject(lw_meta.action .. " failed") end
            end)

            task:subscribe("on_dispose", function()
                unit:unregister_task(task.id)
                emit("task_stopped", { task_id = task.id, unit = unit })
                release_lock()
            end)

            task:start()
        end

        -- Protected start: catch errors so the Future always resolves/rejects.
        -- Surface the error to the user too — without this, a throw between
        -- `overseer.new_task()` and `task:start()` leaves the task wedged in
        -- PENDING with no visible signal (the Future rejects but Operations
        -- only observe ConfigUnit state changes, which never happen).
        local function safe_start()
            local ok, err = pcall(do_start)
            if not ok then
                local msg = "loomworks: task start failed: " .. tostring(err)
                vim.schedule(function()
                    vim.notify(msg, vim.log.levels.ERROR)
                end)
                reject(msg)
            end
        end

        if lw_meta.build_dir then
            local ws = unit._workspace
            if ws then
                local dir = ws._core._deps.normalize(lw_meta.build_dir)
                ws:acquire_build_dir_lock(dir, lock_type_for_action(lw_meta.action), safe_start)
                return
            end
        end

        safe_start()
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end

    return f
end

--- Check whether a task should be launched, skipped, or deferred based on the
--- ConfigUnit's local state: a task observed in the workspace daemon never
--- holds an editor task back (spec §19.16) — the cross-process
--- build-dir lock (§16.6) gates it.
--- Configure tasks: only launch if unconfigured or configure_failed — or, for
--- an explicit (user-requested) configure, in any state but unknown. That
--- includes a unit already configuring/building: its configure is launched
--- and queues behind the build-dir lock.
--- Build tasks: skip if already building, defer if currently configuring,
--- block if in unknown state.
--- @param task_def table task definition with .loomworks
--- @param opts? { explicit_configure?: boolean } lift only the configured-skip
--- @return "launch"|"skip"|"defer"|"block"
local function check_task_readiness(task_def, opts)
    local lw_meta = task_def.loomworks
    local unit = lw_meta.unit
    local state = unit:local_state()

    -- Unknown state blocks all actions — user must clean/delete first
    if state == "unknown" then return "block" end

    if lw_meta.action == "configure" then
        if opts and opts.explicit_configure then return "launch" end
        if state == "unconfigured" or state == "configure_failed" then
            return "launch"
        end
        return "skip"
    end

    -- action == "build"
    if state == "building" then return "skip" end
    if state == "configuring" then return "defer" end
    return "launch"
end

--- Launch a list of task definitions via overseer.
--- Returns a Future that resolves with boolean (all succeeded).
--- Respects ConfigUnit state: skips already-running tasks, defers build tasks
--- that are waiting for an in-progress configure to finish.
--- @param overseer table overseer module
--- @param task_defs table[] task definitions with .builder and .loomworks
--- @param on_all_done? function legacy callback (deprecated, use Future)
--- @param opts? { force?: boolean, explicit_configure?: boolean, on_task_settled?: fun(task_def: table, ok: boolean) }
---   force=true bypasses readiness checks; explicit_configure=true lifts only
---   the configured-skip (unknown still blocks); on_task_settled is called once
---   per launched/deferred task when it finishes, and with ok=false for a
---   blocked task
--- @return loomworks.Future, number launched
local function launch_tasks(overseer, task_defs, on_all_done, opts)
    local future_mod = require("loomworks.future")
    local force = opts and opts.force or false
    local on_task_settled = opts and opts.on_task_settled

    local to_launch, to_defer = {}, {}
    for _, task_def in ipairs(task_defs) do
        if not task_def.loomworks then goto next end
        if force then
            to_launch[#to_launch + 1] = task_def
        else
            local readiness = check_task_readiness(task_def, opts)
            if readiness == "launch" then
                to_launch[#to_launch + 1] = task_def
            elseif readiness == "defer" then
                to_defer[#to_defer + 1] = task_def
            elseif readiness == "block" then
                local meta = task_def.loomworks
                vim.notify(
                    "loomworks: " .. meta.project_key .. "/" .. meta.configuration_key
                        .. " is in unknown state — clean or delete first",
                    vim.log.levels.WARN
                )
                -- The caller may already count this task (it filtered
                -- readiness before create_operation emitted events): settle
                -- it as failed so a tracking Operation cannot hang on it.
                if on_task_settled then on_task_settled(task_def, false) end
            end
        end
        ::next::
    end

    local total = #to_launch + #to_defer
    if total == 0 then
        if on_all_done then
            vim.schedule(function() on_all_done(true) end)
        end
        return future_mod.resolved(true), 0
    end

    local task_futures = {}
    local function track(task_def, tf)
        task_futures[#task_futures + 1] = tf
        if on_task_settled then
            tf:next(function() on_task_settled(task_def, true) end,
                function() on_task_settled(task_def, false) end)
        end
    end

    for _, task_def in ipairs(to_launch) do
        track(task_def, start_one_task(overseer, task_def))
    end

    for _, task_def in ipairs(to_defer) do
        local deferred_f = future_mod.Future.new()
        track(task_def, deferred_f)

        local unit = task_def.loomworks.unit
        local unsub
        unsub = unit:on_state_change(function(u)
            local new_state = u:local_state()
            if new_state == "configuring" then return end
            unsub()
            if new_state == "configure_failed" then
                deferred_f:_reject("configure failed")
                return
            end
            start_one_task(overseer, task_def):next(
                function(...) deferred_f:_resolve(...) end,
                function(err) deferred_f:_reject(err) end
            )
        end)
    end

    local result_f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if all_ok then return true
        else error("one or more tasks failed") end
    end)

    if on_all_done then
        result_f:next(function() on_all_done(true) end)
               :catch(function() on_all_done(false) end)
    end

    return result_f, total
end

--- Filter task definitions to only those that will actually launch or defer.
--- Excludes "skip" (already done) and "block" (unknown state) tasks.
--- @param task_defs table[]
--- @param opts? { explicit_configure?: boolean } see check_task_readiness
--- @return table[]
local function filter_launchable_tasks(task_defs, opts)
    local result = {}
    for _, task_def in ipairs(task_defs) do
        if task_def.loomworks then
            local readiness = check_task_readiness(task_def, opts)
            if readiness == "launch" or readiness == "defer" then
                result[#result + 1] = task_def
            end
        end
    end
    return result
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
--- Mirrors run_profile_action("build") sequencing: configure the units that
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
--- the editor's unit actions collect them (run_configuration_action: the
--- tool its unit records, the active profile's context), then the configures
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
--- run_configuration_action("build") runs them. The tool/configuration
--- compatibility gate refuses first, as in-process. The steps resolve against
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
--- collected as the editor's unit clean collects them
--- (run_configuration_clean: the tool its unit records), in the order given.
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
--- A ProfileProject invalid for the action (a tool compat error) gets no step
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

--- Run a configure or build action on a single ConfigUnit. If building and the
--- unit is unconfigured, configures first. Returns a Future that resolves on
--- success, rejects on failure.
--- @param unit loomworks.ConfigUnit
--- @param action "configure"|"build"
--- @param on_complete? function legacy callback (deprecated)
--- @param opts? table { parallel_jobs?: integer }
--- @return loomworks.Future
--- Editor-side output-artifact conflict gate (spec §5.9). Given the build
--- tasks about to run and a `force` flag, returns a Future that resolves when
--- the build may proceed, or rejects when the user declines. When a conflict is
--- found and not forced, surfaces a Yes/No confirmation naming the conflicting
--- profile and the shared artifact path — the interactive counterpart of the
--- CLI `--force` refusal (§16.28). Confirming proceeds (the other profile is
--- marked stale on completion, §5.9); declining rejects. Centralized here so
--- every editor build entry (`Profile:build`, `run_configuration_action`,
--- session_tracker, `ui.actions`) inherits it. Evaluated by the caller only
--- after any configure step, so a configure→build chain sees U's artifacts.
--- @param ws loomworks.Workspace|nil
--- @param build_tasks table[] build task_defs (carry `.loomworks.unit`)
--- @param force boolean
--- @return loomworks.Future
local function guard_build_conflicts(ws, build_tasks, force)
    local future_mod = require("loomworks.future")
    if force or not ws or not ws.artifact_conflict_block then
        return future_mod.resolved(true)
    end
    local block
    for _, td in ipairs(build_tasks or {}) do
        local unit = td.loomworks and td.loomworks.unit
        if unit then
            block = ws:artifact_conflict_block(unit, false)
            if block then break end
        end
    end
    if not block then return future_mod.resolved(true) end
    return future_mod.create(function(resolve, reject)
        vim.schedule(function()
            vim.ui.select({ "Yes", "No" }, {
                prompt = string.format(
                    "loomworks: build would overwrite an artifact owned by built "
                        .. "profile '%s':\n  %s\nOverwrite it (that profile will be "
                        .. "marked stale)?",
                    block.profile or "?", block.path or "?"),
            }, function(choice)
                if choice == "Yes" then
                    resolve(true)
                else
                    reject("build cancelled — would overwrite profile '"
                        .. (block.profile or "?") .. "'")
                end
            end)
        end)
    end)
end

local in_process_configuration_action

--- Run a build or configure of one configuration unit. Returns a Future.
--- Only a model's operation runs here (the CLI, the daemon, the deprecated
--- `in-process` editor): the `daemon`-mode editor holds no model and names
--- its operations by ids (loomworks.daemon.editor_ops.run_ids, step 6b-α).
--- @param unit loomworks.ConfigUnit
--- @param action "build"|"configure"
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @param opts? { parallel_jobs?: integer, force?: boolean }
--- @return loomworks.Future
function M.run_configuration_action(unit, action, on_complete, opts)
    -- No `daemon`-mode refusal here (there was one before step 6b-α): this
    -- runs in-process unconditionally, which is safe ONLY because a
    -- `daemon`-mode editor holds no model and so has no unit to pass in.
    -- Should that editor ever hold one again, refuse here (§19.16
    -- "Availability": never run in-process in `daemon` mode).
    return in_process_configuration_action(unit, action, on_complete, opts)
end

--- The in-process unit build / configure (run_configuration_action).
in_process_configuration_action = function(unit, action, on_complete, opts)
    local future_mod = require("loomworks.future")

    -- Tool/configuration compatibility gate. Refuse build/configure/
    -- rebuild when the active profile's tool can't honor the
    -- configuration's contract — going further would queue tasks
    -- that either fail opaquely or silently produce wrong-platform
    -- artefacts. The diagnostic already surfaces the same reason on
    -- the status page; this is the belt-and-braces path for users
    -- who act before reading the diagnostic. Runs before the
    -- overseer check because it's about the unit's state, not about
    -- task queueing. Compat error is per-(profile, configuration);
    -- ConfigUnit:tool_compat_error() resolves against the workspace's
    -- active profile.
    local compat_err = unit and unit.tool_compat_error
        and unit:tool_compat_error() or nil
    if compat_err then
        vim.notify(
            "loomworks: " .. compat_err
                .. " — change the profile's tool to match the configuration",
            vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected(compat_err)
    end

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local ws = unit._workspace
        local log = ws and ws._core and ws._core._deps.log
        if log then log:debug("run_configuration_action: %s for %s/%s",
            action, unit._init_project_key or "?", unit:variant() or "?") end

        local all_tasks = collect_configuration_tasks(unit)
        if not all_tasks then
            if log then log:warn("run_configuration_action: no tasks returned for %s", action) end
            f:_reject("no tasks for " .. action)
            return
        end

        if log then
            local n_conf = all_tasks.configure and #all_tasks.configure or 0
            local n_build = all_tasks.build and #all_tasks.build or 0
            log:debug("run_configuration_action: %d configure, %d build tasks", n_conf, n_build)
        end

        if action == "configure" then
            -- Force=true: explicit configure always runs, even if already configured
            launch_tasks(overseer, all_tasks.configure, nil, { force = true }):next(
                function() f:_resolve(true) end,
                function(err) f:_reject(err) end
            )
            return
        end

        if action == "build" then
            if opts and opts.parallel_jobs then
                local jobs = tostring(opts.parallel_jobs)
                for _, task_def in ipairs(all_tasks.build or {}) do
                    local orig_builder = task_def.builder
                    task_def.builder = function()
                        local result = orig_builder()
                        result.cmd = M.append_parallel_jobs(result.cmd or {}, jobs)
                        return result
                    end
                end
            end

            local force = opts and opts.force or false
            local needs_configure = filter_unconfigured_tasks(all_tasks)
            if #needs_configure > 0 then
                launch_tasks(overseer, needs_configure):next(function()
                    -- Configure done → U's artifact set is known; gate before compile.
                    return guard_build_conflicts(ws, all_tasks.build, force)
                end):next(function()
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    function() f:_resolve(true) end,
                    function(err) f:_reject(err) end
                )
            else
                guard_build_conflicts(ws, all_tasks.build, force):next(function()
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    function() f:_resolve(true) end,
                    function(err) f:_reject(err) end
                )
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
        f:_reject("unknown action: " .. action)
    end

    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end

    return f
end

--- Run clean tasks for a single configuration. Returns a Future.
--- @param unit loomworks.ConfigUnit
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @return loomworks.Future
function M.run_configuration_clean(unit, on_complete)
    local future_mod = require("loomworks.future")

    -- Clean invokes the module's build system, which needs the right SDK env
    -- to know where it's pointing. A mismatched tool would clean the wrong tree
    -- or fail opaquely. ConfigUnit:delete (rm-rf of the cached dir) is
    -- independent and remains allowed.
    local compat_err = unit and unit.tool_compat_error
        and unit:tool_compat_error() or nil
    if compat_err then
        vim.notify(
            "loomworks: " .. compat_err
                .. " — change the profile's tool to match the configuration",
            vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected(compat_err)
    end

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local tasks = collect_configuration_clean_tasks(unit)
    if not tasks or #tasks == 0 then
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    local task_futures = {}
    for _, task_def in ipairs(tasks) do
        local tf = future_mod.create(function(resolve, reject, token)
            if task_def.loomworks and task_def.loomworks.wipe_build_dir then
                wipe_build_dir(unit._workspace, task_def)
                    :next(function() resolve(true) end)
                    :catch(function(e)
                        local msg = "loomworks: " .. (task_def.name or "clean") .. ": " .. tostring(e)
                        vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                        reject(msg)
                    end)
                return
            end
            local build_result, h_err = harden(task_def.builder())
            if not build_result then
                local msg = "loomworks: " .. (task_def.name or "clean") .. ": " .. tostring(h_err)
                vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                reject(msg)
                return
            end
            apply_nice(build_result, "clean")
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)
            token:on_cancel(function()
                if task and not task:is_complete() then task:stop() end
            end)
            task:subscribe("on_complete", function(_, status)
                if status == "SUCCESS" then
                    record_module_clean(unit._workspace,
                        task_def.loomworks and task_def.loomworks.unit or unit)
                    resolve(true)
                else reject("clean task failed") end
            end)
            task:start()
        end)
        task_futures[#task_futures + 1] = tf
    end

    local f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if all_ok then return true else error("clean failed") end
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Run clean tasks for all projects in a profile. Returns a Future.
--- @param profile loomworks.Profile
--- @param on_complete? fun(success: boolean) legacy callback (deprecated)
--- @param opts? { refused_ok?: boolean } refused_ok: when the ProfileProjects
---   not cleaned as invalid (core §5.4) are the clean's only failure, the
---   Future resolves with their result lines (loomworks.RefusalLine[])
---   instead of rejecting (Profile:clean; the editor's rebuild goes on to
---   its build). A failed clean task always rejects, naming them too.
--- @return loomworks.Future
function M.run_profile_clean(profile, on_complete, opts)
    local future_mod = require("loomworks.future")
    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then on_complete(false) end
        return future_mod.rejected("overseer.nvim not found")
    end

    -- Invalid ProfileProjects (core §5.4) are not cleaned: the others are,
    -- then the clean fails naming them.
    local tasks, refused = collect_profile_clean_tasks(profile)
    if refused and #refused == 0 then refused = nil end
    local refused_ok = opts and opts.refused_ok
    if not tasks or #tasks == 0 then
        if refused then
            if on_complete then on_complete(false) end
            if refused_ok then return future_mod.resolved(refused) end
            return future_mod.rejected(M.refused_message(refused))
        end
        if on_complete then on_complete(true) end
        return future_mod.resolved(true)
    end

    -- Core-performed wipes of the same build directory are ONE deletion batch
    -- (spec §4.6): wiped once when no config outside this clean uses it.
    local ws = profile._workspace or require("loomworks").get_workspace()
    local wipe_group = {}
    do
        local groups = {}
        -- Grouped by build-dir identity (real path): one folder spelled two
        -- ways is one batch.
        local norm = ws and ws._build_dir_identity and function(p) return ws:_build_dir_identity(p) end
            or (ws and ws._core and ws._core._deps and ws._core._deps.normalize)
        for _, td in ipairs(tasks) do
            local lw = td.loomworks
            if norm and lw and lw.wipe_build_dir and lw.unit
                    and type(lw.build_dir) == "string" and lw.build_dir ~= "" then
                local key = norm(lw.build_dir)
                local g = groups[key]
                if not g then g = { units = {} }; groups[key] = g end
                g.units[#g.units + 1] = lw.unit
                wipe_group[td] = g
            end
        end
    end

    local task_futures = {}
    for _, task_def in ipairs(tasks) do
        local tf = future_mod.create(function(resolve, reject, token)
            if task_def.loomworks and task_def.loomworks.wipe_build_dir then
                local g = wipe_group[task_def]
                local wf
                if g then
                    g.future = g.future or wipe_build_dir(ws, task_def, g.units)
                    wf = g.future
                else
                    wf = wipe_build_dir(ws, task_def)
                end
                wf
                    :next(function() resolve(true) end)
                    :catch(function(e)
                        local msg = "loomworks: " .. (task_def.name or "clean") .. ": " .. tostring(e)
                        vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                        reject(msg)
                    end)
                return
            end
            local build_result, h_err = harden(task_def.builder())
            if not build_result then
                local msg = "loomworks: " .. (task_def.name or "clean") .. ": " .. tostring(h_err)
                vim.schedule(function() vim.notify(msg, vim.log.levels.ERROR) end)
                reject(msg)
                return
            end
            apply_nice(build_result, "clean")
            build_result.components = build_result.components or { "default" }
            build_result.name = task_def.name
            local task = overseer.new_task(build_result)
            token:on_cancel(function()
                if task and not task:is_complete() then task:stop() end
            end)
            task:subscribe("on_complete", function(_, status)
                if status == "SUCCESS" then
                    record_module_clean(ws, task_def.loomworks and task_def.loomworks.unit)
                    resolve(true)
                else reject("clean task failed") end
            end)
            task:start()
        end)
        task_futures[#task_futures + 1] = tf
    end

    local f = future_mod.when_all_settled(task_futures):next(function(results)
        local all_ok = true
        for _, r in ipairs(results) do
            if not r.ok then all_ok = false; break end
        end
        if not all_ok then
            error(refused and ("clean failed\n" .. M.refused_message(refused)) or "clean failed", 0)
        end
        if refused then
            if refused_ok then return refused end
            error(M.refused_message(refused), 0)
        end
        return true
    end)

    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
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

local in_process_single_task

--- Launch a single task definition via overseer. Returns a Future.
--- Used by ConfigUnit:build_target for per-target builds.
--- @param task_def table task definition with .builder and .loomworks
--- @param unit loomworks.ConfigUnit the configuration unit being built
--- @param on_complete? function legacy callback (deprecated)
--- @return loomworks.Future
function M.launch_single_task(task_def, unit, on_complete)
    -- No `daemon`-mode refusal here (there was one before step 6b-α): this
    -- runs in-process unconditionally, which is safe ONLY because a
    -- `daemon`-mode editor holds no model and so has no unit to pass in.
    -- Should that editor ever hold one again, refuse here (§19.16
    -- "Availability": never run in-process in `daemon` mode).
    return in_process_single_task(task_def, unit, on_complete)
end

--- The in-process single-task build (launch_single_task).
in_process_single_task = function(task_def, unit, on_complete)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("overseer.nvim not found")
    end

    local state = unit:local_state()
    if state == "unknown" or state == "building" then
        if on_complete then vim.schedule(function() on_complete(false) end) end
        return future_mod.rejected("unit in " .. state .. " state")
    end

    if task_def.loomworks then
        task_def.loomworks.unit = unit
    end

    local f = start_one_task(overseer, task_def)
    if on_complete then
        f:next(function() on_complete(true) end)
         :catch(function() on_complete(false) end)
    end
    return f
end

--- Collect ConfigUnits and their target states from task definitions.
--- @param task_defs table[] task definitions with .loomworks
--- @param target_state string target ConfigUnit state (e.g. "configured", "built")
--- @return loomworks.ConfigUnit[] units
--- @return table<loomworks.ConfigUnit, string> target_states
local function collect_units_from_tasks(task_defs, target_state)
    local units = {}
    local target_states = {}
    local seen = {} -- unit -> true (dedup by identity)
    for _, task_def in ipairs(task_defs) do
        local meta = task_def.loomworks
        if meta and meta.unit and not seen[meta.unit] then
            seen[meta.unit] = true
            units[#units + 1] = meta.unit
            target_states[meta.unit] = target_state
        end
    end
    return units, target_states
end

local in_process_profile_action

--- Run all tasks of a given action for a profile. Returns a Future.
--- Creates an Operation to track progress and completion.
--- @param profile loomworks.Profile
--- @param action string "configure" or "build"
--- @param opts? table { parallel_jobs?: integer }
--- @return loomworks.Future
function M.run_profile_action(profile, action, opts)
    -- A `daemon`-mode editor holds no model, but its getters hand out the
    -- view rows (`lw.get_active_profile()`, §19.16 "Public API"): a row passed
    -- here is refused, never run in-process (§19.16 "Availability"). Its
    -- build is `lw.build_profile()` (Build/1.build by id).
    if require("loomworks.daemon.editor_ops").daemon_of(nil) then
        local msg = "run_profile_action is not available with the workspace daemon — use lw.build_profile()"
        vim.notify("loomworks: " .. msg, vim.log.levels.ERROR)
        return require("loomworks.future").rejected(msg)
    end
    return in_process_profile_action(profile, action, opts)
end

--- The in-process profile build / configure (run_profile_action).
in_process_profile_action = function(profile, action, opts)
    local future_mod = require("loomworks.future")

    local ok, overseer = pcall(require, "overseer")
    if not ok then
        vim.notify("loomworks: overseer.nvim not found", vim.log.levels.ERROR)
        return future_mod.rejected("overseer.nvim not found")
    end

    local loomworks = require("loomworks")
    local f = future_mod.Future.new()

    local function do_action()
        local ws = loomworks.get_workspace()
        local log = ws and ws._core and ws._core._deps.log
        if log then log:debug("run_profile_action: %s for profile '%s'", action, profile.key) end

        local all_tasks = collect_profile_tasks(profile)
        if not all_tasks then
            if log then log:warn("run_profile_action: no tasks collected for profile '%s'", profile.key) end
            f:_reject("no tasks")
            return
        end
        -- Invalid ProfileProjects (core §5.4) are not run: the operation
        -- counts them finished and failed, and the action fails once the
        -- other projects ran.
        local refused = all_tasks.refused or {}
        local function settle_ok()
            if #refused > 0 then
                f:_reject(table.concat(refused, "\n"))
            else
                f:_resolve(true)
            end
        end

        -- Apply parallel_jobs override: wrap build task builders to append -jN
        if opts and opts.parallel_jobs then
            local jobs = tostring(opts.parallel_jobs)
            for _, task_def in ipairs(all_tasks.build or {}) do
                local orig_builder = task_def.builder
                task_def.builder = function()
                    local result = orig_builder()
                    result.cmd = M.append_parallel_jobs(result.cmd or {}, jobs)
                    return result
                end
            end
        end

        if log then
            local n_conf = all_tasks.configure and #all_tasks.configure or 0
            local n_build = all_tasks.build and #all_tasks.build or 0
            log:debug("run_profile_action: %d configure, %d build tasks for '%s'", n_conf, n_build, profile.key)
        end

        if action == "configure" then
            -- Explicit profile configure (spec §5.1): runs configure for every
            -- unit of the profile, including ones already configured. Only the
            -- configured-skip is lifted — a unit in unknown state is still
            -- blocked (clean/delete first). Only the build's automatic
            -- configure (§5.2) skips configured units.
            local readiness_opts = { explicit_configure = true }
            local launchable = filter_launchable_tasks(all_tasks.configure, readiness_opts)
            local units, target_states = collect_units_from_tasks(launchable, "configured")
            -- The operation tracks this run's own configure tasks, not unit
            -- state: a configure queued behind a build-dir lock (a running
            -- build, an earlier configure) must not count as done when the
            -- unit reaches `built`/`configured` through that other task.
            local op
            if #units > 0 or #refused > 0 then
                op = loomworks.create_operation(profile, "configure", units, target_states,
                    { track_tasks = true, refused = refused })
            end
            local pending, unit_ok = {}, {}
            for _, task_def in ipairs(launchable) do
                local u = task_def.loomworks.unit
                pending[u] = (pending[u] or 0) + 1
                if unit_ok[u] == nil then unit_ok[u] = true end
            end
            readiness_opts.on_task_settled = function(task_def, task_ok)
                local u = task_def.loomworks.unit
                if not pending[u] then return end
                if not task_ok then unit_ok[u] = false end
                pending[u] = pending[u] - 1
                if pending[u] == 0 then
                    pending[u] = nil
                    if op then op:unit_finished(u, unit_ok[u]) end
                end
            end
            launch_tasks(overseer, all_tasks.configure, nil, readiness_opts):next(
                settle_ok,
                function(err) f:_reject(err) end
            )
            return
        end

        if action == "build" then
            local force = opts and opts.force or false
            local needs_configure = filter_unconfigured_tasks(all_tasks)
            local launchable_builds = filter_launchable_tasks(all_tasks.build)
            local units, target_states = collect_units_from_tasks(launchable_builds, "built")

            if #needs_configure > 0 then
                local configure_units = collect_units_from_tasks(needs_configure, "built")
                for _, u in ipairs(configure_units) do
                    if not target_states[u] then
                        units[#units + 1] = u
                        target_states[u] = "built"
                    end
                end

                local op
                if #units > 0 or #refused > 0 then
                    op = loomworks.create_operation(profile, "configure+build", units, target_states,
                        { refused = refused })
                end

                launch_tasks(overseer, needs_configure):next(function()
                    -- Configure done → build units' artifact sets are known;
                    -- gate before compile (spec §5.9).
                    return guard_build_conflicts(ws, all_tasks.build, force)
                end):next(function()
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    settle_ok,
                    function(err)
                        if op and not op.completed then
                            op:cancel(tostring(err))
                        end
                        f:_reject(err)
                    end
                )
            else
                guard_build_conflicts(ws, all_tasks.build, force):next(function()
                    if #units > 0 or #refused > 0 then
                        loomworks.create_operation(profile, "build", units, target_states,
                            { refused = refused })
                    end
                    return launch_tasks(overseer, all_tasks.build)
                end):next(
                    settle_ok,
                    function(err) f:_reject(err) end
                )
            end
            return
        end

        vim.notify("loomworks: unknown action '" .. action .. "'", vim.log.levels.ERROR)
        f:_reject("unknown action: " .. action)
    end

    if loomworks.has_pending_deletions() then
        vim.notify("loomworks: waiting for pending deletion to finish...", vim.log.levels.INFO)
        loomworks.after_deletions(do_action)
    else
        do_action()
    end

    return f
end

return M
