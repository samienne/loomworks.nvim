--- Tests for loomworks.future — Promise/Future async chaining.

local future_mod = require("loomworks.future")
local Future = future_mod.Future

describe("Future", function()
    describe("basic resolution", function()
        it("resolves with values", function()
            local f = Future.new()
            local got
            f:next(function(v) got = v end)
            f:_resolve(42)
            assert.equals(42, got)
        end)

        it("resolves with multiple values", function()
            local f = Future.new()
            local a, b
            f:next(function(x, y) a = x; b = y end)
            f:_resolve("hello", "world")
            assert.equals("hello", a)
            assert.equals("world", b)
        end)

        it("rejects with error", function()
            local f = Future.new()
            local err
            f:catch(function(e) err = e end)
            f:_reject("boom")
            assert.equals("boom", err)
        end)

        it("ignores double resolve", function()
            local f = Future.new()
            local got
            f:next(function(v) got = v end)
            f:_resolve(1)
            f:_resolve(2)
            assert.equals(1, got)
        end)

        it("ignores resolve after reject", function()
            local f = Future.new()
            local got_err
            f:catch(function(e) got_err = e end)
            f:_reject("err")
            f:_resolve(42)
            assert.equals("err", got_err)
        end)
    end)

    describe("pre-resolved", function()
        it("future_mod.resolved() creates resolved future", function()
            local f = future_mod.resolved(10, 20)
            assert.is_true(f:is_resolved())
        end)

        it("future_mod.rejected() creates rejected future", function()
            local f = future_mod.rejected("fail")
            assert.is_true(f:is_rejected())
        end)
    end)

    describe("create()", function()
        it("creates from callback-style function", function()
            local f = future_mod.create(function(resolve)
                resolve(99)
            end)
            assert.is_true(f:is_resolved())
        end)

        it("creates rejected from callback", function()
            local f = future_mod.create(function(_, reject)
                reject("bad")
            end)
            assert.is_true(f:is_rejected())
        end)
    end)

    describe("chaining with :next()", function()
        it("chains synchronous transforms", function()
            local f = Future.new()
            local got
            f:next(function(v) return v * 2 end)
             :next(function(v) got = v end)
            f:_resolve(5)
            assert.equals(10, got)
        end)

        it("propagates rejection through chain", function()
            local f = Future.new()
            local got_err
            f:next(function(v) return v * 2 end)
             :next(function(v) return v + 1 end)
             :catch(function(e) got_err = e end)
            f:_reject("fail")
            assert.equals("fail", got_err)
        end)

        it("catches error thrown in callback", function()
            local f = Future.new()
            local got_err
            f:next(function() error("oops") end)
             :catch(function(e) got_err = e end)
            f:_resolve(1)
            assert.truthy(got_err)
            assert.truthy(got_err:find("oops"))
        end)

        it("joins inner Future (no nesting)", function()
            local inner = Future.new()
            local f = Future.new()
            local got

            f:next(function()
                return inner  -- return a Future
            end):next(function(v)
                got = v
            end)

            f:_resolve()
            assert.is_nil(got)  -- inner not resolved yet

            inner:_resolve("from_inner")
            assert.equals("from_inner", got)
        end)

        it("joins inner Future rejection", function()
            local inner = Future.new()
            local f = Future.new()
            local got_err

            f:next(function() return inner end)
             :catch(function(e) got_err = e end)

            f:_resolve()
            inner:_reject("inner_fail")
            assert.equals("inner_fail", got_err)
        end)

        it("recovery in catch returns resolved Future", function()
            local f = Future.new()
            local got

            f:next(function() error("fail") end)
             :catch(function() return "recovered" end)
             :next(function(v) got = v end)

            f:_resolve()
            assert.equals("recovered", got)
        end)
    end)

    describe("when_all()", function()
        it("resolves when all resolve", function()
            local f1 = Future.new()
            local f2 = Future.new()
            local got

            future_mod.when_all({ f1, f2 }):next(function(results)
                got = results
            end)

            f1:_resolve("a")
            assert.is_nil(got)  -- f2 still pending

            f2:_resolve("b")
            assert.is_not_nil(got)
            assert.equals("a", got[1][1])
            assert.equals("b", got[2][1])
        end)

        it("rejects on first failure", function()
            local f1 = Future.new()
            local f2 = Future.new()
            local got_err

            future_mod.when_all({ f1, f2 }):catch(function(e) got_err = e end)

            f1:_reject("first_fail")
            assert.equals("first_fail", got_err)

            -- f2 resolving after rejection is ignored
            f2:_resolve("ignored")
        end)

        it("handles empty array", function()
            local got
            future_mod.when_all({}):next(function(results) got = results end)
            assert.is_not_nil(got)
            assert.equals(0, #got)
        end)

        it("preserves order regardless of resolution order", function()
            local f1 = Future.new()
            local f2 = Future.new()
            local f3 = Future.new()
            local got

            future_mod.when_all({ f1, f2, f3 }):next(function(results)
                got = results
            end)

            f3:_resolve("third")
            f1:_resolve("first")
            f2:_resolve("second")

            assert.equals("first", got[1][1])
            assert.equals("second", got[2][1])
            assert.equals("third", got[3][1])
        end)
    end)

    describe("when_all_settled()", function()
        it("collects both successes and failures", function()
            local f1 = Future.new()
            local f2 = Future.new()
            local got

            future_mod.when_all_settled({ f1, f2 }):next(function(results)
                got = results
            end)

            f1:_resolve("ok")
            f2:_reject("bad")

            assert.is_not_nil(got)
            assert.is_true(got[1].ok)
            assert.equals("ok", got[1].values[1])
            assert.is_false(got[2].ok)
            assert.equals("bad", got[2].error)
        end)
    end)

    describe("state queries", function()
        it("pending before resolution", function()
            local f = Future.new()
            assert.is_true(f:is_pending())
            assert.is_false(f:is_resolved())
            assert.is_false(f:is_rejected())
        end)

        it("resolved after resolve", function()
            local f = Future.new()
            f:_resolve(1)
            assert.is_false(f:is_pending())
            assert.is_true(f:is_resolved())
        end)

        it("rejected after reject", function()
            local f = Future.new()
            f:_reject("err")
            assert.is_false(f:is_pending())
            assert.is_true(f:is_rejected())
        end)
    end)

    describe("cancellation", function()
        it("cancel rejects with 'cancelled'", function()
            local f = Future.new()
            local got_err
            f:catch(function(e) got_err = e end)
            f:cancel()
            assert.equals("cancelled", got_err)
            assert.is_true(f:is_cancelled())
            assert.is_true(f:is_rejected())
        end)

        it("cancel with custom reason", function()
            local f = Future.new()
            local got_err
            f:catch(function(e) got_err = e end)
            f:cancel("user stopped")
            assert.equals("user stopped", got_err)
        end)

        it("cancel is ignored on resolved Future", function()
            local f = Future.new()
            f:_resolve(42)
            f:cancel()
            assert.is_true(f:is_resolved())
        end)

        it("cancel triggers token cleanup callbacks", function()
            local cleaned = false
            local f = future_mod.create(function(resolve, reject, token)
                token:on_cancel(function()
                    cleaned = true
                end)
            end)
            f:cancel()
            assert.is_true(cleaned)
        end)

        it("token:is_cancelled() returns true after cancel", function()
            local token_ref
            local f = future_mod.create(function(resolve, reject, token)
                token_ref = token
            end)
            assert.is_false(token_ref:is_cancelled())
            f:cancel()
            assert.is_true(token_ref:is_cancelled())
        end)

        it("resolve is suppressed after cancel", function()
            local resolve_fn
            local f = future_mod.create(function(resolve, reject, token)
                resolve_fn = resolve
            end)
            f:cancel()
            resolve_fn(42)  -- should be no-op
            assert.is_true(f:is_rejected())
            assert.equals("cancelled", f._error)
        end)

        it("cancel propagates upstream through chain", function()
            local parent = Future.new()
            local child = parent:next(function(v) return v end)

            child:cancel()
            assert.is_true(parent:is_rejected())
        end)

        it("cancel propagates upstream and triggers token", function()
            local cleaned = false
            local parent = future_mod.create(function(resolve, reject, token)
                token:on_cancel(function() cleaned = true end)
            end)
            local child = parent:next(function(v) return v end)

            child:cancel()
            assert.is_true(cleaned)
        end)

        it("multiple on_cancel callbacks all fire", function()
            local a, b = false, false
            local f = future_mod.create(function(resolve, reject, token)
                token:on_cancel(function() a = true end)
                token:on_cancel(function() b = true end)
            end)
            f:cancel()
            assert.is_true(a)
            assert.is_true(b)
        end)

        it("on_cancel registered after cancellation fires immediately", function()
            local token_ref
            local f = future_mod.create(function(resolve, reject, token)
                token_ref = token
            end)
            f:cancel()
            local late = false
            token_ref:on_cancel(function() late = true end)
            assert.is_true(late)
        end)
    end)
end)
