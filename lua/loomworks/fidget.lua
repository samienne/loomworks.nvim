--- loomworks/fidget.lua — Optional fidget.nvim integration for build progress.
---
--- Shows aggregated progress notifications via fidget.nvim when
--- configure/build operations are running. No-op if fidget is not installed.

local M = {}

local fidget_progress
local handles = {} -- keyed by profile_key or "task:<task_id>"

local ACTION_TITLE = {
    configure = "Configuring",
    build = "Building",
    ["configure+build"] = "Building",
    delete = "Deleting",
    clean = "Cleaning",
}

--- Create a fidget handle for an operation or task.
--- @param key string handle key
--- @param title string
--- @param message string
--- @return table|nil handle
local function create_handle(key, title, message)
    if not fidget_progress then return nil end
    if handles[key] then return handles[key] end

    local handle = fidget_progress.handle.create({
        title = message,
        message = title,
        lsp_client = { name = "loomworks" },
    })
    handles[key] = handle
    return handle
end

--- Finish and remove a handle.
--- @param key string handle key
local function finish_handle(key)
    local handle = handles[key]
    if handle then
        handle:finish()
        handles[key] = nil
    end
end

--- Cancel and remove a handle.
--- @param key string handle key
local function cancel_handle(key)
    local handle = handles[key]
    if handle then
        handle:cancel()
        handles[key] = nil
    end
end

--- Find the handle key for a task (either its operation or standalone).
--- @param data table event data with project_key, configuration_key
--- @return string|nil key
local function find_handle_for_task(data)
    -- Check if this task's config unit belongs to an active operation
    local unit = data.unit
    if not unit then return nil end
    -- Check active operations on referencing profiles
    local refs = unit:referencing_profiles()
    for _, profile in ipairs(refs) do
        for _, op in ipairs(profile:active_operations()) do
            if op:has_unit(unit) then
                local key = "op:" .. op.id
                if handles[key] then
                    return key
                end
            end
        end
    end
    -- Standalone task
    local task_key = "task:" .. data.task_id
    if handles[task_key] then
        return task_key
    end
    return nil
end

--- Initialize fidget integration. Call from setup().
--- No-op if fidget.nvim is not available.
function M.setup()
    local ok, fp = pcall(require, "fidget.progress")
    if not ok then return end
    fidget_progress = fp

    local lw = require("loomworks")

    -- Workspace initialization progress
    lw.on("workspace_initializing", function()
        create_handle("init", "", "Initializing...")
    end)

    lw.on("workspace_changed", function()
        local handle = handles["init"]
        if handle then
            handle:report({ message = "Done" })
            handle:finish()
            handles["init"] = nil
        end
    end)

    -- Tool detection progress
    lw.on("tools_scanning", function()
        create_handle("tools", "", "Detecting tools...")
    end)

    lw.on("tools_detected", function()
        local handle = handles["tools"]
        if handle then
            handle:report({ message = "Done" })
            handle:finish()
            handles["tools"] = nil
        end
    end)

    -- All operations (build, configure, clean, delete) — keyed by operation ID
    lw.on("operation_started", function(data)
        local title = ACTION_TITLE[data.action] or data.action
        local key = data.operation and ("op:" .. data.operation.id) or data.profile_key
        local message = data.profile_key or "workspace"
        create_handle(key, title, message)
    end)

    lw.on("operation_finished", function(data)
        local key = data.operation and ("op:" .. data.operation.id) or data.profile_key
        local handle = handles[key]
        if handle then
            handle:report({
                message = data.message,
            })
            handle:finish()
            handles[key] = nil
        end
    end)

    -- Task-level events (covers both profile tasks and standalone tasks)
    lw.on("task_started", function(data)
        local handle_key = find_handle_for_task(data)
        if handle_key then
            -- Already tracked by an operation — just update message
            local handle = handles[handle_key]
            if handle then
                local action_label = data.action == "configure" and "configuring" or "building"
                local pkey = data.unit._project and data.unit._project.key or data.unit._init_project_key or "?"
                handle:report({ message = pkey .. " " .. action_label })
            end
        else
            -- Standalone task (from Projects section)
            local title = ACTION_TITLE[data.action] or data.action
            local pkey = data.unit._project and data.unit._project.key or data.unit._init_project_key or "?"
            local ckey = data.unit:config_key() or data.unit.id
            local message = pkey .. "/" .. ckey
            create_handle("task:" .. data.task_id, title, message)
        end
    end)

    lw.on("task_progress", function(data)
        local handle_key = find_handle_for_task(data)
        if not handle_key then return end
        local handle = handles[handle_key]
        if not handle then return end

        local p = data.progress
        if p and p.total > 0 then
            local pct = math.floor(p.current / p.total * 100)
            local pkey = data.unit._project and data.unit._project.key or data.unit._init_project_key or "?"
            local msg = pkey .. " [" .. p.current .. "/" .. p.total .. "]"
            handle:report({ message = msg, percentage = pct })
        end
    end)

    lw.on("task_stopped", function(data)
        -- Only finish standalone task handles; operation handles finish via operation_finished
        local task_key = "task:" .. data.task_id
        finish_handle(task_key)
    end)
end

-- ---------------------------------------------------------------------------
-- Public API for top-level action handles
-- ---------------------------------------------------------------------------

--- Create a top-level progress handle for a user action.
--- Returns a handle object with :report(), :finish(), :cancel() or nil
--- if fidget is not available.
--- @param title string e.g., "Launching ScenePluginTest: debug"
--- @return table|nil handle
function M.start_action(title)
    if not fidget_progress then return nil end
    local key = "action:" .. title .. ":" .. tostring(os.clock())
    return create_handle(key, "", title)
end

--- Report progress on a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message string
function M.report(handle, message)
    if handle then handle:report({ message = message }) end
end

--- Finish a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message? string final message
function M.finish(handle, message)
    if not handle then return end
    if message then handle:report({ message = message }) end
    handle:finish()
end

--- Cancel a handle (nil-safe).
--- @param handle table|nil fidget handle
--- @param message? string
function M.fail(handle, message)
    if not handle then return end
    if message then handle:report({ message = message }) end
    handle:cancel()
end

return M
