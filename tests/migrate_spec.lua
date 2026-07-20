--- Tests for loomworks.migrate — convention migration (spec §16.19).
---
--- The contract that matters is meaning-preservation: a migration rewrites
--- form only. Anything it cannot rewrite without risking a behaviour change
--- must be reported and left alone, never guessed at.

local h = require("tests.helpers")
local migrate = require("loomworks.migrate")
local Project = require("loomworks.project")

--- A project whose module emits `variant:*` auto-gens, plus whatever user
--- configurations the test declares.
--- @param user_configs table<string, table>
local function make_project(user_configs)
    -- The default mock `_save_user` returns nothing, which `save_configuration`
    -- reads as a failed write; migration needs it to succeed.
    local ws = h.make_mock_workspace({
        _core = { _save_user = function() return true end },
    })
    ws._save_user = function() return true end
    local configurations = {
        ["variant:Debug"] = { prefix = "variant", variant = "Debug", is_default = true },
        ["variant:Release"] = { prefix = "variant", variant = "Release", is_default = true },
    }
    for name, data in pairs(user_configs or {}) do
        data.is_user = true
        configurations[name] = data
    end
    local project = Project.new(ws, "App", {
        type = "cmake",
        path = "App",
        status = "unconfigured",
        configurations = configurations,
        cached_configurations = {},
    })
    ws._projects = { project }
    return ws, project
end

local function find(list, item)
    for _, e in ipairs(list) do
        if e.item == item then return e end
    end
    return nil
end

describe("migrate: variant-inherits", function()
    it("plans a rewrite for a directly declared variant", function()
        local ws = make_project({ Release = { variant = "Release" } })
        local plan = migrate.plan(ws)
        local change = find(plan.changes, "Release")
        assert.is_not_nil(change, "a declared variant should be migratable")
        assert.equals("variant-inherits", change.rule)
        assert.is_truthy(change.after:find("variant:Release", 1, true))
    end)

    it("rewrites to inherits and drops the declared variant", function()
        local ws, project = make_project({
            Release = { variant = "Release", options = { X = "1" } },
        })
        local plan = migrate.plan(ws)
        local applied, err = migrate.apply(plan)
        assert.is_nil(err)
        assert.equals(1, applied)

        local cfg = project:get_configuration("Release")
        assert.same({ "variant:Release" }, cfg.inherits_names)
        assert.same({ X = "1" }, cfg.options, "options must survive untouched")
        local entry = cfg:serialize_user_override()
        assert.is_nil(entry.variant,
            "the declared variant must be gone from the persisted shape")
    end)

    it("preserves meaning: the new base supplies the same variant", function()
        -- The module re-derives the concrete variant from the base on refresh
        -- (no module is wired in this harness, so assert the relationship
        -- rather than the derived value): whatever the config declared, the
        -- base it now inherits must provide exactly that.
        local ws, project = make_project({ Release = { variant = "Release" } })
        migrate.apply(migrate.plan(ws))
        local cfg = project:get_configuration("Release")
        assert.equals(1, #cfg.inherits_names)
        local base = project:get_configuration(cfg.inherits_names[1])
        assert.is_not_nil(base, "the base must resolve, not dangle")
        assert.equals("Release", base.module_config.variant,
            "the base must supply the variant the config used to declare")
    end)

    it("is idempotent", function()
        local ws = make_project({ Release = { variant = "Release" } })
        migrate.apply(migrate.plan(ws))
        local second = migrate.plan(ws)
        assert.equals(0, #second.changes, "a migrated workspace has nothing pending")
    end)

    it("leaves auto-generated configurations alone", function()
        local ws = make_project({})
        local plan = migrate.plan(ws)
        assert.equals(0, #plan.changes,
            "variant:* configs ARE the bases; they must not be rewritten")
    end)

    it("skips a variant no configuration provides", function()
        -- A build type the module doesn't offer has nothing to inherit from;
        -- rewriting would drop the value entirely.
        local ws = make_project({ Odd = { variant = "Coverage" } })
        local plan = migrate.plan(ws)
        assert.equals(0, #plan.changes)
        local skip = find(plan.skipped, "Odd")
        assert.is_not_nil(skip)
        assert.is_truthy(skip.reason:find("Coverage", 1, true))
    end)

    it("skips when adding the base could change which option wins", function()
        -- The existing base carries options; prepending another that also
        -- carries options risks changing precedence, so refuse.
        local ws = make_project({
            mixin = { options = { X = "from-mixin" } },
            Combo = { variant = "Release", inherits = { "mixin" } },
        })
        -- Give the variant base options so the collision is real.
        local project = ws._projects[1]
        project:get_configuration("variant:Release").options = { X = "from-base" }

        local plan = migrate.plan(ws)
        assert.equals(0, #plan.changes)
        local skip = find(plan.skipped, "Combo")
        assert.is_not_nil(skip)
        assert.is_truthy(skip.reason:lower():find("option", 1, true))
    end)

    it("keeps existing bases winning when it does rewrite", function()
        -- The variant base contributes no options, so it is safe to add — and
        -- it goes FIRST so the existing base keeps its precedence.
        local ws, project = make_project({
            mixin = { options = { X = "from-mixin" } },
            Combo = { variant = "Release", inherits = { "mixin" } },
        })
        local plan = migrate.plan(ws)
        assert.equals(1, #plan.changes)
        migrate.apply(plan)
        assert.same({ "variant:Release", "mixin" },
            project:get_configuration("Combo").inherits_names)
    end)

    it("skips a config that already inherits the base it would gain", function()
        local ws = make_project({
            Redundant = { variant = "Release", inherits = { "variant:Release" } },
        })
        local plan = migrate.plan(ws)
        assert.equals(0, #plan.changes)
        assert.is_not_nil(find(plan.skipped, "Redundant"))
    end)
end)
