--- Tests for Profile:assert_buildable.
---
--- The buildability gate refuses configure/build/launch/debug when
--- the profile has any project whose module needs a tool but
--- doesn't have one resolved. Without it, the build chain runs
--- with nil tool_data and produces malformed on-disk artefacts
--- (`.nvim/build/<project>/<bare-name>` shape, observed in the
--- field on harmony NativeDemo when DevEco wasn't yet detected).
---
--- Module-agnostic — Profile:is_complete iterates each project's
--- module via the generic capability flags (`has_keyed_tools`,
--- `kits_from_sdk`). Adding a new module (e.g. android) doesn't
--- require touching this code path.

local Profile = require("loomworks.profile").Profile

--- Build a minimal Profile-shaped object that exposes just enough
--- for is_complete / assert_buildable. The real Profile ctor needs
--- an extensive workspace fixture; we don't exercise it here.
--- @param projects { type: string, mod: table, has_tool: boolean, configuration: table? }[]
--- @return loomworks.Profile
local function make_profile(projects)
    local pps = {}
    for _, p in ipairs(projects) do
        pps[#pps + 1] = {
            _project = {
                _module = p.mod,
                type = p.type,
                key = p.type .. "-proj",
            },
            _configuration = p.configuration,
            _has_tool = p.has_tool,
        }
    end

    -- Override Profile:projects() and Profile:tool_for() per-instance
    -- so we can fake module/tool wiring without standing up a workspace.
    local self = setmetatable({
        key = "test-profile",
        _pps = pps,
    }, { __index = Profile })

    function self:projects()
        return self._pps
    end

    function self:tool_for(mod_type)
        for _, pp in ipairs(self._pps) do
            if pp._project.type == mod_type and pp._has_tool then
                return { key = "fake", data = {}, label = "fake-tool" }
            end
        end
        return nil
    end

    return self
end

local function module(opts)
    return {
        id = opts.id,
        has_keyed_tools = opts.has_keyed_tools or false,
        impl = opts.kits_from_sdk and { kits_from_sdk = function() return {} end } or {},
    }
end

describe("Profile:assert_buildable", function()
    it("ok=true when profile has no projects", function()
        local profile = make_profile({})
        local ok, err = profile:assert_buildable()
        assert.is_true(ok)
        assert.is_nil(err)
    end)

    it("ok=true when projects use modules that need no tools", function()
        -- typescript-style: no keyed tools, no SDK kits — nothing to
        -- resolve, so an absent tool is fine.
        local profile = make_profile({
            { type = "ts", mod = module({ id = "ts" }), has_tool = false },
        })
        local ok = profile:assert_buildable()
        assert.is_true(ok)
    end)

    it("ok=false when keyed-tool module has no tool resolved", function()
        -- cmake-style: has_keyed_tools = true. Tool is required.
        local profile = make_profile({
            { type = "kt", mod = module({ id = "kt", has_keyed_tools = true }), has_tool = false },
        })
        local ok, err = profile:assert_buildable()
        assert.is_false(ok)
        assert.is_not_nil(err)
        assert.is_truthy(err:find("incomplete", 1, true),
            "error mentions incompleteness")
        assert.is_truthy(err:find("test-profile", 1, true),
            "error names the profile")
    end)

    it("ok=true when keyed-tool module HAS a tool resolved", function()
        local profile = make_profile({
            { type = "kt", mod = module({ id = "kt", has_keyed_tools = true }), has_tool = true },
        })
        assert.is_true(profile:assert_buildable())
    end)

    it("ok=false when SDK-capable module has no tool (harmony case)", function()
        -- harmony-style: has_keyed_tools = false but kits_from_sdk
        -- exists. Without an SDK tool, the profile is incomplete —
        -- this is the original NativeDemo failure mode.
        local profile = make_profile({
            { type = "hm", mod = module({ id = "hm", kits_from_sdk = true }), has_tool = false },
        })
        local ok, err = profile:assert_buildable()
        assert.is_false(ok)
        assert.is_truthy(err:find("incomplete", 1, true))
    end)

    it("ok=true when SDK-capable module HAS a tool (harmony case)", function()
        local profile = make_profile({
            { type = "hm", mod = module({ id = "hm", kits_from_sdk = true }), has_tool = true },
        })
        assert.is_true(profile:assert_buildable())
    end)

    it("ok=false when ANY project is incomplete (mixed projects)", function()
        -- Defense: a profile with both a complete and incomplete
        -- project must refuse — partial builds are a worse mode
        -- than an explicit refusal.
        local profile = make_profile({
            { type = "kt", mod = module({ id = "kt", has_keyed_tools = true }), has_tool = true },
            { type = "hm", mod = module({ id = "hm", kits_from_sdk = true }), has_tool = false },
        })
        local ok = profile:assert_buildable()
        assert.is_false(ok)
    end)

    it("error message names the profile and why it is unbuildable", function()
        -- The error must be descriptive: identify the profile and cite the
        -- unmet requirement (the reasons from is_valid), not fail silently.
        local profile = make_profile({
            { type = "kt", mod = module({ id = "kt", has_keyed_tools = true }), has_tool = false },
        })
        local ok, err = profile:assert_buildable()
        assert.is_false(ok)
        assert.is_truthy(err, "returns an error message")
        assert.is_truthy(err:find("test-profile", 1, true), "names the profile")
        assert.is_truthy(err:lower():find("not buildable", 1, true),
            "states that it is not buildable")
    end)
end)

describe("Profile:is_valid — abstract configurations", function()
    --- A Configuration-shaped stub. `variant` nil = abstract mixin.
    local function configuration(name, variant)
        return {
            name = name,
            _removed = false,
            module_config = variant and { variant = variant } or nil,
            is_abstract = function(self)
                return not self.module_config or self.module_config.variant == nil
            end,
            effective_languages = function() return {} end,
        }
    end

    -- specification.md §1.4: a configuration with no variant — declared or
    -- inherited — is an abstract mixin, "not directly buildable, only usable
    -- as bases". Nothing enforced that on the build path: mapping a mixin into
    -- a configuration set produced a profile that built happily, with the
    -- module silently falling back to its own default (meson chose
    -- -Dbuildtype=debug). A guessed build type from a config that never named
    -- one is exactly the fallback guessing this project rules out.
    it("refuses a profile whose configuration is an abstract mixin", function()
        local profile = make_profile({
            { type = "meson", mod = module({ id = "meson" }), has_tool = true,
              configuration = configuration("mixin", nil) },
        })
        local ok, reasons = profile:is_valid()
        assert.is_false(ok, "an abstract configuration must not be buildable")
        assert.is_truthy(table.concat(reasons, "; "):lower():find("abstract", 1, true),
            "the reason must say the configuration is abstract, got: "
            .. table.concat(reasons, "; "))
    end)

    it("names the project and configuration in the reason", function()
        local profile = make_profile({
            { type = "meson", mod = module({ id = "meson" }), has_tool = true,
              configuration = configuration("mixin", nil) },
        })
        local _, reasons = profile:is_valid()
        local joined = table.concat(reasons, "; ")
        assert.is_truthy(joined:find("mixin", 1, true), "names the configuration")
        assert.is_truthy(joined:find("meson-proj", 1, true), "names the project")
    end)

    it("accepts a configuration that declares its own variant", function()
        -- Declaring `variant` directly and inheriting one from a base are two
        -- routes to the same concrete result; neither is abstract.
        local profile = make_profile({
            { type = "meson", mod = module({ id = "meson" }), has_tool = true,
              configuration = configuration("Release", "Release") },
        })
        assert.is_true((profile:is_valid()))
    end)

    it("ignores projects with no configuration resolved", function()
        -- An unresolved configuration is a different failure, already
        -- reported elsewhere; this check must not double-report it.
        local profile = make_profile({
            { type = "meson", mod = module({ id = "meson" }), has_tool = true },
        })
        local _, reasons = profile:is_valid()
        assert.is_falsy(table.concat(reasons, "; "):lower():find("abstract", 1, true))
    end)
end)

describe("Profile:is_valid — cmake presets are not abstract", function()
    local Configuration = require("loomworks.configuration")

    --- A cmake preset configuration as `cmake.info` emits it: module-emitted
    --- (`from_preset = true`) and self-contained — configured with
    --- `cmake --preset <name>`, so it carries no loomworks `variant`. A missing
    --- variant here is expected, not a mixin. Uses the REAL
    --- `Configuration:is_abstract` so the from_preset guard is exercised.
    local function preset_configuration(name)
        return {
            name = name,
            _removed = false,
            from_preset = true,
            module_config = {},  -- no variant: cmake owns the build type
            is_abstract = Configuration.is_abstract,
            effective_languages = function() return {} end,
        }
    end

    -- spec/core/data-model.md §1.4: an abstract mixin is a no-variant
    -- configuration that "no module ever emits". A preset IS module-emitted,
    -- so by the spec's own definition it cannot be abstract — the buildability
    -- gate must not refuse it.
    it("accepts a profile whose configuration is a cmake preset", function()
        local profile = make_profile({
            { type = "cmake", mod = module({ id = "cmake" }), has_tool = true,
              configuration = preset_configuration("preset:default") },
        })
        local ok, reasons = profile:is_valid()
        assert.is_true(ok, "a cmake preset is fully buildable, got reasons: "
            .. table.concat(reasons, "; "))
        assert.is_falsy(
            table.concat(reasons, "; "):lower():find("abstract", 1, true),
            "no reason may call the preset abstract, got: "
            .. table.concat(reasons, "; "))
    end)
end)
