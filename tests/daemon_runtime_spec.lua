-- Runtime-mode resolution: env override > configured > in-process default.

local runtime = require("loomworks.daemon.runtime")

local function fake_env(map)
    return { getenv = function(name) return map[name] end }
end

describe("daemon.runtime resolve", function()
    it("defaults to in-process with no config and no env", function()
        local mode, warn = runtime.resolve(nil, fake_env({}))
        assert.equals("in-process", mode)
        assert.is_nil(warn)
        assert.equals("in-process", runtime.DEFAULT)
    end)

    it("uses the configured value when valid", function()
        assert.equals("daemon", (runtime.resolve("daemon", fake_env({}))))
        assert.equals("auto", (runtime.resolve("auto", fake_env({}))))
    end)

    it("lets LOOMWORKS_RUNTIME override the configured value", function()
        local mode = runtime.resolve("in-process", fake_env({ LOOMWORKS_RUNTIME = "daemon" }))
        assert.equals("daemon", mode)
    end)

    it("ignores an invalid env value and warns, falling to config", function()
        local mode, warn = runtime.resolve("daemon", fake_env({ LOOMWORKS_RUNTIME = "bogus" }))
        assert.equals("daemon", mode)
        assert.is_truthy(warn)
    end)

    it("ignores an invalid configured value and warns, falling to default", function()
        local mode, warn = runtime.resolve("nonsense", fake_env({}))
        assert.equals("in-process", mode)
        assert.is_truthy(warn)
    end)

    it("treats an empty env string as unset", function()
        local mode = runtime.resolve("auto", fake_env({ LOOMWORKS_RUNTIME = "" }))
        assert.equals("auto", mode)
    end)

    it("validates the mode enum", function()
        assert.is_true(runtime.is_valid("in-process"))
        assert.is_true(runtime.is_valid("daemon"))
        assert.is_true(runtime.is_valid("auto"))
        assert.is_false(runtime.is_valid("x"))
        assert.is_false(runtime.is_valid(nil))
    end)
end)
