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

--- @class loomworks.CancelToken
--- @field _cancelled boolean
--- @field _callbacks fun()[]
local CancelToken = {}
CancelToken.__index = CancelToken

--- Create a new cancel token.
--- @return loomworks.CancelToken
function CancelToken.new()
    local self = setmetatable({}, CancelToken)
    self._cancelled = false
    self._callbacks = {}
    return self
end

--- Check if cancellation has been requested.
--- @return boolean
function CancelToken:is_cancelled()
    return self._cancelled
end

--- Register a cleanup callback that fires on cancellation.
--- If already cancelled, fires immediately.
--- @param fn fun() cleanup function
function CancelToken:on_cancel(fn)
    if self._cancelled then
        fn()
    else
        self._callbacks[#self._callbacks + 1] = fn
    end
end

--- Trigger cancellation. Fires all registered cleanup callbacks.
function CancelToken:_trigger()
    if self._cancelled then return end
    self._cancelled = true
    local cbs = self._callbacks
    self._callbacks = {}
    for _, fn in ipairs(cbs) do
        pcall(fn)
    end
end

--- @class loomworks.Future
--- @field _state "pending"|"resolved"|"rejected"|"cancelled"
--- @field _values any[] resolved values
--- @field _error string|nil rejection error
--- @field _callbacks { resolve: fun(...: any), reject: fun(err: string) }[]
--- @field _cancel_token loomworks.CancelToken|nil
--- @field _upstream loomworks.Future|nil parent Future for cancel propagation
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
    self._cancel_token = nil
    self._upstream = nil
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
--- The function receives resolve, reject, and a cancel token.
--- The token lets the operation check for cancellation and register cleanup.
--- @param fn fun(resolve: fun(...: any), reject: fun(err: string), token: loomworks.CancelToken)
--- @return loomworks.Future
function M.create(fn)
    local f = Future.new()
    local token = CancelToken.new()
    f._cancel_token = token
    local resolve = function(...)
        if not token:is_cancelled() then f:_resolve(...) end
    end
    local reject = function(err)
        if not token:is_cancelled() then f:_reject(err) end
    end
    local ok, err = pcall(fn, resolve, reject, token)
    if not ok then
        reject(err)
    end
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

--- Cancel this Future. Triggers cleanup callbacks on the cancel token,
--- rejects with "cancelled", and propagates cancellation upstream.
--- @param reason? string cancellation reason
function Future:cancel(reason)
    if self._state ~= "pending" then return end
    -- Trigger cancel token cleanup callbacks first (stop tasks, etc.)
    if self._cancel_token then
        self._cancel_token:_trigger()
    end
    -- Reject the Future
    self._state = "rejected"
    self._error = reason or "cancelled"
    self:_flush()
    -- Propagate upstream
    if self._upstream and self._upstream:is_pending() then
        self._upstream:cancel(reason)
    end
end

--- Check if this Future was cancelled.
--- @return boolean
function Future:is_cancelled()
    return self._state == "rejected" and self._error == "cancelled"
end

--- Get the cancel token for this Future (if created via M.create).
--- @return loomworks.CancelToken|nil
function Future:token()
    return self._cancel_token
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
    result._upstream = self

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
M.CancelToken = CancelToken

return M
