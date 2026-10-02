--- loomworks/run_prep.lua — the preparation of `lw run` (spec §16.17), shared
--- by the in-process host (cli.lua `cmd_run`) and the workspace daemon
--- (daemon/runner.lua, `prepare_run`, §19.15 "Run"): launch-target
--- enumeration and selection, the validity gate, the foreign-artifact probe,
--- the launch-spec resolution and the launch's environment contribution.
---
--- Host-neutral: nothing here prints or exits. Every refusal is returned as
--- the text `lw` prints (after its `lw: ` prefix), so both runners report a
--- run identically. Only executing the resolved spec is the host's.

local M = {}

local function build_run() return require("loomworks.build_run") end

--- @class loomworks.RunCandidate
--- @field kind "launch"|"target"
--- @field project loomworks.Project
--- @field name string the display name the operand is matched against
--- @field target_id? string the module target id (kind "target")

--- Enumerate the launchable targets of a profile: command / target-backed
--- launch configurations and executable build targets across the profile's
--- projects, launch configurations first, each group sorted. Parses targets
--- on demand (build first).
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @return loomworks.RunCandidate[]
function M.launchable_targets(ws, profile)
    local list = {}
    for _, pp in ipairs(profile:projects()) do
        local unit = pp._config_unit
        local project = unit and unit._project
        if project then
            if type(project.launch) == "table" then
                local names = {}
                for lname, cfg in pairs(project.launch) do
                    if type(cfg) == "table" and (cfg.command or cfg.target) then names[#names + 1] = lname end
                end
                table.sort(names)
                for _, lname in ipairs(names) do
                    list[#list + 1] = { kind = "launch", project = project, name = lname }
                end
            end
            build_run().ensure_unit_targets(ws, unit)
            if type(unit.targets) == "table" then
                local ids = {}
                for id in pairs(unit.targets) do ids[#ids + 1] = id end
                table.sort(ids)
                for _, id in ipairs(ids) do
                    local t = unit.targets[id]
                    if t and t.is_executable and t:is_executable() then
                        local dname = (t.display_name and t:display_name()) or id
                        list[#list + 1] = { kind = "target", project = project, name = dname, target_id = id }
                    end
                end
            end
        end
    end
    return list
end

--- A candidate for messages: `project:name (kind)`.
--- @param c loomworks.RunCandidate
--- @return string
function M.fmt_cand(c)
    return c.project.key .. ":" .. c.name .. " (" .. c.kind .. ")"
end

--- The LaunchTarget of a candidate.
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param c loomworks.RunCandidate
--- @return loomworks.LaunchTarget
function M.candidate_launch_target(ws, profile, c)
    local descriptor = { project = c.project.key }
    if c.kind == "target" then descriptor.target = c.target_id else descriptor.launch = c.name end
    return require("loomworks.launch_target").new(ws, profile, descriptor)
end

--- Match a run operand `name` against a profile's launchable targets,
--- honoring an explicit `--project` scope, a `project:name` prefix (only when
--- the prefix is a project of this profile — target ids may contain ':'), and
--- a `--target` / `--launch` kind filter. Returns the matching candidates (0 =
--- none, 1 = unique, >1 = ambiguous) and the full candidate list (`all`,
--- default `launchable_targets`, injectable for tests).
--- @return loomworks.RunCandidate[] matches, loomworks.RunCandidate[] all
function M.match_targets(ws, profile, name, proj_scope, kind, all)
    local scope, bare = proj_scope, name
    if not scope then
        local qproj, rest = build_run().split_target_ref(profile, name)
        if qproj then scope, bare = qproj.key, rest end
    end
    all = all or M.launchable_targets(ws, profile)
    local matches = {}
    for _, c in ipairs(all) do
        if c.name == bare and (not scope or c.project.key == scope)
            and (not kind or c.kind == kind) then matches[#matches + 1] = c end
    end
    return matches, all
end

--- Resolve the launch target of a run against the built tree (spec §16.17
--- "Launch target selection"): the named target (`name`), else the profile's
--- default target, else its sole launchable one. Returns the LaunchTarget, or
--- nil + the refusal (no such target, ambiguous, nothing to run, no default
--- set). `opts.refresh` re-reads every unit's targets first (a long-lived
--- daemon whose units outlived a build, §19.15).
--- @param ws loomworks.Workspace
--- @param profile loomworks.Profile
--- @param name string|nil
--- @param proj_scope string|nil `--project`
--- @param kind "target"|"launch"|nil `--target` / `--launch`
--- @param opts? { refresh?: boolean }
--- @return loomworks.LaunchTarget|nil lt, string|nil err
function M.select(ws, profile, name, proj_scope, kind, opts)
    if opts and opts.refresh then
        for _, pp in ipairs(profile:projects()) do
            build_run().ensure_unit_targets(ws, pp._config_unit, { refresh = true })
        end
    end
    if name then
        local matches, all = M.match_targets(ws, profile, name, proj_scope, kind)
        if #matches == 0 then
            local labels = {}
            for _, c in ipairs(all) do labels[#labels + 1] = M.fmt_cand(c) end
            return nil, "no launch target '" .. name .. "' in profile '" .. profile.key .. "'.\n" ..
                "  available: " .. (next(labels) and table.concat(labels, ", ") or "(none)") .. "\n" ..
                "  a target on a different profile: lw run <profile> <target>"
        elseif #matches > 1 then
            local labels = {}
            for _, c in ipairs(matches) do labels[#labels + 1] = M.fmt_cand(c) end
            return nil, "'" .. name .. "' is ambiguous: " .. table.concat(labels, ", ") ..
                "\n  qualify with `--target`/`--launch`, `--project <key>`, or `<project>:<name>`."
        end
        return M.candidate_launch_target(ws, profile, matches[1])
    end
    -- No name → the profile's default target.
    for _, pp in ipairs(profile:projects()) do build_run().ensure_unit_targets(ws, pp._config_unit) end
    local lt = profile:default_target()
    if lt then return lt end
    local cands = M.launchable_targets(ws, profile)
    if #cands == 1 then return M.candidate_launch_target(ws, profile, cands[1]) end
    if #cands == 0 then
        return nil, "nothing to run in profile '" .. profile.key .. "' — no launch configs or executable targets."
    end
    local labels = {}
    for _, c in ipairs(cands) do labels[#labels + 1] = M.fmt_cand(c) end
    return nil, "no default target set for profile '" .. profile.key .. "'.\n" ..
        "  set one:      lw target set " .. profile.key .. " <target>\n" ..
        "  or name one:  lw run " .. profile.key .. " <target>\n" ..
        "  candidates:   " .. table.concat(labels, ", ")
end

--- The validity gate of a launch target (stale descriptor, invalid profile or
--- configuration): nil when runnable, else the refusal.
--- @param lt loomworks.LaunchTarget
--- @return string|nil
function M.validity_error(lt)
    local ok, reasons = lt:is_valid()
    if ok then return nil end
    return "launch target is not runnable: " ..
        table.concat(type(reasons) == "table" and reasons or { "invalid" }, "; ")
end

--- The foreign-artifact classification of a launch target's build-target
--- artifact (spec §18.1), or nil: a module target or a target-backed launch
--- configuration whose artifact is foreign. Command launches are never probed.
--- @param lt loomworks.LaunchTarget
--- @return loomworks.ForeignArtifact|nil
function M.foreign_of(lt)
    local target = lt._launch_config and lt._config_target or lt._target
    if lt._launch_config and not lt._launch_config.target then return nil end
    if not (target and target.artifact) then return nil end
    local unit = target._config_unit or lt._config_unit
    local bd = unit and unit.build_dir and unit:build_dir()
    if not bd then return nil end
    local artifact = require("loomworks.paths").artifact_path(bd, target.artifact)
    local f = require("loomworks.remote.foreign").classify(unit, artifact)
    if f then f.target = target end
    return f
end

--- The execution platform of the first unit of `profile` that builds with a
--- foreign (cross) kit (spec §18.1, known before anything is built), or nil.
--- @param profile loomworks.Profile
--- @return string|nil
function M.kit_platform(profile)
    for _, pp in ipairs(profile:projects()) do
        local token = require("loomworks.remote.foreign").unit_platform(pp._config_unit)
        if token then return token end
    end
    return nil
end

--- Resolve the launch spec of a (deployed) launch target: the command, its
--- arguments (a command configuration's declared ones, then `extra_args`),
--- cwd and environment, expanded in the current process environment. nil +
--- the refusal (`cannot resolve launch: …`) when it does not resolve.
--- @param lt loomworks.LaunchTarget
--- @param opts { extra_args?: string[], cwd_override?: string }
--- @return { name: string, cmd: string, args: string[], cwd: string|nil, env: table|nil }|nil spec
--- @return string|nil err
function M.resolve_spec(lt, opts)
    local spec, serr = lt:resolve_launch_spec({
        extra_args = opts.extra_args, working_dir = opts.cwd_override })
    -- An unresolved build-target artifact reports its reason and exits
    -- non-zero — reported, never guessed (§16.3 / §16.18).
    if not spec then return nil, "cannot resolve launch: " .. tostring(serr) end
    return spec
end

--- The launch-contributed environment OVERRIDES: entries of the resolved run
--- environment whose value differs from the current process environment. A
--- command launch config's env is already just its declared vars; a
--- build-target / target-backed launch resolves a FULL env (inherited + a
--- PATH prepend), so diffing against the inherited env reduces it to exactly
--- the launch's contribution — never the whole inherited environment (spec
--- §16.17 "Command inspection"). In the daemon the process environment is the
--- requesting client's (loomworks.daemon.envscope), so this is the
--- contribution over the client's environment (§19.15 "Run").
--- @param env table<string,string>|nil
--- @return table<string,string>
function M.env_overrides(env)
    if not env then return {} end
    local inherited = {}
    local ok, cur = pcall(function() return vim.fn.environ() end)
    if ok and type(cur) == "table" then inherited = cur end
    local ov = {}
    for k, v in pairs(env) do
        if inherited[k] ~= v then ov[k] = v end
    end
    return ov
end

return M
