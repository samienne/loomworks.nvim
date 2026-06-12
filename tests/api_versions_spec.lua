--- Tests for the strict-equality API version check on the module
--- and SDK registries. The check is the contract gate between
--- loomworks core and plugin modules — a typo or comparison-
--- operator inversion would let mismatched plugins load silently,
--- which is exactly what the strict check is meant to prevent.
---
--- Approach: stub the package.loaded entry for a fake module /
--- SDK file path, register a table with the right shape but a
--- wrong api_version, and assert M.get() returns nil. Then flip
--- to the matching version and assert M.get() returns the table.

local modules = require("loomworks.modules")
local sdks = require("loomworks.sdks")
local API = require("loomworks.api_versions")

--- vim.notify swallower so the rejection notifications don't bleed
--- into the test output. Plenary's busted assertion library lets
--- us replace and restore via before_each / after_each.
local function silence_notify()
    local original = vim.notify
    vim.notify = function() end
    return original
end

local function restore_notify(original)
    vim.notify = original
end

-- Each test uses a unique fake id so the registry's "rejected once,
-- stay rejected" cache doesn't bleed between tests (clearing it
-- would require exposing internal state). after_each wipes the
-- package cache so the next test can register fresh.

describe("modules registry version check", function()
    local original_notify
    local fakes = {}  -- track ids to clean up

    local function add(id, value)
        package.loaded["loomworks.modules." .. id] = value
        fakes[#fakes + 1] = id
    end

    before_each(function()
        original_notify = silence_notify()
    end)
    after_each(function()
        restore_notify(original_notify)
        for _, id in ipairs(fakes) do
            package.loaded["loomworks.modules." .. id] = nil
        end
        fakes = {}
    end)

    it("rejects a module whose api_version is below core's expected", function()
        add("_apiv_old_mod", {
            id = "_apiv_old_mod",
            api_version = API.module - 1,
            detect = function() end, info = function() end,
            map_variant = function() end, progress_parser = function() end,
        })
        assert.is_nil(modules.get("_apiv_old_mod"))
    end)

    it("rejects a module whose api_version is above core's expected", function()
        add("_apiv_above_mod", {
            id = "_apiv_above_mod",
            api_version = API.module + 1,
            detect = function() end, info = function() end,
            map_variant = function() end, progress_parser = function() end,
        })
        assert.is_nil(modules.get("_apiv_above_mod"))
    end)

    it("rejects a module that omits api_version entirely", function()
        add("_apiv_missing_mod", {
            id = "_apiv_missing_mod",
            detect = function() end, info = function() end,
            map_variant = function() end, progress_parser = function() end,
        })
        assert.is_nil(modules.get("_apiv_missing_mod"))
    end)

    it("accepts a module whose api_version matches", function()
        add("_apiv_match_mod", {
            id = "_apiv_match_mod",
            api_version = API.module,
            detect = function() end, info = function() end,
            map_variant = function() end, progress_parser = function() end,
        })
        local mod = modules.get("_apiv_match_mod")
        assert.is_not_nil(mod)
        assert.equals("_apiv_match_mod", mod.id)
    end)

    --- Built-in modules MUST declare the right version — this is a
    --- canary that catches us forgetting to bump a built-in when we
    --- bump API.module on the core side.
    it("every built-in module declares the matching api_version", function()
        for _, id in ipairs({ "cmake", "meson", "shell", "typescript" }) do
            local mod = modules.get(id)
            assert.is_not_nil(mod, "built-in module '" .. id
                .. "' must load (api_version drift?)")
            assert.equals(API.module, mod.api_version,
                "built-in module '" .. id
                    .. "' declares api_version=" .. tostring(mod.api_version)
                    .. " but core expects " .. tostring(API.module))
        end
    end)
end)

describe("sdks registry version check", function()
    local original_notify
    local fakes = {}

    local function add(id, value)
        package.loaded["loomworks.sdks." .. id] = value
        fakes[#fakes + 1] = id
    end

    before_each(function()
        original_notify = silence_notify()
    end)
    after_each(function()
        restore_notify(original_notify)
        for _, id in ipairs(fakes) do
            package.loaded["loomworks.sdks." .. id] = nil
        end
        fakes = {}
    end)

    it("rejects an SDK provider with mismatched api_version", function()
        add("_apiv_old_sdk", {
            id = "_apiv_old_sdk",
            api_version = API.sdk - 1,
            display_name = "Fake",
        })
        assert.is_nil(sdks.get("_apiv_old_sdk"))
    end)

    it("accepts an SDK provider with matching api_version", function()
        add("_apiv_match_sdk", {
            id = "_apiv_match_sdk",
            api_version = API.sdk,
            display_name = "Fake",
        })
        local provider = sdks.get("_apiv_match_sdk")
        assert.is_not_nil(provider)
        assert.equals("_apiv_match_sdk", provider.id)
    end)

    it("every built-in SDK provider declares the matching api_version", function()
        for _, id in ipairs({ "cpp_compiler" }) do
            local provider = sdks.get(id)
            assert.is_not_nil(provider, "built-in SDK provider '" .. id
                .. "' must load (api_version drift?)")
            assert.equals(API.sdk, provider.api_version,
                "built-in SDK provider '" .. id
                    .. "' declares api_version=" .. tostring(provider.api_version)
                    .. " but core expects " .. tostring(API.sdk))
        end
    end)
end)
