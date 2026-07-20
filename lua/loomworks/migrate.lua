--- loomworks/migrate.lua — convention migration (spec §16.19).
---
--- Rewrites workspace files from a still-valid older shape into the current
--- recommended one. Form changes, meaning does not: a migrated workspace must
--- resolve to the same projects, configurations, options and build types.
---
--- Structured as a registry of named rules rather than a one-off, because this
--- accrues rules over time. Each rule reports what it *would* change
--- (`plan`) separately from changing it (`apply`), so a caller can preview,
--- check in CI, or ask for consent before writing.
---
--- A rule that cannot rewrite a case without risking a behaviour change must
--- SKIP it with a reason. Guessing is the one thing a migration must not do —
--- a silently altered build is far worse than a file left alone.

local M = {}

--- @class loomworks.MigrationChange
--- @field rule string rule name
--- @field project string project key
--- @field item string configuration name (or other item identifier)
--- @field before string human-readable current shape
--- @field after string human-readable migrated shape
--- @field apply fun(): boolean, string|nil performs the rewrite

--- @class loomworks.MigrationSkip
--- @field rule string
--- @field project string
--- @field item string
--- @field reason string why it was left alone

--- @class loomworks.MigrationPlan
--- @field changes loomworks.MigrationChange[]
--- @field skipped loomworks.MigrationSkip[]

-- ---------------------------------------------------------------------------
-- Rule: variant-inherits
-- ---------------------------------------------------------------------------

--- Find the auto-generated configuration in `project` whose module variant is
--- `variant` — the base a declared variant should inherit from instead.
--- @param project loomworks.Project
--- @param variant string
--- @return loomworks.Configuration|nil
local function variant_base(project, variant)
    for _, cfg in ipairs(project:get_configurations()) do
        local mc = cfg.module_config
        if cfg:is_auto_gen() and mc and mc.variant == variant then
            return cfg
        end
    end
    return nil
end

--- Build the data table `save_configuration` expects from a Configuration,
--- dropping values the module derived from a base (those are not this
--- configuration's to restate — see Configuration._derived).
--- @param cfg loomworks.Configuration
--- @return table
local function config_data(cfg)
    local data = {}
    for k, v in pairs(cfg.module_config or {}) do
        if not (cfg._derived and cfg._derived[k]) then data[k] = v end
    end
    if cfg.inherits_names and #cfg.inherits_names > 0 then
        data.inherits = vim.deepcopy(cfg.inherits_names)
    end
    if cfg.options and next(cfg.options) then data.options = vim.deepcopy(cfg.options) end
    if cfg.variables and next(cfg.variables) then data.variables = vim.deepcopy(cfg.variables) end
    if cfg.languages and #cfg.languages > 0 then data.languages = vim.deepcopy(cfg.languages) end
    if cfg.role then data.role = cfg.role end
    return data
end

--- A configuration becomes concrete by inheriting a base that provides a
--- variant, so the build type has a single declared source (spec §1.4). Files
--- written before that rule declared `variant` directly; rewrite those onto
--- the matching `variant:*` base.
local variant_inherits = {
    name = "variant-inherits",
    summary = "declare the build type by inheriting variant:*, not by naming it",
}

--- @param ws loomworks.Workspace
--- @param plan loomworks.MigrationPlan
function variant_inherits.plan(ws, plan)
    for _, project in pairs(ws._projects or {}) do
        if not project.orphaned then
            for _, cfg in ipairs(project:get_configurations()) do
                local declared = cfg.module_config and cfg.module_config.variant
                local is_derived = cfg._derived and cfg._derived.variant
                -- Only user configurations that DECLARE a variant. Auto-gens
                -- are the bases themselves, and a derived variant is already
                -- inherited.
                if cfg.is_user and not cfg:is_auto_gen()
                    and declared and not is_derived then
                    variant_inherits._plan_one(project, cfg, declared, plan)
                end
            end
        end
    end
end

--- @param project loomworks.Project
--- @param cfg loomworks.Configuration
--- @param declared string
--- @param plan loomworks.MigrationPlan
function variant_inherits._plan_one(project, cfg, declared, plan)
    local function skip(reason)
        plan.skipped[#plan.skipped + 1] = {
            rule = variant_inherits.name,
            project = project.key,
            item = cfg.name,
            reason = reason,
        }
    end

    local base = variant_base(project, declared)
    if not base then
        -- Nothing to inherit from: the module does not offer this build type,
        -- so rewriting would drop the value entirely.
        skip("no configuration provides variant '" .. declared
            .. "' — nothing to inherit from")
        return
    end

    local existing = cfg.inherits_names or {}
    if #existing > 0 then
        -- Prepending changes which value wins where two bases collide. Safe
        -- only when the base contributes nothing that could collide.
        if base.options and next(base.options) then
            skip("already inherits " .. table.concat(existing, ", ")
                .. " and base '" .. base.name .. "' carries options — "
                .. "adding it could change which option wins; resolve by hand")
            return
        end
        for _, name in ipairs(existing) do
            if name == base.name then
                skip("already inherits '" .. base.name
                    .. "'; drop the redundant variant by hand")
                return
            end
        end
    end

    -- Bases apply left to right with later winning, so the variant base goes
    -- FIRST: existing bases keep precedence exactly as they had it.
    local new_inherits = { base.name }
    for _, name in ipairs(existing) do new_inherits[#new_inherits + 1] = name end

    plan.changes[#plan.changes + 1] = {
        rule = variant_inherits.name,
        project = project.key,
        item = cfg.name,
        before = "variant: " .. declared
            .. (#existing > 0 and ("  inherits: " .. table.concat(existing, ", ")) or ""),
        after = "inherits: " .. table.concat(new_inherits, ", "),
        apply = function()
            local data = config_data(cfg)
            data.variant = nil
            data.inherits = #new_inherits == 1 and new_inherits[1] or new_inherits
            return project:save_configuration(cfg.name, data)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

--- All migration rules, in application order.
M.RULES = { variant_inherits }

--- Compute what would change, without changing anything.
--- @param ws loomworks.Workspace
--- @return loomworks.MigrationPlan
function M.plan(ws)
    local plan = { changes = {}, skipped = {} }
    for _, rule in ipairs(M.RULES) do
        rule.plan(ws, plan)
    end
    return plan
end

--- Apply a plan's changes. Stops at the first failure and reports it — a
--- partially migrated workspace is still valid (each change is independent
--- and meaning-preserving), so there is nothing to roll back.
--- @param plan loomworks.MigrationPlan
--- @return integer applied, string|nil err
function M.apply(plan)
    local applied = 0
    for _, change in ipairs(plan.changes) do
        local ok, err = change.apply()
        if not ok then
            return applied, string.format("%s/%s: %s", change.project, change.item,
                tostring(err or "could not rewrite"))
        end
        applied = applied + 1
    end
    return applied, nil
end

return M
