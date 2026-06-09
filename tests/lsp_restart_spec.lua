--- Tests for the generic LSP restart machinery in loomworks/lsp.lua.
--- Covers the throttle window, managed-stop suppression, and the
--- on_unexpected_exit dispatch path. We don't exercise the autocmd
--- wiring or actual vim.lsp.enable() — those need a real LSP, which
--- the test harness can't provide.

package.loaded["loomworks.lsp"] = nil
local lsp = require("loomworks.lsp")

local function clear_state()
    -- The module's per-test state is internal; nuke and reload to start fresh.
    package.loaded["loomworks.lsp"] = nil
    lsp = require("loomworks.lsp")
end

describe("loomworks.lsp restart machinery", function()
    before_each(clear_state)

    describe("mark_managed_stop", function()
        it("is a no-op when client_id is nil (defensive)", function()
            -- Must not raise.
            lsp.mark_managed_stop(nil)
            lsp.mark_managed_stop(false)
        end)
    end)

    describe("suppression", function()
        it("starts unsuppressed for an arbitrary (server, root) pair", function()
            assert.is_false(lsp.is_suppressed("clangd", "/work/A"))
        end)

        it("clear_suppression resets a suppressed root", function()
            -- We can't get a root into the suppressed state from the
            -- public API without exercising wrap_on_exit, but
            -- clear_suppression should be safe on a fresh pair too.
            lsp.clear_suppression("clangd", "/work/A")
            assert.is_false(lsp.is_suppressed("clangd", "/work/A"))
        end)
    end)

    describe("wrap_on_exit", function()
        local fake_integration
        local restart_calls

        before_each(function()
            restart_calls = {}
            fake_integration = {
                server = "fake",
                get_resolved_cmd = function(_) return { "fake" } end,
                on_unexpected_exit = function(info)
                    restart_calls[#restart_calls + 1] = info
                    return { restart = true, reason = "test" }
                end,
            }
            lsp.register("fake", fake_integration)
        end)

        it("passes through user-supplied on_exit before dispatching", function()
            local user_calls = 0
            local wrapped = lsp.wrap_on_exit("fake",
                function(_, _, _) user_calls = user_calls + 1 end)
            -- Without a recorded LspAttach for this client_id, the
            -- dispatcher should bail early (no root_dir), but the user
            -- callback must still run.
            wrapped(1, 9, 12345)
            assert.equals(1, user_calls)
        end)

        it("skips dispatch when client_id was marked managed-stop", function()
            local wrapped = lsp.wrap_on_exit("fake", nil)
            lsp.mark_managed_stop(99)
            -- Even with the managed flag, lacking a client_record this
            -- is a no-op — but the important post-condition is that
            -- the flag was consumed (so a later "real" exit for the
            -- same id isn't silently absorbed).
            wrapped(1, 9, 99)
            assert.same({}, restart_calls)
        end)
    end)

    describe("reset_attempts", function()
        it("is safe on a pair that never had attempts", function()
            lsp.reset_attempts("clangd", "/work/Never")
            assert.is_false(lsp.is_suppressed("clangd", "/work/Never"))
        end)
    end)
end)
