--- loomworks/test_plan.lua — the test plan of `lw test` (spec §16.16), shared
--- by the in-process host (cli._test_plan, cli._test_targets) and the
--- workspace daemon's test run (daemon/runner.lua, §19.15): what is planned
--- before the build (`units`, `precheck`), the ordered steps resolved after it
--- (`prepare`), and their execution (`run`, `exec_step`) — every line, JUnit
--- file, summary and failure the same on both hosts.
---
--- Execution is written in continuation-passing style over a host:
---
---   host.out(line)          a stdout line
---   host.err(text)          stderr text (the caller supplies the newline)
---   host.fail(msg, code)    end the invocation (`lw: <msg>`, exit code); never
---                           returns to the plan (in-process: `die`)
---   host.spawn(spec, cb)    run `{ cmd, cwd?, env?, cleanup? }` (argv[1]
---                           unresolved, as build_run.spawn_spec takes it),
---                           then cb(code); a host that ends the step without
---                           calling back (a cancel) calls `cleanup()` first
---   host.probe(exe, label, o, cb)?  probe a build target's artifact for its
---                           test framework (`o = { env, cwd }`), then
---                           cb(framework|nil); default gtest.probe_sync here
---   host.deploy(lt, cb)?    run a launch's deploy steps, then cb(ok, err);
---                           default lt:deploy_sync() here
---   host.exec(lt, o, cb)    one executable step (`exec_step`, or a seam), then
---                           cb(failed, reasons, counts, exit_only, junit_path?)
---   host.foreign(lt, f, o, cb)  a device run (`o = { dev, no_build,
---                           before_exec }`), then cb(outcome); nil when the
---                           host does not run programs on a device
---   host.foreign_of(lt)?    the foreign classification of a step's artifact
---                           (default: run_prep.foreign_of)
---   host.progress(f)?       the fraction of the steps done
---
--- The in-process host calls back synchronously; the daemon's after the
--- spawned process exited (or the probe / deploy copy finished), in a model
--- segment, so a step never blocks its event loop; a cancel kills the running
--- program or probe and skips the remaining deploy copies.

local M = {}

local uv = vim.uv or vim.loop

--- Resolve an entry's `working_dir` like a launch's (spec §1.3.4 "Working
--- directory", §8.7): variable-expanded in the launch context `lctx`, then
--- absolute as-is or workspace-root-relative. nil when the entry has none.
--- An unresolved reference stays literal, as in a launch's `working_dir`,
--- and is returned in `unresolved`.
--- @param wd string|nil the entry's working_dir as written
--- @param lctx table|nil launch expansion context
--- @param root string|nil workspace root (nil: a relative result is returned as expanded)
--- @return string|nil abs
--- @return string[] unresolved names of `${…}` references that resolve to nothing
function M.resolve_working_dir(wd, lctx, root)
    if type(wd) ~= "string" or wd == "" then return nil, {} end
    local expand = require("loomworks.expand")
    local unresolved = expand.unresolved_vars(wd, lctx)
    local ex = expand.expand_string(wd, lctx)
    if ex:match("^/") or ex:match("^%a:") or not root then return ex, unresolved end
    if ex == "." or ex == "./" then return root, unresolved end
    return root .. "/" .. ex, unresolved
end

--- Expand an entry's args like a launch configuration's (spec §1.3.4, §8.7):
--- built-in then project variables of the launch context `lctx`
--- (`expand.launch_context`). Names are never expanded.
--- @param args string[]|nil
--- @param lctx table|nil launch expansion context
--- @return string[] expanded
--- @return string[] unresolved names of `${…}` references that resolve to nothing
function M.expand_args(args, lctx)
    local expand = require("loomworks.expand")
    local out, unresolved, seen = {}, {}, {}
    for _, a in ipairs(args or {}) do
        for _, v in ipairs(expand.unresolved_vars(a, lctx)) do
            if not seen[v] then seen[v] = true; unresolved[#unresolved + 1] = v end
        end
    end
    for i, a in ipairs(expand.expand_array(args or {}, lctx) or {}) do out[i] = a end
    return out, unresolved
end

--- Whether device options were given (spec §16.34).
--- @param d table|nil
--- @return boolean
function M.has_device_opts(d)
    return d and (d.device or d.fresh or d.timeout or d.no_wait or d.log_options) and true or false
end

--- The pre-build test plan of a profile (spec §16.16): per unit, in the
--- profile's project order, whether its batch step is planned and its saved
--- entries. `sel` is nil, "saved" or "discovered". Pure model data — reads no
--- build directory beyond the static batch-runner question. An invalid `tests`
--- declaration (§1.3.4) is planned as one invalid entry, so it fails like a
--- missing entry.
--- @return table[] units { unit, project, pp, batch, batch_dropped, platform, kit_platform, saved, entries }
--- @return integer n_batch, integer n_exec
function M.units(profile, sel)
    local foreign = require("loomworks.remote.foreign")
    local units, n_batch, n_exec = {}, 0, 0
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        local project = unit and unit._project
        if unit and project then
            local u = { unit = unit, project = project, pp = pp, entries = {} }
            if sel ~= "saved" then
                local list_fn = unit.batch_runner_test_units or unit.test_units
                for _, tu in ipairs(list_fn and list_fn(unit) or {}) do
                    if tu.run_command_all and not tu.is_saved_targets then u.batch = true end
                end
            end
            if sel ~= "discovered" and unit.saved_test_targets then
                u.saved = unit:saved_test_targets()
                u.entries = u.saved and u.saved.entries or {}
                if u.saved and u.saved.invalid then
                    u.entries = { { invalid = "tests", decl_invalid = true, index = 1 } }
                end
                local mod = project._module and project._module.impl
                if #u.entries > 0 and not (mod and mod.parse_targets) then
                    -- §1.3.4 Applicability: kept, reported as unsupported, never acted on.
                    u.unsupported = true
                    u.entries = {}
                end
            end
            local token, tool = foreign.unit_platform(unit)
            u.kit_platform = token
            if token and u.batch then
                u.batch, u.batch_dropped, u.platform, u.tool = false, true, token, tool
            end
            if u.batch then n_batch = n_batch + 1 end
            n_exec = n_exec + #u.entries
            units[#units + 1] = u
        end
    end
    return units, n_batch, n_exec
end

--- The project's executable targets, for messages ("App:a, App:b").
function M.executables_of(unit)
    local labels = {}
    for id, t in pairs(type(unit.targets) == "table" and unit.targets or {}) do
        if t.is_executable and t:is_executable() then
            labels[#labels + 1] = unit._project.key .. ":" .. ((t.display_name and t:display_name()) or id)
        end
    end
    table.sort(labels)
    return next(labels) and table.concat(labels, ", ") or "(none)"
end

--- The project's launch configurations in the model, for messages.
function M.launches_of(project)
    local labels = {}
    for name, cfg in pairs(type(project.launch) == "table" and project.launch or {}) do
        if type(cfg) == "table" and (cfg.command or cfg.target) then labels[#labels + 1] = project.key .. ":" .. name end
    end
    table.sort(labels)
    return next(labels) and table.concat(labels, ", ") or "(none)"
end

--- The resolution context of a unit's saved entries (spec §1.3.4
--- "Resolution"): the project's launch configurations, the trust-ignored
--- launches, and the unit's parsed build targets (nil = unknown).
function M.rctx(ws, unit, project, level)
    local test_targets = require("loomworks.test_targets")
    return {
        launches = project.launch,
        launch_ignored = function(n) return test_targets.launch_ignored(ws._shared_ignored, project, n) end,
        targets = unit and type(unit.targets) == "table" and unit.targets or nil,
        level = level,
    }
end

--- The `lw test-target remove` form that drops a saved entry at its level
--- (`--index <k>` for one occurrence of a repeated name).
function M.remove_hint(profile, project, entry, source)
    local level = (source and source._project) and (" --config " .. source.name) or " --project-wide"
    if not entry.name then
        return "fix it in the file by hand, or clear the list: lw test-target clear " .. profile.key .. " "
            .. project.key .. level
    end
    return "lw test-target remove " .. profile.key .. " " .. project.key .. ":" .. entry.name
        .. (entry.repeated and (" --index " .. entry.index) or "") .. level
end

--- @class loomworks.TestPlanPre
--- @field plan table[] `units`
--- @field n_batch integer
--- @field n_exec integer
--- @field keep table<table, boolean> units built although their runner rebuilds (they have saved entries)
--- @field notes string[] stderr lines, printed before anything else
--- @field err string|nil the invocation's refusal (printed after `notes`)
--- @field code integer|nil its exit code
--- @field device_platform string|nil a unit built by a foreign kit has saved entries: its steps run on a device

--- What `lw test` checks before the build (spec §16.16): the plan, its notes
--- and a refusal. `opts = { sel?, extra?, dev? }`.
--- @return loomworks.TestPlanPre
function M.precheck(profile, opts)
    local plan, n_batch, n_exec = M.units(profile, opts.sel)
    local extra = opts.extra or {}
    local pre = { plan = plan, n_batch = n_batch, n_exec = n_exec, keep = {}, notes = {} }
    local function refuse(msg, code)
        pre.err, pre.code = msg, code or 1
        return pre
    end

    -- Foreign units: the batch step is never run on the host (invariant 19).
    -- A unit whose skip note already says its saved targets are unsupported
    -- gets no second "— ignored" note below.
    local noted_unsupported = {}
    for _, u in ipairs(plan) do
        if u.batch_dropped and #u.entries > 0 then
            pre.notes[#pre.notes + 1] = string.format("lw: note: %s: its registered tests cannot run on this host (%s) — "
                .. "skipping its batch runner; its saved test targets run on a device", u.project.key, u.platform)
        elseif u.batch_dropped and n_batch + n_exec > 0 then
            -- Never skipped silently: name the unit, and how to include it only
            -- when it truly has no saved entries (under --discovered they were
            -- not planned; unsupported ones were cleared — neither is "none saved").
            local why
            if opts.sel == "discovered" then
                why = string.format("its discovered tests cannot run on this host (%s)", u.platform)
            elseif u.unsupported then
                noted_unsupported[u] = true
                why = string.format("its registered tests cannot run on this host (%s) and its saved test "
                    .. "targets are not supported by its module", u.platform)
            else
                why = string.format("its registered tests cannot run on this host (%s) and it has no saved test "
                    .. "targets; to run executables on a device: lw test-target add %s %s:<exe>",
                    u.platform, profile.key, u.project.key)
            end
            pre.notes[#pre.notes + 1] = string.format("lw: note: %s: skipped — %s", u.project.key, why)
        end
    end
    if n_batch + n_exec == 0 then
        for _, u in ipairs(plan) do
            if u.batch_dropped then
                local tool = u.tool
                return refuse(string.format("profile '%s' builds with kit %s for %s; its registered tests cannot run "
                    .. "on this host.\n  run test executables on a device: lw test %s --target <exe> [-- <args>]"
                    .. "\n  or save them: lw test-target add %s <exe>",
                    profile.key, tostring(tool and (tool.key or tool.label) or "?"), u.platform, profile.key, profile.key))
            end
        end
    end
    for _, u in ipairs(plan) do
        if u.unsupported and not noted_unsupported[u] then
            pre.notes[#pre.notes + 1] = "lw: note: " .. u.project.key
                .. ": saved test targets are not supported by its module (no build targets) — ignored"
        end
    end
    if M.has_device_opts(opts.dev) and n_exec == 0 then
        return refuse("device options apply to test executables: lw test <profile> --target <exe> …, "
            .. "or saved test targets (lw test-target add)", 2)
    end
    if #extra > 0 and n_batch > 0 and n_exec > 0 then
        return refuse("arguments after `--` need a plan of one kind — the native runners' arguments and the "
            .. "test programs' differ.\n  only the saved test executables: lw test " .. profile.key .. " --saved -- …"
            .. "\n  only the native runners:        lw test " .. profile.key .. " --discovered -- …"
            .. "\n  named executables:              lw test " .. profile.key .. " --target <exe> -- …", 2)
    end
    for _, u in ipairs(plan) do
        if #u.entries > 0 then
            pre.keep[u.unit] = true
            if u.kit_platform and not pre.device_platform then pre.device_platform = u.kit_platform end
        end
    end
    return pre
end

--- @class loomworks.TestPlanSteps
--- @field steps table[] the ordered steps { kind = "batch"|"exec", unit, project, label, entry?, lt?, args?, cwd? }
--- @field batch_steps table<table, table[]> per unit, its planned native runner steps
--- @field junit_for fun(label: string): string|nil the JUnit path of a step
--- @field notes string[] stderr notes printed before the steps (`--no-build`: possibly stale builds)

--- `lw test --no-build` (spec §16.16 "Skipping the build"): whether a build
--- target's artifact exists. `t` is the target, `unit` its config unit.
--- @return boolean built, string|nil path
function M.artifact_built(unit, t)
    local bd = unit and unit.build_dir and unit:build_dir()
    local path = (bd and t and t.artifact) and require("loomworks.paths").artifact_path(bd, t.artifact) or nil
    return (path and uv.fs_stat(path)) and true or false, path
end

--- The build target behind a launch target (a named target, or a
--- target-backed launch), or nil for a command launch.
function M.lt_build_target(lt)
    return lt and (lt._target or lt._config_target) or nil
end

--- The failure of a `--no-build` invocation before any step runs (exit 1):
--- `head` (the missing saved entries), one line per problem, then the two
--- ways forward (§16.16).
--- @return string
function M.no_build_message(profile, problems, head)
    local lines = {}
    for _, p in ipairs(head or {}) do lines[#lines + 1] = p end
    for _, p in ipairs(problems) do lines[#lines + 1] = p end
    return "--no-build: cannot run the tests against the existing build:\n  " .. table.concat(lines, "\n  ")
        .. "\n  build first: lw build " .. profile.key
        .. "\n  or run without --no-build"
end

--- `--no-build`: one note per unit whose recorded state says its build may
--- not match the current configuration (§16.16 "Stale builds are noted") —
--- the build gate's reconfigure reasons, or a failed last build. Recorded
--- state only: no source scan, no build-tool query.
--- @return string[] notes
function M.stale_notes(profile, units)
    local notes = {}
    for _, unit in ipairs(units) do
        if unit.configured_here and unit:configured_here() then
            local why = unit.configure_reason and unit:configure_reason(false, profile) or nil
            if not why and unit.state_value == "failed_build" then why = "last build failed" end
            if why then
                notes[#notes + 1] = string.format("lw: note: %s: its build may be stale (%s) — --no-build runs it as it is",
                    unit._project and unit._project.key or "?", why)
            end
        end
    end
    return notes
end

--- After the build (the units' targets parsed): resolve every saved entry —
--- a missing one fails the invocation before any step runs — and plan the
--- batch steps, their order and JUnit labels (spec §16.16). `opts = { junit?,
--- extra?, no_build? }`: `no_build` (`lw test --no-build`, §16.16 "Skipping
--- the build") also refuses a unit not configured here, an executable not
--- built and a self-rebuilding runner that cannot skip its rebuild — one
--- line each, before any step — and notes a possibly stale build (`notes`).
--- `deps` (tests): launch_target replaces the launch-target construction,
--- artifact_built(unit, target) → built, path the artifact check. Returns the
--- steps (`steps` empty: no tests to run), or nil and the refusal.
--- @param pre loomworks.TestPlanPre
--- @return loomworks.TestPlanSteps|nil, string|nil
function M.prepare(ws, profile, pre, opts, deps)
    deps = deps or {}
    local overseer = require("loomworks.overseer")
    local test_targets = require("loomworks.test_targets")
    local launch_target = deps.launch_target or require("loomworks.run_prep").candidate_launch_target
    local plan, n_batch = pre.plan, pre.n_batch
    local extra = opts.extra or {}

    local no_build = opts.no_build and true or false
    local artifact_built = deps.artifact_built or M.artifact_built

    -- `--no-build`: what must already exist (§16.16 "Skipping the build"). A
    -- unit with a batch step, or with an entry that needs its build targets,
    -- must be configured here — one line per unit, never a configure.
    local problems, unconfigured = {}, {}
    local function configured_here(u) return u.unit.configured_here and u.unit:configured_here() end
    local function not_configured(u)
        if not unconfigured[u] then
            unconfigured[u] = true
            problems[#problems + 1] = u.project.key .. ": not configured on this machine"
        end
    end
    -- Configured here, yet its build targets could not be read (its build
    -- directory is missing, or the module's target introspection failed).
    local function targets_unknown(u)
        if not unconfigured[u] then
            unconfigured[u] = true
            problems[#problems + 1] = u.project.key
                .. ": its build targets are unknown (build directory missing or unreadable)"
        end
    end
    if no_build then
        for _, u in ipairs(plan) do
            if u.batch and not configured_here(u) then not_configured(u) end
        end
    end

    -- Resolve every saved entry before the first step runs (missing → fail):
    -- a launch configuration first, else an executable build target (§1.3.4).
    local missing = {}
    for _, u in ipairs(plan) do
        u.exec = {}
        local level = u.saved and test_targets.level_label(u.saved.source) or u.project.key
        local rctx = M.rctx(ws, u.unit, u.project, level)
        for _, e in ipairs(u.entries) do
            local r = test_targets.resolve_entry(e, rctx)
            if no_build and r.state == "unknown" then
                -- Its build targets are unknown: the unit is not configured here,
                -- or it is but they could not be read.
                if configured_here(u) then targets_unknown(u) else not_configured(u) end
                r = { state = "skip" }
            elseif no_build and r.state == "ok" and r.target then
                -- A `target` entry or a target-backed launch: its artifact must
                -- exist (a command launch needs no check).
                local built, path = artifact_built(u.unit, r.target)
                if not built then
                    problems[#problems + 1] = string.format("saved test entry '%s' (%s): not built%s",
                        test_targets.entry_label(e), level, path and (" (" .. path .. ")") or "")
                end
            end
            -- Args and working_dir expand in the entry's launch context, where
            -- `${target_dir}` is its build target's artifact directory (§8.7).
            local lctx = r.state == "ok"
                and require("loomworks.expand").launch_context(ws, profile, u.project, { target = r.target }) or nil
            if r.state == "ok" then
                local lt
                if r.kind == "launch" then
                    lt = launch_target(ws, profile, { kind = "launch", project = u.project, name = e.name })
                else
                    local dname = (r.target.display_name and r.target:display_name()) or r.target.id
                    lt = launch_target(ws, profile,
                        { kind = "target", project = u.project, name = dname, target_id = r.target.id })
                end
                u.exec[#u.exec + 1] = { entry = e, lt = lt, kind = r.kind, args = M.expand_args(e.args, lctx),
                    cwd = (M.resolve_working_dir(e.working_dir, lctx, ws.root)) }
            elseif r.state ~= "skip" then
                local why = r.reason or ("cannot be resolved (the build targets of " .. u.project.key .. " are unknown)")
                if e.decl_invalid then why = "`tests` of " .. level .. " is not an array of saved test entries" end
                missing[#missing + 1] = string.format(
                    "saved test entry '%s' (%s): %s.\n    executables: %s\n    launch configurations: %s\n    remove it: %s",
                    test_targets.entry_label(e), level, why, M.executables_of(u.unit), M.launches_of(u.project),
                    M.remove_hint(profile, u.project, e, u.saved and u.saved.source))
            end
        end
    end

    -- Batch steps (after the build: a runner without a test set plans none).
    -- Under --no-build a self-rebuilding runner that cannot skip its rebuild
    -- is refused here, before any step runs (§8.9.2 `opts.no_rebuild`).
    local skip = {}
    for _, u in ipairs(plan) do if not u.batch or unconfigured[u] then skip[u.unit] = true end end
    local probe = (n_batch > 0) and overseer.plan_profile_test(profile, { skip_units = skip,
        no_rebuild = no_build or nil }) or {}
    local batch_count = {}
    for _, st in ipairs(probe or {}) do
        batch_count[st.unit] = (batch_count[st.unit] or 0) + 1
        if st.refused then
            problems[#problems + 1] = string.format("%s: %s",
                st.unit._project and st.unit._project.key or st.name, st.refused)
        end
    end
    if #problems > 0 then return nil, M.no_build_message(profile, problems, missing) end
    if #missing > 0 then return nil, table.concat(missing, "\n  ") end
    -- `--no-build`: a possibly stale build is noted, never refused.
    local notes = {}
    if no_build then
        local units = {}
        for _, u in ipairs(plan) do
            if batch_count[u.unit] or #u.exec > 0 then units[#units + 1] = u.unit end
        end
        notes = M.stale_notes(profile, units)
    end

    -- The final ordered steps and their JUnit labels (§16.16).
    local steps, labels = {}, {}
    for _, u in ipairs(plan) do
        if batch_count[u.unit] then
            local label = u.project.key .. ":" .. tostring(u.unit:variant())
            steps[#steps + 1] = { kind = "batch", unit = u.unit, project = u.project, label = label }
            labels[label] = (labels[label] or 0) + 1
        end
        for _, x in ipairs(u.exec) do
            steps[#steps + 1] = { kind = "exec", unit = u.unit, project = u.project, entry = x.entry,
                lt = x.lt, args = x.args, cwd = x.cwd, label = x.entry.name }
            labels[x.entry.name] = (labels[x.entry.name] or 0) + 1
        end
    end
    local res = { steps = steps, batch_steps = {}, notes = notes, junit_for = function() return nil end }
    if #steps == 0 then return res end
    -- Same label twice: qualify the executable step with its project, then,
    -- when its name repeats in its list, with its occurrence index.
    for _, st in ipairs(steps) do
        if st.kind == "exec" and labels[st.label] > 1 then
            st.label = st.project.key .. ":" .. st.label
                .. (st.entry.repeated and ("#" .. st.entry.index) or "")
        end
    end
    local multi = #steps > 1
    res.junit_for = function(label)
        return opts.junit and overseer._junit_dest_for(opts.junit, label, multi) or nil
    end
    if n_batch > 0 then
        local planned = overseer.plan_profile_test(profile, {
            skip_units = skip, extra_args = (#extra > 0) and extra or nil, junit = opts.junit,
            no_rebuild = no_build or nil,
            junit_dest_for = function(label) return res.junit_for(label) end,
        })
        for _, st in ipairs(planned or {}) do
            res.batch_steps[st.unit] = res.batch_steps[st.unit] or {}
            table.insert(res.batch_steps[st.unit], st)
        end
    end
    local okj, jerr = require("loomworks.build_run").prepare_junit(opts.junit)
    if not okj then return nil, jerr end
    return res
end

--- Run the prepared steps (spec §16.16): per unit, its batch step(s), then one
--- executable step per saved entry; every step runs even when an earlier one
--- failed. Prints each step, the per-step summary and `TESTS OK: <profile>
--- (<n> step[s])`. `done(code, err, results)`: `err` is the failure
--- (`<k> of <n> test step[s] failed`, exit 1); `results = { steps = {{ name,
--- exit_code, status }}, junit = { paths } }` (Tests/1.run's task result).
--- `opts = { extra?, dev?, no_build? }` (`no_build`: each executable step
--- skips its launch's deploy, §16.16).
--- @param prepared loomworks.TestPlanSteps
function M.run(ws, profile, prepared, opts, host, done)
    local test_targets = require("loomworks.test_targets")
    local build_run = require("loomworks.build_run")
    local extra = opts.extra or {}
    local junit_for = prepared.junit_for
    -- One queue entry per batch runner step or executable step.
    local queue = {}
    for _, st in ipairs(prepared.steps) do
        if st.kind == "batch" then
            for _, b in ipairs(prepared.batch_steps[st.unit] or {}) do queue[#queue + 1] = { st = st, b = b } end
        else
            queue[#queue + 1] = { st = st }
        end
    end
    local summary, n_failed = {}, 0
    local results = { steps = {}, junit = {} }
    local function record(name, ok, code, junit)
        results.steps[#results.steps + 1] = { name = name, exit_code = code, status = ok and "passed" or "failed" }
        if junit then results.junit[#results.junit + 1] = junit end
    end

    local i = 0
    local next_step
    local function finish()
        host.out("")
        host.out("summary — profile '" .. profile.key .. "':")
        for _, l in ipairs(summary) do host.out(l) end
        if n_failed > 0 then
            return done(1, string.format("%d of %d test step%s failed", n_failed, #summary,
                #summary == 1 and "" or "s"), results)
        end
        host.out(string.format("TESTS OK: %s (%d step%s)", profile.key, #summary, #summary == 1 and "" or "s"))
        return done(0, nil, results)
    end
    next_step = function()
        if host.progress then host.progress(#queue > 0 and i / #queue or 1) end
        i = i + 1
        local q = queue[i]
        if not q then return finish() end
        local st = q.st
        if q.b then
            local b = q.b
            host.out(string.format("==> [test] %s: %s", st.project.key, b.runner or "runner"))
            return host.spawn(b, function(code)
                local path, warning = build_run.junit_result(b)
                if path then
                    host.out("JUnit: " .. path)
                elseif warning then
                    host.err("lw: warning: no JUnit output for " .. st.label .. "\n")
                end
                local ok = code == 0
                if not ok then n_failed = n_failed + 1 end
                summary[#summary + 1] = string.format("  %-28s %s", st.project.key .. ": " .. (b.runner or "runner"),
                    ok and "passed" or ("FAILED (exit status " .. tostring(code) .. ")"))
                record(b.name or st.label, ok, code, path)
                return next_step()
            end)
        end
        local name = test_targets.entry_label(st.entry)
        return host.exec(st.lt, {
            label = name, header = st.project.key .. ": " .. name, saved = true,
            args = st.args, cwd = st.cwd, entry_working_dir = st.entry.working_dir,
            extra = extra, dev = opts.dev, junit_path = junit_for(st.label), no_build = opts.no_build,
        }, function(failed, reasons, c, exit_only, junit)
            if failed then n_failed = n_failed + 1 end
            summary[#summary + 1] = string.format("  %-28s %s%s", st.project.key .. ": " .. name,
                failed and ("FAILED (" .. require("loomworks.remote.test_run").failed_reasons(reasons, c) .. ")")
                    or ("passed" .. ((c and not exit_only) and require("loomworks.remote.test_run").not_run_suffix(c) or "")),
                exit_only and "  (exit status only — no per-case results)" or "")
            record(st.label, not failed, failed and 1 or 0, junit)
            return next_step()
        end)
    end
    return next_step()
end

--- Run ONE test executable step (spec §16.16, §18.6) — the shared executor of
--- named (`--target`) and saved test entries. `lt` is the resolved
--- `LaunchTarget` (the same object `lw run <name>` uses): a build target, or a
--- launch configuration. A launch's deploy steps run first (a failed deploy
--- fails the step without running the program). The program runs on a device
--- when its build-target artifact is foreign (§18.5), locally otherwise, with
--- argv = program, the framework results option (only for a build target's
--- artifact the gtest helper recognises), a launch's own args, the step's
--- `args` (already expanded), then the caller-forwarded args. The outcome is
--- judged from exit status + parsed results (+ crashes / missing results on a
--- device). Prints the step header and its one-line outcome; writes JUnit to
--- `opts.junit_path` when given.
--- `opts = { label, header?, args?, extra?, dev, junit_path?, saved?, cwd?,
--- entry_working_dir?, cwd_override?, no_build? }`: `cwd` is a saved entry's resolved
--- working directory (absolute; it replaces the program's), `entry_working_dir`
--- the entry's `working_dir` as written (a device step notes it is not used),
--- `cwd_override` a named target's per-invocation `--cwd` (raw, expanded in
--- the target's launch context; refused for a device run). `no_build`
--- (`lw test --no-build`) skips a launch's deploy steps (§16.16). With
--- `saved` (a saved entry's step) a refused or unresolvable run fails the step
--- instead of the invocation, and a program without per-case results is
--- judged on its exit status alone and written to JUnit as one test case.
--- `cb(failed, reasons, counts, exit_only, junit_path?)` (`junit_path`: the
--- JUnit file written).
function M.exec_step(ws, lt, opts, host, cb)
    local test_run = require("loomworks.remote.test_run")
    local gtest = require("loomworks.gtest")
    local remote_run = require("loomworks.remote.run")
    local label = opts.label
    local tail = {}
    for _, a in ipairs(opts.args or {}) do tail[#tail + 1] = a end
    for _, a in ipairs(opts.extra or {}) do tail[#tail + 1] = a end
    local cfg = lt._launch_config
    -- The results option applies only to a build target's artifact (§16.16).
    local artifact = not (cfg and not cfg.target)
    local f = artifact and (host.foreign_of or require("loomworks.run_prep").foreign_of)(lt) or nil
    local results, results_requested, results_missing, failed, reasons

    --- A step that cannot run: fail it (saved entry) or the invocation (nil).
    local function refuse(msg)
        if not opts.saved then return nil end
        host.err("lw: " .. msg .. "\n")
        return { msg }
    end

    if opts.cwd_override and (f or (lt.requires_device and lt:requires_device())) then
        return host.fail("--cwd does not apply to a device run ('" .. label
            .. "') — set the project's device.working_dir instead", 2)
    end
    -- A device step takes its working directory from the `device` block, never
    -- from the entry (§1.3.4 "Working directory"): say so.
    host.out(string.format("==> [test] %s%s", opts.header or label,
        f and (opts.entry_working_dir and " (on a device; its working_dir is not used there)" or " (on a device)") or ""))
    if opts.saved then
        local ok, why = lt:is_valid()
        if not ok then
            reasons = refuse("launch target is not runnable: " ..
                table.concat(type(why) == "table" and why or { "invalid" }, "; "))
        end
        if not reasons and f and not (f.platform and require("loomworks.remote.runners").for_foreign(f)) then
            reasons = refuse(require("loomworks.remote.foreign").refusal(f))
        end
    end
    -- The step's outcome: its line, its JUnit file, then `cb`.
    local function conclude()
        -- A saved program without per-case results is judged on its exit status
        -- alone, and is one JUnit case (§16.16 "Results option").
        local exit_only = opts.saved and not results_requested and true or false
        local c = test_run.count(results)
        if failed then
            host.out(string.format("%s: FAILED (%s)%s", label, test_run.failed_reasons(reasons, c),
                #c.failed_ids > 0 and (": " .. table.concat(c.failed_ids, ", ")) or ""))
        elseif exit_only then
            host.out(label .. ": passed (exit status 0; no per-case results)")
        else
            host.out(string.format("%s: %d test%s passed%s", label, c.passed, c.passed == 1 and "" or "s",
                test_run.not_run_suffix(c)))
        end
        local written
        if opts.junit_path then
            local junit_results = results
            if exit_only then
                junit_results = { { test_id = "test:" .. label, status = failed and "failed" or "passed",
                    message = failed and table.concat(reasons or {}, ", ") or nil } }
            end
            if junit_results then
                local ok, werr = test_run.write_file(opts.junit_path, test_run.junit_xml(label, junit_results))
                if ok then
                    written = opts.junit_path
                    host.out("JUnit: " .. opts.junit_path)
                else
                    host.err("lw: warning: cannot write JUnit " .. opts.junit_path .. ": " .. tostring(werr) .. "\n")
                end
            else
                host.err("lw: warning: no JUnit output for " .. label .. " (no results file)\n")
            end
        end
        return cb(failed, reasons or {}, c, exit_only, written)
    end

    -- The step itself, once its deploy (if any) is done.
    local function run_step()
        if reasons then
            failed = true
            return conclude()
        end
        if f then
            if not host.foreign then
                -- (The workspace daemon declines a plan whose kit runs it on a
                -- device; this is an artifact found foreign only once built.)
                reasons = refuse("'" .. label .. "' runs on a device (built for " .. tostring(f.platform or f.what)
                    .. "); the workspace daemon does not run device programs — run it with: lw test --no-daemon")
                if not reasons then return host.fail("'" .. label .. "' runs on a device; the workspace daemon "
                    .. "does not run device programs") end
                failed = true
                return conclude()
            end
            local hook, st = test_run.device_hook(f.name, tail)
            return host.foreign(lt, f, { dev = opts.dev, no_build = (cfg ~= nil) or opts.no_build or false,
                before_exec = hook }, function(outcome)
                results_requested = st.framework == "gtest"
                local path = st.results_name and outcome.results[st.results_name]
                results = path and gtest.parse_xml_results(path) or nil
                if path and not results then results = {} end
                results_missing = results_requested and not path
                failed, reasons = test_run.judge({ status = outcome.status, results_requested = results_requested,
                    results = results, results_missing = results_missing, crashes = #outcome.crashes,
                    transport_error = outcome.transport_error or (outcome.timed_out and "timeout" or nil) })
                remote_run.report(outcome, function(s2) host.err(s2 .. "\n") end, failed)
                return conclude()
            end)
        end
        local spec, serr = lt:resolve_launch_spec({ working_dir = opts.cwd_override })
        if not spec then
            local msg = "cannot resolve test executable: " .. tostring(serr)
            reasons = refuse(msg)
            if not reasons then return host.fail(msg) end
            failed = true
            return conclude()
        end
        -- A saved entry's working directory replaces the program's (§1.3.4).
        if opts.cwd then spec.cwd = opts.cwd end
        -- The program runs once probed (a build target's artifact only): through
        -- the host when it probes asynchronously (the workspace daemon, whose
        -- cancel kills the probe), else here.
        local function probed(framework)
            local xml
            if framework == "gtest" then
                results_requested = true
                -- In the workspace's .nvim/tmp, not the system temp dir (§16.40).
                xml = require("loomworks.housekeeping").tmp_path(ws.root, "lw-test-", ".xml")
                -- argv: program, results option, the launch's own args, then the tail.
                table.insert(spec.args, 1, "--gtest_output=xml:" .. xml)
            end
            for _, a in ipairs(tail) do spec.args[#spec.args + 1] = a end
            local argv = { spec.cmd }
            for _, a in ipairs(spec.args) do argv[#argv + 1] = a end
            -- `cleanup`: what a host that ends the step without calling back
            -- (a cancel) removes — the step's results file.
            return host.spawn({ cmd = argv, cwd = spec.cwd, env = spec.env,
                cleanup = xml and function() os.remove(xml) end or nil }, function(code)
                if xml then
                    if uv.fs_stat(xml) then
                        results = gtest.parse_xml_results(xml) or {}
                        os.remove(xml)
                    else
                        results_missing = true
                    end
                end
                failed, reasons = test_run.judge({ status = code, results_requested = results_requested,
                    results = results, results_missing = results_missing })
                return conclude()
            end)
        end
        if not artifact then return probed(nil) end
        local popts = { env = spec.env, cwd = spec.cwd }
        if host.probe then return host.probe(spec.cmd, label, popts, probed) end
        return probed((gtest.probe_sync(spec.cmd, label, popts)))
    end

    -- A launch's deploy steps run before its program (§8.8.4): through the
    -- host when it has an asynchronous deploy (the workspace daemon, which
    -- keeps its loop free and stops between copies on a cancel), else here —
    -- unless the build is skipped, which skips deploy too (§16.16).
    if not reasons and cfg and not opts.no_build then
        local function deployed(dok, derr)
            if not dok then
                local msg = "deploy failed: " .. tostring(derr)
                reasons = refuse(msg)
                if not reasons then return host.fail(msg) end
            end
            return run_step()
        end
        if host.deploy then return host.deploy(lt, deployed) end
        return deployed(lt:deploy_sync())
    end
    return run_step()
end

return M
