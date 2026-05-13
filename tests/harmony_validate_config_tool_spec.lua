--- Tests for harmony.validate_config_tool — enforces that the
--- profile's harmony tool matches the configuration's product on
--- both platform (HarmonyOS vs OpenHarmony) and arch axes. See
--- spec/modules/harmony.md §4a.

local harmony = require("loomworks.modules.harmony")

local function cfg(module_config)
    return { module_config = module_config }
end

local function tool(data)
    return { data = data }
end

describe("harmony.validate_config_tool", function()
    it("accepts a fully-matching tool", function()
        local ok = harmony.validate_config_tool(
            cfg({ runtime_os = "HarmonyOS", abi = "arm64-v8a" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_true(ok)
    end)

    it("rejects a platform mismatch", function()
        local ok, reason = harmony.validate_config_tool(
            cfg({ runtime_os = "OpenHarmony", abi = "arm64-v8a" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_false(ok)
        assert.is_truthy(reason:find("OpenHarmony"))
        assert.is_truthy(reason:find("HarmonyOS"))
    end)

    it("rejects an arch mismatch", function()
        local ok, reason = harmony.validate_config_tool(
            cfg({ runtime_os = "HarmonyOS", abi = "armeabi-v7a" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_false(ok)
        assert.is_truthy(reason:find("armeabi%-v7a"))
        assert.is_truthy(reason:find("arm64%-v8a"))
    end)

    it("reports both axes when both mismatch", function()
        local ok, reason = harmony.validate_config_tool(
            cfg({ runtime_os = "OpenHarmony", abi = "armeabi-v7a" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_false(ok)
        assert.is_truthy(reason:find("HarmonyOS"))
        assert.is_truthy(reason:find("OpenHarmony"))
        assert.is_truthy(reason:find("arm64%-v8a"))
        assert.is_truthy(reason:find("armeabi%-v7a"))
    end)

    it("is permissive when the configuration has no runtime_os", function()
        -- Older cache entries pre-date the field. Don't fail on
        -- missing data — the check resolves once a sync captures the
        -- field afresh from build-profile.json5.
        local ok = harmony.validate_config_tool(
            cfg({}),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_true(ok)
    end)

    it("is permissive when the tool has no platform/arch claim", function()
        -- Legacy SDK-fallback tools (kits_from_sdk hit the no-kits
        -- branch) don't carry platform/arch. With no claim there's
        -- nothing to verify, so accept the configuration unchanged.
        local ok = harmony.validate_config_tool(
            cfg({ runtime_os = "HarmonyOS", abi = "arm64-v8a" }),
            tool({ sdk_key = "deveco-6.0.1" }))
        assert.is_true(ok)
    end)

    it("skips arch check for non-native (ArkTS-only) configs", function()
        -- Non-native configs (no `abi` field) target a runtimeOS but
        -- don't compile native code, so the arch axis doesn't apply.
        -- Platform alone is checked.
        local ok = harmony.validate_config_tool(
            cfg({ runtime_os = "HarmonyOS" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_true(ok)
    end)

    it("still rejects platform mismatch on non-native configs", function()
        local ok, reason = harmony.validate_config_tool(
            cfg({ runtime_os = "OpenHarmony" }),
            tool({ platform = "HarmonyOS", arch = "arm64-v8a" }))
        assert.is_false(ok)
        assert.is_truthy(reason:find("OpenHarmony"))
        assert.is_truthy(reason:find("HarmonyOS"))
    end)

    it("returns true when tool itself is nil", function()
        local ok = harmony.validate_config_tool(
            cfg({ runtime_os = "HarmonyOS", abi = "arm64-v8a" }),
            nil)
        assert.is_true(ok)
    end)
end)
