local M = {}

--- @type table<string, function[]>
local listeners = {}

--- Register a listener for an event.
--- @param event string
--- @param fn function
function M.on(event, fn)
    if not listeners[event] then
        listeners[event] = {}
    end
    listeners[event][#listeners[event] + 1] = fn
end

--- Remove a listener for an event.
--- @param event string
--- @param fn function
function M.off(event, fn)
    if not listeners[event] then return end
    for i, listener in ipairs(listeners[event]) do
        if listener == fn then
            table.remove(listeners[event], i)
            return
        end
    end
end

--- Emit an event, calling all registered listeners with the given data.
--- @param event string
--- @param data any
function M.emit(event, data)
    if not listeners[event] then return end
    for _, fn in ipairs(listeners[event]) do
        local ok, err = pcall(fn, data)
        if not ok then
            vim.notify("loomworks: event '" .. event .. "' listener error: " .. tostring(err), vim.log.levels.ERROR)
        end
    end
end

return M
