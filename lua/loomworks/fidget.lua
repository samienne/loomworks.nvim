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
    title = title,
    message = message,
    lsp_client = { name = "loomworks" },
    percentage = 0,
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
  -- Check if this task belongs to a profile operation
  local lw = require("loomworks")
  local refs = lw.find_referencing_profiles(data.project_key, data.configuration_key)
  for _, profile_key in ipairs(refs) do
    if handles[profile_key] then
      return profile_key
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

  -- Profile-level operations
  lw.on("operation_started", function(data)
    local title = ACTION_TITLE[data.action] or data.action
    create_handle(data.profile_key, title, data.profile_key)
  end)

  lw.on("operation_finished", function(data)
    local handle = handles[data.profile_key]
    if handle then
      handle:report({
        message = data.message,
      })
      handle:finish()
      handles[data.profile_key] = nil
    end
  end)

  -- Task-level events (covers both profile tasks and standalone tasks)
  lw.on("task_started", function(data)
    local handle_key = find_handle_for_task(data)
    if handle_key then
      -- Already tracked by a profile operation — just update message
      local handle = handles[handle_key]
      if handle then
        local action_label = data.action == "configure" and "configuring" or "building"
        handle:report({ message = data.project_key .. " " .. action_label })
      end
    else
      -- Standalone task (from Projects section)
      local title = ACTION_TITLE[data.action] or data.action
      local message = data.project_key .. "/" .. data.configuration_key
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
      local msg = data.project_key .. " [" .. p.current .. "/" .. p.total .. "]"
      handle:report({ message = msg, percentage = pct })
    end
  end)

  lw.on("task_stopped", function(data)
    -- Only finish standalone task handles; profile handles finish via operation_finished
    local task_key = "task:" .. data.task_id
    finish_handle(task_key)
  end)

  -- Deletion events (standalone deletions not covered by profile operations)
  lw.on("deletion_started", function(items)
    for _, item in ipairs(items) do
      local key = "del:" .. item.project_key .. "/" .. item.config_key
      -- Only create handle if not already tracked by a profile operation
      if not handles[key] then
        create_handle(key, "Deleting", item.project_key .. "/" .. item.config_key)
      end
    end
  end)

  lw.on("deletion_completed", function(items)
    for _, item in ipairs(items) do
      local key = "del:" .. item.project_key .. "/" .. item.config_key
      finish_handle(key)
    end
  end)

  lw.on("deletion_failed", function(data)
    for _, item in ipairs(data.items) do
      local key = "del:" .. item.project_key .. "/" .. item.config_key
      local handle = handles[key]
      if handle then
        handle:report({ message = "failed" })
        handle:cancel()
        handles[key] = nil
      end
    end
  end)
end

return M
