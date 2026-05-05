--- Tests for harmony.device_install failure detection
--- (spec/modules/harmony.md §6.2). hdc exits 0 even when an install
--- fails, so the returned `check_output` hook is the only signal that
--- breaks the build→deploy→install→launch chain. The hook must
--- recognise both the older `[Fail]` markers and the modern
--- `error: ... / code:<N>` family that DevEco Studio surfaces.

local harmony = require("loomworks.modules.harmony")

local tool_data = { hdc = "/usr/bin/hdc" }

local function check(lines)
    local spec = harmony.device_install(tool_data, "SERIAL123", "/tmp/app.hap")
    return spec.check_output(lines)
end

describe("harmony.device_install check_output", function()
    it("returns nil for empty output", function()
        assert.is_nil(check({}))
    end)

    it("returns nil for success-shaped output", function()
        local err = check({
            "install bundle successfully.",
        })
        assert.is_nil(err)
    end)

    it("detects [Fail] markers (legacy hdc subcommands)", function()
        local err = check({
            "[Fail]some hdc operation failed",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("Fail", 1, true))
    end)

    it("detects [F] markers", function()
        local err = check({
            "[F]hdc reported a failure",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("[F]", 1, true))
    end)

    it("detects modern hdc install failure (error: prefix)", function()
        local err = check({
            "error: failed to install bundle.",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:lower():find("failed to install", 1, true))
    end)

    it("aggregates code: and follow-up error: lines (no signature file)", function()
        -- This is the exact shape DevEco surfaces and the user's
        -- original failure report. The cause spans three lines —
        -- the hook must concatenate them so the surfaced message is
        -- actionable, not just "error: failed to install bundle."
        -- in isolation.
        local err = check({
            "error: failed to install bundle.",
            "code:9568320",
            "error: no signature file.",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("failed to install", 1, true))
        assert.is_truthy(err:find("9568320", 1, true))
        assert.is_truthy(err:find("no signature file", 1, true))
    end)

    it("handles error: line case-insensitively", function()
        local err = check({
            "Error: failed to install bundle.",
        })
        assert.is_not_nil(err)
    end)

    it("ignores unrelated noise before the error", function()
        local err = check({
            "Connecting to device SERIAL123",
            "Pushing /tmp/app.hap to /data/local/tmp/app.hap",
            "100% complete",
            "error: failed to install bundle.",
            "code:9568320",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("9568320", 1, true))
        -- Should not include the noise lines.
        assert.is_nil(err:find("Connecting", 1, true))
        assert.is_nil(err:find("Pushing", 1, true))
    end)

    it("stops aggregating at a blank line", function()
        local err = check({
            "error: failed to install bundle.",
            "",
            "code:9568320",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("failed to install", 1, true))
        -- code: was on the far side of a blank — not part of the
        -- same error block.
        assert.is_nil(err:find("9568320", 1, true))
    end)

    it("trims leading whitespace before matching error:", function()
        local err = check({
            "  error: failed to install bundle.",
        })
        assert.is_not_nil(err)
    end)
end)
