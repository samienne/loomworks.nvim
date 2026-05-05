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
        -- The legacy `[Fail]` tag is just a discriminator — the
        -- surfaced text strips the bracket prefix and shows the
        -- actual message content.
        local err = check({
            "[Fail]some hdc operation failed",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("some hdc operation failed", 1, true))
    end)

    it("detects [F] markers", function()
        -- `[F]` is two chars between brackets so clean() leaves it
        -- in the surfaced text (the strip pattern requires 3+).
        local err = check({
            "[F]hdc reported a failure",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("[F]", 1, true))
        assert.is_truthy(err:find("hdc reported a failure", 1, true))
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

    it("detects [INFO]-tagged hdc install failure (msg:error: format)", function()
        -- The shape `hdc install` actually emits: an [INFO]-tagged
        -- log line with the install path and a `msg:` field
        -- carrying the bundle-manager's rejection message. The
        -- earlier matcher missed this because the line did not
        -- start with `error:`.
        local err = check({
            "[INFO]App install path:/data/local/tmp/foo.hap"
                .. " msg:error: failed to install bundle.",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("failed to install", 1, true))
        -- The install-path noise must NOT be in the surfaced message.
        assert.is_nil(err:find("/data/local/tmp", 1, true))
    end)

    it("aggregates [INFO]-tagged code: and error: continuation lines", function()
        -- All three lines wear the [INFO] tag; clean() strips it
        -- before continuation-matching so `code:N` and follow-up
        -- `error:` still get aggregated.
        local err = check({
            "[INFO]App install path:/data/local/tmp/foo.hap"
                .. " msg:error: failed to install bundle.",
            "[INFO]code:9568320",
            "[INFO]error: no signature file.",
        })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("failed to install", 1, true))
        assert.is_truthy(err:find("9568320", 1, true))
        assert.is_truthy(err:find("no signature file", 1, true))
        assert.is_nil(err:find("[INFO]", 1, true),
            "log tags must be stripped from surfaced text")
    end)

    it("treats msg:result: ok as success (no error: in msg field)", function()
        -- Defensive: the [INFO]/msg: format also appears on
        -- success. Make sure we don't trip on the `[INFO]` tag
        -- itself or unrelated path content that happens to contain
        -- substrings like `error`.
        local err = check({
            "[INFO]App install path:/data/local/tmp/foo.hap"
                .. " msg:install bundle successfully.",
        })
        assert.is_nil(err)
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
