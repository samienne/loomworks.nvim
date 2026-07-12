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
--- @param projects { type: string, mod: table, has_tool: boolean }[]
--- @return loomworks.Profile
local function make_profile(projects)
    local pps = {}
    for _, p in ipairs(projects) do
        pps[#pps + 1] = {
            _project = {
                _module = p.mod,
                type = p.type,
            },
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
