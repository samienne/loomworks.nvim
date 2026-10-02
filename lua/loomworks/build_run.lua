--- loomworks/build_run.lua — the headless profile-build step logic used by
--- the in-process `lw build` (cli.lua `run_build_steps`). It is kept free of
--- terminal I/O and process exit so another runner (the planned workspace
--- daemon, which spawns asynchronously and streams) can drive the SAME steps:
---
---   lock every build dir → plan (gate + module plan + build request)
---   → per step: before_step (conflict gate, full-reconfigure reset)
---               step_lines (announce, why, log the command line)
---               spawn_spec (hardened argv + env) → run
---               after_step (record result, populate artifacts)
---               failure_message on a nonzero exit (exit_status: a step a
---               signal ended is a failure, status 128 + signal)
---
--- A runner differs only in HOW a step is spawned (blocking vs streamed) and
--- how a refusal is reported (die vs a streamed error). Everything here returns
--- values/errors instead of exiting; nothing here touches the terminal. Spec
--- §16.4 (build), §5.9/§16.28 (artifact conflicts), §5.1/§8.1 (configure
--- record, full reconfigure), §5.10 (program resolution).

local M = {}

-- ---------------------------------------------------------------------------
-- Profile resolution (§16.9) — host-neutral: every refusal is returned as the
-- exact message the CLI prints (`lw: <message>`, exit 1), so the in-process
-- host and the workspace daemon (§19.15) refuse identically.
-- ---------------------------------------------------------------------------

--- The stable positional numbering of profiles (sorted by key, 1..N) — the
--- numbers every listing shows and a bare-integer argument selects.
--- @param ws table
--- @return table[] list
function M.profile_order(ws)
    local list = {}
    for _, p in ipairs(ws._profiles or {}) do list[#list + 1] = p end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

--- The single NAMED-profile matcher: a bare integer is the stable positional
--- index (unless `opts.no_number`), then the exact key, then an unambiguous
--- boundary-anchored substring (`merge.match_profile`). Returns the profile,
--- nil on a miss, or nil + the refusal (number out of range, ambiguous).
--- @param ws table
--- @param name string
--- @param opts? { no_number?: boolean }
--- @return table|nil profile, string|nil err
function M.match_profile(ws, name, opts)
    if not (opts and opts.no_number) and type(name) == "string" and name:match("^%d+$") then
        local list = M.profile_order(ws)
        local n = tonumber(name)
        if n < 1 or n > #list then
            return nil, "profile number " .. n .. " out of range (1.." .. #list .. "); see `lw profile list`"
        end
        return list[n]
    end
    local keys, by_key = {}, {}
    for _, p in ipairs(ws._profiles or {}) do keys[#keys + 1] = p.key; by_key[p.key] = p end
    local hit, ambiguous = require("loomworks.merge").match_profile(keys, name)
    if hit then return by_key[hit] end
    if ambiguous then
        return nil, "'" .. name .. "' matches multiple profiles: " .. table.concat(ambiguous, ", ")
    end
    return nil
end

--- Resolve the profile a command operates on: the named one, else — only when
--- interactive — the active profile, else the only one. Non-interactive mode
--- never uses the active profile nor infers one (a deterministic CI result).
--- Returns the profile or nil + the refusal.
--- @param ws table
--- @param name string|nil
--- @param opts? { no_number?: boolean, usage?: string, interactive?: boolean }
--- @return table|nil profile, string|nil err
function M.resolve_profile(ws, name, opts)
    opts = opts or {}
    local profiles = ws._profiles or {}
    if name then
        local hit, err = M.match_profile(ws, name, opts)
        if err then return nil, err end
        if hit then return hit end
        return nil, "no profile matching '" .. name .. "'. Run `lw profile list` to list."
    end
    if not opts.interactive then
        local keys = {}
        for _, p in ipairs(profiles) do keys[#keys + 1] = p.key end
        table.sort(keys)
        return nil, "no profile specified — non-interactive mode never uses the active profile\n" ..
            "  and never infers one (not even when only one profile exists).\n" ..
            "  pass one explicitly (a unique substring works): " ..
            (opts.usage or "lw <command> <profile>") .. "\n" ..
            "  profiles: " .. (next(keys) and table.concat(keys, ", ") or "(none — `lw profile create`)") .. "\n" ..
            "  scripts: `lw profile query <profile> <project> <field>` resolves keys deterministically"
    end
    local active = ws._active_profile_key
    if active then
        for _, p in ipairs(profiles) do
            if p.key == active then return p end
        end
    end
    if #profiles == 1 then return profiles[1] end
    return nil, "no profile specified and no unambiguous default — run `lw profile select`"
end

--- Resolve the profile a build (and clean / test / reset / run) targets
--- (§16.9). Returns the profile; or nil + the refusal; or nil, nil, "onboard"
--- when no profile matches and the caller is interactive — the host then
--- onboards a profile from a configuration set (prompts; never in a daemon).
--- @param ws table
--- @param name string|nil
--- @param opts? { usage?: string, interactive?: boolean }
--- @return table|nil profile, string|nil err, string|nil action
function M.resolve_target(ws, name, opts)
    opts = opts or {}
    local profiles = ws._profiles or {}
    local usage = opts.usage or "lw build <profile>"
    -- A concrete profile match always wins; a miss falls through to the
    -- configuration-set onboarding / non-interactive refusal below.
    if name then
        local hit, err = M.match_profile(ws, name)
        if err then return nil, err end
        if hit then return hit end
    else
        if not opts.interactive then return M.resolve_profile(ws, nil, { usage = usage }) end
        local active = ws._active_profile_key
        if active then for _, p in ipairs(profiles) do if p.key == active then return p end end end
        if #profiles == 1 then return profiles[1] end
        if #profiles > 1 then
            return nil, "no profile specified and no active default — `lw profile select`, or `" .. usage .. "`"
        end
    end
    if not opts.interactive then
        if name then
            for _, s in ipairs(ws._config_sets or {}) do
                if s.name == name then
                    return nil, "'" .. name .. "' is a configuration set with no profile yet — " ..
                        "create one:\n  lw profile create " .. name .. " <tool> --activate   " ..
                        "(tools: `lw tools`)\n  then: lw build"
                end
            end
        end
        return M.resolve_profile(ws, name, { usage = usage })
    end
    return nil, nil, "onboard"
end

--- Build directories in the canonical lock order of spec §19.3: by
--- normalized path (§2.3 normalization: forward slashes, no trailing slash,
--- lowercased on Windows), duplicates dropped.
--- @param dirs string[]
--- @return string[]
function M.lock_order(dirs)
    local win = package.config:sub(1, 1) == "\\"
    local seen, keyed = {}, {}
    for _, d in ipairs(dirs or {}) do
        local k = d:gsub("\\", "/"):gsub("/+$", "")
        if win then k = k:lower() end
        if not seen[k] then seen[k] = true; keyed[#keyed + 1] = { k = k, d = d } end
    end
    table.sort(keyed, function(a, b) return a.k < b.k end)
    local out = {}
    for _, e in ipairs(keyed) do out[#out + 1] = e.d end
    return out
end

--- The distinct build directories a profile's projects map to — the set the
--- per-build-directory advisory lock (§16.6) covers for one build.
--- @param profile loomworks.Profile
--- @return string[]
function M.profile_build_dirs(profile)
    local dirs, seen = {}, {}
    for _, pp in ipairs(profile:projects()) do
        local bd = pp.build_dir and pp:build_dir()
        if bd and not seen[bd] then seen[bd] = true; dirs[#dirs + 1] = bd end
    end
    return dirs
end

--- The one notice a build prints when loomworks.json program settings of the
--- profile's projects are ignored (spec §17.6, §17.10), or nil when none are.
--- Both hosts print it (in-process and through the daemon, §19.15), so a
--- build never silently runs without an environment or command the shared
--- file names. Counts workspace-level entries and those of the profile's
--- projects.
--- @param ws table workspace
--- @param profile table
--- @return string|nil line
function M.trust_notice(ws, profile)
    if not (ws and ws.ignored_program_settings) then return nil end
    local keys = {}
    for _, pp in ipairs(profile and profile:projects() or {}) do
        if pp._project then keys[pp._project.key] = true end
    end
    local n = 0
    for _, e in ipairs(ws:ignored_program_settings()) do
        if e.project == nil or keys[e.project] then n = n + 1 end
    end
    if n == 0 then return nil end
    return string.format("lw: %d program setting%s in loomworks.json ignored — only your local config "
        .. "may name programs or environment (`lw status` lists %s; lw help trust)",
        n, n == 1 and "" or "s", n == 1 and "it" or "them")
end

--- Whether `cmd` runs a batch file through cmd.exe: the program the build
--- really runs is inside the batch, so arguments appended to this argv never
--- reach it. Recognizes a literal batch path (`cmd /C <x.bat>`) and a program
--- named only by a variable reference cmd.exe expands (`!VAR!` / `%VAR%`) —
--- the cmake vcvarsall wrapper's `cmd /d /v:on /c !LOOMWORKS_VCVARS_BAT!`
--- form. An argv whose real program cmd.exe substitutes cannot be extended
--- safely either way, so it is treated as a batch (refuse, never drop args).
--- @param cmd string[]
--- @return boolean
function M.runs_batch_file(cmd)
    local prog = type(cmd) == "table" and type(cmd[1]) == "string"
        and (cmd[1]:match("([^/\\]+)$") or ""):lower() or ""
    if prog ~= "cmd" and prog ~= "cmd.exe" then return false end
    for i = 2, #cmd do
        local a = tostring(cmd[i]):lower()
        if a:match("%.bat$") or a:match("%.cmd$") then return true end
        if a:match("^!.+!$") or a:match("^%%.+%%$") then return true end
    end
    return false
end

--- The output-artifact conflict refusal (spec §5.9 / §16.28): names the
--- conflicting profile and the shared artifact path, and points at `--force`.
--- @param block { profile: string, path: string|nil }
--- @return string
function M.conflict_message(block)
    return string.format(
        "build would overwrite an artifact owned by built profile '%s':\n"
            .. "      %s\n"
            .. "    pass --force to overwrite it (%s will be marked stale)",
        block.profile, block.path or "?", block.profile)
end

--- The refusal for a profile with no buildable step.
--- @param profile loomworks.Profile
--- @return string
function M.nothing_to_build_message(profile)
    return "nothing to build for profile '" .. profile.key ..
        "' — no buildable projects (unavailable module or unresolved tool?)"
end

-- ---------------------------------------------------------------------------
-- Target operands (headless §16.4 *Naming a build target*) — shared by every
-- runner (in-process `lw build`, the workspace daemon §19.15) through `plan`,
-- and by the launch-target matchers (`lw run`, `lw test --target`, `lw target
-- set`) through `split_target_ref`.
-- ---------------------------------------------------------------------------

--- Up to three of `candidates` close to `name` (case-insensitive substring
--- either way, or a small edit distance), nearest first.
--- @param name string
--- @param candidates string[]
--- @return string[]
function M.close_matches(name, candidates)
    local function dist(a, b)
        local prev = {}
        for j = 0, #b do prev[j] = j end
        for i = 1, #a do
            local cur = { [0] = i }
            for j = 1, #b do
                local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
                cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            end
            prev = cur
        end
        return prev[#b]
    end
    local lname, limit = name:lower(), math.max(1, math.floor(#name / 3))
    local scored = {}
    for _, c in ipairs(candidates) do
        local lc = c:lower()
        local d = dist(lname, lc)
        if d <= limit or lc:find(lname, 1, true) or lname:find(lc, 1, true) then
            scored[#scored + 1] = { name = c, d = d }
        end
    end
    table.sort(scored, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(3, #scored) do out[i] = scored[i].name end
    return out
end

--- Ensure a config unit's build targets are parsed — the headless equivalent
--- of the editor's post-configure scan (workspace.lua). No-op if already
--- parsed (unless `opts.refresh`: re-read, e.g. in a long-lived daemon whose
--- unit outlived a configure) or the module exposes no target introspection.
--- Requires a build dir this machine configured.
--- @param ws loomworks.Workspace
--- @param unit loomworks.ConfigUnit|nil
--- @param opts? { refresh?: boolean }
function M.ensure_unit_targets(ws, unit, opts)
    if not unit or (unit.targets and not (opts and opts.refresh)) then return end
    local project = unit._project
    local mod = project and project._module and project._module.impl
    local build_dir = unit.build_dir and unit:build_dir()
    if not (mod and mod.parse_targets and build_dir) then return end
    -- Only a build dir this machine configured (signed cache, spec §17.8).
    if unit.configured_here and not unit:configured_here() then return end
    -- config_name is the module build type (e.g. "Debug"); matters for
    -- multi-config generators, ignored by single-config ones.
    local cfg = unit.configuration and unit:configuration()
    local config_name = (cfg and cfg.module_config and cfg.module_config.variant)
        or (unit._cached_module_config and unit._cached_module_config.variant)
        or (unit.variant and unit:variant())
    local ok, targets = pcall(mod.parse_targets, {
        build_dir = build_dir,
        project_path = ws.root .. "/" .. (project.path or project.key),
        config_name = config_name,
    })
    if ok and targets then unit:set_targets(targets) end
end

--- Split a target operand into the profile project it is qualified with and
--- the bare name. `<project>:<name>` (the form `lw target` lists) is qualified
--- only when `<project>` names one of the profile's projects — a module's own
--- target syntax may contain ':' (e.g. meson `name:type`); otherwise the whole
--- operand is the bare name.
--- @param profile loomworks.Profile
--- @param name string
--- @return loomworks.Project|nil project, string bare
function M.split_target_ref(profile, name)
    local pfx, rest = name:match("^([^:]+):(.+)$")
    if pfx then
        for _, pp in ipairs(profile:projects()) do
            if pp._project and pp._project.key == pfx then return pp._project, rest end
        end
    end
    return nil, name
end

--- Resolve `--target` operands to the projects that build them (§16.4), against
--- each project's KNOWN target list — a unit configured here that needs no
--- configure now (a configure can change its targets) and whose module
--- introspects targets. A qualified operand goes to its project; a bare name
--- to the one project whose list has it (several → refused as ambiguous), or,
--- in no known list, to every project (the build tool decides). Returns a map
--- Project → bare target names (projects absent from it are not built), or
--- nil + lw's refusal. Never runs anything.
--- @param profile loomworks.Profile
--- @param names string[]
--- @param opts? { reconfigure?: boolean }
--- @return table<loomworks.Project, string[]>|nil picks, string|nil err
function M.resolve_build_targets(profile, names, opts)
    opts = opts or {}
    local ws = profile._workspace
    local entries = {}
    for _, pp in ipairs(profile:projects()) do
        local unit, project = pp._config_unit, pp._project
        if project then
            local known
            if unit and not opts.reconfigure and unit.configure_reason
                    and not unit:configure_reason(false, profile, false) then
                if ws then pcall(M.ensure_unit_targets, ws, unit, { refresh = true }) end
                if type(unit.targets) == "table" and next(unit.targets) then known = unit.targets end
            end
            entries[#entries + 1] = { project = project, known = known }
        end
    end
    local picks = {}
    local function add(project, t)
        local list = picks[project]
        if not list then list = {}; picks[project] = list end
        for _, x in ipairs(list) do if x == t then return end end
        list[#list + 1] = t
    end
    for _, name in ipairs(names) do
        local qproj, bare = M.split_target_ref(profile, name)
        if qproj then
            -- Scoped to that project even when its list lacks the name (a
            -- target lw does not list); the build tool decides.
            add(qproj, bare)
        else
            local hits = {}
            for _, e in ipairs(entries) do
                if e.known and e.known[bare] then hits[#hits + 1] = e end
            end
            if #hits > 1 then
                local labels = {}
                for _, e in ipairs(hits) do labels[#labels + 1] = e.project.key .. ":" .. bare end
                return nil, string.format("target '%s' is ambiguous — it is a build target of several "
                    .. "projects: %s\n  qualify it as <project>:<target>", bare, table.concat(labels, ", "))
            elseif #hits == 1 then
                add(hits[1].project, bare)
            else
                -- In no known list (a custom / build-system target such as
                -- `install`, a project not configured yet, or a typo): every
                -- project gets it, as a plain `--target` always did; the
                -- build tool decides and a failure names close matches.
                for _, e in ipairs(entries) do add(e.project, bare) end
            end
        end
    end
    return picks
end

--- After a failed `--target` build: name each target this step requested
--- that its project's parsed target list does not contain, with close matches
--- from every project of the profile, in the `<project>:<target>` form `lw
--- target` lists (§16.4). Advisory: the lists omit targets a module does not
--- introspect, so such a name was handed to the build tool, which decided.
--- `targets` are the bare names the step built (`step.build_targets` when
--- planned). nil when there is nothing to say.
--- @param ws loomworks.Workspace
--- @param step table
--- @param targets? string[]
--- @return string|nil
function M.unknown_target_hint(ws, step, targets)
    targets = step.build_targets or targets
    if not (targets and step.unit) then return nil end
    local units = { step.unit }
    if step.profile and step.profile.projects then
        units = {}
        for _, pp in ipairs(step.profile:projects()) do
            if pp._config_unit then units[#units + 1] = pp._config_unit end
        end
    end
    local cands, ids, seen = {}, {}, {}
    for _, u in ipairs(units) do
        pcall(M.ensure_unit_targets, ws, u, { refresh = true })
        local proj = u._project
        if type(u.targets) == "table" and proj then
            for id in pairs(u.targets) do
                cands[#cands + 1] = { project = proj, id = id }
                if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
            end
        end
    end
    local known = step.unit.targets
    if type(known) ~= "table" or not next(known) then return nil end
    table.sort(ids)
    table.sort(cands, function(x, y)
        if x.project.key ~= y.project.key then return x.project.key < y.project.key end
        return x.id < y.id
    end)
    local lines = {}
    local project = step.unit._project and step.unit._project.key or "the project"
    for _, t in ipairs(targets) do
        if not known[t] then
            local near = {}
            for _, b in ipairs(M.close_matches(t, ids)) do
                for _, c in ipairs(cands) do
                    if c.id == b then near[#near + 1] = c.project.key .. ":" .. c.id end
                end
            end
            lines[#lines + 1] = string.format("target '%s' is not among %s's known targets%s", t,
                project, #near > 0 and (" — did you mean '" .. table.concat(near, "', '") .. "'?") or "")
        end
    end
    return #lines > 0 and table.concat(lines, "\nlw: ") or nil
end

--- Plan a profile build: the build gate, the module plan, and the build
--- request (core §8.1 / §16.4) checked for every build step before anything
--- runs. A module that applied the request already put it on its native
--- command; for one that did not, `--target` is refused (no generic way to
--- select a target) and forwarded args are appended to the step's command —
--- unless that command runs a batch file, where they would be silently
--- ignored, so it is refused instead.
--- @param profile loomworks.Profile
--- @param opts? { for_test?: boolean, reconfigure?: boolean, extra_args?: string[], build_targets?: string[] }
---   build_targets are the caller's `--target` operands, resolved per
---   project by `resolve_build_targets`; each build step carries the bare
---   names it builds as `step.build_targets`.
--- @return table[]|nil steps (possibly empty), string|nil err
function M.plan(profile, opts)
    opts = opts or {}
    -- Same gate the editor applies in `Profile:build` / `Profile:configure`:
    -- without it an unbuildable profile — e.g. one mapping an abstract
    -- configuration — would build anyway, on whatever default the module picked.
    if profile.assert_buildable then
        local buildable, why = profile:assert_buildable()
        if not buildable then return nil, tostring(why) end
    end
    -- `--target` operands resolve to (project, bare name) BEFORE anything
    -- runs (§16.4): a refusal is lw's, never the build tool's; a project no
    -- operand selects is neither configured nor built.
    local picks
    if opts.build_targets and profile.projects then
        local perr
        picks, perr = M.resolve_build_targets(profile, opts.build_targets, { reconfigure = opts.reconfigure })
        if not picks then return nil, perr end
    end
    local steps, plan_err = require("loomworks.overseer").plan_profile_build(profile, {
        for_test = opts.for_test,
        reconfigure = opts.reconfigure,
        build_args = opts.extra_args,
        build_targets = opts.build_targets,
        build_targets_for = picks,
    })
    if plan_err then return nil, "cannot build: " .. tostring(plan_err) end
    steps = steps or {}
    for _, step in ipairs(steps) do
        if step.kind == "build" then
            -- The bare names this step builds (the failure hint's input).
            local project = step.unit and step.unit._project
            step.build_targets = (picks and project and picks[project]) or opts.build_targets
            if opts.build_targets and not step.applied_build_targets then
                return nil, string.format("%s: this project's module does not support --target "
                    .. "(pass the build tool's own target syntax after `--` instead)", step.name or "?")
            end
            if opts.extra_args and not step.applied_build_args then
                if M.runs_batch_file(step.cmd) then
                    return nil, string.format("%s: cannot forward build-tool args — the module runs "
                        .. "its build through a batch file and does not accept build args", step.name or "?")
                end
                step.cmd = vim.list_extend(vim.list_extend({}, step.cmd), opts.extra_args)
            end
        end
    end
    return steps
end

--- The gates evaluated immediately before a step runs (after recording the
--- step in this process's build-directory lock, spec §19.5):
---   * the output-artifact conflict gate (§5.9 / §16.28), directional and
---     evaluated at compile-start — for a configure→build chain the configure
---     (after_step) already populated this unit's artifact set. `force` is the
---     only bypass, never a prompt;
---   * a full reconfigure's module-named configure-state reset (core §5.1 /
---     §8.1 `pre_configure_reset`) — validated + deleted by core, under the
---     build-dir lock the runner already holds.
--- @param ws loomworks.Workspace
--- @param step table
--- @param opts? { force?: boolean }
--- @return boolean|nil ok, string|nil err
function M.before_step(ws, step, opts)
    opts = opts or {}
    -- The held build-dir lock names the step now running, so a recovery after
    -- this process dies knows what was interrupted (spec §19.5).
    if step.kind == "configure" or step.kind == "build" then
        require("loomworks.build_lock").set_operation(step.build_dir, step.kind)
    end
    if step.kind == "build" and step.unit and ws.artifact_conflict_block then
        local block = ws:artifact_conflict_block(step.unit, opts.force or false)
        if block then return nil, M.conflict_message(block) end
    end
    if step.kind == "configure" and type(step.pre_configure_reset) == "table"
            and #step.pre_configure_reset > 0 then
        local ok_r, r_err = ws:_pre_configure_reset(step.build_dir, step.pre_configure_reset)
        if not ok_r then return nil, tostring(r_err) end
    end
    return true
end

--- The status lines announcing a step (§16.4): `==> [kind] name`, WHY a
--- configure runs (the gate's reason + the module's full / in-place choice),
--- and with `verbose` the command line + cwd. Also writes the command line to
--- the workspace log (always, §16.4).
--- @param ws loomworks.Workspace
--- @param step table
--- @param opts? { verbose?: boolean }
--- @return string[] lines (no trailing newlines)
function M.step_lines(ws, step, opts)
    opts = opts or {}
    local overseer = require("loomworks.overseer")
    local lines = { string.format("==> [%s] %s", step.kind, step.name or "?") }
    if step.kind == "configure" then
        local why = overseer.configure_reason_line(step)
        if why then lines[#lines + 1] = "    " .. why end
    end
    local cwd = step.cwd or ws.root
    overseer.log_task_command(ws, step.name, step, cwd)
    if opts.verbose then
        lines[#lines + 1] = "    $ " .. overseer.command_text(step)
        lines[#lines + 1] = "    (in " .. tostring(cwd) .. ")"
    end
    return lines
end

--- The spawnable form of a step: the program resolved to an absolute path
--- (never the cwd / a relative PATH entry) and, on Windows,
--- NoDefaultCurrentDirectoryInExePath=1 in the child env (spec §5.10). An
--- unresolvable program is reported, never spawned by name. An empty env is
--- dropped (it would wipe PATH; the child inherits the parent env instead).
--- @param step table { cmd, cwd?, env? }
--- @param root string the workspace root (default cwd)
--- @return { cmd: string[], cwd: string, env: table|nil }|nil spec, string|nil err
function M.spawn_spec(step, root)
    local hardened, herr = require("loomworks.exe").harden_spec({ cmd = step.cmd, env = step.env })
    if not hardened then return nil, "cannot run step: " .. tostring(herr) end
    local env = (hardened.env and next(hardened.env)) and hardened.env or nil
    return { cmd = hardened.cmd, cwd = step.cwd or root, env = env }
end

--- Persist a headless step's outcome (state + config snapshot for staleness)
--- to the cache via Workspace:record_task_result, so a later invocation skips
--- an already-done, unchanged configure. build_dir is set on the unit but not
--- passed as result.build_dir (that triggers the post-configure parse_targets
--- scan the headless runners opt out of).
--- @param ws loomworks.Workspace
--- @param step table
--- @param ok boolean
function M.record(ws, step, ok)
    if not step.unit then return end
    if step.build_dir then step.unit.build_dir_value = step.build_dir end
    pcall(function()
        -- Pass the module's configure record (cache_launcher, passed_options, …)
        -- exactly like the editor's task path, so launcher staleness and the
        -- faithful-reconfigure retraction (core §5.1) work for headless
        -- configures too.
        ws:record_task_result({
            unit = step.unit, action = step.kind, success = ok,
            module_info = step.module_info,
            -- The profile being built: the snapshot is taken in its context.
            profile = step.profile,
        })
    end)
end

--- After a step exits: record its result, and after a successful configure
--- populate this unit's resolved artifact set so a following build step in
--- THIS run sees it (the headless runners opt out of the record_task_result
--- post-configure scan by not passing build_dir).
--- @param ws loomworks.Workspace
--- @param step table
--- @param code integer
function M.after_step(ws, step, code)
    M.record(ws, step, code == 0)
    if step.kind == "configure" and code == 0 and step.unit and step.build_dir
            and ws._populate_resolved_artifacts then
        pcall(function()
            ws:_populate_resolved_artifacts(step.unit, step.build_dir, step.unit._variant)
        end)
    end
end

--- Names of the signals whose numbers are the same on Linux and macOS.
M.SIGNAL_NAMES = {
    [1] = "SIGHUP", [2] = "SIGINT", [3] = "SIGQUIT", [4] = "SIGILL", [5] = "SIGTRAP",
    [6] = "SIGABRT", [8] = "SIGFPE", [9] = "SIGKILL", [11] = "SIGSEGV", [13] = "SIGPIPE",
    [14] = "SIGALRM", [15] = "SIGTERM",
}

--- A step's exit status from libuv's exit callback `(code, signal)` (§16.7).
--- On POSIX a process that a signal ended (the OOM killer, `kill -9` on the
--- build tool) is reported as code 0 + the signal: that is a FAILURE, with the
--- conventional status 128 + signal — never a success. Returns the status and,
--- when a signal ended the process, that signal. A status already mapped
--- (128 + signal: the standalone shim's vim.system, Neovim's jobs) is kept.
--- Windows has no such signals: libuv reports the exit code with signal 0,
--- except for its own emulated kills (TerminateProcess: exit code 1 + the
--- signal sent), which keep their exit code, as before.
--- @param code integer|nil
--- @param signal integer|nil
--- @return integer status, integer|nil signal
function M.exit_status(code, signal)
    code = tonumber(code) or 0
    signal = tonumber(signal) or 0
    if signal ~= 0 and (code == 0 or code == 128 + signal) then return 128 + signal, signal end
    return code
end

--- How a step ended, for its failure line: `exit <code>`, or `killed by
--- signal <n> (<NAME>)` when a signal ended it (`signal` from exit_status).
--- @param code integer
--- @param signal? integer
--- @return string
function M.exit_text(code, signal)
    if signal and signal ~= 0 then
        local name = M.SIGNAL_NAMES[signal]
        return "killed by signal " .. signal .. (name and (" (" .. name .. ")") or "")
    end
    return "exit " .. tostring(code)
end

--- The line reporting a step whose resolved program could not be started
--- (the spawn itself failed) — the same on every host; the step then fails
--- with status 127.
--- @param exe string
--- @param err any
--- @return string
function M.spawn_failure_line(exe, err)
    return "lw: cannot start " .. tostring(exe) .. ": " .. tostring(err)
end

--- The failure line for a step that exited nonzero. A build that fails after
--- the post-configure scan predicted it (an error-severity cache-compat
--- finding, e.g. /Zi under sccache) closes with one line pointing back at that
--- finding — advisory: the scan never gates the build (§5.1). `extra_hint`
--- (e.g. an unknown `--target`) leads the hint lines. `signal` (from
--- exit_status): the signal that ended the step, named instead of the code.
--- @param step table
--- @param code integer
--- @param extra_hint? string
--- @param signal? integer
--- @return string
function M.failure_message(step, code, extra_hint, signal)
    local hint
    if step.kind == "build" and step.unit and step.unit.module_info then
        hint = require("loomworks.compiler_cache").compat_failure_hint(
            step.unit.module_info.cache_compat)
    end
    if extra_hint then hint = hint and (extra_hint .. "\nlw: " .. hint) or extra_hint end
    return string.format("%s failed (%s): %s", step.kind, M.exit_text(code, signal), step.name or "?")
        .. (hint and ("\nlw: " .. hint) or "")
end

-- ---------------------------------------------------------------------------
-- Headless test runs (§16.16) — the batch `lw test` around the build steps,
-- shared by the in-process host (cli.lua `cmd_test`) and the workspace daemon
-- (daemon/runner.lua, §19.15): every line and refusal is returned as the text
-- the CLI prints.
-- ---------------------------------------------------------------------------

local function is_win() return package.config:sub(1, 1) == "\\" end

--- A path for comparison: forward slashes, no trailing slash, case-folded on
--- Windows.
local function norm_cmp(p)
    p = tostring(p):gsub("\\", "/"):gsub("/+$", "")
    if is_win() then p = p:lower() end
    return p
end

--- The refusal of a batch test run for a profile that builds with a foreign
--- (cross) kit: its registered tests cannot run on this host (spec §15
--- invariant 19, §18.6). nil when every unit builds for the host.
--- @param profile table
--- @return string|nil
function M.foreign_batch_refusal(profile)
    for _, pp in ipairs(profile:projects()) do
        local token, tool = require("loomworks.remote.foreign").unit_platform(pp._config_unit)
        if token then
            return string.format("profile '%s' builds with kit %s for %s; its registered tests cannot run "
                .. "on this host.\n  run test executables on a device: lw test %s --target <exe> [-- <args>]",
                profile.key, tostring(tool and (tool.key or tool.label) or "?"), token, profile.key)
        end
    end
    return nil
end

--- The line of a test run whose profile has no native test runner.
--- @param profile table
--- @param units integer|nil the number of units planned
--- @return string
function M.no_tests_line(profile, units)
    return "no tests to run for profile '" .. profile.key .. "'" ..
        ((units and units > 0) and " — its modules expose no test runner" or "")
end

--- Create the directory of a requested JUnit file up front (ctest's
--- --output-junit and the copy of a runner's own file both need it).
--- @param junit string|nil absolute path
--- @return boolean ok, string|nil err
function M.prepare_junit(junit)
    local dir = junit and junit:match("^(.*)/[^/]+$")
    if not dir then return true end
    local ok, err = require("loomworks.io").mkdir_p(dir)
    if not ok then return false, "cannot create " .. dir .. ": " .. tostring(err) end
    return true
end

--- Materialize a test step's JUnit file at the caller's path, after the step
--- ran (also when it failed — CI wants the report): copied from the runner's
--- own location when it wrote elsewhere (meson), confirmed when it wrote
--- there directly (ctest). Returns the written path, or a warning line (with
--- its newline) when the runner wrote none; nothing when none was requested.
--- @param step table a test step (overseer.plan_profile_test)
--- @return string|nil path, string|nil warning
function M.junit_result(step)
    if not (step.junit_dest and step.junit_out) then return nil end
    local uv = vim.uv or vim.loop
    local warning = "lw: warning: no JUnit output for " .. (step.name or "?") .. "\n"
    if norm_cmp(step.junit_out) ~= norm_cmp(step.junit_dest) then
        if not uv.fs_stat(step.junit_out) then return nil, warning end
        uv.fs_copyfile(step.junit_out, step.junit_dest)
        return step.junit_dest
    end
    if uv.fs_stat(step.junit_dest) then return step.junit_dest end
    return nil, warning
end

--- The outcome of a test run: the success line, or the failure message
--- (`lw: <message>`, exit 1).
--- @param profile table
--- @param failed string[] the names of the runners that failed
--- @param n integer the number of runners run
--- @return string|nil ok_line, string|nil failure
function M.test_summary(profile, failed, n)
    if #failed > 0 then
        return nil, string.format("%d of %d test run(s) failed: %s", #failed, n, table.concat(failed, ", "))
    end
    return string.format("TESTS OK: %s (%d run%s)", profile.key, n, n == 1 and "" or "s")
end

return M
