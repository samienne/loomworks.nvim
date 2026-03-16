local events = require("loomworks.events")

describe("events", function()
    -- Reset listeners between tests to avoid cross-contamination
    -- events module uses module-level state, so we use unique event names per test

    describe("on + emit", function()
        it("delivers event data to listener", function()
            local received = nil
            events.on("test_deliver", function(data)
                received = data
            end)
            events.emit("test_deliver", { foo = "bar" })
            assert.are.same({ foo = "bar" }, received)
            events.off("test_deliver", received) -- cleanup
        end)

        it("calls multiple listeners in order", function()
            local order = {}
            local fn1 = function() order[#order + 1] = 1 end
            local fn2 = function() order[#order + 1] = 2 end
            events.on("test_multi", fn1)
            events.on("test_multi", fn2)
            events.emit("test_multi")
            assert.are.same({ 1, 2 }, order)
            events.off("test_multi", fn1)
            events.off("test_multi", fn2)
        end)

        it("does nothing for event with no listeners", function()
            -- Should not error
            events.emit("test_no_listeners", { data = true })
        end)
    end)

    describe("off", function()
        it("removes a specific listener", function()
            local called = false
            local fn = function() called = true end
            events.on("test_off", fn)
            events.off("test_off", fn)
            events.emit("test_off")
            assert.is_false(called)
        end)

        it("does not affect other listeners", function()
            local called1, called2 = false, false
            local fn1 = function() called1 = true end
            local fn2 = function() called2 = true end
            events.on("test_off_other", fn1)
            events.on("test_off_other", fn2)
            events.off("test_off_other", fn1)
            events.emit("test_off_other")
            assert.is_false(called1)
            assert.is_true(called2)
            events.off("test_off_other", fn2)
        end)

        it("is safe for non-existent event", function()
            events.off("test_nonexistent", function() end)
        end)
    end)

    describe("error handling", function()
        it("continues calling listeners after one errors", function()
            local second_called = false
            local fn1 = function() error("boom") end
            local fn2 = function() second_called = true end
            events.on("test_error", fn1)
            events.on("test_error", fn2)
            events.emit("test_error")
            assert.is_true(second_called)
            events.off("test_error", fn1)
            events.off("test_error", fn2)
        end)
    end)
end)
