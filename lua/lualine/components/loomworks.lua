--- lualine component for loomworks — shows active project/configuration/tool.
---
--- Usage in lualine config:
---   { "loomworks" }                           -- default: debug > App/Debug [ninja-gcc-12]
---   { "loomworks", show = { "project" } }     -- just the project name
---
--- Available show fields: "set_name", "project", "configuration", "tool_key",
---                        "profile_key", "status"

local M = require("lualine.component"):extend()

local default_options = {
    show = { "set_name", "project", "configuration", "tool_key" },
    join = " \u{e0b1} ",
}

function M:init(options)
    M.super.init(self, options)
    self.options = vim.tbl_deep_extend("keep", self.options or {}, default_options)

    -- Build a lookup set for fast checking
    self._show = {}
    for _, field in ipairs(self.options.show) do
        self._show[field] = true
    end
end

function M:update_status()
    -- Use package.loaded to avoid triggering lazy.nvim's module loader,
    -- which can cause circular dependency during startup.
    local lw = package.loaded["loomworks"]
    if not lw then return "" end

    local status = lw.buf_status()
    if not status then return "" end

    local parts = {}

    -- Set name: "debug"
    if self._show.set_name and status.set_name then
        parts[#parts + 1] = status.set_name
    end

    -- Project and configuration: "App/Debug" or just "App"
    local project_part
    if self._show.project and status.project then
        if self._show.configuration and status.configuration then
            project_part = status.project .. "/" .. status.configuration
        else
            project_part = status.project
        end
    elseif self._show.configuration and status.configuration then
        project_part = status.configuration
    end

    -- Tool key in brackets appended to project: "App/Debug [ninja-gcc-12]"
    if project_part then
        if self._show.tool_key and status.tool_key then
            project_part = project_part .. " [" .. status.tool_key .. "]"
        end
        parts[#parts + 1] = project_part
    elseif self._show.tool_key and status.tool_key then
        parts[#parts + 1] = "[" .. status.tool_key .. "]"
    end

    -- Profile key (full, not shown by default)
    if self._show.profile_key and status.profile_key then
        parts[#parts + 1] = status.profile_key
    end

    -- Status (not shown by default)
    if self._show.status and status.status then
        parts[#parts + 1] = status.status
    end

    return table.concat(parts, self.options.join)
end

return M
