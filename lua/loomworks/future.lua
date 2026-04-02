--- loomworks/future.lua — Promise/Future for async operation chaining.
---
--- A Future represents a value that will be available later. Futures
--- resolve with success (values) or error (message). Chains via :then()
--- compose naturally — if a callback returns a Future, it is joined
--- (no Future<Future<...>> nesting). when_all() waits for multiple
--- Futures to resolve.
---
--- Every Future is guaranteed to resolve exactly once. Callbacks on
--- already-resolved Futures fire immediately (via vim.schedule).

--- @class loomworks.Future
--- @field _state "pending"|"resolved"|"rejected"
--- @field _values any[] resolved values
--- @field _error string|nil rejection error
--- @field _callbacks { resolve: fun(...: any), reject: fun(err: string) }[]
local Future = {}
Future.__index = Future

local M = {}

--- Create a new pending Future.
--- @return loomworks.Future
function Future.new()
    local self = setmetatable({}, Future)
    self._state = "pending"
    self._values = nil
    self._error = nil
    self._callbacks = {}
    return self
end

--- Create a Future that is already resolved with the given values.
--- @param ... any values
--- @return loomworks.Future
function M.resolved(...)
    local f = Future.new()
    f._state = "resolved"
    f._values = { ... }
    return f
end

--- Create a Future that is already rejected with an error.
--- @param err string error message
--- @return loomworks.Future
function M.rejected(err)
    local f = Future.new()
    f._state = "rejected"
    f._error = err
    return f
end

--- Create a Future from a callback-style function.
--- The function receives a resolve(...) and reject(err) callback.
--- @param fn fun(resolve: fun(...: any), reject: fun(err: string))
--- @return loomworks.Future
function M.create(fn)
    local f = Future.new()
    fn(
        function(...) f:_resolve(...) end,
        function(err) f:_reject(err) end
    )
    return f
end

--- Resolve this Future with values.
--- @param ... any values
function Future:_resolve(...)
    if self._state ~= "pending" then return end
    self._state = "resolved"
    self._values = { ... }
    self:_flush()
end

--- Reject this Future with an error.
--- @param err string error message
function Future:_reject(err)
    if self._state ~= "pending" then return end
    self._state = "rejected"
    self._error = err or "unknown error"
    self:_flush()
end

--- Flush pending callbacks after resolution/rejection.
function Future:_flush()
    local callbacks = self._callbacks
    self._callbacks = {}
    for _, cb in ipairs(callbacks) do
        if self._state == "resolved" then
            cb.resolve(unpack(self._values))
        else
            cb.reject(self._error)
        end
    end
end

--- Chain a callback to run when this Future resolves.
--- Returns a new Future for the callback's result.
---
--- If the callback returns a Future, the returned Future joins it
--- (no Future<Future<...>> nesting). If the callback returns plain
--- values, the returned Future resolves with those values.
--- If the callback throws, the returned Future rejects.
---
--- @param on_resolve? fun(...: any): any callback for success
--- @param on_reject? fun(err: string): any callback for error
--- @return loomworks.Future chained future
function Future:next(on_resolve, on_reject)
    local result = Future.new()

    local function handle_resolve(...)
        if not on_resolve then
            result:_resolve(...)
            return
        end
        local ok, ret = pcall(on_resolve, ...)
        if not ok then
            result:_reject(tostring(ret))
            return
        end
        if type(ret) == "table" and getmetatable(ret) == Future then
            -- Join: inner Future controls outer result
            ret:next(
                function(...) result:_resolve(...) end,
                function(err) result:_reject(err) end
            )
        else
            result:_resolve(ret)
        end
    end

    local function handle_reject(err)
        if not on_reject then
            result:_reject(err)
            return
        end
        local ok, ret = pcall(on_reject, err)
        if not ok then
            result:_reject(tostring(ret))
            return
        end
        if type(ret) == "table" and getmetatable(ret) == Future then
            ret:next(
                function(...) result:_resolve(...) end,
                function(e) result:_reject(e) end
            )
        else
            result:_resolve(ret)
        end
    end

    if self._state == "resolved" then
        handle_resolve(unpack(self._values))
    elseif self._state == "rejected" then
        handle_reject(self._error)
    else
        self._callbacks[#self._callbacks + 1] = {
            resolve = handle_resolve,
            reject = handle_reject,
        }
    end

    return result
end

--- Alias for :next() — more familiar name.
Future["then"] = Future.next

--- Catch errors in the chain.
--- @param on_reject fun(err: string): any
--- @return loomworks.Future
function Future:catch(on_reject)
    return self:next(nil, on_reject)
end

--- Wait for all Futures to resolve. The resulting Future resolves with
--- an array of result arrays (one per input Future). If any Future
--- rejects, the result rejects with the first error.
--- @param futures loomworks.Future[]
--- @return loomworks.Future resolves with { {values1...}, {values2...}, ... }
function M.when_all(futures)
    if #futures == 0 then
        return M.resolved({})
    end

    local result = Future.new()
    local remaining = #futures
    local results = {}
    local rejected = false

    for i, f in ipairs(futures) do
        f:next(
            function(...)
                if rejected then return end
                results[i] = { ... }
                remaining = remaining - 1
                if remaining == 0 then
                    result:_resolve(results)
                end
            end,
            function(err)
                if rejected then return end
                rejected = true
                result:_reject(err)
            end
        )
    end

    return result
end

--- Wait for all Futures, collecting both successes and failures.
--- Never rejects — resolves with an array of { ok: boolean, values?: any[], error?: string }.
--- @param futures loomworks.Future[]
--- @return loomworks.Future
function M.when_all_settled(futures)
    if #futures == 0 then
        return M.resolved({})
    end

    local result = Future.new()
    local remaining = #futures
    local results = {}

    for i, f in ipairs(futures) do
        f:next(
            function(...)
                results[i] = { ok = true, values = { ... } }
                remaining = remaining - 1
                if remaining == 0 then result:_resolve(results) end
            end,
            function(err)
                results[i] = { ok = false, error = err }
                remaining = remaining - 1
                if remaining == 0 then result:_resolve(results) end
            end
        )
    end

    return result
end

--- Check if this Future is still pending.
--- @return boolean
function Future:is_pending()
    return self._state == "pending"
end

--- Check if this Future resolved successfully.
--- @return boolean
function Future:is_resolved()
    return self._state == "resolved"
end

--- Check if this Future was rejected.
--- @return boolean
function Future:is_rejected()
    return self._state == "rejected"
end

function Future:__tostring()
    if self._state == "resolved" then
        return "Future(resolved)"
    elseif self._state == "rejected" then
        return "Future(rejected: " .. tostring(self._error) .. ")"
    end
    return "Future(pending)"
end

M.Future = Future

return M
