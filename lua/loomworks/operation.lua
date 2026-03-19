--- loomworks/operation.lua — Operation: a user-initiated action.
--- An Operation tracks ConfigUnit state changes to determine when all
--- affected units have reached their target state (or failed).
--- Supports two modes: "rank" for build/configure (state hierarchy)
--- and "deletion" for clean/delete (waits for deleting flag to clear).

--- @class loomworks.Operation
--- @field id number unique ID
--- @field action string "build"|"configure"|"configure+build"|"clean"|"delete"
--- @field profile loomworks.Profile|nil nil for config-level clean/delete
--- @field units loomworks.ConfigUnit[] affected units
--- @field target_states table<loomworks.ConfigUnit, loomworks.ConfigUnitState> expected end state per unit
--- @field started_at number
--- @field completed boolean
--- @field success boolean|nil nil while running, true/false when completed
--- @field message string|nil result message (set on completion)
--- @field _mode "rank"|"deletion" completion check mode
--- @field _unit_done table<loomworks.ConfigUnit, boolean> tracks which units are done
--- @field _unit_ok table<loomworks.ConfigUnit, boolean> tracks which units succeeded
--- @field _unsubscribers function[] listener cleanup functions
--- @field _on_complete? fun(op: loomworks.Operation) completion callback
--- @field _core loomworks.Core
local Operation = {}
Operation.__index = Operation

local next_id = 1

--- Format a duration in seconds to a compact string.
--- @param seconds number
--- @return string
local function format_duration(seconds)
    local s = math.floor(seconds)
    if s < 60 then
        return s .. "s"
    end
    local m = math.floor(s / 60)
    s = s % 60
    if m < 60 then
        return m .. "m" .. string.format("%02d", s) .. "s"
    end
    local h = math.floor(m / 60)
    m = m % 60
    return h .. "h" .. string.format("%02d", m) .. "m"
end

--- Determine completion mode from action type.
local DELETION_ACTIONS = { clean = true, delete = true }

--- Create a new Operation.
--- @param core loomworks.Core
--- @param profile loomworks.Profile|nil nil for config-level operations
--- @param action string
--- @param units loomworks.ConfigUnit[]
--- @param target_states table<loomworks.ConfigUnit, loomworks.ConfigUnitState>
--- @param on_complete? fun(op: loomworks.Operation) called when operation completes
--- @return loomworks.Operation
function Operation.new(core, profile, action, units, target_states, on_complete)
    local self = setmetatable({}, Operation)
    self.id = next_id
    next_id = next_id + 1
    self._core = core
    self.profile = profile
    self.action = action
    self.units = units
    self.target_states = target_states
    self.started_at = core._deps.clock()
    self.completed = false
    self.success = nil
    self.message = nil
    self._mode = DELETION_ACTIONS[action] and "deletion" or "rank"
    self._unit_done = {}
    self._unit_ok = {}
    self._unsubscribers = {}
    self._on_complete = on_complete

    -- For rank mode: check if units are already in target state.
    -- For deletion mode: skip initial check — units will be marked deleting
    -- after the Operation is created, and we complete when that flag clears.
    if self._mode == "rank" then
        for _, unit in ipairs(units) do
            self:_check_unit(unit)
        end
    end

    -- Subscribe to state changes on each unit
    for _, unit in ipairs(units) do
        if not self._unit_done[unit] then
            local unsub = unit:on_state_change(function(u)
                self:_on_unit_change(u)
            end)
            self._unsubscribers[#self._unsubscribers + 1] = unsub
        end
    end

    -- If all units were already done (rank mode only), complete immediately
    if self._mode == "rank" and not self.completed then
        self:_check_completion()
    end

    return self
end

--- State hierarchy: higher values imply all lower states were achieved.
--- "building" implies "configured" was reached. "built" implies both.
local STATE_RANK = {
    unconfigured     = 0,
    configuring      = 1,
    configured       = 2,
    building         = 3,
    built            = 4,
}

--- Check if a unit has reached its target state (or failed).
--- Rank mode: uses state hierarchy (e.g. "building" satisfies "configured").
--- Deletion mode: completes when unit is no longer deleting.
--- @param unit loomworks.ConfigUnit
function Operation:_check_unit(unit)
    if self._unit_done[unit] then return end

    if self._mode == "deletion" then
        -- Deletion mode: done when the deleting flag clears
        if not unit:is_deleting() then
            local state = unit:state()
            self._unit_done[unit] = true
            -- "unknown" means deletion failed (partial delete, crash)
            self._unit_ok[unit] = state ~= "unknown"
        end
        return
    end

    -- Rank mode: state hierarchy check
    local state = unit:state()
    local target = self.target_states[unit]

    local state_rank = STATE_RANK[state]
    local target_rank = STATE_RANK[target]
    if state_rank and target_rank and state_rank >= target_rank then
        self._unit_done[unit] = true
        self._unit_ok[unit] = true
    elseif state == "configure_failed" or state == "build_failed" then
        self._unit_done[unit] = true
        self._unit_ok[unit] = false
    end
end

--- Handle a ConfigUnit state change.
--- @param unit loomworks.ConfigUnit
function Operation:_on_unit_change(unit)
    if self.completed then return end
    self:_check_unit(unit)
    self:_check_completion()
end

--- Check if all units are done and finalize the operation.
function Operation:_check_completion()
    if self.completed then return end

    local all_done = true
    for _, unit in ipairs(self.units) do
        if not self._unit_done[unit] then
            all_done = false
            break
        end
    end

    if not all_done then return end

    -- All units done — determine overall success
    local all_ok = true
    for _, unit in ipairs(self.units) do
        if not self._unit_ok[unit] then
            all_ok = false
            break
        end
    end

    self.completed = true
    self.success = all_ok

    local elapsed = self._core._deps.clock() - self.started_at
    local verb
    if self.action == "configure" then
        verb = all_ok and "configured" or "configure failed"
    elseif self.action == "build" then
        verb = all_ok and "built" or "build failed"
    elseif self.action == "clean" then
        verb = all_ok and "cleaned" or "clean failed"
    elseif self.action == "delete" then
        verb = all_ok and "deleted" or "delete failed"
    else
        verb = all_ok and "built" or "failed"
    end
    self.message = verb .. " in " .. format_duration(elapsed)

    -- Clean up listeners
    for _, unsub in ipairs(self._unsubscribers) do
        unsub()
    end
    self._unsubscribers = {}

    -- Call completion callback (Core uses this to clean up registries)
    if self._on_complete then
        self._on_complete(self)
    end

    -- Emit event
    self._core._deps.events.emit("operation_finished", {
        profile_key = self.profile and self.profile.key or nil,
        success = all_ok,
        message = self.message,
        operation = self,
    })
end

--- Check if this is a deletion-type operation (clean or delete).
--- @return boolean
function Operation:is_deletion()
    return self._mode == "deletion"
end

--- Get elapsed seconds since the operation started.
--- @return number|nil seconds
function Operation:elapsed()
    if not self.started_at then return nil end
    return self._core._deps.clock() - self.started_at
end

--- Get the number of completed units.
--- @return number done, number total
function Operation:progress_counts()
    local done = 0
    for _, unit in ipairs(self.units) do
        if self._unit_done[unit] then
            done = done + 1
        end
    end
    return done, #self.units
end

--- Check if a specific ConfigUnit is part of this operation.
--- @param unit loomworks.ConfigUnit
--- @return boolean
function Operation:has_unit(unit)
    return self.target_states[unit] ~= nil
end

--- Cancel the operation (clean up listeners, emit finished event).
--- @param message? string custom message (default "cancelled")
function Operation:cancel(message)
    if self.completed then return end
    self.completed = true
    self.success = false
    self.message = message or "cancelled"
    for _, unsub in ipairs(self._unsubscribers) do
        unsub()
    end
    self._unsubscribers = {}

    -- Call completion callback so registries get cleaned up
    if self._on_complete then
        self._on_complete(self)
    end

    -- Emit event so fidget finishes the handle
    self._core._deps.events.emit("operation_finished", {
        profile_key = self.profile and self.profile.key or nil,
        success = false,
        message = self.message,
        operation = self,
    })
end

return Operation
