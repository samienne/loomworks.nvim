--- Tests for the fidget recovery hatch (`:LoomworksFidgetClear`).
---
--- The fidget integration tracks handles in a module-local table
--- keyed by operation/task identity, finishing them on the
--- corresponding completion events. When that event sequence is
--- disrupted (a dap session terminates before initialising, an
--- adapter isn't configured, etc.), a handle is orphaned and the
--- fidget popup spins forever — even after every overseer task has
--- already completed. `M.clear()` is the recovery hatch: cancels
--- every tracked handle so the user doesn't have to restart Neovim.

local function with_fake_fidget(fn)
    -- Replace the cached fidget.progress module with a stub that
    -- yields handles tracking their cancel state. Save and restore
    -- the cache around the test so other suites are unaffected.
    local prev_progress = package.loaded["fidget.progress"]
    local prev_lw = package.loaded["loomworks.fidget"]

    local cancelled = {}
    local fake_progress = {
        handle = {
            create = function(_)
                local id = #cancelled + 1
                cancelled[id] = false
                return {
                    report = function() end,
                    finish = function(self)
                        -- Track finish as cancel for symmetry — the
                        -- test only cares that the handle was wound
                        -- down, not which terminal call was used.
                        cancelled[id] = true
                    end,
                    cancel = function(self)
                        cancelled[id] = true
                    end,
                }
            end,
        },
    }
    package.loaded["fidget.progress"] = fake_progress
    -- Force-reload loomworks.fidget so it picks up the stub.
    package.loaded["loomworks.fidget"] = nil

    local ok, err = pcall(fn, cancelled)

    -- Restore.
    package.loaded["fidget.progress"] = prev_progress
    package.loaded["loomworks.fidget"] = prev_lw

    if not ok then error(err) end
end

describe("loomworks.fidget.clear", function()
    it("returns 0 when no handles are tracked", function()
        with_fake_fidget(function()
            local fidget = require("loomworks.fidget")
            fidget.setup({})
            assert.equals(0, fidget.clear())
        end)
    end)

    it("returns 0 when fidget.nvim is not loaded", function()
        -- Without the stub: M.setup short-circuits, fidget_progress
        -- stays nil, M.clear returns 0 silently.
        local prev_progress = package.loaded["fidget.progress"]
        local prev_lw = package.loaded["loomworks.fidget"]
        package.loaded["fidget.progress"] = nil
        package.preload["fidget.progress"] = nil
        package.loaded["loomworks.fidget"] = nil

        local fidget = require("loomworks.fidget")
        fidget.setup({})
        assert.equals(0, fidget.clear())

        package.loaded["fidget.progress"] = prev_progress
        package.loaded["loomworks.fidget"] = prev_lw
    end)

    it("cancels all outstanding handles created via start_action", function()
        with_fake_fidget(function(cancelled)
            local fidget = require("loomworks.fidget")
            fidget.setup({})

            local h1 = fidget.start_action("Building Foo")
            local h2 = fidget.start_action("Launching Bar")
            local h3 = fidget.start_action("Debugging Baz")

            assert.is_not_nil(h1)
            assert.is_not_nil(h2)
            assert.is_not_nil(h3)

            local cleared = fidget.clear()
            assert.equals(3, cleared)

            -- All three handles received a cancel/finish call.
            for id, was_cancelled in pairs(cancelled) do
                assert.is_true(was_cancelled,
                    "handle " .. id .. " was not wound down")
            end
        end)
    end)

    it("is idempotent — second call returns 0", function()
        with_fake_fidget(function()
            local fidget = require("loomworks.fidget")
            fidget.setup({})
            fidget.start_action("Foo")
            fidget.start_action("Bar")

            assert.equals(2, fidget.clear())
            assert.equals(0, fidget.clear())
        end)
    end)

    it("subsequent start_action still works after clear", function()
        -- Recovery hatch must not poison the integration. After
        -- clear, the next start_action gets a fresh handle as
        -- normal.
        with_fake_fidget(function()
            local fidget = require("loomworks.fidget")
            fidget.setup({})
            fidget.start_action("Pre-clear")
            fidget.clear()

            local h = fidget.start_action("Post-clear")
            assert.is_not_nil(h)
        end)
    end)

    it("survives a cancel that throws — pcall isolates each handle", function()
        -- A misbehaving handle (fidget.nvim version mismatch, weird
        -- internal state) must not stop the sweep. clear() wraps
        -- each cancel in pcall and continues.
        local prev_progress = package.loaded["fidget.progress"]
        local prev_lw = package.loaded["loomworks.fidget"]

        package.loaded["fidget.progress"] = {
            handle = {
                create = function()
                    return {
                        report = function() end,
                        finish = function() end,
                        cancel = function() error("boom") end,
                    }
                end,
            },
        }
        package.loaded["loomworks.fidget"] = nil

        local fidget = require("loomworks.fidget")
        fidget.setup({})
        fidget.start_action("Throwing 1")
        fidget.start_action("Throwing 2")

        -- Should not propagate the error.
        local cleared = fidget.clear()
        assert.equals(2, cleared)

        package.loaded["fidget.progress"] = prev_progress
        package.loaded["loomworks.fidget"] = prev_lw
    end)
end)
