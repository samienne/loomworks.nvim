--- Tests for compiler-cache resolution (core §1.3.2, module specs §5).
---
--- Covers the reserved `cache` policy variable (declaration rejected, override
--- allowed), policy resolution through the ordinary override machinery
--- (config chain, compiler-family override, profile fill, `auto` default), and
--- the policy→launcher resolver (family preference, PATH gating, `off`,
--- explicit tool, unknown family). No build wiring is exercised here.

local cc = require("loomworks.compiler_cache")
local variables = require("loomworks.variables")

--- A lookup stub: only the named tools resolve to a path.
--- @param present table<string, boolean>
--- @return fun(name: string): string|nil
local function lookup_of(present)
    return function(name)
        if present[name] then return "/usr/bin/" .. name end
        return nil
    end
end

-- ---------------------------------------------------------------------------
-- Reserved `cache` variable
-- ---------------------------------------------------------------------------
describe("reserved cache variable", function()
    it("is pre-declared", function()
        assert.is_true(variables.PREDECLARED_NAMES.cache)
    end)

    it("rejects a `cache` variable DECLARATION", function()
        local ok, err = variables.validate_declarations({
            cache = { type = "string", default = "auto" },
        })
        assert.is_false(ok)
        assert.matches("reserved", err)
    end)

    it("is NOT a built-in expansion name (kept out of RESERVED_NAMES)", function()
        assert.is_nil(variables.RESERVED_NAMES.cache)
    end)

    it("ACCEPTS `cache` as a plain variable override (undeclared elsewhere)", function()
        local ok = variables.validate_overrides({ cache = "ccache" }, {})
        assert.is_true(ok)
    end)

    it("accepts a boolean `false` (== off) cache override", function()
        assert.is_true(variables.validate_overrides({ cache = false }, {}))
    end)

    it("ACCEPTS `cache` as a compiler-family override", function()
        local ok = variables.validate_compiler_overrides(
            { msvc = { cache = "off" } }, {})
        assert.is_true(ok)
    end)

    it("still rejects a genuinely undeclared override name", function()
        local ok, err = variables.validate_overrides({ bogus = "x" }, {})
        assert.is_false(ok)
        assert.matches("not declared", err)
    end)
end)

-- ---------------------------------------------------------------------------
-- Policy resolution through the override machinery
-- ---------------------------------------------------------------------------
describe("resolve_cache_policy", function()
    it("defaults to auto when nothing sets it", function()
        local project = { key = "App", variables = {} }
        assert.equals("auto", variables.resolve_cache_policy(project, nil, nil, nil))
    end)

    it("reads a configuration `variables` override", function()
        local cfg = { variables = { cache = "ccache" } }
        local project = { key = "App", variables = {} }
        assert.equals("ccache", variables.resolve_cache_policy(project, cfg, nil, nil))
    end)

    it("prefers a compiler-family override for the active family", function()
        local cfg = {
            variables = { cache = "auto" },
            _overrides = { msvc = { cache = "off" } },
        }
        local project = { key = "App", variables = {} }
        assert.equals("off", variables.resolve_cache_policy(project, cfg, "msvc", nil))
        -- A different family falls through to the plain value.
        assert.equals("auto", variables.resolve_cache_policy(project, cfg, "gcc", nil))
    end)

    it("walks the inheritance chain (nearer config wins)", function()
        local base = { variables = { cache = "ccache" } }
        local child = { variables = {}, _inherits = { base } }
        local project = { key = "App", variables = {} }
        assert.equals("ccache", variables.resolve_cache_policy(project, child, nil, nil))
    end)

    it("falls to the active-profile fill when the chain is silent", function()
        local project = { key = "App", variables = {} }
        local profile = {
            variable_value = function(_, pkey, name)
                if pkey == "App" and name == "cache" then return "sccache" end
            end,
        }
        assert.equals("sccache",
            variables.resolve_cache_policy(project, nil, nil, profile))
    end)

    it("config value shadows the profile fill", function()
        local cfg = { variables = { cache = "off" } }
        local project = { key = "App", variables = {} }
        local profile = {
            variable_value = function() return "ccache" end,
        }
        assert.equals("off", variables.resolve_cache_policy(project, cfg, nil, profile))
    end)
end)

-- ---------------------------------------------------------------------------
-- normalize_policy
-- ---------------------------------------------------------------------------
describe("normalize_policy", function()
    it("maps nil/empty/auto to auto", function()
        assert.equals("auto", cc.normalize_policy(nil))
        assert.equals("auto", cc.normalize_policy(""))
        assert.equals("auto", cc.normalize_policy("auto"))
        assert.equals("auto", cc.normalize_policy("AUTO"))
    end)

    it("maps false and off-synonyms to off", function()
        assert.equals("off", cc.normalize_policy(false))
        assert.equals("off", cc.normalize_policy("off"))
        assert.equals("off", cc.normalize_policy("false"))
        assert.equals("off", cc.normalize_policy("none"))
    end)

    it("passes an explicit launcher through lower-cased", function()
        assert.equals("ccache", cc.normalize_policy("ccache"))
        assert.equals("sccache", cc.normalize_policy("SCCACHE"))
    end)
end)

-- ---------------------------------------------------------------------------
-- Policy → launcher resolution
-- ---------------------------------------------------------------------------
describe("compiler_cache.resolve", function()
    local both = lookup_of({ ccache = true, sccache = true })

    it("auto + gcc prefers ccache", function()
        local r = cc.resolve("auto", "gcc", both)
        assert.equals("ccache", r.tool)
        assert.matches("ccache$", r.path)
    end)

    it("auto + clang prefers ccache", function()
        assert.equals("ccache", cc.resolve("auto", "clang", both).tool)
    end)

    it("auto + msvc prefers sccache", function()
        assert.equals("sccache", cc.resolve("auto", "msvc", both).tool)
    end)

    it("auto + gcc falls back to sccache when ccache is absent", function()
        local only_scc = lookup_of({ sccache = true })
        assert.equals("sccache", cc.resolve("auto", "gcc", only_scc).tool)
    end)

    it("auto + msvc falls back to ccache when sccache is absent", function()
        local only_cc = lookup_of({ ccache = true })
        assert.equals("ccache", cc.resolve("auto", "msvc", only_cc).tool)
    end)

    it("returns nil under auto when neither is on PATH", function()
        assert.is_nil(cc.resolve("auto", "gcc", lookup_of({})))
    end)

    it("off resolves to nil even when tools are present", function()
        assert.is_nil(cc.resolve("off", "gcc", both))
        assert.is_nil(cc.resolve(false, "msvc", both))
    end)

    it("an explicit launcher uses exactly that tool (PATH-gated)", function()
        assert.equals("sccache", cc.resolve("sccache", "gcc", both).tool)
        -- ...but yields nil when the named tool is not installed.
        assert.is_nil(cc.resolve("ccache", "gcc", lookup_of({ sccache = true })))
    end)

    it("clang-cl folds to clang for auto preference", function()
        -- normalize_family folds clang-cl → clang, which prefers ccache;
        -- on a cache-less-ccache box the sccache fallback still applies.
        assert.equals("ccache", cc.resolve("auto", "clang-cl", both).tool)
        assert.equals("sccache",
            cc.resolve("auto", "clang-cl", lookup_of({ sccache = true })).tool)
    end)

    it("an unknown/nil family uses the default preference", function()
        assert.equals("ccache", cc.resolve("auto", "tcc", both).tool)
        assert.equals("ccache", cc.resolve("auto", nil, both).tool)
        assert.is_nil(cc.resolve("auto", "tcc", lookup_of({})))
    end)
end)

-- ---------------------------------------------------------------------------
-- resolve_for (policy resolution + launcher, combined)
-- ---------------------------------------------------------------------------
describe("compiler_cache.resolve_for", function()
    local both = lookup_of({ ccache = true, sccache = true })

    it("resolves auto policy against a gcc tool_data", function()
        local project = { key = "App", variables = {} }
        local r = cc.resolve_for(project, nil, { compiler_id = "gcc-13" }, nil, both)
        assert.equals("ccache", r.tool)
    end)

    it("honors an off policy set on the configuration", function()
        local project = { key = "App", variables = {} }
        local cfg = { variables = { cache = "off" } }
        assert.is_nil(cc.resolve_for(project, cfg, { compiler_id = "gcc-13" }, nil, both))
    end)

    it("honors a compiler-family override keyed to the tool's family", function()
        local project = { key = "App", variables = {} }
        local cfg = {
            variables = { cache = "auto" },
            _overrides = { msvc = { cache = "off" } },
        }
        -- msvc tool_data → override says off → nil
        assert.is_nil(cc.resolve_for(project, cfg,
            { compiler_family = "msvc" }, nil, both))
        -- gcc tool_data → plain auto → ccache
        assert.equals("ccache", cc.resolve_for(project, cfg,
            { compiler_family = "gcc" }, nil, both).tool)
    end)

    it("returns nil for a nil project", function()
        assert.is_nil(cc.resolve_for(nil, nil, {}, nil, both))
    end)
end)

-- ---------------------------------------------------------------------------
-- any_present
-- ---------------------------------------------------------------------------
describe("compiler_cache.any_present", function()
    it("reports the present launcher, preferring sccache", function()
        assert.equals("sccache", cc.any_present(lookup_of({ sccache = true, ccache = true })))
        assert.equals("ccache", cc.any_present(lookup_of({ ccache = true })))
    end)

    it("returns nil when none is installed", function()
        assert.is_nil(cc.any_present(lookup_of({})))
    end)
end)
