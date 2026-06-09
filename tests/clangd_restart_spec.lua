--- Tests for the clangd-specific OOM-adaptive restart policy. We test
--- on_unexpected_exit directly with synthetic exit infos so we don't
--- need an actual clangd process — the only thing that matters here
--- is "given this exit code + signal + prior state, what does it
--- recommend next?"

-- Load lsp.lua FIRST so its bottom-of-module discover() doesn't try to
-- pcall(require, "...clangd") at the exact moment we're mid-loading
-- clangd ourselves. After lsp.lua is in place, requiring clangd just
-- runs the file body and registers — no recursive discover() call.
require("loomworks.lsp")
package.loaded["loomworks.integrations.lsp.clangd"] = nil
local clangd = require("loomworks.integrations.lsp.clangd")

--- Drive a sequence of cmd_factory invocations to seed `_j_state` for
--- a root_dir. We can't call the real cmd_factory (it spawns a
--- process); instead we look at the public surface and observe the
--- decisions on_unexpected_exit makes.
local function exit_info(opts)
    return {
        server = "clangd",
        root_dir = opts.root_dir or "/work/A",
        exit_code = opts.exit_code or 0,
        signal = opts.signal or 0,
        attempt = opts.attempt or 1,
        args = opts.args or { "clangd" },
    }
end

describe("clangd on_unexpected_exit", function()
    -- Reload only the clangd module between tests so the per-root
    -- adaptive state resets. lsp.lua stays loaded — nuking it triggers
    -- a discover() loop that re-requires the clangd we're mid-loading.
    before_each(function()
        package.loaded["loomworks.integrations.lsp.clangd"] = nil
        clangd = require("loomworks.integrations.lsp.clangd")
    end)

    describe("OOM detection", function()
        it("seeds -j 12 on the first OOM (Linux SIGKILL)", function()
            local d = clangd.on_unexpected_exit(exit_info({ signal = 9 }))
            assert.is_true(d.restart)
            assert.is_truthy(d.reason:find("-j 12"),
                "expected `-j 12` in: " .. d.reason)
        end)

        it("halves -j on subsequent OOMs (12 → 6 → 3 → 1)", function()
            assert.is_truthy(clangd.on_unexpected_exit(exit_info({ signal = 9 })).reason:find("-j 12"))
            assert.is_truthy(clangd.on_unexpected_exit(exit_info({ signal = 9 })).reason:find("-j 6"))
            assert.is_truthy(clangd.on_unexpected_exit(exit_info({ signal = 9 })).reason:find("-j 3"))
            assert.is_truthy(clangd.on_unexpected_exit(exit_info({ signal = 9 })).reason:find("-j 1"))
        end)

        it("gives up when OOM hits at -j 1", function()
            for _ = 1, 5 do
                clangd.on_unexpected_exit(exit_info({ signal = 9 }))
            end
            local d = clangd.on_unexpected_exit(exit_info({ signal = 9 }))
            assert.is_false(d.restart)
            assert.is_truthy(d.reason:find("-j 1"))
        end)

        it("treats Windows STATUS_NO_MEMORY as OOM", function()
            local d = clangd.on_unexpected_exit(exit_info({ exit_code = 0xC0000017 }))
            assert.is_true(d.restart)
            assert.is_truthy(d.reason:find("-j 12"))
        end)

        it("treats Windows access violation as OOM (heuristic)", function()
            local d = clangd.on_unexpected_exit(exit_info({ exit_code = 0xC0000005 }))
            assert.is_true(d.restart)
        end)

        it("treats a plain crash (exit 1, signal 0) as non-OOM", function()
            local d = clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            assert.is_true(d.restart)
            assert.is_truthy(d.reason:lower():find("retry"))
        end)

        it("gives up after a non-OOM crash has been retried once", function()
            clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            local d = clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            assert.is_false(d.restart)
            assert.is_truthy(d.reason:lower():find("crash"))
        end)
    end)

    describe("reset", function()
        it("clears state so non-OOM retry budget refreshes", function()
            -- Burn the single retry.
            clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            local d_giveup = clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            assert.is_false(d_giveup.restart)

            -- Reset and we should be willing to retry again.
            clangd.reset("/work/A")
            local d_after = clangd.on_unexpected_exit(exit_info({ exit_code = 1 }))
            assert.is_true(d_after.restart)
        end)
    end)
end)
